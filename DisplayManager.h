#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

extern NSErrorDomain const DDErrorDomain;

typedef NS_ERROR_ENUM(DDErrorDomain, DDErrorCode) {
    DDErrorCGConfigFailed        = 1,
    DDErrorInvalidMode           = 2,
    DDErrorRequiresMacOS14       = 5,
    DDErrorAlreadyForced         = 6,
    DDErrorNotForced             = 7,
    DDErrorReadCurrentModeFailed = 8,
    DDErrorVirtualCreateFailed   = 9,
    DDErrorVirtualApplyFailed    = 10,
    DDErrorVirtualNoDisplayID    = 11,
};

@interface DDDisplayInfo : NSObject
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isBuiltIn;
@property (nonatomic) BOOL isActive;
@property (nonatomic) BOOL isMain;
@property (nonatomic) size_t pixelWidth;
@property (nonatomic) size_t pixelHeight;
@property (nonatomic) size_t logicalWidth;
@property (nonatomic) size_t logicalHeight;
@property (nonatomic) double refreshRate;
@property (nonatomic) BOOL isHiDPI;
@end

@interface DDDisplayMode : NSObject
@property (nonatomic) size_t pixelWidth;
@property (nonatomic) size_t pixelHeight;
@property (nonatomic) size_t logicalWidth;
@property (nonatomic) size_t logicalHeight;
@property (nonatomic) double refreshRate;
@property (nonatomic) BOOL isHiDPI;
@property (nonatomic) BOOL isCurrent;
@property (nonatomic) BOOL isDefaultForDisplay;
@property (nonatomic, nullable) CGDisplayModeRef modeRef;
@end

typedef void (^DisplayChangeBlock)(void);
typedef void (^DDForceHiDPICompletion)(BOOL success, NSError * _Nullable error);

@interface DisplayManager : NSObject

+ (instancetype)shared;

- (NSArray<DDDisplayInfo *> *)allDisplays;
- (NSArray<DDDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)displayID;
- (NSString *)nameForDisplayID:(CGDirectDisplayID)displayID;
- (nullable DDDisplayInfo *)builtInDisplay;
- (BOOL)hasExternalDisplay;
- (CGSize)nativePanelPixelsForDisplay:(CGDirectDisplayID)displayID;

- (BOOL)disableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)enableDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)setMode:(DDDisplayMode *)mode forDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;

- (void)forceHiDPIForDisplay:(CGDirectDisplayID)displayID
                      atMode:(nullable DDDisplayMode *)mode
                  completion:(DDForceHiDPICompletion)completion;
- (NSArray<DDDisplayMode *> *)forceHiDPIOptionsForDisplay:(CGDirectDisplayID)displayID;
- (BOOL)stopForcedHiDPIForDisplay:(CGDirectDisplayID)displayID error:(NSError **)error;
- (BOOL)isHiDPIForcedForDisplay:(CGDirectDisplayID)displayID;
- (nullable DDDisplayMode *)forcedTargetForDisplay:(CGDirectDisplayID)displayID;
- (void)cleanUpAllVirtualDisplays;
- (void)pruneStaleVirtualDisplays;
- (void)realignForcedDisplay;

- (void)startMonitoringWithChangeHandler:(DisplayChangeBlock)handler;
- (void)stopMonitoring;

@end

NS_ASSUME_NONNULL_END
