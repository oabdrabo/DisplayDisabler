#import "AppDelegate.h"
#import "DisplayManager.h"
#import "Brightness.h"
#import "HiDPIInjector.h"
#import "WindowTransparency.h"
#import "WindowPiP.h"
#import "WindowManager.h"
#import "RemoteAccess.h"
#import "BrightnessBooster.h"
#import "ColorTemperature.h"
#import "Caffeine.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

static NSString * const kAutoManage        = @"AutoManageBuiltIn";
static NSString * const kShowNotifications = @"ShowNotifications";
static NSString * const kConfirmDisable    = @"ConfirmBeforeDisable";
static NSString * const kShowResolutions   = @"ShowResolutions";
static NSString * const kFrostedBlur        = @"FrostedBlur";
static NSString * const kDidSetupLogin      = @"DidSetupLoginItem";
static NSString * const kSnapShortcuts      = @"WindowSnapShortcuts";
static NSString * const kSnapDrag           = @"WindowSnapDrag";

static NSString * const kAutoManageNotifID = @"auto-manage";


static const CGFloat kModeTabType = 112;
static const CGFloat kModeTabRate = 184;

static const CGFloat kSliderRowWidth = 150;
static const NSInteger kSliderItemTag = 0x51D5;
static const void *kDDPctLabelKey = &kDDPctLabelKey;

static NSString *ddRateString(double hz, NSString *fallback) {
    return hz > 0 ? [NSString stringWithFormat:@"%.0fHz", hz] : fallback;
}

static NSString *ddLogicalString(size_t w, size_t h) {
    return [NSString stringWithFormat:@"%zu \u00D7 %zu", w, h];
}

static NSImage *ddSymbol(NSString *name) {
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    NSImage *img = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
                    imageWithSymbolConfiguration:cfg];
    img.template = YES;
    return img;
}

static NSImage *ddTintedSymbol(NSString *name, NSColor *color) {
    NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration
        configurationWithPointSize:12 weight:NSFontWeightSemibold]
        configurationByApplyingConfiguration:
            [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
            imageWithSymbolConfiguration:cfg];
}

// A little "screen with the snapped region shaded" glyph for the Window menu,
// like Rectangle/Magnet. Template image: the faint full-screen rect (low alpha)
// reads as empty, the solid region (full alpha) is where the window goes — both
// tint with the menu text colour, so it adapts to light/dark. `r` is normalised
// (0..1, y-up = visually top).
static NSImage *ddSnapGlyph(CGRect r) {
    // 24×16 → inner screen 21×13 ≈ 16:10, matching a real Mac display (not the
    // wide ~16:9 the previous 26-wide size produced).
    NSImage *img = [NSImage imageWithSize:NSMakeSize(24, 16) flipped:NO
                            drawingHandler:^BOOL(NSRect dst) {
        NSRect screen = NSInsetRect(dst, 1.5, 1.5);
        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:screen xRadius:2.5 yRadius:2.5];
        [[NSColor colorWithWhite:0 alpha:0.30] set];
        [bg fill];
        bg.lineWidth = 1.0;
        [[NSColor colorWithWhite:0 alpha:0.55] set];
        [bg stroke];
        NSRect rr = NSMakeRect(screen.origin.x + r.origin.x * screen.size.width,
                               screen.origin.y + r.origin.y * screen.size.height,
                               r.size.width  * screen.size.width,
                               r.size.height * screen.size.height);
        rr = NSInsetRect(rr, 0.75, 0.75);
        [[NSColor colorWithWhite:0 alpha:1.0] set];
        [[NSBezierPath bezierPathWithRoundedRect:rr xRadius:1.5 yRadius:1.5] fill];
        return YES;
    }];
    img.template = YES;
    return img;
}

static NSImage *ddSnapGlyphForLayout(DDSnap l) {
    switch (l) {
        case DDSnapLeftHalf:       return ddSnapGlyph(CGRectMake(0,      0,   0.5,    1));
        case DDSnapRightHalf:      return ddSnapGlyph(CGRectMake(0.5,    0,   0.5,    1));
        case DDSnapTopHalf:        return ddSnapGlyph(CGRectMake(0,    0.5,     1,  0.5));
        case DDSnapBottomHalf:     return ddSnapGlyph(CGRectMake(0,      0,     1,  0.5));
        case DDSnapTopLeft:        return ddSnapGlyph(CGRectMake(0,    0.5,   0.5,  0.5));
        case DDSnapTopRight:       return ddSnapGlyph(CGRectMake(0.5,  0.5,   0.5,  0.5));
        case DDSnapBottomLeft:     return ddSnapGlyph(CGRectMake(0,      0,   0.5,  0.5));
        case DDSnapBottomRight:    return ddSnapGlyph(CGRectMake(0.5,    0,   0.5,  0.5));
        case DDSnapLeftThird:      return ddSnapGlyph(CGRectMake(0,      0, 1.0/3,    1));
        case DDSnapCenterThird:    return ddSnapGlyph(CGRectMake(1.0/3,  0, 1.0/3,    1));
        case DDSnapRightThird:     return ddSnapGlyph(CGRectMake(2.0/3,  0, 1.0/3,    1));
        case DDSnapLeftTwoThirds:  return ddSnapGlyph(CGRectMake(0,      0, 2.0/3,    1));
        case DDSnapRightTwoThirds: return ddSnapGlyph(CGRectMake(1.0/3,  0, 2.0/3,    1));
        case DDSnapMaximize:       return ddSnapGlyph(CGRectMake(0,      0,     1,    1));
        case DDSnapCenter:         return ddSnapGlyph(CGRectMake(0.22, 0.2,  0.56,  0.6));
        case DDSnapRestore:        return ddSymbol(@"arrow.uturn.backward");
    }
    return nil;
}

static const void *kDDOffSymKey = &kDDOffSymKey;
static const void *kDDOnSymKey  = &kDDOnSymKey;

// Reflect a row toggle's on/off state: accent-tinted "on" symbol when active,
// muted symbol when off. (alternateImage doesn't render reliably for the On
// state of a borderless image button, so we set the image explicitly.)
static void ddSetToggle(NSButton *b, BOOL on) {
    NSString *offSym = objc_getAssociatedObject(b, kDDOffSymKey);
    NSString *onSym  = objc_getAssociatedObject(b, kDDOnSymKey);
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.image = ddTintedSymbol(on ? onSym : offSym,
                             on ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor]);
}

static NSAttributedString *ddColumns(NSArray<NSString *> *cols, NSArray<NSNumber *> *tabs,
                                     NSFont *font, NSColor *color) {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    NSMutableArray<NSTextTab *> *stops = [NSMutableArray array];
    for (NSUInteger i = 0; i < tabs.count; i++) {
        [stops addObject:[[NSTextTab alloc] initWithType:NSLeftTabStopType
                                                location:tabs[i].doubleValue]];
    }
    ps.tabStops = stops;
    NSMutableDictionary *attrs = [@{ NSFontAttributeName: font,
                                     NSParagraphStyleAttributeName: ps } mutableCopy];
    if (color) attrs[NSForegroundColorAttributeName] = color;
    return [[NSAttributedString alloc]
            initWithString:[cols componentsJoinedByString:@"\t"] attributes:attrs];
}

@interface AppDelegate () <UNUserNotificationCenterDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *mainMenu;
@property (nonatomic, strong) DisplayManager *displayManager;
@property (nonatomic) BOOL notificationAuthRequested;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self registerDefaults];

    self.displayManager = [DisplayManager shared];

    [self enableLoginItemOnFirstRun];

    [WindowTransparency shared].frostedBlur = [self pref:kFrostedBlur];
    [[WindowTransparency shared] ensureBackendLoaded];

    [[ColorTemperature shared] reapply];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;

    [[WindowManager shared] setHotkeysEnabled:[self pref:kSnapShortcuts]];
    [[WindowManager shared] setDragSnapEnabled:[self pref:kSnapDrag]];

    [[RemoteAccess shared] restoreIfEnabled];

    [self setupStatusItems];
    [self rebuildMenu];

    __weak __typeof(self) weakSelf = self;
    [self.displayManager startMonitoringWithChangeHandler:^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.displayManager pruneStaleVirtualDisplays];
        [strongSelf.displayManager realignForcedDisplay];
        [[Brightness shared] invalidateServiceCache];
        [[BrightnessBooster shared] reapply];
        [[ColorTemperature shared] reapply];
        [strongSelf rebuildMenu];
        [strongSelf performAutoDisableIfNeeded];
        [strongSelf performAutoReenableIfNeeded];
        [strongSelf.displayManager recoverStrandedBuiltIn];
    }];

    [self.displayManager recoverStrandedBuiltIn];
    [self performAutoDisableIfNeeded];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [[ColorTemperature shared] restoreAll];
    [[WindowPiP shared] restoreAll];
    [self.displayManager cleanUpAllVirtualDisplays];
    [self.displayManager stopMonitoring];
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kAutoManage:        @NO,
        kShowNotifications: @YES,
        kConfirmDisable:    @YES,
        kShowResolutions:   @YES,
        kFrostedBlur:       @YES,
        kSnapShortcuts:     @YES,
        kSnapDrag:          @YES,
    }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center; (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)postNotification:(NSString *)title body:(NSString *)body {
    [self postNotification:title body:body identifier:[NSUUID UUID].UUIDString];
}

- (void)postNotification:(NSString *)title body:(NSString *)body identifier:(NSString *)identifier {
    if (![self pref:kShowNotifications]) return;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body  = body;
    content.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];

    dispatch_block_t deliver = ^{
        [UNUserNotificationCenter.currentNotificationCenter
            addNotificationRequest:request withCompletionHandler:nil];
    };

    if (self.notificationAuthRequested) {
        deliver();
        return;
    }
    self.notificationAuthRequested = YES;

    UNAuthorizationOptions opts = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:opts
                      completionHandler:^(BOOL granted, NSError *error) {
        if (error) NSLog(@"DisplayDeck: Notification auth error: %@", error);
        if (granted) dispatch_async(dispatch_get_main_queue(), deliver);
    }];
}

- (void)setupStatusItems {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip =
        @"DisplayDeck — click to keep awake, right-click for the menu";

    self.mainMenu = [[NSMenu alloc] init];
    self.mainMenu.autoenablesItems = NO;
    self.mainMenu.delegate = self;

    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    __weak __typeof(self) weakSelf = self;
    [Caffeine shared].onChange = ^{ [weakSelf updateStatusIcon]; };
    [self updateStatusIcon];
}

- (void)updateStatusIcon {
    BOOL awake = [Caffeine shared].active;
    NSString *symbolName = awake ? @"mug.fill" : @"mug";
    NSImage *icon = [NSImage imageWithSystemSymbolName:symbolName
                              accessibilityDescription:@"DisplayDeck"];
    [icon setTemplate:YES];

    // Scale the glyph to the *actual* menu-bar height instead of a fixed point
    // size, so it fits every Mac — notched or standard, internal or external —
    // and never looks oversized or clipped. ~58% of the bar thickness matches the
    // system's own menu-bar glyphs.
    CGFloat h = round([NSStatusBar systemStatusBar].thickness * 0.58);
    h = MAX(15, MIN(18, h));   // clamp to the standard menu-bar glyph range
    NSSize s = icon.size;
    if (s.height > 0) icon.size = NSMakeSize(round(s.width * h / s.height), h);

    NSStatusBarButton *button = self.statusItem.button;
    button.image = icon;
    button.imageScaling = NSImageScaleProportionallyDown;  // safety net: shrink, never crop
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    NSEvent *e = NSApp.currentEvent;
    BOOL menuClick = (e.type == NSEventTypeRightMouseUp) ||
                     (e.type == NSEventTypeLeftMouseUp &&
                      (e.modifierFlags & NSEventModifierFlagControl));
    if (menuClick) {
        self.statusItem.menu = self.mainMenu;
        [self.statusItem.button performClick:nil];
        self.statusItem.menu = nil;
    } else {
        [[Caffeine shared] toggle];
    }
}

- (void)rebuildMenu {
    [self populateMainMenu:self.mainMenu];
}

- (void)populateMainMenu:(NSMenu *)menu {
    [menu removeAllItems];

    [self addKeepAwakeSectionToMenu:menu];

    NSArray<DDDisplayInfo *> *displays = [self.displayManager allDisplays];
    for (DDDisplayInfo *display in displays) {
        [self addDisplaySectionToMenu:menu display:display];
    }

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Window"]];
    [self addWindowSectionToMenu:menu];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Remote"]];
    [self addRemoteSectionToMenu:menu];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Transparency"]];
    [self addTransparencySectionToMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self fontSmoothingRowItem]];

    NSMenuItem *settingsItem = [[NSMenuItem alloc]
        initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settingsItem.image = ddSymbol(@"gearshape");
    NSMenu *settingsMenu = [[NSMenu alloc] init];
    settingsMenu.autoenablesItems = NO;
    settingsMenu.delegate = self;
    settingsItem.submenu = settingsMenu;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
        action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    quit.image = ddSymbol(@"power");
    [menu addItem:quit];

    [self sizeSliderRowsInMenu:menu];
}

- (void)addKeepAwakeSectionToMenu:(NSMenu *)menu {
    Caffeine *caf = [Caffeine shared];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Keep Awake"]];

    if (caf.active && caf.expiry) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.timeStyle = NSDateFormatterShortStyle;
        df.dateStyle = NSDateFormatterNoStyle;
        [self addLabelToMenu:menu title:
            [NSString stringWithFormat:@"Awake until %@", [df stringFromDate:caf.expiry]]];
    }

    NSMenuItem *forItem = [[NSMenuItem alloc] initWithTitle:@"Keep Awake for"
        action:nil keyEquivalent:@""];
    forItem.image = ddSymbol(@"cup.and.saucer");
    NSMenu *durMenu = [[NSMenu alloc] init];
    durMenu.autoenablesItems = NO;
    NSArray *durations = @[ @[@"15 minutes", @900], @[@"30 minutes", @1800],
                            @[@"1 hour", @3600], @[@"2 hours", @7200], @[@"5 hours", @18000] ];
    for (NSArray *d in durations) {
        NSMenuItem *di = [[NSMenuItem alloc] initWithTitle:d[0]
            action:@selector(keepAwakeFor:) keyEquivalent:@""];
        di.target = self;
        di.representedObject = d[1];
        [durMenu addItem:di];
    }
    forItem.submenu = durMenu;
    [menu addItem:forItem];
}

- (void)keepAwakeFor:(NSMenuItem *)sender {
    [[Caffeine shared] activateForDuration:[sender.representedObject doubleValue]];
    [self rebuildMenu];
}

- (NSMenuItem *)actionItem:(NSString *)title action:(SEL)action
                 displayID:(CGDirectDisplayID)did symbol:(NSString *)symbol {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(did);
    if (symbol) item.image = ddSymbol(symbol);
    return item;
}

#pragma mark - Window management

- (NSMenuItem *)snapItem:(NSString *)title layout:(DDSnap)layout key:(NSString *)key {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title
                                                action:@selector(snapMenu:) keyEquivalent:key];
    it.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    it.target = self;
    it.representedObject = @(layout);
    it.image = ddSnapGlyphForLayout(layout);
    return it;
}

- (void)addWindowSectionToMenu:(NSMenu *)menu {
    if (![[WindowManager shared] hasAccessibility]) {
        NSMenuItem *grant = [[NSMenuItem alloc]
            initWithTitle:@"Enable Snapping…"
                   action:@selector(grantWindowAccess:) keyEquivalent:@""];
        grant.target = self;
        grant.image = ddSymbol(@"macwindow.badge.plus");
        grant.toolTip = @"Grant Accessibility permission to snap windows";
        [menu addItem:grant];
        return;
    }

    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Snap Window"
                                                  action:nil keyEquivalent:@""];
    root.image = ddSymbol(@"macwindow.on.rectangle");
    NSMenu *sm = [[NSMenu alloc] init];
    sm.autoenablesItems = NO;

    NSString *L = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    NSString *R = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSString *U = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
    NSString *D = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];

    [sm addItem:[self snapItem:@"Left Half"   layout:DDSnapLeftHalf   key:L]];
    [sm addItem:[self snapItem:@"Right Half"  layout:DDSnapRightHalf  key:R]];
    [sm addItem:[self snapItem:@"Top Half"    layout:DDSnapTopHalf    key:U]];
    [sm addItem:[self snapItem:@"Bottom Half" layout:DDSnapBottomHalf key:D]];
    [sm addItem:[NSMenuItem separatorItem]];
    [sm addItem:[self snapItem:@"Top Left"     layout:DDSnapTopLeft     key:@"u"]];
    [sm addItem:[self snapItem:@"Top Right"    layout:DDSnapTopRight    key:@"i"]];
    [sm addItem:[self snapItem:@"Bottom Left"  layout:DDSnapBottomLeft  key:@"j"]];
    [sm addItem:[self snapItem:@"Bottom Right" layout:DDSnapBottomRight key:@"k"]];
    [sm addItem:[NSMenuItem separatorItem]];
    [sm addItem:[self snapItem:@"Left Third"       layout:DDSnapLeftThird       key:@"d"]];
    [sm addItem:[self snapItem:@"Center Third"     layout:DDSnapCenterThird     key:@"f"]];
    [sm addItem:[self snapItem:@"Right Third"      layout:DDSnapRightThird      key:@"g"]];
    [sm addItem:[self snapItem:@"Left Two-Thirds"  layout:DDSnapLeftTwoThirds   key:@"e"]];
    [sm addItem:[self snapItem:@"Right Two-Thirds" layout:DDSnapRightTwoThirds  key:@"t"]];
    [sm addItem:[NSMenuItem separatorItem]];
    [sm addItem:[self snapItem:@"Maximize" layout:DDSnapMaximize key:@"\r"]];
    [sm addItem:[self snapItem:@"Center"   layout:DDSnapCenter   key:@"c"]];
    [sm addItem:[self snapItem:@"Restore"  layout:DDSnapRestore  key:@"z"]];

    root.submenu = sm;
    [menu addItem:root];
}

- (void)snapMenu:(NSMenuItem *)sender {
    [[WindowManager shared] snap:(DDSnap)[sender.representedObject integerValue]];
}

- (void)grantWindowAccess:(id)sender {
    (void)sender;
    [[WindowManager shared] requestAccessibility];
}

#pragma mark - Remote access

- (void)addRemoteSectionToMenu:(NSMenu *)menu {
    RemoteAccess *ra = [RemoteAccess shared];
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"Remote Access"
                                                  action:nil keyEquivalent:@""];
    root.image = ddSymbol(@"network");
    NSMenu *sm = [[NSMenu alloc] init];
    sm.autoenablesItems = NO;

    NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:@"Enabled"
        action:@selector(toggleRemoteAccess:) keyEquivalent:@""];
    toggle.target = self;
    toggle.state = ra.isEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [sm addItem:toggle];

    if (ra.isEnabled) {
        NSString *st = !ra.isConfigured ? @"⚠ Set a relay host below"
            : (ra.isConnected ? [NSString stringWithFormat:@"● Connected · relay port %d", ra.sshPort]
                              : @"○ Connecting…");
        NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:st action:nil keyEquivalent:@""];
        status.enabled = NO;
        [sm addItem:status];
    }

    // ---- Relay settings (editable) ----
    [sm addItem:[NSMenuItem separatorItem]];
    [sm addItem:[NSMenuItem sectionHeaderWithTitle:@"Relay"]];
    [sm addItem:[self relayItem:[NSString stringWithFormat:@"Host:  %@",
                    ra.relayHost.length ? ra.relayHost : @"(not set)"]
                         action:@selector(editRelayHost:)]];
    [sm addItem:[self relayItem:[NSString stringWithFormat:@"User:  %@", ra.relayUser]
                         action:@selector(editRelayUser:)]];
    [sm addItem:[self relayItem:[NSString stringWithFormat:@"SSH port:  %@", ra.relayPort]
                         action:@selector(editRelayPort:)]];

    // ---- Copy helpers ----
    [sm addItem:[NSMenuItem separatorItem]];
    NSMenuItem *cc = [[NSMenuItem alloc] initWithTitle:@"Copy connect command"
        action:@selector(copyRemoteConnect:) keyEquivalent:@""];
    cc.target = self; cc.image = ddSymbol(@"terminal"); [sm addItem:cc];
    NSMenuItem *ck = [[NSMenuItem alloc] initWithTitle:@"Copy public key"
        action:@selector(copyRemoteKey:) keyEquivalent:@""];
    ck.target = self; ck.image = ddSymbol(@"key"); [sm addItem:ck];
    NSMenuItem *al = [[NSMenuItem alloc] initWithTitle:@"Copy relay authorize line"
        action:@selector(copyRemoteAuthLine:) keyEquivalent:@""];
    al.target = self; al.image = ddSymbol(@"checkmark.shield"); [sm addItem:al];

    root.submenu = sm;
    [menu addItem:root];
}

- (NSMenuItem *)relayItem:(NSString *)title action:(SEL)action {
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    it.target = self;
    return it;
}

// Small modal text prompt (accessory app — activate first so it takes focus).
- (NSString *)promptValue:(NSString *)info default:(NSString *)def {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"DisplayDeck — Remote Access";
    alert.informativeText = info;
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = def ?: @"";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse r = [alert runModal];
    if (r != NSAlertFirstButtonReturn) return nil;
    return [field.stringValue stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)editRelayHost:(id)sender {
    (void)sender;
    NSString *v = [self promptValue:@"Relay host — an IP or domain you control (your always-on box):"
                            default:[RemoteAccess shared].relayHost];
    if (v) { [[RemoteAccess shared] setRelayHost:v]; [self rebuildMenu]; }
}
- (void)editRelayUser:(id)sender {
    (void)sender;
    NSString *v = [self promptValue:@"Relay SSH user (the forwarding-only account, e.g. tunnel):"
                            default:[RemoteAccess shared].relayUser];
    if (v) { [[RemoteAccess shared] setRelayUser:v]; [self rebuildMenu]; }
}
- (void)editRelayPort:(id)sender {
    (void)sender;
    NSString *v = [self promptValue:@"Relay SSH port (usually 22):"
                            default:[RemoteAccess shared].relayPort];
    if (v) { [[RemoteAccess shared] setRelayPort:v]; [self rebuildMenu]; }
}

- (void)toggleRemoteAccess:(id)sender {
    (void)sender;
    RemoteAccess *ra = [RemoteAccess shared];
    if (ra.isEnabled) { [ra disable]; } else { [ra enable]; }
    [self rebuildMenu];
}

- (void)copyToPasteboard:(NSString *)s {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:(s ?: @"") forType:NSPasteboardTypeString];
}
- (void)copyRemoteConnect:(id)sender  { (void)sender; [self copyToPasteboard:[RemoteAccess shared].connectCommand]; }
- (void)copyRemoteKey:(id)sender      { (void)sender; [self copyToPasteboard:[RemoteAccess shared].publicKey]; }
- (void)copyRemoteAuthLine:(id)sender { (void)sender; [self copyToPasteboard:[RemoteAccess shared].authorizeLine]; }

- (void)addDisplaySectionToMenu:(NSMenu *)menu display:(DDDisplayInfo *)display {
    BOOL forced = [self.displayManager isHiDPIForcedForDisplay:display.displayID];

    NSString *suffix;
    if (forced)                 suffix = @"  \u00B7  HiDPI forced";
    else if (!display.isActive) suffix = @"  \u00B7  off";
    else if (display.isHiDPI)   suffix = @"  \u00B7  HiDPI";
    else                        suffix = @"";
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:
        [display.name stringByAppendingString:suffix]]];

    if (forced) {
        [menu addItem:[self actionItem:@"Stop Forced HiDPI"
                                action:@selector(stopForcedHiDPI:) displayID:display.displayID
                                symbol:@"arrow.uturn.backward"]];
        return;
    }
    if (!display.isActive) {
        if (display.logicalWidth > 0) {
            NSMutableString *line = [NSMutableString stringWithFormat:@"   %@",
                ddLogicalString(display.logicalWidth, display.logicalHeight)];
            if (display.isHiDPI) [line appendString:@"  HiDPI"];
            if (display.refreshRate > 0) [line appendFormat:@" · %.0fHz", display.refreshRate];
            [self addLabelToMenu:menu title:line];
        }
        [menu addItem:[self actionItem:@"Enable"
                                action:@selector(enableDisplay:) displayID:display.displayID
                                symbol:@"power"]];
        return;
    }

    if ([[Brightness shared] supportsBrightness:display.displayID]) {
        int b = [[Brightness shared] brightnessPercentForDisplay:display.displayID];
        if (b < 0) b = 100;
        float boost = [[BrightnessBooster shared] boostForDisplay:display.displayID];
        int shown = boost > 1.0f ? (int)lroundf(boost * 100.0f) : b;
        int maxPct = (int)lroundf([[BrightnessBooster shared]
                                   maxBoostForDisplay:display.displayID] * 100.0f);
        if (maxPct < 100) maxPct = 100;
        if (shown > maxPct) shown = maxPct;
        NSButton *autoToggle = nil;
        if ([[Brightness shared] supportsAutoBrightness:display.displayID]) {
            autoToggle = [self rowToggleWithSymbol:@"a.circle" onSymbol:@"a.circle.fill"
                state:[[Brightness shared] autoBrightnessEnabled:display.displayID]
                  tag:(NSInteger)display.displayID
               action:@selector(toggleAutoBrightness:) tooltip:@"Auto-brightness"];
        }
        [menu addItem:[self sliderRowWithLabel:@"Brightness" icon:ddSymbol(@"sun.max")
                                       percent:shown minPct:10
                                        maxPct:maxPct continuous:YES tag:display.displayID
                                        action:@selector(brightnessSliderChanged:)
                                     accessories:(autoToggle ? @[autoToggle] : @[])]];
    }
    int warmth = (int)lroundf([[ColorTemperature shared]
                               warmthForDisplay:display.displayID] * 100.0f);
    [menu addItem:[self sliderRowWithLabel:@"Warmth" icon:ddSymbol(@"thermometer.sun")
                                   percent:warmth minPct:0
                                    maxPct:100 continuous:YES tag:display.displayID
                                    action:@selector(warmthSliderChanged:)
                                 accessories:@[]]];
    {
        NSArray<DDDisplayMode *> *modes =
            [self curatedModes:[self.displayManager modesForDisplay:display.displayID]
               includeNonHiDPI:[self pref:kShowResolutions]];
        size_t lw = display.logicalWidth ?: display.pixelWidth;
        size_t lh = display.logicalHeight ?: display.pixelHeight;
        NSMutableString *rt = [NSMutableString stringWithString:@"Resolution"];
        if (lw) [rt appendFormat:@"   %@", ddLogicalString(lw, lh)];
        NSMenuItem *res = [[NSMenuItem alloc] initWithTitle:rt action:nil keyEquivalent:@""];
        res.image = ddSymbol(@"rectangle.on.rectangle");
        res.submenu = [self buildModesSubmenuForDisplay:display.displayID modes:modes];
        [menu addItem:res];
    }
    if (NSClassFromString(@"CGVirtualDisplay") != nil) {
        NSArray<DDDisplayMode *> *options =
            [self.displayManager forceHiDPIOptionsForDisplay:display.displayID];
        if (options.count > 0) {
            NSMenuItem *fh = [[NSMenuItem alloc] initWithTitle:@"Force HiDPI" action:nil keyEquivalent:@""];
            fh.image = ddSymbol(@"arrow.up.left.and.arrow.down.right");
            fh.submenu = [self buildForceHiDPISubmenuForDisplay:display.displayID options:options];
            [menu addItem:fh];
        }
    }

    BOOL installed = [[HiDPIInjector shared] isInstalledForDisplay:display.displayID];
    [menu addItem:[self actionItem:(installed
                                    ? @"Remove Crisp HiDPI\u2026"
                                    : @"Install Crisp HiDPI\u2026")
                            action:(installed ? @selector(uninstallCrispHiDPI:)
                                              : @selector(installCrispHiDPI:))
                         displayID:display.displayID
                            symbol:@"sparkles"]];
    [menu addItem:[self actionItem:@"Disable"
                            action:@selector(disableDisplay:) displayID:display.displayID
                            symbol:@"power"]];
}

- (NSMenu *)buildForceHiDPISubmenuForDisplay:(CGDirectDisplayID)displayID
                                     options:(NSArray<DDDisplayMode *> *)options {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *font = [NSFont menuFontOfSize:13];
    NSFont *bold = [NSFont boldSystemFontOfSize:12];

    DDDisplayMode *currentlyForced = [self.displayManager forcedTargetForDisplay:displayID];

    NSMenuItem * (^makeRow)(DDDisplayMode *) = ^NSMenuItem *(DDDisplayMode *mode) {
        BOOL isCurrent = (currentlyForced &&
                          currentlyForced.pixelWidth  == mode.pixelWidth &&
                          currentlyForced.pixelHeight == mode.pixelHeight);
        NSString *size = ddLogicalString(mode.logicalWidth, mode.logicalHeight);
        NSString *rate = ddRateString(mode.refreshRate, @"");
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@""
                   action:isCurrent ? nil : @selector(forceHiDPIAtMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !isCurrent;
        item.representedObject = @{ @"displayID": @(displayID), @"mode": mode };
        item.attributedTitle = ddColumns(@[size, rate], @[@(kModeTabType)],
                                         isCurrent ? bold : font, nil);
        if (isCurrent) item.state = NSControlStateValueOn;
        return item;
    };

    NSMenuItem *colHeader = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    colHeader.attributedTitle = ddColumns(@[@"Looks Like", @"Rate"],
                                          @[@(kModeTabType)],
                                          bold, [NSColor secondaryLabelColor]);
    colHeader.enabled = NO;
    [submenu addItem:colHeader];
    [submenu addItem:[NSMenuItem separatorItem]];

    for (DDDisplayMode *m in options) [submenu addItem:makeRow(m)];

    return submenu;
}

- (void)addTransparencySectionToMenu:(NSMenu *)menu {
    WindowTransparency *wt = [WindowTransparency shared];

    if (![wt backendAvailable]) {
        [self addLabelToMenu:menu title:@"backend not loaded"];
        return;
    }

    NSArray<DDAppWindows *> *apps = [wt appsWithWindows];
    if (apps.count == 0) {
        [self addLabelToMenu:menu title:@"no windows"];
    }
    for (DDAppWindows *app in apps) {
        int pct = 100;
        for (DDWindow *w in app.windows) {
            int p = (int)lroundf(w.alpha * 100.0f);
            if (p < pct) pct = p;
        }
        NSImage *appIcon = [[NSRunningApplication
            runningApplicationWithProcessIdentifier:app.pid] icon];
        NSButton *pip = [self rowToggleWithSymbol:@"pip.enter" onSymbol:@"pip.exit"
            state:[[WindowPiP shared] isActiveForApp:app.pid] tag:app.pid
           action:@selector(togglePiPApp:) tooltip:@"Picture in picture"];
        NSButton *pin = [self rowToggleWithSymbol:@"pin" onSymbol:@"pin.fill"
            state:app.pinned tag:app.pid
           action:@selector(togglePinApp:) tooltip:@"Keep on top"];
        [menu addItem:[self sliderRowWithLabel:app.name icon:appIcon
                                       percent:pct minPct:20
                                        maxPct:100 continuous:YES tag:app.pid
                                        action:@selector(opacitySliderChanged:)
                                   accessories:@[pip, pin]]];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self sliderRowWithLabel:@"All apps" icon:ddSymbol(@"square.on.square")
                                   percent:100 minPct:20
                                    maxPct:100 continuous:YES tag:0
                                    action:@selector(opacitySliderChanged:)
                                 accessories:@[]]];
    NSMenuItem *reset = [[NSMenuItem alloc]
        initWithTitle:@"Reset all (100%)"
               action:@selector(resetAllTransparency:) keyEquivalent:@""];
    reset.target = self;
    reset.image = ddSymbol(@"arrow.counterclockwise");
    [menu addItem:reset];
}

- (NSButton *)rowToggleWithSymbol:(NSString *)offSymbol
                         onSymbol:(NSString *)onSymbol
                            state:(BOOL)on
                              tag:(NSInteger)tag
                           action:(SEL)action
                          tooltip:(NSString *)tooltip {
    NSButton *b = [NSButton buttonWithImage:[NSImage new] target:self action:action];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    [b setButtonType:NSButtonTypePushOnPushOff];
    objc_setAssociatedObject(b, kDDOffSymKey, offSymbol, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(b, kDDOnSymKey, onSymbol, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    b.tag = tag;
    b.toolTip = tooltip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    ddSetToggle(b, on);   // sets state + the correct tinted image
    return b;
}

- (NSMenuItem *)sliderRowWithLabel:(NSString *)label
                              icon:(NSImage *)icon
                           percent:(int)pct
                            minPct:(int)minPct
                            maxPct:(int)maxPct
                        continuous:(BOOL)continuous
                               tag:(NSInteger)tag
                            action:(SEL)action
                       accessories:(NSArray<NSButton *> *)accessories {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSliderRowWidth, 24)];

    NSImageView *iconView = nil;
    if (icon) {
        iconView = [NSImageView imageViewWithImage:icon];
        iconView.imageScaling = NSImageScaleProportionallyDown;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:iconView];
    }

    NSTextField *name = [NSTextField labelWithString:label];
    name.font = [NSFont menuFontOfSize:13];
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [name setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSSlider *slider = [NSSlider sliderWithValue:pct / 100.0
                                        minValue:minPct / 100.0
                                        maxValue:maxPct / 100.0
                                          target:self
                                          action:action];
    slider.continuous = continuous;
    slider.controlSize = NSControlSizeSmall;
    slider.tag = tag;
    slider.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *value = [NSTextField labelWithString:[NSString stringWithFormat:@"%d%%", pct]];
    value.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    value.textColor = [NSColor secondaryLabelColor];
    value.alignment = NSTextAlignmentRight;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    [value setContentHuggingPriority:NSLayoutPriorityRequired
                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    [row addSubview:name];
    [row addSubview:slider];
    [row addSubview:value];
    objc_setAssociatedObject(slider, kDDPctLabelKey, value, OBJC_ASSOCIATION_ASSIGN);

    for (NSButton *btn in accessories) [row addSubview:btn];

    NSMutableArray<NSLayoutConstraint *> *constraints = [@[
        [row.heightAnchor constraintEqualToConstant:24],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [name.widthAnchor constraintEqualToConstant:74],
        [slider.leadingAnchor constraintEqualToAnchor:name.trailingAnchor constant:8],
        [slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:8],
        [value.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.widthAnchor constraintGreaterThanOrEqualToConstant:30],
    ] mutableCopy];

    NSButton *leftmost = nil;
    NSButton *rightNeighbor = nil;
    for (NSInteger i = (NSInteger)accessories.count - 1; i >= 0; i--) {
        NSButton *btn = accessories[i];
        [constraints addObjectsFromArray:@[
            [btn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [btn.widthAnchor constraintEqualToConstant:18],
        ]];
        if (rightNeighbor) {
            [constraints addObject:
                [btn.trailingAnchor constraintEqualToAnchor:rightNeighbor.leadingAnchor constant:-4]];
        } else {
            [constraints addObject:
                [btn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12]];
        }
        rightNeighbor = btn;
        leftmost = btn;
    }
    if (leftmost) {
        [constraints addObject:
            [value.trailingAnchor constraintEqualToAnchor:leftmost.leadingAnchor constant:-7]];
    } else {
        [constraints addObject:
            [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14]];
    }

    if (iconView) {
        [constraints addObjectsFromArray:@[
            [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
            [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [iconView.widthAnchor constraintEqualToConstant:16],
            [iconView.heightAnchor constraintEqualToConstant:16],
            [name.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:7],
        ]];
    } else {
        [constraints addObject:
            [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14]];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.tag = kSliderItemTag;
    item.view = row;
    return item;
}

- (void)sizeSliderRowsInMenu:(NSMenu *)menu {
    CGFloat w = menu.size.width;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag != kSliderItemTag || !item.view) continue;
        NSRect f = item.view.frame;
        if (f.size.width == w) continue;
        f.size.width = w;
        item.view.frame = f;
        [item.view layoutSubtreeIfNeeded];
    }
}

- (void)syncSliderLabel:(NSSlider *)slider {
    NSTextField *value = objc_getAssociatedObject(slider, kDDPctLabelKey);
    value.stringValue = [NSString stringWithFormat:@"%d%%", (int)lround(slider.doubleValue * 100)];
}

- (void)opacitySliderChanged:(NSSlider *)sender {
    [self syncSliderLabel:sender];
    pid_t pid = (pid_t)sender.tag;
    NSError *error = nil;
    if (pid == 0) [[WindowTransparency shared] setAlphaForAllWindows:sender.floatValue error:&error];
    else          [[WindowTransparency shared] setAlpha:sender.floatValue forApp:pid error:&error];
    if (error) NSLog(@"DisplayDeck: transparency failed: %@", error);
}

- (void)toggleAutoBrightness:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    [[Brightness shared] setAutoBrightness:on forDisplay:(CGDirectDisplayID)sender.tag];
    ddSetToggle(sender, on);
}

- (void)warmthSliderChanged:(NSSlider *)sender {
    [self syncSliderLabel:sender];
    [[ColorTemperature shared] setWarmth:sender.floatValue
                              forDisplay:(CGDirectDisplayID)sender.tag];
}

- (void)brightnessSliderChanged:(NSSlider *)sender {
    double val = sender.doubleValue;
    if (fabs(val - 1.0) < 0.04) {
        val = 1.0;
        sender.doubleValue = 1.0;
    }
    [self syncSliderLabel:sender];
    CGDirectDisplayID did = (CGDirectDisplayID)sender.tag;
    NSError *error = nil;
    if (val <= 1.0) {
        [[BrightnessBooster shared] setBoost:1.0f forDisplay:did];
        [[Brightness shared] setBrightnessPercent:(uint8_t)lround(val * 100)
                                       forDisplay:did error:&error];
    } else {
        [[Brightness shared] setBrightnessPercent:100 forDisplay:did error:&error];
        [[BrightnessBooster shared] setBoost:(float)val forDisplay:did];
    }
    if (error) NSLog(@"DisplayDeck: brightness failed: %@", error);
}

- (void)togglePinApp:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    NSError *error = nil;
    [[WindowTransparency shared] setPinned:on forApp:(pid_t)sender.tag error:&error];
    if (error) NSLog(@"DisplayDeck: pin failed: %@", error);
    ddSetToggle(sender, on);
}

- (void)togglePiPApp:(NSButton *)sender {
    WindowPiP *pip = [WindowPiP shared];
    if (![pip hasAccessibility]) {
        [pip requestAccessibility];
        ddSetToggle(sender, NO);
        return;
    }
    BOOL active = [pip toggleForApp:(pid_t)sender.tag];
    ddSetToggle(sender, active);
}

- (void)resetAllTransparency:(NSMenuItem *)sender {
    (void)sender;
    NSError *error = nil;
    if (![[WindowTransparency shared] resetAllWindows:&error]) {
        NSLog(@"DisplayDeck: reset transparency failed: %@", error);
    }
    [self rebuildMenu];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.mainMenu) {
        [self populateMainMenu:menu];
        return;
    }

    [menu removeAllItems];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"General"]];
    [menu addItem:[self checkItemWithTitle:@"Show notifications" key:kShowNotifications]];
    [menu addItem:[self checkItemWithTitle:@"Confirm before disabling" key:kConfirmDisable]];
    [menu addItem:[self checkItemWithTitle:@"Show non-HiDPI resolutions" key:kShowResolutions]];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Display"]];
    [menu addItem:[self checkItemWithTitle:@"Turn off built-in with external display"
                                       key:kAutoManage]];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Transparency"]];
    [menu addItem:[self checkItemWithTitle:@"Frosted glass blur" key:kFrostedBlur]];

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Window"]];
    [menu addItem:[self checkItemWithTitle:@"Snap by dragging to screen edges" key:kSnapDrag]];
    [menu addItem:[self checkItemWithTitle:@"Keyboard shortcuts (⌃⌥ + keys)" key:kSnapShortcuts]];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
        action:@selector(toggleLoginItem:) keyEquivalent:@""];
    login.target = self;
    login.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
        ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];
}

- (NSMenuItem *)checkItemWithTitle:(NSString *)title key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:@selector(toggleCheckSetting:)
                                          keyEquivalent:@""];
    item.target = self;
    item.representedObject = key;
    item.state = [self pref:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

// ---- macOS font smoothing (AppleFontSmoothing, current-host global domain) ----
// Bumps grayscale antialiasing strength so text isn't thin/fuzzy on external,
// non-Retina, or scaled displays. Read by apps at launch → needs a re-login.

- (NSInteger)currentFontSmoothing {
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("AppleFontSmoothing"),
        kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    NSInteger n = -1;  // -1 = key absent (system default)
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)v, kCFNumberNSIntegerType, &n);
        CFRelease(v);
    }
    return n;
}

- (void)applyFontSmoothing:(NSInteger)level {
    CFStringRef key = CFSTR("AppleFontSmoothing");
    if (level < 0) {
        CFPreferencesSetValue(key, NULL, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    } else {
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberNSIntegerType, &level);
        CFPreferencesSetValue(key, num, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
        CFRelease(num);
    }
    CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                             kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

- (void)fontSmoothingSegmentChanged:(NSSegmentedControl *)seg {
    [self applyFontSmoothing:seg.selectedSegment];   // 0 = Off … 3 = Strong
}

// Inline segmented row: "Text smoothing  [ Off · Light · Medium · Strong ]".
- (NSMenuItem *)fontSmoothingRowItem {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSliderRowWidth, 28)];

    NSImageView *iconView = [NSImageView imageViewWithImage:ddSymbol(@"textformat.size")];
    iconView.imageScaling = NSImageScaleProportionallyDown;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:iconView];

    NSTextField *name = [NSTextField labelWithString:@"Text smoothing"];
    name.font = [NSFont menuFontOfSize:13];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [name setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addSubview:name];

    NSSegmentedControl *seg = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Off", @"Light", @"Medium", @"Strong"]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self action:@selector(fontSmoothingSegmentChanged:)];
    seg.controlSize = NSControlSizeMini;
    seg.segmentStyle = NSSegmentStyleRounded;
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    NSInteger cur = [self currentFontSmoothing];
    seg.selectedSegment = (cur >= 0 && cur <= 3) ? cur : -1;   // unset → nothing selected
    seg.toolTip = @"Log out and back in for the change to take effect";
    [row addSubview:seg];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:28],
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:16],
        [iconView.heightAnchor constraintEqualToConstant:16],
        [name.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:7],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [seg.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:10],
        [seg.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [seg.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.tag = kSliderItemTag;   // sized to the menu width like the slider rows
    item.view = row;
    return item;
}

- (NSArray<DDDisplayMode *> *)curatedModes:(NSArray<DDDisplayMode *> *)modes
                           includeNonHiDPI:(BOOL)includeNonHiDPI {
    NSMutableArray<DDDisplayMode *> *out = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *index = [NSMutableDictionary dictionary];
    for (DDDisplayMode *m in modes) {
        if (!m.isCurrent) {
            if (!includeNonHiDPI && !m.isHiDPI) continue;
            if (m.logicalWidth < 1024) continue;
        }
        NSString *key = [NSString stringWithFormat:@"%zux%zu_%d",
                         m.logicalWidth, m.logicalHeight, (int)m.isHiDPI];
        NSNumber *at = index[key];
        if (!at) {
            index[key] = @(out.count);
            [out addObject:m];
            continue;
        }
        DDDisplayMode *existing = out[at.unsignedIntegerValue];
        if (existing.isCurrent) continue;
        if (m.isCurrent ||
            m.refreshRate > existing.refreshRate ||
            (m.refreshRate == existing.refreshRate && m.pixelWidth > existing.pixelWidth)) {
            out[at.unsignedIntegerValue] = m;
        }
    }
    return out;
}

- (NSMenu *)buildModesSubmenuForDisplay:(CGDirectDisplayID)displayID
                                  modes:(NSArray<DDDisplayMode *> *)modes {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *font = [NSFont menuFontOfSize:13];
    NSFont *bold = [NSFont boldSystemFontOfSize:12];

    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    header.attributedTitle = ddColumns(@[@"Looks Like", @"Type", @"Rate"], @[@(kModeTabType), @(kModeTabRate)],
                                       bold, [NSColor secondaryLabelColor]);
    header.enabled = NO;
    [submenu addItem:header];
    [submenu addItem:[NSMenuItem separatorItem]];

    for (DDDisplayMode *mode in modes) {
        NSString *rate = ddRateString(mode.refreshRate, @"—");
        if (mode.isDefaultForDisplay) rate = [rate stringByAppendingString:@"  ★"];
        NSString *type = mode.isHiDPI ? @"HiDPI" : @"Standard";
        NSString *logical = ddLogicalString(mode.logicalWidth, mode.logicalHeight);

        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@""
                   action:mode.isCurrent ? nil : @selector(switchMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !mode.isCurrent;
        item.representedObject = @{ @"mode": mode, @"displayID": @(displayID) };
        item.attributedTitle = ddColumns(@[logical, type, rate], @[@(kModeTabType), @(kModeTabRate)],
                                         mode.isCurrent ? bold : font, nil);
        if (mode.isCurrent) item.state = NSControlStateValueOn;
        [submenu addItem:item];
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    [self addLabelToMenu:submenu title:@"★ = panel-native (crispest)"];

    return submenu;
}

- (void)addLabelToMenu:(NSMenu *)menu title:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:nil
                                          keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];
}

- (BOOL)pref:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

- (void)flipPref:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:![defaults boolForKey:key] forKey:key];
}

- (void)switchMode:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    DDDisplayMode *mode = info[@"mode"];
    CGDirectDisplayID did = [info[@"displayID"] unsignedIntValue];

    NSError *error = nil;
    if ([self.displayManager setMode:mode forDisplay:did error:&error]) {
        NSString *label = mode.isHiDPI ? @"HiDPI" : @"Standard";
        NSMutableString *body = [NSMutableString stringWithFormat:
            @"%zu \u00D7 %zu %@", mode.pixelWidth, mode.pixelHeight, label];
        if (mode.refreshRate > 0) {
            [body appendFormat:@" %.0fHz", mode.refreshRate];
        }
        [self postNotification:@"Resolution Changed" body:body];
    } else {
        NSLog(@"DisplayDeck: Failed to set mode: %@", error);
        [self postNotification:@"Resolution Change Failed"
                          body:error.localizedDescription];
    }
}

- (void)disableDisplay:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSUInteger activeCount = 0;
    for (DDDisplayInfo *d in [self.displayManager allDisplays]) {
        if (d.isActive) activeCount++;
    }
    if (activeCount <= 1) {
        [self postNotification:@"Cannot Disable"
                          body:@"Refusing to disable the only active display."];
        return;
    }

    if ([self pref:kConfirmDisable] &&
        ![self confirmDestructive:[NSString stringWithFormat:@"Disable \"%@\"?", name]
                             info:@"You can re-enable it from this menu."
                       actionName:@"Disable"]) {
        return;
    }

    NSError *error = nil;
    if ([self.displayManager disableDisplay:did error:&error]) {
        [self postNotification:@"Display Disabled"
                          body:[NSString stringWithFormat:@"%@ has been disabled.", name]];
    } else {
        NSLog(@"DisplayDeck: Failed to disable 0x%X: %@", did, error);
        [self postNotification:@"Disable Failed"
                          body:error.localizedDescription];
    }
}

- (void)enableDisplay:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];
    NSError *error = nil;
    if ([self.displayManager enableDisplay:did error:&error]) {
        [self postNotification:@"Display Enabled"
                          body:[NSString stringWithFormat:@"%@ has been enabled.", name]];
    } else {
        NSLog(@"DisplayDeck: Failed to enable 0x%X: %@", did, error);
        [self postNotification:@"Enable Failed"
                          body:error.localizedDescription];
    }
}

- (void)forceHiDPIAtMode:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    DDDisplayMode *mode = info[@"mode"];
    CGDirectDisplayID did = [info[@"displayID"] unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    __weak __typeof(self) weakSelf = self;
    [self.displayManager forceHiDPIForDisplay:did atMode:mode
                                   completion:^(BOOL success, NSError *error) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            NSMutableString *body = [NSMutableString stringWithFormat:
                @"HiDPI enabled for %@ at %zu \u00D7 %zu.",
                name, mode.pixelWidth, mode.pixelHeight];
            [strongSelf postNotification:@"HiDPI Forced" body:body];
            [strongSelf rebuildMenu];
        } else {
            NSLog(@"DisplayDeck: Failed to force HiDPI for 0x%X: %@", did, error);
            [strongSelf postNotification:@"Force HiDPI Failed"
                                    body:error.localizedDescription];
        }
    }];
}

- (void)stopForcedHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSError *error = nil;
    if ([self.displayManager stopForcedHiDPIForDisplay:did error:&error]) {
        [self postNotification:@"HiDPI Stopped"
                          body:[NSString stringWithFormat:
                                @"Restored native rendering for %@.", name]];
        [self rebuildMenu];
    } else {
        NSLog(@"DisplayDeck: Failed to stop forced HiDPI for 0x%X: %@", did, error);
    }
}

- (void)installCrispHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSArray<NSValue *> *presets = [[HiDPIInjector shared] defaultResolutionsForDisplay:did];

    NSMutableString *list = [NSMutableString string];
    for (NSValue *v in presets) {
        NSSize s = v.sizeValue;
        [list appendFormat:@"  \u2022 %d \u00D7 %d\n", (int)s.width, (int)s.height];
    }

    [NSApp activate];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:
        @"Install crisp HiDPI on \"%@\"?", name];
    alert.informativeText = [NSString stringWithFormat:
        @"Writes /Library/Displays/…/DisplayVendorID-%x/DisplayProductID-%x "
        @"with these logical resolutions as native HiDPI modes:\n\n%@\n"
        @"Requires your admin password and a reboot to activate. You can undo "
        @"via the same menu afterwards.",
        CGDisplayVendorNumber(did), CGDisplayModelNumber(did), list];
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    __weak __typeof(self) weakSelf = self;
    [[HiDPIInjector shared] installForDisplay:did resolutions:presets
                                   completion:^(BOOL ok, NSError *err) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ok) {
            NSLog(@"DisplayDeck: HiDPI install failed: %@", err);
            if (err.code != -128) {
                [strongSelf postNotification:@"Install Failed"
                                        body:err.localizedDescription];
            }
            return;
        }
        [strongSelf rebuildMenu];
        [strongSelf offerRebootWithMessage:
            [NSString stringWithFormat:
             @"Crisp HiDPI overrides installed for \"%@\".", name]];
    }];
}

- (void)uninstallCrispHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    if (![self confirmDestructive:[NSString stringWithFormat:
                                   @"Remove crisp HiDPI overrides for \"%@\"?", name]
                             info:@"Requires admin password. A reboot is needed "
                                  @"to fully revert to macOS defaults."
                       actionName:@"Remove"]) {
        return;
    }

    __weak __typeof(self) weakSelf = self;
    [[HiDPIInjector shared] uninstallForDisplay:did
                                     completion:^(BOOL ok, NSError *err) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ok) {
            NSLog(@"DisplayDeck: HiDPI uninstall failed: %@", err);
            if (err.code != -128) {
                [strongSelf postNotification:@"Remove Failed"
                                        body:err.localizedDescription];
            }
            return;
        }
        [strongSelf rebuildMenu];
        [strongSelf offerRebootWithMessage:
            [NSString stringWithFormat:
             @"Crisp HiDPI overrides removed for \"%@\".", name]];
    }];
}

- (void)offerRebootWithMessage:(NSString *)message {
    [NSApp activate];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = @"The change applies only after a reboot. Would you "
                             @"like to restart now?";
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:
        @"tell application \"System Events\" to restart"];
    NSDictionary *asErr = nil;
    [as executeAndReturnError:&asErr];
    if (asErr) NSLog(@"DisplayDeck: restart script error: %@", asErr);
}

- (void)enableLoginItemOnFirstRun {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kDidSetupLogin]) return;
    [defaults setBool:YES forKey:kDidSetupLogin];

    SMAppService *service = [SMAppService mainAppService];
    if (service.status != SMAppServiceStatusEnabled) {
        NSError *error = nil;
        if (![service registerAndReturnError:&error]) {
            NSLog(@"DisplayDeck: default login-item registration failed: %@", error);
        }
    }
}

- (void)toggleLoginItem:(NSMenuItem *)sender {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;

    if (service.status == SMAppServiceStatusEnabled) {
        if (![service unregisterAndReturnError:&error]) {
            NSLog(@"DisplayDeck: Failed to unregister login item: %@", error);
        }
    } else {
        if (![service registerAndReturnError:&error]) {
            NSLog(@"DisplayDeck: Failed to register login item: %@", error);
            if (service.status == SMAppServiceStatusRequiresApproval) {
                [SMAppService openSystemSettingsLoginItems];
            }
        }
    }

    sender.state = (service.status == SMAppServiceStatusEnabled)
                   ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleCheckSetting:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    [self flipPref:key];
    sender.state = [self pref:key] ? NSControlStateValueOn : NSControlStateValueOff;
    if ([key isEqualToString:kShowResolutions]) [self rebuildMenu];
    if ([key isEqualToString:kAutoManage] && [self pref:kAutoManage]) {
        [self performAutoDisableIfNeeded];
    }
    if ([key isEqualToString:kFrostedBlur]) {
        [WindowTransparency shared].frostedBlur = [self pref:kFrostedBlur];
        [[WindowTransparency shared] reapplyBlurForAllWindows];
    }
    if ([key isEqualToString:kSnapDrag]) {
        [[WindowManager shared] setDragSnapEnabled:[self pref:kSnapDrag]];
    }
    if ([key isEqualToString:kSnapShortcuts]) {
        [[WindowManager shared] setHotkeysEnabled:[self pref:kSnapShortcuts]];
    }
}

- (BOOL)confirmDestructive:(NSString *)message
                      info:(NSString *)info
                actionName:(NSString *)actionName {
    [NSApp activate];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:actionName];
    [alert addButtonWithTitle:@"Cancel"];

    return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)performAutoDisableIfNeeded {
    if (![self pref:kAutoManage]) return;

    DDDisplayInfo *builtIn = [self.displayManager builtInDisplay];
    if (!builtIn || !builtIn.isActive) return;
    if (![self.displayManager hasExternalDisplay]) return;

    NSError *error = nil;
    if ([self.displayManager disableDisplay:builtIn.displayID error:&error]) {
        [self postNotification:@"Built-in Display Disabled"
                          body:@"External monitor detected."
                    identifier:kAutoManageNotifID];
    } else {
        NSLog(@"DisplayDeck: Auto-disable failed: %@", error);
    }
}

- (void)performAutoReenableIfNeeded {
    if (![self pref:kAutoManage]) return;

    DDDisplayInfo *builtIn = [self.displayManager builtInDisplay];
    if (!builtIn) return;
    if (builtIn.isActive) return;
    if ([self.displayManager hasExternalDisplay]) return;

    NSError *error = nil;
    if ([self.displayManager enableDisplay:builtIn.displayID error:&error]) {
        [self postNotification:@"Built-in Display Re-enabled"
                          body:@"No external monitor detected."
                    identifier:kAutoManageNotifID];
    } else {
        NSLog(@"DisplayDeck: Auto-reenable failed: %@", error);
    }
}

@end
