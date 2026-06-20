#import "WindowPiP.h"
#import "WindowTransparency.h"
#import "AXWindow.h"
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

- (BOOL)toggleForApp:(pid_t)pid {
    if (!DDAXTrusted()) {
        DDAXRequestTrust();
        return NO;
    }
    AXUIElementRef w = copyMainWindow(pid);
    if (!w) return [self isActiveForApp:pid];

    BOOL nowActive;
    if ([self isActiveForApp:pid]) {
        CGRect f = self.savedFrames[@(pid)].rectValue;
        DDAXSetFrame(w, f);
        [self.savedFrames removeObjectForKey:@(pid)];
        [[WindowTransparency shared] setPinned:NO forApp:pid error:NULL];
        nowActive = NO;
    } else {
        CGRect cur;
        if (!DDAXCopyFrame(w, &cur) || cur.size.width < 1) {
            CFRelease(w);
            return NO;
        }
        self.savedFrames[@(pid)] = [NSValue valueWithRect:cur];
        CGRect screen = CGDisplayBounds(CGMainDisplayID());
        CGSize size = CGSizeMake(kPiPWidth, kPiPWidth * cur.size.height / cur.size.width);
        CGPoint origin = CGPointMake(
            screen.origin.x + screen.size.width  - size.width  - kPiPMargin,
            screen.origin.y + screen.size.height - size.height - kPiPMargin);
        DDAXSetFrame(w, (CGRect){ origin, size });
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
