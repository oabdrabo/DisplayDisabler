/*
 * DisplayManager.m — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import "DisplayManager.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <math.h>

#define MAX_DISPLAYS 16

static NSString * const kDDErrorDomain = @"com.local.DisplayDisabler";

// ── Model implementations ───────────────────────────────────────────────────

@implementation DDDisplayInfo
@end

@implementation DDDisplayMode
@end

// ── DisplayManager ──────────────────────────────────────────────────────────

@interface DisplayManager () {
    @package
    DisplayChangeBlock _changeHandler;
    NSInteger _coalesceToken;
    BOOL _monitoring;
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
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
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

    for (uint32_t i = 0; i < onlineCount; i++) {
        CGDirectDisplayID did = online[i];
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

    for (uint32_t i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(displays[i])) return YES;
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
        if (error) *error = [NSError errorWithDomain:kDDErrorDomain code:err
                     userInfo:@{NSLocalizedDescriptionKey:
                     [NSString stringWithFormat:@"Failed to commit configuration (error %d)", err]}];
        return NO;
    }

    return YES;
}

// ── Monitoring ──────────────────────────────────────────────────────────────

- (void)startMonitoringWithChangeHandler:(DisplayChangeBlock)handler {
    if (_monitoring) [self stopMonitoring];
    _changeHandler = [handler copy];
    _monitoring = YES;
    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback,
                                              (__bridge void *)self);
}

- (void)stopMonitoring {
    if (!_monitoring) return;
    CGDisplayRemoveReconfigurationCallback(displayReconfigCallback,
                                            (__bridge void *)self);
    _changeHandler = nil;
    _monitoring = NO;
}

@end
