#import "AppDelegate.h"
#import "DisplayManager.h"
#import "Brightness.h"
#import "HiDPIInjector.h"
#import "WindowTransparency.h"
#import "WindowPiP.h"
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
    }];

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
        if (error) NSLog(@"DisplayDisabler: Notification auth error: %@", error);
        if (granted) dispatch_async(dispatch_get_main_queue(), deliver);
    }];
}

- (void)setupStatusItems {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip =
        @"DisplayDisabler — click to keep awake, right-click for the menu";

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
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:16
                                                        weight:NSFontWeightRegular
                                                         scale:NSImageSymbolScaleMedium];
    NSImage *icon = [[NSImage imageWithSystemSymbolName:symbolName
                                accessibilityDescription:@"DisplayDisabler"]
                     imageWithSymbolConfiguration:cfg];
    [icon setTemplate:YES];
    self.statusItem.button.image = icon;
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

    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Transparency"]];
    [self addTransparencySectionToMenu:menu];

    [menu addItem:[NSMenuItem separatorItem]];

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

    NSMutableArray<DDDisplayMode *> *panelOpts = [NSMutableArray array];
    NSMutableArray<DDDisplayMode *> *synthOpts = [NSMutableArray array];
    for (DDDisplayMode *m in options) {
        if (m.modeRef != NULL) [panelOpts addObject:m];
        else                   [synthOpts addObject:m];
    }

    if (panelOpts.count > 0) {
        NSMenuItem *h = [[NSMenuItem alloc]
            initWithTitle:@"From panel modes" action:nil keyEquivalent:@""];
        h.enabled = NO;
        [submenu addItem:h];
        [submenu addItem:[NSMenuItem separatorItem]];
        for (DDDisplayMode *m in panelOpts) [submenu addItem:makeRow(m)];
    }

    if (synthOpts.count > 0) {
        if (panelOpts.count > 0) [submenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *h = [[NSMenuItem alloc]
            initWithTitle:@"Custom sizes" action:nil keyEquivalent:@""];
        h.enabled = NO;
        [submenu addItem:h];
        [submenu addItem:[NSMenuItem separatorItem]];
        for (DDDisplayMode *m in synthOpts) [submenu addItem:makeRow(m)];
    }

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
    b.image = ddTintedSymbol(offSymbol, [NSColor tertiaryLabelColor]);
    b.alternateImage = ddTintedSymbol(onSymbol, [NSColor controlAccentColor]);
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.tag = tag;
    b.toolTip = tooltip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
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
    if (error) NSLog(@"DisplayDisabler: transparency failed: %@", error);
}

- (void)toggleAutoBrightness:(NSButton *)sender {
    [[Brightness shared] setAutoBrightness:(sender.state == NSControlStateValueOn)
                                forDisplay:(CGDirectDisplayID)sender.tag];
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
    if (error) NSLog(@"DisplayDisabler: brightness failed: %@", error);
}

- (void)togglePinApp:(NSButton *)sender {
    NSError *error = nil;
    [[WindowTransparency shared] setPinned:(sender.state == NSControlStateValueOn)
                                    forApp:(pid_t)sender.tag error:&error];
    if (error) NSLog(@"DisplayDisabler: pin failed: %@", error);
}

- (void)togglePiPApp:(NSButton *)sender {
    WindowPiP *pip = [WindowPiP shared];
    if (![pip hasAccessibility]) {
        [pip requestAccessibility];
        sender.state = NSControlStateValueOff;
        return;
    }
    BOOL active = [pip toggleForApp:(pid_t)sender.tag];
    sender.state = active ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)resetAllTransparency:(NSMenuItem *)sender {
    (void)sender;
    NSError *error = nil;
    if (![[WindowTransparency shared] resetAllWindows:&error]) {
        NSLog(@"DisplayDisabler: reset transparency failed: %@", error);
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

- (NSArray<DDDisplayMode *> *)curatedModes:(NSArray<DDDisplayMode *> *)modes
                           includeNonHiDPI:(BOOL)includeNonHiDPI {
    NSMutableArray<DDDisplayMode *> *out = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *index = [NSMutableDictionary dictionary];
    for (DDDisplayMode *m in modes) {
        if (!includeNonHiDPI && !m.isHiDPI && !m.isCurrent) continue;
        NSString *key = [NSString stringWithFormat:@"%zux%zu_%d_%.0f",
                         m.logicalWidth, m.logicalHeight, (int)m.isHiDPI, m.refreshRate];
        NSNumber *at = index[key];
        if (at) {
            DDDisplayMode *existing = out[at.unsignedIntegerValue];
            if (m.pixelWidth > existing.pixelWidth) out[at.unsignedIntegerValue] = m;
        } else {
            index[key] = @(out.count);
            [out addObject:m];
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
        NSLog(@"DisplayDisabler: Failed to set mode: %@", error);
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
        NSLog(@"DisplayDisabler: Failed to disable 0x%X: %@", did, error);
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
        NSLog(@"DisplayDisabler: Failed to enable 0x%X: %@", did, error);
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
            NSLog(@"DisplayDisabler: Failed to force HiDPI for 0x%X: %@", did, error);
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
        NSLog(@"DisplayDisabler: Failed to stop forced HiDPI for 0x%X: %@", did, error);
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
            NSLog(@"DisplayDisabler: HiDPI install failed: %@", err);
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
            NSLog(@"DisplayDisabler: HiDPI uninstall failed: %@", err);
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
    if (asErr) NSLog(@"DisplayDisabler: restart script error: %@", asErr);
}

- (void)enableLoginItemOnFirstRun {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kDidSetupLogin]) return;
    [defaults setBool:YES forKey:kDidSetupLogin];

    SMAppService *service = [SMAppService mainAppService];
    if (service.status != SMAppServiceStatusEnabled) {
        NSError *error = nil;
        if (![service registerAndReturnError:&error]) {
            NSLog(@"DisplayDisabler: default login-item registration failed: %@", error);
        }
    }
}

- (void)toggleLoginItem:(NSMenuItem *)sender {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;

    if (service.status == SMAppServiceStatusEnabled) {
        if (![service unregisterAndReturnError:&error]) {
            NSLog(@"DisplayDisabler: Failed to unregister login item: %@", error);
        }
    } else {
        if (![service registerAndReturnError:&error]) {
            NSLog(@"DisplayDisabler: Failed to register login item: %@", error);
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
        NSLog(@"DisplayDisabler: Auto-disable failed: %@", error);
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
        NSLog(@"DisplayDisabler: Auto-reenable failed: %@", error);
    }
}

@end
