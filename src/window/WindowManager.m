#import "WindowManager.h"
#import "AXWindow.h"
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

static const CGFloat kEdgeThreshold = 14.0;
static const CGFloat kCornerBand    = 140.0;

#pragma mark - Accessibility window helpers (AX uses global, top-left/Y-down coords)

static AXUIElementRef copyFocusedWindow(pid_t *outPid) {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    if (!sys) return NULL;
    CFTypeRef appRef = NULL;
    AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute, &appRef);
    CFRelease(sys);
    if (!appRef) return NULL;
    if (outPid) AXUIElementGetPid((AXUIElementRef)appRef, outPid);
    CFTypeRef winRef = NULL;
    AXUIElementCopyAttributeValue((AXUIElementRef)appRef, kAXFocusedWindowAttribute, &winRef);
    CFRelease(appRef);
    return (AXUIElementRef)winRef;
}

static NSScreen *screenForCGPoint(CGPoint p) {
    for (NSScreen *s in [NSScreen screens]) {
        CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        if (CGRectContainsPoint(CGDisplayBounds(did), p)) return s;
    }
    return [NSScreen mainScreen];
}

static CGRect visibleFrameCG(NSScreen *s) {
    CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect full = CGDisplayBounds(did);
    NSRect fc = s.frame, vc = s.visibleFrame;
    CGFloat left   = vc.origin.x - fc.origin.x;
    CGFloat right  = NSMaxX(fc) - NSMaxX(vc);
    CGFloat top    = NSMaxY(fc) - NSMaxY(vc);
    CGFloat bottom = vc.origin.y - fc.origin.y;
    return CGRectMake(full.origin.x + left,
                      full.origin.y + top,
                      full.size.width  - left - right,
                      full.size.height - top - bottom);
}

static CGRect rectForLayout(DDSnap l, CGRect v, CGRect cur) {
    CGFloat x = v.origin.x, y = v.origin.y, w = v.size.width, h = v.size.height;
    switch (l) {
        case DDSnapLeftHalf:      return CGRectMake(x,           y,         w/2, h);
        case DDSnapRightHalf:     return CGRectMake(x + w/2,     y,         w/2, h);
        case DDSnapTopHalf:       return CGRectMake(x,           y,         w,   h/2);
        case DDSnapBottomHalf:    return CGRectMake(x,           y + h/2,   w,   h/2);
        case DDSnapTopLeft:       return CGRectMake(x,           y,         w/2, h/2);
        case DDSnapTopRight:      return CGRectMake(x + w/2,     y,         w/2, h/2);
        case DDSnapBottomLeft:    return CGRectMake(x,           y + h/2,   w/2, h/2);
        case DDSnapBottomRight:   return CGRectMake(x + w/2,     y + h/2,   w/2, h/2);
        case DDSnapLeftThird:     return CGRectMake(x,           y,         w/3, h);
        case DDSnapCenterThird:   return CGRectMake(x + w/3,     y,         w/3, h);
        case DDSnapRightThird:    return CGRectMake(x + 2*w/3,   y,         w/3, h);
        case DDSnapLeftTwoThirds: return CGRectMake(x,           y,       2*w/3, h);
        case DDSnapRightTwoThirds:return CGRectMake(x + w/3,     y,       2*w/3, h);
        case DDSnapMaximize:      return v;
        case DDSnapCenter:        return CGRectMake(x + (w - cur.size.width)/2,
                                                    y + (h - cur.size.height)/2,
                                                    cur.size.width, cur.size.height);
        case DDSnapRestore:       return cur;
    }
    return v;
}

static const CGFloat kArrangeMainFraction = 0.62;

static CGRect centeredRect(CGRect v, CGFloat frac) {
    CGFloat w = v.size.width * frac, h = v.size.height * frac;
    return CGRectMake(v.origin.x + (v.size.width  - w) / 2,
                      v.origin.y + (v.size.height - h) / 2, w, h);
}

#pragma mark - Coordinate conversion (Cocoa bottom-left <-> CG top-left)

static CGFloat primaryHeight(void) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    return screens.count ? NSMaxY(screens[0].frame) : 0;
}
static CGPoint cocoaToCG(NSPoint p) { return CGPointMake(p.x, primaryHeight() - p.y); }
static NSRect cgToCocoaRect(CGRect r) {
    return NSMakeRect(r.origin.x, primaryHeight() - (r.origin.y + r.size.height),
                      r.size.width, r.size.height);
}

#pragma mark - Hotkey table

#define DD_HOTKEY_COUNT 16
typedef struct { UInt32 key; DDSnap layout; } DDHotkey;
static const DDHotkey kHotkeys[] = {
    { kVK_LeftArrow,  DDSnapLeftHalf },   { kVK_RightArrow, DDSnapRightHalf },
    { kVK_UpArrow,    DDSnapTopHalf },    { kVK_DownArrow,  DDSnapBottomHalf },
    { kVK_Return,     DDSnapMaximize },   { kVK_ANSI_C,     DDSnapCenter },
    { kVK_ANSI_U,     DDSnapTopLeft },    { kVK_ANSI_I,     DDSnapTopRight },
    { kVK_ANSI_J,     DDSnapBottomLeft }, { kVK_ANSI_K,     DDSnapBottomRight },
    { kVK_ANSI_D,     DDSnapLeftThird },  { kVK_ANSI_F,     DDSnapCenterThird },
    { kVK_ANSI_G,     DDSnapRightThird }, { kVK_ANSI_E,     DDSnapLeftTwoThirds },
    { kVK_ANSI_T,     DDSnapRightTwoThirds }, { kVK_ANSI_Z,  DDSnapRestore },
};
static const size_t kHotkeyCount = sizeof(kHotkeys) / sizeof(*kHotkeys);
_Static_assert(sizeof(kHotkeys) / sizeof(*kHotkeys) == DD_HOTKEY_COUNT, "hotkey count mismatch");

#define DD_ARRANGE_COUNT 7
typedef struct { UInt32 key; DDArrange cmd; } DDArrangeKey;
static const DDArrangeKey kArrangeKeys[] = {
    { kVK_ANSI_G,     DDArrangeGrid },       { kVK_ANSI_C,    DDArrangeCentered },
    { kVK_Space,      DDArrangeCycle },      { kVK_Return,    DDArrangePromote },
    { kVK_RightArrow, DDArrangeRotateNext }, { kVK_LeftArrow, DDArrangeRotatePrev },
    { kVK_ANSI_Z,     DDArrangeRestore },
};
static const size_t kArrangeCount = sizeof(kArrangeKeys) / sizeof(*kArrangeKeys);
_Static_assert(sizeof(kArrangeKeys) / sizeof(*kArrangeKeys) == DD_ARRANGE_COUNT, "arrange count mismatch");

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef e, void *ud);

@interface WindowManager () {
    EventHotKeyRef _hotkeyRefs[DD_HOTKEY_COUNT];
    EventHotKeyRef _arrangeRefs[DD_ARRANGE_COUNT];
    EventHandlerRef _handler;
    BOOL _hotkeysOn;
    BOOL _dragOn;
    NSInteger _activeLayout;
    AXUIElementRef _mainWindow;
}
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *restoreFrames;
@property (nonatomic, strong) NSArray<DDManagedWindow *> *restoreSnapshot;
@property (nonatomic) id dragMon;
@property (nonatomic) id upMon;
@property (nonatomic) id downMon;
@property (nonatomic) BOOL dragging;
@property (nonatomic) pid_t dragPid;
@property (nonatomic) DDSnap pendingLayout;
@property (nonatomic) BOOL hasPending;
@property (nonatomic, strong) NSWindow *preview;
@end

@implementation WindowManager

+ (instancetype)shared {
    static WindowManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[WindowManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _restoreFrames = [NSMutableDictionary dictionary];
        _activeLayout = -1;
    }
    return self;
}

#pragma mark - Snapping

- (void)snap:(DDSnap)layout {
    if (!DDAXTrusted()) { DDAXRequestTrust(); return; }
    pid_t pid = 0;
    AXUIElementRef w = copyFocusedWindow(&pid);
    if (!w) return;
    [self applyLayout:layout toWindow:w pid:pid];
    CFRelease(w);
}

- (void)applyLayout:(DDSnap)layout toWindow:(AXUIElementRef)w pid:(pid_t)pid {
    CGRect cur;
    if (!DDAXCopyFrame(w, &cur) || cur.size.width < 1) return;

    CGRect target;
    if (layout == DDSnapRestore) {
        NSValue *saved = self.restoreFrames[@(pid)];
        if (!saved) return;
        target = saved.rectValue;
        [self.restoreFrames removeObjectForKey:@(pid)];
    } else {
        CGPoint center = CGPointMake(CGRectGetMidX(cur), CGRectGetMidY(cur));
        CGRect v = visibleFrameCG(screenForCGPoint(center));
        target = rectForLayout(layout, v, cur);

        BOOL noop = fabs(cur.origin.x - target.origin.x) < 2 &&
                    fabs(cur.origin.y - target.origin.y) < 2 &&
                    fabs(cur.size.width  - target.size.width)  < 2 &&
                    fabs(cur.size.height - target.size.height) < 2;
        if (noop) return;
        self.restoreFrames[@(pid)] = [NSValue valueWithRect:cur];
    }
    DDAXSetFrame(w, target);
}

#pragma mark - Arrange (multi-window layouts)

- (void)arrange:(DDArrange)command {
    if (!DDAXTrusted()) { DDAXRequestTrust(); return; }

    if (command == DDArrangeRestore) {
        for (DDManagedWindow *m in self.restoreSnapshot) DDAXSetFrame(m.window, m.frame);
        self.restoreSnapshot = nil;
        _activeLayout = -1;
        [self setMainWindow:NULL];
        return;
    }

    CGRect v = [self arrangeVisibleFrame];
    NSArray<DDManagedWindow *> *wins = DDAXManageableWindowsOnScreen(v);
    if (wins.count == 0) return;

    if (self.restoreSnapshot.count == 0) self.restoreSnapshot = wins;

    DDArrange layout;
    switch (command) {
        case DDArrangeCycle:      layout = (_activeLayout == DDArrangeGrid) ? DDArrangeCentered : DDArrangeGrid; break;
        case DDArrangePromote:    [self setMainWindowToFocusedIn:wins]; layout = DDArrangeCentered; break;
        case DDArrangeRotateNext: [self rotateMainBy:1 in:wins];  layout = DDArrangeCentered; break;
        case DDArrangeRotatePrev: [self rotateMainBy:-1 in:wins]; layout = DDArrangeCentered; break;
        case DDArrangeCentered:   layout = DDArrangeCentered; break;
        default:                  layout = DDArrangeGrid; break;
    }

    if (layout == DDArrangeCentered) [self applyCentered:wins inFrame:v];
    else                             [self applyGrid:wins inFrame:v];
    _activeLayout = layout;
}

- (CGRect)arrangeVisibleFrame {
    CGPoint anchor = cocoaToCG([NSEvent mouseLocation]);
    AXUIElementRef w = copyFocusedWindow(NULL);
    if (w) {
        CGRect f;
        if (DDAXCopyFrame(w, &f)) anchor = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
        CFRelease(w);
    }
    return visibleFrameCG(screenForCGPoint(anchor));
}

- (void)applyGrid:(NSArray<DDManagedWindow *> *)wins inFrame:(CGRect)v {
    NSUInteger n = wins.count;
    if (n == 0) return;
    if (n == 1) { DDAXSetFrame(wins[0].window, v); return; }
    if (n == 2) {
        DDAXSetFrame(wins[0].window, rectForLayout(DDSnapLeftHalf,  v, CGRectZero));
        DDAXSetFrame(wins[1].window, rectForLayout(DDSnapRightHalf, v, CGRectZero));
        return;
    }
    if (n == 3) {
        DDAXSetFrame(wins[0].window, rectForLayout(DDSnapLeftHalf,    v, CGRectZero));
        DDAXSetFrame(wins[1].window, rectForLayout(DDSnapTopRight,    v, CGRectZero));
        DDAXSetFrame(wins[2].window, rectForLayout(DDSnapBottomRight, v, CGRectZero));
        return;
    }
    const DDSnap quad[4] = { DDSnapTopLeft, DDSnapTopRight, DDSnapBottomLeft, DDSnapBottomRight };
    for (NSUInteger i = 0; i < n; i++)
        DDAXSetFrame(wins[i].window, rectForLayout(quad[i % 4], v, CGRectZero));
}

- (void)applyCentered:(NSArray<DDManagedWindow *> *)wins inFrame:(CGRect)v {
    DDManagedWindow *main = [self mainWindowIn:wins];
    [self setMainWindow:main.window];
    NSMutableArray<DDManagedWindow *> *back = [NSMutableArray array];
    for (DDManagedWindow *m in wins) if (m != main) [back addObject:m];

    [self applyGrid:back inFrame:v];
    DDAXSetFrame(main.window, centeredRect(v, kArrangeMainFraction));
    DDAXRaise(main.window);
    DDAXActivateApp(main.pid);
}

- (DDManagedWindow *)mainWindowIn:(NSArray<DDManagedWindow *> *)wins {
    if (_mainWindow) {
        for (DDManagedWindow *m in wins)
            if (CFEqual(m.window, _mainWindow)) return m;
    }
    DDManagedWindow *focused = nil;
    AXUIElementRef w = copyFocusedWindow(NULL);
    if (w) {
        for (DDManagedWindow *m in wins)
            if (CFEqual(m.window, w)) { focused = m; break; }
        CFRelease(w);
    }
    return focused ?: wins.firstObject;
}

- (void)setMainWindowToFocusedIn:(NSArray<DDManagedWindow *> *)wins {
    AXUIElementRef w = copyFocusedWindow(NULL);
    if (!w) return;
    for (DDManagedWindow *m in wins)
        if (CFEqual(m.window, w)) { [self setMainWindow:m.window]; break; }
    CFRelease(w);
}

- (void)rotateMainBy:(NSInteger)delta in:(NSArray<DDManagedWindow *> *)wins {
    NSMutableArray<DDManagedWindow *> *order = [NSMutableArray array];
    for (DDManagedWindow *s in self.restoreSnapshot)
        for (DDManagedWindow *w in wins)
            if (CFEqual(s.window, w.window)) { [order addObject:w]; break; }
    for (DDManagedWindow *w in wins)
        if (![order containsObject:w]) [order addObject:w];

    NSInteger n = order.count;
    if (n == 0) return;
    NSInteger cur = -1;
    if (_mainWindow)
        for (NSInteger i = 0; i < n; i++)
            if (CFEqual(order[i].window, _mainWindow)) { cur = i; break; }
    NSInteger next = (cur < 0) ? (delta > 0 ? 0 : n - 1) : ((cur + delta + n) % n);
    [self setMainWindow:order[next].window];
}

- (void)setMainWindow:(AXUIElementRef)w {
    if (_mainWindow == w) return;
    if (w) CFRetain(w);
    if (_mainWindow) CFRelease(_mainWindow);
    _mainWindow = w;
}

#pragma mark - Global hotkeys (Carbon)

- (void)setHotkeysEnabled:(BOOL)enabled {
    if (enabled == _hotkeysOn) return;
    _hotkeysOn = enabled;
    if (enabled) {
        if (!_handler) {
            EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
            InstallApplicationEventHandler(&HotKeyHandler, 1, &spec,
                                           (__bridge void *)self, &_handler);
        }
        UInt32 mods = controlKey | optionKey;
        for (size_t i = 0; i < kHotkeyCount; i++) {
            EventHotKeyID hkid = { .signature = 'DDwm', .id = (UInt32)i };
            RegisterEventHotKey(kHotkeys[i].key, mods, hkid,
                                GetApplicationEventTarget(), 0, &_hotkeyRefs[i]);
        }
        UInt32 amods = controlKey | optionKey | shiftKey;
        for (size_t i = 0; i < kArrangeCount; i++) {
            EventHotKeyID hkid = { .signature = 'DDwm', .id = (UInt32)(kHotkeyCount + i) };
            RegisterEventHotKey(kArrangeKeys[i].key, amods, hkid,
                                GetApplicationEventTarget(), 0, &_arrangeRefs[i]);
        }
    } else {
        for (size_t i = 0; i < kHotkeyCount; i++) {
            if (_hotkeyRefs[i]) { UnregisterEventHotKey(_hotkeyRefs[i]); _hotkeyRefs[i] = NULL; }
        }
        for (size_t i = 0; i < kArrangeCount; i++) {
            if (_arrangeRefs[i]) { UnregisterEventHotKey(_arrangeRefs[i]); _arrangeRefs[i] = NULL; }
        }
    }
}

- (void)fireHotkeyIndex:(UInt32)i {
    if (i < kHotkeyCount) { [self snap:kHotkeys[i].layout]; return; }
    UInt32 j = i - (UInt32)kHotkeyCount;
    if (j < kArrangeCount) [self arrange:kArrangeKeys[j].cmd];
}

#pragma mark - Snap on drag

- (void)setDragSnapEnabled:(BOOL)enabled {
    if (enabled == _dragOn) return;
    _dragOn = enabled;
    if (enabled) {
        __weak __typeof(self) ws = self;
        self.downMon = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                                              handler:^(NSEvent *e){ (void)e; [ws onMouseDown]; }];
        self.dragMon = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged
                                                              handler:^(NSEvent *e){ (void)e; [ws onMouseDragged]; }];
        self.upMon   = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                                              handler:^(NSEvent *e){ (void)e; [ws onMouseUp]; }];
    } else {
        if (self.downMon) { [NSEvent removeMonitor:self.downMon]; self.downMon = nil; }
        if (self.dragMon) { [NSEvent removeMonitor:self.dragMon]; self.dragMon = nil; }
        if (self.upMon)   { [NSEvent removeMonitor:self.upMon];   self.upMon = nil; }
        [self hidePreview];
        self.dragging = NO;
    }
}

- (void)onMouseDown {
    self.dragging = NO;
    self.hasPending = NO;
    if (!DDAXTrusted()) return;
    pid_t pid = 0;
    AXUIElementRef w = copyFocusedWindow(&pid);
    if (!w) return;
    CGRect f;
    if (DDAXCopyFrame(w, &f)) {
        CGPoint m = cocoaToCG([NSEvent mouseLocation]);
        CGRect titlebar = CGRectMake(f.origin.x, f.origin.y, f.size.width, 32);
        if (CGRectContainsPoint(titlebar, m)) { self.dragging = YES; self.dragPid = pid; }
    }
    CFRelease(w);
}

- (void)onMouseDragged {
    if (!self.dragging) return;
    CGPoint m = cocoaToCG([NSEvent mouseLocation]);
    NSScreen *scr = screenForCGPoint(m);
    CGDirectDisplayID did = [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect b = CGDisplayBounds(did);

    BOOL nearL = (m.x - CGRectGetMinX(b)) < kEdgeThreshold;
    BOOL nearR = (CGRectGetMaxX(b) - m.x) < kEdgeThreshold;
    BOOL nearT = (m.y - CGRectGetMinY(b)) < kEdgeThreshold;
    BOOL nearB = (CGRectGetMaxY(b) - m.y) < kEdgeThreshold;
    BOOL topBand = (m.y - CGRectGetMinY(b)) < kCornerBand;
    BOOL botBand = (CGRectGetMaxY(b) - m.y) < kCornerBand;

    DDSnap layout = DDSnapMaximize; BOOL has = YES;
    if (nearL)      layout = topBand ? DDSnapTopLeft  : (botBand ? DDSnapBottomLeft  : DDSnapLeftHalf);
    else if (nearR) layout = topBand ? DDSnapTopRight : (botBand ? DDSnapBottomRight : DDSnapRightHalf);
    else if (nearT) layout = DDSnapMaximize;
    else if (nearB) layout = DDSnapBottomHalf;
    else            has = NO;

    self.hasPending = has;
    self.pendingLayout = layout;
    if (has) [self showPreviewRect:rectForLayout(layout, visibleFrameCG(scr), CGRectZero)];
    else     [self hidePreview];
}

- (void)onMouseUp {
    BOOL act = self.dragging && self.hasPending;
    DDSnap layout = self.pendingLayout;
    pid_t pid = self.dragPid;
    self.dragging = NO;
    self.hasPending = NO;
    [self hidePreview];
    if (!act) return;

    AXUIElementRef w = copyFocusedWindow(NULL);
    if (w) { [self applyLayout:layout toWindow:w pid:pid]; CFRelease(w); }
}

#pragma mark - Drag preview overlay

- (void)showPreviewRect:(CGRect)cgRect {
    if (!self.preview) {
        NSWindow *p = [[NSWindow alloc] initWithContentRect:NSZeroRect
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        p.level = NSStatusWindowLevel;
        p.opaque = NO;
        p.backgroundColor = [NSColor clearColor];
        p.ignoresMouseEvents = YES;
        p.hasShadow = NO;
        p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorIgnoresCycle;
        NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
        v.wantsLayer = YES;
        v.layer.backgroundColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.22].CGColor;
        v.layer.borderColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.9].CGColor;
        v.layer.borderWidth = 2.0;
        v.layer.cornerRadius = 10.0;
        p.contentView = v;
        self.preview = p;
    }
    [self.preview setFrame:cgToCocoaRect(cgRect) display:YES];
    [self.preview orderFrontRegardless];
}

- (void)hidePreview { [self.preview orderOut:nil]; }

@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef e, void *ud) {
    (void)next;
    EventHotKeyID hk;
    if (GetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof hk, NULL, &hk) != noErr) return eventNotHandledErr;
    WindowManager *self = (__bridge WindowManager *)ud;
    UInt32 idx = hk.id;
    dispatch_async(dispatch_get_main_queue(), ^{ [self fireHotkeyIndex:idx]; });
    return noErr;
}
