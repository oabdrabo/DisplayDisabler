#import "DDUtil.h"

NSError *DDError(NSErrorDomain domain, NSInteger code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:domain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

NSString *DDAppleScriptEscape(NSString *s) {
    NSString *o = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [o stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}
