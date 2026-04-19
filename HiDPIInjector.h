/*
 * HiDPIInjector.h — Inject custom HiDPI resolutions into macOS so the OS
 * exposes them as native modes (pixel-perfect Retina at any logical size).
 *
 * Mechanism: writes a DisplayVendorID-xxx / DisplayProductID-xxx override
 * plist to /Library/Displays/Contents/Resources/Overrides and sets the
 * com.apple.windowserver DisplayResolutionEnabled preference. After a
 * reboot, System Settings → Displays and our own All Resolutions submenu
 * list the new HiDPI modes natively, at 1:1 mirror quality.
 *
 * Requires admin credentials (writes to /Library) and a reboot to activate.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface HiDPIInjector : NSObject

+ (instancetype)shared;

// Per-display logical-resolution presets to install. Derived from the panel's
// physical pixel grid at common HiDPI logical scales so every entry shares the
// panel's exact aspect — installing aspect-mismatched modes would surface
// broken/letterboxed entries in System Settings → Displays. Returned as
// NSValues of NSSize (integer components).
- (NSArray<NSValue *> *)defaultResolutionsForDisplay:(CGDirectDisplayID)displayID;

// Whether an override plist is already installed for this display.
- (BOOL)isInstalledForDisplay:(CGDirectDisplayID)displayID;

// Install overrides. Prompts for admin auth synchronously (on main); calls
// completion on main with success/error once the file is written and the
// windowserver pref has been flipped. A reboot is still required to activate.
- (void)installForDisplay:(CGDirectDisplayID)displayID
              resolutions:(NSArray<NSValue *> *)sizes
               completion:(void (^)(BOOL ok, NSError * _Nullable err))completion;

// Remove the per-display override plist.
- (void)uninstallForDisplay:(CGDirectDisplayID)displayID
                 completion:(void (^)(BOOL ok, NSError * _Nullable err))completion;

@end

NS_ASSUME_NONNULL_END
