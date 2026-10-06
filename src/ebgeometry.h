// Overlay geometry as pure functions, so it can be unit-tested against synthetic screens instead of
// needing a second monitor attached.
//
// Two coordinate spaces matter on macOS and mixing them up is how overlays end up under the Dock:
//   screen.frame        the whole display, including the menu bar and the Dock area
//   screen.visibleFrame the work area, i.e. frame minus menu bar and Dock
// Full-screen things (the dimming layer, the long break) must use frame; anything that floats above
// the desktop (panels, bubbles, dialogs) must use visibleFrame.

#ifndef EB_GEOMETRY_H
#define EB_GEOMETRY_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Centres `content` in `workArea`.
NSRect EBCenteredRect(NSSize content, NSRect workArea);

// Shrinks `content` to fit inside `workArea`, preserving the aspect ratio. Returns `content`
// unchanged when it already fits, and clamps to at least 1x1 so a degenerate area cannot produce a
// zero or negative size.
NSSize EBFittedSize(NSSize content, NSRect workArea);

// Pins `content` to the bottom-right corner of `workArea` with the given inset, as the countdown
// bubble and the notification do.
NSRect EBBottomRightRect(NSSize content, NSRect workArea, CGFloat inset);

NS_ASSUME_NONNULL_END

#endif // EB_GEOMETRY_H