#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DDSnap) {
    DDSnapLeftHalf = 0,
    DDSnapRightHalf,
    DDSnapTopHalf,
    DDSnapBottomHalf,
    DDSnapTopLeft,
    DDSnapTopRight,
    DDSnapBottomLeft,
    DDSnapBottomRight,
    DDSnapLeftThird,
    DDSnapCenterThird,
    DDSnapRightThird,
    DDSnapLeftTwoThirds,
    DDSnapRightTwoThirds,
    DDSnapMaximize,
    DDSnapCenter,
    DDSnapRestore,
};

typedef NS_ENUM(NSInteger, DDArrange) {
    DDArrangeGrid = 0,
    DDArrangeCentered,
    DDArrangeCycle,
    DDArrangePromote,
    DDArrangeRotateNext,
    DDArrangeRotatePrev,
    DDArrangeRestore,
};

@interface WindowManager : NSObject

+ (instancetype)shared;

- (void)snap:(DDSnap)layout;

- (void)arrange:(DDArrange)command;

- (void)setHotkeysEnabled:(BOOL)enabled;

- (void)setDragSnapEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
