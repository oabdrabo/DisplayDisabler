/*
 * AppDelegate.m — Menu bar application delegate
 * Part of DisplayDisabler v3.0
 */

#import "AppDelegate.h"
#import "DisplayManager.h"
#import "Brightness.h"
#import "HiDPIInjector.h"
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>

// ── UserDefaults keys ───────────────────────────────────────────────────────

static NSString * const kAutoManage        = @"AutoManageBuiltIn";
static NSString * const kShowNotifications = @"ShowNotifications";
static NSString * const kConfirmDisable    = @"ConfirmBeforeDisable";
static NSString * const kShowResolutions   = @"ShowResolutions";
static NSString * const kHideNotch         = @"HideNotch";

// Notification identifier used for auto-manage events so consecutive
// disable/re-enable banners replace each other instead of stacking.
static NSString * const kAutoManageNotifID = @"auto-manage";

// ── Switch-row layout ───────────────────────────────────────────────────────

static const CGFloat kSwitchRowWidth   = 290;
static const CGFloat kSwitchRowHeight  = 28;
static const CGFloat kSwitchRowPad     = 18;
static const CGFloat kSwitchLabelGap   = 8;

// ── Modes-submenu layout ────────────────────────────────────────────────────
// Column widths (in chars) tuned for a monospaced font. Covers 8K and 5-digit
// pixel counts with room to spare.

static const NSUInteger kModeColPixels  = 17;
static const NSUInteger kModeColLogical = 17;
static const NSUInteger kModeColType    = 10;

// Common HiDPI logical resolutions the user can force on any display, even
// when the panel doesn't advertise them as a mode. These go through the
// virtual-display path — macOS scales the mirror to the panel's real pixels.
static const struct { size_t w, h; } kCommonHiDPIResolutions[] = {
    {1280,  800},
    {1440,  900},
    {1600, 1000},
    {1680, 1050},
    {1920, 1080},
    {1920, 1200},
    {2048, 1280},
    {2560, 1440},
    {2560, 1600},
    {3008, 1692},
    {3456, 2160},
    {3840, 2160},
};
static const size_t kCommonHiDPICount =
    sizeof kCommonHiDPIResolutions / sizeof *kCommonHiDPIResolutions;

@interface AppDelegate () <UNUserNotificationCenterDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) DisplayManager *displayManager;
@property (nonatomic) BOOL notificationAuthRequested;
// Black strip covering the notch region of the MacBook's built-in display.
// Created lazily; nil when the pref is off or no notched display is attached.
@property (nonatomic, strong) NSWindow *notchOverlay;
@end

@implementation AppDelegate

// ── Lifecycle ───────────────────────────────────────────────────────────────

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self registerDefaults];

    self.displayManager = [DisplayManager shared];

    UNUserNotificationCenter.currentNotificationCenter.delegate = self;

    [self setupStatusItem];
    [self rebuildMenu];
    [self updateNotchOverlay];

    __weak __typeof(self) weakSelf = self;
    [self.displayManager startMonitoringWithChangeHandler:^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.displayManager pruneStaleVirtualDisplays];
        [strongSelf rebuildMenu];
        [strongSelf updateNotchOverlay];
        [strongSelf performAutoDisableIfNeeded];
        [strongSelf performAutoReenableIfNeeded];
    }];

    // Reconfiguration callbacks don't fire on registration, so run once
    // now to cover the common "launched while already plugged in" case.
    [self performAutoDisableIfNeeded];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.displayManager cleanUpAllVirtualDisplays];
    [self.displayManager stopMonitoring];
    [self tearDownNotchOverlay];
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kAutoManage:        @NO,
        kShowNotifications: @YES,
        kConfirmDisable:    @YES,
        kShowResolutions:   @YES,
        kHideNotch:         @NO,
    }];
}

// ── Notifications ───────────────────────────────────────────────────────────

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

    // Lazy-request auth on first use so a menu-bar-only app doesn't surface a
    // permission prompt until it actually has something to say.
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

// ── Status item ─────────────────────────────────────────────────────────────

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    [self updateStatusIcon:NO];
    self.statusItem.button.toolTip = @"DisplayDisabler";
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

// ── Notch overlay ───────────────────────────────────────────────────────────

// Screen whose built-in panel has a camera notch, else nil. Detected via
// NSScreen.safeAreaInsets.top > 0 — non-zero only on notched MacBooks.
- (NSScreen *)notchedScreen {
    if (@available(macOS 12.0, *)) {
        for (NSScreen *s in [NSScreen screens]) {
            if (s.safeAreaInsets.top > 0) return s;
        }
    }
    return nil;
}

- (void)updateNotchOverlay {
    BOOL wantsOverlay = [self pref:kHideNotch];
    NSScreen *screen = [self notchedScreen];

    if (!wantsOverlay || !screen) {
        [self tearDownNotchOverlay];
        return;
    }

    CGFloat notchHeight = 0;
    if (@available(macOS 12.0, *)) notchHeight = screen.safeAreaInsets.top;
    if (notchHeight <= 0) { [self tearDownNotchOverlay]; return; }

    // Cocoa windows are bottom-left-origin; place our strip flush with the
    // top of the target screen, full width, notch-height tall.
    NSRect frame = NSMakeRect(screen.frame.origin.x,
                              screen.frame.origin.y + screen.frame.size.height - notchHeight,
                              screen.frame.size.width,
                              notchHeight);

    if (!self.notchOverlay) {
        NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.backgroundColor = [NSColor blackColor];
        w.opaque = YES;
        w.hasShadow = NO;
        // Above the menubar so it sits on top of the notch cutout.
        w.level = NSStatusWindowLevel + 1;
        w.ignoresMouseEvents = YES;
        w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.notchOverlay = w;
    } else {
        [self.notchOverlay setFrame:frame display:NO];
    }
    [self.notchOverlay orderFront:nil];
}

- (void)tearDownNotchOverlay {
    if (!self.notchOverlay) return;
    [self.notchOverlay orderOut:nil];
    self.notchOverlay = nil;
}

// ── Menu building ───────────────────────────────────────────────────────────

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

    NSString *version = [[NSBundle mainBundle]
                         objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    [self addLabelToMenu:menu title:
        [NSString stringWithFormat:@"DisplayDisabler v%@", version]];
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
    // Populate lazily in -menuNeedsUpdate:. Building the custom switch-row
    // views eagerly here can trip AppKit's layout-recursion warning because
    // NSSwitch + NSTextField bring autolayout constraints into a menu-item
    // custom view. Lazy build also makes the settings always reflect current
    // Launch-at-Login status without us having to watch SMAppService.
    NSMenu *settingsMenu = [[NSMenu alloc] init];
    settingsMenu.autoenablesItems = NO;
    settingsMenu.delegate = self;
    settingsItem.submenu = settingsMenu;
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
    BOOL forced = [self.displayManager isHiDPIForcedForDisplay:display.displayID];
    [self addDisplayHeader:display forced:forced toMenu:menu];

    if (forced) {
        [self addForcedHiDPIControls:display toMenu:menu];
    } else if (display.isActive) {
        [self addActiveDisplayControls:display toMenu:menu];
    } else {
        [self addDisabledDisplayControls:display toMenu:menu];
    }
}

- (void)addDisplayHeader:(DDDisplayInfo *)display
                  forced:(BOOL)forced
                  toMenu:(NSMenu *)menu {
    BOOL effectivelyActive = display.isActive || forced;
    NSString *dot = effectivelyActive ? @"\u25CF " : @"\u25CB ";

    NSMutableAttributedString *attrTitle = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@%@", dot, display.name]
            attributes:@{NSFontAttributeName: [NSFont menuBarFontOfSize:14]}];
    [attrTitle appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"  0x%X", display.displayID]
            attributes:@{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10
                                        weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
            }]];

    NSMenuItem *nameItem = [[NSMenuItem alloc] initWithTitle:@""
                                                      action:nil keyEquivalent:@""];
    nameItem.enabled = NO;
    nameItem.attributedTitle = attrTitle;
    [menu addItem:nameItem];

    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    if (forced)            [tags addObject:@"HiDPI forced"];
    else                   [tags addObject:display.isActive ? @"active" : @"disabled"];
    if (display.isBuiltIn) [tags addObject:@"built-in"];
    if (display.isMain)    [tags addObject:@"main"];

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
    NSMutableString *resStr = [NSMutableString stringWithFormat:@"    %zu \u00D7 %zu",
                               display.pixelWidth, display.pixelHeight];
    if (display.isHiDPI && display.logicalWidth > 0) {
        [resStr appendFormat:@" @%zux", display.pixelWidth / display.logicalWidth];
    }
    if (display.refreshRate > 0) {
        [resStr appendFormat:@"  %.0fHz", display.refreshRate];
    }
    [self addLabelToMenu:menu title:resStr];

    // Fetch the mode list once; both submenu builders read from it.
    // Force HiDPI is offered on every panel when CGVirtualDisplay is available —
    // including panels that already have native HiDPI (e.g. the MacBook built-in),
    // because the user may want arbitrary HiDPI logical sizes beyond what macOS
    // exposes natively.
    BOOL needAllRes = [self pref:kShowResolutions];
    BOOL needForce  = NSClassFromString(@"CGVirtualDisplay") != nil;
    NSArray<DDDisplayMode *> *modes = (needAllRes || needForce)
        ? [self.displayManager modesForDisplay:display.displayID]
        : @[];

    if (needAllRes) {
        NSMenuItem *modesItem = [[NSMenuItem alloc]
            initWithTitle:@"    All Resolutions" action:nil keyEquivalent:@""];
        modesItem.submenu = [self buildModesSubmenuForDisplay:display.displayID modes:modes];
        [menu addItem:modesItem];
    }

    if (!display.isHiDPI && display.hasNativeHiDPIModes) {
        [self addActionToMenu:menu title:@"Switch to HiDPI"
                       action:@selector(switchToHiDPI:) displayID:display.displayID];
    }

    if (needForce) {
        NSArray<DDDisplayMode *> *candidates =
            [self.displayManager forceHiDPICandidatesFromModes:modes];
        if (candidates.count > 0) {
            NSSet<NSString *> *nativeKeys =
                [self.displayManager nativeHiDPIPixelKeysFromModes:modes];
            NSMenuItem *forceItem = [[NSMenuItem alloc]
                initWithTitle:@"    Force HiDPI" action:nil keyEquivalent:@""];
            forceItem.submenu = [self buildForceHiDPISubmenuForDisplay:display.displayID
                                                            candidates:candidates
                                                            nativeKeys:nativeKeys];
            [menu addItem:forceItem];
        }
    }

    if ([[Brightness shared] supportsBrightness:display.displayID]) {
        NSMenuItem *brightItem = [[NSMenuItem alloc]
            initWithTitle:@"    Brightness" action:nil keyEquivalent:@""];
        brightItem.submenu = [self buildBrightnessSubmenuForDisplay:display.displayID];
        [menu addItem:brightItem];
    }

    // "Crisp" system-level HiDPI: writes a display override plist that adds
    // custom resolutions to macOS's own mode list. Requires admin + reboot.
    // After reboot, these appear as native HiDPI modes in All Resolutions
    // and in System Settings → Displays.
    BOOL installed = [[HiDPIInjector shared] isInstalledForDisplay:display.displayID];
    [self addActionToMenu:menu
                    title:(installed
                           ? @"Remove Crisp HiDPI Overrides\u2026"
                           : @"Install Crisp HiDPI (admin + reboot)\u2026")
                   action:(installed
                           ? @selector(uninstallCrispHiDPI:)
                           : @selector(installCrispHiDPI:))
                displayID:display.displayID];

    [self addActionToMenu:menu title:@"Disable This Display"
                   action:@selector(disableDisplay:) displayID:display.displayID];
}

- (NSMenu *)buildBrightnessSubmenuForDisplay:(CGDirectDisplayID)displayID {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    static const uint8_t levels[] = {10, 25, 50, 75, 100};
    for (size_t i = 0; i < sizeof levels / sizeof *levels; i++) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"%u%%", levels[i]]
                   action:@selector(setBrightness:)
            keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{ @"displayID": @(displayID),
                                    @"percent":   @(levels[i]) };
        [submenu addItem:item];
    }
    return submenu;
}

- (NSMenu *)buildForceHiDPISubmenuForDisplay:(CGDirectDisplayID)displayID
                                  candidates:(NSArray<DDDisplayMode *> *)candidates
                                  nativeKeys:(NSSet<NSString *> *)nativeKeys {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *mono     = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];

    NSMenuItem *header = [[NSMenuItem alloc]
        initWithTitle:@"Mirror into a 2\u00D7 virtual display"
               action:nil keyEquivalent:@""];
    header.enabled = NO;
    [submenu addItem:header];
    [submenu addItem:[NSMenuItem separatorItem]];

    DDDisplayMode *currentlyForced = [self.displayManager forcedTargetForDisplay:displayID];

    static const NSUInteger kPixelColWidth = 15;
    static const NSUInteger kHzColWidth    = 8;

    for (DDDisplayMode *mode in candidates) {
        NSString *pixelStr = [[NSString stringWithFormat:@"%zu \u00D7 %zu",
                               mode.pixelWidth, mode.pixelHeight]
                              stringByPaddingToLength:kPixelColWidth
                                              withString:@" " startingAtIndex:0];
        NSString *hzStr;
        if (mode.refreshRate > 0) {
            hzStr = [[NSString stringWithFormat:@"%.0fHz", mode.refreshRate]
                     stringByPaddingToLength:kHzColWidth
                                  withString:@" " startingAtIndex:0];
        } else {
            hzStr = [@"" stringByPaddingToLength:kHzColWidth
                                      withString:@" " startingAtIndex:0];
        }

        NSString *key = [NSString stringWithFormat:@"%zu_%zu",
                         mode.pixelWidth, mode.pixelHeight];
        // "native" = a native HiDPI mode for this pixel size also exists, so
        // forcing here is a supersample-style choice rather than the only path
        // to HiDPI. No marker = Standard-only pixel size, where force is it.
        NSString *tag = [nativeKeys containsObject:key] ? @"\u25CE native" : @"\u26A1 force";

        NSString *line = [NSString stringWithFormat:@"%@%@%@", pixelStr, hzStr, tag];

        BOOL isCurrent = (currentlyForced &&
                          currentlyForced.pixelWidth  == mode.pixelWidth &&
                          currentlyForced.pixelHeight == mode.pixelHeight);

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
        [submenu addItem:item];
    }

    // Common HiDPI presets: pixel sizes not in the panel's mode list, but that
    // the virtual-display pipeline can still render at (macOS scales the
    // mirror). Built as synthetic DDDisplayMode objects with modeRef=nil so
    // forceHiDPIForDisplay:atMode:completion: skips the panel mode switch.
    [submenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *commonHeader = [[NSMenuItem alloc]
        initWithTitle:@"Common HiDPI resolutions" action:nil keyEquivalent:@""];
    commonHeader.enabled = NO;
    [submenu addItem:commonHeader];

    // Build a set of pixel keys already listed above so we don't duplicate
    // entries that happen to match one of the panel's advertised sizes.
    NSMutableSet<NSString *> *advertisedKeys = [NSMutableSet set];
    for (DDDisplayMode *mode in candidates) {
        [advertisedKeys addObject:
            [NSString stringWithFormat:@"%zu_%zu", mode.pixelWidth, mode.pixelHeight]];
    }

    // Pre-index candidate pixel sizes so we can check, for each common preset,
    // whether the panel has an exact 2×target match (→ pixel-perfect) or will
    // require mirror scaling (→ softness). Lets us label each row honestly.
    NSMutableSet<NSString *> *candidatePixelKeys = [NSMutableSet set];
    for (DDDisplayMode *mode in candidates) {
        [candidatePixelKeys addObject:
            [NSString stringWithFormat:@"%zu_%zu", mode.pixelWidth, mode.pixelHeight]];
    }

    for (size_t i = 0; i < kCommonHiDPICount; i++) {
        size_t pw = kCommonHiDPIResolutions[i].w;
        size_t ph = kCommonHiDPIResolutions[i].h;
        NSString *key = [NSString stringWithFormat:@"%zu_%zu", pw, ph];
        if ([advertisedKeys containsObject:key]) continue;

        DDDisplayMode *synthetic = [[DDDisplayMode alloc] init];
        synthetic.pixelWidth    = pw;
        synthetic.pixelHeight   = ph;
        synthetic.logicalWidth  = pw;
        synthetic.logicalHeight = ph;
        synthetic.refreshRate   = 0;
        synthetic.isHiDPI       = NO;
        synthetic.modeRef       = NULL;

        NSString *doubleKey = [NSString stringWithFormat:@"%zu_%zu", pw * 2, ph * 2];
        BOOL pixelPerfect = [candidatePixelKeys containsObject:doubleKey];

        NSString *pixelStr = [[NSString stringWithFormat:@"%zu \u00D7 %zu", pw, ph]
                              stringByPaddingToLength:kPixelColWidth
                                          withString:@" " startingAtIndex:0];
        NSString *gap = [@"" stringByPaddingToLength:kHzColWidth
                                           withString:@" " startingAtIndex:0];
        NSString *line = [NSString stringWithFormat:@"%@%@\u2295 custom%@",
                          pixelStr, gap,
                          pixelPerfect ? @"" : @" (scaled)"];

        BOOL isCurrent = (currentlyForced &&
                          currentlyForced.pixelWidth  == pw &&
                          currentlyForced.pixelHeight == ph);

        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:line
                   action:isCurrent ? nil : @selector(forceHiDPIAtMode:)
            keyEquivalent:@""];
        item.target = self;
        item.enabled = !isCurrent;
        item.representedObject = @{ @"displayID": @(displayID), @"mode": synthetic };
        item.attributedTitle = [[NSAttributedString alloc]
            initWithString:line
                attributes:@{NSFontAttributeName: isCurrent ? monoBold : mono}];
        if (isCurrent) item.state = NSControlStateValueOn;
        [submenu addItem:item];
    }

    [submenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *legend = [[NSMenuItem alloc]
        initWithTitle:@"\u25CE native  \u2014  "
                      @"\u26A1 force  \u2014  "
                      @"\u2295 custom (virtual-only)"
               action:nil keyEquivalent:@""];
    legend.enabled = NO;
    [submenu addItem:legend];

    return submenu;
}

- (void)addDisabledDisplayControls:(DDDisplayInfo *)display toMenu:(NSMenu *)menu {
    [self addActionToMenu:menu title:@"Enable This Display"
                   action:@selector(enableDisplay:) displayID:display.displayID];
}

// ── Settings submenu (lazy) ─────────────────────────────────────────────────

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

    // Hide-the-notch is only offered when a notched display is actually attached.
    if ([self notchedScreen]) {
        [menu addItem:[self checkItemWithTitle:@"Hide the notch on built-in display"
                                           key:kHideNotch]];
    }
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

    // `labelWithString:` returns a label with auto-layout enabled, which
    // triggers recursive layout when AppKit lays out our custom menu-item
    // view. Pin it to manual frame layout and preset its preferred wrap
    // width so the intrinsic-size calc doesn't re-enter.
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

// ── Modes submenu ───────────────────────────────────────────────────────────

- (NSMenu *)buildModesSubmenuForDisplay:(CGDirectDisplayID)displayID
                                  modes:(NSArray<DDDisplayMode *> *)modes {
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO;

    NSFont *mono     = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSFont *monoBold = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];

    NSMenuItem *header = [[NSMenuItem alloc]
        initWithTitle:@"" action:nil keyEquivalent:@""];
    NSString *headerLine = [NSString stringWithFormat:@"%@%@%@%@",
        [@"Pixels"    stringByPaddingToLength:kModeColPixels  withString:@" " startingAtIndex:0],
        [@"Looks Like" stringByPaddingToLength:kModeColLogical withString:@" " startingAtIndex:0],
        [@"Type"      stringByPaddingToLength:kModeColType    withString:@" " startingAtIndex:0],
        @"Rate"];
    header.attributedTitle = [[NSAttributedString alloc]
        initWithString:headerLine
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
            stringByPaddingToLength:kModeColPixels withString:@" " startingAtIndex:0];
        NSString *logicalCol = [[NSString stringWithFormat:@"%zu \u00D7 %zu",
            mode.logicalWidth, mode.logicalHeight]
            stringByPaddingToLength:kModeColLogical withString:@" " startingAtIndex:0];
        NSString *typeCol = [(mode.isHiDPI ? @"HiDPI" : @"Standard")
            stringByPaddingToLength:kModeColType withString:@" " startingAtIndex:0];

        NSString *line = [NSString stringWithFormat:@"%@%@%@%@",
            pixelCol, logicalCol, typeCol, rateStr];

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

    // Refuse to disable the last active display — prevents an unrecoverable black screen.
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

    NSArray<NSValue *> *presets = [[HiDPIInjector shared] defaultCustomResolutions];

    NSMutableString *list = [NSMutableString string];
    for (NSValue *v in presets) {
        NSSize s = v.sizeValue;
        [list appendFormat:@"  • %d × %d\n", (int)s.width, (int)s.height];
    }

    if (@available(macOS 14.0, *)) { [NSApp activate]; }
    else { [NSApp activateIgnoringOtherApps:YES]; }

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
            [strongSelf postNotification:@"Install Failed"
                                    body:err.localizedDescription];
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
            [strongSelf postNotification:@"Remove Failed"
                                    body:err.localizedDescription];
            return;
        }
        [strongSelf rebuildMenu];
        [strongSelf offerRebootWithMessage:
            [NSString stringWithFormat:
             @"Crisp HiDPI overrides removed for \"%@\".", name]];
    }];
}

- (void)offerRebootWithMessage:(NSString *)message {
    if (@available(macOS 14.0, *)) { [NSApp activate]; }
    else { [NSApp activateIgnoringOtherApps:YES]; }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = @"The change applies only after a reboot. Would you "
                             @"like to restart now?";
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    // Trigger the standard macOS restart via AppleScript (no admin needed).
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:
        @"tell application \"System Events\" to restart"];
    NSDictionary *asErr = nil;
    [as executeAndReturnError:&asErr];
    if (asErr) NSLog(@"DisplayDisabler: restart script error: %@", asErr);
}

// ── Settings actions ────────────────────────────────────────────────────────

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
    // kShowResolutions changes the menu's structure, not just a checkmark state.
    if ([key isEqualToString:kShowResolutions]) [self rebuildMenu];
    if ([key isEqualToString:kHideNotch])       [self updateNotchOverlay];
}

// ── Confirmation dialog ─────────────────────────────────────────────────────

- (BOOL)confirmDestructive:(NSString *)message
                      info:(NSString *)info
                actionName:(NSString *)actionName {
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = info;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:actionName];
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
