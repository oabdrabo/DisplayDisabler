#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDWindow : NSObject
@property (nonatomic) uint32_t windowID;
@property (nonatomic) pid_t ownerPID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) float alpha;
@property (nonatomic) CGRect bounds;
@end

@interface DDAppWindows : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSArray<DDWindow *> *windows;
@end

@interface WindowTransparency : NSObject

+ (instancetype)shared;

- (BOOL)backendAvailable;
- (void)ensureBackendLoaded;

- (NSArray<DDAppWindows *> *)appsWithWindows;

- (BOOL)setAlpha:(float)alpha forWindow:(uint32_t)windowID error:(NSError **)error;
- (BOOL)setAlpha:(float)alpha forApp:(pid_t)pid error:(NSError **)error;
- (BOOL)setAlphaForAllWindows:(float)alpha error:(NSError **)error;
- (BOOL)resetAllWindows:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
