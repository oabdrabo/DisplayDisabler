#import "WindowPiP.h"
#import "WindowTransparency.h"
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static const CGFloat kPiPWidth = 480.0;
static const CGFloat kPiPMargin = 16.0;

@interface WindowPiP ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *savedFrames;
@end

@implementation WindowPiP

+ (instancetype)shared {
    static WindowPiP *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[WindowPiP alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) _savedFrames = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)hasAccessibility {
    return AXIsProcessTrusted();
}

- (void)requestAccessibility {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

- (BOOL)isActiveForApp:(pid_t)pid {
    return self.savedFrames[@(pid)] != nil;
}

static AXUIElementRef copyMainWindow(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return NULL;
    AXUIElementRef win = NULL;
    CFTypeRef main = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &main) == kAXErrorSuccess && main) {
        win = (AXUIElementRef)main;
    } else {
        CFTypeRef wins = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins) {
            if (CFArrayGetCount(wins) > 0) {
                win = (AXUIElementRef)CFRetain(CFArrayGetValueAtIndex(wins, 0));
            }
            CFRelease(wins);
        }
    }
    CFRelease(app);
    return win;
}

static BOOL axGetFrame(AXUIElementRef w, CGRect *out) {
    CFTypeRef pv = NULL, sv = NULL;
    CGPoint p; CGSize s;
    if (AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &pv) != kAXErrorSuccess) return NO;
    if (AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &sv) != kAXErrorSuccess) {
        CFRelease(pv);
        return NO;
    }
    BOOL ok = AXValueGetValue(pv, kAXValueCGPointType, &p) &&
              AXValueGetValue(sv, kAXValueCGSizeType, &s);
    CFRelease(pv); CFRelease(sv);
    if (ok) *out = CGRectMake(p.x, p.y, s.width, s.height);
    return ok;
}

static void axSetPos(AXUIElementRef w, CGPoint p) {
    AXValueRef v = AXValueCreate(kAXValueCGPointType, &p);
    AXUIElementSetAttributeValue(w, kAXPositionAttribute, v);
    CFRelease(v);
}

static void axSetSize(AXUIElementRef w, CGSize s) {
    AXValueRef v = AXValueCreate(kAXValueCGSizeType, &s);
    AXUIElementSetAttributeValue(w, kAXSizeAttribute, v);
    CFRelease(v);
}

- (BOOL)toggleForApp:(pid_t)pid {
    if (![self hasAccessibility]) {
        [self requestAccessibility];
        return NO;
    }
    AXUIElementRef w = copyMainWindow(pid);
    if (!w) return [self isActiveForApp:pid];

    BOOL nowActive;
    if ([self isActiveForApp:pid]) {
        CGRect f = self.savedFrames[@(pid)].rectValue;
        axSetPos(w, f.origin);
        axSetSize(w, f.size);
        axSetPos(w, f.origin);
        [self.savedFrames removeObjectForKey:@(pid)];
        [[WindowTransparency shared] setPinned:NO forApp:pid error:NULL];
        nowActive = NO;
    } else {
        CGRect cur;
        if (!axGetFrame(w, &cur) || cur.size.width < 1) {
            CFRelease(w);
            return NO;
        }
        self.savedFrames[@(pid)] = [NSValue valueWithRect:cur];
        CGRect screen = CGDisplayBounds(CGMainDisplayID());
        CGSize size = CGSizeMake(kPiPWidth, kPiPWidth * cur.size.height / cur.size.width);
        CGPoint origin = CGPointMake(
            screen.origin.x + screen.size.width  - size.width  - kPiPMargin,
            screen.origin.y + screen.size.height - size.height - kPiPMargin);
        axSetSize(w, size);
        axSetPos(w, origin);
        [[WindowTransparency shared] setPinned:YES forApp:pid error:NULL];
        nowActive = YES;
    }
    CFRelease(w);
    return nowActive;
}

- (void)restoreAll {
    for (NSNumber *pidNum in [self.savedFrames allKeys]) {
        [self toggleForApp:pidNum.intValue];
    }
}

@end
