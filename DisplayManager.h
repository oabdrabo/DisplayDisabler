/*
 * DisplayManager.h — Display query, control, and monitoring
 * Part of DisplayDisabler v3.0
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Private API declaration
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

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

// Monitoring
- (void)startMonitoringWithChangeHandler:(DisplayChangeBlock)handler;
- (void)stopMonitoring;

@end
