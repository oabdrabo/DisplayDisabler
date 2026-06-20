#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrightnessBooster : NSObject

+ (instancetype)shared;

- (float)maxBoostForDisplay:(CGDirectDisplayID)displayID;
- (float)boostForDisplay:(CGDirectDisplayID)displayID;
- (void)setBoost:(float)factor forDisplay:(CGDirectDisplayID)displayID;
- (void)reapply;

@end

NS_ASSUME_NONNULL_END
