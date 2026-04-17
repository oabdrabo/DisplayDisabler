/*
 * build_icon.m — generate AppIcon.iconset from the "display" SF Symbol.
 * Not shipped. Invoked by `make icon` → iconutil → AppIcon.icns.
 */

#import <AppKit/AppKit.h>

static void renderAtSize(CGFloat size, NSString *path) {
    NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [out lockFocus];

    // Rounded-rect background — macOS app-icon corner radius ≈ 22%.
    CGFloat radius = size * 0.2237;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size, size)
                                                       xRadius:radius yRadius:radius];
    [[NSColor colorWithRed:0.125 green:0.133 blue:0.157 alpha:1.0] setFill];
    [bg fill];

    // Monochrome display glyph tinted white, ~55% of icon size.
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:nil];
    CGFloat pt = size * 0.55;
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
        configurationWithPointSize:pt weight:NSFontWeightRegular];
    if (@available(macOS 12.0, *)) {
        config = [config configurationByApplyingConfiguration:
                  [NSImageSymbolConfiguration configurationWithPaletteColors:
                   @[[NSColor whiteColor]]]];
    }
    NSImage *glyph = [symbol imageWithSymbolConfiguration:config];
    NSSize gs = glyph.size;
    NSRect gRect = NSMakeRect((size - gs.width) / 2.0,
                              (size - gs.height) / 2.0,
                              gs.width, gs.height);
    [glyph drawInRect:gRect];

    [out unlockFocus];

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:out.TIFFRepresentation];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:path atomically:YES]) {
        fprintf(stderr, "failed to write %s\n", path.UTF8String);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *dir = (argc > 1) ? @(argv[1]) : @"AppIcon.iconset";
        NSError *err = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                       withIntermediateDirectories:YES
                                                        attributes:nil error:&err]) {
            fprintf(stderr, "mkdir %s failed: %s\n", dir.UTF8String, err.localizedDescription.UTF8String);
            return 1;
        }

        // Sizes iconutil expects for a complete .icns.
        struct { CGFloat px; const char *name; } sizes[] = {
            {  16, "icon_16x16.png"     },
            {  32, "icon_16x16@2x.png"  },
            {  32, "icon_32x32.png"     },
            {  64, "icon_32x32@2x.png"  },
            { 128, "icon_128x128.png"   },
            { 256, "icon_128x128@2x.png"},
            { 256, "icon_256x256.png"   },
            { 512, "icon_256x256@2x.png"},
            { 512, "icon_512x512.png"   },
            {1024, "icon_512x512@2x.png"},
        };
        for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
            NSString *path = [dir stringByAppendingPathComponent:@(sizes[i].name)];
            renderAtSize(sizes[i].px, path);
        }
    }
    return 0;
}
