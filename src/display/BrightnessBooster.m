#import "BrightnessBooster.h"
#import "DDUtil.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

static NSScreen *screenForDisplay(CGDirectDisplayID did);

static BOOL fullScreenSystemOverlayActive(CGDirectDisplayID displayID) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,
                                                 kCGNullWindowID);
    if (!list) return NO;
    CGRect bounds = CGDisplayBounds(displayID);
    BOOL active = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
        if ([info[(__bridge NSString *)kCGWindowLayer] intValue] <= 0) continue;
        if (![info[(__bridge NSString *)kCGWindowOwnerName] isEqualToString:@"Dock"]) continue;
        CGRect b = CGRectZero;
        CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], &b);
        if (b.size.width >= bounds.size.width * 0.9 &&
            b.size.height >= bounds.size.height * 0.9) { active = YES; break; }
    }
    CFRelease(list);
    return active;
}

@interface DDBoost : NSObject
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic) float boost;
@property (nonatomic) float presented;
@property (nonatomic) float observedPeak;
@property (nonatomic) int pollCounter;
@property (nonatomic) BOOL suspended;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) CADisplayLink *link;
- (void)renderTick;
@end

@implementation DDBoost
- (void)renderTick {
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [self.layer nextDrawable];
        if (!drawable) return;

        if (self.pollCounter-- <= 0) {
            self.pollCounter = 6;
            BOOL sys = fullScreenSystemOverlayActive(self.displayID);
            if (sys != self.suspended) {
                self.suspended = sys;
                self.window.alphaValue = sys ? 0.0 : 1.0;
            }
        }

        NSScreen *s = screenForDisplay(self.displayID);
        float headroom = s ? (float)s.maximumExtendedDynamicRangeColorComponentValue : 1.0f;
        if (headroom > self.observedPeak) self.observedPeak = headroom;

        float eff = self.boost;
        if (eff < 1.0f) eff = 1.0f;
        self.presented = eff;

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(eff, eff, eff, 1.0);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [self.queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];
    }
}
- (void)teardown {
    [self.link invalidate];
    self.link = nil;
    [self.window orderOut:nil];
    self.window = nil;
}
@end

static NSScreen *screenForDisplay(CGDirectDisplayID did) {
    for (NSScreen *s in [NSScreen screens]) {
        if ([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == did) return s;
    }
    return nil;
}

static NSString *const kHeadroomKey = @"DDBoostHeadroom";

@interface BrightnessBooster ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, DDBoost *> *boosts;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *learnedHeadroom;
@end

@implementation BrightnessBooster

+ (instancetype)shared {
    static BrightnessBooster *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[BrightnessBooster alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _device = MTLCreateSystemDefaultDevice();
        _boosts = [NSMutableDictionary dictionary];
        _learnedHeadroom = DDLoadNumberMap(kHeadroomKey);
    }
    return self;
}

- (void)learnHeadroom:(float)peak forDisplay:(CGDirectDisplayID)displayID {
    if (peak <= 1.05f) return;
    NSNumber *prev = self.learnedHeadroom[@(displayID)];
    if (prev && prev.floatValue >= peak) return;
    self.learnedHeadroom[@(displayID)] = @(peak);
    DDSaveNumberMap(self.learnedHeadroom, kHeadroomKey);
}

- (float)maxBoostForDisplay:(CGDirectDisplayID)displayID {
    DDBoost *active = self.boosts[@(displayID)];
    if (active && active.observedPeak > 1.05f) return active.observedPeak;
    NSNumber *learned = self.learnedHeadroom[@(displayID)];
    if (learned && learned.floatValue > 1.05f) return learned.floatValue;

    NSScreen *s = screenForDisplay(displayID);
    float p = s ? (float)s.maximumPotentialExtendedDynamicRangeColorComponentValue : 1.0f;
    return p > 1.0f ? p : 1.0f;
}

- (float)boostForDisplay:(CGDirectDisplayID)displayID {
    DDBoost *b = self.boosts[@(displayID)];
    return b ? b.boost : 1.0f;
}

- (void)setBoost:(float)factor forDisplay:(CGDirectDisplayID)displayID {
    if (!self.device) return;

    if (factor <= 1.001f) {
        DDBoost *b = self.boosts[@(displayID)];
        if (b) {
            [self learnHeadroom:b.observedPeak forDisplay:displayID];
            [b teardown];
            [self.boosts removeObjectForKey:@(displayID)];
        }
        return;
    }

    NSScreen *screen = screenForDisplay(displayID);
    if (!screen) return;

    DDBoost *b = self.boosts[@(displayID)];
    if (!b) {
        b = [[DDBoost alloc] init];
        b.displayID = displayID;
        b.queue = [self.device newCommandQueue];
        [self buildWindowFor:b screen:screen];
        self.boosts[@(displayID)] = b;
    }
    b.boost = factor;
    [b renderTick];
}

- (void)buildWindowFor:(DDBoost *)b screen:(NSScreen *)screen {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:screen.frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO
                                                 screen:screen];
    w.level = NSModalPanelWindowLevel;
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    w.ignoresMouseEvents = YES;
    w.releasedWhenClosed = NO;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorStationary |
                           NSWindowCollectionBehaviorFullScreenAuxiliary |
                           NSWindowCollectionBehaviorIgnoresCycle;

    NSView *v = [[NSView alloc] initWithFrame:(NSRect){.size = screen.frame.size}];
    v.wantsLayer = YES;

    CAMetalLayer *ml = [CAMetalLayer layer];
    ml.device = self.device;
    ml.pixelFormat = MTLPixelFormatRGBA16Float;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    ml.colorspace = cs;
    CGColorSpaceRelease(cs);
    ml.wantsExtendedDynamicRangeContent = YES;
    ml.framebufferOnly = NO;
    ml.opaque = NO;
    ml.compositingFilter = @"multiplyBlendMode";
    ml.frame = v.bounds;
    ml.contentsScale = screen.backingScaleFactor;
    ml.drawableSize = CGSizeMake(screen.frame.size.width  * screen.backingScaleFactor,
                                 screen.frame.size.height * screen.backingScaleFactor);
    v.layer = ml;
    w.contentView = v;
    [w orderFrontRegardless];

    b.window = w;
    b.layer  = ml;
    b.link   = [v displayLinkWithTarget:b selector:@selector(renderTick)];
    [b.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)reapply {
    for (NSNumber *idNum in self.boosts.allKeys) {
        DDBoost *b = self.boosts[idNum];
        float f = b.boost;
        [b teardown];
        [self.boosts removeObjectForKey:idNum];
        [self setBoost:f forDisplay:idNum.unsignedIntValue];
    }
}

@end
