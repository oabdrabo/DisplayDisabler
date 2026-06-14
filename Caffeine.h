#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Caffeine : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly, nullable) NSDate *expiry;
@property (nonatomic, copy, nullable) void (^onChange)(void);

- (void)toggle;
- (void)activateForDuration:(NSTimeInterval)duration;
- (void)deactivate;

@end

NS_ASSUME_NONNULL_END
