#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface HiDPIInjector : NSObject

+ (instancetype)shared;

- (NSArray<NSValue *> *)defaultResolutionsForDisplay:(CGDirectDisplayID)displayID;

- (BOOL)isInstalledForDisplay:(CGDirectDisplayID)displayID;

- (void)installForDisplay:(CGDirectDisplayID)displayID
              resolutions:(NSArray<NSValue *> *)sizes
               completion:(void (^)(BOOL ok, NSError * _Nullable err))completion;

- (void)uninstallForDisplay:(CGDirectDisplayID)displayID
                 completion:(void (^)(BOOL ok, NSError * _Nullable err))completion;

@end

NS_ASSUME_NONNULL_END
