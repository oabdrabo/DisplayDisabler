/*
 * DisplayManager.m — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import "DisplayManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <objc/runtime.h>
#include <math.h>
#include <os/log.h>

NSErrorDomain const DDErrorDomain = @"com.local.DisplayDisabler";

// ── Tunables ────────────────────────────────────────────────────────────────

// Debounce reconfiguration bursts; macOS often emits several in quick succession.
static const NSTimeInterval kDDCoalesceInterval = 0.5;

// Timeout while polling for a freshly-created virtual display to appear in
// CGGetOnlineDisplayList. Beyond this we give up and report the failure.
// Observed on macOS 26 Apple Silicon: applySettings returns success almost
// immediately but the VD can take 4–6 seconds to actually register in
// CGGetOnlineDisplayList (SkyLight fires its display-system-state-change
// notifications that late). 5s was right at the edge and sometimes lost
// the race — bumped to 15s for headroom.
static const NSTimeInterval kDDVirtualOnlineTimeout = 15.0;

// Aspect-ratio tolerance for matching a virtual/synthetic logical size against
// the panel's physical aspect. Panels round their advertised dimensions to
// integers so an exact ratio match is rare — 0.5% absorbs that integer rounding
// while rejecting any mismatch that would produce visible mirror bars. (Worst
// case at 0.5%: ~6px of pillarbox on a 2560-wide panel — below visual notice.)
static const double kDDAspectTolerance = 0.005;

// Common HiDPI logical scales applied to the panel's physical pixel grid to
// generate synthetic Force HiDPI options. Each scale s produces a logical size
// (W*s, H*s) where W×H is the panel native pixel grid; the virtual then renders
// at (W*s*2, H*s*2) pixel and mirrors back. By construction every scale yields
// the panel's exact aspect, so the mirror always fills the panel.
//   < 1.0  → larger UI (more text, less space)
//   = 1.0  → "use the whole panel as 1pt = 1 native pixel"
//   > 1.0  → smaller UI (more space)
static const double kDDHiDPIScales[] = {0.5, 0.625, 0.75, 0.875, 1.0, 1.125, 1.25, 1.5, 1.75, 2.0};
static const size_t kDDHiDPIScaleCount = sizeof(kDDHiDPIScales) / sizeof(*kDDHiDPIScales);


// ── SLVirtualDisplay private API (SkyLight, macOS 14+, runtime-resolved) ────
//
// Modern replacement for CGVirtualDisplay. The decisive practical difference
// for Force HiDPI on a notched MacBook panel: when the SLVirtualDisplay's
// configuration is cloned from the source panel's CoreDisplay info, macOS
// auto-selects the panel's own HiDPI variant as the mirror destination's
// runtime mode (e.g. pixel 5120×3328 @ logical 2560×1664 — the same scaled
// HiDPI mode System Settings would set natively). The CGVirtualDisplay path
// instead lands on a Standard-pixel mirror mode (pixel 2560×1664 @ logical
// 2560×1664), which carries different notch-handling behavior in WindowServer's
// compositor. Empirical reverse engineering (lldb disassembly of
// MBDisplays::GetDisplayNotchBounds and SLSGetDisplayAppleThemeLegacyRect)
// showed that the destination-driven safe-aperture shift cannot be overridden
// via any exposed SLS/CG/IOKit setter — switching to SL's HiDPI-mode mirror
// path is the highest-leverage workaround available without resorting to the
// reboot-and-admin Crisp HiDPI plist injection.
//
// Class layout established by introspecting class_copyMethodList /
// class_copyIvarList against the live SkyLight image. SLVirtualDisplayMode's
// pixel/points size structs are {uint32_t width; uint32_t height} (encoding
// "{?=II}") — declared anonymously here to match the runtime ABI.

typedef struct { uint32_t width; uint32_t height; } SLVirtualDisplaySize;

@interface SLVirtualDisplayMode : NSObject
- (instancetype)initWithSizeInPixels:(SLVirtualDisplaySize)pixels
                        sizeInPoints:(SLVirtualDisplaySize)points
                         refreshRate:(float)refreshRate
                               error:(NSError **)error;
@end

@interface SLVirtualDisplayConfiguration : NSObject
+ (instancetype)configurationWithDisplayInfo:(NSDictionary *)displayInfo;
@property (nonatomic) NSUInteger options;
@end

@interface SLVirtualDisplaySettings : NSObject
- (instancetype)initWithNativeMode:(SLVirtualDisplayMode *)nativeMode
                     preferredMode:(SLVirtualDisplayMode *)preferredMode
                     optionalModes:(NSArray<SLVirtualDisplayMode *> *)optionalModes
                         rotations:(NSUInteger)rotations
                             error:(NSError **)error;
@end

@interface SLVirtualDisplay : NSObject
- (instancetype)initWithConfiguration:(SLVirtualDisplayConfiguration *)config
                                error:(NSError **)error;
- (BOOL)applySettings:(SLVirtualDisplaySettings *)settings error:(NSError **)error;
- (void)destroy;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

// CoreDisplay private — used to clone the source panel's identity / chromaticities
// into the SLVirtualDisplay configuration. Already linked via -framework CoreDisplay.
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display)
    CF_RETURNS_RETAINED;

// ── Error helpers ───────────────────────────────────────────────────────────

static NSError *ddMakeError(DDErrorCode code, NSString *format, ...) NS_FORMAT_FUNCTION(2,3);
static NSError *ddMakeError(DDErrorCode code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:DDErrorDomain code:code
                 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSError *ddMakeCGError(CGError cgError, NSString *phase) {
    return [NSError errorWithDomain:DDErrorDomain
                               code:DDErrorCGConfigFailed
                           userInfo:@{
        NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"%@ (CGError %d).", phase, cgError],
    }];
}

// ── Display-list helpers (dynamic size — no silent truncation) ──────────────

typedef CGError (*DDDisplayListFn)(uint32_t, CGDirectDisplayID *, uint32_t *);

static NSArray<NSNumber *> *ddQueryDisplayList(DDDisplayListFn fn) {
    uint32_t count = 0;
    if (fn(0, NULL, &count) != kCGErrorSuccess || count == 0) return @[];
    CGDirectDisplayID *buf = calloc(count, sizeof *buf);
    if (!buf) return @[];
    CGError err = fn(count, buf, &count);
    if (err != kCGErrorSuccess) { free(buf); return @[]; }
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) [out addObject:@(buf[i])];
    free(buf);
    return out;
}

// ── Model implementations ───────────────────────────────────────────────────

@implementation DDDisplayInfo
@end

@implementation DDDisplayMode

- (void)setModeRef:(CGDisplayModeRef)modeRef {
    if (_modeRef == modeRef) return;
    if (_modeRef) CGDisplayModeRelease(_modeRef);
    _modeRef = modeRef ? CGDisplayModeRetain(modeRef) : NULL;
}

- (void)dealloc {
    if (_modeRef) CGDisplayModeRelease(_modeRef);
}

@end

// ── DisplayManager ──────────────────────────────────────────────────────────

typedef CGError (^DisplayConfigBlock)(CGDisplayConfigRef config);

@interface DisplayManager ()
@property (nonatomic, copy) DisplayChangeBlock changeHandler;
@property (nonatomic) NSInteger coalesceToken;
@property (nonatomic) BOOL monitoring;
// Exactly one CGVirtualDisplay per process, created lazily on the first
// force and reused for every subsequent one. Two constraints drive this
// singleton design:
//   1. A mirrored CGVirtualDisplay does not tear down reliably via ARC on
//      macOS 13–26 — a second create + mirror fails with CGError 1001.
//   2. Creating a second CGVirtualDisplay while the first is still alive
//      also fails (the new VD never appears in CGGetOnlineDisplayList).
// One VD, kept alive, re-configured per force, mirror swapped between
// physicals. Only one display can be forced at a time.
@property (nonatomic, strong) id sharedVirtualDisplay;
// The physical currently forced, or 0 if none. Other state is only
// meaningful while this is non-zero.
@property (nonatomic) CGDirectDisplayID forcedPhysical;
@property (nonatomic, strong) DDDisplayMode *forcedTarget;
@property (nonatomic, strong) DDDisplayMode *preForceMode;
// Snapshot of every active display's origin before the force, so we can
// restore the whole topology on stop — not just the target's mode. Without
// this, other displays stay where the force stacked them (right of virtual).
@property (nonatomic, strong) NSDictionary<NSNumber *, NSValue *> *preForceTopology;
// Re-entry guard for -realignForcedDisplay. The realign calls performDisplayConfig
// which itself emits reconfig callbacks → another coalesced realign. Each
// invariant check is idempotent (only fires when drifted), so it converges,
// but a pathological run where macOS keeps overriding our pin could oscillate.
// This flag is a hard cap: only one realign runs at a time.
@property (nonatomic) BOOL realignInFlight;
// Set YES during a force-apply critical section (from top of
// forceHiDPIForDisplay: until we deliver the completion). While set:
//   - the coalesced reconfig handler re-enqueues itself instead of running
//     prune+realign — avoiding nested CGBeginDisplayConfiguration;
//   - the VD termination handler defers clearing state until the apply
//     returns, so we don't race half-applied state against a VD that's
//     about to be nilled out.
// The wait-for-VD-online must pump the main runloop (CGVirtualDisplay's
// registration XPC requires it); this flag is what makes that pump safe.
@property (nonatomic) BOOL applyingForce;
@property (nonatomic) BOOL vdTerminationDeferred;
- (void)scheduleChangeNotification;
- (void)handleSharedVirtualDisplayTerminated;
@end

static void displayReconfigCallback(CGDirectDisplayID display __unused,
                                     CGDisplayChangeSummaryFlags flags,
                                     void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    DisplayManager *mgr = (__bridge DisplayManager *)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [mgr scheduleChangeNotification];
    });
}

@implementation DisplayManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _forcedPhysical = kCGNullDirectDisplay;
    }
    return self;
}

+ (instancetype)shared {
    static DisplayManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DisplayManager alloc] init];
    });
    return instance;
}

// ── Display configuration transaction ───────────────────────────────────────
// Wraps begin/action/complete with proper cancel-on-failure handling.

- (BOOL)performDisplayConfig:(DisplayConfigBlock)block error:(NSError **)error {
    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        os_log(OS_LOG_DEFAULT,
               "DisplayDisabler: CGBeginDisplayConfiguration → CGError %{public}d", (int)err);
        if (error) *error = ddMakeCGError(err, @"Failed to begin display configuration");
        return NO;
    }

    err = block(config);
    if (err != kCGErrorSuccess) {
        os_log(OS_LOG_DEFAULT,
               "DisplayDisabler: display-config block → CGError %{public}d", (int)err);
        CGCancelDisplayConfiguration(config);
        if (error) *error = ddMakeCGError(err, @"Display configuration step failed");
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (err != kCGErrorSuccess) {
        os_log(OS_LOG_DEFAULT,
               "DisplayDisabler: CGCompleteDisplayConfiguration → CGError %{public}d", (int)err);
        CGCancelDisplayConfiguration(config);
        if (error) *error = ddMakeCGError(err, @"Failed to commit display configuration");
        return NO;
    }

    return YES;
}

// ── Virtual display bookkeeping ─────────────────────────────────────────────

- (BOOL)isVirtualDisplayID:(CGDirectDisplayID)displayID {
    SLVirtualDisplay *vd = self.sharedVirtualDisplay;
    return vd && vd.displayID == displayID;
}

- (void)handleSharedVirtualDisplayTerminated {
    if (!self.sharedVirtualDisplay) return;
    // Defer state clear if a force-apply is mid-flight — clearing sharedVD /
    // forcedPhysical / preForceMode while the apply still holds references
    // to them would corrupt the apply's outcome. The apply itself will
    // notice the VD is gone (mirror / mode CG calls will fail) and the
    // force will return an error; after it returns, we re-run cleanup.
    if (self.applyingForce) {
        self.vdTerminationDeferred = YES;
        return;
    }
    self.sharedVirtualDisplay = nil;
    self.forcedPhysical   = kCGNullDirectDisplay;
    self.forcedTarget     = nil;
    self.preForceMode     = nil;
    self.preForceTopology = nil;
    NSLog(@"DisplayDisabler: Shared virtual display terminated externally.");
    [self scheduleChangeNotification];
}

// ── Unmirror helper ─────────────────────────────────────────────────────────

- (void)unmirrorDisplay:(CGDirectDisplayID)displayID {
    NSError *error = nil;
    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
    } error:&error];
    if (!ok) {
        NSLog(@"DisplayDisabler: Warning: failed to unmirror 0x%X: %@", displayID, error);
    }
}

// ── Display name via IOKit ──────────────────────────────────────────────────

- (NSString *)nameForDisplayID:(CGDirectDisplayID)displayID {
    NSString *defaultName = CGDisplayIsBuiltin(displayID) ? @"Built-in Display" : @"External Display";

    CFMutableDictionaryRef matching = IOServiceMatching("IODisplayConnect");
    if (!matching) return defaultName;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
        return defaultName;
    }

    uint32_t targetVendor = CGDisplayVendorNumber(displayID);
    uint32_t targetModel  = CGDisplayModelNumber(displayID);

    NSString *result = nil;
    io_service_t serv;
    while ((serv = IOIteratorNext(iter)) != 0) {
        NSDictionary *info = (__bridge_transfer NSDictionary *)
            IODisplayCreateInfoDictionary(serv, kIODisplayOnlyPreferredName);
        IOObjectRelease(serv);

        if (!info) continue;

        NSNumber *vendorID  = info[@kDisplayVendorID];
        NSNumber *productID = info[@kDisplayProductID];

        if (vendorID && productID &&
            vendorID.unsignedIntValue == targetVendor &&
            productID.unsignedIntValue == targetModel) {

            NSDictionary *names = info[@kDisplayProductName];
            if (names.count > 0) result = names.allValues.firstObject;
            break;
        }
    }
    IOObjectRelease(iter);

    return result ?: defaultName;
}

// ── Query ───────────────────────────────────────────────────────────────────

- (NSArray<DDDisplayInfo *> *)allDisplays {
    NSArray<NSNumber *> *online = ddQueryDisplayList(CGGetOnlineDisplayList);
    if (online.count == 0) return @[];

    NSSet<NSNumber *> *activeSet = [NSSet setWithArray:ddQueryDisplayList(CGGetActiveDisplayList)];

    NSMutableArray<DDDisplayInfo *> *result = [NSMutableArray arrayWithCapacity:online.count];

    for (NSNumber *didNum in online) {
        CGDirectDisplayID did = didNum.unsignedIntValue;
        if ([self isVirtualDisplayID:did]) continue;

        DDDisplayInfo *info = [[DDDisplayInfo alloc] init];
        info.displayID = did;
        info.name      = [self nameForDisplayID:did];
        info.isBuiltIn = CGDisplayIsBuiltin(did);
        info.isActive  = [activeSet containsObject:didNum];
        info.isMain    = CGDisplayIsMain(did);

        if (info.isActive) {
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
            if (mode) {
                info.logicalWidth  = CGDisplayModeGetWidth(mode);
                info.logicalHeight = CGDisplayModeGetHeight(mode);
                info.pixelWidth    = CGDisplayModeGetPixelWidth(mode);
                info.pixelHeight   = CGDisplayModeGetPixelHeight(mode);
                info.refreshRate   = CGDisplayModeGetRefreshRate(mode);
                info.isHiDPI       = (info.pixelWidth > info.logicalWidth);
                CGDisplayModeRelease(mode);
            }
        }

        [result addObject:info];
    }

    return result;
}

- (NSArray<DDDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)displayID {
    NSDictionary *opts = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
    if (!allModes) return @[];

    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
    size_t curPW = 0, curPH = 0, curLW = 0, curLH = 0;
    double curRate = 0;
    uint32_t curFlags = 0;
    if (curMode) {
        curPW    = CGDisplayModeGetPixelWidth(curMode);
        curPH    = CGDisplayModeGetPixelHeight(curMode);
        curLW    = CGDisplayModeGetWidth(curMode);
        curLH    = CGDisplayModeGetHeight(curMode);
        curRate  = CGDisplayModeGetRefreshRate(curMode);
        curFlags = CGDisplayModeGetIOFlags(curMode);
        CGDisplayModeRelease(curMode);
    }

    NSMutableArray<DDDisplayMode *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);

        size_t lw = CGDisplayModeGetWidth(mode);
        size_t lh = CGDisplayModeGetHeight(mode);
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t ph = CGDisplayModeGetPixelHeight(mode);
        double hz = CGDisplayModeGetRefreshRate(mode);
        uint32_t flags = CGDisplayModeGetIOFlags(mode);
        BOOL hidpi = (pw > lw);

        // Dedup key includes IO flags so we don't collapse modes that differ by
        // pixel encoding / stretching into a single visible row.
        NSString *key = [NSString stringWithFormat:@"%zu_%zu_%zu_%zu_%.2f_%u",
                         pw, ph, lw, lh, hz, flags];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];

        DDDisplayMode *m = [[DDDisplayMode alloc] init];
        m.pixelWidth          = pw;
        m.pixelHeight         = ph;
        m.logicalWidth        = lw;
        m.logicalHeight       = lh;
        m.refreshRate         = hz;
        m.isHiDPI             = hidpi;
        m.modeRef             = mode;
        m.isDefaultForDisplay = (flags & 0x04) != 0;  // kDisplayModeDefaultFlag
        m.isCurrent           = (pw == curPW && ph == curPH &&
                                 lw == curLW && lh == curLH &&
                                 flags == curFlags &&
                                 fabs(hz - curRate) < 1.0);

        [result addObject:m];
    }
    CFRelease(allModes);

    [result sortUsingComparator:^NSComparisonResult(DDDisplayMode *a, DDDisplayMode *b) {
        if (a.pixelWidth  != b.pixelWidth)  return (a.pixelWidth  < b.pixelWidth)  ? NSOrderedDescending : NSOrderedAscending;
        if (a.pixelHeight != b.pixelHeight) return (a.pixelHeight < b.pixelHeight) ? NSOrderedDescending : NSOrderedAscending;
        if (a.isHiDPI     != b.isHiDPI)     return a.isHiDPI ? NSOrderedAscending : NSOrderedDescending;
        if (a.refreshRate != b.refreshRate) return (a.refreshRate < b.refreshRate) ? NSOrderedDescending : NSOrderedAscending;
        return NSOrderedSame;
    }];

    return result;
}

- (DDDisplayInfo *)builtInDisplay {
    for (DDDisplayInfo *d in [self allDisplays]) {
        if (d.isBuiltIn) return d;
    }
    return nil;
}

- (BOOL)hasExternalDisplay {
    for (NSNumber *didNum in ddQueryDisplayList(CGGetOnlineDisplayList)) {
        CGDirectDisplayID did = didNum.unsignedIntValue;
        if (CGDisplayIsBuiltin(did)) continue;
        if ([self isVirtualDisplayID:did]) continue;
        return YES;
    }
    return NO;
}

- (CGSize)nativePanelPixelsForDisplay:(CGDirectDisplayID)displayID {
    // Returns the panel's FULL native pixel grid including the notch-side
    // strip area. Enumerate Standard panel modes (logical == pixel); at the
    // largest width, pick the MAX height (= full panel including strip), not
    // min (= below-notch). On the M3 Air this returns 2560×1664 (full) vs
    // physicalPixelsForDisplay:'s 2560×1600 (below-notch). Identical result
    // on non-notched panels.
    NSDictionary *opts = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID,
        (__bridge CFDictionaryRef)opts);
    CGSize result = CGSizeZero;
    if (allModes) {
        size_t maxW = 0, maxHAtMaxW = 0;
        CFIndex n = CFArrayGetCount(allModes);
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
            size_t pw = CGDisplayModeGetPixelWidth(m);
            size_t ph = CGDisplayModeGetPixelHeight(m);
            if (pw != CGDisplayModeGetWidth(m))  continue;
            if (ph != CGDisplayModeGetHeight(m)) continue;
            if (pw > maxW) { maxW = pw; maxHAtMaxW = ph; }
            else if (pw == maxW && ph > maxHAtMaxW) { maxHAtMaxW = ph; }
        }
        result.width = maxW; result.height = maxHAtMaxW;
        CFRelease(allModes);
    }
    if (result.width == 0 || result.height == 0) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(displayID);
        if (cur) {
            result.width  = CGDisplayModeGetPixelWidth(cur);
            result.height = CGDisplayModeGetPixelHeight(cur);
            CGDisplayModeRelease(cur);
        }
    }
    return result;
}

- (CGSize)physicalPixelsForDisplay:(CGDirectDisplayID)displayID {
    // Returns the dimensions of the panel's MIRROR-USABLE rectangle, which is
    // what the Force HiDPI options list must aspect-match. On a non-notched
    // panel this is simply the full pixel grid. On a notched panel (M3 Air,
    // 14/16" MBP M1+) this is the BELOW-NOTCH rectangle — macOS's mirror
    // compositor aspect-fits the source into that rectangle, so any source
    // aspect that doesn't match produces pillarbox/letterbox bars the OS
    // won't let us override (empirically verified: all SLS safe-aperture,
    // menu-bar, connection-property, SLVirtualDisplay type/subtype/options,
    // and post-mirror panel-mode-switch knobs either no-op or get reverted).
    //
    // Detection: enumerate Standard (logical == pixel) panel modes with the
    // duplicate-low-res flag set. Group by width. At the largest width where
    // more than one height exists, take the MIN height — that's the below-
    // notch rectangle. Widths with single heights stay as-is. If every width
    // has only one height, the panel is not notched and we return the max.
    NSDictionary *opts = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID,
        (__bridge CFDictionaryRef)opts);
    CGSize result = CGSizeZero;

    if (allModes) {
        NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *standardByWidth =
            [NSMutableDictionary dictionary];
        size_t maxStdW = 0;
        CFIndex n = CFArrayGetCount(allModes);
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
            size_t pw = CGDisplayModeGetPixelWidth(m);
            size_t ph = CGDisplayModeGetPixelHeight(m);
            if (pw != CGDisplayModeGetWidth(m))  continue;  // Standard only
            if (ph != CGDisplayModeGetHeight(m)) continue;
            NSMutableSet<NSNumber *> *heights = standardByWidth[@(pw)];
            if (!heights) {
                heights = [NSMutableSet set];
                standardByWidth[@(pw)] = heights;
            }
            [heights addObject:@(ph)];
            if (pw > maxStdW) maxStdW = pw;
        }
        if (maxStdW > 0) {
            NSMutableSet<NSNumber *> *heights = standardByWidth[@(maxStdW)];
            size_t h = SIZE_MAX;
            for (NSNumber *hh in heights) {
                size_t v = hh.unsignedLongValue;
                if (v < h) h = v;
            }
            result.width  = maxStdW;
            result.height = h;
        }
        CFRelease(allModes);
    }

    if (result.width == 0 || result.height == 0) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(displayID);
        if (cur) {
            result.width  = CGDisplayModeGetPixelWidth(cur);
            result.height = CGDisplayModeGetPixelHeight(cur);
            CGDisplayModeRelease(cur);
        }
    }
    return result;
}

// ── Actions ─────────────────────────────────────────────────────────────────

- (BOOL)disableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    return [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGSConfigureDisplayEnabled(config, displayID, false);
    } error:error];
}

- (BOOL)enableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    return [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGSConfigureDisplayEnabled(config, displayID, true);
    } error:error];
}

- (BOOL)setMode:(DDDisplayMode *)mode forDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    if (!mode.modeRef) {
        if (error) *error = ddMakeError(DDErrorInvalidMode, @"Invalid display mode.");
        return NO;
    }

    // Wrap in a transaction so the change is atomic and reverts cleanly on
    // failure; kCGConfigureForSession persists it for the current login session.
    return [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayWithDisplayMode(config, displayID, mode.modeRef, NULL);
    } error:error];
}

// ── Force HiDPI via CGVirtualDisplay ────────────────────────────────────────

// Find a CGDisplayModeRef on `virtualID` whose logical (point) size matches
// (lw, lh). Prefers the HiDPI variant (pixel > logical) so the virtual renders
// at 2× pixel backing for supersampling; falls back to Standard if no HiDPI
// variant exists. Returns a retained ref — caller must CGDisplayModeRelease.
// CFArrayGetValueAtIndex returns an unowned pointer whose lifetime ends with
// the array's release, so the CGDisplayModeRetain before CFRelease is what
// keeps the chosen mode alive for the caller.
- (CGDisplayModeRef)copyVirtualDisplayModeForVirtual:(CGDirectDisplayID)virtualID
                                         logicalWidth:(size_t)lw
                                        logicalHeight:(size_t)lh CF_RETURNS_RETAINED {
    // kCGDisplayShowDuplicateLowResolutionModes is REQUIRED here. Without it,
    // CGDisplayCopyAllDisplayModes hides the HiDPI variant at any pixel size
    // that also has a Standard variant (Apple's "duplicate low-res" filter
    // keeps Standard, drops HiDPI). Our SLVirtualDisplay advertises a HiDPI
    // mode with logical=2560×1664, pixel=5120×3328 — and a Standard sibling
    // with logical=pixel=2560×1664. Without the flag we'd find only Standard,
    // pin the VD to it, and the mirror compositor would then select the
    // panel's Standard mode (logical=pixel=2560×1664) instead of the panel's
    // own HiDPI variant (pixel=5120×3328). The Standard panel mode produces
    // the visible left/right pillarbox bars — picking the HiDPI variant
    // matches the panel's native scaled rendering and fills the entire panel.
    NSDictionary *opts = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(virtualID,
        (__bridge CFDictionaryRef)opts);
    if (!modes) return NULL;

    CGDisplayModeRef hidpi = NULL, standard = NULL;
    CFIndex n = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < n; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(m)  != lw) continue;
        if (CGDisplayModeGetHeight(m) != lh) continue;
        if (CGDisplayModeGetPixelWidth(m) > lw) {
            if (!hidpi) hidpi = m;
        } else {
            if (!standard) standard = m;
        }
    }
    CGDisplayModeRef chosen = hidpi ?: standard;
    if (chosen) CGDisplayModeRetain(chosen);
    CFRelease(modes);
    return chosen;
}

// Check once whether `vdID` is in the current online-display list.
- (BOOL)isDisplayIDOnline:(CGDirectDisplayID)vdID {
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(0, NULL, &n) != kCGErrorSuccess || n == 0) return NO;
    CGDirectDisplayID *buf = calloc(n, sizeof *buf);
    if (!buf) return NO;
    BOOL found = NO;
    if (CGGetOnlineDisplayList(n, buf, &n) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < n; i++) {
            if (buf[i] == vdID) { found = YES; break; }
        }
    }
    free(buf);
    return found;
}

// Wait until `vdID` appears in CGGetOnlineDisplayList, or timeout.
//
// Why we pump the main runloop here (on purpose):
// CGVirtualDisplay's registration with windowserver involves an XPC round-
// trip that requires the CLIENT's main runloop to process a queued callback
// before SkyLight publishes the display into CGGetOnlineDisplayList. A hard
// dispatch_semaphore_wait on main deadlocks that handshake — the VD stays
// unregistered until main unblocks at timeout. Runloop pumping lets the XPC
// callback run.
//
// Why this doesn't cause the re-entry hazard it used to:
// Our own coalesced reconfig handler (scheduleChangeNotification) and the
// VD termination handler (desc.queue = main) ARE dispatched to main, so
// they can fire during a runloop pump. We gate them with `applyingForce`,
// which is set YES around the force-apply critical section — while set,
// those handlers re-enqueue themselves instead of executing, so no nested
// CGBeginDisplayConfiguration can happen and no state-clearing handler
// runs mid-transaction.
- (BOOL)waitForVirtualDisplayOnline:(CGDirectDisplayID)vdID timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline compare:[NSDate date]] == NSOrderedDescending) {
        if ([self isDisplayIDOnline:vdID]) return YES;
        [[NSRunLoop mainRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return [self isDisplayIDOnline:vdID];
}

// Ensure the singleton shared SLVirtualDisplay exists and apply settings
// advertising a single mode with the requested logical size at 2× pixel
// backing. First-time creation clones the source panel's CoreDisplay info
// dictionary into the SLVirtualDisplayConfiguration — the cloned identity
// (vendor/product/serial/chromaticities/dimensions) is what causes macOS to
// auto-select the panel's own HiDPI variant as the runtime mirror mode (see
// SLVirtualDisplay header block above for the reverse-engineering trace).
//
// Subsequent forces reuse the same SLVirtualDisplay; -applySettings:error:
// re-flows the advertised mode without recreating the descriptor (which can't
// be recreated cleanly once the VD has been mirrored on macOS 14–26).
- (SLVirtualDisplay *)ensureSharedVirtualDisplayWithLogicalWidth:(size_t)lw
                                                          height:(size_t)lh
                                                     refreshRate:(double)refreshRate
                                                   sourceDisplay:(CGDirectDisplayID)sourceID
                                                           error:(NSError **)error {
    Class ModeC = NSClassFromString(@"SLVirtualDisplayMode");
    Class SetC  = NSClassFromString(@"SLVirtualDisplaySettings");
    Class CfgC  = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class VDC   = NSClassFromString(@"SLVirtualDisplay");
    if (!ModeC || !SetC || !CfgC || !VDC) {
        if (error) *error = ddMakeError(DDErrorRequiresMacOS14,
            @"SLVirtualDisplay private API not available on this macOS.");
        return nil;
    }

    float rate = (refreshRate > 0) ? (float)refreshRate : 60.0f;
    SLVirtualDisplaySize px  = {(uint32_t)(lw * 2), (uint32_t)(lh * 2)};
    SLVirtualDisplaySize pts = {(uint32_t)lw,       (uint32_t)lh};

    NSError *modeErr = nil;
    SLVirtualDisplayMode *mode = [[ModeC alloc] initWithSizeInPixels:px
                                                        sizeInPoints:pts
                                                         refreshRate:rate
                                                               error:&modeErr];
    if (!mode) {
        if (error) *error = ddMakeError(DDErrorVirtualApplyFailed,
            @"SLVirtualDisplayMode init failed: %@", modeErr.localizedDescription);
        return nil;
    }

    NSError *setErr = nil;
    SLVirtualDisplaySettings *settings = [[SetC alloc]
        initWithNativeMode:mode
             preferredMode:mode
             optionalModes:@[mode]
                 rotations:0
                     error:&setErr];
    if (!settings) {
        if (error) *error = ddMakeError(DDErrorVirtualApplyFailed,
            @"SLVirtualDisplaySettings init failed: %@", setErr.localizedDescription);
        return nil;
    }

    SLVirtualDisplay *vd = self.sharedVirtualDisplay;
    if (vd) {
        NSError *applyErr = nil;
        if (![vd applySettings:settings error:&applyErr]) {
            if (error) *error = ddMakeError(DDErrorVirtualApplyFailed,
                @"applySettings: failed: %@", applyErr.localizedDescription);
            return nil;
        }
        return vd;
    }

    // First-time creation. Clone the source panel's identity so SL's mirror
    // path lands the panel on its native HiDPI variant. CoreDisplay's info
    // dict carries vendor/product/serial/chromaticities/dimensions/name —
    // configurationWithDisplayInfo: consumes the same keys IODisplayCreateInfo
    // emits.
    if (sourceID == kCGNullDirectDisplay) {
        if (error) *error = ddMakeError(DDErrorVirtualCreateFailed,
            @"Cannot create shared virtual display without a source panel.");
        return nil;
    }
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(sourceID);
    if (!info) {
        if (error) *error = ddMakeError(DDErrorVirtualCreateFailed,
            @"CoreDisplay returned no info for source panel 0x%X.", sourceID);
        return nil;
    }
    SLVirtualDisplayConfiguration *config =
        [CfgC configurationWithDisplayInfo:(__bridge NSDictionary *)info];
    CFRelease(info);
    if (!config) {
        if (error) *error = ddMakeError(DDErrorVirtualCreateFailed,
            @"configurationWithDisplayInfo: returned nil for panel 0x%X.", sourceID);
        return nil;
    }

    // The cloned configuration inherits the source panel's
    // _maximumSizeInPixels (e.g. 6016×3384 for the M3 Air built-in), which is
    // too small for synthetic Force HiDPI sizes that go past the panel's own
    // mode envelope (e.g. 5880×3824 logical, 11760×7648 pixel). The
    // SLVirtualDisplayConfiguration property is read-only, but the underlying
    // ivar is a plain {uint32_t,uint32_t} struct — overwrite it directly to
    // grant the VD enough envelope for any plausible target. 10240×5760 covers
    // a 5K panel at 2× HiDPI, well past anything the option picker offers.
    Ivar maxIvar = class_getInstanceVariable([config class], "_maximumSizeInPixels");
    if (maxIvar) {
        ptrdiff_t offset = ivar_getOffset(maxIvar);
        SLVirtualDisplaySize *slot = (SLVirtualDisplaySize *)
            ((char *)(__bridge void *)config + offset);
        slot->width  = 10240;
        slot->height = 5760;
    }

    NSError *initErr = nil;
    vd = [[VDC alloc] initWithConfiguration:config error:&initErr];
    if (!vd) {
        if (error) *error = ddMakeError(DDErrorVirtualCreateFailed,
            @"SLVirtualDisplay init failed: %@", initErr.localizedDescription);
        return nil;
    }
    NSError *applyErr = nil;
    if (![vd applySettings:settings error:&applyErr]) {
        if (error) *error = ddMakeError(DDErrorVirtualApplyFailed,
            @"applySettings: failed on first create: %@", applyErr.localizedDescription);
        return nil;
    }
    if (vd.displayID == kCGNullDirectDisplay) {
        if (error) *error = ddMakeError(DDErrorVirtualNoDisplayID,
            @"SLVirtualDisplay has no valid displayID after apply.");
        return nil;
    }

    self.sharedVirtualDisplay = vd;
    return vd;
}

- (void)forceHiDPIForDisplay:(CGDirectDisplayID)displayID
                      atMode:(DDDisplayMode *)targetMode
                  completion:(DDForceHiDPICompletion)completion {
    // Gate coalesced reconfig handler and VD termination handler off for
    // the duration of the apply (see `applyingForce` doc). The `deliver`
    // wrapper clears the gate and flushes any deferred termination that
    // accumulated during the apply; the @try/@finally below is an
    // exception-safety backstop so the gate can't stay wedged at YES if
    // anything in the pipeline raises an ObjC exception before deliver
    // gets called.
    self.applyingForce = YES;
    __weak __typeof(self) weakSelf = self;
    DDForceHiDPICompletion deliver = ^(BOOL success, NSError *error) {
        __strong __typeof(weakSelf) strong = weakSelf;
        if (strong) {
            strong.applyingForce = NO;
            if (strong.vdTerminationDeferred) {
                strong.vdTerminationDeferred = NO;
                [strong handleSharedVirtualDisplayTerminated];
            }
        }
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
    };

    @try {

    if (!NSClassFromString(@"SLVirtualDisplay")) {
        deliver(NO, ddMakeError(DDErrorRequiresMacOS14,
                                @"Force HiDPI requires macOS 14 or later."));
        return;
    }
    if (self.forcedPhysical == displayID) {
        deliver(NO, ddMakeError(DDErrorAlreadyForced,
                                @"HiDPI is already being forced for this display."));
        return;
    }
    if (self.forcedPhysical != kCGNullDirectDisplay) {
        deliver(NO, ddMakeError(DDErrorAlreadyForced,
            @"Another display is already forced. Stop it first — this version "
            @"supports one forced display at a time (one CGVirtualDisplay per "
            @"process is an OS-level limit)."));
        return;
    }
    // The pipeline downstream reads CGDisplayBounds, CGDisplayCopyDisplayMode,
    // CGConfigureDisplay* on this ID — every one of those is meaningless on an
    // inactive display. Reject up-front so we don't smuggle a ghost ID through
    // the apply and have to dig out half-applied state later.
    if (!CGDisplayIsActive(displayID)) {
        deliver(NO, ddMakeError(DDErrorNotForced,
                                @"Cannot force HiDPI on an inactive display."));
        return;
    }
    // Snapshot the target's current bounds BEFORE any mirror / mode change,
    // so we can place the virtual at the same origin afterwards and keep
    // the cursor-topology aligned with the other displays.
    CGRect preForceBounds = CGDisplayBounds(displayID);

    // Snapshot every active display's origin so we can restore the full
    // pre-force topology on stop. The force step stacks other displays to
    // the right of the virtual; without this snapshot they stay where the
    // force put them after unforce or app quit.
    NSMutableDictionary<NSNumber *, NSValue *> *topology = [NSMutableDictionary dictionary];
    for (NSNumber *didNum in ddQueryDisplayList(CGGetActiveDisplayList)) {
        CGDirectDisplayID did = didNum.unsignedIntValue;
        if ([self isVirtualDisplayID:did]) continue;
        CGRect b = CGDisplayBounds(did);
        topology[didNum] = [NSValue valueWithPoint:NSMakePoint(b.origin.x, b.origin.y)];
    }

    // Resolve the virtual's target logical size (points). For a ⚡ force row
    // (Standard-only panel mode) logicalWidth equals pixelWidth; for a ⊕
    // custom row (synthetic) we set logical == pixel at construction. Passing
    // this as the virtual's advertised logical makes its cursor canvas match
    // the target exactly.
    size_t targetLogicalWidth = 0, targetLogicalHeight = 0;
    if (targetMode) {
        targetLogicalWidth  = targetMode.logicalWidth;
        targetLogicalHeight = targetMode.logicalHeight;
    } else {
        CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
        if (!curMode) {
            deliver(NO, ddMakeError(DDErrorReadCurrentModeFailed,
                                    @"Could not read current display mode."));
            return;
        }
        targetLogicalWidth  = CGDisplayModeGetWidth(curMode);
        targetLogicalHeight = CGDisplayModeGetHeight(curMode);
        CGDisplayModeRelease(curMode);
    }

    // Resolve the panel mode the force will switch to. Single picker for both
    // panel-derived and synthetic targets, hard aspect constraint (mismatched
    // aspect → mirror bars). Within the surviving candidates the picker
    // prefers an exact 2× pixel match (true 1:1 mirror downsample), then
    // falls within a single sweep to the smallest scale deviation, with a
    // mild bias toward Standard variants.
    //
    // Note on notched panels: macOS's mirror compositor unconditionally
    // auto-switches the destination panel to a runtime mode that matches
    // the source virtual's logical dimensions and shifts content below the
    // notch line — overriding whichever mode this picker selects. The
    // strip beside the camera notch ends up dark regardless. This is
    // destination-driven OS behavior with no override path; Crisp HiDPI
    // (panel-native plist injection) is the only architecture that can
    // render at custom logical sizes without that dead strip.
    NSArray<DDDisplayMode *> *panelModes = [self modesForDisplay:displayID];

    size_t wantPW = targetLogicalWidth  * 2;
    size_t wantPH = targetLogicalHeight * 2;
    double targetAspect = (double)wantPW / (double)wantPH;

    CGDisplayModeRef switchMode = NULL;
    double bestScore = INFINITY;
    for (DDDisplayMode *m in panelModes) {
        if (!m.modeRef) continue;
        double mAspect = (double)m.pixelWidth / (double)m.pixelHeight;
        if (fabs(mAspect - targetAspect) / targetAspect > kDDAspectTolerance) continue;

        double score;
        if (m.pixelWidth == wantPW && m.pixelHeight == wantPH) {
            // Exact 2× pixel match — pure 1:1 mirror, supersample-free path.
            score = m.isHiDPI ? -0.5 : -1.0;
        } else {
            double rw = (double)m.pixelWidth  / (double)wantPW;
            double rh = (double)m.pixelHeight / (double)wantPH;
            score = MAX(fabs(1.0 - rw), fabs(1.0 - rh));
            if (!m.isHiDPI) score *= 0.95;  // mild Standard bias
        }
        if (score < bestScore) { bestScore = score; switchMode = m.modeRef; }
    }

    // Capture the current panel mode for restore-on-stop. Captured before
    // mirror so it reflects the user-visible pre-force mode, not the runtime
    // mirror-destination mode macOS substitutes once mirroring engages.
    DDDisplayMode *preForce = nil;
    for (DDDisplayMode *m in panelModes) {
        if (m.isCurrent) { preForce = m; break; }
    }

    // Resolve the refresh rate to advertise on the virtual mode. Synthetic
    // targets carry rate=0 and inherit the panel's current rate. The panel
    // is guaranteed active here (the CGDisplayIsActive check above gates
    // entry), so CGDisplayCopyDisplayMode is non-NULL — no recovery branch
    // is needed. ProMotion 120Hz and high-refresh externals propagate
    // directly into the virtual instead of being pinned to 60Hz.
    double targetRate = (targetMode && targetMode.refreshRate > 0)
        ? targetMode.refreshRate : 0.0;
    if (targetRate == 0.0) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(displayID);
        targetRate = CGDisplayModeGetRefreshRate(cur);
        CGDisplayModeRelease(cur);
    }

    NSError *vdErr = nil;
    SLVirtualDisplay *vd = [self ensureSharedVirtualDisplayWithLogicalWidth:targetLogicalWidth
                                                                     height:targetLogicalHeight
                                                                refreshRate:targetRate
                                                              sourceDisplay:displayID
                                                                      error:&vdErr];
    if (!vd) { deliver(NO, vdErr); return; }
    CGDirectDisplayID virtualID = vd.displayID;

    // Wait until the VD is discoverable in CGGetOnlineDisplayList before
    // attempting to mirror — CGCompleteDisplayConfiguration returns 1001
    // if the destination ID isn't yet registered in the topology.
    if (![self waitForVirtualDisplayOnline:virtualID timeout:kDDVirtualOnlineTimeout]) {
        deliver(NO, ddMakeError(DDErrorVirtualCreateFailed,
                                @"Virtual display did not appear online."));
        return;
    }

    // When a CGVirtualDisplay comes online, macOS auto-places it at (0, 0),
    // which is exactly where the target's pre-force origin usually is (main
    // or built-in). macOS resolves the origin collision by deactivating one
    // of the two, and since the VD was just registered it wins — the
    // physical goes "inactive" in CGGetActiveDisplayList, and every
    // subsequent operation on the physical (mirror, enable, etc.) fails
    // confusingly.
    // Fix: move the VD to the right of the target's pre-force bounds the
    // instant it's online, clearing the (0,0) slot. The physical then
    // reactivates, mirror sets up cleanly, and the final topology-alignment
    // transaction will re-place the VD at the target's origin at the end
    // of the apply. This early move is purely to release the collision.
    int32_t parkedX = (int32_t)(preForceBounds.origin.x + preForceBounds.size.width);
    int32_t parkedY = (int32_t)preForceBounds.origin.y;
    [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayOrigin(config, virtualID, parkedX, parkedY);
    } error:NULL];

    // Now that the VD is parked away from (0,0), re-validate that the target
    // is actually still connected. If it's still inactive it wasn't the
    // collision — the user genuinely unplugged the display during the
    // wait, and continuing into mirror on a ghost ID would fail confusingly.
    if (!CGDisplayIsActive(displayID)) {
        deliver(NO, ddMakeError(DDErrorNotForced,
                                @"Target display disconnected before the force could be applied."));
        return;
    }

    // Mirror FIRST (while the panel is still on its pre-force mode). Mode-
    // switch-then-mirror hits CGError 1001 on macOS 26.3; mirror-first works.
    NSError *mirrorError = nil;
    BOOL mirrored = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayMirrorOfDisplay(config, displayID, virtualID);
    } error:&mirrorError];
    if (!mirrored) { deliver(NO, mirrorError); return; }

    // No post-mirror panel-mode switch. Empirically verified the mirror
    // destination panel is locked to the macOS-synthesized mirror-runtime
    // mode (flag kDisplayModeValidForMirroringFlag, 0x00200000) — explicit
    // CGConfigureDisplayWithDisplayMode back to a NATIVE-flagged variant
    // returns CGError 0 but the OS immediately re-synthesizes the mirror
    // mode. Forcing Force HiDPI options to aspect-match the mirror's
    // below-notch destination rectangle is the working fix (see
    // usablePanelPixelsForDisplay: — the aspect-lock now uses the below-
    // notch dimensions on notched panels).

    // Pin the virtual onto OUR advertised (targetLogical × targetLogical HiDPI)
    // mode. After the mirror+panel-switch above, macOS may have auto-selected
    // a virtual mode whose pixel count matches the physical's current mode
    // (auto-generated from the descriptor's 10240×5760 envelope). If the auto-
    // picked mode doesn't equal what applySettings advertised, the virtual's
    // logical ends up ≠ target and every pointer event fires at the wrong
    // coordinate (cursor visual at X, event at 2X). Explicit switch closes
    // that gap; the verify-then-rollback step below is what enforces it (no
    // silent acceptance of a wrong-size auto-pick).
    CGDisplayModeRef virtualMode = [self copyVirtualDisplayModeForVirtual:virtualID
                                                              logicalWidth:targetLogicalWidth
                                                             logicalHeight:targetLogicalHeight];
    if (virtualMode) {
        NSError *pinErr = nil;
        BOOL pinned = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
            return CGConfigureDisplayWithDisplayMode(config, virtualID, virtualMode, NULL);
        } error:&pinErr];
        if (!pinned) {
            NSLog(@"DisplayDisabler: Warning: could not pin virtual mode to %zu\u00D7%zu: %@",
                  targetLogicalWidth, targetLogicalHeight, pinErr);
        }
        CGDisplayModeRelease(virtualMode);
    }

    // Verify the virtual's live mode actually matches the advertised target.
    // If copyVirtualDisplayModeForVirtual returned NULL, or the pin failed, or
    // macOS auto-picked a different mode afterwards, the cursor canvas won't
    // match what apps think the screen size is → pointer events fire at
    // wrong coordinates. That's the "clicks somewhere else" class of bug we
    // spent a long time rooting out; don't silently ship it. Roll back the
    // mirror + panel-mode on mismatch and fail the force cleanly.
    CGDisplayModeRef liveMode = CGDisplayCopyDisplayMode(virtualID);
    BOOL logicalOK = NO;
    if (liveMode) {
        logicalOK = (CGDisplayModeGetWidth(liveMode)  == targetLogicalWidth &&
                     CGDisplayModeGetHeight(liveMode) == targetLogicalHeight);
        CGDisplayModeRelease(liveMode);
    }
    if (!logicalOK) {
        [self unmirrorDisplay:displayID];
        if (preForce && preForce.modeRef) {
            [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                return CGConfigureDisplayWithDisplayMode(config, displayID,
                                                         preForce.modeRef, NULL);
            } error:NULL];
        }
        deliver(NO, ddMakeError(DDErrorVirtualApplyFailed,
            @"Could not pin the virtual display to the requested logical size — "
            @"pointer coordinates would misalign. Force aborted."));
        return;
    }

    // Match the virtual display's gamma table to the physical panel's so the
    // compositor renders to virtual with the correct transfer curve. Without
    // this, mirrored HiDPI content shows a mild color/contrast shift relative
    // to the same content rendered natively on the panel. Best-effort — a
    // gamma mismatch is a quality issue, not a failure.
    [self matchGammaFromDisplay:displayID toDisplay:virtualID];

    // Realign the whole cursor topology in a single atomic transaction:
    //   - virtual takes the target panel's pre-force origin
    //   - every other active non-virtual display is stacked to its right,
    //     top-aligned with the virtual — so the cursor can cross freely
    //     at any Y in their shared range.
    // Without this, macOS auto-places the new virtual and leaves externals
    // at their old Y offset, which produces an invisible "wall" where the
    // Y-ranges don't overlap. Best-effort: a failure here is cosmetic.
    CGRect virtualBounds = CGDisplayBounds(virtualID);
    NSArray<NSNumber *> *online = ddQueryDisplayList(CGGetOnlineDisplayList);
    NSError *topoErr = nil;
    BOOL topoOk = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        CGError e = CGConfigureDisplayOrigin(config, virtualID,
                                             (int32_t)preForceBounds.origin.x,
                                             (int32_t)preForceBounds.origin.y);
        if (e != kCGErrorSuccess) return e;
        int32_t x = (int32_t)(preForceBounds.origin.x + virtualBounds.size.width);
        int32_t y = (int32_t)preForceBounds.origin.y;
        for (NSNumber *didNum in online) {
            CGDirectDisplayID other = didNum.unsignedIntValue;
            if (other == displayID) continue;            // target is now mirrored
            if (other == virtualID) continue;
            if ([self isVirtualDisplayID:other]) continue;
            if (!CGDisplayIsActive(other)) continue;
            e = CGConfigureDisplayOrigin(config, other, x, y);
            if (e != kCGErrorSuccess) return e;
            x += (int32_t)CGDisplayBounds(other).size.width;
        }
        return kCGErrorSuccess;
    } error:&topoErr];
    if (!topoOk) {
        NSLog(@"DisplayDisabler: Warning: cursor-topology alignment failed: %@", topoErr);
    }

    self.forcedPhysical   = displayID;
    self.forcedTarget     = targetMode ?: preForce;
    self.preForceMode     = preForce;
    self.preForceTopology = topology;

    NSLog(@"DisplayDisabler: Forced HiDPI for display 0x%X at %zu\u00D7%zu via virtual 0x%X",
          displayID, targetLogicalWidth, targetLogicalHeight, virtualID);
    deliver(YES, nil);

    } @finally {
        // Backstop: deliver() always clears applyingForce in the normal
        // return paths. If an ObjC exception unwound out of the pipeline
        // before any deliver call, clear it here so future forces, prunes,
        // realigns, and VD-termination handlers aren't frozen in the gate.
        if (self.applyingForce) {
            self.applyingForce = NO;
            if (self.vdTerminationDeferred) {
                self.vdTerminationDeferred = NO;
                [self handleSharedVirtualDisplayTerminated];
            }
        }
    }
}

- (BOOL)matchGammaFromDisplay:(CGDirectDisplayID)source toDisplay:(CGDirectDisplayID)target {
    enum { kGammaCapacity = 256 };
    CGGammaValue red[kGammaCapacity], green[kGammaCapacity], blue[kGammaCapacity];
    uint32_t sampleCount = 0;

    CGError err = CGGetDisplayTransferByTable(source, kGammaCapacity,
                                              red, green, blue, &sampleCount);
    if (err != kCGErrorSuccess || sampleCount == 0) {
        NSLog(@"DisplayDisabler: gamma read from 0x%X failed (%d)", source, err);
        return NO;
    }

    err = CGSetDisplayTransferByTable(target, sampleCount, red, green, blue);
    if (err != kCGErrorSuccess) {
        NSLog(@"DisplayDisabler: gamma write to 0x%X failed (%d)", target, err);
        return NO;
    }
    return YES;
}

- (NSArray<DDDisplayMode *> *)forceHiDPIOptionsForDisplay:(CGDirectDisplayID)displayID {
    CGSize physical = [self physicalPixelsForDisplay:displayID];
    if (physical.width <= 0 || physical.height <= 0) return @[];
    double panelAspect = physical.width / physical.height;

    NSArray<DDDisplayMode *> *panelModes = [self modesForDisplay:displayID];

    // Logical sizes the panel already exposes as HiDPI in All Resolutions.
    // Force HiDPI must not duplicate them — the panel-native HiDPI row is
    // always the better choice (correct fill behavior, no virtual-display
    // overhead), so offering a Force variant of the same logical size would
    // be a strictly-worse alternative.
    NSMutableSet<NSString *> *redundantLogical = [NSMutableSet set];
    for (DDDisplayMode *m in panelModes) {
        if (!m.isHiDPI) continue;
        [redundantLogical addObject:
            [NSString stringWithFormat:@"%zu_%zu", m.logicalWidth, m.logicalHeight]];
    }

    BOOL (^aspectMatches)(double, double) = ^BOOL(double w, double h) {
        if (h <= 0) return NO;
        return fabs((w / h) - panelAspect) / panelAspect <= kDDAspectTolerance;
    };

    NSMutableArray<DDDisplayMode *> *options = [NSMutableArray array];
    NSMutableSet<NSString *> *seenLogical = [NSMutableSet set];

    // Pass 1: panel Standard modes that match panel aspect AND aren't already
    // covered by a HiDPI variant in All Resolutions. Highest refresh wins
    // when several Standard rows share a pixel resolution.
    NSMutableDictionary<NSString *, DDDisplayMode *> *byPixel = [NSMutableDictionary dictionary];
    for (DDDisplayMode *m in panelModes) {
        if (m.isHiDPI) continue;
        if (!aspectMatches((double)m.pixelWidth, (double)m.pixelHeight)) continue;
        NSString *logKey = [NSString stringWithFormat:@"%zu_%zu",
                            m.logicalWidth, m.logicalHeight];
        if ([redundantLogical containsObject:logKey]) continue;
        NSString *pxKey = [NSString stringWithFormat:@"%zu_%zu",
                           m.pixelWidth, m.pixelHeight];
        DDDisplayMode *cur = byPixel[pxKey];
        if (!cur || m.refreshRate > cur.refreshRate) byPixel[pxKey] = m;
    }
    for (DDDisplayMode *m in byPixel.allValues) {
        [options addObject:m];
        [seenLogical addObject:[NSString stringWithFormat:@"%zu_%zu",
                                m.logicalWidth, m.logicalHeight]];
    }

    // Pass 2: synthetic sizes derived from panel physical at common HiDPI
    // logical scales. Aspect-correct by construction (each is panel pixels
    // multiplied by a scalar). Skip ones that overlap pass-1 results or
    // panel HiDPI logical sizes. Round to even integers so the virtual's
    // 2× pixel backing stays integer-clean.
    for (size_t i = 0; i < kDDHiDPIScaleCount; i++) {
        size_t lw = (size_t)round(physical.width  * kDDHiDPIScales[i] / 2.0) * 2;
        size_t lh = (size_t)round(physical.height * kDDHiDPIScales[i] / 2.0) * 2;
        if (lw == 0 || lh == 0) continue;
        NSString *logKey = [NSString stringWithFormat:@"%zu_%zu", lw, lh];
        if ([seenLogical containsObject:logKey]) continue;
        if ([redundantLogical containsObject:logKey]) continue;

        DDDisplayMode *synth = [[DDDisplayMode alloc] init];
        synth.pixelWidth    = lw;
        synth.pixelHeight   = lh;
        synth.logicalWidth  = lw;
        synth.logicalHeight = lh;
        synth.refreshRate   = 0;
        synth.isHiDPI       = NO;
        synth.modeRef       = NULL;
        [options addObject:synth];
        [seenLogical addObject:logKey];
    }

    [options sortUsingComparator:^NSComparisonResult(DDDisplayMode *a, DDDisplayMode *b) {
        size_t areaA = a.pixelWidth * a.pixelHeight;
        size_t areaB = b.pixelWidth * b.pixelHeight;
        if (areaA != areaB) return (areaA < areaB) ? NSOrderedDescending : NSOrderedAscending;
        if (a.refreshRate != b.refreshRate)
            return (a.refreshRate < b.refreshRate) ? NSOrderedDescending : NSOrderedAscending;
        return NSOrderedSame;
    }];

    return options;
}

- (DDDisplayMode *)forcedTargetForDisplay:(CGDirectDisplayID)displayID {
    return (self.forcedPhysical == displayID) ? self.forcedTarget : nil;
}

// Compose the topology-restore + virtual-park steps into an open
// CGDisplayConfigRef so callers can bundle them with mirror/mode operations
// in a single atomic transaction. Returns kCGErrorSuccess if there's nothing
// to restore (empty snapshot).
//
// The shared virtual display isn't destroyed on stop — it's reused for the
// next force. After we restore the physicals to their pre-force origins, the
// VD is still sitting at whatever origin it held during the force (target's
// pre-force origin, placed there by the apply-time topology alignment). That
// position now collides with the physical that's coming back; macOS resolves
// by auto-deactivating one and the cursor "gets lost" on panels that end up
// at the same origin. Parking the VD past the rightmost restored physical
// inside this same transaction prevents the collision.
- (CGError)restoreTopology:(NSDictionary<NSNumber *, NSValue *> *)topology
                  toConfig:(CGDisplayConfigRef)config {
    if (topology.count == 0) return kCGErrorSuccess;

    int32_t rightmost = 0;
    BOOL haveRightmost = NO;
    for (NSNumber *didNum in topology) {
        NSPoint p = [topology[didNum] pointValue];
        CGRect b = CGDisplayBounds(didNum.unsignedIntValue);
        int32_t right = (int32_t)(p.x + b.size.width);
        if (!haveRightmost || right > rightmost) {
            rightmost = right;
            haveRightmost = YES;
        }
    }
    int32_t parkX = haveRightmost ? rightmost + 256 : 0;

    for (NSNumber *didNum in topology) {
        CGDirectDisplayID did = didNum.unsignedIntValue;
        if (!CGDisplayIsActive(did)) continue;
        NSPoint p = [topology[didNum] pointValue];
        CGError e = CGConfigureDisplayOrigin(config, did, (int32_t)p.x, (int32_t)p.y);
        if (e != kCGErrorSuccess) return e;
    }

    SLVirtualDisplay *vd = self.sharedVirtualDisplay;
    if (vd) {
        CGError e = CGConfigureDisplayOrigin(config, vd.displayID, parkX, 0);
        if (e != kCGErrorSuccess) return e;
    }

    return kCGErrorSuccess;
}

- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    if (self.forcedPhysical != displayID) {
        if (error) *error = ddMakeError(DDErrorNotForced,
                                        @"HiDPI is not being forced for this display.");
        return NO;
    }

    DDDisplayMode *pre                                     = self.preForceMode;
    NSDictionary<NSNumber *, NSValue *> *topology          = self.preForceTopology;

    // Single atomic transaction: unmirror + pre-force mode restore + topology
    // restore + virtual park. Splitting these across multiple
    // performDisplayConfig calls leaves the cursor in ambiguous coordinate
    // space between commits — macOS spends time re-resolving its position
    // and the cursor visibly disappears for a beat. One transaction = one
    // coherent state change = the OS reposition the cursor exactly once at
    // the end.
    NSError *err = nil;
    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        CGError e = CGConfigureDisplayMirrorOfDisplay(config, displayID,
                                                       kCGNullDirectDisplay);
        if (e != kCGErrorSuccess) return e;
        if (pre && pre.modeRef) {
            e = CGConfigureDisplayWithDisplayMode(config, displayID, pre.modeRef, NULL);
            if (e != kCGErrorSuccess) return e;
        }
        return [self restoreTopology:topology toConfig:config];
    } error:&err];

    if (!ok) {
        NSLog(@"DisplayDisabler: Warning: stop transaction failed on 0x%X: %@",
              displayID, err);
    }

    self.forcedPhysical   = kCGNullDirectDisplay;
    self.forcedTarget     = nil;
    self.preForceMode     = nil;
    self.preForceTopology = nil;
    // sharedVirtualDisplay is deliberately retained — see property comment.

    NSLog(@"DisplayDisabler: Stopped forced HiDPI for display 0x%X", displayID);
    return ok;
}

- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID {
    return self.forcedPhysical == displayID;
}

- (void)cleanUpAllVirtualDisplays {
    if (self.forcedPhysical != kCGNullDirectDisplay) {
        CGDirectDisplayID did                              = self.forcedPhysical;
        DDDisplayMode *pre                                 = self.preForceMode;
        NSDictionary<NSNumber *, NSValue *> *topology      = self.preForceTopology;
        // Same single-transaction discipline as -stopForcedHiDPIForDisplay:
        // so the cursor doesn't disappear between commits during process
        // shutdown.
        [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
            CGError e = CGConfigureDisplayMirrorOfDisplay(config, did,
                                                           kCGNullDirectDisplay);
            if (e != kCGErrorSuccess) return e;
            if (pre && pre.modeRef) {
                e = CGConfigureDisplayWithDisplayMode(config, did, pre.modeRef, NULL);
                if (e != kCGErrorSuccess) return e;
            }
            return [self restoreTopology:topology toConfig:config];
        } error:NULL];

        self.forcedPhysical   = kCGNullDirectDisplay;
        self.forcedTarget     = nil;
        self.preForceMode     = nil;
        self.preForceTopology = nil;
    }

    // Releasing the shared SLVirtualDisplay here is mostly a formality — the
    // process is about to exit, which guarantees OS-side teardown. -destroy
    // is the SL-API tear-down primitive; nil-ing the property without it would
    // leak the VD until WindowServer noticed the dead client.
    if (self.sharedVirtualDisplay) {
        SLVirtualDisplay *vd = self.sharedVirtualDisplay;
        self.sharedVirtualDisplay = nil;
        [vd destroy];
        NSLog(@"DisplayDisabler: Released shared virtual display.");
    }
}

// Re-establish the Force HiDPI invariants after a display topology change.
// When an external connects/disconnects or a mode changes elsewhere, macOS
// can (a) break the physical↔virtual mirror, (b) auto-switch the virtual
// to a mode matching whatever panel is now present, (c) shuffle display
// origins. Any of those leaves the cursor drifting or the force looking
// "half-applied". We check each invariant and fix only what drifted — no
// blind reconfiguration, so this is safe to call on every reconfig event.
- (void)realignForcedDisplay {
    if (self.forcedPhysical == kCGNullDirectDisplay) return;
    if (self.realignInFlight) return;
    CGDirectDisplayID physical = self.forcedPhysical;
    if (!CGDisplayIsActive(physical)) return;  // pruneStaleVirtualDisplays handles

    SLVirtualDisplay *vd = self.sharedVirtualDisplay;
    if (!vd) return;
    CGDirectDisplayID virtualID = vd.displayID;
    self.realignInFlight = YES;

    // @try/@finally guarantees the guard clears even if an ObjC exception
    // propagates (e.g. future NSLog format-spec bug) — otherwise a thrown
    // exception between set and clear would wedge realigns forever.
    @try {
        // 1. Mirror integrity.
        BOOL mirrorOK = (CGDisplayMirrorsDisplay(physical) == virtualID);

        // 2. Virtual-mode integrity: must still be our advertised logical size.
        DDDisplayMode *target = self.forcedTarget;
        BOOL modeOK = YES;
        if (target) {
            CGDisplayModeRef curV = CGDisplayCopyDisplayMode(virtualID);
            if (curV) {
                modeOK = (CGDisplayModeGetWidth(curV)  == target.logicalWidth &&
                          CGDisplayModeGetHeight(curV) == target.logicalHeight);
                CGDisplayModeRelease(curV);
            } else {
                modeOK = NO;
            }
        }

        // 3. Topology integrity: virtual origin matches the pre-force snapshot,
        // other displays stacked right of the virtual.
        NSValue *physOriginV = self.preForceTopology[@(physical)];
        CGPoint physOrigin = physOriginV ? [physOriginV pointValue] : CGPointZero;
        CGRect vb = CGDisplayBounds(virtualID);
        BOOL topoOK = (vb.origin.x == physOrigin.x && vb.origin.y == physOrigin.y);

        if (mirrorOK && modeOK && topoOK) return;

        NSLog(@"DisplayDisabler: Realigning forced display after reconfig "
              @"(mirror=%d mode=%d topology=%d).", mirrorOK, modeOK, topoOK);

        if (!mirrorOK) {
            [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                return CGConfigureDisplayMirrorOfDisplay(config, physical, virtualID);
            } error:NULL];
        }

        if (!modeOK && target) {
            CGDisplayModeRef vmode = [self copyVirtualDisplayModeForVirtual:virtualID
                                                               logicalWidth:target.logicalWidth
                                                              logicalHeight:target.logicalHeight];
            if (vmode) {
                [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                    return CGConfigureDisplayWithDisplayMode(config, virtualID, vmode, NULL);
                } error:NULL];
                CGDisplayModeRelease(vmode);
            }
        }

        if (!topoOK) {
            CGRect postVB = CGDisplayBounds(virtualID);
            NSArray<NSNumber *> *online = ddQueryDisplayList(CGGetOnlineDisplayList);
            [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                CGError e = CGConfigureDisplayOrigin(config, virtualID,
                                                     (int32_t)physOrigin.x,
                                                     (int32_t)physOrigin.y);
                if (e != kCGErrorSuccess) return e;
                int32_t x = (int32_t)(physOrigin.x + postVB.size.width);
                int32_t y = (int32_t)physOrigin.y;
                for (NSNumber *didNum in online) {
                    CGDirectDisplayID other = didNum.unsignedIntValue;
                    if (other == physical) continue;
                    if (other == virtualID) continue;
                    if ([self isVirtualDisplayID:other]) continue;
                    if (!CGDisplayIsActive(other)) continue;
                    e = CGConfigureDisplayOrigin(config, other, x, y);
                    if (e != kCGErrorSuccess) return e;
                    x += (int32_t)CGDisplayBounds(other).size.width;
                }
                return kCGErrorSuccess;
            } error:NULL];
        }
    } @finally {
        self.realignInFlight = NO;
    }
}

- (void)pruneStaleVirtualDisplays {
    if (self.forcedPhysical == kCGNullDirectDisplay) return;

    NSSet<NSNumber *> *onlineSet = [NSSet setWithArray:ddQueryDisplayList(CGGetOnlineDisplayList)];
    if ([onlineSet containsObject:@(self.forcedPhysical)]) return;

    CGDirectDisplayID did = self.forcedPhysical;
    NSDictionary<NSNumber *, NSValue *> *topology = self.preForceTopology;
    NSLog(@"DisplayDisabler: Forced display 0x%X disconnected, clearing force state.", did);

    // Single transaction: unmirror the now-offline ID + restore origins of
    // remaining displays + park the virtual. The forced display is gone so
    // the cursor isn't on it, but the survivors' origins changing in
    // separate commits would still glitch the cursor on whichever screen
    // it's currently on.
    [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        CGError e = CGConfigureDisplayMirrorOfDisplay(config, did,
                                                       kCGNullDirectDisplay);
        // Unmirror on a vanished ID may legitimately fail; ignore and proceed
        // with the topology restore for the survivors.
        (void)e;
        return [self restoreTopology:topology toConfig:config];
    } error:NULL];

    self.forcedPhysical   = kCGNullDirectDisplay;
    self.forcedTarget     = nil;
    self.preForceMode     = nil;
    self.preForceTopology = nil;
    // sharedVirtualDisplay stays alive for the next force.
}

// ── Monitoring ──────────────────────────────────────────────────────────────

- (void)startMonitoringWithChangeHandler:(DisplayChangeBlock)handler {
    if (self.monitoring) [self stopMonitoring];
    self.changeHandler = handler;
    self.monitoring = YES;

    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback,
                                              (__bridge void *)self);

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(screenParametersChanged:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:nil];
}

- (void)screenParametersChanged:(NSNotification *)notification {
    (void)notification;
    // NSApplicationDidChangeScreenParametersNotification is posted on main, so
    // no dispatch hop is required.
    [self scheduleChangeNotification];
}

- (void)scheduleChangeNotification {
    NSInteger token = ++self.coalesceToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kDDCoalesceInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.coalesceToken) return;
        // Defer if a force-apply is mid-flight. Re-enqueue ourselves so the
        // handler (prune + realign + menu rebuild) eventually runs after the
        // apply returns. This is what makes it safe for waitForVirtualDisplay-
        // Online to pump the runloop — the coalesced handler that would
        // otherwise fire here (and call performDisplayConfig inside an open
        // apply transaction) just reschedules itself instead.
        if (self.applyingForce) {
            [self scheduleChangeNotification];
            return;
        }
        if (self.changeHandler) self.changeHandler();
    });
}

- (void)stopMonitoring {
    if (!self.monitoring) return;
    CGDisplayRemoveReconfigurationCallback(displayReconfigCallback,
                                            (__bridge void *)self);
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    self.changeHandler = nil;
    self.monitoring = NO;
}

@end
