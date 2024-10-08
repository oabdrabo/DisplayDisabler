/*
 * DDC.h — External-display DDC/CI control over Apple Silicon's IOAVService.
 * Part of DisplayDisabler v3.0
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDC : NSObject

+ (instancetype)shared;

// Whether a DCPAVServiceProxy exists for the display. True only for external
// DisplayPort / HDMI / USB-C Alt Mode panels that advertise DDC; always false
// for the built-in MacBook display and for Sidecar / AirPlay virtual outputs.
- (BOOL)supportsBrightness:(CGDirectDisplayID)displayID;

// Write a 0–100 brightness value to the display's VCP 0x10 register.
- (BOOL)setBrightnessPercent:(uint8_t)percent
                  forDisplay:(CGDirectDisplayID)displayID
                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
