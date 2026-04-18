/*
 * DisplayManager.h — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Private API — same mechanism used by BetterDisplay to toggle displays on/off.
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

// ── Errors ──────────────────────────────────────────────────────────────────

extern NSErrorDomain const DDErrorDomain;

typedef NS_ERROR_ENUM(DDErrorDomain, DDErrorCode) {
    DDErrorCGConfigFailed        = 1,
    DDErrorInvalidMode           = 2,
    DDErrorRequiresMacOS14       = 5,
    DDErrorAlreadyForced         = 6,
    DDErrorNotForced             = 7,
    DDErrorReadCurrentModeFailed = 8,
    DDErrorVirtualCreateFailed   = 9,
    DDErrorVirtualApplyFailed    = 10,
    DDErrorVirtualNoDisplayID    = 11,
};

// ── Display info model ──────────────────────────────────────────────────────

@interface DDDisplayInfo : NSObject
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isBuiltIn;
@property (nonatomic) BOOL isActive;
@property (nonatomic) BOOL isMain;
// Current mode (only meaningful when isActive)
@property (nonatomic) size_t pixelWidth;
@property (nonatomic) size_t pixelHeight;
@property (nonatomic) size_t logicalWidth;
@property (nonatomic) size_t logicalHeight;
@property (nonatomic) double refreshRate;
@property (nonatomic) BOOL isHiDPI;
@end

// ── Display mode model ──────────────────────────────────────────────────────

@interface DDDisplayMode : NSObject
@property (nonatomic) size_t pixelWidth;
@property (nonatomic) size_t pixelHeight;
@property (nonatomic) size_t logicalWidth;
@property (nonatomic) size_t logicalHeight;
@property (nonatomic) double refreshRate;
@property (nonatomic) BOOL isHiDPI;
@property (nonatomic) BOOL isCurrent;
@property (nonatomic, nullable) CGDisplayModeRef modeRef;  // retained for setMode
@end

// ── Display manager ─────────────────────────────────────────────────────────

typedef void (^DisplayChangeBlock)(void);
typedef void (^DDForceHiDPICompletion)(BOOL success, NSError * _Nullable error);

@interface DisplayManager : NSObject

+ (instancetype)shared;

// Query
- (NSArray<DDDisplayInfo *> *)allDisplays;
- (NSArray<DDDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)displayID;
- (NSString *)nameForDisplayID:(CGDirectDisplayID)displayID;
- (nullable DDDisplayInfo *)builtInDisplay;
- (BOOL)hasExternalDisplay;

// Actions
- (BOOL)disableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)enableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)setMode:(DDDisplayMode *)mode forDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;

// HiDPI forcing via CGVirtualDisplay (macOS 14+).
// Pass `mode == nil` to force HiDPI at the panel's current pixel resolution;
// pass a concrete mode to switch the panel to that mode first, then force.
- (void)forceHiDPIForDisplay:(CGDirectDisplayID)displayID
                      atMode:(nullable DDDisplayMode *)mode
                  completion:(DDForceHiDPICompletion)completion;
// From a mode list (as returned by -modesForDisplay:), return one representative
// DDDisplayMode per distinct pixel resolution — Standard variant when available,
// otherwise the HiDPI one. The UI filters out the HiDPI-only rows because
// forcing them would be redundant with a regular mode-switch in All Resolutions.
// Sorted desc by area.
- (NSArray<DDDisplayMode *> *)forceHiDPICandidatesFromModes:(NSArray<DDDisplayMode *> *)modes;
- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID;
// The target mode currently forced for this display, or nil if not forced.
- (nullable DDDisplayMode *)forcedTargetForDisplay:(CGDirectDisplayID)displayID;
- (void)cleanUpAllVirtualDisplays;
- (void)pruneStaleVirtualDisplays;
// Re-establish the Force HiDPI invariants after a display topology change.
// macOS may drop the mirror, auto-switch the virtual's mode, or shuffle
// origins when externals connect/disconnect — this call re-asserts the
// mirror, re-pins the virtual onto our advertised mode, and re-lays out
// the topology. No-op if nothing is forced or nothing drifted.
- (void)realignForcedDisplay;

// Monitoring
- (void)startMonitoringWithChangeHandler:(DisplayChangeBlock)handler;
- (void)stopMonitoring;

@end

NS_ASSUME_NONNULL_END
