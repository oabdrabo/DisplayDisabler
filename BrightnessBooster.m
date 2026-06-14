#import "BrightnessBooster.h"
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

static NSScreen *screenForDisplay(CGDirectDisplayID did);

static const float kHeadroomProbeStep = 0.1f;

@interface DDBoost : NSObject
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic) float boost;
@property (nonatomic) float presented;
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

        NSScreen *s = screenForDisplay(self.displayID);
        float headroom = s ? (float)s.maximumExtendedDynamicRangeColorComponentValue : 1.0f;
        float eff = MIN(self.boost, headroom + kHeadroomProbeStep);
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

@interface BrightnessBooster ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, DDBoost *> *boosts;
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
    }
    return self;
}

- (BOOL)available {
    return self.device != nil;
}

- (float)maxBoostForDisplay:(CGDirectDisplayID)displayID {
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
    w.level = NSScreenSaverWindowLevel;
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
    ml.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
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
