// One-shot asset generator for the macOS port. Renders:
//   Resources/StatusActive.png    22x22 px  1x menu bar glyph
//   Resources/StatusActive@2x.png 44x44 px  2x menu bar glyph
//   Resources/StatusPaused.png    22x22 px  1x
//   Resources/StatusPaused@2x.png 44x44 px  2x
//
// Both scales are required: NSStatusBar.thickness on this machine is 22 pt, and a single 44x44
// asset is interpreted as 44 *points* -- twice the height of the menu bar, which collapses the
// status item button to zero height and makes it invisible.
//   Resources/AppIcon.icns       app icon set                              -> Finder
//
// Template images carry meaning in their alpha channel only; macOS paints them in
// the menu bar foreground colour, so they must be black on transparent.
//
//   clang -O2 -fobjc-arc -o mkicon mkicon.m -framework AppKit -framework ImageIO
//   ./mkicon <output-dir>

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreGraphics/CGBitmapContext.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static CGContextRef MakeContext(size_t px) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs,
                                           kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    // No CTM scaling: everything below draws in pixel coordinates. Scaling the CTM by px would
    // make user space 0..1 across the canvas, and a glyph sized in pixels would land far outside
    // it -- which renders a completely transparent, invisible menu bar icon.
    CGContextSetShouldAntialias(c, true);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextSetLineCap(c, kCGLineCapRound);
    return c;
}

// Counts pixels with meaningful alpha. A template glyph that renders to nothing is invisible in the
// menu bar while every API still reports success, so the generator refuses to pass silently.
static long OpaquePixelCount(CGContextRef c, size_t px) {
    CGImageRef img = CGBitmapContextCreateImage(c);
    if (!img)
        return -1;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img));
    size_t bytesPerRow = CGImageGetBytesPerRow(img);
    CFIndex length = CFDataGetLength(data);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    long opaque = 0;
    for (size_t y = 0; y < px; y++) {
        const UInt8 *row = bytes + y * bytesPerRow;
        for (size_t x = 0; x < px; x++) {
            // kCGImageAlphaPremultipliedLast, so alpha is the last byte of each pixel
            if (row[x * 4 + 3] > 16)
                opaque++;
        }
    }
    CFRelease(data);
    CGImageRelease(img);
    return opaque;
}

static BOOL WritePNG(CGContextRef c, NSString *path) {
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    if (!img)
        return NO;

    CFStringRef cfPath = (__bridge CFStringRef)path;
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!dst) {
        CGImageRelease(img);
        return NO;
    }
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    (void)cfPath;
    return ok;
}

// The eye: two arcs meeting at sharp corners, the classic lens shape.
static void DrawEyePath(CGContextRef c, CGPoint center, CGFloat halfWidth, CGFloat halfHeight) {
    CGContextBeginPath(c);
    CGContextMoveToPoint(c, center.x - halfWidth, center.y);
    CGContextAddQuadCurveToPoint(c, center.x, center.y - halfHeight * 2.1, center.x + halfWidth, center.y);
    CGContextAddQuadCurveToPoint(c, center.x, center.y + halfHeight * 2.1, center.x - halfWidth, center.y);
    CGContextClosePath(c);
}

static BOOL RenderTemplate(NSString *path, size_t px, BOOL paused) {
    CGContextRef c = MakeContext(px);
    // Proportions are expressed against a 44-unit reference so 1x and 2x are the same drawing.
    const CGFloat k = px / 44.0;
    CGPoint center = CGPointMake(px / 2.0, px / 2.0);

    CGContextSetStrokeColorWithColor(c, CGColorCreateGenericRGB(0, 0, 0, 1));
    CGContextSetLineWidth(c, k * 2.4);
    DrawEyePath(c, center, px * 0.40, px * 0.135);
    CGContextStrokePath(c);

    CGContextSetFillColorWithColor(c, CGColorCreateGenericRGB(0, 0, 0, 1));
    if (!paused) {
        CGContextFillEllipseInRect(c, CGRectMake(center.x - px * 0.115, center.y - px * 0.115, px * 0.23, px * 0.23));
    } else {
        CGFloat bw = k * 2.4, bh = k * 9.7, gap = k * 3.7;
        CGContextFillRect(c, CGRectMake(center.x - gap - bw / 2.0, center.y - bh / 2.0, bw, bh));
        CGContextFillRect(c, CGRectMake(center.x + gap - bw / 2.0, center.y - bh / 2.0, bw, bh));
    }

    long opaque = OpaquePixelCount(c, px);
    if (opaque <= 0) {
        fprintf(stderr, "refusing to write %s: rendered %ld opaque pixels, glyph is invisible\n",
                path.UTF8String, opaque);
        return NO;
    }
    printf("  %s: %zux%zu, %ld/%zu opaque px\n", path.lastPathComponent.UTF8String, px, px, opaque, px * px);
    return WritePNG(c, path);
}

static void RenderAppIcon(NSString *path, size_t px) {
    CGContextRef c = MakeContext(px);
    CGRect r = CGRectMake(px * 0.055, px * 0.055, px * 0.89, px * 0.89);
    CGFloat radius = px * 0.2237; // keeps the squircle ratio Apple uses

    CGContextSaveGState(c);
    CGContextAddPath(c, CGPathCreateWithRoundedRect(r, radius, radius, NULL));
    CGContextClip(c);

    NSArray *colors = @[
        (id)[[NSColor colorWithSRGBRed:0.16 green:0.38 blue:0.70 alpha:1] CGColor],
        (id)[[NSColor colorWithSRGBRed:0.46 green:0.74 blue:0.97 alpha:1] CGColor],
    ];
    CGContextDrawLinearGradient(c,
                                CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)colors, NULL),
                                CGPointMake(0, px), CGPointMake(px, 0), 0);

    CGPoint center = CGPointMake(px / 2.0, px / 2.0);
    CGFloat hw = px * 0.295, hh = px * 0.098;
    CGContextSetStrokeColorWithColor(c, CGColorCreateGenericRGB(1, 1, 1, 1));
    CGContextSetLineWidth(c, px * 0.046);
    DrawEyePath(c, center, hw, hh);
    CGContextStrokePath(c);
    CGContextSetFillColorWithColor(c, CGColorCreateGenericRGB(1, 1, 1, 1));
    CGContextFillEllipseInRect(c, CGRectMake(center.x - px * 0.082, center.y - px * 0.082, px * 0.164, px * 0.164));
    CGContextRestoreGState(c);

    WritePNG(c, path);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = argc > 1 ? @(argv[1]) : @".";
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:NULL];

        int bad = 0;
        struct { const char *name; BOOL paused; } glyphs[] = {
            { "StatusActive", NO }, { "StatusPaused", YES },
        };
        for (unsigned g = 0; g < sizeof(glyphs) / sizeof(glyphs[0]); g++) {
            NSString *name = @(glyphs[g].name);
            NSString *base = [name stringByAppendingPathExtension:@"png"];
            NSString *retina = [[name stringByAppendingString:@"@2x"] stringByAppendingPathExtension:@"png"];
            if (!RenderTemplate([out stringByAppendingPathComponent:base], 22, glyphs[g].paused) ||
                !RenderTemplate([out stringByAppendingPathComponent:retina], 44, glyphs[g].paused)) {
                fprintf(stderr, "failed: %s\n", glyphs[g].name);
                bad = 1;
            }
        }

        NSString *iconset = [NSTemporaryDirectory() stringByAppendingPathComponent:@"EyeLeo.iconset"];
        [fm removeItemAtPath:iconset error:NULL];
        [fm createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSNumber *s in @[ @16, @32, @128, @256, @512 ]) {
            NSString *fmt = @"icon_%dx%d%@.png";
            RenderAppIcon([iconset stringByAppendingPathComponent:
                              [NSString stringWithFormat:fmt, (int)s.integerValue, (int)s.integerValue, @""]],
                          s.unsignedIntegerValue);
            RenderAppIcon([iconset stringByAppendingPathComponent:
                              [NSString stringWithFormat:fmt, (int)s.integerValue, (int)s.integerValue, @"@2x"]],
                          s.unsignedIntegerValue * 2);
        }

        NSString *icns = [out stringByAppendingPathComponent:@"AppIcon.icns"];
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/usr/bin/iconutil";
        t.arguments = @[ @"-c", @"icns", iconset, @"-o", icns ];
        [t launch];
        [t waitUntilExit];
        if (t.terminationStatus != 0) {
            fprintf(stderr, "failed: iconutil exited %d\n", t.terminationStatus);
            bad = 1;
        }
        [fm removeItemAtPath:iconset error:NULL];

        if (!bad)
            printf("assets written to %s\n", out.UTF8String);
        return bad;
    }
}