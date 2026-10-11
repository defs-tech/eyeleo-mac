#import "ebassets.h"

@interface EBAssets ()
- (nullable NSImage *)load:(NSString *)name inDirectory:(nullable NSString *)directory;
@end

@implementation EBAssets {
    NSMutableDictionary<NSString *, NSImage *> *_cache;
    NSMutableSet<NSString *> *_drinkKeys;
}

+ (EBAssets *)shared {
    static EBAssets *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[EBAssets alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSMutableDictionary dictionary];
        _drinkKeys = [NSMutableSet set];
    }
    return self;
}

- (nullable NSImage *)load:(NSString *)name {
    return [self load:name inDirectory:nil];
}

- (nullable NSImage *)load:(NSString *)name inDirectory:(NSString *)directory {
    NSString *key = directory ? [NSString stringWithFormat:@"%@/%@", directory, name] : name;
    NSImage *cached = _cache[key];
    if (cached)
        return cached;

    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:directory];
    if (!path) {
        NSLog(@"[EyeLeo] missing asset %@.png", key);
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image)
        return nil;

    // Broken images otherwise silently collapse to a zero-sized view.
    if (image.size.width < 1 || image.size.height < 1) {
        NSLog(@"[EyeLeo] asset %@.png decoded to zero size", name);
        return nil;
    }
    _cache[key] = image;
    return image;
}

- (NSImage *)panel {
    return [self load:@"skin2"];
}

- (NSImage *)bar {
    return [self load:@"skin3"];
}

- (NSImage *)bubble {
    return [self load:@"skin4"];
}

- (NSImage *)title {
    return [self load:@"eyeleo_title"];
}

- (NSImage *)windowImage {
    return [self load:@"minipause_window"];
}

- (NSImage *)noticeLeopard {
    return [self load:@"notification_leopard"];
}

// Indexed by the raw enum value, so EBPersonageFrame and this array are one list, not two.
static NSString *const kPersonageNames[EBNumPersonageFrames] = {
    @"leopard_default", @"leopard_look_left", @"leopard_look_right",
    @"leopard_look_up", @"leopard_look_down", @"leopard_blink",
    @"leopard_close_tightly", @"leopard_shoulders_up", @"leopard_shoulders_down",
    @"leopard_stretch_neutral", @"leopard_stretch_left", @"leopard_stretch_right",
    @"leopard_stretch_up_neutral", @"leopard_stretch_up", @"leopard_stretch_upper",
    @"leopard_eyes_open", @"leopard_eyes_closed",
};

// The generated personage frames are stored at twice the size the panel asks for, so they stay sharp on
// a Retina display. A PNG carries no resolution of its own, so AppKit reads one pixel as one point and a
// 696px frame arrives as 696pt: twice the intended size, which on the long break pushed the leopard
// through the Dock and off the bottom of the screen. Halving the size here makes the points match the
// pixels the artwork was drawn for. The original seven frames are not doubled and must not be halved.
static const double kRetinaScale = 2.0;

- (NSImage *)personage:(EBPersonageFrame)frame {
    if (frame < 0 || frame >= EBNumPersonageFrames)
        return nil;
    NSString *key = kPersonageNames[frame];
    NSImage *cached = _cache[key];
    if (cached)
        return cached;

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:
                                   [NSBundle.mainBundle pathForResource:key ofType:@"png"
                                                          inDirectory:@"Personages"]];
    if (image && frame >= EBFrameShouldersUp) {
        NSImage *sized = [[NSImage alloc] initWithSize:NSMakeSize(image.size.width / kRetinaScale,
                                                                   image.size.height / kRetinaScale)];
        [sized addRepresentation:image.representations.firstObject];
        image = sized;
    }
    _cache[key] = image;
    return image;
}

- (void)purgePersonage {
    for (int i = 0; i < EBNumPersonageFrames; i++)
        [_cache removeObjectForKey:kPersonageNames[i]];
}

// The PNG header, read straight from the file: the eight-byte signature, then the IHDR chunk carrying the
// width, the height, the bit depth and the colour type. NSImage will decode a JPEG that has been renamed to
// .png and it reports nothing about the colour type, so the one property that matters here - whether the
// vessel carries a real alpha channel - can only be answered from the bytes themselves.
typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t bitDepth;
    uint8_t colourType;
} EBPngHeader;

static BOOL ReadPngHeader(NSString *path, EBPngHeader *out) {
    static const uint8_t kSignature[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file)
        return NO;
    uint8_t buf[26];
    size_t read = fread(buf, 1, sizeof(buf), file);
    fclose(file);

    if (read != sizeof(buf) || memcmp(buf, kSignature, sizeof(kSignature)) != 0 || memcmp(buf + 12, "IHDR", 4) != 0)
        return NO;
    out->width = ((uint32_t)buf[16] << 24) | ((uint32_t)buf[17] << 16) | ((uint32_t)buf[18] << 8) | (uint32_t)buf[19];
    out->height = ((uint32_t)buf[20] << 24) | ((uint32_t)buf[21] << 16) | ((uint32_t)buf[22] << 8) | (uint32_t)buf[23];
    out->bitDepth = buf[24];
    out->colourType = buf[25];
    return YES;
}

- (nullable NSImage *)drinkImageNamed:(NSString *)name {
    if (name.length == 0)
        return nil;
    NSString *key = [NSString stringWithFormat:@"tea_%@", name];
    NSImage *cached = _cache[key];
    if (cached)
        return cached;

    NSString *path = [NSBundle.mainBundle pathForResource:key ofType:@"png"];
    if (!path) {
        NSLog(@"[EyeLeo] no vessel %@.png, nothing will be drawn in the glass slot", key);
        return nil;
    }

    // The three checks below are what separate a vessel from a picture that happens to be named like one.
    // They cost a file read on first use and nothing after that, and each one has a failure that shows up
    // on screen as a black box or a bubble that will not draw: without an alpha channel a PNG composites
    // against black, and oversized artwork is cropped off the edge of the slot.
    EBPngHeader header;
    if (!ReadPngHeader(path, &header)) {
        NSLog(@"[EyeLeo] vessel %@.png is not a PNG", key);
        return nil;
    }
    if (header.bitDepth != EBPngBitDepth || header.colourType != EBPngColourTypeRGBA) {
        NSLog(@"[EyeLeo] vessel %@.png is %u-bit colour type %u, want %u-bit RGBA (%u) with a real alpha channel",
              key, header.bitDepth, header.colourType, EBPngBitDepth, EBPngColourTypeRGBA);
        return nil;
    }
    const uint32_t maxW = (uint32_t)EBDrinkSlotWidthPt * 2;
    const uint32_t maxH = (uint32_t)EBDrinkSlotHeightPt * 2;
    if (header.width > maxW || header.height > maxH) {
        NSLog(@"[EyeLeo] vessel %@.png is %ux%u, larger than the %ux%u slot", key, header.width, header.height,
              maxW, maxH);
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image) {
        NSLog(@"[EyeLeo] vessel %@.png did not decode", key);
        return nil;
    }
    _cache[key] = image;
    [_drinkKeys addObject:key];
    return image;
}

- (void)purgeDrinks {
    for (NSString *key in _drinkKeys)
        [_cache removeObjectForKey:key];
    [_drinkKeys removeAllObjects];
}

@end