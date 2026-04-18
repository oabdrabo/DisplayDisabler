/*
 * DisplayManager.m — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import "DisplayManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
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

// ── CGVirtualDisplay private API (macOS 14+, resolved at runtime) ───────────

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id display, id error);
@property (nonatomic) NSUInteger vendorID;
@property (nonatomic) NSUInteger productID;
@property (nonatomic) NSUInteger serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

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
- (BOOL)displayHasNativeHiDPIModes:(CGDirectDisplayID)displayID;
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
    CGVirtualDisplay *vd = self.sharedVirtualDisplay;
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
            info.hasNativeHiDPIModes = [self displayHasNativeHiDPIModes:did];
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
        m.pixelWidth    = pw;
        m.pixelHeight   = ph;
        m.logicalWidth  = lw;
        m.logicalHeight = lh;
        m.refreshRate   = hz;
        m.isHiDPI       = hidpi;
        m.modeRef       = mode;
        m.isCurrent     = (pw == curPW && ph == curPH &&
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

// ── HiDPI (native) ──────────────────────────────────────────────────────────

- (BOOL)displayHasNativeHiDPIModes:(CGDirectDisplayID)displayID {
    NSDictionary *opts = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
    if (!allModes) return NO;

    BOOL hasHiDPI = NO;
    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetWidth(mode)) {
            hasHiDPI = YES;
            break;
        }
    }
    CFRelease(allModes);
    return hasHiDPI;
}

- (BOOL)switchToHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    NSDictionary *opts = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
    if (!allModes) {
        if (error) *error = ddMakeError(DDErrorReadModesFailed, @"Could not read display modes.");
        return NO;
    }

    // Choose the HiDPI mode whose pixel dimensions match the panel's current
    // pixel resolution (the "native" HiDPI where logical = pixel / 2). When
    // no such mode exists, pick the HiDPI mode with the largest logical area —
    // this is the same choice the Displays pane makes for "Default for display".
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
    size_t curPW = 0, curPH = 0;
    if (curMode) {
        curPW = CGDisplayModeGetPixelWidth(curMode);
        curPH = CGDisplayModeGetPixelHeight(curMode);
        CGDisplayModeRelease(curMode);
    }

    CGDisplayModeRef pixelMatchMode = NULL;
    CGDisplayModeRef largestAreaMode = NULL;
    size_t largestArea = 0;

    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t ph = CGDisplayModeGetPixelHeight(mode);
        size_t lw = CGDisplayModeGetWidth(mode);
        size_t lh = CGDisplayModeGetHeight(mode);
        if (pw <= lw) continue;  // not HiDPI

        if (!pixelMatchMode && pw == curPW && ph == curPH) {
            pixelMatchMode = mode;
        }
        size_t area = lw * lh;
        if (area > largestArea) {
            largestArea = area;
            largestAreaMode = mode;
        }
    }

    CGDisplayModeRef bestMode = pixelMatchMode ? pixelMatchMode : largestAreaMode;
    if (!bestMode) {
        CFRelease(allModes);
        if (error) *error = ddMakeError(DDErrorNoHiDPIModes, @"No HiDPI modes available.");
        return NO;
    }

    // Retain the chosen mode across the CFRelease of the array.
    CGDisplayModeRetain(bestMode);
    CFRelease(allModes);

    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayWithDisplayMode(config, displayID, bestMode, NULL);
    } error:error];

    CGDisplayModeRelease(bestMode);
    return ok;
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
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(virtualID, NULL);
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

// Pick color primaries for the virtual display descriptor from the source
// panel's named color space. For the common cases (built-in P3, older sRGB
// externals) this lets apps render into the correct wide-gamut/sRGB space
// instead of a blind P3 assumption. For calibrated-ICC or custom profiles
// CGColorSpaceCopyName returns NULL — we fall back to P3 (the modern-Apple
// default). CGVirtualDisplay's descriptor only accepts primaries + white
// point, so true ICC/calibration passthrough is fundamentally impossible.
static void ddPrimariesForColorSpace(CGColorSpaceRef cs,
                                      CGPoint *red, CGPoint *green,
                                      CGPoint *blue, CGPoint *white) {
    // Display P3 (default / modern Apple).
    *red   = CGPointMake(0.6800, 0.3200);
    *green = CGPointMake(0.2650, 0.6900);
    *blue  = CGPointMake(0.1500, 0.0600);
    *white = CGPointMake(0.3127, 0.3290);
    if (!cs) return;
    CFStringRef name = CGColorSpaceCopyName(cs);
    if (!name) return;
    if (CFEqual(name, kCGColorSpaceSRGB) ||
        CFEqual(name, kCGColorSpaceLinearSRGB) ||
        CFEqual(name, kCGColorSpaceExtendedSRGB) ||
        CFEqual(name, kCGColorSpaceGenericRGB)) {
        // sRGB / Rec.709 primaries, D65.
        *red   = CGPointMake(0.6400, 0.3300);
        *green = CGPointMake(0.3000, 0.6000);
        *blue  = CGPointMake(0.1500, 0.0600);
        *white = CGPointMake(0.3127, 0.3290);
    }
    CFRelease(name);
}

// Ensure the singleton shared virtual display exists, sized large enough to
// cover any plausible target (10240×5760 — enough for a 5K panel at 2×), and
// re-apply settings advertising a single (lw × lh) logical mode with HiDPI
// so the virtual has a 2× pixel backing at that logical size. The refresh
// rate matches the source panel's current refresh so ProMotion (120Hz) and
// high-refresh externals aren't pegged to 60Hz.
- (CGVirtualDisplay *)ensureSharedVirtualDisplayWithLogicalWidth:(size_t)lw
                                                          height:(size_t)lh
                                                     refreshRate:(double)refreshRate
                                                   sourceDisplay:(CGDirectDisplayID)sourceID
                                                           error:(NSError **)error {
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass     = NSClassFromString(@"CGVirtualDisplayMode");

    // CGVirtualDisplayMode.width/height are LOGICAL (points). hiDPI=1 then
    // gives a 2× pixel backing, so the mode we advertise has logical=(lw,lh)
    // and pixel=(lw*2,lh*2) — normal HiDPI with cursor canvas matching lw×lh.
    double rate = (refreshRate > 0) ? refreshRate : 60.0;
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[
        [[modeClass alloc] initWithWidth:lw height:lh refreshRate:rate],
    ];

    CGVirtualDisplay *vd = self.sharedVirtualDisplay;
    if (vd) {
        // applySettings updates the VD's advertised modes (so logical size
        // and refresh rate re-flow), but NOT its descriptor — color primaries
        // and white point are pinned to what the first force observed on its
        // source panel. Forcing across panels with different gamuts (e.g. a
        // P3 built-in then an sRGB external) keeps the first panel's
        // primaries on the virtual. This is an OS-level constraint:
        // CGVirtualDisplay's descriptor is immutable, and recreation while
        // any mirror has ever been active reliably fails on macOS 26.
        if (![vd applySettings:settings]) {
            if (error) *error = ddMakeError(DDErrorVirtualApplyFailed,
                @"Failed to reapply HiDPI settings to the shared virtual display.");
            return nil;
        }
        return vd;
    }

    // First-time creation. Generous max to support any subsequent target
    // without recreating the VD (which would fail — see class comment).
    enum { kSharedMaxPixelsWide = 10240, kSharedMaxPixelsHigh = 5760 };

    Class vdClass   = NSClassFromString(@"CGVirtualDisplay");
    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.name              = @"DD-HiDPI";
    desc.maxPixelsWide     = kSharedMaxPixelsWide;
    desc.maxPixelsHigh     = kSharedMaxPixelsHigh;
    // Size is essentially arbitrary — the compositor uses it for DPI math but
    // the VD is never the true "output" (physical mirrors it). ~27" neutral.
    desc.sizeInMillimeters = CGSizeMake(600, 340);
    desc.queue             = dispatch_get_main_queue();
    desc.vendorID          = 0xDD;
    desc.productID         = 0x01;
    desc.serialNum         = 1;
    // Match the source panel's color primaries so apps render into the
    // right gamut. For Apple Silicon built-ins and modern externals this
    // is P3; for older sRGB panels it's sRGB. Calibrated ICCs can't be
    // matched — the descriptor only takes primaries + white point.
    CGPoint redPri, greenPri, bluePri, whitePt;
    CGColorSpaceRef sourceCS = (sourceID != kCGNullDirectDisplay)
                                ? CGDisplayCopyColorSpace(sourceID) : NULL;
    ddPrimariesForColorSpace(sourceCS, &redPri, &greenPri, &bluePri, &whitePt);
    if (sourceCS) CFRelease(sourceCS);
    desc.redPrimary   = redPri;
    desc.greenPrimary = greenPri;
    desc.bluePrimary  = bluePri;
    desc.whitePoint   = whitePt;

    __weak __typeof(self) weakSelf = self;
    desc.terminationHandler = ^(id __unused display, id __unused err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleSharedVirtualDisplayTerminated];
        });
    };

    vd = [[vdClass alloc] initWithDescriptor:desc];
    if (!vd) {
        if (error) *error = ddMakeError(DDErrorVirtualCreateFailed,
                                        @"Failed to create virtual display.");
        return nil;
    }
    if (![vd applySettings:settings]) {
        if (error) *error = ddMakeError(DDErrorVirtualApplyFailed,
                                        @"Failed to apply HiDPI settings to virtual display.");
        return nil;
    }
    if (vd.displayID == kCGNullDirectDisplay) {
        if (error) *error = ddMakeError(DDErrorVirtualNoDisplayID,
                                        @"Virtual display has no valid ID.");
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
    // wrapper below clears the gate and flushes any deferred termination
    // that accumulated during the apply.
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

    if (!NSClassFromString(@"CGVirtualDisplay")) {
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

    // Resolve the panel mode we'll switch to. For a targetMode with a real
    // modeRef, it's the mode itself. For a synthetic (custom) target with nil
    // modeRef, find the best-fit panel mode:
    //   1. Exact 2×target pixels → 1:1 mirror, pixel-perfect (Standard preferred).
    //   2. Failing that, the panel mode whose dimensions minimize the max-axis
    //      scale deviation from virtual (2×target) — so the mirror's downscale
    //      is as close to 1.0 as this panel can offer. This matters on the
    //      MacBook built-in where Apple advertises a curated set of scaled
    //      modes but rarely an exact 2×target for arbitrary logical sizes.
    NSArray<DDDisplayMode *> *panelModes = [self modesForDisplay:displayID];
    CGDisplayModeRef switchMode = targetMode ? targetMode.modeRef : NULL;
    if (targetMode && !switchMode) {
        size_t wantPW = targetLogicalWidth  * 2;
        size_t wantPH = targetLogicalHeight * 2;

        // Pass 1: exact 2× match (Standard preferred).
        for (DDDisplayMode *m in panelModes) {
            if (m.pixelWidth == wantPW && m.pixelHeight == wantPH && !m.isHiDPI) {
                switchMode = m.modeRef; break;
            }
        }
        if (!switchMode) {
            for (DDDisplayMode *m in panelModes) {
                if (m.pixelWidth == wantPW && m.pixelHeight == wantPH) {
                    switchMode = m.modeRef; break;
                }
            }
        }

        // Pass 2: no exact match — closest-by-scale-deviation.
        if (!switchMode) {
            DDDisplayMode *best = nil;
            double bestScore = INFINITY;
            // Prefer Standard variants as mirror sources.
            for (DDDisplayMode *m in panelModes) {
                if (m.isHiDPI) continue;
                double rw = (double)m.pixelWidth  / (double)wantPW;
                double rh = (double)m.pixelHeight / (double)wantPH;
                double score = MAX(fabs(1.0 - rw), fabs(1.0 - rh));
                if (score < bestScore) { bestScore = score; best = m; }
            }
            // Fall back to HiDPI variants if no Standard exists.
            if (!best) {
                for (DDDisplayMode *m in panelModes) {
                    double rw = (double)m.pixelWidth  / (double)wantPW;
                    double rh = (double)m.pixelHeight / (double)wantPH;
                    double score = MAX(fabs(1.0 - rw), fabs(1.0 - rh));
                    if (score < bestScore) { bestScore = score; best = m; }
                }
            }
            if (best) switchMode = best.modeRef;
        }
    }

    // Capture the current mode for restore-on-stop — only if we're actually
    // going to switch the panel.
    DDDisplayMode *preForce = nil;
    if (switchMode) {
        for (DDDisplayMode *m in panelModes) {
            if (m.isCurrent) { preForce = m; break; }
        }
    }

    // Resolve the refresh rate to advertise on the virtual mode. Prefer the
    // target mode's rate; fall back to the panel's current rate; then 60.
    // This lets the virtual match ProMotion 120Hz / high-refresh externals
    // instead of pinning everything to 60Hz.
    double targetRate = 0.0;
    if (targetMode && targetMode.refreshRate > 0) {
        targetRate = targetMode.refreshRate;
    } else {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(displayID);
        if (cur) {
            targetRate = CGDisplayModeGetRefreshRate(cur);
            CGDisplayModeRelease(cur);
        }
    }

    NSError *vdErr = nil;
    CGVirtualDisplay *vd = [self ensureSharedVirtualDisplayWithLogicalWidth:targetLogicalWidth
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

    // THEN switch the panel to the target mode (if we resolved one).
    // No resolution = synthetic target with no matching panel mode = panel
    // stays on its current mode and macOS scales the mirror (accept blur).
    if (switchMode) {
        CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
        BOOL alreadyOnTarget = NO;
        if (curMode) {
            alreadyOnTarget =
                (CGDisplayModeGetPixelWidth(curMode)  == CGDisplayModeGetPixelWidth(switchMode) &&
                 CGDisplayModeGetPixelHeight(curMode) == CGDisplayModeGetPixelHeight(switchMode) &&
                 CGDisplayModeGetWidth(curMode)       == CGDisplayModeGetWidth(switchMode) &&
                 CGDisplayModeGetHeight(curMode)      == CGDisplayModeGetHeight(switchMode));
            CGDisplayModeRelease(curMode);
        }
        if (!alreadyOnTarget) {
            NSError *switchErr = nil;
            BOOL switched = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                return CGConfigureDisplayWithDisplayMode(config, displayID,
                                                         switchMode, NULL);
            } error:&switchErr];
            if (!switched) {
                // Roll back the mirror — leaving it live while the mode is wrong
                // strands the panel in an inconsistent state.
                [self unmirrorDisplay:displayID];
                deliver(NO, switchErr);
                return;
            }
        }
    }

    // Pin the virtual onto OUR advertised (targetLogical × targetLogical HiDPI)
    // mode. After the mirror+panel-switch above, macOS may have auto-selected
    // a virtual mode whose pixel count matches the physical's current mode
    // (auto-generated from the descriptor's 10240×5760 envelope). If the auto-
    // picked mode doesn't equal what applySettings advertised, the virtual's
    // logical ends up ≠ target and every pointer event fires at the wrong
    // coordinate (cursor visual at X, event at 2X). Explicit switch closes
    // that gap. Best-effort: worst case we fall back to the auto-pick.
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

- (NSArray<DDDisplayMode *> *)forceHiDPICandidatesFromModes:(NSArray<DDDisplayMode *> *)modes {
    if (modes.count == 0) return @[];

    // One representative per distinct pixel size. Prefer the Standard variant
    // so logicalWidth == pixelWidth — the correct value to pass as the virtual
    // display's advertised logical size. HiDPI variants are only used as a
    // fallback (no Standard exists). Panel pixel sizes that have a native
    // HiDPI variant are filtered out at the UI layer (nativeKeys) because
    // they belong in All Resolutions, not Force HiDPI. Ties: highest refresh.
    NSMutableDictionary<NSString *, DDDisplayMode *> *byPixel = [NSMutableDictionary dictionary];
    for (DDDisplayMode *m in modes) {
        NSString *key = [NSString stringWithFormat:@"%zu_%zu", m.pixelWidth, m.pixelHeight];
        DDDisplayMode *cur = byPixel[key];
        if (!cur) { byPixel[key] = m; continue; }
        if (cur.isHiDPI != m.isHiDPI) { if (!m.isHiDPI) byPixel[key] = m; continue; }
        if (m.refreshRate > cur.refreshRate) byPixel[key] = m;
    }

    return [byPixel.allValues sortedArrayUsingComparator:^NSComparisonResult(DDDisplayMode *a, DDDisplayMode *b) {
        if (a.pixelWidth  != b.pixelWidth)  return (a.pixelWidth  < b.pixelWidth)  ? NSOrderedDescending : NSOrderedAscending;
        if (a.pixelHeight != b.pixelHeight) return (a.pixelHeight < b.pixelHeight) ? NSOrderedDescending : NSOrderedAscending;
        return NSOrderedSame;
    }];
}

- (DDDisplayMode *)forcedTargetForDisplay:(CGDirectDisplayID)displayID {
    return (self.forcedPhysical == displayID) ? self.forcedTarget : nil;
}

// Restore the pre-force origin of every display we snapshotted. Best-effort:
// a failure here is cosmetic (displays stay in the force-time positions) but
// we log it so it's visible.
- (void)restorePreForceTopology {
    NSDictionary<NSNumber *, NSValue *> *topology = self.preForceTopology;
    if (topology.count == 0) return;

    // The shared virtual display isn't destroyed on stop — it's reused for
    // the next force. After we restore the physicals to their pre-force
    // origins, the VD is still sitting at whatever origin it held during
    // the force (target's pre-force origin, placed there by the apply-time
    // topology alignment). That position now collides with the physical
    // that's coming back — macOS resolves by auto-deactivating one and the
    // cursor "gets lost" on panels that end up at the same origin.
    //
    // Fix: in the SAME atomic transaction as the physical-origin restore,
    // park the VD past the rightmost restored physical so it can't collide
    // with anything user-visible. VD isn't mirrored anywhere now, so its
    // logical bounds are only used for future force reuse.
    CGVirtualDisplay *vd = self.sharedVirtualDisplay;
    CGDirectDisplayID virtualID = vd ? vd.displayID : kCGNullDirectDisplay;

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

    NSError *err = nil;
    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        for (NSNumber *didNum in topology) {
            CGDirectDisplayID did = didNum.unsignedIntValue;
            if (!CGDisplayIsActive(did)) continue;
            NSPoint p = [topology[didNum] pointValue];
            CGError e = CGConfigureDisplayOrigin(config, did, (int32_t)p.x, (int32_t)p.y);
            if (e != kCGErrorSuccess) return e;
        }
        if (virtualID != kCGNullDirectDisplay) {
            CGError e = CGConfigureDisplayOrigin(config, virtualID, parkX, 0);
            if (e != kCGErrorSuccess) return e;
        }
        return kCGErrorSuccess;
    } error:&err];
    if (!ok) {
        NSLog(@"DisplayDisabler: Warning: topology restore failed: %@", err);
    }
}

- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    if (self.forcedPhysical != displayID) {
        if (error) *error = ddMakeError(DDErrorNotForced,
                                        @"HiDPI is not being forced for this display.");
        return NO;
    }

    [self unmirrorDisplay:displayID];

    // Restore the panel to its pre-force mode so the user isn't left on the
    // reduced Standard resolution after stop.
    DDDisplayMode *pre = self.preForceMode;
    if (pre && pre.modeRef) {
        NSError *restoreErr = nil;
        if (![self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
            return CGConfigureDisplayWithDisplayMode(config, displayID, pre.modeRef, NULL);
        } error:&restoreErr]) {
            NSLog(@"DisplayDisabler: Warning: failed to restore pre-force mode on 0x%X: %@",
                  displayID, restoreErr);
        }
    }

    [self restorePreForceTopology];

    self.forcedPhysical   = kCGNullDirectDisplay;
    self.forcedTarget     = nil;
    self.preForceMode     = nil;
    self.preForceTopology = nil;
    // sharedVirtualDisplay is deliberately retained — see property comment.

    NSLog(@"DisplayDisabler: Stopped forced HiDPI for display 0x%X", displayID);
    return YES;
}

- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID {
    return self.forcedPhysical == displayID;
}

- (void)cleanUpAllVirtualDisplays {
    if (self.forcedPhysical != kCGNullDirectDisplay) {
        CGDirectDisplayID did = self.forcedPhysical;
        [self unmirrorDisplay:did];
        DDDisplayMode *pre = self.preForceMode;
        if (pre && pre.modeRef) {
            [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                return CGConfigureDisplayWithDisplayMode(config, did, pre.modeRef, NULL);
            } error:NULL];
        }
        [self restorePreForceTopology];
        self.forcedPhysical   = kCGNullDirectDisplay;
        self.forcedTarget     = nil;
        self.preForceMode     = nil;
        self.preForceTopology = nil;
    }

    // Releasing the shared VD here is mostly a formality — the process is
    // about to exit, which guarantees OS-side teardown. Clear the reference
    // so any late callbacks see a clean slate.
    if (self.sharedVirtualDisplay) {
        self.sharedVirtualDisplay = nil;
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

    CGVirtualDisplay *vd = self.sharedVirtualDisplay;
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
    NSLog(@"DisplayDisabler: Forced display 0x%X disconnected, clearing force state.", did);
    [self unmirrorDisplay:did];
    [self restorePreForceTopology];
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
