#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDWindow : NSObject
@property (nonatomic) uint32_t windowID;
@property (nonatomic) float alpha;
@end

@interface DDAppWindows : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSArray<DDWindow *> *windows;
@end

@interface WindowTransparency : NSObject

+ (instancetype)shared;

@property (nonatomic) BOOL frostedBlur;

- (BOOL)backendAvailable;
- (void)ensureBackendLoaded;

- (NSArray<DDAppWindows *> *)appsWithWindows;

- (BOOL)setAlpha:(float)alpha forApp:(pid_t)pid error:(NSError **)error;
- (BOOL)setAlphaForAllWindows:(float)alpha error:(NSError **)error;
- (BOOL)resetAllWindows:(NSError **)error;
- (void)reapplyBlurForAllWindows;

@end

NS_ASSUME_NONNULL_END
