#import "Caffeine.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

static NSString *const kActiveKey = @"CaffeineActive";
static NSString *const kExpiryKey = @"CaffeineExpiry";

@interface Caffeine ()
@property (nonatomic) IOPMAssertionID assertionID;
@property (nonatomic, readwrite) BOOL active;
@property (nonatomic, readwrite, nullable) NSDate *expiry;
@property (nonatomic, strong, nullable) NSTimer *timer;
@end

@implementation Caffeine

+ (instancetype)shared {
    static Caffeine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[Caffeine alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _assertionID = kIOPMNullAssertionID;
        [self restoreState];
    }
    return self;
}

- (void)restoreState {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kActiveKey]) return;
    NSDate *exp = [d objectForKey:kExpiryKey];
    if (exp && [exp timeIntervalSinceNow] <= 0) {
        [self persist];
        return;
    }
    [self activateForDuration:exp ? [exp timeIntervalSinceNow] : 0];
}

- (void)activateForDuration:(NSTimeInterval)duration {
    if (!self.active) {
        IOReturn r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionLevelOn,
            CFSTR("DisplayDeck keep awake"),
            &_assertionID);
        if (r != kIOReturnSuccess) return;
        self.active = YES;
    }

    [self.timer invalidate];
    self.timer = nil;
    self.expiry = nil;
    if (duration > 0) {
        self.expiry = [NSDate dateWithTimeIntervalSinceNow:duration];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:duration
                                                      target:self
                                                    selector:@selector(deactivate)
                                                    userInfo:nil
                                                     repeats:NO];
    }
    [self persist];
    [self changed];
}

- (void)deactivate {
    [self.timer invalidate];
    self.timer = nil;
    self.expiry = nil;
    if (self.active) {
        IOPMAssertionRelease(self.assertionID);
        self.assertionID = kIOPMNullAssertionID;
        self.active = NO;
    }
    [self persist];
    [self changed];
}

- (void)toggle {
    if (self.active) [self deactivate];
    else             [self activateForDuration:0];
}

- (void)persist {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:self.active forKey:kActiveKey];
    if (self.expiry) [d setObject:self.expiry forKey:kExpiryKey];
    else             [d removeObjectForKey:kExpiryKey];
}

- (void)changed {
    if (self.onChange) self.onChange();
}

@end
