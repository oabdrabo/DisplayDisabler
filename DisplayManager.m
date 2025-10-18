/*
 * DisplayManager.m — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import "DisplayManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <math.h>

#define MAX_DISPLAYS 16

static NSString * const kDDErrorDomain = @"com.local.DisplayDisabler";

// ── Model implementations ───────────────────────────────────────────────────

@implementation DDDisplayInfo
@end

@implementation DDDisplayMode

- (void)setModeRef:(CGDisplayModeRef)modeRef {
    if (_modeRef != modeRef) {
        if (_modeRef) CGDisplayModeRelease(_modeRef);
        _modeRef = modeRef ? CGDisplayModeRetain(modeRef) : NULL;
    }
}

- (void)dealloc {
    if (_modeRef) CGDisplayModeRelease(_modeRef);
}

@end

// ── DisplayManager ──────────────────────────────────────────────────────────

@interface DisplayManager () {
    @package
    DisplayChangeBlock _changeHandler;
    NSInteger _coalesceToken;
    BOOL _monitoring;
    NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *_virtualDisplays;
}
@end

static void displayReconfigCallback(CGDirectDisplayID display,
                                     CGDisplayChangeSummaryFlags flags,
                                     void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    DisplayManager *mgr = (__bridge DisplayManager *)userInfo;
    // Dispatch everything to main queue for thread safety.
    // The 0.5s delay coalesces rapid-fire callbacks from a single event.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger token = ++mgr->_coalesceToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (token == mgr->_coalesceToken && mgr->_changeHandler) {
                mgr->_changeHandler();
            }
        });
    });
}

@implementation DisplayManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _virtualDisplays = [NSMutableDictionary dictionary];
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

// ── Display name via IOKit ──────────────────────────────────────────────────

- (NSString *)nameForDisplay:(CGDirectDisplayID)displayID {
    io_iterator_t iter;
    io_service_t serv;

    CFMutableDictionaryRef matching = IOServiceMatching("IODisplayConnect");
    if (!matching ||
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
        return CGDisplayIsBuiltin(displayID) ? @"Built-in Display" : @"External Display";
    }

    uint32_t targetVendor = CGDisplayVendorNumber(displayID);
    uint32_t targetModel  = CGDisplayModelNumber(displayID);

    NSString *result = nil;

    while ((serv = IOIteratorNext(iter)) != 0) {
        NSDictionary *info = (__bridge_transfer NSDictionary *)
            IODisplayCreateInfoDictionary(serv, kIODisplayOnlyPreferredName);
        IOObjectRelease(serv);

        if (!info) continue;

        NSNumber *vendorID  = info[@kDisplayVendorID];
        NSNumber *productID = info[@kDisplayProductID];

        if (vendorID && productID &&
            [vendorID unsignedIntValue] == targetVendor &&
            [productID unsignedIntValue] == targetModel) {

            NSDictionary *names = info[@kDisplayProductName];
            if (names.count > 0) result = names.allValues.firstObject;
            break;
        }
    }
    IOObjectRelease(iter);

    if (result) return result;
    return CGDisplayIsBuiltin(displayID) ? @"Built-in Display" : @"External Display";
}

// ── Query ───────────────────────────────────────────────────────────────────

- (NSString *)nameForDisplayID:(CGDirectDisplayID)displayID {
    return [self nameForDisplay:displayID];
}

- (NSArray<DDDisplayInfo *> *)allDisplays {
    uint32_t activeCount = 0, onlineCount = 0;
    CGDirectDisplayID active[MAX_DISPLAYS], online[MAX_DISPLAYS];

    if (CGGetActiveDisplayList(MAX_DISPLAYS, active, &activeCount) != kCGErrorSuccess)
        activeCount = 0;
    if (CGGetOnlineDisplayList(MAX_DISPLAYS, online, &onlineCount) != kCGErrorSuccess)
        return @[];

    NSMutableSet *activeSet = [NSMutableSet set];
    for (uint32_t i = 0; i < activeCount; i++)
        [activeSet addObject:@(active[i])];

    NSMutableArray<DDDisplayInfo *> *result = [NSMutableArray array];

    // Collect our virtual display IDs so we can skip them (snapshot for safety)
    NSMutableSet *virtualIDs = [NSMutableSet set];
    for (NSNumber *key in [_virtualDisplays allKeys]) {
        CGVirtualDisplay *vd = _virtualDisplays[key];
        if (vd && [vd respondsToSelector:@selector(displayID)])
            [virtualIDs addObject:@(vd.displayID)];
    }

    for (uint32_t i = 0; i < onlineCount; i++) {
        CGDirectDisplayID did = online[i];

        // Skip our own virtual displays
        if ([virtualIDs containsObject:@(did)]) continue;

        DDDisplayInfo *info = [[DDDisplayInfo alloc] init];

        info.displayID = did;
        info.name      = [self nameForDisplay:did];
        info.isBuiltIn = CGDisplayIsBuiltin(did);
        info.isActive  = [activeSet containsObject:@(did)];
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

            CGSize mm = CGDisplayScreenSize(did);
            info.physicalSizeMM = NSMakeSize(mm.width, mm.height);
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

    // Current mode for marking
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
    size_t curPW = 0, curPH = 0, curLW = 0, curLH = 0;
    double curRate = 0;
    if (curMode) {
        curPW   = CGDisplayModeGetPixelWidth(curMode);
        curPH   = CGDisplayModeGetPixelHeight(curMode);
        curLW   = CGDisplayModeGetWidth(curMode);
        curLH   = CGDisplayModeGetHeight(curMode);
        curRate = CGDisplayModeGetRefreshRate(curMode);
        CGDisplayModeRelease(curMode);
    }

    NSMutableArray<DDDisplayMode *> *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);

        size_t lw = CGDisplayModeGetWidth(mode);
        size_t lh = CGDisplayModeGetHeight(mode);
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t ph = CGDisplayModeGetPixelHeight(mode);
        double hz = CGDisplayModeGetRefreshRate(mode);
        BOOL hidpi = (pw > lw);

        NSString *key = [NSString stringWithFormat:@"%zu_%zu_%zu_%zu_%.0f", pw, ph, lw, lh, hz];
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
                           fabs(hz - curRate) < 1.0);

        [result addObject:m];
    }
    CFRelease(allModes);

    // Sort: pixel width desc → pixel height desc → HiDPI first → refresh desc
    [result sortUsingComparator:^NSComparisonResult(DDDisplayMode *a, DDDisplayMode *b) {
        NSComparisonResult r;
        r = [@(b.pixelWidth) compare:@(a.pixelWidth)];
        if (r != NSOrderedSame) return r;
        r = [@(b.pixelHeight) compare:@(a.pixelHeight)];
        if (r != NSOrderedSame) return r;
        r = [@(b.isHiDPI) compare:@(a.isHiDPI)];
        if (r != NSOrderedSame) return r;
        return [@(b.refreshRate) compare:@(a.refreshRate)];
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
    uint32_t count = 0;
    CGDirectDisplayID displays[MAX_DISPLAYS];
    if (CGGetOnlineDisplayList(MAX_DISPLAYS, displays, &count) != kCGErrorSuccess)
        return NO;

    // Collect our virtual display IDs to exclude them
    NSMutableSet *virtualIDs = [NSMutableSet set];
    for (NSNumber *key in [_virtualDisplays allKeys]) {
        CGVirtualDisplay *vd = _virtualDisplays[key];
        if (vd && [vd respondsToSelector:@selector(displayID)])
            [virtualIDs addObject:@(vd.displayID)];
    }

    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i])) continue;
        if ([virtualIDs containsObject:@(displays[i])]) continue;
        return YES;
    }
    return NO;
}

// ── Actions ─────────────────────────────────────────────────────────────────

- (BOOL)disableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    CGDisplayConfigRef config;
    CGError err;

    err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to begin configuration (error %d)", err]}];
        return NO;
    }

    err = CGSConfigureDisplayEnabled(config, displayID, false);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to disable display (error %d)", err]}];
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to commit configuration (error %d)", err]}];
        return NO;
    }

    return YES;
}

- (BOOL)enableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    CGDisplayConfigRef config;
    CGError err;

    err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to begin configuration (error %d)", err]}];
        return NO;
    }

    err = CGSConfigureDisplayEnabled(config, displayID, true);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to enable display (error %d)", err]}];
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to commit configuration (error %d)", err]}];
        return NO;
    }

    return YES;
}

- (BOOL)setMode:(DDDisplayMode *)mode forDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    if (!mode.modeRef) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid display mode"}];
        return NO;
    }

    CGError err = CGDisplaySetDisplayMode(displayID, mode.modeRef, NULL);
    if (err != kCGErrorSuccess) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to set display mode (error %d)", err]}];
        return NO;
    }

    return YES;
}

// ── HiDPI forcing via CGVirtualDisplay ───────────────────────────────────────

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

- (BOOL)forceHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    // Runtime check — CGVirtualDisplay requires macOS 14+
    Class vdClass       = NSClassFromString(@"CGVirtualDisplay");
    Class descClass     = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass     = NSClassFromString(@"CGVirtualDisplayMode");

    if (!vdClass || !descClass || !settingsClass || !modeClass) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey:
                     @"Force HiDPI requires macOS 14 or later."}];
        return NO;
    }

    if (_virtualDisplays[@(displayID)]) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey:
                     @"HiDPI is already being forced for this display."}];
        return NO;
    }

    // Get current pixel resolution
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
    if (!curMode) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey:
                     @"Could not read current display mode."}];
        return NO;
    }

    size_t pixelWidth  = CGDisplayModeGetPixelWidth(curMode);
    size_t pixelHeight = CGDisplayModeGetPixelHeight(curMode);
    CGDisplayModeRelease(curMode);

    // Physical size for descriptor
    CGSize mm = CGDisplayScreenSize(displayID);
    if (mm.width <= 0 || mm.height <= 0)
        mm = CGSizeMake(600, 340);  // fallback ~27" 16:9

    // Configure descriptor
    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.name = [NSString stringWithFormat:@"DD-HiDPI-%X", displayID];
    desc.maxPixelsWide = pixelWidth;
    desc.maxPixelsHigh = pixelHeight;
    desc.sizeInMillimeters = mm;
    desc.queue = dispatch_get_main_queue();
    desc.vendorID  = 0xDD;
    desc.productID = 0x01;
    desc.serialNum = displayID;

    // sRGB color primaries
    desc.redPrimary   = CGPointMake(0.6400, 0.3300);
    desc.greenPrimary = CGPointMake(0.3000, 0.6000);
    desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
    desc.whitePoint   = CGPointMake(0.3127, 0.3290);

    // Create virtual display
    CGVirtualDisplay *vd = [[vdClass alloc] initWithDescriptor:desc];
    if (!vd) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey:
                     @"Failed to create virtual display."}];
        return NO;
    }

    // Apply HiDPI settings with one mode at native resolution
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 1;
    CGVirtualDisplayMode *vdMode = [[modeClass alloc]
        initWithWidth:pixelWidth height:pixelHeight refreshRate:60.0];
    settings.modes = @[vdMode];

    if (![vd applySettings:settings]) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey:
                     @"Failed to apply HiDPI settings to virtual display."}];
        return NO;
    }

    // Mirror the physical display to the virtual display
    CGDirectDisplayID virtualID = vd.displayID;

    if (virtualID == kCGNullDirectDisplay) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey:
                     @"Virtual display has no valid ID."}];
        return NO;
    }

    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to begin configuration (error %d)", err]}];
        return NO;
    }

    err = CGConfigureDisplayMirrorOfDisplay(config, displayID, virtualID);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to configure mirroring (error %d)", err]}];
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to commit mirroring (error %d)", err]}];
        return NO;
    }

    _virtualDisplays[@(displayID)] = vd;
    NSLog(@"DisplayDisabler: Forced HiDPI for display 0x%X via virtual display 0x%X",
          displayID, virtualID);
    return YES;
}

- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    CGVirtualDisplay *vd = _virtualDisplays[@(displayID)];
    if (!vd) {
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:-1
                     userInfo:@{NSLocalizedDescriptionKey:
                     @"HiDPI is not being forced for this display."}];
        return NO;
    }

    // Stop mirroring (pass 0 as master)
    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err == kCGErrorSuccess) {
        CGConfigureDisplayMirrorOfDisplay(config, displayID, 0);
        CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    }

    // Release destroys the virtual display
    [_virtualDisplays removeObjectForKey:@(displayID)];
    NSLog(@"DisplayDisabler: Stopped forced HiDPI for display 0x%X", displayID);
    return YES;
}

- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID {
    return _virtualDisplays[@(displayID)] != nil;
}

- (void)cleanUpAllVirtualDisplays {
    if (_virtualDisplays.count == 0) return;

    for (NSNumber *displayIDNum in [_virtualDisplays allKeys]) {
        CGDirectDisplayID did = [displayIDNum unsignedIntValue];
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(config, did, 0);
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
    }
    [_virtualDisplays removeAllObjects];
    NSLog(@"DisplayDisabler: Cleaned up all virtual displays.");
}

- (void)pruneStaleVirtualDisplays {
    if (_virtualDisplays.count == 0) return;

    uint32_t onlineCount = 0;
    CGDirectDisplayID online[MAX_DISPLAYS];
    if (CGGetOnlineDisplayList(MAX_DISPLAYS, online, &onlineCount) != kCGErrorSuccess)
        return;  // can't determine what's online; don't prune

    NSMutableSet *onlineSet = [NSMutableSet set];
    for (uint32_t i = 0; i < onlineCount; i++)
        [onlineSet addObject:@(online[i])];

    for (NSNumber *displayIDNum in [_virtualDisplays allKeys]) {
        if (![onlineSet containsObject:displayIDNum]) {
            NSLog(@"DisplayDisabler: Display 0x%X disconnected, removing virtual display.",
                  [displayIDNum unsignedIntValue]);
            [_virtualDisplays removeObjectForKey:displayIDNum];
        }
    }
}

// ── Monitoring ──────────────────────────────────────────────────────────────

- (void)startMonitoringWithChangeHandler:(DisplayChangeBlock)handler {
    if (_monitoring) [self stopMonitoring];
    _changeHandler = [handler copy];
    _monitoring = YES;

    // CG callback — may not fire on macOS Tahoe (26+)
    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback,
                                              (__bridge void *)self);

    // NSNotification fallback — works on all macOS versions including Tahoe
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(screenParametersChanged:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:nil];
}

- (void)screenParametersChanged:(NSNotification *)notification {
    // Same coalescing logic as displayReconfigCallback
    NSInteger token = ++_coalesceToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token == self->_coalesceToken && self->_changeHandler) {
            self->_changeHandler();
        }
    });
}

- (void)stopMonitoring {
    if (!_monitoring) return;
    CGDisplayRemoveReconfigurationCallback(displayReconfigCallback,
                                            (__bridge void *)self);
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    _changeHandler = nil;
    _monitoring = NO;
}

@end
