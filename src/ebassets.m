#import "ebassets.h"

@interface EBAssets ()
- (nullable NSImage *)load:(NSString *)name inDirectory:(nullable NSString *)directory;
@end

@implementation EBAssets {
    NSMutableDictionary<NSString *, NSImage *> *_cache;
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

// Indexed by the raw enum value, as with the personage frames above.
static NSString *const kDrinkNames[EBNumDrinks] = {
    @"tea_green", @"tea_white", @"tea_oolong", @"tea_black", @"tea_red", @"tea_puer", @"tea_herbal",
    @"tea_water",
};

- (NSImage *)drinkImage:(EBDrinkKind)drink {
    if (drink <= EBDrinkNone || drink > EBDrinkWater)
        return nil;
    return [self load:kDrinkNames[drink - 1]];
}

- (void)purgeDrinks {
    for (int i = 0; i < EBNumDrinks; i++)
        [_cache removeObjectForKey:kDrinkNames[i]];
}

@end