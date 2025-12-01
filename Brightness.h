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
// Built-in: queried via DisplayServicesCanChangeBrightness (not merely
// "DisplayServices loaded" — some panels advertise the framework but refuse
// writes). External: DDC/CI resolution via IOAVService.
- (BOOL)supportsBrightness:(CGDirectDisplayID)displayID;

// Write a 0–100 brightness value. Built-in uses DisplayServicesSetBrightness
// Smooth for the same fade animation Apple's F1/F2 path produces; external
// uses DDC VCP "Set Feature" 0x03 on code 0x10.
- (BOOL)setBrightnessPercent:(uint8_t)percent
                  forDisplay:(CGDirectDisplayID)displayID
                       error:(NSError **)error;

// Read the display's current brightness as a 0–100 percent. Returns -1 on
// failure (capability query failed, DDC read timed out, etc). Built-in
// path uses DisplayServicesGetBrightness; DDC externals are unsupported
// here because VCP reads over IOAVService are fragile across panels.
- (int)brightnessPercentForDisplay:(CGDirectDisplayID)displayID;

// Drop the cached IOAVService handles. Call when displays come and go so
// subsequent DDC writes don't hit a stale handle to a disconnected panel.
- (void)invalidateServiceCache;

@end

NS_ASSUME_NONNULL_END
