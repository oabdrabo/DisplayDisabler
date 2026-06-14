#import "WindowTransparency.h"
#import "DDUtil.h"
#import <AppKit/AppKit.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <errno.h>

static NSErrorDomain const kTransparencyErrorDomain = @"com.local.DisplayDisabler.Transparency";

static const uint8_t kSAOpcodeWindowOpacity = 0x07;
static const uint8_t kSAOpcodeWindowBlur    = 0x08;
static const uint8_t kSAOpcodeWindowLevel   = 0x09;
static const int kMaxBlurRadius = 28;

@interface WindowTransparency ()
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pinnedWindowIDs;
@end

@implementation DDWindow
@end

@implementation DDAppWindows
@end

@implementation WindowTransparency

+ (instancetype)shared {
    static WindowTransparency *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[WindowTransparency alloc] init]; });
    return instance;
}

- (NSMutableSet<NSNumber *> *)pinnedWindowIDs {
    if (!_pinnedWindowIDs) _pinnedWindowIDs = [NSMutableSet set];
    return _pinnedWindowIDs;
}

- (NSString *)socketPath {
    return [NSString stringWithFormat:@"/tmp/displaydisabler-sa_%@.socket", NSUserName()];
}

- (int)connectedSocketFD {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, [self socketPath].fileSystemRepresentation,
            sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)backendAvailable {
    int fd = [self connectedSocketFD];
    if (fd < 0) return NO;
    close(fd);
    return YES;
}

static NSString *const kSALoaderPath = @"/Library/DisplayDisabler/loader";

- (BOOL)runTask:(NSString *)launchPath args:(NSArray<NSString *> *)args {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:launchPath];
    task.arguments = args;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError  = [NSFileHandle fileHandleWithNullDevice];
    NSError *e = nil;
    if (![task launchAndReturnError:&e]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

- (BOOL)reloadSilently {
    if ([self backendAvailable]) return YES;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:kSALoaderPath]) {
        [self runTask:@"/usr/bin/sudo" args:@[@"-n", kSALoaderPath]];
    }
    return [self backendAvailable];
}

static NSString *shellQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'",
            [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (NSString *)bundleSADir {
    return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"sa"];
}

- (BOOL)installedSAMatchesBundle {
    NSData *inst = [NSData dataWithContentsOfFile:@"/Library/DisplayDisabler/payload"];
    NSData *bund = [NSData dataWithContentsOfFile:
        [[self bundleSADir] stringByAppendingPathComponent:@"payload"]];
    return inst && bund && [inst isEqualToData:bund];
}

- (void)restartDockAndInject {
    [self runTask:@"/usr/bin/killall" args:@[@"Dock"]];
    for (int i = 0; i < 20; i++) {
        usleep(300000);
        [self runTask:@"/usr/bin/sudo" args:@[@"-n", kSALoaderPath]];
        if ([self backendAvailable]) return;
    }
}

- (void)ensureBackendLoaded {
    if ([self installedSAMatchesBundle] && [self reloadSilently]) return;

    NSString *saDir = [self bundleSADir];
    if (![[NSFileManager defaultManager]
            isReadableFileAtPath:[saDir stringByAppendingPathComponent:@"loader"]]) {
        NSLog(@"DisplayDisabler: bundled scripting addition missing in %@", saDir);
        return;
    }

    NSString *sudoLine = shellQuote([NSString stringWithFormat:
        @"%@ ALL=(root) NOPASSWD: %@", NSUserName(), kSALoaderPath]);
    NSString *cmd = [NSString stringWithFormat:
        @"mkdir -p /Library/DisplayDisabler && "
        @"cp %@ /Library/DisplayDisabler/loader && "
        @"cp %@ /Library/DisplayDisabler/payload && "
        @"chown -R root:wheel /Library/DisplayDisabler && "
        @"chmod -R 755 /Library/DisplayDisabler && "
        @"echo %@ > /etc/sudoers.d/displaydisabler && "
        @"chmod 440 /etc/sudoers.d/displaydisabler",
        shellQuote([saDir stringByAppendingPathComponent:@"loader"]),
        shellQuote([saDir stringByAppendingPathComponent:@"payload"]),
        sudoLine];

    NSString *source = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", DDAppleScriptEscape(cmd)];
    NSDictionary *err = nil;
    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&err];
    if (err) { NSLog(@"DisplayDisabler: SA install failed: %@", err); return; }

    [self restartDockAndInject];
}

- (NSArray<DDAppWindows *> *)appsWithWindows {
    CGWindowListOption opts = kCGWindowListOptionOnScreenOnly |
                             kCGWindowListExcludeDesktopElements;
    CFArrayRef list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID);
    if (!list) return @[];

    pid_t selfPID = NSProcessInfo.processInfo.processIdentifier;
    NSMutableDictionary<NSNumber *, DDAppWindows *> *byPID = [NSMutableDictionary dictionary];
    NSMutableArray<DDAppWindows *> *order = [NSMutableArray array];

    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);

        uint32_t wid = [(NSNumber *)info[(__bridge NSString *)kCGWindowNumber] unsignedIntValue];
        BOOL isPinned = [self.pinnedWindowIDs containsObject:@(wid)];

        NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
        if (layer.intValue != 0 && !isPinned) continue;

        NSNumber *pidNum = info[(__bridge NSString *)kCGWindowOwnerPID];
        if (!pidNum || pidNum.intValue == selfPID) continue;

        CGRect bounds = CGRectZero;
        CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], &bounds);
        if (bounds.size.width < 80 || bounds.size.height < 80) continue;

        DDWindow *w = [[DDWindow alloc] init];
        w.windowID = wid;
        w.alpha    = [(NSNumber *)info[(__bridge NSString *)kCGWindowAlpha] floatValue];

        DDAppWindows *app = byPID[pidNum];
        if (!app) {
            app = [[DDAppWindows alloc] init];
            app.pid     = pidNum.intValue;
            app.name    = info[(__bridge NSString *)kCGWindowOwnerName] ?: @"Unknown";
            app.windows = @[];
            byPID[pidNum] = app;
            [order addObject:app];
        }
        if (isPinned) app.pinned = YES;
        app.windows = [app.windows arrayByAddingObject:w];
    }
    CFRelease(list);

    [order sortUsingComparator:^NSComparisonResult(DDAppWindows *a, DDAppWindows *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return order;
}

- (BOOL)sendOpcode:(uint8_t)opcode payload:(const void *)payload length:(size_t)payloadLen
             error:(NSError **)error {
    int fd = [self connectedSocketFD];
    if (fd < 0) {
        if (error) *error = DDError(kTransparencyErrorDomain, 1,
            @"Transparency backend (scripting addition) is not loaded.");
        return NO;
    }

    char bytes[0x1000];
    int16_t length = 1 + (int16_t)sizeof(int16_t);
    bytes[sizeof(int16_t)] = (char)opcode;
    memcpy(bytes + length, payload, payloadLen); length += payloadLen;
    *(int16_t *)bytes = length - (int16_t)sizeof(int16_t);

    ssize_t sent = send(fd, bytes, length, 0);
    close(fd);
    if (sent != length) {
        if (error) *error = DDError(kTransparencyErrorDomain, errno, @"Failed to send to backend.");
        return NO;
    }
    return YES;
}

- (BOOL)applyAlpha:(float)alpha toWindowID:(uint32_t)windowID error:(NSError **)error {
    struct { uint32_t wid; float alpha; float duration; } p = { windowID, alpha, 0.0f };
    return [self sendOpcode:kSAOpcodeWindowOpacity payload:&p length:sizeof p error:error];
}

- (BOOL)applyBlur:(int)radius toWindowID:(uint32_t)windowID error:(NSError **)error {
    struct { uint32_t wid; int radius; } p = { windowID, radius };
    return [self sendOpcode:kSAOpcodeWindowBlur payload:&p length:sizeof p error:error];
}

- (BOOL)applyAlpha:(float)alpha toWindowsMatching:(BOOL (^)(DDAppWindows *app))match
             error:(NSError **)error {
    [self reloadSilently];
    BOOL all = YES;
    NSError *first = nil;
    for (DDAppWindows *app in [self appsWithWindows]) {
        if (match && !match(app)) continue;
        for (DDWindow *w in app.windows) {
            NSError *e = nil;
            if (![self applyAlpha:alpha toWindowID:w.windowID error:&e]) {
                all = NO;
                if (!first) first = e;
            }
            if (self.frostedBlur) {
                int radius = (int)lroundf((1.0f - alpha) * kMaxBlurRadius);
                [self applyBlur:radius toWindowID:w.windowID error:NULL];
            }
        }
    }
    if (!all && error) *error = first;
    return all;
}

- (BOOL)setAlpha:(float)alpha forApp:(pid_t)pid error:(NSError **)error {
    return [self applyAlpha:alpha toWindowsMatching:^BOOL(DDAppWindows *app) {
        return app.pid == pid;
    } error:error];
}

- (BOOL)setAlphaForAllWindows:(float)alpha error:(NSError **)error {
    return [self applyAlpha:alpha toWindowsMatching:nil error:error];
}

- (BOOL)resetAllWindows:(NSError **)error {
    return [self setAlphaForAllWindows:1.0f error:error];
}

- (void)reapplyBlurForAllWindows {
    [self reloadSilently];
    for (DDAppWindows *app in [self appsWithWindows]) {
        for (DDWindow *w in app.windows) {
            int radius = self.frostedBlur
                ? (int)lroundf((1.0f - w.alpha) * kMaxBlurRadius) : 0;
            [self applyBlur:radius toWindowID:w.windowID error:NULL];
        }
    }
}

- (BOOL)applyLevel:(int)level toWindowID:(uint32_t)windowID error:(NSError **)error {
    struct { uint32_t wid; int level; } p = { windowID, level };
    return [self sendOpcode:kSAOpcodeWindowLevel payload:&p length:sizeof p error:error];
}

- (BOOL)setPinned:(BOOL)pinned forApp:(pid_t)pid error:(NSError **)error {
    [self reloadSilently];
    int level = pinned ? (int)CGWindowLevelForKey(kCGFloatingWindowLevelKey) : 0;
    BOOL all = YES;
    NSError *first = nil;
    for (DDAppWindows *app in [self appsWithWindows]) {
        if (app.pid != pid) continue;
        for (DDWindow *w in app.windows) {
            NSError *e = nil;
            if (![self applyLevel:level toWindowID:w.windowID error:&e]) {
                all = NO;
                if (!first) first = e;
            }
            if (pinned) [self.pinnedWindowIDs addObject:@(w.windowID)];
            else        [self.pinnedWindowIDs removeObject:@(w.windowID)];
        }
    }
    if (!all && error) *error = first;
    return all;
}

@end
