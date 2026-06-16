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
- (NSString *)connectCommand;            // copy-paste command to reach this Mac
- (NSString *)authorizeLine;             // forwarding-only authorized_keys line for the relay
- (BOOL)isConfigured;                    // a relay host is set

// Configure the relay (persisted; reconnects live if enabled).
- (void)setRelayHost:(NSString *)host;
- (void)setRelayUser:(NSString *)user;
- (void)setRelayPort:(NSString *)port;
- (void)setRelayHost:(NSString *)host user:(nullable NSString *)user port:(nullable NSString *)port;  // all at once

// --- Client: connect to your *other* Macs through the same relay ---
// Each peer: @{ @"name":…, @"user":…, @"ssh":@(port), @"vnc":@(port) }.
- (NSArray<NSDictionary *> *)peers;
- (void)addPeerName:(NSString *)name user:(NSString *)user ssh:(int)ssh vnc:(int)vnc;
- (void)removePeerAtIndex:(NSUInteger)index;
- (void)screenSharePeer:(NSDictionary *)peer;   // opens Screen Sharing via the relay
- (void)sshPeer:(NSDictionary *)peer;           // opens an SSH session in Terminal

// Restore on launch if previously enabled.
- (void)restoreIfEnabled;

@end

NS_ASSUME_NONNULL_END
