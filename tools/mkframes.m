// Builds the artwork the app actually loads, out of the raw generator output in ~/Projects/eyeleo-art.
//
// The frames of one set are not at the same scale. In stretch/ the leaning figures came out 8.6%
// larger than the neutral one, measured twice, once by leg length and once by leg thickness. Left
// alone that makes the leopard jump by a quarter of its height on every frame swap, so each set is
// aligned to a common anchor before it is scaled down to the size the panel asks for.
//
// Four modes, because each set needs a different anchor:
//   full  - leg thickness for the scale, foot line and foot centre for placement (stretch/)
//   bust  - the crown of the head, since raised paws sit above it and break every other anchor
//   eyes  - the same head crop, cut down to the size of the original 156x98 head
//   cups  - nothing to align; each vessel is a single image, so it is only sized and recoloured
//
// Build: clang -O2 -fobjc-arc -mmacosx-version-min=13.0 -o build/mkframes tools/mkframes.m -framework Cocoa
// Run:   ./build/mkframes <mode> <input dir> <output dir>

#import <Cocoa/Cocoa.h>

// The generator's background is not a clean #FF00FF: the three most common pixels cover barely a
// third of the frame and the rest is a slightly noisy magenta. A single exact-colour test leaves a
// speckled halo, so the key is a range test plus a flood fill from the border, which also keeps a
// magenta that happens to sit inside the drawing from being punched out.
static const uint8_t kKeyMinR = 200;
static const uint8_t kKeyMinB = 200;
static const uint8_t kKeyMaxG = 80;

// Pixels in a blob smaller than this are specks, not part of the drawing.
static const long kMinBlobPixels = 32;

// A bubble reserves this much room: 71x44 pt, so every stored bitmap is twice that.
static const double kPanelArtW = 71.0, kPanelArtH = 44.0;

// The scale every target below is multiplied by, and the short break art slot.
//
// Both are overridable from the environment so the same tool can emit 1x bitmaps for the Windows port
// of EyeLeo, which is a different program with two constraints this one does not have: wxBitmap uses a
// PNG's pixel size as-is, so there is no halving step to rely on, and its portrait has to fit a
// narrower slot (the Windows panel puts the exercise text at x=183, leaving 165x118 from the portrait's
// origin at x=18). The defaults are the macOS values, so existing invocations are unaffected.
static double gArtScale = 2.0;
static double gShortArtW = 178.0, gShortArtH = 110.0;

// The short break panel is 461x156, with the exercise art capped at this.
#define kShortArtW gShortArtW
#define kShortArtH gShortArtH

// The long break screen shows a figure up to this tall, less what the tip, clock and Skip button need.
static const double kLongArtMaxH = 340.0, kLongReservedBelow = 386.0;

// The original head bitmap, which the palming frames have to match.
static const double kOriginalHeadW = 156.0, kOriginalHeadH = 98.0;

static int gFailures = 0;

static void Fail(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Fail(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "  FAIL  %s\n", msg.UTF8String);
    gFailures++;
}

static inline int IsKeyColour(uint8_t r, uint8_t g, uint8_t b) {
    return r >= kKeyMinR && b >= kKeyMinB && g <= kKeyMaxG;
}

// A weaker test used while spreading through the background, so a noisy magenta with a few stray
// shades still clears instead of speckling the silhouette.
static inline int IsKeyLoose(uint8_t r, uint8_t g, uint8_t b) {
    return IsKeyColour(r, g, b) || (r >= 170 && g <= 110 && b >= 170);
}

#pragma mark - Buffers

typedef struct {
    long w, h;
    uint8_t *px; // RGBA8, row 0 at the top
} EBBitmap;

static EBBitmap AllocBitmap(long w, long h) {
    EBBitmap b = {w, h, calloc((size_t)(w * h * 4), 1)};
    return b;
}

static inline void PxGet(EBBitmap *b, long x, long y, uint8_t *out) {
    uint8_t *p = b->px + (y * b->w + x) * 4;
    out[0] = p[0]; out[1] = p[1]; out[2] = p[2]; out[3] = p[3];
}

static inline void PxSet(EBBitmap *b, long x, long y, uint8_t r, uint8_t g, uint8_t bl, uint8_t a) {
    uint8_t *p = b->px + (y * b->w + x) * 4;
    p[0] = r; p[1] = g; p[2] = bl; p[3] = a;
}

static inline int AlphaAt(const EBBitmap *b, long x, long y) { return b->px[(y * b->w + x) * 4 + 3]; }

static void FreeBitmap(EBBitmap *b) { free(b->px); b->px = NULL; }

// Decodes any PNG into RGBA8 with the rows the natural way up. Going through CGImage keeps this
// independent of the source colour space, and a per-pixel -colorAtX:y: on a 1536x1024 bitmap is slow
// enough to dominate the whole run.
static EBBitmap DecodePNG(NSString *path) {
    EBBitmap out = {0, 0, NULL};
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        Fail(@"не читается %@", path.lastPathComponent);
        return out;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:data];
    if (!rep) {
        Fail(@"не декодируется PNG %@", path.lastPathComponent);
        return out;
    }
    long w = (long)rep.pixelsWide, h = (long)rep.pixelsHigh;
    out = AllocBitmap(w, h);
    memset(out.px, 0, (size_t)(w * h * 4));
    NSInteger bpp = rep.bitsPerPixel / 8;
    uint8_t *src = rep.bitmapData;
    for (long y = 0; y < h; y++) {
        for (long x = 0; x < w; x++) {
            const uint8_t *p = src + y * rep.bytesPerRow + x * bpp;
            uint8_t r, g, b, a = 255;
            if (rep.hasAlpha) {
                r = p[0]; g = p[1]; b = p[2]; a = p[3];
            } else {
                r = p[0]; g = p[1]; b = p[2];
            }
            PxSet(&out, x, y, r, g, b, a);
        }
    }
    return out;
}

static void WritePNG(EBBitmap *b, NSString *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(b->px, b->w, b->h, 8, b->w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    // CGBitmapContext with premultiplied alpha expects the data already multiplied; the generator
    // gives straight alpha, and the resampler keeps it straight.
    for (long i = 0; i < b->w * b->h; i++) {
        uint8_t *p = b->px + i * 4;
        double a = p[3] / 255.0;
        p[0] = (uint8_t)lround(p[0] * a);
        p[1] = (uint8_t)lround(p[1] * a);
        p[2] = (uint8_t)lround(p[2] * a);
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    CGImageRelease(img);
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError *err = nil;
    if (![png writeToFile:path options:NSDataWritingAtomic error:&err])
        Fail(@"не пишется %@: %@", path.lastPathComponent, err.localizedDescription);
}

#pragma mark - Keying

// Turns the magenta background into transparency.
//
// The fill starts from the border rather than testing every pixel: a global test would also erase a
// magenta that happens to be inside the drawing. An edge pixel blends the subject with the key
// colour, so the key content is taken back out of it, which leaves the leopard's own colour at the
// edge instead of a pink rim.
static void KeyOut(EBBitmap *b) {
    long w = b->w, h = b->h;
    uint8_t *seen = calloc((size_t)(w * h), 1);
    int32_t *q = malloc((size_t)(w * h * 2) * sizeof(int32_t));
    long head = 0, tail = 0;

    for (long x = 0; x < w; x++) {
        for (long y = 0; y < h; y++) {
            if (y != 0 && y != h - 1 && x != 0 && x != w - 1)
                continue;
            uint8_t px[4];
            PxGet(b, x, y, px);
            if (seen[y * w + x] || !IsKeyColour(px[0], px[1], px[2]))
                continue;
            seen[y * w + x] = 1;
            q[tail * 2] = (int32_t)x;
            q[tail * 2 + 1] = (int32_t)y;
            tail++;
        }
    }
    while (head < tail) {
        int32_t cx = q[head * 2], cy = q[head * 2 + 1];
        head++;
        uint8_t px[4];
        PxGet(b, cx, cy, px);
        PxSet(b, cx, cy, 0, 0, 0, 0);
        static const int kStep[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
        for (int k = 0; k < 4; k++) {
            long nx = cx + kStep[k][0], ny = cy + kStep[k][1];
            if (nx < 0 || ny < 0 || nx >= w || ny >= h || seen[ny * w + nx])
                continue;
            uint8_t nb[4];
            PxGet(b, nx, ny, nb);
            if (!IsKeyLoose(nb[0], nb[1], nb[2]))
                continue;
            seen[ny * w + nx] = 1;
            q[tail * 2] = (int32_t)nx;
            q[tail * 2 + 1] = (int32_t)ny;
            tail++;
        }
    }
    free(q);
    free(seen);

    // A second pass over whatever the flood from the border could not reach. The gap between a raised
    // arm and the torso is a closed pocket of background, and the leopard's rosettes are brown, never
    // magenta, so any remaining magenta is background whatever pocket it sits in.
    for (long y = 0; y < h; y++) {
        for (long x = 0; x < w; x++) {
            uint8_t px[4];
            PxGet(b, x, y, px);
            if (px[3] && IsKeyLoose(px[0], px[1], px[2]))
                PxSet(b, x, y, 0, 0, 0, 0);
        }
    }

    static const int kAround[8][2] = {{-1, -1}, {0, -1}, {1, -1}, {-1, 0},
                                      {1, 0},  {-1, 1}, {0, 1}, {1, 1}};
    for (long y = 1; y < h - 1; y++) {
        for (long x = 1; x < w - 1; x++) {
            uint8_t px[4];
            PxGet(b, x, y, px);
            if (px[3] == 0 || !IsKeyLoose(px[0], px[1], px[2]))
                continue;
            int subject = 0;
            for (int k = 0; k < 8; k++) {
                uint8_t nb[4];
                PxGet(b, x + kAround[k][0], y + kAround[k][1], nb);
                if (nb[3] == 255 && !IsKeyColour(nb[0], nb[1], nb[2])) {
                    subject = 1;
                    break;
                }
            }
            if (!subject)
                continue;
            int keyLevel = (px[0] + px[2]) / 2 - px[1];
            if (keyLevel < 20)
                continue;
            double a = 1.0 - (double)keyLevel / 255.0;
            if (a < 0.0) a = 0.0;
            if (a > 1.0) a = 1.0;
            int r = (int)lround((px[0] - (1 - a) * 250.0) / (a > 0.05 ? a : 1.0));
            int g = (int)lround((px[1] - (1 - a) * 5.0) / (a > 0.05 ? a : 1.0));
            int bl = (int)lround((px[2] - (1 - a) * 250.0) / (a > 0.05 ? a : 1.0));
            if (r < 0) r = 0; if (r > 255) r = 255;
            if (g < 0) g = 0; if (g > 255) g = 255;
            if (bl < 0) bl = 0; if (bl > 255) bl = 255;
            PxSet(b, x, y, (uint8_t)r, (uint8_t)g, (uint8_t)bl,
                  (uint8_t)lround(a * 255.0 > 255.0 ? 255.0 : a * 255.0));
        }
    }
}

// Drops blobs a few pixels across: the generator leaves stray specks in the sky, and one of them far
// from the figure becomes a visible dot in the middle of the panel.
static void DropSpecks(EBBitmap *b) {
    long w = b->w, h = b->h;
    int32_t *lab = malloc((size_t)(w * h) * sizeof(int32_t));
    int32_t *q = malloc((size_t)(w * h * 2) * sizeof(int32_t));
    int32_t next = 0;
    static const int kStep[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};

    for (long y = 0; y < h; y++) {
        for (long x = 0; x < w; x++) {
            long i = y * w + x;
            if (lab[i])
                continue;
            if (AlphaAt(b, x, y) == 0) {
                lab[i] = -1;
                continue;
            }
            next++;
            long head = 0, tail = 0;
            lab[i] = next;
            q[tail * 2] = (int32_t)x;
            q[tail * 2 + 1] = (int32_t)y;
            tail++;
            while (head < tail) {
                int32_t cx = q[head * 2], cy = q[head * 2 + 1];
                head++;
                for (int k = 0; k < 4; k++) {
                    long nx = cx + kStep[k][0], ny = cy + kStep[k][1];
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h || lab[ny * w + nx])
                        continue;
                    if (AlphaAt(b, nx, ny) == 0)
                        continue;
                    lab[ny * w + nx] = next;
                    q[tail * 2] = (int32_t)nx;
                    q[tail * 2 + 1] = (int32_t)ny;
                    tail++;
                }
            }
        }
    }
    if (next > 0) {
        int32_t *cnt = calloc((size_t)(next + 1), sizeof(int32_t));
        for (long i = 0; i < w * h; i++)
            if (lab[i] > 0)
                cnt[lab[i]]++;
        for (long y = 0; y < h; y++)
            for (long x = 0; x < w; x++) {
                int32_t l = lab[y * w + x];
                if (l > 0 && cnt[l] < kMinBlobPixels)
                    PxSet(b, x, y, 0, 0, 0, 0);
            }
        free(cnt);
    }
    free(q);
    free(lab);
}

#pragma mark - Geometry

typedef struct {
    int valid;
    long x0, y0, x1, y1; // inclusive, y counted from the top
} EBRect;

// The floor matters. These generators leave a faint halo of almost transparent pixels around the
// subject, and counting any non-zero alpha as content stretched the bounding box of one cup from 907px to
// 1221px: the vessel was then fitted to a frame a third wider than itself and came out smeared.
static uint8_t gContentAlphaFloor = 8;

static EBRect ContentRect(EBBitmap *b) {
    EBRect r = {0, 0, 0, 0, 0};
    for (long y = 0; y < b->h; y++)
        for (long x = 0; x < b->w; x++)
            if (AlphaAt(b, x, y) >= gContentAlphaFloor) {
                if (!r.valid) {
                    r.valid = 1; r.x0 = r.x1 = x; r.y0 = r.y1 = y;
                } else {
                    if (x < r.x0) r.x0 = x;
                    if (x > r.x1) r.x1 = x;
                    if (y < r.y0) r.y0 = y;
                    if (y > r.y1) r.y1 = y;
                }
            }
    return r;
}

// Foot line: the lowest row wide enough to be a pair of feet. A tail tip or a paw hangs lower than the
// soles, so taking the last opaque row reports a sliver as the feet and throws the anchor sideways.
static long FootRowWide(const EBBitmap *b, const EBRect *box, long minWidth) {
    for (long y = box->y1; y >= box->y0; y--) {
        long lo = -1, hi = -1;
        for (long x = box->x0; x <= box->x1; x++)
            if (AlphaAt(b, x, y)) {
                if (lo < 0) lo = x;
                hi = x;
            }
        if (lo >= 0 && hi - lo + 1 >= minWidth)
            return y;
    }
    return box->y1;
}

// Half the figure's width: the axis the head and the feet are both centred on.
static double FigureAxis(const EBRect *box) { return (box->x0 + box->x1 + 1) / 2.0; }

// Ears rise above the crown, and shaving them off makes the crop look cut. Back the top off by this
// share of the head's width.
static const double kEarMargin = 0.10;

// How much of the figure the short-break crop keeps: the head, the chest and most of the arm.
static const double kBustKeep = 0.26;

// Crown of the head: the first row carrying a single wide run centred on the axis. The top of the
// bounding box is no use, because in a raised-arm frame the topmost thing is a paw; and merely the first
// single run is no use either, because fingers are narrow runs too.
static long CrownRow(const EBBitmap *b, const EBRect *box, double minRun, double axis) {
    for (long y = box->y0; y <= box->y1; y++) {
        long runs = 0, best = 0, lo = -1, bestLo = -1;
        for (long x = box->x0; x <= box->x1; x++) {
            if (AlphaAt(b, x, y)) {
                if (lo < 0) lo = x;
            } else if (lo >= 0) {
                long len = x - lo;
                if (len >= minRun) {
                    runs++;
                    if (len > best) { best = len; bestLo = lo; }
                }
                lo = -1;
            }
        }
        if (lo >= 0) {
            long len = box->x1 - lo + 1;
            if (len >= minRun) {
                runs++;
                if (len > best) { best = len; bestLo = lo; }
            }
        }
        if (runs == 1 && bestLo >= 0 && bestLo <= axis && axis <= bestLo + best)
            return y;
    }
    return box->y0;
}

// Width of the lower leg, measured on the calf band.
//
// This is the only scale reference that survives the poses in these frames. Total height does not: in
// the leaning frames it includes a raised arm, so fitting every frame to one height shrinks the body
// and not just the arm, which left the standing figure noticeably larger than the other two. The calf
// is close to a circle in section and the feet stay planted, so it measures the body alone.
static long CalfThickness(const EBBitmap *b, const EBRect *box) {
    long samples[512];
    int n = 0;
    long span = box->y1 - box->y0;
    for (long y = box->y1 - span * 15 / 100; y <= box->y1 && n < 512; y += 3) {
        long widths[512];
        int wn = 0, run = 0;
        for (long x = box->x0; x <= box->x1; x++) {
            if (AlphaAt(b, x, y))
                run++;
            else {
                if (run >= 10 && wn < 512)
                    widths[wn++] = run;
                run = 0;
            }
        }
        if (run >= 10 && wn < 512)
            widths[wn++] = run;
        // Median of the runs on this row, so one wide thigh next to a narrow calf cannot set the value.
        if (wn > 0)
            for (int i = 1; i < wn; i++) {
                long v = widths[i];
                int j = i - 1;
                while (j >= 0 && widths[j] > v) { widths[j + 1] = widths[j]; j--; }
                widths[j + 1] = v;
            }
        if (wn > 0)
            samples[n++] = widths[wn / 2];
    }
    if (!n)
        return 0;
    for (int i = 1; i < n; i++) {
        long v = samples[i];
        int j = i - 1;
        while (j >= 0 && samples[j] > v) { samples[j + 1] = samples[j]; j--; }
        samples[j + 1] = v;
    }
    return samples[n / 2];
}

#pragma mark - Resampling#pragma mark - Resampling

// Area average, because these are reductions by a factor of four or more: bilinear sampling of that
// much of a step loses roughly a third of the rosettes and leaves the leopard looking smeared.
static void ResampleInto(EBBitmap *dst, const EBBitmap *src) {
    for (long y = 0; y < dst->h; y++) {
        long sy0 = y * src->h / dst->h;
        long sy1 = (y + 1) * src->h / dst->h;
        if (sy1 <= sy0) sy1 = sy0 + 1;
        for (long x = 0; x < dst->w; x++) {
            long sx0 = x * src->w / dst->w;
            long sx1 = (x + 1) * src->w / dst->w;
            if (sx1 <= sx0) sx1 = sx0 + 1;
            double accR = 0, accG = 0, accB = 0, accA = 0;
            long n = 0;
            for (long sy = sy0; sy < sy1 && sy < src->h; sy++) {
                for (long sx = sx0; sx < sx1 && sx < src->w; sx++) {
                    const uint8_t *p = src->px + (sy * src->w + sx) * 4;
                    double a = p[3] / 255.0;
                    // Weight colour by alpha so a transparent magenta cannot tint the edge inward.
                    accR += p[0] * a;
                    accG += p[1] * a;
                    accB += p[2] * a;
                    accA += p[3];
                    n++;
                }
            }
            uint8_t *o = dst->px + (y * dst->w + x) * 4;
            if (!n || accA <= 0.5) { memset(o, 0, 4); continue; }
            double a = accA / n / 255.0;
            o[3] = (uint8_t)lround(MIN(255.0, a * 255.0));
            o[0] = (uint8_t)lround(MIN(255.0, accR / n / a));
            o[1] = (uint8_t)lround(MIN(255.0, accG / n / a));
            o[2] = (uint8_t)lround(MIN(255.0, accB / n / a));
        }
    }
}

// Draws a source bitmap into a destination at a given scale and offset, nearest neighbour. The
// reduction to the final size happens afterwards, in one area-averaged pass, so nothing is averaged
// twice.
static void BlitScaled(EBBitmap *dst, const EBBitmap *src, double scale, long offX, long offY) {
    for (long y = 0; y < src->h; y++) {
        long dy = lround(y * scale) + offY;
        if (dy < 0 || dy >= dst->h)
            continue;
        for (long x = 0; x < src->w; x++) {
            int a = AlphaAt(src, x, y);
            if (!a)
                continue;
            long dx = lround(x * scale) + offX;
            if (dx < 0 || dx >= dst->w)
                continue;
            const uint8_t *p = src->px + (y * src->w + x) * 4;
            uint8_t *o = dst->px + (dy * dst->w + dx) * 4;
            o[0] = p[0]; o[1] = p[1]; o[2] = p[2]; o[3] = p[3];
        }
    }
}

// Crops to a window of the source and scales it into a new bitmap of exactly dw x dh.
// Crops a window and scales it to exactly dw x dh in one area-averaged pass.
//
// One pass only. Scaling first with BlitScaled and then averaging in ResampleInto reduced the image twice
// over, which is harmless for a solid figure but turned the narrow glass into a smear: at a seventh of the
// width there is barely more than one source pixel per output column, so a second pass had nothing left
// to average and blended neighbours that were never adjacent.
static EBBitmap CropTo(EBBitmap *src, long x0, long y0, long cw, long ch, long dw, long dh) {
    if (cw < 1) cw = 1;
    if (ch < 1) ch = 1;
    if (dw < 1) dw = 1;
    if (dh < 1) dh = 1;
    EBBitmap out = AllocBitmap(dw, dh);
    for (long y = 0; y < dh; y++) {
        long sy0 = y0 + (long)((double)y * ch / dh);
        long sy1 = y0 + (long)((double)(y + 1) * ch / dh);
        if (sy1 <= sy0) sy1 = sy0 + 1;
        for (long x = 0; x < dw; x++) {
            long sx0 = x0 + (long)((double)x * cw / dw);
            long sx1 = x0 + (long)((double)(x + 1) * cw / dw);
            if (sx1 <= sx0) sx1 = sx0 + 1;
            double accR = 0, accG = 0, accB = 0, accA = 0;
            long n = 0;
            for (long sy = sy0; sy < sy1; sy++) {
                if (sy < 0 || sy >= src->h)
                    continue;
                for (long sx = sx0; sx < sx1; sx++) {
                    if (sx < 0 || sx >= src->w)
                        continue;
                    const uint8_t *p = src->px + (sy * src->w + sx) * 4;
                    double a = p[3] / 255.0;
                    // Weight colour by alpha, so a transparent pixel cannot tint its neighbour inward.
                    accR += p[0] * a;
                    accG += p[1] * a;
                    accB += p[2] * a;
                    accA += p[3];
                    n++;
                }
            }
            uint8_t *o = out.px + (y * dw + x) * 4;
            if (!n || accA <= 0.5) {
                memset(o, 0, 4);
                continue;
            }
            double a = accA / n / 255.0;
            o[3] = (uint8_t)lround(MIN(255.0, a * 255.0));
            o[0] = (uint8_t)lround(MIN(255.0, accR / n / a));
            o[1] = (uint8_t)lround(MIN(255.0, accG / n / a));
            o[2] = (uint8_t)lround(MIN(255.0, accB / n / a));
        }
    }
    return out;
}

#pragma mark - Frames

typedef struct {
    NSString *inName;
    NSString *outName;
    EBBitmap bmp;
    EBRect box;
    long calf;
} EBFrame;

static int LoadFrame(EBFrame *f, NSString *inDir, NSString *inName, NSString *outName) {
    // Assigned field by field rather than memset: the struct holds two Objective-C pointers, and
    // clearing it as raw memory trips the compiler's non-trivial-memaccess check.
    f->bmp.px = NULL;
    f->bmp.w = f->bmp.h = 0;
    f->box.valid = 0;
    f->box.x0 = f->box.y0 = f->box.x1 = f->box.y1 = 0;
    f->calf = 0;
    f->inName = inName;
    f->outName = outName;
    f->bmp = DecodePNG([inDir stringByAppendingPathComponent:inName]);
    if (!f->bmp.px)
        return 0;
    KeyOut(&f->bmp);
    DropSpecks(&f->bmp);
    f->box = ContentRect(&f->bmp);
    if (!f->box.valid) {
        Fail(@"в %@ не осталось непрозрачных пикселей", inName);
        return 0;
    }
    f->calf = CalfThickness(&f->bmp, &f->box);
    return 1;
}

static void Emit(EBBitmap *img, NSString *outDir, NSString *name) {
    WritePNG(img, [outDir stringByAppendingPathComponent:name]);
    printf("  %-32s %ldx%ld\n", name.UTF8String, img->w, img->h);
    FreeBitmap(img);
}

// stretch/: the full figure on the long break. Placement is by the foot line and the foot centre,
// which the measurements showed agree within 8px, and the scale comes from the leg.
static void RunFull(NSString *inDir, NSString *outDir) {
    EBFrame f[3];
    if (!LoadFrame(&f[0], inDir, @"stretch_neutral.png", @"leopard_stretch_neutral.png") ||
        !LoadFrame(&f[1], inDir, @"stretch_left.png", @"leopard_stretch_left.png") ||
        !LoadFrame(&f[2], inDir, @"stretch_right.png", @"leopard_stretch_right.png"))
        return;
    if (f[0].calf <= 0) {
        Fail(@"neutral: не измерилась голень");
        return;
    }

    // One scale for the set, taken from the calf alone.
    //
    // Fitting each frame to a common height does not work here, and this was the reason the standing
    // figure looked bigger than the other two: in the leaning frames the silhouette's height includes a
    // raised arm, so forcing all three to the same number of pixels shrank the body as well as the arm
    // and left the standing figure, which has no arm in the air, at full size. The calf is unaffected by
    // the arms, so scaling by it brings the bodies together and lets the arms be whatever height the
    // pose needs.
    double scale[3];
    for (int i = 0; i < 3; i++)
        scale[i] = (double)f[0].calf / (double)MAX(f[i].calf, 1L);
    for (int i = 1; i < 3; i++) {
        double d = scale[i] / scale[0];
        if (d < 0.90 || d > 1.11)
            Fail(@"%@: голень отличается от нормы в %.2f раза, ожидалось 0.90..1.11", f[i].inName, d);
    }

    // The canvas has to hold the tallest of the three, which is a leaning frame with its arm up. The
    // standing figure then leaves empty space above itself, and that is correct: it is standing still.
    long boxW = 0, boxH = 0;
    for (int i = 0; i < 3; i++) {
        long bw = lround((f[i].box.x1 - f[i].box.x0 + 1) * scale[i]);
        long bh = lround((f[i].box.y1 - f[i].box.y0 + 1) * scale[i]);
        if (bw > boxW) boxW = bw;
        if (bh > boxH) boxH = bh;
    }
    long pad = 8;
    long canvasW = boxW + pad * 2;
    long canvasH = boxH + pad * 2;

    // Cap the whole set so the figure stays within what the long break screen can give it: it starts 200pt
    // from the top and the tip, clock and Skip button need about 250pt below. The stored bitmaps are twice
    // this, so the ceiling here is in the doubled space.
    long capH = lround(MIN(kLongArtMaxH, MAX(120.0, 1200.0 - kLongReservedBelow)) * gArtScale);
    if (canvasH > capH) {
        double shrink = (double)capH / canvasH;
        for (int i = 0; i < 3; i++)
            scale[i] *= shrink;
        canvasW = lround(canvasW * shrink);
        canvasH = capH;
    }

    // Anchor: the row of feet, and the middle of the feet on that row.
    long anchorX = canvasW / 2;
    long anchorY = canvasH - pad;

    for (int i = 0; i < 3; i++) {
        EBFrame *fr = &f[i];
        long boxWOf = fr->box.x1 - fr->box.x0 + 1;
        long minFootW = MAX(boxWOf / 5, 12);
        long footRow = FootRowWide(&fr->bmp, &fr->box, minFootW);
        long flo = fr->box.x0, fhi = fr->box.x1;
        for (long x = fr->box.x0; x <= fr->box.x1; x++)
            if (AlphaAt(&fr->bmp, x, footRow)) { flo = x; break; }
        for (long x = fr->box.x1; x >= fr->box.x0; x--)
            if (AlphaAt(&fr->bmp, x, footRow)) { fhi = x; break; }
        long offX = anchorX - lround((flo + fhi + 1) / 2.0 * scale[i]);
        long offY = anchorY - lround((footRow + 1) * scale[i]);

        EBBitmap placed = AllocBitmap(canvasW, canvasH);
        BlitScaled(&placed, &fr->bmp, scale[i], offX, offY);

        // Correct against where the feet actually landed, not where the arithmetic intended: rounding
        // leaves a leaning frame a few pixels out, and a set whose feet disagree swaps with a visible
        // jump.
        EBRect drawn = ContentRect(&placed);
        if (!drawn.valid) {
            Fail(@"%@: после размещения не осталось пикселей", fr->outName);
            FreeBitmap(&placed);
            continue;
        }
        long rw = FootRowWide(&placed, &drawn, MAX((drawn.x1 - drawn.x0 + 1) / 5, 12));
        long dlo = drawn.x0, dhi = drawn.x1;
        for (long x = drawn.x0; x <= drawn.x1; x++)
            if (AlphaAt(&placed, x, rw)) { dlo = x; break; }
        for (long x = drawn.x1; x >= drawn.x0; x--)
            if (AlphaAt(&placed, x, rw)) { dhi = x; break; }
        long shiftX = anchorX - (dlo + dhi) / 2;
        long shiftY = anchorY - (rw + 1);
        if (shiftX || shiftY) {
            EBBitmap fixed = AllocBitmap(canvasW, canvasH);
            BlitScaled(&fixed, &placed, 1.0, shiftX, shiftY);
            FreeBitmap(&placed);
            placed = fixed;
        }
        Emit(&placed, outDir, fr->outName);
    }

    // The bodies have to end up the same size, which is what the calf scaling is for. Measure each one
    // and report a real number rather than trusting the arithmetic.
    long calfOut[3];
    for (int i = 0; i < 3; i++) {
        NSString *p = [outDir stringByAppendingPathComponent:f[i].outName];
        EBBitmap b = DecodePNG(p);
        if (!b.px)
            continue;
        EBRect box = ContentRect(&b);
        if (box.valid)
            calfOut[i] = CalfThickness(&b, &box);
        FreeBitmap(&b);
    }
    if (calfOut[0] > 0) {
        printf("  голень после сборки: %ld / %ld / %ld px\n", calfOut[0], calfOut[1], calfOut[2]);
        // The calf is a narrow feature: on a 2x bitmap it is around 40 px wide and 6% is nearly three
        // pixels of slack, but the same 6% of a 20 px calf at 1x is barely one pixel, and rounding in
        // the resampler then trips a check that has nothing to do with alignment. So the tolerance has
        // a floor of two pixels' worth. It is still far tighter than the figure visibly changing size,
        // which is what this check is for.
        double tol = MAX(0.06, 2.0 / (double)MAX(calfOut[0], 1L));
        for (int i = 1; i < 3; i++) {
            double d = (double)calfOut[i] / (double)MAX(calfOut[0], 1L);
            if (d < 1.0 - tol || d > 1.0 + tol)
                Fail(@"%@: голень в результате отличается в %.2f раза (допуск %.3f)", f[i].outName, d, tol);
        }
    }
    for (int i = 0; i < 3; i++)
        FreeBitmap(&f[i].bmp);
}

// stretch_up/: the short break's "stretch" exercise, cut below the chest so the raised paws stay in
// frame and the legs go. Alignment is by the crown: in these frames the head starts at y=79 while a
// raised paw reaches y=4, so cutting at a fixed row would leave the neutral frame 75px shorter than
// the other two and the leopard would jump.
static void RunBust(NSString *inDir, NSString *outDir) {
    EBFrame f[3];
    if (!LoadFrame(&f[0], inDir, @"stretch_neutral.png", @"leopard_stretch_up_neutral.png") ||
        !LoadFrame(&f[1], inDir, @"stretch_up.png", @"leopard_stretch_up.png") ||
        !LoadFrame(&f[2], inDir, @"stretch_upper.png", @"leopard_stretch_upper.png"))
        return;
    long targetW = lround(kShortArtW * gArtScale);
    long targetH = lround(kShortArtH * gArtScale);

    // The three frames already agree on scale: measured on the leg they are 51, 50 and 51 px across.
    // So nothing needs rescaling to match and the only thing to find is where each head starts, which
    // is a different row in each frame.
    long crown[3], headW[3], headCx[3], cropTop[3], cropH[3];
    for (int i = 0; i < 3; i++) {
        EBFrame *fr = &f[i];
        double axis = FigureAxis(&fr->box);
        long boxW = fr->box.x1 - fr->box.x0 + 1;
        long cy = CrownRow(&fr->bmp, &fr->box, boxW * 0.40, axis);
        // Width of the head, taken on the crown row itself, where the run is the head alone.
        long lo = fr->box.x0, hi = fr->box.x1;
        for (long x = fr->box.x0; x <= fr->box.x1; x++)
            if (AlphaAt(&fr->bmp, x, cy)) { lo = x; break; }
        for (long x = fr->box.x1; x >= fr->box.x0; x--)
            if (AlphaAt(&fr->bmp, x, cy)) { hi = x; break; }
        headW[i] = hi - lo + 1;
        headCx[i] = (lo + hi) / 2;
        // Back the crop off by the ear margin so the ears are not shaved off by the top edge.
        cropTop[i] = MAX(fr->box.y0, cy - lround(headW[i] * kEarMargin));
        // Keep the head, the chest and as much of the arm as will fit: measured from the crop top as a
        // share of the figure's own height, so it is one number for the set instead of three that each
        // depend on where the figure happened to end.
        cropH[i] = lround((fr->box.y1 - cropTop[i]) * kBustKeep);
    }

    // One scale for all three, from the reference head width. Three separate fits would make the head
    // breathe during the animation, which is the one thing this crop has to avoid.
    double scale = (double)targetH / (double)MAX(cropH[0], 1L);
    for (int i = 1; i < 3; i++) {
        double ratio = (double)headW[i] / (double)MAX(headW[0], 1L);
        // The head width is measured on each frame's own crown row, and in a raised-arm frame that
        // row still catches a paw, so the tolerance is wide on purpose: a large jump here means the
        // crown was found on the wrong row, a small one just means the paw is in shot.
        if (ratio < 0.80 || ratio > 1.40)
            Fail(@"%@: голова шире нормы в %.2f раза, ожидалось 0.80..1.40", f[i].inName, ratio);
    }

    long pad = 4;
    long canvasW = targetW + pad * 2;
    long canvasH = targetH + pad * 2;

    for (int i = 0; i < 3; i++) {
        EBFrame *fr = &f[i];
        long srcW = fr->box.x1 - fr->box.x0 + 1;
        EBBitmap out = CropTo(&fr->bmp, fr->box.x0, cropTop[i], srcW, cropH[i], canvasW, canvasH);
        EBRect drawn = ContentRect(&out);
        if (!drawn.valid) {
            Fail(@"%@: после кропа не осталось пикселей", fr->outName);
            FreeBitmap(&out);
            continue;
        }
        // Centre on the head. With a raised arm the figure is far wider than with the arms down, so
        // centring the bounding box would push the head to one side of the panel. Measured on the
        // cropped result rather than on the source, because the two live in different coordinate
        // spaces once the crop has been taken and mixing them slides the head off the panel.
        EBRect drawn2 = ContentRect(&out);
        if (drawn2.valid) {
            // The head is the wide run at the top of the crop; the shoulders below it are wider still,
            // so the search stops before they take over.
            long best = 0, bestCx = drawn2.x0 + (drawn2.x1 - drawn2.x0) / 2;
            long limit = MIN(drawn2.y1, drawn2.y0 + canvasH / 4);
            for (long y = drawn2.y0; y <= limit; y++) {
                long run = 0, lo = -1;
                for (long x = drawn2.x0; x <= drawn2.x1; x++) {
                    if (AlphaAt(&out, x, y)) {
                        if (run == 0) lo = x;
                        run++;
                    } else if (run) {
                        if (run > best) { best = run; bestCx = lo + run / 2; }
                        run = 0;
                    }
                }
                if (run > best) { best = run; bestCx = lo + run / 2; }
            }
            long shiftX = canvasW / 2 - bestCx;
            if (shiftX) {
                EBBitmap fixed = AllocBitmap(canvasW, canvasH);
                BlitScaled(&fixed, &out, 1.0, shiftX, 0);
                FreeBitmap(&out);
                out = fixed;
            }
        }
        Emit(&out, outDir, fr->outName);
    }
    for (int i = 0; i < 3; i++)
        FreeBitmap(&f[i].bmp);
}

// close_eyes/: the palming exercise. These two frames already agree on head size, 242px against
// 244px, so no rescaling is needed, only the crop down to the original head size.
static void RunEyes(NSString *inDir, NSString *outDir) {
    EBFrame f[2];
    if (!LoadFrame(&f[0], inDir, @"open.png", @"leopard_eyes_open.png") ||
        !LoadFrame(&f[1], inDir, @"close.png", @"leopard_eyes_closed.png"))
        return;
    long targetW = lround(kOriginalHeadW * gArtScale);
    long targetH = lround(kOriginalHeadH * gArtScale);
    for (int i = 0; i < 2; i++) {
        EBFrame *fr = &f[i];
        long span = fr->box.y1 - fr->box.y0;
        long cropH = lround(span * 0.30);
        long bw = fr->box.x1 - fr->box.x0 + 1;
        EBBitmap out = CropTo(&fr->bmp, fr->box.x0, fr->box.y0, bw, cropH, targetW, targetH);
        Emit(&out, outDir, fr->outName);
    }
    for (int i = 0; i < 2; i++)
        FreeBitmap(&f[i].bmp);
}

// neck_new/: the neck and shoulders exercise. Two drawn poses rather than a transform, so they get no
// scale normalisation at all: measurements on the two frames agree to within a pixel, and both take
// the same crop so the two pictures are interchangeable.
// How much of the source is kept, measured down from the top, and how far above the content the crop
// starts. A share of the height rather than a row number: the same command has to survive a picture that
// comes back at a different size.
static const double kShouldersKeep = 0.738;
static const long kShouldersTopMargin = 5;

// Two frames of an animation have to differ enough for the swap to be worth doing. Measured on this art
// set: ending the crop at the neck leaves the frames 7.3% apart, which on screen is a pair of identical
// pictures alternating every 350ms. The chosen crop gives 21.2%.
static const double kMinFrameDifference = 0.15;

// Share of pixels in a window that differ between two frames. A pixel counts as different when it is
// drawn in one frame and not the other, or when both draw it in clearly different colours.
static double FrameDifference(const EBBitmap *a, const EBBitmap *b, long x0, long y0, long w, long h) {
    if (a->w != b->w || a->h != b->h)
        return 1.0;
    long diff = 0, total = 0;
    for (long y = y0; y < y0 + h; y++) {
        if (y < 0 || y >= a->h)
            continue;
        for (long x = x0; x < x0 + w; x++) {
            if (x < 0 || x >= a->w)
                continue;
            const uint8_t *pa = a->px + (y * a->w + x) * 4;
            const uint8_t *pb = b->px + (y * b->w + x) * 4;
            int oa = pa[3] > 8, ob = pb[3] > 8;
            long d = ABS((long)pa[0] - pb[0]) + ABS((long)pa[1] - pb[1]) + ABS((long)pa[2] - pb[2]);
            if (oa != ob || (oa && ob && d > 60))
                diff++;
            total++;
        }
    }
    return total ? (double)diff / (double)total : 0.0;
}

// Draws one bitmap over another with source-over alpha, so a frame with a transparent background lands on
// a panel-coloured sheet instead of punching a hole through it.
static void CompositeOver(EBBitmap *dst, const EBBitmap *src, long atX, long atY) {
    for (long y = 0; y < src->h; y++) {
        long dy = atY + y;
        if (dy < 0 || dy >= dst->h)
            continue;
        for (long x = 0; x < src->w; x++) {
            long dx = atX + x;
            if (dx < 0 || dx >= dst->w)
                continue;
            const uint8_t *sp = src->px + (y * src->w + x) * 4;
            if (!sp[3])
                continue;
            uint8_t *dp = dst->px + (dy * dst->w + dx) * 4;
            double a = sp[3] / 255.0;
            for (int k = 0; k < 3; k++)
                dp[k] = (uint8_t)lround(sp[k] * a + dp[k] * (1.0 - a));
            dp[3] = 255;
        }
    }
}

// neck2/: the shoulders exercise. Two head-and-shoulders poses, head up, head down.
//
// The crop keeps the top of the drawing down to the upper chest. Going lower does not help: the generator's
// own framing cuts the arms off at the bottom of its frame, and a crop that reaches that line just repeats
// the cut. Going higher is worse, because the movement lives entirely in the shoulders -- measured on this
// pair, the head and neck differ by 2px between the two poses while everything below the shoulders differs
// by nearly 60%, so a crop above the neckline leaves two identical pictures.
//
// Unlike the other modes there is no crown search: the source is already a bust, so the content box is the
// frame. One window is shared by both poses, which differ in width, and fitted by aspect ratio into the
// panel's slot.
static void RunShoulders(NSString *inDir, NSString *outDir) {
    static const char *kIn[2] = {"shoulders_up.png", "shoulders_down.png"};
    static const char *kOut[2] = {"leopard_shoulders_up.png", "leopard_shoulders_down.png"};
    long slotW = lround(kShortArtW * gArtScale);
    long slotH = lround(kShortArtH * gArtScale);

    EBFrame f[2];
    int loaded = 0;
    for (int i = 0; i < 2; i++) {
        if (!LoadFrame(&f[i], inDir, @(kIn[i]), @(kOut[i])))
            continue;
        loaded++;
    }
    if (loaded != 2) {
        Fail(@"плечи: ожидалось 2 кадра, загружено %d", loaded);
        for (int i = 0; i < 2; i++)
            if (f[i].bmp.px)
                FreeBitmap(&f[i].bmp);
        return;
    }

    long top = f[0].box.y0 < f[1].box.y0 ? f[0].box.y0 : f[1].box.y0;
    long bottomMost = f[0].box.y1 > f[1].box.y1 ? f[0].box.y1 : f[1].box.y1;
    top -= kShouldersTopMargin;
    if (top < 0)
        top = 0;
    long contentH = bottomMost - top + 1;
    long cropH = lround(contentH * kShouldersKeep);
    long cropBottom = top + cropH;

    // Shared horizontal window: the raised pose is wider, and a window fitted to each would put the head at
    // two different scales and shift it sideways on every swap.
    long x0 = -1, x1 = -1;
    for (int i = 0; i < 2; i++) {
        for (long y = top; y <= cropBottom && y < f[i].bmp.h; y++) {
            long lo = -1, hi = -1;
            for (long x = 0; x < f[i].bmp.w; x++)
                if (AlphaAt(&f[i].bmp, x, y)) {
                    if (lo < 0)
                        lo = x;
                    hi = x;
                }
            if (lo < 0)
                continue;
            if (x0 < 0 || lo < x0)
                x0 = lo;
            if (hi > x1)
                x1 = hi;
        }
    }
    if (x0 < 0) {
        Fail(@"плечи: пустое окно кадрирования");
        for (int i = 0; i < 2; i++)
            FreeBitmap(&f[i].bmp);
        return;
    }
    long cropW = x1 - x0 + 1;
    double scale = MIN((double)slotW / (double)cropW, (double)slotH / (double)cropH);
    long dw = MAX(lround(cropW * scale), 1);
    long dh = MAX(lround(cropH * scale), 1);
    if (dw > slotW) {
        dh = MAX(lround(dh * (double)slotW / (double)dw), 1);
        dw = slotW;
    }

    // The guard that matters here is not "is there a head" -- three ways of asking that were tried and none
    // of them separated a head from a headless torso -- but "do the two frames differ at all". A crop that
    // swallows the shoulders produces two identical pictures and an animation that appears to do nothing.
    double diff = FrameDifference(&f[0].bmp, &f[1].bmp, x0, top, cropW, cropH);
    if (diff < kMinFrameDifference)
        Fail(@"плечи: кадры различаются лишь на %.1f%%, порог %.0f%% — движение не будет видно", diff * 100.0,
             kMinFrameDifference * 100.0);

    EBBitmap out[2];
    for (int i = 0; i < 2; i++)
        out[i] = CropTo(&f[i].bmp, x0, top, cropW, cropH, dw, dh);

    printf("  окно %ldx%ld от y=%ld, кадры различаются на %.1f%%\n", cropW, cropH, top, diff * 100.0);
    fflush(stdout);

    // Both frames side by side on the panel's own colour. A head that never made it into the source cannot
    // be caught by any cheap test, so the pair is laid out to be looked at in one glance before it is used.
    // Built before Emit, which frees the bitmaps it is given.
    long gap = 8;
    long sheetW = dw * 2 + gap + 16, sheetH = dh + 16;
    EBBitmap sheet = AllocBitmap(sheetW, sheetH);
    for (long y = 0; y < sheetH; y++)
        for (long x = 0; x < sheetW; x++)
            PxSet(&sheet, x, y, 28, 28, 31, 255);
    CompositeOver(&sheet, &out[0], 8, 8);
    CompositeOver(&sheet, &out[1], 8 + dw + gap, 8);
    WritePNG(&sheet, [outDir stringByAppendingPathComponent:@"preview_shoulders.png"]);
    printf("  preview_shoulders.png — оба кадра рядом\n");
    FreeBitmap(&sheet);

    for (int i = 0; i < 2; i++)
        Emit(&out[i], outDir, @(kOut[i]));

    for (int i = 0; i < 2; i++)
        FreeBitmap(&f[i].bmp);
}

#pragma mark - Cups

// The seven vessels, one per drink.
//
// These come out with a real alpha channel rather than a coloured background, so there is nothing to key
// and no colour that could survive at the rim. All this mode does is cut each one to its own content and
// fit it into the panel's slot.
//
// Fitting matters because the vessels are deliberately different shapes: the water glass is 1.29 times as
// tall as it is wide, the black tea glass only 0.55. Scaling each to the same height would make the tall
// ones enormous and the wide ones tiny; scaling each to the same width would do the opposite. So each is
// scaled by whichever of the two limits binds first, which keeps every vessel the right shape and lets
// its height follow from that.
static void RunCups(NSString *inDir, NSString *outDir) {
    static const struct { const char *src; const char *dst; } kMap[] = {
        {"green.png", "tea_green.png"},      {"white.png", "tea_white.png"},
        {"Ulun.png", "tea_oolong.png"},     {"black.png", "tea_black.png"},
        {"pu-er.png", "tea_puer.png"},       {"grass.png", "tea_herbal.png"},
        {"water.png", "tea_water.png"},
    };
    // The slot in the bubble, at 2x.
    long slotW = lround(kPanelArtW * gArtScale);
    long slotH = lround(kPanelArtH * gArtScale);

    long tallest = 0, widest = 0;
    for (size_t i = 0; i < sizeof(kMap) / sizeof(kMap[0]); i++) {
        NSString *src = [inDir stringByAppendingPathComponent:@(kMap[i].src)];
        if (![[NSFileManager defaultManager] fileExistsAtPath:src]) {
            printf("  %-16s пропуск, файла нет\n", kMap[i].src);
            continue;
        }
        EBBitmap b = DecodePNG(src);
        if (!b.px)
            continue;
        // No keying: the generator produced transparency, which is better than a colour to remove.
        // A higher floor than elsewhere: these are photographs of glass, and the soft edge of the vessel
        // fades out over many pixels rather than ending at a line like a cut-out drawing does.
        gContentAlphaFloor = 64;
        EBRect box = ContentRect(&b);
        gContentAlphaFloor = 8;
        if (!box.valid) {
            Fail(@"%s: изображение полностью прозрачное", kMap[i].src);
            FreeBitmap(&b);
            continue;
        }
        long cw = box.x1 - box.x0 + 1, ch = box.y1 - box.y0 + 1;
        double scale = (double)slotW / (double)cw;
        double byH = (double)slotH / (double)ch;
        if (byH < scale)
            scale = byH;
        long dw = MAX(lround(cw * scale), 1);
        long dh = MAX(lround(ch * scale), 1);
        if (dw > slotW) {
            // Only reachable if rounding pushed it over; keep the vessel inside the slot.
            dh = MAX(lround(dh * (double)slotW / (double)dw), 1);
            dw = slotW;
        }
        EBBitmap out = CropTo(&b, box.x0, box.y0, cw, ch, dw, dh);
        WritePNG(&out, [outDir stringByAppendingPathComponent:@(kMap[i].dst)]);
        printf("  %-16s %ldx%ld -> %-14s %ldx%ld  пропорция %.2f\n", kMap[i].src, cw, ch, kMap[i].dst, dw, dh,
               (double)cw / (double)ch);
        if (dh > tallest) tallest = dh;
        if (dw > widest) widest = dw;
        FreeBitmap(&out);
        FreeBitmap(&b);
    }
    printf("  самый высокий %ld px, самый широкий %ld px, слот %ldx%ld\n", tallest, widest, slotW, slotH);
    if (widest > slotW || tallest > slotH)
        Fail(@"сосуд не поместился в слот");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: mkframes <full|bust|eyes|shoulders|cups> <input dir> <output dir>\n");
            return 2;
        }
        NSString *mode = @(argv[1]), *inDir = @(argv[2]), *outDir = @(argv[3]);

        // Optional, and only needed when generating for the Windows port: see the declarations.
        struct { const char *name; double *slot; } overrides[] = {
            {"EYELEO_ART_SCALE", &gArtScale},
            {"EYELEO_SHORT_ART_W", &gShortArtW},
            {"EYELEO_SHORT_ART_H", &gShortArtH},
        };
        for (size_t i = 0; i < sizeof(overrides) / sizeof(overrides[0]); i++) {
            const char *raw = getenv(overrides[i].name);
            if (!raw || !*raw)
                continue;
            double value = atof(raw);
            if (!(value > 0.0)) {
                fprintf(stderr, "  FAIL  %s=%s не положительное число\n", overrides[i].name, raw);
                return 2;
            }
            *overrides[i].slot = value;
        }
        printf("== %s  (scale %.3g, short slot %.3gx%.3g)\n", mode.UTF8String, gArtScale, gShortArtW,
               gShortArtH);
        [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        printf("== %s\n", mode.UTF8String);
        if ([mode isEqualToString:@"full"]) RunFull(inDir, outDir);
        else if ([mode isEqualToString:@"bust"]) RunBust(inDir, outDir);
        else if ([mode isEqualToString:@"eyes"]) RunEyes(inDir, outDir);
        else if ([mode isEqualToString:@"shoulders"]) RunShoulders(inDir, outDir);
        else if ([mode isEqualToString:@"cups"]) RunCups(inDir, outDir);
        else { Fail(@"неизвестный режим %@", mode); return 2; }
        if (gFailures) printf("провалов: %d\n", gFailures);
        else printf("готово\n");
        return gFailures ? 1 : 0;
    }
}