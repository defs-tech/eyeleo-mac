// The five overlays of the original app, rebuilt on AppKit.
//
// Layouts and timings come from the Windows version:
//   long break      bigpause_wnd.cpp      full display, black, leopard, text, clock, Skip
//   short break     minipause_wnd.cpp      skin2 panel, or the whole screen in fullscreen mode
//   countdown       notification_wnd.cpp   skin4 bubble pinned to the bottom-right corner
//   before break    beforepause_wnd.cpp    skin2 panel with three buttons and a ready timer
//   waiting         waiting_wnd.cpp        skin3 banner, centred
//
// Timings carried over: fades stop at 82% opacity (the Windows build uses 210/255) and the
// exercise animation ticks at 100 ms. Unlike the original, windows are created on demand and
// released when the break ends, so an idle EyeLeo holds no windows at all.

#ifndef EB_WINDOWS_H
#define EB_WINDOWS_H

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol EBOverlayDelegate <NSObject>
- (void)overlayDidRequestSkipLongBreak;
- (void)overlayDidRequestRefuse;
- (void)overlayDidRequestPostpone;
- (void)overlayDidRequestAccept;
- (void)overlayDidRequestCloseShortBreak;
@end

@interface EBOverlayController : NSObject

@property(nonatomic, weak) id<EBOverlayDelegate> delegate;
// Strict mode hides the long break's Skip button, as in the original.
@property(nonatomic) BOOL strictMode;
// Only then may a short break be dismissed with a right click.
@property(nonatomic) BOOL canCloseNotifications;

- (void)showLongBreakWithSeconds:(int)seconds;
- (void)hideLongBreakAnimated:(BOOL)animated;

- (void)showShortBreakWithCount:(unsigned)showCount
                      durationMs:(long)durationMs
                      fullscreen:(BOOL)fullscreen
                    windowNearby:(BOOL)windowNearby;
- (void)hideShortBreakAnimated:(BOOL)animated;

- (void)showCountdownWithMsLeft:(long)msLeft onDisplay:(int)display;
- (void)updateCountdownMsLeft:(long)msLeft;
- (void)hideCountdownAnimated:(BOOL)animated;

- (void)showBeforeBreakOnDisplay:(int)display;
- (void)hideBeforeBreakAnimated:(BOOL)animated;

- (void)showWaiting;
- (void)hideWaitingAnimated:(BOOL)animated;

// A self-dismissing bubble in the bottom-right corner. Replaces the Windows tray balloon so the
// app never has to ask for the Notifications permission.
- (void)showNotificationWithText:(NSString *)text seconds:(NSTimeInterval)seconds;
- (void)hideNotification;

// Everything, immediately. Used on quit and when monitoring is suspended.
- (void)hideAll;

@property(nonatomic, readonly) BOOL anyVisible;

@end

NS_ASSUME_NONNULL_END

#endif // EB_WINDOWS_H