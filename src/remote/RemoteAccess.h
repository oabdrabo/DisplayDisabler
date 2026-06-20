#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RemoteAccess : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly, nullable) NSString *lastError;
@property (nonatomic) BOOL keepAwake;

- (void)enable;
- (void)disable;

- (int)sshPort;
- (int)vncPort;
- (NSString *)relayHost;
- (NSString *)relayUser;
- (NSString *)relayPort;
- (NSString *)authorizeLine;
- (BOOL)isConfigured;

- (void)setRelayHost:(NSString *)host user:(nullable NSString *)user port:(nullable NSString *)port;

- (NSArray<NSDictionary *> *)peers;
- (void)refreshPeers;
@property (nonatomic, copy, nullable) void (^onPeersChanged)(void);
- (void)screenSharePeer:(NSDictionary *)peer;
- (void)sshPeer:(NSDictionary *)peer;
- (void)sftpPeer:(NSDictionary *)peer;

- (void)restoreIfEnabled;

- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
