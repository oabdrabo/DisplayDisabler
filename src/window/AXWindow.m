#import "AXWindow.h"
#import <Cocoa/Cocoa.h>

BOOL DDAXTrusted(void) {
    return AXIsProcessTrusted();
}

void DDAXRequestTrust(void) {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

BOOL DDAXCopyFrame(AXUIElementRef window, CGRect *outFrame) {
    CFTypeRef pv = NULL, sv = NULL;
    CGPoint p; CGSize s;
    if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &pv) != kAXErrorSuccess) return NO;
    if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &sv) != kAXErrorSuccess) {
        CFRelease(pv);
        return NO;
    }
    BOOL ok = AXValueGetValue(pv, kAXValueCGPointType, &p) &&
              AXValueGetValue(sv, kAXValueCGSizeType, &s);
    CFRelease(pv); CFRelease(sv);
    if (ok) *outFrame = CGRectMake(p.x, p.y, s.width, s.height);
    return ok;
}

void DDAXSetFrame(AXUIElementRef window, CGRect frame) {
    AXValueRef pos = AXValueCreate(kAXValueCGPointType, &frame.origin);
    AXValueRef siz = AXValueCreate(kAXValueCGSizeType, &frame.size);
    AXUIElementSetAttributeValue(window, kAXPositionAttribute, pos);
    AXUIElementSetAttributeValue(window, kAXSizeAttribute, siz);
    AXUIElementSetAttributeValue(window, kAXPositionAttribute, pos);
    CFRelease(pos); CFRelease(siz);
}

void DDAXRaise(AXUIElementRef window) {
    AXUIElementPerformAction(window, kAXRaiseAction);
}

void DDAXActivateApp(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return;
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, kCFBooleanTrue);
    CFRelease(app);
}

#pragma mark - Managed window enumeration

@interface DDManagedWindow ()
@property (nonatomic) NSInteger zIndex;
- (instancetype)initWithWindow:(AXUIElementRef)window pid:(pid_t)pid frame:(CGRect)frame;
@end

@implementation DDManagedWindow {
    AXUIElementRef _window;
}

- (instancetype)initWithWindow:(AXUIElementRef)window pid:(pid_t)pid frame:(CGRect)frame {
    self = [super init];
    if (self) {
        _window = (AXUIElementRef)CFRetain(window);
        _pid = pid;
        _frame = frame;
    }
    return self;
}

- (void)dealloc { if (_window) CFRelease(_window); }
- (AXUIElementRef)window { return _window; }

@end

static NSString *axStringAttr(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return nil;
    NSString *out = (CFGetTypeID(v) == CFStringGetTypeID()) ? [(__bridge NSString *)v copy] : nil;
    CFRelease(v);
    return out;
}

static BOOL axBoolAttr(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) != kAXErrorSuccess || !v) return NO;
    BOOL b = (CFGetTypeID(v) == CFBooleanGetTypeID()) && CFBooleanGetValue(v);
    CFRelease(v);
    return b;
}

static BOOL axIsStandardWindow(AXUIElementRef win) {
    if (![axStringAttr(win, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXWindowRole])
        return NO;
    if (![axStringAttr(win, kAXSubroleAttribute) isEqualToString:(__bridge NSString *)kAXStandardWindowSubrole])
        return NO;
    return !axBoolAttr(win, kAXMinimizedAttribute);
}

NSArray<DDManagedWindow *> *DDAXManageableWindowsOnScreen(CGRect visibleFrame) {
    NSMutableArray<NSDictionary *> *order = [NSMutableArray array];
    CFArrayRef cg = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (cg) {
        NSInteger idx = 0;
        for (NSDictionary *info in (__bridge NSArray *)cg) {
            if ([info[(__bridge NSString *)kCGWindowLayer] integerValue] != 0) continue;
            CGRect b = CGRectZero;
            CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], &b);
            [order addObject:@{ @"pid": info[(__bridge NSString *)kCGWindowOwnerPID] ?: @0,
                                @"cx":  @(CGRectGetMidX(b)),
                                @"cy":  @(CGRectGetMidY(b)),
                                @"idx": @(idx++) }];
        }
        CFRelease(cg);
    }

    NSMutableArray<DDManagedWindow *> *out = [NSMutableArray array];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular || app.terminated) continue;
        pid_t pid = app.processIdentifier;
        AXUIElementRef appEl = AXUIElementCreateApplication(pid);
        if (!appEl) continue;
        CFTypeRef wins = NULL;
        if (AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins) {
            for (id w in (__bridge NSArray *)wins) {
                AXUIElementRef win = (__bridge AXUIElementRef)w;
                CGRect f;
                if (!axIsStandardWindow(win) || !DDAXCopyFrame(win, &f)) continue;
                CGPoint c = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
                if (!CGRectContainsPoint(visibleFrame, c)) continue;

                DDManagedWindow *m = [[DDManagedWindow alloc] initWithWindow:win pid:pid frame:f];
                m.zIndex = NSIntegerMax;
                double bestDist = 1e18;
                for (NSDictionary *e in order) {
                    if ([e[@"pid"] intValue] != pid) continue;
                    double dx = [e[@"cx"] doubleValue] - c.x, dy = [e[@"cy"] doubleValue] - c.y;
                    double d = dx*dx + dy*dy;
                    if (d < bestDist) { bestDist = d; m.zIndex = [e[@"idx"] integerValue]; }
                }
                [out addObject:m];
            }
            CFRelease(wins);
        }
        CFRelease(appEl);
    }

    [out sortUsingComparator:^NSComparisonResult(DDManagedWindow *a, DDManagedWindow *b) {
        if (a.zIndex < b.zIndex) return NSOrderedAscending;
        if (a.zIndex > b.zIndex) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}
