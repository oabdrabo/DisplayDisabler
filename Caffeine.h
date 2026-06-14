#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keeps the Mac (and its display) awake via an IOKit power assertion — a
// built-in replacement for KeepingYouAwake / caffeinate.
@interface Caffeine : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly, nullable) NSDate *expiry;   // nil = indefinite
@property (nonatomic, copy, nullable) void (^onChange)(void);

- (void)toggle;
- (void)activateForDuration:(NSTimeInterval)duration;       // 0 = indefinite
- (void)deactivate;

@end

NS_ASSUME_NONNULL_END
