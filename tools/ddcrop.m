#import <Cocoa/Cocoa.h>
int main(int c, char **v) { @autoreleasepool {
  if (c < 7) { fprintf(stderr, "usage: ddcrop in.png x y w h out.png\n"); return 2; }
  NSImage *src = [[NSImage alloc] initWithContentsOfFile:@(v[1])];
  CGImageRef cg = [src CGImageForProposedRect:NULL context:nil hints:nil];
  CGImageRef cr = CGImageCreateWithImageInRect(cg,
      CGRectMake(atoi(v[2]), atoi(v[3]), atoi(v[4]), atoi(v[5])));
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cr];
  [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(v[6]) atomically:YES];
  return 0;
}}
