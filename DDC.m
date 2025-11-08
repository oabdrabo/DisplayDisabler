/*
 * DDC.m — External-display DDC/CI control over Apple Silicon's IOAVService.
 *
 * Packet layout (write path, VCP "Set Feature" 0x03):
 *   byte 0: 0x80 | length    — 0x84 for a 4-byte payload
 *   byte 1: 0x03             — VCP "Set Feature Request"
 *   byte 2: vcp code         — 0x10 = brightness
 *   byte 3: value hi byte
 *   byte 4: value lo byte
 *   byte 5: checksum         — XOR of 0x6E, source addr, bytes 0..4
 *
 * Derived from the m1ddc reverse-engineering work (MIT licensed).
 */

#import "DDC.h"
#import <IOKit/IOKitLib.h>

// ── Private API (runtime-resolved via declarations) ────────────────────────

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator,
                                                   io_service_t service)
    CF_RETURNS_RETAINED;
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

// CoreDisplay private: gives us the display's IODisplayLocation path so we
// can find the matching DCPAVServiceProxy in IORegistry.
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display)
    CF_RETURNS_RETAINED;

// ── DDC constants ──────────────────────────────────────────────────────────

static NSErrorDomain const kDDCErrorDomain = @"com.local.DisplayDisabler.DDC";

static const uint8_t kDDCChipAddress   = 0x37;  // standard DDC device address
static const uint8_t kDDCSourceAddress = 0x51;  // host input address
static const uint8_t kDDCVCPBrightness = 0x10;  // VESA VCP: brightness

// Some panels reject commands issued too quickly after power-on or mode change.
// 10 ms is the conservative baseline m1ddc uses.
static const useconds_t kDDCSettleUs = 10000;
// A single write is occasionally dropped; two attempts is enough in practice.
static const int kDDCAttempts = 2;

// ── Helpers ────────────────────────────────────────────────────────────────

static NSError *ddcError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kDDCErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// ── Implementation ─────────────────────────────────────────────────────────

@interface DDC ()
// Cache: per-display AV service, lazily discovered.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *services;
@end

@implementation DDC

+ (instancetype)shared {
    static DDC *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[DDC alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) { _services = [NSMutableDictionary dictionary]; }
    return self;
}

// Resolve the display's IODisplayLocation and scan IORegistry for the
// DCPAVServiceProxy sibling whose path starts with that location. Returns
// a retained IOAVServiceRef that callers hand back to the dict for caching.
- (IOAVServiceRef)resolveAVServiceFor:(CGDirectDisplayID)displayID CF_RETURNS_RETAINED {
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    if (!info) return NULL;

    NSString *location = (__bridge NSString *)CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    CFRelease(info);
    if (location.length == 0) return NULL;

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iter = 0;
    if (IORegistryEntryCreateIterator(root, kIOServicePlane,
                                      kIORegistryIterateRecursively, &iter) != KERN_SUCCESS) {
        return NULL;
    }

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
            // Only "External" location proxies are the user-facing display.
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

- (BOOL)supportsBrightness:(CGDirectDisplayID)displayID {
    if (CGDisplayIsBuiltin(displayID)) return NO;
    return [self serviceFor:displayID] != NULL;
}

- (BOOL)setBrightnessPercent:(uint8_t)percent
                  forDisplay:(CGDirectDisplayID)displayID
                       error:(NSError **)error {
    if (percent > 100) percent = 100;

    IOAVServiceRef svc = [self serviceFor:displayID];
    if (!svc) {
        if (error) *error = ddcError(1, @"This display does not support DDC.");
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
        *error = ddcError(last,
            [NSString stringWithFormat:@"DDC write failed (IOReturn 0x%X).", last]);
    }
    return NO;
}

@end
