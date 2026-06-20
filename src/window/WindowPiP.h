#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WindowPiP : NSObject

+ (instancetype)shared;

- (BOOL)isActiveForApp:(pid_t)pid;
- (BOOL)toggleForApp:(pid_t)pid;
- (void)restoreAll;

@end

NS_ASSUME_NONNULL_END
