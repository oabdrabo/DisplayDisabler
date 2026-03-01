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

@interface AppDelegate () <UNUserNotificationCenterDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) DisplayManager *displayManager;
@end

@implementation AppDelegate

// ── Lifecycle ───────────────────────────────────────────────────────────────

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self registerDefaults];

    self.displayManager = [DisplayManager shared];
    [self setupStatusItem];
    [self setupNotifications];
    [self rebuildMenu];

    __weak typeof(self) weakSelf = self;
    [self.displayManager startMonitoringWithChangeHandler:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rebuildMenu];
        [strongSelf performAutoDisableIfNeeded];
        [strongSelf performAutoReenableIfNeeded];
    }];

    [self performAutoDisableIfNeeded];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
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

// ── Notifications setup ─────────────────────────────────────────────────────

- (void)setupNotifications {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        if (error) NSLog(@"DisplayDisabler: Notification auth error: %@", error);
    }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)postNotification:(NSString *)title body:(NSString *)body {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kShowNotifications]) return;

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
    for (DDDisplayInfo *d in displays) { if (d.isActive) activeCount++; }

    // Header
    [self addItemToMenu:menu
                  title:[NSString stringWithFormat:@"DisplayDisabler v%s", APP_VERSION]
                 action:nil enabled:NO];
    [self addItemToMenu:menu
                  title:[NSString stringWithFormat:@"%lu online, %lu active",
                         (unsigned long)displays.count, (unsigned long)activeCount]
                 action:nil enabled:NO];

    [menu addItem:[NSMenuItem separatorItem]];

    // Per-display sections
    for (DDDisplayInfo *display in displays) {
        [self addDisplaySection:display toMenu:menu];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    // Settings submenu
    NSMenuItem *settingsItem = [[NSMenuItem alloc]
        initWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settingsItem.submenu = [self buildSettingsSubmenu];
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Quit
    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit DisplayDisabler"
               action:@selector(terminate:)
        keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)addDisplaySection:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    // Display name with status indicator
    NSString *dot = display.isActive ? @"\u25CF " : @"\u25CB ";
    NSString *title = [NSString stringWithFormat:@"%@%@ \u2014 0x%X",
                       dot, display.name, display.displayID];

    NSMenuItem *nameItem = [[NSMenuItem alloc] initWithTitle:title
                                                      action:nil keyEquivalent:@""];
    nameItem.enabled = NO;
    NSMutableAttributedString *attrTitle = [[NSMutableAttributedString alloc]
        initWithString:title
            attributes:@{NSFontAttributeName: [NSFont menuBarFontOfSize:14]}];
    nameItem.attributedTitle = attrTitle;
    [menu addItem:nameItem];

    // Tags line
    NSMutableArray *tags = [NSMutableArray array];
    [tags addObject:display.isActive ? @"active" : @"disabled"];
    if (display.isBuiltIn) [tags addObject:@"built-in"];
    if (display.isMain) [tags addObject:@"main"];

    [self addItemToMenu:menu
                  title:[NSString stringWithFormat:@"    %@",
                         [tags componentsJoinedByString:@"  \u2502  "]]
                 action:nil enabled:NO];

    if (display.isActive) {
        // Resolution line
        NSString *resStr;
        if (display.isHiDPI && display.logicalWidth > 0) {
            resStr = [NSString stringWithFormat:@"    %zu \u00D7 %zu @%zdx  %.0fHz",
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
        [self addItemToMenu:menu title:resStr action:nil enabled:NO];

        // HiDPI Modes submenu (togglable)
        if ([[NSUserDefaults standardUserDefaults] boolForKey:kShowResolutions]) {
            NSMenuItem *modesItem = [[NSMenuItem alloc]
                initWithTitle:@"    All Resolutions" action:nil keyEquivalent:@""];
            modesItem.submenu = [self buildModesSubmenuForDisplay:display.displayID];
            [menu addItem:modesItem];
        }

        // Disable button
        NSMenuItem *disableItem = [[NSMenuItem alloc]
            initWithTitle:@"    Disable This Display"
                   action:@selector(disableDisplay:)
            keyEquivalent:@""];
        disableItem.target = self;
        disableItem.tag = (NSInteger)display.displayID;
        [menu addItem:disableItem];
    } else {
        // Enable button
        NSMenuItem *enableItem = [[NSMenuItem alloc]
            initWithTitle:@"    Enable This Display"
                   action:@selector(enableDisplay:)
            keyEquivalent:@""];
        enableItem.target = self;
        enableItem.tag = (NSInteger)display.displayID;
        [menu addItem:enableItem];
    }
}

// ── Settings submenu ─────────────────────────────────────────────────────────

- (NSMenu *)buildSettingsSubmenu {
    NSMenu *settings = [[NSMenu alloc] init];
    settings.autoenablesItems = NO;

    // Automation toggle (NSSwitch — menu stays open)
    [settings addItem:[self switchItemWithTitle:@"Turn off laptop screen when external monitor is connected"
                                            key:kAutoManage]];
    [settings addItem:[NSMenuItem separatorItem]];

    // Simple preferences (checkmark — standard menu items)
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

    // Login toggle (NSSwitch)
    [settings addItem:[self loginSwitchItem]];

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

static const CGFloat kSwitchRowWidth  = 290;
static const CGFloat kSwitchRowHeight = 28;
static const CGFloat kSwitchRowPad    = 18;

- (NSMenuItem *)switchItemWithTitle:(NSString *)title key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] init];

    NSView *row = [[NSView alloc] initWithFrame:
                   NSMakeRect(0, 0, kSwitchRowWidth, kSwitchRowHeight)];

    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont menuFontOfSize:13];
    [label sizeToFit];
    label.frame = NSMakeRect(kSwitchRowPad,
                             (kSwitchRowHeight - label.frame.size.height) / 2,
                             kSwitchRowWidth - 80, label.frame.size.height);
    [row addSubview:label];

    NSSwitch *sw = [[NSSwitch alloc] init];
    sw.controlSize = NSControlSizeMini;
    [sw sizeToFit];
    sw.frame = NSMakeRect(kSwitchRowWidth - sw.frame.size.width - kSwitchRowPad,
                          (kSwitchRowHeight - sw.frame.size.height) / 2,
                          sw.frame.size.width, sw.frame.size.height);
    sw.state = [self pref:key] ? NSControlStateValueOn : NSControlStateValueOff;
    sw.target = self;
    sw.action = @selector(switchToggled:);
    sw.identifier = key;
    [row addSubview:sw];

    item.view = row;
    return item;
}

- (NSMenuItem *)loginSwitchItem {
    NSMenuItem *item = [[NSMenuItem alloc] init];

    NSView *row = [[NSView alloc] initWithFrame:
                   NSMakeRect(0, 0, kSwitchRowWidth, kSwitchRowHeight)];

    NSTextField *label = [NSTextField labelWithString:@"Launch at Login"];
    label.font = [NSFont menuFontOfSize:13];
    [label sizeToFit];
    label.frame = NSMakeRect(kSwitchRowPad,
                             (kSwitchRowHeight - label.frame.size.height) / 2,
                             kSwitchRowWidth - 80, label.frame.size.height);
    [row addSubview:label];

    NSSwitch *sw = [[NSSwitch alloc] init];
    sw.controlSize = NSControlSizeMini;
    [sw sizeToFit];
    sw.frame = NSMakeRect(kSwitchRowWidth - sw.frame.size.width - kSwitchRowPad,
                          (kSwitchRowHeight - sw.frame.size.height) / 2,
                          sw.frame.size.width, sw.frame.size.height);
    sw.target = self;
    sw.action = @selector(loginSwitchToggled:);
    sw.identifier = @"LaunchAtLogin";

    if (@available(macOS 13.0, *)) {
        sw.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
                   ? NSControlStateValueOn : NSControlStateValueOff;
    }

    [row addSubview:sw];
    item.view = row;
    return item;
}

// ── Modes submenu (clickable — switches resolution) ─────────────────────────

- (NSMenu *)buildModesSubmenuForDisplay:(CGDirectDisplayID)displayID {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSArray<DDDisplayMode *> *modes = [self.displayManager modesForDisplay:displayID];
    NSFont *mono = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];

    NSMenuItem *header = [[NSMenuItem alloc]
        initWithTitle:@"" action:nil keyEquivalent:@""];
    header.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Pixels           Looks Like       Scale  Rate"
            attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11
                                                weight:NSFontWeightBold]}];
    header.enabled = NO;
    [submenu addItem:header];
    [submenu addItem:[NSMenuItem separatorItem]];

    for (DDDisplayMode *mode in modes) {
        NSString *scaleStr = mode.isHiDPI ? @"2x" : @"1x";
        NSString *rateStr  = mode.refreshRate > 0
            ? [NSString stringWithFormat:@"%.0fHz", mode.refreshRate] : @"--";

        NSString *line = [NSString stringWithFormat:@"%-17s%-17s%-7s%@",
            [[NSString stringWithFormat:@"%zu \u00D7 %zu",
              mode.pixelWidth, mode.pixelHeight] UTF8String],
            [[NSString stringWithFormat:@"%zu \u00D7 %zu",
              mode.logicalWidth, mode.logicalHeight] UTF8String],
            [scaleStr UTF8String],
            rateStr];

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
        item.attributedTitle = [[NSMutableAttributedString alloc]
            initWithString:line
                attributes:@{NSFontAttributeName: mode.isCurrent ? monoBold : mono}];
        if (mode.isCurrent) item.state = NSControlStateValueOn;
        [submenu addItem:item];
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *countItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"%lu modes — click to switch",
                       (unsigned long)modes.count]
               action:nil keyEquivalent:@""];
    countItem.enabled = NO;
    [submenu addItem:countItem];

    return submenu;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

- (void)addItemToMenu:(NSMenu *)menu title:(NSString *)title
               action:(SEL)action enabled:(BOOL)enabled {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:action
                                          keyEquivalent:@""];
    item.enabled = enabled;
    [menu addItem:item];
}

- (BOOL)pref:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

- (void)flipPref:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:![defaults boolForKey:key] forKey:key];
}

// ── Actions ─────────────────────────────────────────────────────────────────

- (void)switchMode:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    DDDisplayMode *mode = info[@"mode"];
    CGDirectDisplayID did = [info[@"displayID"] unsignedIntValue];

    NSError *error = nil;
    if ([self.displayManager setMode:mode forDisplay:did error:&error]) {
        NSString *label = mode.isHiDPI ? @"HiDPI" : @"Standard";
        [self postNotification:@"Resolution Changed"
                          body:[NSString stringWithFormat:@"%zu \u00D7 %zu %@ %.0fHz",
                                mode.pixelWidth, mode.pixelHeight,
                                label, mode.refreshRate]];
    } else {
        NSLog(@"DisplayDisabler: Failed to set mode: %@", error);
    }
}

- (void)disableDisplay:(NSMenuItem *)sender {
    CGDirectDisplayID did = (CGDirectDisplayID)sender.tag;

    if ([self pref:kConfirmDisable]) {
        NSString *name = [self.displayManager nameForDisplayID:did];
        if (![self confirmAction:[NSString stringWithFormat:
                @"Disable \"%@\"?", name]
                            info:@"You can re-enable it from this menu."]) {
            return;
        }
    }

    NSError *error = nil;
    if ([self.displayManager disableDisplay:did error:&error]) {
        [self postNotification:@"Display Disabled"
                          body:[NSString stringWithFormat:@"0x%X has been disabled.", did]];
    } else {
        NSLog(@"DisplayDisabler: Failed to disable 0x%X: %@", did, error);
    }
}

- (void)enableDisplay:(NSMenuItem *)sender {
    CGDirectDisplayID did = (CGDirectDisplayID)sender.tag;
    NSError *error = nil;
    if ([self.displayManager enableDisplay:did error:&error]) {
        [self postNotification:@"Display Enabled"
                          body:[NSString stringWithFormat:@"0x%X has been enabled.", did]];
    } else {
        NSLog(@"DisplayDisabler: Failed to enable 0x%X: %@", did, error);
    }
}

// ── Switch actions (menu stays open) ────────────────────────────────────────

- (void)switchToggled:(NSSwitch *)sender {
    NSString *key = sender.identifier;
    [self flipPref:key];

    if ([key isEqualToString:kAutoManage] && [self pref:kAutoManage])
        [self performAutoDisableIfNeeded];
}

- (void)loginSwitchToggled:(NSSwitch *)sender {
    if (@available(macOS 13.0, *)) {
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
}

// ── Checkmark setting actions ────────────────────────────────────────────────

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

// ── Auto-disable logic ─────────────────────────────────────────────────────

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

// ── Auto-re-enable logic ────────────────────────────────────────────────────

- (void)performAutoReenableIfNeeded {
    if (![self pref:kAutoManage]) return;

    DDDisplayInfo *builtIn = [self.displayManager builtInDisplay];
    if (!builtIn) return;
    if (builtIn.isActive) return;                       // already on
    if ([self.displayManager hasExternalDisplay]) return; // still has external

    NSError *error = nil;
    if ([self.displayManager enableDisplay:builtIn.displayID error:&error]) {
        [self postNotification:@"Built-in Display Re-enabled"
                          body:@"No external monitor detected."];
    } else {
        NSLog(@"DisplayDisabler: Auto-reenable failed: %@", error);
    }
}

@end
