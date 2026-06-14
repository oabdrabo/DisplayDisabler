#import "AppDelegate.h"
#import "DisplayManager.h"
#import "Brightness.h"
#import "HiDPIInjector.h"
#import "WindowTransparency.h"
#import "BrightnessBooster.h"
#import "Caffeine.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

static NSString * const kAutoManage        = @"AutoManageBuiltIn";
static NSString * const kShowNotifications = @"ShowNotifications";
static NSString * const kConfirmDisable    = @"ConfirmBeforeDisable";
static NSString * const kShowResolutions   = @"ShowResolutions";
static NSString * const kFrostedBlur        = @"FrostedBlur";

static NSString * const kAutoManageNotifID = @"auto-manage";

static const CGFloat kSwitchRowWidth   = 290;
static const CGFloat kSwitchRowHeight  = 28;
static const CGFloat kSwitchRowPad     = 18;
static const CGFloat kSwitchLabelGap   = 8;

static const NSUInteger kModeColLogical = 17;
static const NSUInteger kModeColType    = 10;

static const CGFloat kSliderRowWidth = 150;
static const NSInteger kSliderItemTag = 0x51D5;
static const void *kDDPctLabelKey = &kDDPctLabelKey;

static NSString *ddPad(NSString *s, NSUInteger length) {
    return [s stringByPaddingToLength:length withString:@" " startingAtIndex:0];
}

static NSString *ddRateString(double hz, NSString *fallback) {
    return hz > 0 ? [NSString stringWithFormat:@"%.0fHz", hz] : fallback;
}

static NSString *ddLogicalString(size_t w, size_t h) {
    return [NSString stringWithFormat:@"%zu \u00D7 %zu", w, h];
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

    [WindowTransparency shared].frostedBlur = [self pref:kFrostedBlur];
    [[WindowTransparency shared] ensureBackendLoaded];

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
        [strongSelf rebuildMenu];
        [strongSelf performAutoDisableIfNeeded];
        [strongSelf performAutoReenableIfNeeded];
    }];

    [self performAutoDisableIfNeeded];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
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
    NSMenu *settingsMenu = [[NSMenu alloc] init];
    settingsMenu.autoenablesItems = NO;
    settingsMenu.delegate = self;
    settingsItem.submenu = settingsMenu;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
        action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    [self sizeSliderRowsInMenu:menu];
}

- (void)addKeepAwakeSectionToMenu:(NSMenu *)menu {
    Caffeine *caf = [Caffeine shared];

    if (caf.active && caf.expiry) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.timeStyle = NSDateFormatterShortStyle;
        df.dateStyle = NSDateFormatterNoStyle;
        [self addLabelToMenu:menu title:
            [NSString stringWithFormat:@"Awake until %@", [df stringFromDate:caf.expiry]]];
    }

    NSMenuItem *forItem = [[NSMenuItem alloc] initWithTitle:@"Keep Awake for"
        action:nil keyEquivalent:@""];
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

    [menu addItem:[NSMenuItem separatorItem]];
}

- (void)keepAwakeFor:(NSMenuItem *)sender {
    [[Caffeine shared] activateForDuration:[sender.representedObject doubleValue]];
    [self rebuildMenu];
}

- (NSMenuItem *)actionItem:(NSString *)title action:(SEL)action displayID:(CGDirectDisplayID)did {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(did);
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
                                action:@selector(stopForcedHiDPI:) displayID:display.displayID]];
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
                                action:@selector(enableDisplay:) displayID:display.displayID]];
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
        [menu addItem:[self sliderRowWithLabel:@"Brightness" percent:shown minPct:10
                                        maxPct:maxPct continuous:YES tag:display.displayID
                                        action:@selector(brightnessSliderChanged:)
                                   pinnedState:-1]];
        if ([[Brightness shared] supportsAutoBrightness:display.displayID]) {
            NSMenuItem *auto_ = [[NSMenuItem alloc] initWithTitle:@"Auto-brightness"
                action:@selector(toggleAutoBrightness:) keyEquivalent:@""];
            auto_.target = self;
            auto_.tag = (NSInteger)display.displayID;
            auto_.state = [[Brightness shared] autoBrightnessEnabled:display.displayID]
                ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:auto_];
        }
    }
    if ([self pref:kShowResolutions]) {
        NSArray<DDDisplayMode *> *modes = [self.displayManager modesForDisplay:display.displayID];
        size_t lw = display.logicalWidth ?: display.pixelWidth;
        size_t lh = display.logicalHeight ?: display.pixelHeight;
        NSMutableString *rt = [NSMutableString stringWithString:@"Resolution"];
        if (lw) [rt appendFormat:@"   %@", ddLogicalString(lw, lh)];
        NSMenuItem *res = [[NSMenuItem alloc] initWithTitle:rt action:nil keyEquivalent:@""];
        res.submenu = [self buildModesSubmenuForDisplay:display.displayID modes:modes];
        [menu addItem:res];
    }
    if (NSClassFromString(@"CGVirtualDisplay") != nil) {
        NSArray<DDDisplayMode *> *options =
            [self.displayManager forceHiDPIOptionsForDisplay:display.displayID];
        if (options.count > 0) {
            NSMenuItem *fh = [[NSMenuItem alloc] initWithTitle:@"Force HiDPI" action:nil keyEquivalent:@""];
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
                         displayID:display.displayID]];
    [menu addItem:[self actionItem:@"Disable"
                            action:@selector(disableDisplay:) displayID:display.displayID]];
}

- (NSMenu *)buildForceHiDPISubmenuForDisplay:(CGDirectDisplayID)displayID
                                     options:(NSArray<DDDisplayMode *> *)options {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *mono     = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];

    DDDisplayMode *currentlyForced = [self.displayManager forcedTargetForDisplay:displayID];

    NSMenuItem * (^makeRow)(DDDisplayMode *) = ^NSMenuItem *(DDDisplayMode *mode) {
        BOOL isCurrent = (currentlyForced &&
                          currentlyForced.pixelWidth  == mode.pixelWidth &&
                          currentlyForced.pixelHeight == mode.pixelHeight);
        NSString *sizeCol = ddPad(ddLogicalString(mode.logicalWidth, mode.logicalHeight),
                                  kModeColLogical);
        NSString *rateStr = ddRateString(mode.refreshRate, @"");
        NSString *line = [NSString stringWithFormat:@"%@%@", sizeCol, rateStr];
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:line
                   action:isCurrent ? nil : @selector(forceHiDPIAtMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !isCurrent;
        item.representedObject = @{ @"displayID": @(displayID), @"mode": mode };
        item.attributedTitle = [[NSAttributedString alloc]
            initWithString:line
                attributes:@{NSFontAttributeName: isCurrent ? monoBold : mono}];
        if (isCurrent) item.state = NSControlStateValueOn;
        return item;
    };

    NSMenuItem *colHeader = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    colHeader.attributedTitle = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@%@",
                        ddPad(@"Looks Like", kModeColLogical), @"Rate"]
            attributes:@{NSFontAttributeName: monoBold}];
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
        [menu addItem:[self sliderRowWithLabel:app.name percent:pct minPct:20
                                        maxPct:100 continuous:YES tag:app.pid
                                        action:@selector(opacitySliderChanged:)
                                   pinnedState:(app.pinned ? 1 : 0)]];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self sliderRowWithLabel:@"All apps" percent:100 minPct:20
                                    maxPct:100 continuous:YES tag:0
                                    action:@selector(opacitySliderChanged:)
                               pinnedState:-1]];
    NSMenuItem *reset = [[NSMenuItem alloc]
        initWithTitle:@"Reset all (100%)"
               action:@selector(resetAllTransparency:) keyEquivalent:@""];
    reset.target = self;
    [menu addItem:reset];
}

- (void)stylePinButton:(NSButton *)b pinned:(BOOL)pinned {
    NSImageSymbolConfiguration *cfg =
        [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold];
    b.image = [[NSImage imageWithSystemSymbolName:(pinned ? @"pin.fill" : @"pin")
                            accessibilityDescription:@"Keep on top"]
               imageWithSymbolConfiguration:cfg];
    b.contentTintColor = pinned ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
    b.state = pinned ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NSMenuItem *)sliderRowWithLabel:(NSString *)label
                           percent:(int)pct
                            minPct:(int)minPct
                            maxPct:(int)maxPct
                        continuous:(BOOL)continuous
                               tag:(NSInteger)tag
                            action:(SEL)action
                       pinnedState:(int)pinnedState {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSliderRowWidth, 24)];

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

    NSButton *pin = nil;
    if (pinnedState >= 0) {
        pin = [NSButton buttonWithImage:[NSImage new] target:self
                                 action:@selector(togglePinApp:)];
        pin.bordered = NO;
        pin.imagePosition = NSImageOnly;
        [pin setButtonType:NSButtonTypePushOnPushOff];
        pin.tag = tag;
        pin.toolTip = @"Keep on top";
        pin.translatesAutoresizingMaskIntoConstraints = NO;
        [self stylePinButton:pin pinned:(pinnedState == 1)];
        [row addSubview:pin];
    }

    NSMutableArray<NSLayoutConstraint *> *constraints = [@[
        [row.heightAnchor constraintEqualToConstant:24],
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [name.widthAnchor constraintEqualToConstant:74],
        [slider.leadingAnchor constraintEqualToAnchor:name.trailingAnchor constant:8],
        [slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.leadingAnchor constraintEqualToAnchor:slider.trailingAnchor constant:8],
        [value.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [value.widthAnchor constraintGreaterThanOrEqualToConstant:30],
    ] mutableCopy];

    if (pin) {
        [constraints addObjectsFromArray:@[
            [pin.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
            [pin.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [pin.widthAnchor constraintEqualToConstant:18],
            [value.trailingAnchor constraintEqualToAnchor:pin.leadingAnchor constant:-7],
        ]];
    } else {
        [constraints addObject:
            [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14]];
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

- (void)toggleAutoBrightness:(NSMenuItem *)sender {
    CGDirectDisplayID did = (CGDirectDisplayID)sender.tag;
    BOOL newState = ![[Brightness shared] autoBrightnessEnabled:did];
    [[Brightness shared] setAutoBrightness:newState forDisplay:did];
    sender.state = newState ? NSControlStateValueOn : NSControlStateValueOff;
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
    BOOL nowPinned = (sender.state == NSControlStateValueOn);
    NSError *error = nil;
    [[WindowTransparency shared] setPinned:nowPinned forApp:(pid_t)sender.tag error:&error];
    [self stylePinButton:sender pinned:nowPinned];
    if (error) NSLog(@"DisplayDisabler: pin failed: %@", error);
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

    [menu addItem:[self switchRowWithTitle:
        @"Turn off laptop screen when external monitor is connected"
            state:[self pref:kAutoManage] identifier:kAutoManage
           action:@selector(switchToggled:)]];
    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItem:[self checkItemWithTitle:@"Show notifications"
                                       key:kShowNotifications]];
    [menu addItem:[self checkItemWithTitle:@"Ask before disabling a display"
                                       key:kConfirmDisable]];
    [menu addItem:[self checkItemWithTitle:@"Show all resolutions"
                                       key:kShowResolutions]];
    [menu addItem:[self checkItemWithTitle:@"Frosted glass (blur behind transparent windows)"
                                       key:kFrostedBlur]];
    [menu addItem:[NSMenuItem separatorItem]];

    BOOL loginEnabled = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled);
    [menu addItem:[self switchRowWithTitle:@"Launch at Login"
            state:loginEnabled identifier:nil
           action:@selector(loginSwitchToggled:)]];
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

- (NSMenuItem *)switchRowWithTitle:(NSString *)title
                             state:(BOOL)state
                        identifier:(nullable NSString *)identifier
                            action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] init];

    NSSwitch *sw = [[NSSwitch alloc] init];
    sw.controlSize = NSControlSizeMini;
    sw.translatesAutoresizingMaskIntoConstraints = YES;
    [sw sizeToFit];
    CGFloat switchWidth  = sw.frame.size.width;
    CGFloat switchHeight = sw.frame.size.height;

    CGFloat labelWidth = kSwitchRowWidth - (kSwitchRowPad * 2) - switchWidth - kSwitchLabelGap;
    NSFont *font = [NSFont menuFontOfSize:13];
    NSRect textRect = [title boundingRectWithSize:NSMakeSize(labelWidth, CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin
                                       attributes:@{NSFontAttributeName: font}];
    CGFloat labelHeight = ceil(textRect.size.height);
    CGFloat rowHeight = MAX(kSwitchRowHeight, labelHeight + 10);

    NSView *row = [[NSView alloc] initWithFrame:
                   NSMakeRect(0, 0, kSwitchRowWidth, rowHeight)];
    row.translatesAutoresizingMaskIntoConstraints = YES;
    row.autoresizesSubviews = NO;

    sw.frame = NSMakeRect(kSwitchRowWidth - kSwitchRowPad - switchWidth,
                          (rowHeight - switchHeight) / 2,
                          switchWidth, switchHeight);
    sw.state = state ? NSControlStateValueOn : NSControlStateValueOff;
    sw.target = self;
    sw.action = action;
    sw.identifier = identifier;
    sw.accessibilityLabel = title;
    [row addSubview:sw];

    NSTextField *label = [NSTextField labelWithString:title];
    label.translatesAutoresizingMaskIntoConstraints = YES;
    label.font = font;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    label.preferredMaxLayoutWidth = labelWidth;
    label.frame = NSMakeRect(kSwitchRowPad,
                             (rowHeight - labelHeight) / 2,
                             labelWidth, labelHeight);
    [row addSubview:label];

    item.view = row;
    return item;
}

- (NSMenu *)buildModesSubmenuForDisplay:(CGDirectDisplayID)displayID
                                  modes:(NSArray<DDDisplayMode *> *)modes {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *mono     = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];

    NSMenuItem *header = [[NSMenuItem alloc]
        initWithTitle:@"" action:nil keyEquivalent:@""];
    NSString *headerLine = [NSString stringWithFormat:@"%@%@%@",
        ddPad(@"Looks Like", kModeColLogical),
        ddPad(@"Type", kModeColType),
        @"Rate"];
    header.attributedTitle = [[NSAttributedString alloc]
        initWithString:headerLine
            attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11
                                                weight:NSFontWeightBold]}];
    header.enabled = NO;
    [submenu addItem:header];
    [submenu addItem:[NSMenuItem separatorItem]];

    for (DDDisplayMode *mode in modes) {
        NSString *rateStr = ddRateString(mode.refreshRate, @"--");
        NSString *logicalCol = ddPad(ddLogicalString(mode.logicalWidth, mode.logicalHeight),
                                     kModeColLogical);
        NSString *typeCol = ddPad(mode.isHiDPI ? @"HiDPI" : @"Standard", kModeColType);
        NSString *marker = mode.isDefaultForDisplay ? @"  ★" : @"";
        NSString *line = [NSString stringWithFormat:@"%@%@%@%@",
                          logicalCol, typeCol, rateStr, marker];

        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:line
                   action:mode.isCurrent ? nil : @selector(switchMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !mode.isCurrent;
        item.representedObject = @{
            @"mode": mode,
            @"displayID": @(displayID),
        };
        item.attributedTitle = [[NSAttributedString alloc]
            initWithString:line
                attributes:@{NSFontAttributeName: mode.isCurrent ? monoBold : mono}];
        if (mode.isCurrent) item.state = NSControlStateValueOn;
        [submenu addItem:item];
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    [self addLabelToMenu:submenu title:@"★ = panel-native (no scaling, crispest)"];

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

- (void)switchToggled:(NSSwitch *)sender {
    NSString *key = sender.identifier;
    [self flipPref:key];

    if ([key isEqualToString:kAutoManage] && [self pref:kAutoManage]) {
        [self performAutoDisableIfNeeded];
    }
}

- (void)loginSwitchToggled:(NSSwitch *)sender {
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
