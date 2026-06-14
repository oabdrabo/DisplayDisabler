#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface Brightness : NSObject

+ (instancetype)shared;

- (BOOL)supportsBrightness:(CGDirectDisplayID)displayID;

- (BOOL)setBrightnessPercent:(uint8_t)percent
                  forDisplay:(CGDirectDisplayID)displayID
                       error:(NSError **)error;

- (int)brightnessPercentForDisplay:(CGDirectDisplayID)displayID;

- (void)invalidateServiceCache;

@end

NS_ASSUME_NONNULL_END
