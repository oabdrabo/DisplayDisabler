/*
 * HiDPIInjector.m — writes a system-level Display override to expose custom
 * HiDPI modes natively. Reverse-engineered from xzhih/one-key-hidpi (MIT)
 * and BetterDisplay's "fully-scalable HiDPI" flow.
 *
 * scale-resolutions entry layout (9 bytes, from the one-key-hidpi
 * create_res_1 pattern that works on Apple Silicon macOS 13+):
 *     [0..3] pixel width  × 2 (big-endian uint32) — the HiDPI backing
 *     [4..7] pixel height × 2 (big-endian uint32)
 *     [8]    flag byte = 0x00
 * Apple's windowserver reads the array and materialises both a Standard
 * pixel mode at the given dimensions AND a HiDPI mode at half the logical
 * size, giving crisp 1:1 retina at any resolution the plist contains.
 */

#import "HiDPIInjector.h"
#import "DisplayManager.h"
#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#include <arpa/inet.h>  // htonl
#include <math.h>

// Logical scales applied to the panel's physical pixel grid to generate the
// curated install list. Mirrors the Force HiDPI synthetic scales so the two
// custom-size paths (virtual mirror vs plist override) cover the same logical
// real estate without a panel-agnostic constant list to drift.
static const double kInjectorScales[] = {0.625, 0.75, 0.875, 1.0, 1.125, 1.25, 1.5};
static const size_t kInjectorScaleCount =
    sizeof(kInjectorScales) / sizeof(*kInjectorScales);

NS_ASSUME_NONNULL_BEGIN

static NSErrorDomain const kInjectorErrorDomain = @"com.local.DisplayDisabler.HiDPIInjector";

static NSString *const kOverridesRoot =
    @"/Library/Displays/Contents/Resources/Overrides";

static NSError *injectorError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kInjectorErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation HiDPIInjector

+ (instancetype)shared {
    static HiDPIInjector *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[HiDPIInjector alloc] init]; });
    return instance;
}

- (NSArray<NSValue *> *)defaultResolutionsForDisplay:(CGDirectDisplayID)displayID {
    CGSize physical = [[DisplayManager shared] physicalPixelsForDisplay:displayID];
    if (physical.width <= 0 || physical.height <= 0) return @[];

    NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:kInjectorScaleCount];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (size_t i = 0; i < kInjectorScaleCount; i++) {
        // Even integers keep the resulting pixel-doubled HiDPI mode integer-clean.
        size_t lw = (size_t)round(physical.width  * kInjectorScales[i] / 2.0) * 2;
        size_t lh = (size_t)round(physical.height * kInjectorScales[i] / 2.0) * 2;
        if (lw == 0 || lh == 0) continue;
        NSString *key = [NSString stringWithFormat:@"%zu_%zu", lw, lh];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [out addObject:[NSValue valueWithSize:NSMakeSize(lw, lh)]];
    }
    return out;
}

// Windowserver matches the override plist by the display's "DisplayAttributes
// → ProductAttributes" IDs. On Apple Silicon the built-in panel reports a
// ProductID that is NOT the value returned by CGDisplayModelNumber (e.g. an
// ASCII Apple codename like 0x30313441 vs CG's 0xa052). For externals with
// EDID the two agree. So: prefer AppleCLCD2's values when available, fall
// back to the CG API for safety (headless/virtual displays).
- (void)productAttributesForDisplay:(CGDirectDisplayID)displayID
                             vendor:(uint32_t *)outVendor
                            product:(uint32_t *)outProduct {
    uint32_t cgVendor  = CGDisplayVendorNumber(displayID);
    uint32_t cgProduct = CGDisplayModelNumber(displayID);
    *outVendor  = cgVendor;
    *outProduct = cgProduct;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                      IOServiceMatching("AppleCLCD2"), &iter) != KERN_SUCCESS) {
        return;
    }
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
            CFDictionaryRef attrs = CFDictionaryGetValue(props, CFSTR("DisplayAttributes"));
            CFDictionaryRef prod  = attrs ? CFDictionaryGetValue(attrs, CFSTR("ProductAttributes")) : NULL;
            if (prod) {
                uint32_t vid = 0, pid = 0;
                CFNumberRef vn = CFDictionaryGetValue(prod, CFSTR("LegacyManufacturerID"));
                CFNumberRef pn = CFDictionaryGetValue(prod, CFSTR("ProductID"));
                if (vn) CFNumberGetValue(vn, kCFNumberSInt32Type, &vid);
                if (pn) CFNumberGetValue(pn, kCFNumberSInt32Type, &pid);
                // Match: for externals, ioreg VID/PID equals CG's. For the
                // built-in (CG vendor = 0x610 = Apple VESA), ioreg's vendor
                // matches but its product differs — use that pair.
                BOOL exactMatch = (vid == cgVendor && pid == cgProduct);
                BOOL builtinVendorMatch = CGDisplayIsBuiltin(displayID) &&
                                           vid == cgVendor;
                if (exactMatch || builtinVendorMatch) {
                    *outVendor  = vid;
                    *outProduct = pid;
                    CFRelease(props);
                    IOObjectRelease(svc);
                    break;
                }
            }
            CFRelease(props);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
}

// Build the path /Library/Displays/.../DisplayVendorID-XXX/DisplayProductID-XXX
// using IDs that actually match what windowserver looks up at runtime.
- (NSString *)overridePathForDisplay:(CGDirectDisplayID)displayID {
    uint32_t vendor = 0, product = 0;
    [self productAttributesForDisplay:displayID vendor:&vendor product:&product];
    return [NSString stringWithFormat:@"%@/DisplayVendorID-%x/DisplayProductID-%x",
            kOverridesRoot, vendor, product];
}

- (BOOL)isInstalledForDisplay:(CGDirectDisplayID)displayID {
    return [[NSFileManager defaultManager] fileExistsAtPath:
            [self overridePathForDisplay:displayID]];
}

// Encode one scale-resolutions entry: (w*2, h*2) big-endian + 1 zero flag byte.
- (NSString *)base64EntryForLogicalWidth:(NSUInteger)w height:(NSUInteger)h {
    uint8_t bytes[9] = {0};
    uint32_t W = htonl((uint32_t)(w * 2));
    uint32_t H = htonl((uint32_t)(h * 2));
    memcpy(bytes + 0, &W, 4);
    memcpy(bytes + 4, &H, 4);
    // bytes[8] = 0x00 already
    NSData *data = [NSData dataWithBytes:bytes length:sizeof bytes];
    return [data base64EncodedStringWithOptions:0];
}

- (NSString *)plistXMLForDisplay:(CGDirectDisplayID)displayID
                     resolutions:(NSArray<NSValue *> *)sizes {
    uint32_t vendor = 0, product = 0;
    [self productAttributesForDisplay:displayID vendor:&vendor product:&product];

    NSMutableString *entries = [NSMutableString string];
    for (NSValue *v in sizes) {
        NSSize s = v.sizeValue;
        NSString *b64 = [self base64EntryForLogicalWidth:(NSUInteger)s.width
                                                  height:(NSUInteger)s.height];
        [entries appendFormat:@"\t\t\t<data>%@</data>\n", b64];
    }

    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\">\n"
        @"<dict>\n"
        @"\t<key>DisplayProductID</key>\n"
        @"\t<integer>%u</integer>\n"
        @"\t<key>DisplayVendorID</key>\n"
        @"\t<integer>%u</integer>\n"
        @"\t<key>scale-resolutions</key>\n"
        @"\t<array>\n"
        @"%@"
        @"\t</array>\n"
        @"\t<key>target-default-ppmm</key>\n"
        @"\t<real>10.0699301</real>\n"
        @"</dict>\n"
        @"</plist>\n",
        product, vendor, entries];
}

// Escape a string for safe embedding in a single-quoted AppleScript literal.
// AppleScript single-quoted strings interpret nothing, but we're going through
// `do shell script`, which embeds the string literally into a bash heredoc —
// bash won't interpret anything inside <<'EOF' ... EOF either, so just protect
// against the terminator appearing in the content (it won't for our plist).
// We still escape double-quote and backslash for the AppleScript string.
static NSString *escapeForAppleScript(NSString *s) {
    NSString *out = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    out = [out stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return out;
}

- (void)runPrivilegedShell:(NSString *)script
                completion:(void (^)(BOOL ok, NSError * _Nullable err))completion {
    // NSAppleScript is not thread-safe — must execute on the main thread.
    // The auth prompt is modal anyway, so blocking the main run loop while
    // the user types their password is the expected behavior. Enforce the
    // thread invariant with a live runtime check (NSAssert would compile out
    // under -DNDEBUG; explicit early-return survives Release builds).
    if (![NSThread isMainThread]) {
        completion(NO, injectorError(-1,
            @"runPrivilegedShell must be called on the main thread."));
        return;
    }

    NSString *escaped = escapeForAppleScript(script);
    NSString *source = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges",
        escaped];
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

    // We send the plist content via a bash heredoc to avoid any quoting gymnastics.
    // The 'CRISP_EOF' terminator is unlikely to appear in any plist we generate.
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
        // Defence-in-depth: the script might have returned success but the
        // file could still be missing (e.g. silent mount issue). Verify.
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            completion(NO, injectorError(-1,
                @"Script ran but the override plist isn't on disk. "
                @"Check /var/log or the permissions under /Library/Displays."));
            return;
        }
        completion(YES, nil);
    }];
}

- (void)uninstallForDisplay:(CGDirectDisplayID)displayID
                 completion:(void (^)(BOOL ok, NSError * _Nullable err))completion {
    NSString *path = [self overridePathForDisplay:displayID];
    NSString *dir  = [path stringByDeletingLastPathComponent];

    // Only remove the per-display directory; leave other vendors alone and
    // leave DisplayResolutionEnabled in place (it's a no-op once overrides
    // are gone, and other tools might rely on it).
    NSString *script = [NSString stringWithFormat:
        @"/bin/rm -rf %@", dir];

    [self runPrivilegedShell:script completion:completion];
}

@end

NS_ASSUME_NONNULL_END
