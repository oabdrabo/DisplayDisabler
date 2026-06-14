#import "AppDelegate.h"
#import "DisplayManager.h"
#import "Brightness.h"
#import "HiDPIInjector.h"
#import "WindowTransparency.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

static NSString * const kAutoManage        = @"AutoManageBuiltIn";
static NSString * const kShowNotifications = @"ShowNotifications";
static NSString * const kConfirmDisable    = @"ConfirmBeforeDisable";
static NSString * const kShowResolutions   = @"ShowResolutions";

static NSString * const kAutoManageNotifID = @"auto-manage";

static const CGFloat kSwitchRowWidth   = 290;
static const CGFloat kSwitchRowHeight  = 28;
static const CGFloat kSwitchRowPad     = 18;
static const CGFloat kSwitchLabelGap   = 8;

static const NSUInteger kModeColLogical = 17;
static const NSUInteger kModeColType    = 10;

static const int kTransparencyLevels[] = {100, 90, 75, 50, 25};

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
@property (nonatomic, strong) DisplayManager *displayManager;
@property (nonatomic) BOOL notificationAuthRequested;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self registerDefaults];

    self.displayManager = [DisplayManager shared];

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
    self.statusItem.button.toolTip = @"DisplayDisabler";
    [self updateStatusIcon:NO];
}

- (void)updateStatusIcon:(BOOL)hasDisabledDisplay {
    NSString *symbolName = hasDisabledDisplay
        ? @"display.trianglebadge.exclamationmark"
        : @"display";

    NSImage *icon = [NSImage imageWithSystemSymbolName:symbolName
                               accessibilityDescription:@"DisplayDisabler"];
    [icon setTemplate:YES];
    self.statusItem.button.image = icon;
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    NSArray<DDDisplayInfo *> *displays = [self.displayManager allDisplays];
    NSUInteger activeCount = 0;
    BOOL anyDisabled = NO;
    for (DDDisplayInfo *d in displays) {
        BOOL effectivelyActive = d.isActive ||
            [self.displayManager isHiDPIForcedForDisplay:d.displayID];
        if (effectivelyActive) activeCount++;
        else                   anyDisabled = YES;
    }
    [self updateStatusIcon:anyDisabled];

    NSMenu *displaysSub = [[NSMenu alloc] init];
    displaysSub.autoenablesItems = NO;
    for (DDDisplayInfo *display in displays) {
        [self addDisplayRow:display toMenu:displaysSub];
    }
    NSMenuItem *displaysItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"Displays  (%lu of %lu active)",
                       (unsigned long)activeCount, (unsigned long)displays.count]
               action:nil keyEquivalent:@""];
    displaysItem.submenu = displaysSub;
    [menu addItem:displaysItem];

    NSMenu *transparencySub = [[NSMenu alloc] init];
    transparencySub.autoenablesItems = NO;
    [self addTransparencySectionToMenu:transparencySub];
    NSMenuItem *transparencyItem = [[NSMenuItem alloc]
        initWithTitle:@"Transparency" action:nil keyEquivalent:@""];
    transparencyItem.submenu = transparencySub;
    [menu addItem:transparencyItem];

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

    self.statusItem.menu = menu;
}

- (NSMenuItem *)actionItem:(NSString *)title action:(SEL)action displayID:(CGDirectDisplayID)did {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(did);
    return item;
}

- (void)addDisplayRow:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    BOOL forced = [self.displayManager isHiDPIForcedForDisplay:display.displayID];
    NSMutableString *title = [NSMutableString stringWithFormat:@"  %@", display.name];
    if (display.isActive && display.pixelWidth > 0) {
        [title appendFormat:@"   %@", ddLogicalString(display.pixelWidth, display.pixelHeight)];
    }
    NSString *state = forced ? @"HiDPI" : (display.isActive ? @"on" : @"off");
    [title appendFormat:@"   %@", state];

    NSMenuItem *row = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    row.submenu = [self displaySubmenuFor:display forced:forced];
    [menu addItem:row];
}

- (NSMenu *)displaySubmenuFor:(DDDisplayInfo *)display forced:(BOOL)forced {
    NSMenu *m = [[NSMenu alloc] init];
    m.autoenablesItems = NO;

    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    if (forced)                 [tags addObject:@"HiDPI forced"];
    else if (!display.isActive) [tags addObject:@"disabled"];
    if (display.isBuiltIn)      [tags addObject:@"built-in"];
    if (display.isMain)         [tags addObject:@"main"];
    if (display.isActive && display.refreshRate > 0)
        [tags addObject:[NSString stringWithFormat:@"%.0fHz", display.refreshRate]];
    if (tags.count > 0) {
        [self addLabelToMenu:m title:[tags componentsJoinedByString:@" \u00B7 "]];
        [m addItem:[NSMenuItem separatorItem]];
    }

    if (forced) {
        [m addItem:[self actionItem:@"Stop Forced HiDPI"
                             action:@selector(stopForcedHiDPI:) displayID:display.displayID]];
        return m;
    }
    if (!display.isActive) {
        [m addItem:[self actionItem:@"Enable"
                             action:@selector(enableDisplay:) displayID:display.displayID]];
        return m;
    }

    if ([self pref:kShowResolutions]) {
        NSArray<DDDisplayMode *> *modes = [self.displayManager modesForDisplay:display.displayID];
        NSMenuItem *res = [[NSMenuItem alloc] initWithTitle:@"Resolution" action:nil keyEquivalent:@""];
        res.submenu = [self buildModesSubmenuForDisplay:display.displayID modes:modes];
        [m addItem:res];
    }
    if (NSClassFromString(@"CGVirtualDisplay") != nil) {
        NSArray<DDDisplayMode *> *options =
            [self.displayManager forceHiDPIOptionsForDisplay:display.displayID];
        if (options.count > 0) {
            NSMenuItem *fh = [[NSMenuItem alloc] initWithTitle:@"Force HiDPI" action:nil keyEquivalent:@""];
            fh.submenu = [self buildForceHiDPISubmenuForDisplay:display.displayID options:options];
            [m addItem:fh];
        }
    }
    if ([[Brightness shared] supportsBrightness:display.displayID]) {
        int b = [[Brightness shared] brightnessPercentForDisplay:display.displayID];
        NSString *bt = b >= 0 ? [NSString stringWithFormat:@"Brightness   %d%%", b] : @"Brightness";
        NSMenuItem *br = [[NSMenuItem alloc] initWithTitle:bt action:nil keyEquivalent:@""];
        br.submenu = [self buildBrightnessSubmenuForDisplay:display.displayID];
        [m addItem:br];
    }

    BOOL installed = [[HiDPIInjector shared] isInstalledForDisplay:display.displayID];
    [m addItem:[self actionItem:(installed
                                 ? @"Remove Crisp HiDPI Overrides\u2026"
                                 : @"Install Crisp HiDPI (admin + reboot)\u2026")
                         action:(installed ? @selector(uninstallCrispHiDPI:)
                                           : @selector(installCrispHiDPI:))
                      displayID:display.displayID]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self actionItem:@"Disable"
                         action:@selector(disableDisplay:) displayID:display.displayID]];
    return m;
}

- (NSMenu *)buildBrightnessSubmenuForDisplay:(CGDirectDisplayID)displayID {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    int cur = [[Brightness shared] brightnessPercentForDisplay:displayID];
    if (cur >= 0) {
        [self addLabelToMenu:submenu
                       title:[NSString stringWithFormat:@"Currently %d%%", cur]];
        [submenu addItem:[NSMenuItem separatorItem]];
    }

    static const uint8_t levels[] = {10, 25, 50, 75, 100};
    for (size_t i = 0; i < sizeof levels / sizeof *levels; i++) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"%u%%", levels[i]]
                   action:@selector(setBrightness:)
            keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{ @"displayID": @(displayID),
                                    @"percent":   @(levels[i]) };
        if (cur >= 0 && abs((int)levels[i] - cur) <= 5) {
            item.state = NSControlStateValueOn;
        }
        [submenu addItem:item];
    }
    return submenu;
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
        NSString *suffix = app.windows.count > 1
            ? [NSString stringWithFormat:@"   (%lu win)", (unsigned long)app.windows.count]
            : @"";
        NSMenuItem *row = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"%@   %d%%%@", app.name, pct, suffix]
                   action:nil keyEquivalent:@""];
        row.submenu = [self transparencyLevelsMenuForPID:app.pid allWindows:NO current:pct];
        [menu addItem:row];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *all = [[NSMenuItem alloc]
        initWithTitle:@"All windows…" action:nil keyEquivalent:@""];
    all.submenu = [self transparencyLevelsMenuForPID:0 allWindows:YES current:-1];
    [menu addItem:all];

    NSMenuItem *reset = [[NSMenuItem alloc]
        initWithTitle:@"Reset all (100%)"
               action:@selector(resetAllTransparency:) keyEquivalent:@""];
    reset.target = self;
    [menu addItem:reset];
}

- (NSMenu *)transparencyLevelsMenuForPID:(pid_t)pid
                              allWindows:(BOOL)allWindows
                                 current:(int)current {
    NSMenu *m = [[NSMenu alloc] init];
    m.autoenablesItems = NO;
    for (size_t i = 0; i < sizeof kTransparencyLevels / sizeof *kTransparencyLevels; i++) {
        int pct = kTransparencyLevels[i];
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"%d%%", pct]
                   action:@selector(applyTransparency:) keyEquivalent:@""];
        item.target = self;
        if (!allWindows && abs(pct - current) <= 2) item.state = NSControlStateValueOn;
        item.representedObject = @{ @"pct": @(pct),
                                    @"pid": @(pid),
                                    @"all": @(allWindows) };
        [m addItem:item];
    }
    return m;
}

- (void)applyTransparency:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    float alpha = [info[@"pct"] intValue] / 100.0f;
    NSError *error = nil;
    BOOL ok = [info[@"all"] boolValue]
        ? [[WindowTransparency shared] setAlphaForAllWindows:alpha error:&error]
        : [[WindowTransparency shared] setAlpha:alpha forApp:[info[@"pid"] intValue] error:&error];
    if (!ok) {
        NSLog(@"DisplayDisabler: transparency failed: %@", error);
        [self postNotification:@"Transparency Failed" body:error.localizedDescription];
    }
    [self rebuildMenu];
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

- (void)setBrightness:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    CGDirectDisplayID did = [info[@"displayID"] unsignedIntValue];
    uint8_t pct = (uint8_t)[info[@"percent"] unsignedCharValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSError *error = nil;
    if ([[Brightness shared] setBrightnessPercent:pct forDisplay:did error:&error]) {
        [self postNotification:@"Brightness"
                          body:[NSString stringWithFormat:@"%@ set to %u%%.", name, pct]];
    } else {
        NSLog(@"DisplayDisabler: Failed to set brightness on 0x%X: %@", did, error);
        [self postNotification:@"Brightness Failed"
                          body:error.localizedDescription];
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
