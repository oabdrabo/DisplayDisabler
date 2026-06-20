#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

NSError *DDError(NSErrorDomain domain, NSInteger code, NSString *format, ...)
    NS_FORMAT_FUNCTION(3, 4);
NSString *DDAppleScriptEscape(NSString *s);

NSMutableDictionary<NSNumber *, NSNumber *> *DDLoadNumberMap(NSString *key);
void DDSaveNumberMap(NSDictionary<NSNumber *, NSNumber *> *map, NSString *key);

typedef CGError (*DDDisplayListFn)(uint32_t, CGDirectDisplayID * _Nullable, uint32_t *);
NSArray<NSNumber *> *DDQueryDisplayList(DDDisplayListFn fn);

NS_ASSUME_NONNULL_END
