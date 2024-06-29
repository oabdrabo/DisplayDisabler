/*
 * DisplayDisabler v2.0 — Lightweight display management for Apple Silicon
 * Reverse-engineered from BetterDisplay behavior
 *
 * Compilation:
 *   clang -fobjc-arc -framework CoreGraphics -framework Foundation -framework IOKit \
 *         display_disable.m -o display_disable
 *
 * Usage:
 *   ./display_disable list              # List all displays with details
 *   ./display_disable modes <ID>        # Show all available resolutions (incl. HiDPI)
 *   ./display_disable disable <ID>      # Disable specific display
 *   ./display_disable disable-builtin   # Auto-disable built-in display
 *   ./display_disable enable <ID>       # Re-enable display
 *   ./display_disable status            # Quick status overview
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <math.h>

#define VERSION "2.0.0"
#define APP_NAME "DisplayDisabler"
#define MAX_DISPLAYS 16

// Private API declaration (not in public headers)
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

// ── ANSI formatting ─────────────────────────────────────────────────────────

#define B   "\033[1m"       // bold
#define D   "\033[2m"       // dim
#define R   "\033[0m"       // reset
#define FG  "\033[32m"      // green
#define FY  "\033[33m"      // yellow
#define FB  "\033[34m"      // blue
#define FC  "\033[36m"      // cyan
#define FR  "\033[31m"      // red

// ── Display name via IOKit ──────────────────────────────────────────────────

static NSString *getDisplayName(CGDirectDisplayID displayID) {
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

// ── Parse display ID (hex or decimal) ───────────────────────────────────────

static CGDirectDisplayID parseDisplayID(const char *str) {
    if (strncmp(str, "0x", 2) == 0 || strncmp(str, "0X", 2) == 0) {
        return (CGDirectDisplayID)strtoul(str, NULL, 16);
    }
    return (CGDirectDisplayID)strtoul(str, NULL, 10);
}

// ── List all modes for a display (including HiDPI) ──────────────────────────

static void listModes(CGDirectDisplayID displayID) {
    // Request all modes including HiDPI variants
    NSDictionary *opts = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
    if (!allModes) {
        printf("  No modes available for this display.\n");
        return;
    }

    // Current mode for comparison
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

    // Collect unique modes
    NSMutableArray *modes = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    CFIndex count = CFArrayGetCount(allModes);
    for (CFIndex i = 0; i < count; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);

        size_t lw = CGDisplayModeGetWidth(mode);
        size_t lh = CGDisplayModeGetHeight(mode);
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t ph = CGDisplayModeGetPixelHeight(mode);
        double hz = CGDisplayModeGetRefreshRate(mode);
        BOOL   hidpi = (pw > lw);

        NSString *key = [NSString stringWithFormat:@"%zu_%zu_%zu_%zu_%.0f", pw, ph, lw, lh, hz];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];

        BOOL current = (pw == curPW && ph == curPH &&
                        lw == curLW && lh == curLH && fabs(hz - curRate) < 1.0);

        [modes addObject:@{
            @"pw": @(pw), @"ph": @(ph),
            @"lw": @(lw), @"lh": @(lh),
            @"hz": @(hz), @"hidpi": @(hidpi),
            @"cur": @(current)
        }];
    }
    CFRelease(allModes);

    // Sort: pixel width desc → pixel height desc → HiDPI first → refresh desc
    [modes sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r;
        r = [b[@"pw"] compare:a[@"pw"]]; if (r != NSOrderedSame) return r;
        r = [b[@"ph"] compare:a[@"ph"]]; if (r != NSOrderedSame) return r;
        r = [b[@"hidpi"] compare:a[@"hidpi"]]; if (r != NSOrderedSame) return r;
        return [b[@"hz"] compare:a[@"hz"]];
    }];

    // Table header
    printf("  " B "%-16s  %-16s  %-6s  %-6s" R "\n",
           "Pixels", "Looks Like", "Scale", "Rate");
    printf("  ────────────────  ────────────────  ──────  ──────\n");

    for (NSDictionary *m in modes) {
        size_t pw = [m[@"pw"] unsignedLongValue];
        size_t ph = [m[@"ph"] unsignedLongValue];
        size_t lw = [m[@"lw"] unsignedLongValue];
        size_t lh = [m[@"lh"] unsignedLongValue];
        double hz = [m[@"hz"] doubleValue];
        BOOL hidpi   = [m[@"hidpi"] boolValue];
        BOOL current = [m[@"cur"] boolValue];

        char pixStr[32], lookStr[32], hzStr[16], scaleStr[16];
        snprintf(pixStr,   sizeof(pixStr),   "%zu x %zu", pw, ph);
        snprintf(lookStr,  sizeof(lookStr),  "%zu x %zu", lw, lh);
        snprintf(scaleStr, sizeof(scaleStr), "%s", hidpi ? "2x" : "1x");
        if (hz > 0)
            snprintf(hzStr, sizeof(hzStr), "%.0fHz", hz);
        else
            snprintf(hzStr, sizeof(hzStr), "--");

        const char *typeClr = hidpi ? FC : D;
        const char *marker  = current ? FG " <-- current" R : "";

        printf("  %s%-16s" R "  %-16s  %s%-6s" R "  %-6s%s\n",
               typeClr, pixStr, lookStr, typeClr, scaleStr, hzStr, marker);
    }

    printf("\n  " D "Total: %lu mode%s" R "\n",
           (unsigned long)modes.count, modes.count == 1 ? "" : "s");
}

// ── List displays ───────────────────────────────────────────────────────────

static void listDisplays(void) {
    uint32_t activeCount, onlineCount;
    CGDirectDisplayID active[MAX_DISPLAYS], online[MAX_DISPLAYS];

    CGGetActiveDisplayList(MAX_DISPLAYS, active, &activeCount);
    CGGetOnlineDisplayList(MAX_DISPLAYS, online, &onlineCount);

    NSMutableSet *activeSet = [NSMutableSet set];
    for (uint32_t i = 0; i < activeCount; i++)
        [activeSet addObject:@(active[i])];

    printf("\n " B "%s" R " v%s\n", APP_NAME, VERSION);
    printf(" ══════════════════════════════════════════\n\n");
    printf(" " D "Displays: %u online, %u active" R "\n\n", onlineCount, activeCount);

    for (uint32_t i = 0; i < onlineCount; i++) {
        CGDirectDisplayID did = online[i];
        BOOL isActive  = [activeSet containsObject:@(did)];
        BOOL isBuiltIn = CGDisplayIsBuiltin(did);
        BOOL isMain    = CGDisplayIsMain(did);

        NSString *name = getDisplayName(did);

        // Header line
        printf(" %s%s" R " " B "%s" R D " — 0x%x" R "\n",
               isActive ? FG : FR,
               isActive ? "●" : "○",
               [name UTF8String], did);

        // Tags
        printf("   ");
        if (isBuiltIn) printf(FY "built-in" R "  ");
        if (isMain)    printf(FB "main" R "  ");
        printf("%s%s" R "\n",
               isActive ? FG : FR,
               isActive ? "active" : "disabled");

        if (isActive) {
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
            if (mode) {
                size_t lw = CGDisplayModeGetWidth(mode);
                size_t lh = CGDisplayModeGetHeight(mode);
                size_t pw = CGDisplayModeGetPixelWidth(mode);
                size_t ph = CGDisplayModeGetPixelHeight(mode);
                double hz = CGDisplayModeGetRefreshRate(mode);
                BOOL hidpi = (pw > lw);

                printf("   Resolution: " B "%zu x %zu" R, pw, ph);
                if (hidpi && lw > 0) {
                    printf(FC " @%zux" R " (looks like %zu x %zu)", pw / lw, lw, lh);
                }
                if (hz > 0) printf("  %.0fHz", hz);
                printf("\n");

                CGDisplayModeRelease(mode);
            }

            // Physical size
            CGSize mm = CGDisplayScreenSize(did);
            if (mm.width > 0 && mm.height > 0) {
                double diag = sqrt(mm.width * mm.width + mm.height * mm.height) / 25.4;
                printf("   Screen:     %.0f x %.0f mm (%.1f\")\n", mm.width, mm.height, diag);
            }

            // Rotation
            double rot = CGDisplayRotation(did);
            if (rot != 0) {
                printf("   Rotation:   %.0f deg\n", rot);
            }
        }

        printf("\n");
    }

    printf(" " D "Run 'display_disable modes <ID>' to see all resolutions" R "\n\n");
}

// ── Quick status ────────────────────────────────────────────────────────────

static void printStatus(void) {
    uint32_t activeCount, onlineCount;
    CGDirectDisplayID active[MAX_DISPLAYS], online[MAX_DISPLAYS];

    CGGetActiveDisplayList(MAX_DISPLAYS, active, &activeCount);
    CGGetOnlineDisplayList(MAX_DISPLAYS, online, &onlineCount);

    NSMutableSet *activeSet = [NSMutableSet set];
    for (uint32_t i = 0; i < activeCount; i++)
        [activeSet addObject:@(active[i])];

    printf("\n");
    for (uint32_t i = 0; i < onlineCount; i++) {
        CGDirectDisplayID did = online[i];
        BOOL isActive  = [activeSet containsObject:@(did)];
        BOOL isBuiltIn = CGDisplayIsBuiltin(did);
        NSString *name = getDisplayName(did);

        printf(" %s%s" R " %-8s %s%-10s" R "  %s (0x%x)\n",
               isActive ? FG : FR,
               isActive ? "●" : "○",
               isBuiltIn ? "[built-in]" : "",
               isActive ? FG : FR,
               isActive ? "active" : "disabled",
               [name UTF8String], did);
    }
    printf("\n");
}

// ── Find built-in display ───────────────────────────────────────────────────

static CGDirectDisplayID findBuiltInDisplay(void) {
    uint32_t count;
    CGDirectDisplayID displays[MAX_DISPLAYS];

    CGGetOnlineDisplayList(MAX_DISPLAYS, displays, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i]))
            return displays[i];
    }
    return 0;
}

// ── Disable / Enable ────────────────────────────────────────────────────────

static bool disableDisplay(CGDirectDisplayID displayID) {
    CGDisplayConfigRef config;
    CGError err;

    err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, FR "x" R " Failed to begin configuration (error %d)\n", err);
        return false;
    }

    err = CGSConfigureDisplayEnabled(config, displayID, false);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, FR "x" R " Failed to disable display (error %d)\n", err);
        CGCancelDisplayConfiguration(config);
        return false;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, FR "x" R " Failed to commit configuration (error %d)\n", err);
        return false;
    }

    printf(FG "✓" R " Display " B "0x%x" R " disabled\n", displayID);
    return true;
}

static bool enableDisplay(CGDirectDisplayID displayID) {
    CGDisplayConfigRef config;
    CGError err;

    err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, FR "x" R " Failed to begin configuration (error %d)\n", err);
        return false;
    }

    err = CGSConfigureDisplayEnabled(config, displayID, true);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, FR "x" R " Failed to enable display (error %d)\n", err);
        CGCancelDisplayConfiguration(config);
        return false;
    }

    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, FR "x" R " Failed to commit configuration (error %d)\n", err);
        return false;
    }

    printf(FG "✓" R " Display " B "0x%x" R " enabled\n", displayID);
    return true;
}

// ── Usage / Help ────────────────────────────────────────────────────────────

static void printUsage(const char *prog) {
    printf("\n " B "%s" R " v%s\n", APP_NAME, VERSION);
    printf(" Lightweight display management for Apple Silicon\n\n");

    printf(B " USAGE" R "\n");
    printf("   %s " FC "<command>" R " [options]\n\n", prog);

    printf(B " COMMANDS" R "\n");
    printf("   " FC "list" R "               List all displays with current info\n");
    printf("   " FC "modes" R " <ID>          Show all available resolutions (incl. HiDPI)\n");
    printf("   " FC "disable" R " <ID>        Disable a specific display\n");
    printf("   " FC "disable-builtin" R "     Auto-detect and disable built-in display\n");
    printf("   " FC "enable" R " <ID>         Re-enable a disabled display\n");
    printf("   " FC "status" R "              Quick status of all displays\n");
    printf("   " FC "--version" R "           Show version\n\n");

    printf(B " DISPLAY ID" R "\n");
    printf("   Accepts hex (" D "0x1" R ") or decimal (" D "1" R ") format.\n");
    printf("   Run '" D "%s list" R "' to find display IDs.\n\n", prog);

    printf(B " EXAMPLES" R "\n");
    printf("   %s list                 " D "# see all displays" R "\n", prog);
    printf("   %s modes 0x1            " D "# browse HiDPI modes" R "\n", prog);
    printf("   %s disable-builtin      " D "# disable MacBook screen" R "\n", prog);
    printf("   %s enable 0x1           " D "# re-enable a display" R "\n\n", prog);
}

// ── Main ────────────────────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            printUsage(argv[0]);
            return 1;
        }

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        // --version / -v
        if ([cmd isEqualToString:@"--version"] || [cmd isEqualToString:@"-v"]) {
            printf("%s v%s\n", APP_NAME, VERSION);
            return 0;
        }

        // list / ls
        if ([cmd isEqualToString:@"list"] || [cmd isEqualToString:@"ls"]) {
            listDisplays();
            return 0;
        }

        // status
        if ([cmd isEqualToString:@"status"]) {
            printStatus();
            return 0;
        }

        // modes <ID>
        if ([cmd isEqualToString:@"modes"]) {
            if (argc < 3) {
                fprintf(stderr, FR "x" R " Display ID required.\n");
                fprintf(stderr, "  Run '%s list' to find display IDs.\n", argv[0]);
                return 1;
            }
            CGDirectDisplayID did = parseDisplayID(argv[2]);
            NSString *name = getDisplayName(did);
            printf("\n " B "%s" R D " — 0x%x" R "\n\n", [name UTF8String], did);
            listModes(did);
            printf("\n");
            return 0;
        }

        // disable-builtin
        if ([cmd isEqualToString:@"disable-builtin"]) {
            CGDirectDisplayID builtIn = findBuiltInDisplay();
            if (builtIn == 0) {
                printf(FY "!" R " No built-in display found.\n");
                return 0;
            }

            NSString *name = getDisplayName(builtIn);
            printf("Found: %s (0x%x)\n", [name UTF8String], builtIn);

            if (disableDisplay(builtIn)) {
                printf("\n" D "To re-enable:" R " %s enable 0x%x\n", argv[0], builtIn);
                return 0;
            }
            return 1;
        }

        // disable <ID> / enable <ID>
        if ([cmd isEqualToString:@"disable"] || [cmd isEqualToString:@"enable"]) {
            if (argc < 3) {
                fprintf(stderr, FR "x" R " Display ID required.\n");
                fprintf(stderr, "  Run '%s list' to find display IDs.\n", argv[0]);
                return 1;
            }
            CGDirectDisplayID did = parseDisplayID(argv[2]);

            if ([cmd isEqualToString:@"disable"]) {
                return disableDisplay(did) ? 0 : 1;
            } else {
                return enableDisplay(did) ? 0 : 1;
            }
        }

        // help / --help / -h
        if ([cmd isEqualToString:@"help"] || [cmd isEqualToString:@"--help"] ||
            [cmd isEqualToString:@"-h"]) {
            printUsage(argv[0]);
            return 0;
        }

        fprintf(stderr, FR "x" R " Unknown command: '%s'\n", argv[1]);
        fprintf(stderr, "  Run '%s --help' for usage.\n", argv[0]);
        return 1;
    }
}
