#import "HiDPIInjector.h"
#import "DisplayManager.h"
#import "DDUtil.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#include <arpa/inet.h>
#include <math.h>

static const double kInjectorFullPanelScales[] = { 0.625, 0.75, 0.875, 1.0, 1.125, 1.25, 1.5 };
static const size_t kInjectorFullPanelScaleCount =
    sizeof(kInjectorFullPanelScales) / sizeof(*kInjectorFullPanelScales);

NS_ASSUME_NONNULL_BEGIN

static NSErrorDomain const kInjectorErrorDomain = @"com.local.DisplayDisabler.HiDPIInjector";

static NSString *const kOverridesLibraryRoot =
    @"/Library/Displays/Contents/Resources/Overrides";
static NSString *const kOverridesSystemRoot =
    @"/System/Library/Displays/Contents/Resources/Overrides";

static NSData *entry8(NSUInteger logicalW, NSUInteger logicalH) {
    uint8_t bytes[8] = {0};
    uint32_t W = htonl((uint32_t)(logicalW * 2));
    uint32_t H = htonl((uint32_t)(logicalH * 2));
    memcpy(bytes + 0, &W, 4);
    memcpy(bytes + 4, &H, 4);
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}

@implementation HiDPIInjector

+ (instancetype)shared {
    static HiDPIInjector *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[HiDPIInjector alloc] init]; });
    return instance;
}

- (NSArray<NSValue *> *)defaultResolutionsForDisplay:(CGDirectDisplayID)displayID {
    CGSize panel = [[DisplayManager shared] nativePanelPixelsForDisplay:displayID];
    if (panel.width <= 0 || panel.height <= 0) return @[];

    NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:kInjectorFullPanelScaleCount];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (size_t i = 0; i < kInjectorFullPanelScaleCount; i++) {
        size_t lw = (size_t)round(panel.width  * kInjectorFullPanelScales[i] / 2.0) * 2;
        size_t lh = (size_t)round(panel.height * kInjectorFullPanelScales[i] / 2.0) * 2;
        if (lw == 0 || lh == 0) continue;
        NSString *key = [NSString stringWithFormat:@"%zu_%zu", lw, lh];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [out addObject:[NSValue valueWithSize:NSMakeSize(lw, lh)]];
    }
    return out;
}

- (void)productAttributesForDisplay:(CGDirectDisplayID)displayID
                             vendor:(uint32_t *)outVendor
                            product:(uint32_t *)outProduct {
    *outVendor  = CGDisplayVendorNumber(displayID);
    *outProduct = CGDisplayModelNumber(displayID);
}

- (NSString *)overridePathUnderRoot:(NSString *)root
                         forDisplay:(CGDirectDisplayID)displayID {
    uint32_t vendor = 0, product = 0;
    [self productAttributesForDisplay:displayID vendor:&vendor product:&product];
    return [NSString stringWithFormat:@"%@/DisplayVendorID-%x/DisplayProductID-%x",
            root, vendor, product];
}

- (NSString *)overridePathForDisplay:(CGDirectDisplayID)displayID {
    return [self overridePathUnderRoot:kOverridesLibraryRoot forDisplay:displayID];
}

- (NSString *)systemOverridePathForDisplay:(CGDirectDisplayID)displayID {
    return [self overridePathUnderRoot:kOverridesSystemRoot forDisplay:displayID];
}

- (BOOL)isInstalledForDisplay:(CGDirectDisplayID)displayID {
    return [[NSFileManager defaultManager] fileExistsAtPath:
            [self overridePathForDisplay:displayID]];
}

- (nullable NSDictionary *)loadSystemOverrideForDisplay:(CGDirectDisplayID)displayID {
    NSString *path = [self systemOverridePathForDisplay:displayID];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSError *e = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:&e];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    return obj;
}

- (NSDictionary *)mergedPlistDictForDisplay:(CGDirectDisplayID)displayID
                                resolutions:(NSArray<NSValue *> *)sizes {
    uint32_t vendor = 0, product = 0;
    [self productAttributesForDisplay:displayID vendor:&vendor product:&product];

    NSDictionary *apple = [self loadSystemOverrideForDisplay:displayID];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    if (apple) [out addEntriesFromDictionary:apple];

    out[@"DisplayVendorID"]  = @(vendor);
    out[@"DisplayProductID"] = @(product);

    NSMutableArray *entries = [NSMutableArray array];
    NSMutableSet<NSData *> *seen = [NSMutableSet set];
    NSArray *existing = apple[@"scale-resolutions"];
    if ([existing isKindOfClass:[NSArray class]]) {
        for (id e in existing) {
            if ([e isKindOfClass:[NSData class]] && ![seen containsObject:e]) {
                [entries addObject:e];
                [seen addObject:e];
            }
        }
    }
    for (NSValue *v in sizes) {
        NSSize s = v.sizeValue;
        NSData *d = entry8((NSUInteger)s.width, (NSUInteger)s.height);
        if (![seen containsObject:d]) {
            [entries addObject:d];
            [seen addObject:d];
        }
    }
    out[@"scale-resolutions"] = entries;

    return out;
}

- (NSString *)plistXMLForDisplay:(CGDirectDisplayID)displayID
                     resolutions:(NSArray<NSValue *> *)sizes {
    NSDictionary *merged = [self mergedPlistDictForDisplay:displayID
                                                resolutions:sizes];
    NSError *e = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:merged
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&e];
    if (!xml) return @"";
    return [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
}

- (void)runPrivilegedShell:(NSString *)script
                completion:(void (^)(BOOL ok, NSError * _Nullable err))completion {
    if (![NSThread isMainThread]) {
        completion(NO, DDError(kInjectorErrorDomain, -1,
            @"runPrivilegedShell must be called on the main thread."));
        return;
    }
    NSString *escaped = DDAppleScriptEscape(script);
    NSString *source = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", escaped];
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *errDict = nil;
    NSAppleEventDescriptor *result = [as executeAndReturnError:&errDict];
    if (result) {
        completion(YES, nil);
    } else {
        NSString *msg = errDict[NSAppleScriptErrorMessage] ?: @"Shell script failed";
        NSInteger code = [errDict[NSAppleScriptErrorNumber] integerValue];
        if (code == -128) msg = @"Authorization cancelled.";
        completion(NO, DDError(kInjectorErrorDomain, code, @"%@", msg));
    }
}

- (void)installForDisplay:(CGDirectDisplayID)displayID
              resolutions:(NSArray<NSValue *> *)sizes
               completion:(void (^)(BOOL ok, NSError * _Nullable err))completion {
    if (CGDisplayVendorNumber(displayID) == 0 || CGDisplayModelNumber(displayID) == 0) {
        completion(NO, DDError(kInjectorErrorDomain, -1,
            @"Display reports no vendor/product ID; cannot target an override plist."));
        return;
    }

    NSString *path = [self overridePathForDisplay:displayID];
    NSString *dir  = [path stringByDeletingLastPathComponent];
    NSString *xml  = [self plistXMLForDisplay:displayID resolutions:sizes];

    NSString *script = [NSString stringWithFormat:
        @"/bin/mkdir -p %@ && "
        @"/usr/bin/tee %@ > /dev/null <<'CRISP_EOF'\n"
        @"%@"
        @"CRISP_EOF\n"
        @"/usr/sbin/chown -R root:wheel %@ && "
        @"/bin/chmod -R 0644 %@ && "
        @"/bin/chmod 0755 %@ && "
        @"/usr/bin/defaults write /Library/Preferences/com.apple.windowserver "
        @"DisplayResolutionEnabled -bool YES",
        dir, path, xml, dir, path, dir];

    [self runPrivilegedShell:script completion:^(BOOL ok, NSError *err) {
        if (!ok) { completion(NO, err); return; }
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            completion(NO, DDError(kInjectorErrorDomain, -1,
                @"Script ran but the override plist isn't on disk. "
                @"Check permissions under /Library/Displays."));
            return;
        }
        completion(YES, nil);
    }];
}

- (void)uninstallForDisplay:(CGDirectDisplayID)displayID
                 completion:(void (^)(BOOL ok, NSError * _Nullable err))completion {
    NSString *path = [self overridePathForDisplay:displayID];
    NSString *dir  = [path stringByDeletingLastPathComponent];

    NSString *script = [NSString stringWithFormat:@"/bin/rm -rf %@", dir];
    [self runPrivilegedShell:script completion:completion];
}

@end

NS_ASSUME_NONNULL_END
