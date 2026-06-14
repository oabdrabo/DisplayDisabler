#import "DisplayManager.h"
#import "DDUtil.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <objc/runtime.h>
#include <math.h>
#include <os/log.h>

NSErrorDomain const DDErrorDomain = @"com.local.DisplayDisabler";

static const NSTimeInterval kDDCoalesceInterval = 0.5;

static const NSTimeInterval kDDVirtualOnlineTimeout = 15.0;

static const double kDDAspectTolerance = 0.005;

static const double kDDHiDPIScales[] = {0.5, 0.625, 0.75, 0.875, 1.0, 1.125, 1.25, 1.5, 1.75, 2.0};
static const size_t kDDHiDPIScaleCount = sizeof(kDDHiDPIScales) / sizeof(*kDDHiDPIScales);

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

extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display)
    CF_RETURNS_RETAINED;

static NSError *ddMakeCGError(CGError cgError, NSString *phase) {
    return DDError(DDErrorDomain, DDErrorCGConfigFailed,
                   @"%@ (CGError %d).", phase, cgError);
}

static CFArrayRef ddCopyAllModes(CGDirectDisplayID displayID) CF_RETURNS_RETAINED {
    NSDictionary *opts = @{
        (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
    };
    return CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
}

static CGSize ddCurrentPixelSize(CGDirectDisplayID displayID) {
    CGSize r = CGSizeZero;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(displayID);
    if (cur) {
        r.width  = CGDisplayModeGetPixelWidth(cur);
        r.height = CGDisplayModeGetPixelHeight(cur);
        CGDisplayModeRelease(cur);
    }
    return r;
}

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

typedef CGError (^DisplayConfigBlock)(CGDisplayConfigRef config);

@interface DisplayManager ()
@property (nonatomic, copy) DisplayChangeBlock changeHandler;
@property (nonatomic) NSInteger coalesceToken;
@property (nonatomic) BOOL monitoring;
@property (nonatomic, strong) id sharedVirtualDisplay;
@property (nonatomic) CGDirectDisplayID forcedPhysical;
@property (nonatomic, strong) DDDisplayMode *forcedTarget;
@property (nonatomic, strong) DDDisplayMode *preForceMode;
@property (nonatomic, strong) NSDictionary<NSNumber *, NSValue *> *preForceTopology;
@property (nonatomic) BOOL realignInFlight;
@property (nonatomic) BOOL applyingForce;
@property (nonatomic) BOOL vdTerminationDeferred;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, DDDisplayInfo *> *disabledInfos;
- (void)scheduleChangeNotification;
- (void)handleSharedVirtualDisplayTerminated;
- (void)clearForceState;
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
        _disabledInfos = [NSMutableDictionary dictionary];
        [self loadDisabledInfos];
    }
    return self;
}

static NSString *const kDisabledDisplaysKey = @"DDDisabledDisplays";

- (void)loadDisabledInfos {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults]
                           dictionaryForKey:kDisabledDisplaysKey];
    for (NSString *key in saved) {
        NSDictionary *d = saved[key];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        DDDisplayInfo *info = [[DDDisplayInfo alloc] init];
        info.displayID     = (CGDirectDisplayID)key.longLongValue;
        info.name          = d[@"name"] ?: @"Display";
        info.isBuiltIn     = [d[@"builtin"] boolValue];
        info.isActive      = NO;
        info.pixelWidth    = [d[@"pw"] unsignedLongValue];
        info.pixelHeight   = [d[@"ph"] unsignedLongValue];
        info.logicalWidth  = [d[@"lw"] unsignedLongValue];
        info.logicalHeight = [d[@"lh"] unsignedLongValue];
        info.refreshRate   = [d[@"hz"] doubleValue];
        info.isHiDPI       = [d[@"hidpi"] boolValue];
        self.disabledInfos[@(info.displayID)] = info;
    }
}

- (void)saveDisabledInfos {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSNumber *idNum in self.disabledInfos) {
        DDDisplayInfo *i = self.disabledInfos[idNum];
        out[idNum.stringValue] = @{
            @"name": i.name ?: @"Display", @"builtin": @(i.isBuiltIn),
            @"pw": @(i.pixelWidth), @"ph": @(i.pixelHeight),
            @"lw": @(i.logicalWidth), @"lh": @(i.logicalHeight),
            @"hz": @(i.refreshRate), @"hidpi": @(i.isHiDPI),
        };
    }
    [[NSUserDefaults standardUserDefaults] setObject:out forKey:kDisabledDisplaysKey];
}

+ (instancetype)shared {
    static DisplayManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DisplayManager alloc] init];
    });
    return instance;
}

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

- (BOOL)isVirtualDisplayID:(CGDirectDisplayID)displayID {
    SLVirtualDisplay *vd = self.sharedVirtualDisplay;
    return vd && vd.displayID == displayID;
}

- (void)clearForceState {
    self.forcedPhysical   = kCGNullDirectDisplay;
    self.forcedTarget     = nil;
    self.preForceMode     = nil;
    self.preForceTopology = nil;
}

- (void)handleSharedVirtualDisplayTerminated {
    if (!self.sharedVirtualDisplay) return;
    if (self.applyingForce) {
        self.vdTerminationDeferred = YES;
        return;
    }
    self.sharedVirtualDisplay = nil;
    [self clearForceState];
    NSLog(@"DisplayDisabler: Shared virtual display terminated externally.");
    [self scheduleChangeNotification];
}

- (void)unmirrorDisplay:(CGDirectDisplayID)displayID {
    NSError *error = nil;
    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
    } error:&error];
    if (!ok) {
        NSLog(@"DisplayDisabler: Warning: failed to unmirror 0x%X: %@", displayID, error);
    }
}

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

- (NSArray<DDDisplayInfo *> *)allDisplays {
    NSArray<NSNumber *> *online = ddQueryDisplayList(CGGetOnlineDisplayList);
    NSSet<NSNumber *> *onlineSet = [NSSet setWithArray:online];
    NSSet<NSNumber *> *activeSet = [NSSet setWithArray:ddQueryDisplayList(CGGetActiveDisplayList)];

    NSMutableArray<DDDisplayInfo *> *result = [NSMutableArray array];

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

    if (self.disabledInfos.count > 0) {
        NSMutableArray<NSNumber *> *reappeared = [NSMutableArray array];
        for (NSNumber *idNum in self.disabledInfos) {
            if ([onlineSet containsObject:idNum]) { [reappeared addObject:idNum]; continue; }
            [result addObject:self.disabledInfos[idNum]];
        }
        if (reappeared.count > 0) {
            [self.disabledInfos removeObjectsForKeys:reappeared];
            [self saveDisabledInfos];
        }
    }

    return result;
}

- (NSArray<DDDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)displayID {
    CFArrayRef allModes = ddCopyAllModes(displayID);
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
        m.isDefaultForDisplay = (flags & 0x04) != 0;
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

- (void)enumerateStandardModesForDisplay:(CGDirectDisplayID)displayID
                                   block:(void (^)(size_t pw, size_t ph))block {
    CFArrayRef allModes = ddCopyAllModes(displayID);
    if (!allModes) return;
    CFIndex n = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < n; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t pw = CGDisplayModeGetPixelWidth(m);
        size_t ph = CGDisplayModeGetPixelHeight(m);
        if (pw != CGDisplayModeGetWidth(m))  continue;
        if (ph != CGDisplayModeGetHeight(m)) continue;
        block(pw, ph);
    }
    CFRelease(allModes);
}

- (CGSize)nativePanelPixelsForDisplay:(CGDirectDisplayID)displayID {
    __block size_t maxW = 0, maxHAtMaxW = 0;
    [self enumerateStandardModesForDisplay:displayID block:^(size_t pw, size_t ph) {
        if (pw > maxW) { maxW = pw; maxHAtMaxW = ph; }
        else if (pw == maxW && ph > maxHAtMaxW) { maxHAtMaxW = ph; }
    }];
    if (maxW == 0 || maxHAtMaxW == 0) return ddCurrentPixelSize(displayID);
    return CGSizeMake(maxW, maxHAtMaxW);
}

- (CGSize)physicalPixelsForDisplay:(CGDirectDisplayID)displayID {
    NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *standardByWidth =
        [NSMutableDictionary dictionary];
    __block size_t maxStdW = 0;
    [self enumerateStandardModesForDisplay:displayID block:^(size_t pw, size_t ph) {
        NSMutableSet<NSNumber *> *heights = standardByWidth[@(pw)];
        if (!heights) {
            heights = [NSMutableSet set];
            standardByWidth[@(pw)] = heights;
        }
        [heights addObject:@(ph)];
        if (pw > maxStdW) maxStdW = pw;
    }];

    CGSize result = CGSizeZero;
    if (maxStdW > 0) {
        size_t h = SIZE_MAX;
        for (NSNumber *hh in standardByWidth[@(maxStdW)]) {
            size_t v = hh.unsignedLongValue;
            if (v < h) h = v;
        }
        result.width  = maxStdW;
        result.height = h;
    }
    if (result.width == 0 || result.height == 0) return ddCurrentPixelSize(displayID);
    return result;
}

- (BOOL)disableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    DDDisplayInfo *captured = nil;
    for (DDDisplayInfo *d in [self allDisplays]) {
        if (d.displayID == displayID) { captured = d; break; }
    }

    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGSConfigureDisplayEnabled(config, displayID, false);
    } error:error];

    if (ok) {
        if (!captured) {
            captured = [[DDDisplayInfo alloc] init];
            captured.displayID = displayID;
            captured.name = [self nameForDisplayID:displayID];
            captured.isBuiltIn = CGDisplayIsBuiltin(displayID);
        }
        captured.isActive = NO;
        self.disabledInfos[@(displayID)] = captured;
        [self saveDisabledInfos];
    }
    return ok;
}

- (BOOL)enableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGSConfigureDisplayEnabled(config, displayID, true);
    } error:error];
    if (ok) {
        [self.disabledInfos removeObjectForKey:@(displayID)];
        [self saveDisabledInfos];
    }
    return ok;
}

- (BOOL)setMode:(DDDisplayMode *)mode forDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    if (!mode.modeRef) {
        if (error) *error = DDError(DDErrorDomain, DDErrorInvalidMode, @"Invalid display mode.");
        return NO;
    }

    return [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayWithDisplayMode(config, displayID, mode.modeRef, NULL);
    } error:error];
}

- (CGDisplayModeRef)copyVirtualDisplayModeForVirtual:(CGDirectDisplayID)virtualID
                                         logicalWidth:(size_t)lw
                                        logicalHeight:(size_t)lh CF_RETURNS_RETAINED {
    CFArrayRef modes = ddCopyAllModes(virtualID);
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

- (BOOL)isDisplayIDOnline:(CGDirectDisplayID)vdID {
    return [ddQueryDisplayList(CGGetOnlineDisplayList) containsObject:@(vdID)];
}

- (BOOL)waitForVirtualDisplayOnline:(CGDirectDisplayID)vdID timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline compare:[NSDate date]] == NSOrderedDescending) {
        if ([self isDisplayIDOnline:vdID]) return YES;
        [[NSRunLoop mainRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return [self isDisplayIDOnline:vdID];
}

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
        if (error) *error = DDError(DDErrorDomain, DDErrorRequiresMacOS14,
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
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualApplyFailed,
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
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualApplyFailed,
            @"SLVirtualDisplaySettings init failed: %@", setErr.localizedDescription);
        return nil;
    }

    SLVirtualDisplay *vd = self.sharedVirtualDisplay;
    if (vd) {
        NSError *applyErr = nil;
        if (![vd applySettings:settings error:&applyErr]) {
            if (error) *error = DDError(DDErrorDomain, DDErrorVirtualApplyFailed,
                @"applySettings: failed: %@", applyErr.localizedDescription);
            return nil;
        }
        return vd;
    }

    if (sourceID == kCGNullDirectDisplay) {
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualCreateFailed,
            @"Cannot create shared virtual display without a source panel.");
        return nil;
    }
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(sourceID);
    if (!info) {
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualCreateFailed,
            @"CoreDisplay returned no info for source panel 0x%X.", sourceID);
        return nil;
    }
    SLVirtualDisplayConfiguration *config =
        [CfgC configurationWithDisplayInfo:(__bridge NSDictionary *)info];
    CFRelease(info);
    if (!config) {
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualCreateFailed,
            @"configurationWithDisplayInfo: returned nil for panel 0x%X.", sourceID);
        return nil;
    }

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
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualCreateFailed,
            @"SLVirtualDisplay init failed: %@", initErr.localizedDescription);
        return nil;
    }
    NSError *applyErr = nil;
    if (![vd applySettings:settings error:&applyErr]) {
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualApplyFailed,
            @"applySettings: failed on first create: %@", applyErr.localizedDescription);
        return nil;
    }
    if (vd.displayID == kCGNullDirectDisplay) {
        if (error) *error = DDError(DDErrorDomain, DDErrorVirtualNoDisplayID,
            @"SLVirtualDisplay has no valid displayID after apply.");
        return nil;
    }

    self.sharedVirtualDisplay = vd;
    return vd;
}

- (void)forceHiDPIForDisplay:(CGDirectDisplayID)displayID
                      atMode:(DDDisplayMode *)targetMode
                  completion:(DDForceHiDPICompletion)completion {
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
        deliver(NO, DDError(DDErrorDomain, DDErrorRequiresMacOS14,
                                @"Force HiDPI requires macOS 14 or later."));
        return;
    }
    if (self.forcedPhysical == displayID) {
        deliver(NO, DDError(DDErrorDomain, DDErrorAlreadyForced,
                                @"HiDPI is already being forced for this display."));
        return;
    }
    if (self.forcedPhysical != kCGNullDirectDisplay) {
        deliver(NO, DDError(DDErrorDomain, DDErrorAlreadyForced,
            @"Another display is already forced. Stop it first — this version "
            @"supports one forced display at a time (one CGVirtualDisplay per "
            @"process is an OS-level limit)."));
        return;
    }
    if (!CGDisplayIsActive(displayID)) {
        deliver(NO, DDError(DDErrorDomain, DDErrorNotForced,
                                @"Cannot force HiDPI on an inactive display."));
        return;
    }
    CGRect preForceBounds = CGDisplayBounds(displayID);

    NSMutableDictionary<NSNumber *, NSValue *> *topology = [NSMutableDictionary dictionary];
    for (NSNumber *didNum in ddQueryDisplayList(CGGetActiveDisplayList)) {
        CGDirectDisplayID did = didNum.unsignedIntValue;
        if ([self isVirtualDisplayID:did]) continue;
        CGRect b = CGDisplayBounds(did);
        topology[didNum] = [NSValue valueWithPoint:NSMakePoint(b.origin.x, b.origin.y)];
    }

    size_t targetLogicalWidth = 0, targetLogicalHeight = 0;
    if (targetMode) {
        targetLogicalWidth  = targetMode.logicalWidth;
        targetLogicalHeight = targetMode.logicalHeight;
    } else {
        CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
        if (!curMode) {
            deliver(NO, DDError(DDErrorDomain, DDErrorReadCurrentModeFailed,
                                    @"Could not read current display mode."));
            return;
        }
        targetLogicalWidth  = CGDisplayModeGetWidth(curMode);
        targetLogicalHeight = CGDisplayModeGetHeight(curMode);
        CGDisplayModeRelease(curMode);
    }

    DDDisplayMode *preForce = nil;
    for (DDDisplayMode *m in [self modesForDisplay:displayID]) {
        if (m.isCurrent) { preForce = m; break; }
    }

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

    if (![self waitForVirtualDisplayOnline:virtualID timeout:kDDVirtualOnlineTimeout]) {
        deliver(NO, DDError(DDErrorDomain, DDErrorVirtualCreateFailed,
                                @"Virtual display did not appear online."));
        return;
    }

    int32_t parkedX = (int32_t)(preForceBounds.origin.x + preForceBounds.size.width);
    int32_t parkedY = (int32_t)preForceBounds.origin.y;
    [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayOrigin(config, virtualID, parkedX, parkedY);
    } error:NULL];

    if (!CGDisplayIsActive(displayID)) {
        deliver(NO, DDError(DDErrorDomain, DDErrorNotForced,
                                @"Target display disconnected before the force could be applied."));
        return;
    }

    NSError *mirrorError = nil;
    BOOL mirrored = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayMirrorOfDisplay(config, displayID, virtualID);
    } error:&mirrorError];
    if (!mirrored) { deliver(NO, mirrorError); return; }

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
        deliver(NO, DDError(DDErrorDomain, DDErrorVirtualApplyFailed,
            @"Could not pin the virtual display to the requested logical size — "
            @"pointer coordinates would misalign. Force aborted."));
        return;
    }

    [self matchGammaFromDisplay:displayID toDisplay:virtualID];

    NSArray<NSNumber *> *online = ddQueryDisplayList(CGGetOnlineDisplayList);
    NSError *topoErr = nil;
    BOOL topoOk = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return [self layoutVirtual:virtualID atOrigin:preForceBounds.origin
                          physical:displayID online:online toConfig:config];
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

    double currentRate = 0;
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
    if (curMode) {
        currentRate = CGDisplayModeGetRefreshRate(curMode);
        CGDisplayModeRelease(curMode);
    }

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
        synth.refreshRate   = currentRate;
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

- (CGError)layoutVirtual:(CGDirectDisplayID)virtualID
                atOrigin:(CGPoint)origin
                physical:(CGDirectDisplayID)physical
                  online:(NSArray<NSNumber *> *)online
                toConfig:(CGDisplayConfigRef)config {
    CGError e = CGConfigureDisplayOrigin(config, virtualID,
                                         (int32_t)origin.x, (int32_t)origin.y);
    if (e != kCGErrorSuccess) return e;
    int32_t x = (int32_t)(origin.x + CGDisplayBounds(virtualID).size.width);
    int32_t y = (int32_t)origin.y;
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
}

- (CGError)teardownForcedDisplay:(CGDirectDisplayID)did
                    preForceMode:(DDDisplayMode *)pre
                        topology:(NSDictionary<NSNumber *, NSValue *> *)topology
                     restoreMode:(BOOL)restoreMode
                        toConfig:(CGDisplayConfigRef)config {
    CGError e = CGConfigureDisplayMirrorOfDisplay(config, did, kCGNullDirectDisplay);
    if (restoreMode) {
        if (e != kCGErrorSuccess) return e;
        if (pre && pre.modeRef) {
            e = CGConfigureDisplayWithDisplayMode(config, did, pre.modeRef, NULL);
            if (e != kCGErrorSuccess) return e;
        }
    }
    return [self restoreTopology:topology toConfig:config];
}

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
        if (error) *error = DDError(DDErrorDomain, DDErrorNotForced,
                                        @"HiDPI is not being forced for this display.");
        return NO;
    }

    DDDisplayMode *pre                                     = self.preForceMode;
    NSDictionary<NSNumber *, NSValue *> *topology          = self.preForceTopology;

    NSError *err = nil;
    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return [self teardownForcedDisplay:displayID preForceMode:pre topology:topology
                               restoreMode:YES toConfig:config];
    } error:&err];

    if (!ok) {
        NSLog(@"DisplayDisabler: Warning: stop transaction failed on 0x%X: %@",
              displayID, err);
    }

    [self clearForceState];

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
        [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
            return [self teardownForcedDisplay:did preForceMode:pre topology:topology
                                   restoreMode:YES toConfig:config];
        } error:NULL];

        [self clearForceState];
    }

    if (self.sharedVirtualDisplay) {
        SLVirtualDisplay *vd = self.sharedVirtualDisplay;
        self.sharedVirtualDisplay = nil;
        [vd destroy];
        NSLog(@"DisplayDisabler: Released shared virtual display.");
    }
}

- (void)realignForcedDisplay {
    if (self.forcedPhysical == kCGNullDirectDisplay) return;
    if (self.realignInFlight) return;
    CGDirectDisplayID physical = self.forcedPhysical;
    if (!CGDisplayIsActive(physical)) return;

    SLVirtualDisplay *vd = self.sharedVirtualDisplay;
    if (!vd) return;
    CGDirectDisplayID virtualID = vd.displayID;
    self.realignInFlight = YES;

    @try {
        BOOL mirrorOK = (CGDisplayMirrorsDisplay(physical) == virtualID);

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
            NSArray<NSNumber *> *online = ddQueryDisplayList(CGGetOnlineDisplayList);
            [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
                return [self layoutVirtual:virtualID atOrigin:physOrigin
                                  physical:physical online:online toConfig:config];
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

    [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return [self teardownForcedDisplay:did preForceMode:nil topology:topology
                               restoreMode:NO toConfig:config];
    } error:NULL];

    [self clearForceState];
}

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
    [self scheduleChangeNotification];
}

- (void)scheduleChangeNotification {
    NSInteger token = ++self.coalesceToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kDDCoalesceInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self.coalesceToken) return;
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
