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

- (NSImage *)personage:(EBPersonageFrame)frame {
    static NSString *const names[] = {
        @"leopard_default", @"leopard_look_left", @"leopard_look_right",
        @"leopard_look_up", @"leopard_look_down", @"leopard_blink",
        @"leopard_close_tightly",
    };
    if (frame < 0 || frame > EBFrameCloseTightly)
        return nil;
    return [self load:names[frame] inDirectory:@"Personages"];
}

- (void)purgePersonage {
    static NSString *const names[] = {
        @"leopard_default", @"leopard_look_left", @"leopard_look_right",
        @"leopard_look_up", @"leopard_look_down", @"leopard_blink",
        @"leopard_close_tightly",
    };
    for (NSUInteger i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        [_cache removeObjectForKey:names[i]];
}

@end