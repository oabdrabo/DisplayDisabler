/*
 * DisplayManager.h — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Private API declarations
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

// ── CGVirtualDisplay private API (macOS 14+, resolved at runtime) ───────────

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id display, id error);
@property (nonatomic) NSUInteger vendorID;
@property (nonatomic) NSUInteger productID;
@property (nonatomic) NSUInteger serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

// ── Display info model ──────────────────────────────────────────────────────

@interface DDDisplayInfo : NSObject
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isBuiltIn;
@property (nonatomic) BOOL isActive;
@property (nonatomic) BOOL isMain;
@property (nonatomic) NSSize physicalSizeMM;
// Current mode (only valid when isActive)
@property (nonatomic) size_t pixelWidth;
@property (nonatomic) size_t pixelHeight;
@property (nonatomic) size_t logicalWidth;
@property (nonatomic) size_t logicalHeight;
@property (nonatomic) double refreshRate;
@property (nonatomic) BOOL isHiDPI;
@property (nonatomic) BOOL hasNativeHiDPIModes;
@end

// ── Display mode model ──────────────────────────────────────────────────────

@interface DDDisplayMode : NSObject
@property (nonatomic) size_t pixelWidth;
@property (nonatomic) size_t pixelHeight;
@property (nonatomic) size_t logicalWidth;
@property (nonatomic) size_t logicalHeight;
@property (nonatomic) double refreshRate;
@property (nonatomic) BOOL isHiDPI;
@property (nonatomic) BOOL isCurrent;
@property (nonatomic) CGDisplayModeRef modeRef;  // retained for setMode
@end

// ── Display manager ─────────────────────────────────────────────────────────

typedef void (^DisplayChangeBlock)(void);

@interface DisplayManager : NSObject

+ (instancetype)shared;

// Query
- (NSArray<DDDisplayInfo *> *)allDisplays;
- (NSArray<DDDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)displayID;
- (NSString *)nameForDisplayID:(CGDirectDisplayID)displayID;
- (DDDisplayInfo *)builtInDisplay;
- (BOOL)hasExternalDisplay;

// Actions
- (BOOL)disableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)enableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)setMode:(DDDisplayMode *)mode forDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;

// HiDPI forcing (macOS 14+ only — uses CGVirtualDisplay)
- (BOOL)forceHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID;
- (BOOL)displayHasNativeHiDPIModes:(CGDirectDisplayID)displayID;
- (void)cleanUpAllVirtualDisplays;
- (void)pruneStaleVirtualDisplays;

// Monitoring
- (void)startMonitoringWithChangeHandler:(DisplayChangeBlock)handler;
- (void)stopMonitoring;

@end
