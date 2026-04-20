/*
 * HiDPIInjector.m — writes a /Library-level Display override that adds custom
 * HiDPI modes to macOS's native mode list. Reverse-engineered against Apple's
 * own /System/Library/Displays/Contents/Resources/Overrides plists, which
 * remain the gold standard for correct format.
 *
 * scale-resolutions entry format (per Apple's M3 Air built-in override at
 * /System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/
 * DisplayProductID-a052):
 *
 *   8-byte entry — FULL-PANEL aspect, the standard HiDPI scaled mode:
 *     [0..3] pixel width  × 2  (big-endian uint32 — HiDPI backing)
 *     [4..7] pixel height × 2  (big-endian uint32)
 *
 *   12-byte entry — BELOW-NOTCH aspect, the "Scale to fit below built-in
 *   camera" variant on notched MacBooks:
 *     [0..3]  pixel width  × 2  (big-endian uint32)
 *     [4..7]  pixel height × 2  (big-endian uint32)
 *     [8..11] flag = 1          (big-endian uint32)
 *
 * An older "one-key-hidpi" format used 9 bytes with a single-byte 0x00 flag —
 * that format did NOT match Apple's actual file layout on macOS 26 and likely
 * produced silently-discarded entries.
 *
 * We ALSO preserve Apple's own scale-resolutions entries by reading the
 * /System plist (which macOS ships per-panel) and merging its entries into
 * our /Library override. Without this merge, installing our plist would
 * wipe all of Apple's curated scaled modes (e.g. the 3420×2224, 2940×1912,
 * 2048×1332 entries for the M3 Air), since /Library shadows /System at the
 * windowserver lookup layer.
 */

#import "HiDPIInjector.h"
#import "DisplayManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#include <arpa/inet.h>  // htonl
#include <math.h>

// HiDPI logical scales applied to the panel's FULL native pixel grid. Each
// produces a mode whose pixel backing is 2× the logical size (standard
// retina-style HiDPI). 1.0 = "looks like the panel's native pixel count"
// (supersampled Retina) — this is the mode Apple ships in System Settings'
// default list for the M3 Air as "Looks like 2560×1664 Retina" only when
// their own plist includes it. Our full-panel list adds it back if absent.
static const double kInjectorFullPanelScales[] = { 0.625, 0.75, 0.875, 1.0, 1.125, 1.25, 1.5 };
static const size_t kInjectorFullPanelScaleCount =
    sizeof(kInjectorFullPanelScales) / sizeof(*kInjectorFullPanelScales);

NS_ASSUME_NONNULL_BEGIN

static NSErrorDomain const kInjectorErrorDomain = @"com.local.DisplayDisabler.HiDPIInjector";

static NSString *const kOverridesLibraryRoot =
    @"/Library/Displays/Contents/Resources/Overrides";
static NSString *const kOverridesSystemRoot =
    @"/System/Library/Displays/Contents/Resources/Overrides";

static NSError *injectorError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kInjectorErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// ── Apple-format scale-resolutions entry encoders ───────────────────────────

// 8-byte entry: full-panel aspect HiDPI mode.
static NSData *entry8(NSUInteger logicalW, NSUInteger logicalH) {
    uint8_t bytes[8] = {0};
    uint32_t W = htonl((uint32_t)(logicalW * 2));
    uint32_t H = htonl((uint32_t)(logicalH * 2));
    memcpy(bytes + 0, &W, 4);
    memcpy(bytes + 4, &H, 4);
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}

// 12-byte entry: below-notch aspect variant (flag = 1).
__unused static NSData *entry12BelowNotch(NSUInteger logicalW, NSUInteger logicalH) {
    uint8_t bytes[12] = {0};
    uint32_t W = htonl((uint32_t)(logicalW * 2));
    uint32_t H = htonl((uint32_t)(logicalH * 2));
    uint32_t F = htonl((uint32_t)1);
    memcpy(bytes + 0,  &W, 4);
    memcpy(bytes + 4,  &H, 4);
    memcpy(bytes + 8,  &F, 4);
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}

@implementation HiDPIInjector

+ (instancetype)shared {
    static HiDPIInjector *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[HiDPIInjector alloc] init]; });
    return instance;
}

// Returns full-panel HiDPI logical sizes derived from the panel's NATIVE
// pixel grid (including the notch-side strip area on notched panels — the
// strip is menu-bar space in panel-native rendering, not dead). Deliberately
// uses nativePanelPixelsForDisplay: rather than the mirror-usable
// physicalPixelsForDisplay: because Crisp HiDPI runs through the OS's own
// rendering path that handles notch geometry correctly.
- (NSArray<NSValue *> *)defaultResolutionsForDisplay:(CGDirectDisplayID)displayID {
    CGSize panel = [[DisplayManager shared] nativePanelPixelsForDisplay:displayID];
    if (panel.width <= 0 || panel.height <= 0) return @[];

    NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:kInjectorFullPanelScaleCount];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (size_t i = 0; i < kInjectorFullPanelScaleCount; i++) {
        // Even-integer sizes keep the 2× pixel backing integer-clean.
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

// Windowserver looks up override plists by CoreGraphics' vendor/product IDs.
// Verified empirically against Apple's shipped overrides: e.g. the M3 Air
// built-in panel has CGDisplayModelNumber == 0xa052 and Apple ships
// /System/Library/Displays/…/DisplayVendorID-610/DisplayProductID-a052.
// Earlier versions of this code pulled ProductID from AppleCLCD2's
// DisplayAttributes.ProductAttributes dict and truncated a 64-bit ASCII
// panel codename (e.g. "014A\0"/0x3031344101) to SInt32 = 0x30313441,
// producing a garbage override path that never matched Apple's naming and
// made loadSystemOverrideForDisplay: silently fail. CG's values are the
// single source of truth.
- (void)productAttributesForDisplay:(CGDirectDisplayID)displayID
                             vendor:(uint32_t *)outVendor
                            product:(uint32_t *)outProduct {
    *outVendor  = CGDisplayVendorNumber(displayID);
    *outProduct = CGDisplayModelNumber(displayID);
}

// Build the /Library override path using the resolved vendor/product IDs.
- (NSString *)overridePathForDisplay:(CGDirectDisplayID)displayID {
    uint32_t vendor = 0, product = 0;
    [self productAttributesForDisplay:displayID vendor:&vendor product:&product];
    return [NSString stringWithFormat:@"%@/DisplayVendorID-%x/DisplayProductID-%x",
            kOverridesLibraryRoot, vendor, product];
}

// Parallel path under /System — Apple's factory-shipped override.
- (NSString *)systemOverridePathForDisplay:(CGDirectDisplayID)displayID {
    uint32_t vendor = 0, product = 0;
    [self productAttributesForDisplay:displayID vendor:&vendor product:&product];
    return [NSString stringWithFormat:@"%@/DisplayVendorID-%x/DisplayProductID-%x",
            kOverridesSystemRoot, vendor, product];
}

- (BOOL)isInstalledForDisplay:(CGDirectDisplayID)displayID {
    return [[NSFileManager defaultManager] fileExistsAtPath:
            [self overridePathForDisplay:displayID]];
}

// Load Apple's /System override plist for this panel if one exists. Returns
// nil for displays Apple doesn't ship an override for (most non-Apple
// externals). The returned dictionary is the starting point for our merge —
// we keep its DisplayProductName, IOGFlags, target-default-ppmm, and
// existing scale-resolutions entries intact, then append our own.
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

// Generate the full merged plist: Apple's /System fields (if any) + our own
// scale-resolutions entries appended. Returns a CFData-ready NSDictionary
// that we later serialize to XML for the shell-script heredoc.
- (NSDictionary *)mergedPlistDictForDisplay:(CGDirectDisplayID)displayID
                                resolutions:(NSArray<NSValue *> *)sizes {
    uint32_t vendor = 0, product = 0;
    [self productAttributesForDisplay:displayID vendor:&vendor product:&product];

    NSDictionary *apple = [self loadSystemOverrideForDisplay:displayID];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // Carry forward every key Apple set, so we shadow their plist without
    // losing fields the windowserver may depend on (IOGFlags, product name,
    // target-default-ppmm, display-product-string, icons, etc.).
    if (apple) [out addEntriesFromDictionary:apple];

    // Mandatory identifiers.
    out[@"DisplayVendorID"]  = @(vendor);
    out[@"DisplayProductID"] = @(product);

    // Existing scale-resolutions (Apple's curated entries) go first; our
    // appended entries come after. Dedup by the raw NSData value so a
    // size Apple already has doesn't get a duplicate entry from us.
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

// Escape a string for safe embedding in a double-quoted AppleScript literal.
static NSString *escapeForAppleScript(NSString *s) {
    NSString *out = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    out = [out stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return out;
}

- (void)runPrivilegedShell:(NSString *)script
                completion:(void (^)(BOOL ok, NSError * _Nullable err))completion {
    if (![NSThread isMainThread]) {
        completion(NO, injectorError(-1,
            @"runPrivilegedShell must be called on the main thread."));
        return;
    }
    NSString *escaped = escapeForAppleScript(script);
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
        completion(NO, injectorError(code, msg));
    }
}

- (void)installForDisplay:(CGDirectDisplayID)displayID
              resolutions:(NSArray<NSValue *> *)sizes
               completion:(void (^)(BOOL ok, NSError * _Nullable err))completion {
    if (CGDisplayVendorNumber(displayID) == 0 || CGDisplayModelNumber(displayID) == 0) {
        completion(NO, injectorError(-1,
            @"Display reports no vendor/product ID; cannot target an override plist."));
        return;
    }

    NSString *path = [self overridePathForDisplay:displayID];
    NSString *dir  = [path stringByDeletingLastPathComponent];
    NSString *xml  = [self plistXMLForDisplay:displayID resolutions:sizes];

    // Heredoc terminator that cannot collide with any XML content. Single-
    // quoted ('CRISP_EOF') prevents bash from interpolating anything inside.
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
            completion(NO, injectorError(-1,
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

    // Only remove the per-display directory; Apple's /System entry remains
    // in effect. DisplayResolutionEnabled stays flipped — it's a no-op once
    // our overrides are gone and other tools might rely on it.
    NSString *script = [NSString stringWithFormat:@"/bin/rm -rf %@", dir];
    [self runPrivilegedShell:script completion:completion];
}

@end

NS_ASSUME_NONNULL_END
