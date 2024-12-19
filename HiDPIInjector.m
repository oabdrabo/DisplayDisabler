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
#import <AppKit/AppKit.h>
#include <arpa/inet.h>  // htonl

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

- (NSArray<NSValue *> *)defaultCustomResolutions {
    return @[
        [NSValue valueWithSize:NSMakeSize(1024,  640)],
        [NSValue valueWithSize:NSMakeSize(1280,  800)],
        [NSValue valueWithSize:NSMakeSize(1440,  900)],
        [NSValue valueWithSize:NSMakeSize(1600, 1000)],
        [NSValue valueWithSize:NSMakeSize(1680, 1050)],
        [NSValue valueWithSize:NSMakeSize(1920, 1080)],
        [NSValue valueWithSize:NSMakeSize(1920, 1200)],
        [NSValue valueWithSize:NSMakeSize(2048, 1280)],
        [NSValue valueWithSize:NSMakeSize(2560, 1440)],
        [NSValue valueWithSize:NSMakeSize(2560, 1600)],
    ];
}

// Build the path /Library/Displays/.../DisplayVendorID-XXX/DisplayProductID-XXX
// for the given displayID. Vendor and product are the IOKit values exposed via
// CGDisplayVendorNumber / CGDisplayModelNumber, formatted as lowercase hex.
- (NSString *)overridePathForDisplay:(CGDirectDisplayID)displayID {
    uint32_t vendor = CGDisplayVendorNumber(displayID);
    uint32_t product = CGDisplayModelNumber(displayID);
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
    uint32_t vendor  = CGDisplayVendorNumber(displayID);
    uint32_t product = CGDisplayModelNumber(displayID);

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
                completion:(void (^)(BOOL ok, NSError *err))completion {
    // `do shell script with administrator privileges` runs on current thread
    // and shows the standard auth prompt. Call from a background queue so we
    // don't block the main run loop.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *escaped = escapeForAppleScript(script);
        NSString *source = [NSString stringWithFormat:
            @"do shell script \"%@\" with administrator privileges",
            escaped];
        NSAppleScript *as = [[NSAppleScript alloc] initWithSource:source];
        NSDictionary *errDict = nil;
        NSAppleEventDescriptor *result = [as executeAndReturnError:&errDict];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) {
                completion(YES, nil);
            } else {
                NSString *msg = errDict[NSAppleScriptErrorMessage] ?: @"Shell script failed";
                NSInteger code = [errDict[NSAppleScriptErrorNumber] integerValue];
                // -128 is user-cancel — translate to a friendlier message.
                if (code == -128) msg = @"Authorization cancelled.";
                completion(NO, injectorError(code, msg));
            }
        });
    });
}

- (void)installForDisplay:(CGDirectDisplayID)displayID
              resolutions:(NSArray<NSValue *> *)sizes
               completion:(void (^)(BOOL ok, NSError *err))completion {
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

    [self runPrivilegedShell:script completion:completion];
}

- (void)uninstallForDisplay:(CGDirectDisplayID)displayID
                 completion:(void (^)(BOOL ok, NSError *err))completion {
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
