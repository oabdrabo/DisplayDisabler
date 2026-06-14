#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSError *DDError(NSErrorDomain domain, NSInteger code, NSString *format, ...)
    NS_FORMAT_FUNCTION(3, 4);
NSString *DDAppleScriptEscape(NSString *s);

NS_ASSUME_NONNULL_END
