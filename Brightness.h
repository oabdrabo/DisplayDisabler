/*
 * Brightness.h — Unified brightness control for built-in and external displays.
 * Part of DisplayDisabler v3.0
 *
 * Internal panels use the private DisplayServices framework (same path the F1/F2
 * keys go through). External DisplayPort/HDMI/USB-C panels use DDC/CI over
 * Apple Silicon's IOAVService.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface Brightness : NSObject

+ (instancetype)shared;

// Whether this display exposes a settable brightness through either path.
// YES for the built-in panel and for externals that advertise DDC/CI.
- (BOOL)supportsBrightness:(CGDirectDisplayID)displayID;

// Write a 0–100 brightness value to the display.
- (BOOL)setBrightnessPercent:(uint8_t)percent
                  forDisplay:(CGDirectDisplayID)displayID
                       error:(NSError **)error;

// Drop the cached IOAVService handles. Call when displays come and go so
// subsequent DDC writes don't hit a stale handle to a disconnected panel.
- (void)invalidateServiceCache;

@end

NS_ASSUME_NONNULL_END
