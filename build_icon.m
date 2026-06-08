/*
 * build_icon.m — generate AppIcon.iconset and AppIcon.icns from the "display"
 * SF Symbol. Not shipped. Invoked by `make icon`.
 */

#import <AppKit/AppKit.h>

static NSData *renderAtSize(CGFloat size, NSString *path) {
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
    NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration
        configurationWithPointSize:pt weight:NSFontWeightRegular]
        configurationByApplyingConfiguration:
        [NSImageSymbolConfiguration configurationWithPaletteColors:
         @[[NSColor whiteColor]]]];
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
    return png;
}

static void appendBE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)((value >> 24) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)(value & 0xff),
    };
    [data appendBytes:bytes length:sizeof bytes];
}

static void appendFourCC(NSMutableData *data, const char *fourCC) {
    [data appendBytes:fourCC length:4];
}

static void writeICNS(NSArray<NSDictionary *> *chunks, NSString *path) {
    uint32_t totalLength = 8;
    for (NSDictionary *chunk in chunks) {
        NSData *png = chunk[@"png"];
        totalLength += 8 + (uint32_t)png.length;
    }

    NSMutableData *icns = [NSMutableData dataWithCapacity:totalLength];
    appendFourCC(icns, "icns");
    appendBE32(icns, totalLength);

    for (NSDictionary *chunk in chunks) {
        NSString *type = chunk[@"type"];
        NSData *png = chunk[@"png"];
        appendFourCC(icns, type.UTF8String);
        appendBE32(icns, 8 + (uint32_t)png.length);
        [icns appendData:png];
    }

    if (![icns writeToFile:path atomically:YES]) {
        fprintf(stderr, "failed to write %s\n", path.UTF8String);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *dir = (argc > 1) ? @(argv[1]) : @"AppIcon.iconset";
        NSString *icnsPath = (argc > 2) ? @(argv[2]) : @"AppIcon.icns";
        NSError *err = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                       withIntermediateDirectories:YES
                                                        attributes:nil error:&err]) {
            fprintf(stderr, "mkdir %s failed: %s\n", dir.UTF8String, err.localizedDescription.UTF8String);
            return 1;
        }

        // File names match iconutil's conventional iconset layout. The ICNS
        // writer stores one PNG chunk per unique pixel size, avoiding a
        // toolchain dependency on iconutil while keeping the iconset inspectable.
        struct { CGFloat px; const char *name; const char *icnsType; } sizes[] = {
            {  16, "icon_16x16.png",      "icp4" },
            {  32, "icon_16x16@2x.png",   NULL   },
            {  32, "icon_32x32.png",      "icp5" },
            {  64, "icon_32x32@2x.png",   "icp6" },
            { 128, "icon_128x128.png",    "ic07" },
            { 256, "icon_128x128@2x.png", NULL   },
            { 256, "icon_256x256.png",    "ic08" },
            { 512, "icon_256x256@2x.png", NULL   },
            { 512, "icon_512x512.png",    "ic09" },
            {1024, "icon_512x512@2x.png", "ic10" },
        };

        NSMutableArray<NSDictionary *> *chunks = [NSMutableArray array];
        for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
            NSString *path = [dir stringByAppendingPathComponent:@(sizes[i].name)];
            NSData *png = renderAtSize(sizes[i].px, path);
            if (sizes[i].icnsType) {
                [chunks addObject:@{ @"type": @(sizes[i].icnsType), @"png": png }];
            }
        }

        writeICNS(chunks, icnsPath);
    }
    return 0;
}
