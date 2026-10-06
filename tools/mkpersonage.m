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

// The bust is drawn as two separate images so the shoulders and the head can move independently.
// Baking them into one PNG and transforming the result is what made the first attempt read as a
// sliding picture rather than a stretch: a translation moves the head too, and the eye sees a whole
// image shift. With the head as its own layer it rotates about the neck while the torso lifts, and
// the two disagreeing is exactly what makes it read as a body.
static const int kTorsoW = 156;
static const int kTorsoH = 46;
// Overlap between the head and the torso, in points. Must match EBNeckOverlapPt in ebwindows.m.
// Five still left a one-pixel band of background between chin and shoulders once both layers were
// cropped, so it is seven: enough that the head's neck stub sits inside the torso's neck column.
static const double kTorsoHeadGap = 16;
// The head's own size, fixed. Deriving it from kTorsoHeadGap made the head grow every time the overlap
// was deepened: a bigger overlap silently meant a bigger face.
static const int kHeadHeight = 50;

// Magenta tolerance in one RGB unit. The generator was told "flat solid #FF00FF with no gradient",
// and the delivered background holds inside this band; the band cannot be much tighter because the
// JPEG chroma subsampling smears the colour two pixels past the silhouette.
static const int kKeyR = 255, kKeyG = 0, kKeyB = 255;
static const int kKeyTol = 30;
// Where the falloff completes. Chosen against the delivered image: a 50% magenta/fur blend lands
// about 96 away in Chebyshev distance, so the ramp has to reach past that for the halo to disappear.
static const int kKeyFeather = 150;

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

// Renders into a fresh ARGB bitmap premultiplied-last, the layout AppKit expects for NSBitmapImageRep.
// The colour space is created and released per canvas instead of being cached in a static, which would
// leak one space for the life of the process; there are only a handful of canvases here.
static CGContextRef NewCanvas(int w, int h) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                           kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
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
            // Gradual falloff instead of a single cutoff. A blend pixel that is 50% magenta still
            // sits well outside the hard threshold, and dropping its alpha in proportion to how much
            // magenta it carries is what keeps the pink halo off the silhouette. Scaling the colour
            // channels along with alpha is what makes that correct in a premultiplied buffer.
            int dr = abs(r - kKeyR), dg = abs(g - kKeyG), db = abs(b - kKeyB);
            int d = dr > dg ? dr : dg;
            if (db > d) d = db;
            if (d > kKeyTol) {
                int span = kKeyFeather - kKeyTol;
                int f = (d - kKeyTol) * 255 / (span > 0 ? span : 1);
                if (f < 255)
                    for (int c = 0; c < 4; c++)
                        p[c] = (unsigned char)(p[c] * f / 255);
            }
            kept++;
        }
        Note("kept %ld of %zu pixels (%.1f%%)", kept, bw * bh, kept * 100.0 / (bw * bh));

        // Bounds of the opaque content, scanned while the context is still alive. Reading it after
        // CGContextRelease is a use-after-free, which crashes without a message.
        CGRect content = CGRectNull;
        {
            unsigned char *kp = (unsigned char *)CGBitmapContextGetData(keying);
            size_t stride = CGBitmapContextGetBytesPerRow(keying);
            size_t minx = bw, miny = bh, maxx = 0, maxy = 0;
            for (size_t y = 0; y < bh; y++)
                for (size_t x = 0; x < bw; x++) {
                    if (kp[(y * stride + x * 4) + 3] <= 8)
                        continue;
                    if (x < minx) minx = x;
                    if (x > maxx) maxx = x;
                    if (y < miny) miny = y;
                    if (y > maxy) maxy = y;
                }
            if (maxx < minx || maxy < miny) {
                fprintf(stderr, "FAIL: nothing survived the key\n");
                CGContextRelease(keying);
                return 1;
            }
            content = CGRectMake(minx, miny, maxx - minx + 1, maxy - miny + 1);
            Note("torso content: %.0f,%.0f %.0fx%.0f", content.origin.x, content.origin.y,
                 content.size.width, content.size.height);
        }

        CGImageRef keyed = CGBitmapContextCreateImage(keying);
        CGContextRelease(keying);
        if (!keyed)
            return 1;

        // --- torso only, cropped to its own content and scaled into the art slot -------------
        // The source is a wide frame (the generated bust is about 1.59:1) of which the shoulders
        // occupy the lower half. Cropping to the opaque content first, then scaling, keeps the
        // shoulders from being squashed by the empty space above them.
        CGContextRef torso = NewCanvas(kTorsoW, kTorsoH);
        if (!torso) {
            CGImageRelease(keyed);
            return 1;
        }
        // Take a horizontal slice off the TOP of the torso content, not the whole of it. The content is
        // about 1.6:1 while the slot is 3.4:1, so fitting the whole thing by width produced an image
        // twice as tall as the slot and what survived the crop was the narrow neck, not the shoulders.
        // Starting from the top is also what puts the shoulder line where the head will meet it.
        double sliceH = content.size.width * ((double)kTorsoH / (double)kTorsoW);
        if (sliceH > content.size.height)
            sliceH = content.size.height;
        CGRect slice = CGRectMake(content.origin.x, content.origin.y, content.size.width, sliceH);
        Note("torso slice: %.0f,%.0f %.0fx%.0f", slice.origin.x, slice.origin.y, slice.size.width,
             slice.size.height);

        double tscale = (double)kTorsoW / slice.size.width;
        CGContextSaveGState(torso);
        CGContextScaleCTM(torso, tscale, tscale);
        CGContextTranslateCTM(torso, -slice.origin.x, -slice.origin.y);
        CGContextDrawImage(torso, slice, keyed);
        CGContextRestoreGState(torso);
        CGImageRelease(keyed);

        // Cropped to the opaque content, same reason as the head: 3 px of empty space at the top of the
        // slice turned a 5 pt overlap into 1 px and left a visible gap between chin and shoulders. With
        // both layers cropped, the overlap the panel applies is the overlap of actual pixels.
        CGRect torsoBox = CGRectNull;
        {
            unsigned char *tp = (unsigned char *)CGBitmapContextGetData(torso);
            size_t stride = CGBitmapContextGetBytesPerRow(torso);
            size_t minx = kTorsoW, miny = kTorsoH, maxx = 0, maxy = 0;
            for (int y = 0; y < kTorsoH; y++)
                for (int x = 0; x < kTorsoW; x++) {
                    if (tp[(y * stride + x * 4) + 3] <= 8)
                        continue;
                    if (x < minx) minx = x;
                    if (x > maxx) maxx = x;
                    if (y < miny) miny = y;
                    if (y > maxy) maxy = y;
                }
            if (maxx < minx || maxy < miny) {
                fprintf(stderr, "FAIL: the torso is empty\n");
                CGContextRelease(torso);
                return 1;
            }
            torsoBox = CGRectMake(minx, miny, maxx - minx + 1, maxy - miny + 1);
        }
        int torsoW = (int)torsoBox.size.width, torsoH = (int)torsoBox.size.height;
        Note("torso content after crop: %dx%d", torsoW, torsoH);

        // Cropped out of the probe we just drew, rather than out of the keyed source: the scale is
        // already correct there, so re-applying it would round twice.
        CGImageRef probeCG = CGBitmapContextCreateImage(torso);
        CGContextRelease(torso);
        if (!probeCG)
            return 1;
        CGContextRef torsoOut = NewCanvas(torsoW, torsoH);
        if (!torsoOut) {
            CGImageRelease(probeCG);
            return 1;
        }
        CGContextDrawImage(torsoOut, torsoBox, probeCG);
        CGImageRelease(probeCG);
        torso = torsoOut;
        long torsoOpaque = OpaquePixels(torso, torsoW, torsoH);
        Note("torso: %dx%d, opaque %ld (%.0f%%)", torsoW, torsoH, torsoOpaque,
             torsoOpaque * 100.0 / (torsoW * torsoH));
        NSString *torsoPath = [dir stringByAppendingPathComponent:@"leopard_shoulders_torso.png"];
        bool torsoOk = WritePNG(torso, torsoPath);
        CGContextRelease(torso);
        if (!torsoOk) {
            fprintf(stderr, "cannot write %s\n", torsoPath.UTF8String);
            return 1;
        }
        Note("wrote %s", torsoPath.UTF8String);

        // --- head only, unchanged from the app's own artwork ----------------------------------
        // Written out as its own file too, so the two layers are both plain PNGs on disk and the
        // panel code does not have to know anything about how they were produced.
        NSString *headPath = [dir stringByAppendingPathComponent:@"leopard_default.png"];
        NSImage *head = [[NSImage alloc] initWithContentsOfFile:headPath];
        if (!head) {
            fprintf(stderr, "cannot read %s\n", headPath.UTF8String);
            return 1;
        }
        // Borrowed, not owned: this is an NSImage method and the CGImage belongs to the NSImage.
        // Releasing it here over-releases and the process traps on the way out.
        CGImageRef headCG = [head CGImageForProposedRect:NULL context:nil hints:nil];
        if (!headCG) {
            fprintf(stderr, "cannot decode the head\n");
            return 1;
        }
        int hh = kHeadHeight;
        CGContextRef headOutProbe = NewCanvas((int)(CGImageGetWidth(headCG) * ((double)hh / CGImageGetHeight(headCG))), hh);
        if (!headOutProbe)
            return 1;
        CGContextDrawImage(headOutProbe,
                           CGRectMake(0, 0, CGImageGetWidth(headCG) * ((double)hh / CGImageGetHeight(headCG)), hh),
                           headCG);
        double hs = (double)hh / CGImageGetHeight(headCG);
        double hw = CGImageGetWidth(headCG) * hs;
        // Crop to the head's own opaque bounds. The source is 156x98 with transparent margins, and the
        // bottom one matters: the panel overlaps the head over the torso by a fixed number of points,
        // so 4 px of empty space at the bottom of this file quietly turned a 5 pt overlap into 1 pt
        // and left a visible seam under the chin.
        CGRect headBox = CGRectNull;
        {
            unsigned char *hp = (unsigned char *)CGBitmapContextGetData(headOutProbe);
            size_t stride = CGBitmapContextGetBytesPerRow(headOutProbe);
            int iw = (int)hw, ih = hh;
            size_t minx = iw, miny = ih, maxx = 0, maxy = 0;
            for (int y = 0; y < ih; y++)
                for (int x = 0; x < iw; x++) {
                    if (hp[(y * stride + x * 4) + 3] <= 8)
                        continue;
                    if (x < minx) minx = x;
                    if (x > maxx) maxx = x;
                    if (y < miny) miny = y;
                    if (y > maxy) maxy = y;
                }
            if (maxx < minx || maxy < miny) {
                fprintf(stderr, "FAIL: the head is empty\n");
                CGContextRelease(headOutProbe);
                return 1;
            }
            headBox = CGRectMake(minx, miny, maxx - minx + 1, maxy - miny + 1);
        }
        // Cropped out of the probe, at the scale the bbox was measured in. Drawing headBox from headCG
        // directly used probe coordinates against the unscaled 156x98 source, which sampled the wrong
        // region and left 7 rows of transparent margin at the bottom of the result.
        CGImageRef headProbeCG = CGBitmapContextCreateImage(headOutProbe);
        CGContextRelease(headOutProbe);
        if (!headProbeCG)
            return 1;
        int headW = (int)headBox.size.width, headH = (int)headBox.size.height;
        Note("head content after crop: %dx%d", headW, headH);

        CGContextRef headOut = NewCanvas(headW, headH);
        if (!headOut) {
            CGImageRelease(headProbeCG);
            return 1;
        }
        CGContextDrawImage(headOut, headBox, headProbeCG);
        CGImageRelease(headProbeCG);
        NSString *headOutPath = [dir stringByAppendingPathComponent:@"leopard_shoulders_head.png"];
        bool headOk = WritePNG(headOut, headOutPath);
        long headOpaque = OpaquePixels(headOut, headW, headH);
        CGContextRelease(headOut);
        if (!headOk) {
            fprintf(stderr, "cannot write %s\n", headOutPath.UTF8String);
            return 1;
        }
        Note("wrote %s, opaque %ld", headOutPath.UTF8String, headOpaque);

        // --- preview: the two layers assembled, as the panel lays them out -------------------
        // Written so the composition can be inspected without running the app or taking a screenshot,
        // which is not possible here: screencapture needs Screen Recording and this shell has none.
        // The numbers must match ebwindows.m, including the 5 pt overlap.
        {
            NSImage *headImg = [[NSImage alloc] initWithContentsOfFile:headOutPath];
            NSImage *torsoImg = [[NSImage alloc] initWithContentsOfFile:torsoPath];
            CGImageRef headCG = [headImg CGImageForProposedRect:NULL context:nil hints:nil];
            CGImageRef torsoCG = [torsoImg CGImageForProposedRect:NULL context:nil hints:nil];
            if (headCG && torsoCG) {
                double totalH = headH + torsoH - kTorsoHeadGap;
                double cx = headW / 2.0;

                for (int phase = 0; phase < 4; phase++) {
                    // Rendered four times up on the panel's own dark background. Judging a 156x88
                    // image by eye in this environment was repeatedly misleading; at this size the
                    // junction between chin and shoulders is actually decidable.
                    const double kPreviewScale = 4.0;
                    CGContextRef c = NewCanvas((int)(kTorsoW * kPreviewScale), (int)(totalH * kPreviewScale));
                    CGContextSetRGBFillColor(c, 0.12, 0.10, 0.10, 1.0);
                    CGContextFillRect(c, CGRectMake(0, 0, kTorsoW * kPreviewScale, totalH * kPreviewScale));

                    // Torso sits on the bottom edge and rides up or down.
                    double lift = (phase == 1 ? 2.5 : phase == 3 ? -1.0 : 0.0);
                    CGContextSaveGState(c);
                    CGContextScaleCTM(c, kPreviewScale, kPreviewScale);
                    CGContextDrawImage(c, CGRectMake((kTorsoW - torsoW) / 2.0, lift, torsoW, torsoH), torsoCG);
                    // Head above it, overlapping, rotating about its own bottom edge: that edge is where
                    // the neck is, so the face tilts instead of swinging away.
                    double tilt = (phase == 1 ? 0.7 : phase == 3 ? -0.7 : 0.0) * 0.12;
                    CGContextSaveGState(c);
                    // Canvas centre, not the head's own half width: translating by cx alone put the
                    // head 32 px left of the torso.
                    CGContextTranslateCTM(c, kTorsoW / 2.0, torsoH - kTorsoHeadGap);
                    CGContextRotateCTM(c, tilt);
                    CGContextDrawImage(c, CGRectMake(-cx, 0, headW, headH), headCG);
                    CGContextRestoreGState(c);
                    CGContextRestoreGState(c);

                    // Into build/, not into Resources/Personages/: the Makefile copies every PNG from
                    // there into the app bundle, and a pile of preview frames does not belong in a
                    // 1.7 MB build.
                    NSString *name = [NSString stringWithFormat:@"preview_phase%d.png", phase];
                    WritePNG(c, [@"build" stringByAppendingPathComponent:name]);
                    CGContextRelease(c);
                }
                Note("wrote build/preview_phase0..3.png at %.0f pt tall, 4x scale", totalH);
            }
        }

        Note("reaching final check");
        if (torsoOpaque < kTorsoW * kTorsoH / 8) {
            fprintf(stderr, "FAIL: too few opaque torso pixels\n");
            return 1;
        }
        return 0;
    }
}
