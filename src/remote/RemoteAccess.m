#import "RemoteAccess.h"
#import <AppKit/AppKit.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

static NSString *const kEnabledKey  = @"RemoteAccessEnabled";
static NSString *const kServicesKey = @"RemoteServicesEnabled";
static NSString *const kRelayHostKey = @"RemoteRelayHost";
static NSString *const kRelayUserKey = @"RemoteRelayUser";
static NSString *const kRelayPortKey = @"RemoteRelayPort";
static NSString *const kKeepAwakeKey = @"RemoteKeepAwake";

static NSString *const kDefaultRelayHost = @"";
static NSString *const kDefaultRelayUser = @"tunnel";
static NSString *const kDefaultRelayPort = @"22";

static NSString *ddFriendlyTunnelError(NSString *raw) {
    if (raw.length == 0) return nil;
    NSString *low = raw.lowercaseString;
    if ([low containsString:@"remote port forwarding failed"]) return @"Relay port already in use";
    if ([low containsString:@"could not resolve"])             return @"Relay host not found";
    if ([low containsString:@"permission denied"])             return @"Relay rejected the key";
    if ([low containsString:@"host key verification failed"])  return @"Relay host key changed";
    if ([low containsString:@"connection refused"] || [low containsString:@"timed out"] ||
        [low containsString:@"no route to host"] || [low containsString:@"network is unreachable"])
        return @"Relay unreachable";
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) return t;
    }
    return nil;
}

@interface RemoteAccess ()
@property (nonatomic, strong) NSTask *task;
@property (nonatomic) BOOL connected;
@property (nonatomic, copy, nullable) NSString *lastError;
@property (nonatomic, strong) dispatch_queue_t q;
@property (nonatomic) NSTimeInterval backoff;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSTask *> *forwards;
@property (nonatomic, strong) NSArray<NSDictionary *> *cachedPeers;
@property (nonatomic) IOPMAssertionID sleepAssertion;
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

- (BOOL)keepAwake {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:kKeepAwakeKey];
    return v ? v.boolValue : YES;
}
- (void)setKeepAwake:(BOOL)keepAwake {
    [[NSUserDefaults standardUserDefaults] setBool:keepAwake forKey:kKeepAwakeKey];
    [self updateSleepAssertion];
}

- (void)updateSleepAssertion {
    BOOL want = self.isEnabled && self.keepAwake;
    if (want && self.sleepAssertion == 0) {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionLevelOn, CFSTR("DisplayDeck Remote Access"), &_sleepAssertion);
    } else if (!want && self.sleepAssertion != 0) {
        IOPMAssertionRelease(self.sleepAssertion);
        self.sleepAssertion = 0;
    }
}

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

- (NSString *)authorizeLine {

    [self ensureDiscoveryKey];
    NSString *fwd = [NSString stringWithFormat:
        @"restrict,port-forwarding,permitlisten=\"%d\",permitlisten=\"%d\" %@",
        self.sshPort, self.vncPort, self.publicKey ?: @""];
    NSString *disc = [NSString stringWithFormat:
        @"restrict,command=\"/usr/local/bin/dd-list-peers\" %@",
        self.discoveryPublicKey ?: @""];
    return [NSString stringWithFormat:@"%@\n%@", fwd, disc];
}

- (BOOL)isConfigured { return self.relayHost.length > 0; }

- (void)setRelayHost:(NSString *)host user:(NSString *)user port:(NSString *)port {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:(host ?: @"") forKey:kRelayHostKey];
    [d setObject:(user.length ? user : kDefaultRelayUser) forKey:kRelayUserKey];
    [d setObject:(port.length ? port : kDefaultRelayPort) forKey:kRelayPortKey];
    [self reconnect];
}

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

- (NSArray<NSDictionary *> *)peers { return self.cachedPeers ?: @[]; }

- (NSString *)discoveryKeyPath {
    return [[self supportDir] stringByAppendingPathComponent:@"remote_discovery_ed25519"];
}

- (BOOL)ensureDiscoveryKey {
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self discoveryKeyPath]]) return YES;
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/ssh-keygen";
    t.arguments = @[@"-t", @"ed25519", @"-N", @"", @"-q",
                    @"-C", [NSString stringWithFormat:@"displaydeck-discovery-%@",
                            [[NSHost currentHost] localizedName] ?: NSUserName()],
                    @"-f", [self discoveryKeyPath]];
    @try { [t launch]; [t waitUntilExit]; } @catch (__unused NSException *e) { return NO; }
    return t.terminationStatus == 0;
}

- (NSString *)discoveryPublicKey {
    NSString *pub = [[self discoveryKeyPath] stringByAppendingPathExtension:@"pub"];
    NSString *s = [NSString stringWithContentsOfFile:pub encoding:NSUTF8StringEncoding error:NULL];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)refreshPeers {
    if (!self.isConfigured || ![self ensureDiscoveryKey]) return;
    dispatch_async(self.q, ^{
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/usr/bin/ssh";
        t.arguments = @[
            @"-i", [self discoveryKeyPath], @"-o", @"IdentitiesOnly=yes",
            @"-o", @"BatchMode=yes", @"-o", @"StrictHostKeyChecking=accept-new",
            @"-o", [NSString stringWithFormat:@"UserKnownHostsFile=%@", [self knownHosts]],
            @"-o", @"ConnectTimeout=10",
            @"-p", self.relayPort,
            [NSString stringWithFormat:@"%@@%@", self.relayUser, self.relayHost] ];
        NSPipe *pipe = [NSPipe pipe];
        t.standardOutput = pipe;
        t.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSData *data = nil;
        @try {
            [t launch];
            data = [pipe.fileHandleForReading readDataToEndOfFile];
            [t waitUntilExit];
        } @catch (__unused NSException *e) { return; }
        if (t.terminationStatus != 0) return;

        NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
        int selfSsh = self.sshPort;
        for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
            NSArray<NSString *> *f = [line componentsSeparatedByString:@"\t"];
            if (f.count < 3) continue;
            int ssh = f[1].intValue, vnc = f[2].intValue;
            if (ssh <= 0) continue;
            BOOL online = (f.count >= 4 && f[3].intValue != 0);
            [found addObject:@{ @"name": f[0].length ? f[0] : @"Mac",
                                @"user": NSUserName(),
                                @"ssh": @(ssh), @"vnc": @(vnc), @"online": @(online),
                                @"self": @(ssh == selfSsh) }];
        }
        if ([found isEqualToArray:(self.cachedPeers ?: @[])]) return;
        self.cachedPeers = found;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onPeersChanged) self.onPeersChanged();
        });
    });
}

- (NSArray<NSString *> *)relayBaseArgs {
    return @[ @"-i", [self keyPath], @"-o", @"IdentitiesOnly=yes",
              @"-o", @"StrictHostKeyChecking=accept-new",
              @"-o", [NSString stringWithFormat:@"UserKnownHostsFile=%@", [self knownHosts]] ];
}

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

- (void)sftpPeer:(NSDictionary *)peer {
    int ssh = [peer[@"ssh"] intValue];
    if (ssh <= 0) return;
    NSString *cmd = [NSString stringWithFormat:
        @"sftp -i '%@' -o IdentitiesOnly=yes -J %@@%@ -P %d %@@localhost",
        [self keyPath], self.relayUser, self.relayHost, ssh, peer[@"user"]];
    NSString *src = [NSString stringWithFormat:
        @"tell application \"Terminal\"\nactivate\ndo script \"%@\"\nend tell",
        [cmd stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:src] executeAndReturnError:&err];
    if (err) NSLog(@"DisplayDeck: sftp peer failed: %@", err);
}

#pragma mark - Enable / disable

- (void)enable {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kEnabledKey];
    if (![self ensureKey]) {
        NSLog(@"DisplayDeck: remote access — key generation failed");
        return;
    }
    [self enableServicesIfNeeded];
    [self updateSleepAssertion];
    dispatch_async(self.q, ^{ self.backoff = 2.0; [self launchTunnelLocked]; });
}

- (void)disable {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kEnabledKey];
    [self updateSleepAssertion];
    dispatch_async(self.q, ^{
        NSTask *t = self.task;
        self.task = nil;
        @try { [t terminate]; } @catch (__unused NSException *e) {}
        dispatch_async(dispatch_get_main_queue(), ^{ self.connected = NO; self.lastError = nil; });
    });
}

- (void)restoreIfEnabled {
    if (self.isEnabled) [self enable];
}

- (void)shutdown {
    NSTask *t = self.task;
    self.task = nil;
    @try { if (t.isRunning) [t terminate]; } @catch (__unused NSException *e) {}
    for (NSTask *f in self.forwards.allValues) {
        @try { if (f.isRunning) [f terminate]; } @catch (__unused NSException *e) {}
    }
    [self.forwards removeAllObjects];
    if (self.sleepAssertion != 0) { IOPMAssertionRelease(self.sleepAssertion); self.sleepAssertion = 0; }
}

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
    if (self.relayHost.length == 0) return;
    if (self.task.isRunning) return;

    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/ssh";
    t.arguments = @[
        @"-i", [self keyPath],
        @"-o", @"IdentitiesOnly=yes",
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
    NSPipe *errPipe = [NSPipe pipe];
    t.standardError  = errPipe;

    __weak __typeof(self) ws = self;
    t.terminationHandler = ^(NSTask *task) {
        (void)task;
        __strong __typeof(ws) self = ws; if (!self) return;
        NSData *ed = [errPipe.fileHandleForReading readDataToEndOfFile];
        NSString *why = ddFriendlyTunnelError(
            [[NSString alloc] initWithData:ed encoding:NSUTF8StringEncoding] ?: @"");
        dispatch_async(self.q, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                self.connected = NO;
                if (why) self.lastError = why;
            });
            if (!self.isEnabled) return;

            NSTimeInterval delay = self.backoff;
            self.backoff = MIN(self.backoff * 1.6, 30.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           self.q, ^{ [self launchTunnelLocked]; });
        });
    };

    @try {
        [t launch];
        self.task = t;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), self.q, ^{
            if (self.task == t && t.isRunning) {
                self.backoff = 2.0;
                dispatch_async(dispatch_get_main_queue(), ^{ self.connected = YES; self.lastError = nil; });
            }
        });
    } @catch (__unused NSException *e) {
        NSLog(@"DisplayDeck: remote access — failed to launch ssh");
    }
}

@end
