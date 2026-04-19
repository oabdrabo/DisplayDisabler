/*
 * test_options.m — read-only enumerator for the new
 * forceHiDPIOptionsForDisplay: API. Doesn't create a virtual or touch the
 * mirror; safe to run while a force is already active.
 */

#import <Cocoa/Cocoa.h>
#import "DisplayManager.h"

int main(int argc __unused, const char *argv[] __unused) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        DisplayManager *mgr = [DisplayManager shared];

        for (DDDisplayInfo *d in [mgr allDisplays]) {
            CGSize phys = [mgr physicalPixelsForDisplay:d.displayID];
            double aspect = (phys.height > 0) ? phys.width / phys.height : 0;
            fprintf(stderr,
                "\n== %s (0x%X) builtin=%d active=%d ==\n",
                [d.name UTF8String], d.displayID, d.isBuiltIn, d.isActive);
            fprintf(stderr, "   physical pixels: %.0f x %.0f  aspect=%.4f\n",
                    phys.width, phys.height, aspect);

            NSArray<DDDisplayMode *> *opts = [mgr forceHiDPIOptionsForDisplay:d.displayID];
            fprintf(stderr, "   force-HiDPI options (%lu):\n", (unsigned long)opts.count);
            for (DDDisplayMode *m in opts) {
                double mAsp = (m.pixelHeight > 0)
                    ? (double)m.pixelWidth / (double)m.pixelHeight : 0;
                fprintf(stderr,
                    "     %s  logical=%4zu x %4zu  pixel=%4zu x %4zu  asp=%.4f  rate=%.0fHz\n",
                    (m.modeRef != NULL) ? "panel" : "synth",
                    m.logicalWidth, m.logicalHeight,
                    m.pixelWidth,   m.pixelHeight,
                    mAsp, m.refreshRate);
            }
        }
        return 0;
    }
}
