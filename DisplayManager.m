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

// ── Error helper ────────────────────────────────────────────────────────────

static NSError *ddError(NSInteger code, NSString *format, ...) NS_FORMAT_FUNCTION(2,3);
static NSError *ddError(NSInteger code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:kDDErrorDomain code:code
                 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

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

typedef CGError (^DisplayConfigBlock)(CGDisplayConfigRef config);

@interface DisplayManager ()
@property (nonatomic, copy) DisplayChangeBlock changeHandler;
@property (nonatomic) NSInteger coalesceToken;
@property (nonatomic) BOOL monitoring;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *virtualDisplays;
- (void)scheduleChangeNotification;
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

// ── Display configuration transaction ───────────────────────────────────────
// Wraps begin/action/complete with proper cancel-on-failure handling.

- (BOOL)performDisplayConfig:(DisplayConfigBlock)block error:(NSError **)error {
    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        if (error) *error = ddError(err, @"Failed to begin display configuration (error %d)", err);
        return NO;
    }

    err = block(config);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = ddError(err, @"Display configuration step failed (error %d)", err);
        return NO;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        if (error) *error = ddError(err, @"Failed to commit display configuration (error %d)", err);
        return NO;
    }

    return YES;
}

// ── Virtual display ID set ──────────────────────────────────────────────────
// Snapshot of display IDs owned by our virtual displays, for filtering.

- (NSSet<NSNumber *> *)virtualDisplayIDSet {
    NSMutableSet *ids = [NSMutableSet setWithCapacity:self.virtualDisplays.count];
    for (NSNumber *key in self.virtualDisplays) {
        CGVirtualDisplay *vd = self.virtualDisplays[key];
        if (vd) [ids addObject:@(vd.displayID)];
    }
    return ids;
}

// ── Unmirror helper ─────────────────────────────────────────────────────────

- (void)unmirrorDisplay:(CGDirectDisplayID)displayID {
    NSError *error = nil;
    BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
        return CGConfigureDisplayMirrorOfDisplay(config, displayID, 0);
    } error:&error];
    if (!ok) {
        NSLog(@"DisplayDisabler: Warning: failed to unmirror 0x%X: %@", displayID, error);
    }
}

// ── Display name via IOKit ──────────────────────────────────────────────────

- (NSString *)nameForDisplayID:(CGDirectDisplayID)displayID {
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

    NSSet *virtualIDs = [self virtualDisplayIDSet];
    NSMutableArray<DDDisplayInfo *> *result = [NSMutableArray array];

    for (uint32_t i = 0; i < onlineCount; i++) {
        CGDirectDisplayID did = online[i];
        if ([virtualIDs containsObject:@(did)]) continue;

        DDDisplayInfo *info = [[DDDisplayInfo alloc] init];

        info.displayID = did;
        info.name      = [self nameForDisplayID:did];
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

    [result sortUsingComparator:^NSComparisonResult(DDDisplayMode *a, DDDisplayMode *b) {
        NSComparisonResult r;
        r = [@(b.pixelWidth) compare:@(a.pixelWidth)];   if (r != NSOrderedSame) return r;
        r = [@(b.pixelHeight) compare:@(a.pixelHeight)]; if (r != NSOrderedSame) return r;
        r = [@(b.isHiDPI) compare:@(a.isHiDPI)];         if (r != NSOrderedSame) return r;
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

    NSSet *virtualIDs = [self virtualDisplayIDSet];

    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i])) continue;
        if ([virtualIDs containsObject:@(displays[i])]) continue;
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
        if (error) *error = ddError(-1, @"Invalid display mode");
        return NO;
    }

    CGError err = CGDisplaySetDisplayMode(displayID, mode.modeRef, NULL);
    if (err != kCGErrorSuccess) {
        if (error) *error = ddError(err, @"Failed to set display mode (error %d)", err);
        return NO;
    }

    return YES;
}

// ── HiDPI ────────────────────────────────────────────────────────────────────

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
        if (error) *error = ddError(-1, @"Could not read display modes.");
        return NO;
    }

    CGDisplayModeRef bestMode = NULL;
    size_t bestArea = 0;

    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t lw = CGDisplayModeGetWidth(mode);
        size_t lh = CGDisplayModeGetHeight(mode);
        if (pw <= lw) continue;
        size_t area = lw * lh;
        if (area > bestArea) {
            bestArea = area;
            bestMode = mode;
        }
    }

    if (!bestMode) {
        CFRelease(allModes);
        if (error) *error = ddError(-1, @"No HiDPI modes available.");
        return NO;
    }

    CGError err = CGDisplaySetDisplayMode(displayID, bestMode, NULL);
    CFRelease(allModes);

    if (err != kCGErrorSuccess) {
        if (error) *error = ddError(err, @"Failed to set HiDPI mode (error %d)", err);
        return NO;
    }
    return YES;
}

// ── Force HiDPI via CGVirtualDisplay ────────────────────────────────────────

- (void)forceHiDPIForDisplay:(CGDirectDisplayID)displayID
                  completion:(void (^)(BOOL success, NSError *error))completion {
    // Runtime check — CGVirtualDisplay requires macOS 14+
    Class vdClass       = NSClassFromString(@"CGVirtualDisplay");
    Class descClass     = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass     = NSClassFromString(@"CGVirtualDisplayMode");

    if (!vdClass || !descClass || !settingsClass || !modeClass) {
        if (completion) completion(NO, ddError(-1, @"Force HiDPI requires macOS 14 or later."));
        return;
    }

    if (self.virtualDisplays[@(displayID)]) {
        if (completion) completion(NO, ddError(-1, @"HiDPI is already being forced for this display."));
        return;
    }

    // Get current pixel resolution
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(displayID);
    if (!curMode) {
        if (completion) completion(NO, ddError(-1, @"Could not read current display mode."));
        return;
    }

    size_t pixelWidth  = CGDisplayModeGetPixelWidth(curMode);
    size_t pixelHeight = CGDisplayModeGetPixelHeight(curMode);
    CGDisplayModeRelease(curMode);

    // Virtual display at 2x so HiDPI logical resolution matches native pixels
    size_t vdPixelWidth  = pixelWidth * 2;
    size_t vdPixelHeight = pixelHeight * 2;

    CGSize mm = CGDisplayScreenSize(displayID);
    if (mm.width <= 0 || mm.height <= 0)
        mm = CGSizeMake(600, 340);  // fallback ~27" 16:9

    // Build virtual display
    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.name = [NSString stringWithFormat:@"DD-HiDPI-%X", displayID];
    desc.maxPixelsWide = vdPixelWidth;
    desc.maxPixelsHigh = vdPixelHeight;
    desc.sizeInMillimeters = mm;
    desc.queue = dispatch_get_main_queue();
    desc.vendorID  = 0xDD;
    desc.productID = 0x01;
    desc.serialNum = displayID;
    desc.redPrimary   = CGPointMake(0.6400, 0.3300);
    desc.greenPrimary = CGPointMake(0.3000, 0.6000);
    desc.bluePrimary  = CGPointMake(0.1500, 0.0600);
    desc.whitePoint   = CGPointMake(0.3127, 0.3290);

    CGVirtualDisplay *vd = [[vdClass alloc] initWithDescriptor:desc];
    if (!vd) {
        if (completion) completion(NO, ddError(-1, @"Failed to create virtual display."));
        return;
    }

    // Apply HiDPI settings: native LoDPI mode + HiDPI target mode
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[
        [[modeClass alloc] initWithWidth:vdPixelWidth height:vdPixelHeight refreshRate:60.0],
        [[modeClass alloc] initWithWidth:pixelWidth height:pixelHeight refreshRate:60.0],
    ];

    if (![vd applySettings:settings]) {
        if (completion) completion(NO, ddError(-1, @"Failed to apply HiDPI settings to virtual display."));
        return;
    }

    // Retain the virtual display
    self.virtualDisplays[@(displayID)] = vd;
    CGDirectDisplayID virtualID = vd.displayID;

    if (virtualID == kCGNullDirectDisplay) {
        [self.virtualDisplays removeObjectForKey:@(displayID)];
        if (completion) completion(NO, ddError(-1, @"Virtual display has no valid ID."));
        return;
    }

    // Defer mirroring so macOS registers the new virtual display.
    // Without this delay, CGCompleteDisplayConfiguration fails with
    // error 1001 on macOS 15+.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSError *mirrorError = nil;
        BOOL ok = [self performDisplayConfig:^CGError(CGDisplayConfigRef config) {
            return CGConfigureDisplayMirrorOfDisplay(config, displayID, virtualID);
        } error:&mirrorError];

        if (!ok) {
            [self.virtualDisplays removeObjectForKey:@(displayID)];
            if (completion) completion(NO, mirrorError);
            return;
        }

        NSLog(@"DisplayDisabler: Forced HiDPI for display 0x%X via virtual display 0x%X",
              displayID, virtualID);
        if (completion) completion(YES, nil);
    });
}

- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error {
    if (!self.virtualDisplays[@(displayID)]) {
        if (error) *error = ddError(-1, @"HiDPI is not being forced for this display.");
        return NO;
    }

    [self unmirrorDisplay:displayID];
    [self.virtualDisplays removeObjectForKey:@(displayID)];
    NSLog(@"DisplayDisabler: Stopped forced HiDPI for display 0x%X", displayID);
    return YES;
}

- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID {
    return self.virtualDisplays[@(displayID)] != nil;
}

- (void)cleanUpAllVirtualDisplays {
    if (self.virtualDisplays.count == 0) return;

    for (NSNumber *displayIDNum in [self.virtualDisplays allKeys]) {
        [self unmirrorDisplay:[displayIDNum unsignedIntValue]];
    }
    [self.virtualDisplays removeAllObjects];
    NSLog(@"DisplayDisabler: Cleaned up all virtual displays.");
}

- (void)pruneStaleVirtualDisplays {
    if (self.virtualDisplays.count == 0) return;

    uint32_t onlineCount = 0;
    CGDirectDisplayID online[MAX_DISPLAYS];
    if (CGGetOnlineDisplayList(MAX_DISPLAYS, online, &onlineCount) != kCGErrorSuccess)
        return;

    NSMutableSet *onlineSet = [NSMutableSet set];
    for (uint32_t i = 0; i < onlineCount; i++)
        [onlineSet addObject:@(online[i])];

    for (NSNumber *displayIDNum in [self.virtualDisplays allKeys]) {
        if (![onlineSet containsObject:displayIDNum]) {
            CGDirectDisplayID did = [displayIDNum unsignedIntValue];
            NSLog(@"DisplayDisabler: Display 0x%X disconnected, removing virtual display.", did);
            [self unmirrorDisplay:did];
            [self.virtualDisplays removeObjectForKey:displayIDNum];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scheduleChangeNotification];
    });
}

- (void)scheduleChangeNotification {
    NSInteger token = ++self.coalesceToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
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
