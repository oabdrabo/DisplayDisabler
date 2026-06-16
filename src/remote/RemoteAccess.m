#import "RemoteAccess.h"
#import <AppKit/AppKit.h>

static NSString *const kEnabledKey  = @"RemoteAccessEnabled";
static NSString *const kServicesKey = @"RemoteServicesEnabled";   // services already turned on once
static NSString *const kRelayHostKey = @"RemoteRelayHost";
static NSString *const kRelayUserKey = @"RemoteRelayUser";
static NSString *const kRelayPortKey = @"RemoteRelayPort";

static NSString *const kDefaultRelayHost = @"";          // unset by default — user configures
static NSString *const kDefaultRelayUser = @"tunnel";
static NSString *const kDefaultRelayPort = @"22";

static NSString *const kPeersKey = @"RemotePeers";

@interface RemoteAccess ()
@property (nonatomic, strong) NSTask *task;
@property (nonatomic) BOOL connected;
@property (nonatomic, strong) dispatch_queue_t q;
@property (nonatomic) NSTimeInterval backoff;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSTask *> *forwards;  // localPort → ssh -L
@end

@implementation RemoteAccess

+ (instancetype)shared {
    static RemoteAccess *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[RemoteAccess alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _q = dispatch_queue_create("com.local.DisplayDeck.remote", DISPATCH_QUEUE_SERIAL);
        _backoff = 2.0;
        _forwards = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Paths / config

- (NSString *)supportDir {
    NSString *base = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"DisplayDeck"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}
- (NSString *)keyPath       { return [[self supportDir] stringByAppendingPathComponent:@"remote_id_ed25519"]; }
- (NSString *)knownHosts    { return [[self supportDir] stringByAppendingPathComponent:@"known_hosts"]; }

- (NSString *)relayHost { return [[NSUserDefaults standardUserDefaults] stringForKey:kRelayHostKey] ?: kDefaultRelayHost; }
- (NSString *)relayUser { return [[NSUserDefaults standardUserDefaults] stringForKey:kRelayUserKey] ?: kDefaultRelayUser; }
- (NSString *)relayPort { return [[NSUserDefaults standardUserDefaults] stringForKey:kRelayPortKey] ?: kDefaultRelayPort; }

- (BOOL)isEnabled { return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledKey]; }

// Stable per-Mac loopback ports on the relay, derived from the host name.
- (int)portWithBase:(int)base {
    NSString *name = [[NSHost currentHost] localizedName] ?: NSUserName();
    NSUInteger h = name.hash % 1500;
    return base + (int)h;
}
- (int)sshPort { return [self portWithBase:22000]; }
- (int)vncPort { return [self portWithBase:24000]; }

#pragma mark - Key

- (BOOL)ensureKey {
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self keyPath]]) return YES;
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/ssh-keygen";
    t.arguments = @[@"-t", @"ed25519", @"-N", @"", @"-q",
                    @"-C", [NSString stringWithFormat:@"displaydeck-remote-%@",
                            [[NSHost currentHost] localizedName] ?: NSUserName()],
                    @"-f", [self keyPath]];
    @try { [t launch]; [t waitUntilExit]; } @catch (__unused NSException *e) { return NO; }
    return t.terminationStatus == 0;
}

- (NSString *)publicKey {
    NSString *pub = [[self keyPath] stringByAppendingPathExtension:@"pub"];
    NSString *s = [NSString stringWithContentsOfFile:pub encoding:NSUTF8StringEncoding error:NULL];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)connectCommand {
    return [NSString stringWithFormat:@"ssh -J %@@%@ %@@localhost -p %d",
            self.relayUser, self.relayHost, NSUserName(), self.sshPort];
}

- (NSString *)authorizeLine {
    // permitlisten locks the *reverse* tunnel to this Mac's own ports; local
    // forwarding stays open so the same key can act as a client (ProxyJump /
    // -L) to reach peer Macs' ports on the relay.
    return [NSString stringWithFormat:
        @"restrict,port-forwarding,permitlisten=\"%d\",permitlisten=\"%d\" %@",
        self.sshPort, self.vncPort, self.publicKey ?: @""];
}

- (BOOL)isConfigured { return self.relayHost.length > 0; }

- (void)setRelayHost:(NSString *)host {
    [[NSUserDefaults standardUserDefaults] setObject:(host ?: @"") forKey:kRelayHostKey];
    [self reconnect];
}
- (void)setRelayUser:(NSString *)user {
    [[NSUserDefaults standardUserDefaults] setObject:(user.length ? user : kDefaultRelayUser) forKey:kRelayUserKey];
    [self reconnect];
}
- (void)setRelayPort:(NSString *)port {
    [[NSUserDefaults standardUserDefaults] setObject:(port.length ? port : kDefaultRelayPort) forKey:kRelayPortKey];
    [self reconnect];
}
- (void)setRelayHost:(NSString *)host user:(NSString *)user port:(NSString *)port {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:(host ?: @"") forKey:kRelayHostKey];
    [d setObject:(user.length ? user : kDefaultRelayUser) forKey:kRelayUserKey];
    [d setObject:(port.length ? port : kDefaultRelayPort) forKey:kRelayPortKey];
    [self reconnect];
}

// Pick up new relay settings live: drop the current tunnel; the termination
// handler relaunches it (reading the fresh config). No-op if not enabled.
- (void)reconnect {
    if (!self.isEnabled) return;
    dispatch_async(self.q, ^{
        self.backoff = 2.0;
        if (self.task.isRunning) {
            @try { [self.task terminate]; } @catch (__unused NSException *e) {}
        } else {
            [self launchTunnelLocked];
        }
    });
}

#pragma mark - Client (connect to peer Macs)

- (NSArray<NSDictionary *> *)peers {
    NSArray *p = [[NSUserDefaults standardUserDefaults] arrayForKey:kPeersKey];
    return [p isKindOfClass:[NSArray class]] ? p : @[];
}

- (void)addPeerName:(NSString *)name user:(NSString *)user ssh:(int)ssh vnc:(int)vnc {
    if (name.length == 0 || ssh <= 0) return;
    NSMutableArray *p = [self.peers mutableCopy];
    [p addObject:@{ @"name": name,
                    @"user": user.length ? user : NSUserName(),
                    @"ssh": @(ssh),
                    @"vnc": @(vnc > 0 ? vnc : 0) }];
    [[NSUserDefaults standardUserDefaults] setObject:p forKey:kPeersKey];
}

- (void)removePeerAtIndex:(NSUInteger)index {
    NSMutableArray *p = [self.peers mutableCopy];
    if (index < p.count) {
        [p removeObjectAtIndex:index];
        [[NSUserDefaults standardUserDefaults] setObject:p forKey:kPeersKey];
    }
}

// Common ssh args to reach the relay with only our key.
- (NSArray<NSString *> *)relayBaseArgs {
    return @[ @"-i", [self keyPath], @"-o", @"IdentitiesOnly=yes",
              @"-o", @"StrictHostKeyChecking=accept-new",
              @"-o", [NSString stringWithFormat:@"UserKnownHostsFile=%@", [self knownHosts]] ];
}

// Open Screen Sharing to a peer: hold an ssh -L from a local port → relay's
// loopback port that the peer reverse-forwarded its :5900 onto, then open vnc://.
- (void)screenSharePeer:(NSDictionary *)peer {
    int vnc = [peer[@"vnc"] intValue];
    if (vnc <= 0) return;
    int local = 5910 + (vnc % 85);

    NSTask *existing = self.forwards[@(local)];
    if (!existing.isRunning) {
        NSMutableArray *args = [[self relayBaseArgs] mutableCopy];
        [args addObjectsFromArray:@[
            @"-N", @"-T", @"-o", @"ExitOnForwardFailure=yes",
            @"-L", [NSString stringWithFormat:@"%d:localhost:%d", local, vnc],
            @"-p", self.relayPort,
            [NSString stringWithFormat:@"%@@%@", self.relayUser, self.relayHost] ]];
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/usr/bin/ssh";
        t.arguments = args;
        t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        t.standardError  = [NSFileHandle fileHandleWithNullDevice];
        @try { [t launch]; self.forwards[@(local)] = t; }
        @catch (__unused NSException *e) { return; }
    }
    NSString *url = [NSString stringWithFormat:@"vnc://localhost:%d", local];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
    });
}

// Open an SSH session to a peer in Terminal (ProxyJump through the relay).
- (void)sshPeer:(NSDictionary *)peer {
    int ssh = [peer[@"ssh"] intValue];
    if (ssh <= 0) return;
    NSString *cmd = [NSString stringWithFormat:
        @"ssh -i '%@' -o IdentitiesOnly=yes -J %@@%@ %@@localhost -p %d",
        [self keyPath], self.relayUser, self.relayHost, peer[@"user"], ssh];
    NSString *src = [NSString stringWithFormat:
        @"tell application \"Terminal\"\nactivate\ndo script \"%@\"\nend tell",
        [cmd stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
    if (err) NSLog(@"DisplayDeck: ssh peer failed: %@", err);
}

#pragma mark - Enable / disable

- (void)enable {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kEnabledKey];
    if (![self ensureKey]) {
        NSLog(@"DisplayDeck: remote access — key generation failed");
        return;
    }
    [self enableServicesIfNeeded];
    dispatch_async(self.q, ^{ self.backoff = 2.0; [self launchTunnelLocked]; });
}

- (void)disable {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kEnabledKey];
    dispatch_async(self.q, ^{
        NSTask *t = self.task;
        self.task = nil;
        @try { [t terminate]; } @catch (__unused NSException *e) {}
        dispatch_async(dispatch_get_main_queue(), ^{ self.connected = NO; });
    });
}

- (void)restoreIfEnabled {
    if (self.isEnabled) [self enable];
}

// Enable Remote Login + Screen Sharing once (single admin prompt). Best-effort:
// if it fails, the tunnel still runs; the user can enable the services manually.
- (void)enableServicesIfNeeded {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kServicesKey]) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *sh =
            @"/usr/sbin/systemsetup -f -setremotelogin on >/dev/null 2>&1; "
            @"/bin/launchctl enable system/com.apple.screensharing >/dev/null 2>&1; "
            @"/bin/launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1; "
            @"true";
        NSString *src = [NSString stringWithFormat:
            @"do shell script \"%@\" with administrator privileges", sh];
        NSDictionary *err = nil;
        [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
        if (!err) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kServicesKey];
        } else {
            NSLog(@"DisplayDeck: remote access — could not enable services: %@", err);
        }
    });
}

#pragma mark - Tunnel (runs on self.q)

- (void)launchTunnelLocked {
    if (!self.isEnabled) return;
    if (self.relayHost.length == 0) return;   // not configured yet
    if (self.task.isRunning) return;

    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/ssh";
    t.arguments = @[
        @"-i", [self keyPath],
        @"-o", @"IdentitiesOnly=yes",   // offer ONLY our key (avoids tripping fail2ban)
        @"-N", @"-T",
        @"-o", @"ExitOnForwardFailure=yes",
        @"-o", @"ServerAliveInterval=30",
        @"-o", @"ServerAliveCountMax=3",
        @"-o", @"StrictHostKeyChecking=accept-new",
        @"-o", [NSString stringWithFormat:@"UserKnownHostsFile=%@", [self knownHosts]],
        @"-o", @"ConnectTimeout=15",
        @"-R", [NSString stringWithFormat:@"%d:localhost:22", self.sshPort],
        @"-R", [NSString stringWithFormat:@"%d:localhost:5900", self.vncPort],
        @"-p", self.relayPort,
        [NSString stringWithFormat:@"%@@%@", self.relayUser, self.relayHost],
    ];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];

    __weak __typeof(self) ws = self;
    t.terminationHandler = ^(NSTask *task) {
        (void)task;
        __strong __typeof(ws) self = ws; if (!self) return;
        dispatch_async(self.q, ^{
            dispatch_async(dispatch_get_main_queue(), ^{ self.connected = NO; });
            if (!self.isEnabled) return;
            // exponential backoff, capped — survive relay reboots / network drops
            NSTimeInterval delay = self.backoff;
            self.backoff = MIN(self.backoff * 1.6, 30.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           self.q, ^{ [self launchTunnelLocked]; });
        });
    };

    @try {
        [t launch];
        self.task = t;
        // If it stays up a few seconds, consider it connected and reset backoff.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), self.q, ^{
            if (self.task == t && t.isRunning) {
                self.backoff = 2.0;
                dispatch_async(dispatch_get_main_queue(), ^{ self.connected = YES; });
            }
        });
    } @catch (__unused NSException *e) {
        NSLog(@"DisplayDeck: remote access — failed to launch ssh");
    }
}

@end
