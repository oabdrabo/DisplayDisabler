/*
 * AppDelegate.m — Menu bar application delegate
 * Part of DisplayDisabler v3.0
 */

#import "AppDelegate.h"
#import "DisplayManager.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

#define APP_VERSION "3.0"

// ── UserDefaults keys ───────────────────────────────────────────────────────

static NSString * const kAutoManage        = @"AutoManageBuiltIn";
static NSString * const kShowNotifications = @"ShowNotifications";
static NSString * const kConfirmDisable    = @"ConfirmBeforeDisable";
static NSString * const kShowResolutions   = @"ShowResolutions";

// ── Switch row layout constants ─────────────────────────────────────────────

static const CGFloat kSwitchRowWidth  = 290;
static const CGFloat kSwitchRowHeight = 28;
static const CGFloat kSwitchRowPad    = 18;

@interface AppDelegate () <UNUserNotificationCenterDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) DisplayManager *displayManager;
@end

@implementation AppDelegate

// ── Lifecycle ───────────────────────────────────────────────────────────────

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self registerDefaults];

    self.displayManager = [DisplayManager shared];
    [self setupStatusItem];
    [self setupNotifications];
    [self rebuildMenu];

    __weak typeof(self) weakSelf = self;
    [self.displayManager startMonitoringWithChangeHandler:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.displayManager pruneStaleVirtualDisplays];
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
        kConfirmDisable:    @NO,
        kShowResolutions:   @YES,
    }];
}

// ── Notifications ───────────────────────────────────────────────────────────

- (void)setupNotifications {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted __unused, NSError *error) {
        if (error) NSLog(@"DisplayDisabler: Notification auth error: %@", error);
    }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center; (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)postNotification:(NSString *)title body:(NSString *)body {
    if (![self pref:kShowNotifications]) return;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];

    NSString *identifier = [[NSUUID UUID] UUIDString];
    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:nil];
}

// ── Status item ─────────────────────────────────────────────────────────────

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];

    NSImage *icon = [NSImage imageWithSystemSymbolName:@"display"
                               accessibilityDescription:@"DisplayDisabler"];
    [icon setTemplate:YES];
    self.statusItem.button.image = icon;
    self.statusItem.button.toolTip = @"DisplayDisabler";
}

// ── Menu building ───────────────────────────────────────────────────────────

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    NSArray<DDDisplayInfo *> *displays = [self.displayManager allDisplays];
    NSUInteger activeCount = 0;
    for (DDDisplayInfo *d in displays) {
        if (d.isActive || [self.displayManager isHiDPIForcedForDisplay:d.displayID])
            activeCount++;
    }

    [self addLabelToMenu:menu title:
        [NSString stringWithFormat:@"DisplayDisabler v%s", APP_VERSION]];
    [self addLabelToMenu:menu title:
        [NSString stringWithFormat:@"%lu connected, %lu active",
         (unsigned long)displays.count, (unsigned long)activeCount]];

    [menu addItem:[NSMenuItem separatorItem]];

    for (DDDisplayInfo *display in displays) {
        [self addDisplaySection:display toMenu:menu];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *settingsItem = [[NSMenuItem alloc]
        initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settingsItem.submenu = [self buildSettingsSubmenu];
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit DisplayDisabler"
               action:@selector(terminate:)
        keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

// ── Per-display menu section ────────────────────────────────────────────────

- (void)addDisplaySection:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    [self addDisplayHeader:display toMenu:menu];

    if ([self.displayManager isHiDPIForcedForDisplay:display.displayID]) {
        [self addForcedHiDPIControls:display toMenu:menu];
    } else if (display.isActive) {
        [self addActiveDisplayControls:display toMenu:menu];
    } else {
        [self addDisabledDisplayControls:display toMenu:menu];
    }
}

- (void)addDisplayHeader:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    BOOL effectivelyActive = display.isActive ||
        [self.displayManager isHiDPIForcedForDisplay:display.displayID];
    NSString *dot = effectivelyActive ? @"\u25CF " : @"\u25CB ";
    NSString *title = [NSString stringWithFormat:@"%@%@ \u2014 0x%X",
                       dot, display.name, display.displayID];

    NSMenuItem *nameItem = [[NSMenuItem alloc] initWithTitle:title
                                                      action:nil keyEquivalent:@""];
    nameItem.enabled = NO;
    nameItem.attributedTitle = [[NSAttributedString alloc]
        initWithString:title
            attributes:@{NSFontAttributeName: [NSFont menuBarFontOfSize:14]}];
    [menu addItem:nameItem];

    // Tags line
    NSMutableArray *tags = [NSMutableArray array];
    if ([self.displayManager isHiDPIForcedForDisplay:display.displayID])
        [tags addObject:@"HiDPI forced"];
    else
        [tags addObject:display.isActive ? @"active" : @"disabled"];
    if (display.isBuiltIn) [tags addObject:@"built-in"];
    if (display.isMain) [tags addObject:@"main"];

    [self addLabelToMenu:menu title:
        [NSString stringWithFormat:@"    %@",
         [tags componentsJoinedByString:@"  \u2502  "]]];
}

- (void)addForcedHiDPIControls:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    [self addLabelToMenu:menu title:@"    \u26A1 HiDPI via virtual display mirroring"];
    [self addActionToMenu:menu title:@"Stop Forced HiDPI"
                   action:@selector(stopForcedHiDPI:) displayID:display.displayID];
}

- (void)addActiveDisplayControls:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    // Resolution info
    NSString *resStr;
    if (display.isHiDPI && display.logicalWidth > 0) {
        resStr = [NSString stringWithFormat:@"    %zu \u00D7 %zu @%zux  %.0fHz",
                  display.pixelWidth, display.pixelHeight,
                  display.pixelWidth / display.logicalWidth,
                  display.refreshRate];
    } else {
        NSMutableString *s = [NSMutableString stringWithFormat:@"    %zu \u00D7 %zu",
                              display.pixelWidth, display.pixelHeight];
        if (display.refreshRate > 0)
            [s appendFormat:@"  %.0fHz", display.refreshRate];
        resStr = s;
    }
    [self addLabelToMenu:menu title:resStr];

    // All Resolutions submenu
    if ([self pref:kShowResolutions]) {
        NSMenuItem *modesItem = [[NSMenuItem alloc]
            initWithTitle:@"    All Resolutions" action:nil keyEquivalent:@""];
        modesItem.submenu = [self buildModesSubmenuForDisplay:display.displayID];
        [menu addItem:modesItem];
    }

    // HiDPI options
    if (!display.isHiDPI && display.hasNativeHiDPIModes) {
        [self addActionToMenu:menu title:@"Switch to HiDPI"
                       action:@selector(switchToHiDPI:) displayID:display.displayID];
    } else if (!display.isHiDPI && !display.hasNativeHiDPIModes &&
               NSClassFromString(@"CGVirtualDisplay")) {
        [self addActionToMenu:menu title:@"Force HiDPI"
                       action:@selector(forceHiDPI:) displayID:display.displayID];
    }

    // Disable
    [self addActionToMenu:menu title:@"Disable This Display"
                   action:@selector(disableDisplay:) displayID:display.displayID];
}

- (void)addDisabledDisplayControls:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    [self addActionToMenu:menu title:@"Enable This Display"
                   action:@selector(enableDisplay:) displayID:display.displayID];
}

// ── Settings submenu ─────────────────────────────────────────────────────────

- (NSMenu *)buildSettingsSubmenu {
    NSMenu *settings = [[NSMenu alloc] init];
    settings.autoenablesItems = NO;

    [settings addItem:[self switchRowWithTitle:
        @"Turn off laptop screen when external monitor is connected"
            state:[self pref:kAutoManage] identifier:kAutoManage
           action:@selector(switchToggled:)]];
    [settings addItem:[NSMenuItem separatorItem]];

    [settings addItem:[self checkItemWithTitle:@"Show notifications"
                                           key:kShowNotifications
                                        action:@selector(toggleCheckSetting:)]];
    [settings addItem:[self checkItemWithTitle:@"Ask before disabling a display"
                                           key:kConfirmDisable
                                        action:@selector(toggleCheckSetting:)]];
    [settings addItem:[self checkItemWithTitle:@"Show all resolutions"
                                           key:kShowResolutions
                                        action:@selector(toggleCheckSettingAndRebuild:)]];
    [settings addItem:[NSMenuItem separatorItem]];

    BOOL loginEnabled = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled);
    [settings addItem:[self switchRowWithTitle:@"Launch at Login"
            state:loginEnabled identifier:@"LaunchAtLogin"
           action:@selector(loginSwitchToggled:)]];

    return settings;
}

- (NSMenuItem *)checkItemWithTitle:(NSString *)title key:(NSString *)key action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:action
                                          keyEquivalent:@""];
    item.target = self;
    item.representedObject = key;
    item.state = [self pref:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (NSMenuItem *)switchRowWithTitle:(NSString *)title
                             state:(BOOL)state
                        identifier:(NSString *)identifier
                            action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] init];

    // Measure switch first to calculate available label width
    NSSwitch *sw = [[NSSwitch alloc] init];
    sw.controlSize = NSControlSizeMini;
    [sw sizeToFit];
    CGFloat switchWidth = sw.frame.size.width;
    CGFloat switchHeight = sw.frame.size.height;

    // Calculate label width and measure wrapped height
    CGFloat labelWidth = kSwitchRowWidth - kSwitchRowPad * 2 - switchWidth - 8;
    NSFont *font = [NSFont menuFontOfSize:13];
    NSRect textRect = [title boundingRectWithSize:NSMakeSize(labelWidth, CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin
                                       attributes:@{NSFontAttributeName: font}];
    CGFloat labelHeight = ceil(textRect.size.height);
    CGFloat rowHeight = MAX(kSwitchRowHeight, labelHeight + 10);

    // Build row
    NSView *row = [[NSView alloc] initWithFrame:
                   NSMakeRect(0, 0, kSwitchRowWidth, rowHeight)];

    sw.frame = NSMakeRect(kSwitchRowWidth - kSwitchRowPad - switchWidth,
                          (rowHeight - switchHeight) / 2,
                          switchWidth, switchHeight);
    sw.state = state ? NSControlStateValueOn : NSControlStateValueOff;
    sw.target = self;
    sw.action = action;
    sw.identifier = identifier;
    [row addSubview:sw];

    NSTextField *label = [NSTextField labelWithString:title];
    label.font = font;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    label.frame = NSMakeRect(kSwitchRowPad,
                             (rowHeight - labelHeight) / 2,
                             labelWidth, labelHeight);
    [row addSubview:label];

    item.view = row;
    return item;
}

// ── Modes submenu ───────────────────────────────────────────────────────────

- (NSMenu *)buildModesSubmenuForDisplay:(CGDirectDisplayID)displayID {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSArray<DDDisplayMode *> *modes = [self.displayManager modesForDisplay:displayID];
    NSFont *mono = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];

    NSMenuItem *header = [[NSMenuItem alloc]
        initWithTitle:@"" action:nil keyEquivalent:@""];
    header.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Pixels           Looks Like       Type      Rate"
            attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11
                                                weight:NSFontWeightBold]}];
    header.enabled = NO;
    [submenu addItem:header];
    [submenu addItem:[NSMenuItem separatorItem]];

    for (DDDisplayMode *mode in modes) {
        NSString *rateStr = mode.refreshRate > 0
            ? [NSString stringWithFormat:@"%.0fHz", mode.refreshRate] : @"--";

        NSString *pixelCol = [[NSString stringWithFormat:@"%zu \u00D7 %zu",
            mode.pixelWidth, mode.pixelHeight]
            stringByPaddingToLength:17 withString:@" " startingAtIndex:0];
        NSString *logicalCol = [[NSString stringWithFormat:@"%zu \u00D7 %zu",
            mode.logicalWidth, mode.logicalHeight]
            stringByPaddingToLength:17 withString:@" " startingAtIndex:0];
        NSString *typeCol = [(mode.isHiDPI ? @"HiDPI" : @"Standard")
            stringByPaddingToLength:10 withString:@" " startingAtIndex:0];

        NSString *line = [NSString stringWithFormat:@"%@%@%@%@",
            pixelCol, logicalCol, typeCol, rateStr];

        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@""
                   action:mode.isCurrent ? nil : @selector(switchMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !mode.isCurrent;
        item.representedObject = @{
            @"mode": mode,
            @"displayID": @(displayID)
        };
        item.attributedTitle = [[NSAttributedString alloc]
            initWithString:line
                attributes:@{NSFontAttributeName: mode.isCurrent ? monoBold : mono}];
        if (mode.isCurrent) item.state = NSControlStateValueOn;
        [submenu addItem:item];
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *countItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"%lu modes \u2014 click to switch",
                       (unsigned long)modes.count]
               action:nil keyEquivalent:@""];
    countItem.enabled = NO;
    [submenu addItem:countItem];

    return submenu;
}

// ── Menu helpers ────────────────────────────────────────────────────────────

- (void)addLabelToMenu:(NSMenu *)menu title:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:nil
                                          keyEquivalent:@""];
    item.enabled = NO;
    [menu addItem:item];
}

- (void)addActionToMenu:(NSMenu *)menu
                  title:(NSString *)title
                 action:(SEL)action
              displayID:(CGDirectDisplayID)displayID {
    NSMenuItem *item = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"    %@", title]
               action:action
        keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(displayID);
    [menu addItem:item];
}

// ── Preference helpers ──────────────────────────────────────────────────────

- (BOOL)pref:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

- (void)flipPref:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:![defaults boolForKey:key] forKey:key];
}

// ── Display actions ─────────────────────────────────────────────────────────

- (void)switchMode:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    DDDisplayMode *mode = info[@"mode"];
    CGDirectDisplayID did = [info[@"displayID"] unsignedIntValue];

    NSError *error = nil;
    if ([self.displayManager setMode:mode forDisplay:did error:&error]) {
        NSString *label = mode.isHiDPI ? @"HiDPI" : @"Standard";
        NSMutableString *body = [NSMutableString stringWithFormat:
            @"%zu \u00D7 %zu %@", mode.pixelWidth, mode.pixelHeight, label];
        if (mode.refreshRate > 0)
            [body appendFormat:@" %.0fHz", mode.refreshRate];
        [self postNotification:@"Resolution Changed" body:body];
    } else {
        NSLog(@"DisplayDisabler: Failed to set mode: %@", error);
        [self postNotification:@"Resolution Change Failed"
                          body:error.localizedDescription ?: @"Unknown error"];
    }
}

- (void)disableDisplay:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    // Refuse to disable the last active display — prevents an unrecoverable black screen
    NSArray<DDDisplayInfo *> *displays = [self.displayManager allDisplays];
    NSUInteger activeCount = 0;
    for (DDDisplayInfo *d in displays) {
        if (d.isActive) activeCount++;
    }
    if (activeCount <= 1) {
        [self postNotification:@"Cannot Disable"
                          body:@"Refusing to disable the only active display."];
        return;
    }

    if ([self pref:kConfirmDisable]) {
        if (![self confirmAction:[NSString stringWithFormat:@"Disable \"%@\"?", name]
                            info:@"You can re-enable it from this menu."]) {
            return;
        }
    }

    NSError *error = nil;
    if ([self.displayManager disableDisplay:did error:&error]) {
        [self postNotification:@"Display Disabled"
                          body:[NSString stringWithFormat:@"%@ has been disabled.", name]];
    } else {
        NSLog(@"DisplayDisabler: Failed to disable 0x%X: %@", did, error);
        [self postNotification:@"Disable Failed"
                          body:error.localizedDescription ?: @"Unknown error"];
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
                          body:error.localizedDescription ?: @"Unknown error"];
    }
}

- (void)switchToHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    NSError *error = nil;
    if ([self.displayManager switchToHiDPIForDisplay:did error:&error]) {
        [self postNotification:@"Switched to HiDPI"
                          body:[NSString stringWithFormat:@"%@ is now in HiDPI mode.", name]];
    } else {
        NSLog(@"DisplayDisabler: Failed to switch to HiDPI for 0x%X: %@", did, error);
        [self postNotification:@"HiDPI Switch Failed"
                          body:error.localizedDescription ?: @"Unknown error"];
    }
}

- (void)forceHiDPI:(NSMenuItem *)sender {
    CGDirectDisplayID did = [sender.representedObject unsignedIntValue];
    NSString *name = [self.displayManager nameForDisplayID:did];

    [self.displayManager forceHiDPIForDisplay:did completion:^(BOOL success, NSError *error) {
        if (success) {
            [self postNotification:@"HiDPI Forced"
                              body:[NSString stringWithFormat:
                                    @"HiDPI enabled for %@ via virtual display.", name]];
            [self rebuildMenu];
        } else {
            NSLog(@"DisplayDisabler: Failed to force HiDPI for 0x%X: %@", did, error);
            [self postNotification:@"Force HiDPI Failed"
                              body:error.localizedDescription ?: @"Unknown error"];
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

// ── Settings actions ────────────────────────────────────────────────────────

- (void)switchToggled:(NSSwitch *)sender {
    NSString *key = sender.identifier;
    [self flipPref:key];

    if ([key isEqualToString:kAutoManage] && [self pref:kAutoManage])
        [self performAutoDisableIfNeeded];
}

- (void)loginSwitchToggled:(NSSwitch *)sender {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;

    if (service.status == SMAppServiceStatusEnabled) {
        [service unregisterAndReturnError:&error];
        if (error)
            NSLog(@"DisplayDisabler: Failed to unregister login item: %@", error);
    } else {
        BOOL success = [service registerAndReturnError:&error];
        if (!success) {
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
}

- (void)toggleCheckSettingAndRebuild:(NSMenuItem *)sender {
    [self toggleCheckSetting:sender];
    [self rebuildMenu];
}

// ── Confirmation dialog ─────────────────────────────────────────────────────

- (BOOL)confirmAction:(NSString *)message info:(NSString *)info {
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Disable"];
    [alert addButtonWithTitle:@"Cancel"];

    return [alert runModal] == NSAlertFirstButtonReturn;
}

// ── Auto-manage logic ───────────────────────────────────────────────────────

- (void)performAutoDisableIfNeeded {
    if (![self pref:kAutoManage]) return;

    DDDisplayInfo *builtIn = [self.displayManager builtInDisplay];
    if (!builtIn || !builtIn.isActive) return;
    if (![self.displayManager hasExternalDisplay]) return;

    NSError *error = nil;
    if ([self.displayManager disableDisplay:builtIn.displayID error:&error]) {
        [self postNotification:@"Built-in Display Disabled"
                          body:@"External monitor detected."];
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
                          body:@"No external monitor detected."];
    } else {
        NSLog(@"DisplayDisabler: Auto-reenable failed: %@", error);
    }
}

@end
