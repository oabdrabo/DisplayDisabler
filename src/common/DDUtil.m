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

NSMutableDictionary<NSNumber *, NSNumber *> *DDLoadNumberMap(NSString *key) {
    NSMutableDictionary<NSNumber *, NSNumber *> *map = [NSMutableDictionary dictionary];
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:key];
    for (NSString *k in saved) {
        if ([saved[k] isKindOfClass:[NSNumber class]]) map[@((uint32_t)k.longLongValue)] = saved[k];
    }
    return map;
}

void DDSaveNumberMap(NSDictionary<NSNumber *, NSNumber *> *map, NSString *key) {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    for (NSNumber *k in map) out[k.stringValue] = map[k];
    [[NSUserDefaults standardUserDefaults] setObject:out forKey:key];
}

NSArray<NSNumber *> *DDQueryDisplayList(DDDisplayListFn fn) {
    uint32_t count = 0;
    if (fn(0, NULL, &count) != kCGErrorSuccess || count == 0) return @[];
    CGDirectDisplayID *buf = calloc(count, sizeof *buf);
    if (!buf) return @[];
    CGError err = fn(count, buf, &count);
    if (err != kCGErrorSuccess) { free(buf); return @[]; }
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) [out addObject:@(buf[i])];
    free(buf);
    return out;
}
