/*
 * DisplayManager.m — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import "DisplayManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <math.h>

NSErrorDomain const DDErrorDomain = @"com.local.DisplayDisabler";

// ── Tunables ────────────────────────────────────────────────────────────────

// Debounce reconfiguration bursts; macOS often emits several in quick succession.
static const NSTimeInterval kDDCoalesceInterval = 0.5;

// Timeout while polling for a freshly-created virtual display to appear in
// CGGetOnlineDisplayList. Beyond this we give up and report the failure.
static const NSTimeInterval kDDVirtualOnlineTimeout = 5.0;

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
// One virtual display per physical, kept alive for the process lifetime once
// created. CGVirtualDisplay on macOS 13–26 does not reliably tear down after
// being mirrored; a subsequent create+mirror fails with CGError 1001. The
// only robust pattern is "create once, reuse forever". See probe evidence.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *virtualDisplays;
// Target mode currently forced per physical, or absent when not forced.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, DDDisplayMode *> *forceActiveTargets;
// Panel mode captured before the first force, used to restore on stop.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, DDDisplayMode *> *preForceModes;
- (void)scheduleChangeNotification;
- (void)handleVirtualDisplayTerminated:(CGDirectDisplayID)physicalID;
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
        _virtualDisplays     = [NSMutableDictionary dictionary];
        _forceActiveTargets  = [NSMutableDictionary dictionary];
        _preForceModes       = [NSMutableDictionary dictionary];
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
        if (error) *error = ddMakeCGError(err, @"Failed to begin display configuration");
        return NO;
    }

    err = block(config);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = ddMakeCGError(err, @"Display configuration step failed");
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = ddMakeCGError(err, @"Failed to commit display configuration");
        return NO;
    }

    return YES;
}

// ── Virtual display bookkeeping ─────────────────────────────────────────────

- (BOOL)isVirtualDisplayID:(CGDirectDisplayID)displayID {
    for (CGVirtualDisplay *vd in self.virtualDisplays.allValues) {
        if (vd.displayID == displayID) return YES;
    }
    return NO;
}

- (void)handleVirtualDisplayTerminated:(CGDirectDisplayID)physicalID {
    if (!self.virtualDisplays[@(physicalID)]) return;
    [self.virtualDisplays    removeObjectForKey:@(physicalID)];
    [self.forceActiveTargets removeObjectForKey:@(physicalID)];
    [self.preForceModes      removeObjectForKey:@(physicalID)];
    NSLog(@"DisplayDisabler: Virtual display for 0x%X terminated externally.", physicalID);
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

// Wait until `vdID` appears in CGGetOnlineDisplayList, or timeout.
- (BOOL)waitForVirtualDisplayOnline:(CGDirectDisplayID)vdID timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline compare:[NSDate date]] == NSOrderedDescending) {
        uint32_t n = 0;
        if (CGGetOnlineDisplayList(0, NULL, &n) == kCGErrorSuccess && n > 0) {
            CGDirectDisplayID *buf = calloc(n, sizeof *buf);
            if (buf && CGGetOnlineDisplayList(n, buf, &n) == kCGErrorSuccess) {
                for (uint32_t i = 0; i < n; i++) {
                    if (buf[i] == vdID) { free(buf); return YES; }
                }
            }
            if (buf) free(buf);
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return NO;
}

- (CGVirtualDisplay *)getOrCreateVirtualDisplayForPhysical:(CGDirectDisplayID)displayID
                                                pixelWidth:(size_t)pixelWidth
                                               pixelHeight:(size_t)pixelHeight
                                                     error:(NSError **)error {
    CGVirtualDisplay *existing = self.virtualDisplays[@(displayID)];
    if (existing) {
        // Reuse. Re-apply settings so the VD advertises modes that match this
        // force's target (needed when consecutive forces use different targets).
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        Class modeClass     = NSClassFromString(@"CGVirtualDisplayMode");
        CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[
            [[modeClass alloc] initWithWidth:pixelWidth * 2 height:pixelHeight * 2 refreshRate:60.0],
            [[modeClass alloc] initWithWidth:pixelWidth     height:pixelHeight     refreshRate:60.0],
        ];
        if (![existing applySettings:settings]) {
            if (error) *error = ddMakeError(DDErrorVirtualApplyFailed,
                                            @"Failed to reapply HiDPI settings to virtual display.");
            return nil;
        }
        return existing;
    }

    // First-time creation.
    CGSize mm = CGDisplayScreenSize(displayID);
    if (mm.width <= 0 || mm.height <= 0) {
        if (error) *error = ddMakeError(DDErrorPhysicalSizeUnknown,
            @"Display reports no physical size; cannot build a virtual display.");
        return nil;
    }

    Class vdClass       = NSClassFromString(@"CGVirtualDisplay");
    Class descClass     = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass     = NSClassFromString(@"CGVirtualDisplayMode");

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.name              = [NSString stringWithFormat:@"DD-HiDPI-%X", displayID];
    desc.maxPixelsWide     = pixelWidth * 2;
    desc.maxPixelsHigh     = pixelHeight * 2;
    desc.sizeInMillimeters = mm;
    desc.queue             = dispatch_get_main_queue();
    desc.vendorID          = 0xDD;
    desc.productID         = 0x01;
    desc.serialNum         = displayID;
    // sRGB primaries / D65 white point — vanilla color description.
    desc.redPrimary   = CGPointMake(0.6400, 0.3300);
    desc.greenPrimary = CGPointMake(0.3000, 0.6000);
    desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
    desc.whitePoint   = CGPointMake(0.3127, 0.3290);

    __weak __typeof(self) weakSelf = self;
    CGDirectDisplayID physicalID = displayID;
    desc.terminationHandler = ^(id __unused display, id __unused err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleVirtualDisplayTerminated:physicalID];
        });
    };

    CGVirtualDisplay *vd = [[vdClass alloc] initWithDescriptor:desc];
    if (!vd) {
        if (error) *error = ddMakeError(DDErrorVirtualCreateFailed,
                                        @"Failed to create virtual display.");
        return nil;
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[
        [[modeClass alloc] initWithWidth:pixelWidth * 2 height:pixelHeight * 2 refreshRate:60.0],
        [[modeClass alloc] initWithWidth:pixelWidth     height:pixelHeight     refreshRate:60.0],
    ];
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

    self.virtualDisplays[@(displayID)] = vd;
    return vd;
}

- (void)forceHiDPIForDisplay:(CGDirectDisplayID)displayID
                      atMode:(DDDisplayMode *)targetMode
                  completion:(DDForceHiDPICompletion)completion {
    DDForceHiDPICompletion deliver = ^(BOOL success, NSError *error) {
        if (!completion) return;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
    };

    if (!NSClassFromString(@"CGVirtualDisplay")) {
        deliver(NO, ddMakeError(DDErrorRequiresMacOS14,
                                @"Force HiDPI requires macOS 14 or later."));
        return;
    }
    if (self.forceActiveTargets[@(displayID)]) {
        deliver(NO, ddMakeError(DDErrorAlreadyForced,
                                @"HiDPI is already being forced for this display."));
        return;
    }
    if (targetMode && !targetMode.modeRef) {
        deliver(NO, ddMakeError(DDErrorInvalidMode, @"Invalid display mode."));
        return;
    }

    // Resolve target pixel size.
    size_t pixelWidth = 0, pixelHeight = 0;
    if (targetMode) {
        pixelWidth  = targetMode.pixelWidth;
        pixelHeight = targetMode.pixelHeight;
    } else {
        CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
        if (!curMode) {
            deliver(NO, ddMakeError(DDErrorReadCurrentModeFailed,
                                    @"Could not read current display mode."));
            return;
        }
        pixelWidth  = CGDisplayModeGetPixelWidth(curMode);
        pixelHeight = CGDisplayModeGetPixelHeight(curMode);
        CGDisplayModeRelease(curMode);
    }

    // Capture the current mode for restore-on-stop (only if we're actually
    // switching — i.e. targetMode provided and different from current).
    DDDisplayMode *preForce = nil;
    if (targetMode) {
        for (DDDisplayMode *m in [self modesForDisplay:displayID]) {
            if (m.isCurrent) { preForce = m; break; }
        }
    }

    NSError *vdErr = nil;
    CGVirtualDisplay *vd = [self getOrCreateVirtualDisplayForPhysical:displayID
                                                           pixelWidth:pixelWidth
                                                          pixelHeight:pixelHeight
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

    // Mirror FIRST (while the panel is still on its pre-force mode). Mode-
    // switch-then-mirror hits CGError 1001 on macOS 26.3; mirror-first works.
    NSError *mirrorError = nil;
    BOOL mirrored = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayMirrorOfDisplay(config, displayID, virtualID);
    } error:&mirrorError];
    if (!mirrored) { deliver(NO, mirrorError); return; }

    // THEN switch the panel to the target mode (if any, and not already there).
    if (targetMode) {
        CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
        BOOL alreadyOnTarget = NO;
        if (curMode) {
            alreadyOnTarget =
                (CGDisplayModeGetPixelWidth(curMode)  == targetMode.pixelWidth &&
                 CGDisplayModeGetPixelHeight(curMode) == targetMode.pixelHeight &&
                 CGDisplayModeGetWidth(curMode)       == targetMode.logicalWidth &&
                 CGDisplayModeGetHeight(curMode)      == targetMode.logicalHeight);
            CGDisplayModeRelease(curMode);
        }
        if (!alreadyOnTarget) {
            NSError *switchErr = nil;
            BOOL switched = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                return CGConfigureDisplayWithDisplayMode(config, displayID,
                                                         targetMode.modeRef, NULL);
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

    // Match the virtual display's gamma table to the physical panel's so the
    // compositor renders to virtual with the correct transfer curve. Without
    // this, mirrored HiDPI content shows a mild color/contrast shift relative
    // to the same content rendered natively on the panel. Best-effort — a
    // gamma mismatch is a quality issue, not a failure.
    [self matchGammaFromDisplay:displayID toDisplay:virtualID];

    self.forceActiveTargets[@(displayID)] = targetMode ?: preForce;
    if (preForce) self.preForceModes[@(displayID)] = preForce;

    NSLog(@"DisplayDisabler: Forced HiDPI for display 0x%X at %zu\u00D7%zu via virtual 0x%X",
          displayID, pixelWidth, pixelHeight, virtualID);
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

    // One representative per distinct pixel size. Prefer a Standard mode (the
    // panel already drives that pixel count 1:1, which is what we want before
    // mirror+switch). Fall back to a HiDPI representative if no Standard exists
    // for that size. Among ties, pick the highest refresh.
    NSMutableDictionary<NSString *, DDDisplayMode *> *byPixel = [NSMutableDictionary dictionary];
    for (DDDisplayMode *m in modes) {
        NSString *key = [NSString stringWithFormat:@"%zu_%zu", m.pixelWidth, m.pixelHeight];
        DDDisplayMode *cur = byPixel[key];
        if (!cur) { byPixel[key] = m; continue; }
        BOOL curIsStd = !cur.isHiDPI, mIsStd = !m.isHiDPI;
        if (curIsStd != mIsStd) { if (mIsStd) byPixel[key] = m; continue; }
        if (m.refreshRate > cur.refreshRate) byPixel[key] = m;
    }

    return [byPixel.allValues sortedArrayUsingComparator:^NSComparisonResult(DDDisplayMode *a, DDDisplayMode *b) {
        if (a.pixelWidth  != b.pixelWidth)  return (a.pixelWidth  < b.pixelWidth)  ? NSOrderedDescending : NSOrderedAscending;
        if (a.pixelHeight != b.pixelHeight) return (a.pixelHeight < b.pixelHeight) ? NSOrderedDescending : NSOrderedAscending;
        return NSOrderedSame;
    }];
}

- (NSSet<NSString *> *)nativeHiDPIPixelKeysFromModes:(NSArray<DDDisplayMode *> *)modes {
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (DDDisplayMode *m in modes) {
        if (m.isHiDPI) {
            [set addObject:[NSString stringWithFormat:@"%zu_%zu", m.pixelWidth, m.pixelHeight]];
        }
    }
    return set;
}

- (DDDisplayMode *)forcedTargetForDisplay:(CGDirectDisplayID)displayID {
    return self.forceActiveTargets[@(displayID)];
}

- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    if (!self.forceActiveTargets[@(displayID)]) {
        if (error) *error = ddMakeError(DDErrorNotForced,
                                        @"HiDPI is not being forced for this display.");
        return NO;
    }

    [self unmirrorDisplay:displayID];

    // Restore the panel to its pre-force mode so the user isn't left on the
    // reduced Standard resolution after stop.
    DDDisplayMode *pre = self.preForceModes[@(displayID)];
    if (pre && pre.modeRef) {
        NSError *restoreErr = nil;
        if (![self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
            return CGConfigureDisplayWithDisplayMode(config, displayID, pre.modeRef, NULL);
        } error:&restoreErr]) {
            NSLog(@"DisplayDisabler: Warning: failed to restore pre-force mode on 0x%X: %@",
                  displayID, restoreErr);
        }
    }

    [self.forceActiveTargets removeObjectForKey:@(displayID)];
    [self.preForceModes      removeObjectForKey:@(displayID)];
    // virtualDisplays entry is deliberately retained — see property comment.

    NSLog(@"DisplayDisabler: Stopped forced HiDPI for display 0x%X", displayID);
    return YES;
}

- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID {
    return self.forceActiveTargets[@(displayID)] != nil;
}

- (void)cleanUpAllVirtualDisplays {
    for (NSNumber *physicalIDNum in self.forceActiveTargets.allKeys) {
        CGDirectDisplayID did = physicalIDNum.unsignedIntValue;
        [self unmirrorDisplay:did];
        DDDisplayMode *pre = self.preForceModes[physicalIDNum];
        if (pre && pre.modeRef) {
            [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                return CGConfigureDisplayWithDisplayMode(config, did, pre.modeRef, NULL);
            } error:NULL];
        }
    }
    [self.forceActiveTargets removeAllObjects];
    [self.preForceModes      removeAllObjects];

    // Releasing the virtual displays here is mostly a formality — the process
    // is about to exit, which guarantees OS-side teardown. Still, clear the
    // dict so any late callbacks see a clean slate.
    if (self.virtualDisplays.count > 0) {
        [self.virtualDisplays removeAllObjects];
        NSLog(@"DisplayDisabler: Cleaned up all virtual displays.");
    }
}

- (void)pruneStaleVirtualDisplays {
    if (self.virtualDisplays.count == 0) return;

    NSSet<NSNumber *> *onlineSet = [NSSet setWithArray:ddQueryDisplayList(CGGetOnlineDisplayList)];

    for (NSNumber *physicalIDNum in self.virtualDisplays.allKeys) {
        if (![onlineSet containsObject:physicalIDNum]) {
            CGDirectDisplayID did = physicalIDNum.unsignedIntValue;
            NSLog(@"DisplayDisabler: Display 0x%X disconnected, releasing virtual display.", did);
            [self unmirrorDisplay:did];
            [self.forceActiveTargets removeObjectForKey:physicalIDNum];
            [self.preForceModes      removeObjectForKey:physicalIDNum];
            [self.virtualDisplays    removeObjectForKey:physicalIDNum];
        }
    }
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
        if (token == self.coalesceToken && self.changeHandler) {
            self.changeHandler();
        }
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
