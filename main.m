/*
 * main.m — Application entry point
 * Part of DisplayDisabler v3.0
 */

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc __unused, const char *argv[] __unused) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
