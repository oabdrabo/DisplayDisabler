#import "Brightness.h"
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator,
                                                   io_service_t service)
    CF_RETURNS_RETAINED;
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display)
    CF_RETURNS_RETAINED;

typedef int (*DSSetFn)(CGDirectDisplayID, float);
typedef int (*DSGetFn)(CGDirectDisplayID, float *);
typedef int (*DSCanChangeFn)(CGDirectDisplayID);

typedef struct {
    DSSetFn         set;
    DSSetFn         setSmooth;
    DSGetFn         get;
    DSCanChangeFn   canChange;
} DSBrightnessFns;

static DSBrightnessFns dsBrightness(void) {
    static DSBrightnessFns f = {0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY);
        if (!h) return;
        f.set       = (DSSetFn)dlsym(h, "DisplayServicesSetBrightness");
        f.setSmooth = (DSSetFn)dlsym(h, "DisplayServicesSetBrightnessSmooth");
        f.get       = (DSGetFn)dlsym(h, "DisplayServicesGetBrightness");
        f.canChange = (DSCanChangeFn)dlsym(h, "DisplayServicesCanChangeBrightness");
    });
    return f;
}

static NSErrorDomain const kBrightnessErrorDomain = @"com.local.DisplayDisabler.Brightness";

static const uint8_t kDDCChipAddress   = 0x37;
static const uint8_t kDDCSourceAddress = 0x51;
static const uint8_t kDDCVCPBrightness = 0x10;
static const useconds_t kDDCSettleUs   = 10000;
static const int kDDCAttempts          = 2;

static NSError *brightnessError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kBrightnessErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface Brightness ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *services;
@end

@implementation Brightness

+ (instancetype)shared {
    static Brightness *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[Brightness alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) { _services = [NSMutableDictionary dictionary]; }
    return self;
}

- (IOAVServiceRef)resolveAVServiceFor:(CGDirectDisplayID)displayID CF_RETURNS_RETAINED {
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    if (!info) return NULL;

    NSString *location = (__bridge NSString *)CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    CFRelease(info);
    if (location.length == 0) return NULL;

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iter = 0;
    kern_return_t kr = IORegistryEntryCreateIterator(root, kIOServicePlane,
                                                     kIORegistryIterateRecursively, &iter);
    IOObjectRelease(root);
    if (kr != KERN_SUCCESS) return NULL;

    IOAVServiceRef found = NULL;
    BOOL foundParent = NO;
    io_service_t svc;

    while ((svc = IOIteratorNext(iter)) != MACH_PORT_NULL) {
        if (!foundParent) {
            io_string_t path;
            if (IORegistryEntryGetPath(svc, kIOServicePlane, path) == KERN_SUCCESS &&
                strcmp(path, location.UTF8String) == 0) {
                foundParent = YES;
            }
            IOObjectRelease(svc);
            continue;
        }

        io_name_t name = {0};
        if (IORegistryEntryGetName(svc, name) == KERN_SUCCESS &&
            strcmp(name, "DCPAVServiceProxy") == 0) {
            CFTypeRef loc = IORegistryEntrySearchCFProperty(
                svc, kIOServicePlane, CFSTR("Location"),
                kCFAllocatorDefault, kIORegistryIterateRecursively);
            BOOL isExternal = (loc && CFGetTypeID(loc) == CFStringGetTypeID() &&
                               CFStringCompare((CFStringRef)loc, CFSTR("External"), 0) == kCFCompareEqualTo);
            if (loc) CFRelease(loc);

            if (isExternal) {
                found = IOAVServiceCreateWithService(kCFAllocatorDefault, svc);
                IOObjectRelease(svc);
                break;
            }
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
    return found;
}

- (IOAVServiceRef)serviceFor:(CGDirectDisplayID)displayID {
    id cached = self.services[@(displayID)];
    if (cached) return (__bridge IOAVServiceRef)cached;

    IOAVServiceRef svc = [self resolveAVServiceFor:displayID];
    if (!svc) return NULL;

    self.services[@(displayID)] = (__bridge_transfer id)svc;
    return svc;
}

- (BOOL)setBrightnessViaDDC:(uint8_t)percent
                 forDisplay:(CGDirectDisplayID)displayID
                      error:(NSError **)error {
    IOAVServiceRef svc = [self serviceFor:displayID];
    if (!svc) {
        if (error) *error = brightnessError(1, @"This display does not support DDC.");
        return NO;
    }

    uint16_t value = percent;
    uint8_t pkt[6];
    pkt[0] = 0x84;
    pkt[1] = 0x03;
    pkt[2] = kDDCVCPBrightness;
    pkt[3] = (uint8_t)(value >> 8);
    pkt[4] = (uint8_t)(value & 0xFF);
    pkt[5] = 0x6E ^ kDDCSourceAddress ^ pkt[0] ^ pkt[1] ^ pkt[2] ^ pkt[3] ^ pkt[4];

    IOReturn last = kIOReturnError;
    for (int i = 0; i < kDDCAttempts; i++) {
        usleep(kDDCSettleUs);
        last = IOAVServiceWriteI2C(svc, kDDCChipAddress, kDDCSourceAddress, pkt, sizeof pkt);
        if (last == kIOReturnSuccess) return YES;
    }

    if (error) {
        *error = brightnessError(last,
            [NSString stringWithFormat:@"DDC write failed (IOReturn 0x%X).", last]);
    }
    return NO;
}

- (BOOL)setBrightnessViaDisplayServices:(uint8_t)percent
                             forDisplay:(CGDirectDisplayID)displayID
                                  error:(NSError **)error {
    DSBrightnessFns f = dsBrightness();
    DSSetFn setFn = f.setSmooth ?: f.set;
    if (!setFn) {
        if (error) *error = brightnessError(-1,
            @"DisplayServices is unavailable on this macOS version.");
        return NO;
    }

    int rc = setFn(displayID, percent / 100.0f);
    if (rc != 0) {
        if (error) *error = brightnessError(rc,
            [NSString stringWithFormat:@"DisplayServices rejected the brightness (rc=%d).", rc]);
        return NO;
    }
    return YES;
}

- (BOOL)supportsBrightness:(CGDirectDisplayID)displayID {
    if (CGDisplayIsBuiltin(displayID)) {
        DSBrightnessFns f = dsBrightness();
        if (!f.set && !f.setSmooth) return NO;
        return f.canChange ? (f.canChange(displayID) != 0) : YES;
    }
    return [self serviceFor:displayID] != NULL;
}

- (int)brightnessPercentForDisplay:(CGDirectDisplayID)displayID {
    if (!CGDisplayIsBuiltin(displayID)) return -1;
    DSBrightnessFns f = dsBrightness();
    if (!f.get) return -1;
    float v = -1;
    if (f.get(displayID, &v) != 0) return -1;
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    return (int)lroundf(v * 100.0f);
}

- (void)invalidateServiceCache {
    [self.services removeAllObjects];
}

- (BOOL)setBrightnessPercent:(uint8_t)percent
                  forDisplay:(CGDirectDisplayID)displayID
                       error:(NSError **)error {
    if (percent > 100) percent = 100;

    if (CGDisplayIsBuiltin(displayID)) {
        return [self setBrightnessViaDisplayServices:percent forDisplay:displayID error:error];
    }
    return [self setBrightnessViaDDC:percent forDisplay:displayID error:error];
}

@end
