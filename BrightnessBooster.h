#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Pushes a display brighter than its 100% SDR maximum by rendering a fullscreen
// multiply-blend EDR overlay (white above 1.0), which engages the display's HDR
// backlight headroom while preserving colors. Technique per xdr-boost / Vivid.
@interface BrightnessBooster : NSObject

+ (instancetype)shared;

- (BOOL)available;                                    // Metal present
- (float)maxBoostForDisplay:(CGDirectDisplayID)displayID;  // EDR headroom (e.g. 2.0)
- (float)boostForDisplay:(CGDirectDisplayID)displayID;     // current, 1.0 = off
- (void)setBoost:(float)factor forDisplay:(CGDirectDisplayID)displayID;  // 1.0 removes
- (void)reapply;                                      // after a display reconfig

@end

NS_ASSUME_NONNULL_END
