// One-shot asset tool: turns the generated leopard bust into the app's own PNG.
//
// The bust arrives as a JPEG on a flat magenta field. JPEG cannot hold an alpha channel, so the
// magenta has to be keyed out, and it has to be done here rather than by hand: the fuzzy boundary
// pixels are a blend of fur and magenta, and a naive threshold either leaves a pink halo or eats
// into the light fur.
//
// Output is Resources/Personages/leopard_shoulders.png, 156x98 to match the other personage frames,
// with the existing 156x98 leopard head composited on top so the face is guaranteed to be the same
// character as everywhere else in the app.
//
//   clang -O2 -fobjc-arc -o mkpersonage mkpersonage.m -framework AppKit -framework CoreGraphics
//   ./mkpersonage <bust.jpg> <Resources/Personages>

#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <stdarg.h>

static const int kOutW = 156;
static const int kOutH = 98;

// Magenta tolerance in one RGB unit. The generator was told "flat solid #FF00FF with no gradient",
// and the delivered background holds inside this band; the band cannot be much tighter because the
// JPEG chroma subsampling smears the colour two pixels past the silhouette.
static const int kKeyR = 255, kKeyG = 0, kKeyB = 255;
static const int kKeyTol = 30;

// Where the bust sits once the head is on top, as a fraction of the 156x98 canvas. The bust's own
// aspect is much wider than 156x98, so it is scaled to fit the width and the head is then centred
// over it. These numbers were chosen against the delivered image: its figure runs from 7% to 100%
// of the frame height, so it has to be pushed down to make room for the head.
static const double kBustCenterY = 0.30;
static const double kBustWidth = 1.02;  // slightly wider than the canvas, so the arms reach the edges

static CGImageRef LoadImage(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        fprintf(stderr, "cannot read %s\n", path.UTF8String);
        return NULL;
    }
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) {
        fprintf(stderr, "cannot decode %s\n", path.UTF8String);
        return NULL;
    }
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;
}

static CGColorSpaceRef ColorSpace(void) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return cs;
}

// Renders into a fresh ARGB bitmap premultiplied-last, the layout AppKit expects for NSBitmapImageRep.
static CGContextRef NewCanvas(int w, int h) {
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, ColorSpace(),
                                           kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    if (c)
        CGContextClearRect(c, CGRectMake(0, 0, w, h));
    return c;
}

static bool WritePNG(CGContextRef c, NSString *path) {
    CGImageRef img = CGBitmapContextCreateImage(c);
    if (!img)
        return false;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (CFStringRef)@"public.png", 1, NULL);
    if (!dest) {
        CGImageRelease(img);
        return false;
    }
    CGImageDestinationAddImage(dest, img, NULL);
    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(img);
    return ok;
}

// A template glyph that renders to nothing, or an asset that never got keyed, is invisible in the
// panel while every API still reports success. Count what actually ended up opaque and refuse to
// pass silently.
static long OpaquePixels(CGContextRef c, int w, int h) {
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(c);
    size_t stride = CGBitmapContextGetBytesPerRow(c);
    long n = 0;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            unsigned char a = px[y * stride + x * 4 + 3];
            if (a > 40)
                n++;
        }
    return n;
}

static void Note(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fflush(stderr);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: mkpersonage <bust.jpg> <personage-dir>\n");
            return 2;
        }
        NSString *bustPath = [NSString stringWithUTF8String:argv[1]];
        NSString *dir = [NSString stringWithUTF8String:argv[2]];

        CGImageRef bust = LoadImage(bustPath);
        if (!bust)
            return 1;
        size_t bw = CGImageGetWidth(bust), bh = CGImageGetHeight(bust);
        Note("bust source: %zux%zu", bw, bh);

        // --- key the magenta out -------------------------------------------------------
        // Done in an intermediate canvas at source resolution so the boundary keeps subpixel
        // accuracy; downscaling a keyed image afterwards would alias the new edge.
        CGContextRef keying = NewCanvas((int)bw, (int)bh);
        if (!keying) {
            CGImageRelease(bust);
            return 1;
        }
        CGContextDrawImage(keying, CGRectMake(0, 0, bw, bh), bust);
        CGImageRelease(bust);

        unsigned char *px = (unsigned char *)CGBitmapContextGetData(keying);
        size_t stride = CGBitmapContextGetBytesPerRow(keying);
        long kept = 0;
        for (size_t i = 0; i < bw * bh; i++) {
            unsigned char *p = px + i * 4;
            int r = p[0], g = p[1], b = p[2];
            // The canvas is premultiplied last, so alpha and colour are not independent: clearing
            // alpha alone leaves rgb=255,0,255 with a=0, and unpremultiplying that divides by zero
            // and hands the magenta straight back. All four channels have to move together.
            if (abs(r - kKeyR) <= kKeyTol && g <= kKeyTol && abs(b - kKeyB) <= kKeyTol) {
                p[0] = p[1] = p[2] = p[3] = 0;
                continue;
            }
            // Feather the band just outside the hard threshold: a pixel that is mostly magenta but
            // not enough to be keyed outright still shows as a halo, so drop its alpha in
            // proportion to how much magenta it carries. Scaling rgb along with a is what makes this
            // correct in a premultiplied buffer.
            int dr = abs(r - kKeyR), dg = abs(g - kKeyG), db = abs(b - kKeyB);
            int over = dr + dg + db - 3 * kKeyTol;
            if (over > 0 && over < 150) {
                int f = (150 - over) * 255 / 150;
                for (int c = 0; c < 4; c++)
                    p[c] = (unsigned char)(p[c] * f / 255);
            }
            kept++;
        }
        Note("kept %ld of %zu pixels (%.1f%%)", kept, bw * bh, kept * 100.0 / (bw * bh));
        CGImageRef keyed = CGBitmapContextCreateImage(keying);
        CGContextRelease(keying);
        if (!keyed)
            return 1;

        // --- compose: bust underneath, the app's own head on top ------------------------
        CGContextRef out = NewCanvas(kOutW, kOutH);
        if (!out) {
            CGImageRelease(keyed);
            return 1;
        }

        double scale = (double)kOutW * kBustWidth / (double)bw;
        double dstW = bw * scale, dstH = bh * scale;
        double dx = (kOutW - dstW) / 2.0;
        double dy = kOutH * (1.0 - kBustCenterY) - dstH;
        CGContextDrawImage(out, CGRectMake(dx, dy, dstW, dstH), keyed);
        CGImageRelease(keyed);

        NSString *headPath = [dir stringByAppendingPathComponent:@"leopard_default.png"];
        NSImage *head = [[NSImage alloc] initWithContentsOfFile:headPath];
        if (!head) {
            fprintf(stderr, "cannot read %s\n", headPath.UTF8String);
            CGContextRelease(out);
            return 1;
        }
        // Borrowed, not owned: this is an NSImage method and the CGImage belongs to the NSImage.
        // Releasing it here over-releases and the process traps on the way out.
        CGImageRef headCG = [head CGImageForProposedRect:NULL context:nil hints:nil];
        if (headCG) {
            // The head is 156x98, exactly the canvas, and it was drawn for a head-only panel. Inside
            // a bust it has to shrink, or the neck never closes and the ears overflow. 0.62 leaves
            // room for the shoulders underneath.
            double hs = 0.62;
            double hw = CGImageGetWidth(headCG) * hs, hh = CGImageGetHeight(headCG) * hs;
            CGContextDrawImage(out, CGRectMake((kOutW - hw) / 2.0, kOutH - hh, hw, hh), headCG);
        }

        long opaque = OpaquePixels(out, kOutW, kOutH);
        Note("output: %dx%d, opaque pixels: %ld (%.0f%%)", kOutW, kOutH, opaque, opaque * 100.0 / (kOutW * kOutH));

        NSString *outPath = [dir stringByAppendingPathComponent:@"leopard_shoulders.png"];
        bool ok = WritePNG(out, outPath);
        Note("WritePNG returned %d", ok ? 1 : 0);
        CGContextRelease(out);
        Note("context released");
        if (!ok) {
            fprintf(stderr, "cannot write %s\n", outPath.UTF8String);
            return 1;
        }
        Note("wrote %s", outPath.UTF8String);

        Note("reaching final check");
        if (opaque < kOutW * kOutH / 8) {
            fprintf(stderr, "FAIL: too few opaque pixels, the bust did not composite\n");
            return 1;
        }
        return 0;
    }
}