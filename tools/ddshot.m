#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static pid_t ddPID(void) {
    for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications])
        if ([a.localizedName isEqualToString:@"DisplayDeck"] ||
            [a.bundleIdentifier isEqualToString:@"com.local.DisplayDeck"])
            return a.processIdentifier;
    return -1;
}

static NSArray *windowsForPID(pid_t pid, int layer) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *w in (__bridge NSArray *)list) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        if (layer != INT_MIN && [w[(id)kCGWindowLayer] intValue] != layer) continue;
        [out addObject:w];
    }
    CFRelease(list);
    return out;
}

static CGRect rectOf(NSDictionary *w) {
    CGRect r = CGRectZero;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
    return r;
}

static void rightClick(CGPoint p) {
    CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, p, kCGMouseButtonRight);
    CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventRightMouseUp,   p, kCGMouseButtonRight);
    CGEventPost(kCGHIDEventTap, d); usleep(60000);
    CGEventPost(kCGHIDEventTap, u);
    CFRelease(d); CFRelease(u);
}

static void moveMouse(CGPoint p) {
    CGEventRef m = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, m);
    CFRelease(m);
}

static void dismiss(void) {
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, 53, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, 53, false);
    CGEventPost(kCGHIDEventTap, d); usleep(40000);
    CGEventPost(kCGHIDEventTap, u);
    CFRelease(d); CFRelease(u);
    usleep(250000);
}

static void capture(NSDictionary *w, NSString *out) {
    NSString *wid = [w[(id)kCGWindowNumber] stringValue];
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/sbin/screencapture";
    t.arguments = @[ [@"-l" stringByAppendingString:wid], @"-o", @"-x", out ];
    [t launch]; [t waitUntilExit];
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: ddshot <out.png> [row substring]\n"); return 2; }
    NSString *out = [NSString stringWithUTF8String:argv[1]];
    NSString *hover = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;

    dismiss();
    pid_t pid = ddPID();
    if (pid < 0) { fprintf(stderr, "DisplayDeck not running\n"); return 1; }

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFTypeRef extras = NULL;
    AXUIElementCopyAttributeValue(app, CFSTR("AXExtrasMenuBar"), &extras);
    CFArrayRef sItems = NULL;
    if (extras) AXUIElementCopyAttributeValue((AXUIElementRef)extras, kAXChildrenAttribute,
                                              (CFTypeRef *)&sItems);
    if (!sItems || !CFArrayGetCount(sItems)) { fprintf(stderr, "no status item\n"); return 1; }
    AXUIElementRef sItem = (AXUIElementRef)CFArrayGetValueAtIndex(sItems, 0);
    CFTypeRef spv = NULL, ssv = NULL; CGPoint sp; CGSize ss;
    AXUIElementCopyAttributeValue(sItem, kAXPositionAttribute, &spv);
    AXUIElementCopyAttributeValue(sItem, kAXSizeAttribute, &ssv);
    AXValueGetValue(spv, kAXValueCGPointType, &sp);
    AXValueGetValue(ssv, kAXValueCGSizeType, &ss);
    CFRelease(spv); CFRelease(ssv);
    rightClick(CGPointMake(sp.x + ss.width/2, sp.y + ss.height/2));
    usleep(450000);

    NSArray *menus = windowsForPID(pid, 101);
    if (!menus.count) { fprintf(stderr, "menu didn't open\n"); return 1; }

    NSDictionary *mainMenu = menus.firstObject;
    for (NSDictionary *w in menus)
        if (rectOf(w).origin.x < rectOf(mainMenu).origin.x) mainMenu = w;

    if (!hover) { capture(mainMenu, out); usleep(150000); dismiss(); return 0; }

    CGRect mm = rectOf(mainMenu);
    AXUIElementRef menuEl = NULL;
    AXUIElementCopyElementAtPosition(app, CGRectGetMidX(mm), mm.origin.y + 12, &menuEl);

    while (menuEl) {
        CFTypeRef role = NULL;
        AXUIElementCopyAttributeValue(menuEl, kAXRoleAttribute, &role);
        BOOL isMenu = role && CFEqual(role, CFSTR("AXMenu"));
        if (role) CFRelease(role);
        if (isMenu) break;
        AXUIElementRef parent = NULL;
        AXUIElementCopyAttributeValue(menuEl, kAXParentAttribute, (CFTypeRef *)&parent);
        CFRelease(menuEl); menuEl = parent;
    }
    if (menuEl) {
        CFArrayRef kids = NULL;
        AXUIElementCopyAttributeValue(menuEl, kAXChildrenAttribute, (CFTypeRef *)&kids);
        for (CFIndex i = 0; kids && i < CFArrayGetCount(kids); i++) {
            AXUIElementRef row = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
            CFTypeRef title = NULL;
            AXUIElementCopyAttributeValue(row, kAXTitleAttribute, &title);
            NSString *t = (__bridge NSString *)title;
            BOOL match = t && [t rangeOfString:hover options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (title) CFRelease(title);
            if (!match) continue;
            CFTypeRef posv = NULL, sizev = NULL; CGPoint pos; CGSize sz;
            AXUIElementCopyAttributeValue(row, kAXPositionAttribute, &posv);
            AXUIElementCopyAttributeValue(row, kAXSizeAttribute, &sizev);
            AXValueGetValue(posv, kAXValueCGPointType, &pos);
            AXValueGetValue(sizev, kAXValueCGSizeType, &sz);
            CFRelease(posv); CFRelease(sizev);
            moveMouse(CGPointMake(pos.x + sz.width/2, pos.y + sz.height/2));
            usleep(550000);
            break;
        }
        if (kids) CFRelease(kids);
        CFRelease(menuEl);
    }
    CFRelease(app);

    NSArray *now = windowsForPID(pid, 101);
    NSDictionary *sub = now.firstObject;
    for (NSDictionary *w in now)
        if (rectOf(w).origin.x > rectOf(sub).origin.x) sub = w;
    capture(sub, out);
    usleep(150000);
    dismiss();
    return 0;
} }
