/*
 * DisplayDisabler - Lightweight tool to disable built-in display on Apple Silicon
 * Reverse-engineered from BetterDisplay behavior
 * 
 * Compilation:
 *   clang -framework CoreGraphics -framework Foundation display_disable.m -o display_disable
 * 
 * Usage:
 *   ./display_disable list              # List all displays
 *   ./display_disable disable <ID>      # Disable specific display
 *   ./display_disable disable-builtin   # Auto-disable built-in display
 *   ./display_disable enable <ID>       # Re-enable display
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Private API declarations (not in public headers)
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, 
                                          CGDirectDisplayID display, 
                                          bool enabled);

void listDisplays() {
    uint32_t displayCount;
    CGDirectDisplayID displays[10];
    
    CGGetActiveDisplayList(10, displays, &displayCount);
    
    printf("=== Active Displays ===\n");
    for (int i = 0; i < displayCount; i++) {
        CGDirectDisplayID displayID = displays[i];
        
        printf("\nDisplay %d:\n", i);
        printf("  ID: 0x%x (%u)\n", displayID, displayID);
        printf("  Built-in: %s\n", CGDisplayIsBuiltin(displayID) ? "YES" : "NO");
        printf("  Main: %s\n", CGDisplayIsMain(displayID) ? "YES" : "NO");
        printf("  Resolution: %zu x %zu\n", 
               CGDisplayPixelsWide(displayID), 
               CGDisplayPixelsHigh(displayID));
        
        // Get display name via IOKit (more complex, simplified here)
        printf("  Active: YES\n");
    }
    
    printf("\n=== Online Displays ===\n");
    CGGetOnlineDisplayList(10, displays, &displayCount);
    printf("Online display count: %u\n", displayCount);
}

CGDirectDisplayID findBuiltInDisplay() {
    uint32_t displayCount;
    CGDirectDisplayID displays[10];
    
    CGGetOnlineDisplayList(10, displays, &displayCount);
    
    for (int i = 0; i < displayCount; i++) {
        if (CGDisplayIsBuiltin(displays[i])) {
            return displays[i];
        }
    }
    
    return 0; // Not found
}

bool disableDisplay(CGDirectDisplayID displayID) {
    CGDisplayConfigRef config;
    CGError err;
    
    // Begin configuration transaction
    err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "Error: Failed to begin display configuration (error %d)\n", err);
        return false;
    }
    
    // Disable the display using private API
    err = CGSConfigureDisplayEnabled(config, displayID, false);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "Error: Failed to disable display (error %d)\n", err);
        CGCancelDisplayConfiguration(config);
        return false;
    }
    
    // Commit changes permanently
    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "Error: Failed to commit display configuration (error %d)\n", err);
        return false;
    }
    
    printf("✅ Display 0x%x disabled successfully\n", displayID);
    return true;
}

bool enableDisplay(CGDirectDisplayID displayID) {
    CGDisplayConfigRef config;
    CGError err;
    
    err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "Error: Failed to begin display configuration (error %d)\n", err);
        return false;
    }
    
    // Enable the display
    err = CGSConfigureDisplayEnabled(config, displayID, true);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "Error: Failed to enable display (error %d)\n", err);
        CGCancelDisplayConfiguration(config);
        return false;
    }
    
    err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "Error: Failed to commit display configuration (error %d)\n", err);
        return false;
    }
    
    printf("✅ Display 0x%x enabled successfully\n", displayID);
    return true;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            printf("Usage:\n");
            printf("  %s list              # List all displays\n", argv[0]);
            printf("  %s disable <ID>      # Disable specific display (hex or decimal)\n", argv[0]);
            printf("  %s disable-builtin   # Auto-disable built-in display\n", argv[0]);
            printf("  %s enable <ID>       # Re-enable display\n", argv[0]);
            return 1;
        }
        
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        
        if ([command isEqualToString:@"list"]) {
            listDisplays();
            return 0;
        }
        
        if ([command isEqualToString:@"disable-builtin"]) {
            CGDirectDisplayID builtInID = findBuiltInDisplay();
            
            if (builtInID == 0) {
                printf("⚠️  No built-in display found\n");
                return 0;
            }
            
            printf("Found built-in display: 0x%x\n", builtInID);
            
            if (disableDisplay(builtInID)) {
                printf("✅ Built-in display disabled successfully!\n");
                printf("\nTo re-enable: %s enable 0x%x\n", argv[0], builtInID);
                return 0;
            } else {
                return 1;
            }
        }
        
        if ([command isEqualToString:@"disable"] || [command isEqualToString:@"enable"]) {
            if (argc < 3) {
                fprintf(stderr, "Error: Display ID required\n");
                return 1;
            }
            
            // Parse display ID (hex or decimal)
            CGDirectDisplayID displayID;
            if (strncmp(argv[2], "0x", 2) == 0) {
                sscanf(argv[2], "%x", &displayID);
            } else {
                displayID = atoi(argv[2]);
            }
            
            if ([command isEqualToString:@"disable"]) {
                return disableDisplay(displayID) ? 0 : 1;
            } else {
                return enableDisplay(displayID) ? 0 : 1;
            }
        }
        
        fprintf(stderr, "Error: Unknown command '%s'\n", argv[1]);
        return 1;
    }
}
