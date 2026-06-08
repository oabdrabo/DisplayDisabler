/*
 * Brightness.h — Unified brightness control for built-in and external displays.
 * Part of DisplayDisabler v3.0
 *
 * System-managed panels use the private DisplayServices framework (same path
 * the F1/F2 keys go through). Other external DisplayPort/HDMI/USB-C panels use
 * DDC/CI over Apple Silicon's IOAVService.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface Brightness : NSObject

+ (instancetype)shared;

// Whether this display exposes a settable brightness through either path.
// DisplayServices is preferred when macOS says it can change this display.
// Other external panels fall back to DDC/CI resolution via IOAVService.
- (BOOL)supportsBrightness:(CGDirectDisplayID)displayID;

// Write a 0–100 brightness value. DisplayServicesSetBrightness is used when
// available; unsupported external panels use DDC VCP "Set Feature" 0x03 on
// code 0x10.
- (BOOL)setBrightnessPercent:(uint8_t)percent
                  forDisplay:(CGDirectDisplayID)displayID
                       error:(NSError **)error;

// Read the display's current brightness as a 0–100 percent. Returns -1 on
// failure. DisplayServicesGetBrightness is used when available; DDC externals
// are unsupported here because VCP reads over IOAVService are fragile across
// panels.
- (int)brightnessPercentForDisplay:(CGDirectDisplayID)displayID;

// Drop the cached IOAVService handles. Call when displays come and go so
// subsequent DDC writes don't hit a stale handle to a disconnected panel.
- (void)invalidateServiceCache;

@end

NS_ASSUME_NONNULL_END
