// Image loading for the overlays. The original images are reused from the Windows build
// (bin/Resources and bin/Personages) at their original pixel sizes.
//
// Decoded cost is small and was measured rather than assumed: the eight personage frames are
// 156x98 each, about 60 KB decoded, so the whole set is ~430 KB. Decoding stays lazy and
// purgeable purely to keep the idle footprint near zero; there is no cache tuning to speak of.

#ifndef EB_ASSETS_H
#define EB_ASSETS_H

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, EBPersonageFrame) {
    EBFrameDefault = 0,
    EBFrameLookLeft,
    EBFrameLookRight,
    EBFrameLookUp,
    EBFrameLookDown,
    EBFrameBlink,
    EBFrameCloseTightly,
    // The neck and shoulders exercise: two drawn frames, swapped. Replacing an earlier version that
    // moved a baked picture with a transform.
    EBFrameShouldersUp,
    EBFrameShouldersDown,
    // The full-figure stretch for the long break. Three frames, cycled; they were generated at
    // different scales and aligned by tools/mkframes.m before they were checked in.
    EBFrameStretchNeutral,
    EBFrameStretchLeft,
    EBFrameStretchRight,
    // The head-and-shoulders crop for the short break's "stretch" exercise: arms down, arms up, and a
    // backward bend. Three frames, cycled.
    EBFrameStretchUpNeutral,
    EBFrameStretchUp,
    EBFrameStretchUpper,
    // The palming exercise: eyes open, then covered by both paws. Two frames, cycled.
    EBFrameEyesOpen,
    EBFrameEyesClosed,
};

// How many personage frames exist. personage: and purgePersonage index their name array with the raw
// enum value, and that array is sized by this constant, so the enum and the array cannot drift apart.
enum { EBNumPersonageFrames = 17 };

// What is being drunk. Each has its own glass, so the reminder shows the cup and not a generic icon.
typedef NS_ENUM(int, EBDrinkKind) {
    EBDrinkNone = 0,
    EBDrinkGreen,   // green tea
    EBDrinkWhite,   // white tea
    EBDrinkOolong,
    EBDrinkBlack,
    EBDrinkPuer,
    EBDrinkHerbal,
    EBDrinkWater,   // the hydration reminder, not tea
};

// How many kinds exist, counting the water. drinkImage: indexes its array with the raw value.
enum { EBNumDrinks = 7 };

@interface EBAssets : NSObject

@property(class, readonly) EBAssets *shared;

- (nullable NSImage *)panel;         // skin2.png, 461x156, short break and dialogs
- (nullable NSImage *)bar;           // skin3.png, 550x74, waiting banner
- (nullable NSImage *)bubble;        // skin4.png, 209x71, countdown
- (nullable NSImage *)title;         // eyeleo_title.png
- (nullable NSImage *)windowImage;   // minipause_window.png, the "look at the window" image
- (nullable NSImage *)noticeLeopard; // notification_leopard.png
- (nullable NSImage *)personage:(EBPersonageFrame)frame;

// The glass for a drink, at 71x44 pt. Seven separate vessels rather than one tinted, because the shapes
// are the point: a tall faceted water glass and a wide shallow one tell you apart at a glance.
- (nullable NSImage *)drinkImage:(EBDrinkKind)drink;

// Drops the personage frames. Called when a break ends; the common case holds none at all,
// because short breaks are the only consumer.
- (void)purgePersonage;

// Drops the glass bitmaps. Called when the reminder closes; seven vessels are small but there is no
// reason to hold them between drinks either.
- (void)purgeDrinks;

@end

NS_ASSUME_NONNULL_END

#endif // EB_ASSETS_H