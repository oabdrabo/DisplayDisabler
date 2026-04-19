/*
 * test_force.m — autonomous test harness for the Force HiDPI path.
 */

#import <Cocoa/Cocoa.h>
#import "DisplayManager.h"

static void log_displays(DisplayManager *mgr, const char *tag) {
    NSArray<DDDisplayInfo *> *d = [mgr allDisplays];
    fprintf(stderr, "  [%s] displays (%lu):\n", tag, (unsigned long)d.count);
    for (DDDisplayInfo *i in d) {
        CGRect b = CGDisplayBounds(i.displayID);
        fprintf(stderr, "    0x%X  %-20s  %-9s  %s  bounds=(%.0f,%.0f %.0fx%.0f)  px=%zux%zu  lg=%zux%zu%s\n",
                i.displayID,
                [i.name UTF8String],
                i.isBuiltIn ? "built-in" : "external",
                i.isActive ? "ACTIVE  " : "INACTIVE",
                b.origin.x, b.origin.y, b.size.width, b.size.height,
                i.pixelWidth, i.pixelHeight,
                i.logicalWidth, i.logicalHeight,
                i.isHiDPI ? "  HiDPI" : "");
    }
}

static void pump(NSTimeInterval t) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:t]];
}

static BOOL do_force(DisplayManager *mgr, CGDirectDisplayID did,
                     DDDisplayMode *mode, const char *label) {
    fprintf(stderr, "\n-- force [%s]: %zux%zu logical=%zux%zu hiDPI=%d modeRef=%s --\n",
            label, mode.pixelWidth, mode.pixelHeight,
            mode.logicalWidth, mode.logicalHeight, mode.isHiDPI,
            mode.modeRef ? "yes" : "synthetic");

    __block BOOL done = NO, ok = NO;
    __block NSError *err = nil;
    NSDate *t0 = [NSDate date];
    [mgr forceHiDPIForDisplay:did atMode:mode completion:^(BOOL s, NSError *e) {
        done = YES; ok = s; err = e;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (!done && [deadline compare:[NSDate date]] == NSOrderedDescending) {
        pump(0.05);
    }
    fprintf(stderr, "   result: ok=%d  dt=%.2fs  err=%s\n",
            ok, -[t0 timeIntervalSinceNow],
            err ? [err.localizedDescription UTF8String] : "(nil)");
    return ok;
}

static BOOL do_stop(DisplayManager *mgr, CGDirectDisplayID did, const char *label) {
    fprintf(stderr, "\n-- stop [%s] --\n", label);
    NSError *err = nil;
    NSDate *t0 = [NSDate date];
    BOOL ok = [mgr stopForcedHiDPIForDisplay:did error:&err];
    fprintf(stderr, "   result: ok=%d  dt=%.2fs  err=%s\n",
            ok, -[t0 timeIntervalSinceNow],
            err ? [err.localizedDescription UTF8String] : "(nil)");
    return ok;
}

int main(int argc __unused, const char *argv[] __unused) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        DisplayManager *mgr = [DisplayManager shared];

        log_displays(mgr, "pre-test");

        DDDisplayInfo *target = nil;
        for (DDDisplayInfo *i in [mgr allDisplays]) {
            if (i.isBuiltIn && i.isActive) { target = i; break; }
        }
        if (!target) {
            fprintf(stderr, "no built-in; abort\n");
            return 2;
        }

        NSArray<DDDisplayMode *> *opts = [mgr forceHiDPIOptionsForDisplay:target.displayID];

        DDDisplayMode *forceMode = nil, *customMode = nil;
        for (DDDisplayMode *m in opts) {
            BOOL panelDerived = (m.modeRef != NULL);
            BOOL sameAsCurrent = (m.pixelWidth  == target.pixelWidth &&
                                  m.pixelHeight == target.pixelHeight);
            if (!forceMode  && panelDerived && !sameAsCurrent) forceMode  = m;
            if (!customMode && !panelDerived)                  customMode = m;
            if (forceMode && customMode) break;
        }
        if (!forceMode)  { fprintf(stderr, "no panel-derived force option; abort\n"); return 3; }
        if (!customMode) { fprintf(stderr, "no synthetic force option; abort\n");     return 4; }

        // ── Test 1: Force panel-advertised Standard mode ─────────────────
        fprintf(stderr, "\n=== TEST 1: force+stop panel-standard ===\n");
        if (!do_force(mgr, target.displayID, forceMode, "panel-standard")) return 10;
        log_displays(mgr, "post-force T1");
        pump(0.5);
        if (!do_stop(mgr, target.displayID, "panel-standard")) return 11;
        log_displays(mgr, "post-stop T1");

        // ── Test 2: rapid re-force after stop (shared VD reuse) ──────────
        fprintf(stderr, "\n=== TEST 2: rapid re-force (shared VD reuse) ===\n");
        pump(0.5);
        if (!do_force(mgr, target.displayID, forceMode, "reuse")) return 20;
        log_displays(mgr, "post-force T2");
        pump(0.5);
        if (!do_stop(mgr, target.displayID, "reuse")) return 21;

        // ── Test 3: custom synthetic mode (whichever the option list yields first) ──
        fprintf(stderr, "\n=== TEST 3: force+stop custom synthetic %zux%zu ===\n",
                customMode.pixelWidth, customMode.pixelHeight);
        pump(0.5);
        if (!do_force(mgr, target.displayID, customMode, "synthetic")) return 30;
        log_displays(mgr, "post-force T3");
        pump(0.5);
        if (!do_stop(mgr, target.displayID, "synthetic")) return 31;

        // ── Test 4: double-force error path (should fail with AlreadyForced) ─
        fprintf(stderr, "\n=== TEST 4: double-force should error ===\n");
        pump(0.5);
        if (!do_force(mgr, target.displayID, forceMode, "first")) return 40;
        // Second force on same display while forced: expect failure.
        __block BOOL d2done = NO, d2ok = NO;
        __block NSError *d2err = nil;
        [mgr forceHiDPIForDisplay:target.displayID atMode:forceMode
                       completion:^(BOOL s, NSError *e) {
            d2done = YES; d2ok = s; d2err = e;
        }];
        NSDate *d2deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!d2done && [d2deadline compare:[NSDate date]] == NSOrderedDescending) pump(0.05);
        fprintf(stderr, "   second force: ok=%d (expected 0)  err=%s\n",
                d2ok, d2err ? [d2err.localizedDescription UTF8String] : "(nil)");
        if (d2ok) return 42;  // must fail
        do_stop(mgr, target.displayID, "first-cleanup");

        log_displays(mgr, "final");
        [mgr cleanUpAllVirtualDisplays];

        fprintf(stderr, "\n=== ALL TESTS PASSED ===\n");
        return 0;
    }
}
