#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Inline remote access — no Tailscale/Headscale, nothing to install. DisplayDeck
// holds a reverse SSH tunnel (macOS's built-in /usr/bin/ssh) to a relay host you
// control (e.g. your kk0s box), forwarding this Mac's SSH (22) and Screen Sharing
// (5900) to loopback ports on the relay. Reach the Mac from anywhere by hopping
// through the relay (ProxyJump). The tunnel auto-reconnects.
@interface RemoteAccess : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;   // user wants it on (persisted)
@property (nonatomic, readonly, getter=isConnected) BOOL connected; // tunnel process currently up
@property (nonatomic, readonly, nullable) NSString *lastError;   // why the tunnel last failed (nil once connected)
@property (nonatomic) BOOL keepAwake;            // hold a sleep assertion while enabled, so the Mac stays reachable (persisted, default ON)

// Turn on: generate the key if needed, enable Remote Login + Screen Sharing
// (one admin prompt), and start the auto-reconnecting tunnel.
- (void)enable;
- (void)disable;

- (nullable NSString *)publicKey;        // the key to authorize on the relay
- (int)sshPort;                          // relay loopback port → this Mac's 22
- (int)vncPort;                          // relay loopback port → this Mac's 5900
- (NSString *)relayHost;
- (NSString *)relayUser;
- (NSString *)relayPort;
- (NSString *)authorizeLine;             // forwarding-only authorized_keys line for the relay
- (BOOL)isConfigured;                    // a relay host is set

// Configure the relay (persisted; reconnects live if enabled).
- (void)setRelayHost:(NSString *)host;
- (void)setRelayUser:(NSString *)user;
- (void)setRelayPort:(NSString *)port;
- (void)setRelayHost:(NSString *)host user:(nullable NSString *)user port:(nullable NSString *)port;  // all at once

// --- Client: connect to your *other* Macs through the same relay ---
// Peers are auto-discovered: a read-only "list-peers" command on the relay
// returns every authorized Mac's name, ports, and whether its tunnel is live. Each:
// @{ @"name":…, @"user":…, @"ssh":@(port), @"vnc":@(port), @"online":@(BOOL) }.
- (NSArray<NSDictionary *> *)peers;       // last discovered set (cached)
- (void)refreshPeers;                     // async: query the relay, then onPeersChanged
@property (nonatomic, copy, nullable) void (^onPeersChanged)(void);
- (void)screenSharePeer:(NSDictionary *)peer;   // opens Screen Sharing via the relay
- (void)sshPeer:(NSDictionary *)peer;           // opens an SSH session in Terminal
- (void)sftpPeer:(NSDictionary *)peer;          // opens an SFTP (file transfer) session in Terminal

// Restore on launch if previously enabled.
- (void)restoreIfEnabled;

// Tear down the tunnel + any forwards on app quit, without changing the persisted
// enabled flag — otherwise the ssh children are orphaned and keep holding the relay
// ports, so the next launch can't rebind them.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
