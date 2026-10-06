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
    EBFrameShoulders,  // head-and-shoulders bust, used by the neck and shoulders exercise
};

// How many personage frames exist. personage: and purgePersonage index their name array with the raw
// enum value, and that array is sized by this constant, so the enum and the array cannot drift apart.
enum { EBNumPersonageFrames = 8 };

@interface EBAssets : NSObject

@property(class, readonly) EBAssets *shared;

- (nullable NSImage *)panel;         // skin2.png, 461x156, short break and dialogs
- (nullable NSImage *)bar;           // skin3.png, 550x74, waiting banner
- (nullable NSImage *)bubble;        // skin4.png, 209x71, countdown
- (nullable NSImage *)title;         // eyeleo_title.png
- (nullable NSImage *)windowImage;   // minipause_window.png, the "look at the window" image
- (nullable NSImage *)noticeLeopard; // notification_leopard.png
- (nullable NSImage *)personage:(EBPersonageFrame)frame;

// The two halves of the neck and shoulders exercise, 156x46 and 90x57. Kept apart on purpose: baked
// into one image, the head moves with the torso and the result reads as a sliding picture rather than
// a stretch. Both come out of tools/mkpersonage.m, the head from the app's own artwork.
- (nullable NSImage *)shouldersTorso;
- (nullable NSImage *)shouldersHead;

// Drops the personage frames. Called when a break ends; the common case holds none at all,
// because short breaks are the only consumer.
- (void)purgePersonage;

@end

NS_ASSUME_NONNULL_END

#endif // EB_ASSETS_H