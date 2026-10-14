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

#import "ebexercise.h"

NS_ASSUME_NONNULL_BEGIN

@protocol EBOverlayDelegate <NSObject>
- (void)overlayDidRequestSkipLongBreak;
- (void)overlayDidRequestRefuse;
- (void)overlayDidRequestPostpone;
- (void)overlayDidRequestAccept;
- (void)overlayDidRequestCloseShortBreak;
// The app is background-only again after a break, and the menu bar item it should be living in has to be
// put back. Going to NSApplicationActivationPolicyRegular and coming back costs the status item, and the
// system does not reliably hand it back on its own: what the user sees is the Dock icon and no way to
// reach the menu at all, which is the whole interface.
- (void)overlayDidReturnToBackground;
@end

@interface EBOverlayController : NSObject

@property(nonatomic, weak) id<EBOverlayDelegate> delegate;
// Strict mode hides the long break's Skip button, as in the original.
@property(nonatomic) BOOL strictMode;
// Only then may a short break be dismissed with a right click.
@property(nonatomic) BOOL canCloseNotifications;
// Whether there is a foreground session to take the keyboard from. A break that arrives while the screen
// is locked must not remember what is in front, because that is the login window: it is gone by the time
// the break ends, and restoring focus to it left the activation policy switched over for good.
@property(nonatomic) BOOL sessionActive;
// Test hook: forces which exercise a short break shows. EBExerciseNone, the default, keeps the
// original random pick. Without it, checking one exercise means waiting for it to come up in a draw of
// nine, which is not something anyone does twice.
@property(nonatomic) EBExercise forcedExercise;

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

// Hydration reminder. Built from the same skin4 bubble and in the same bottom-right corner as the
// long-break countdown, but with a drawn glass instead of the leopard portrait and an auto-dismiss
// countdown instead of a time remaining until an event. Added in the port.
- (void)showWaterReminderWithVolumeMl:(int)ml seconds:(NSTimeInterval)seconds;
// Yields YES when the long-break countdown owns the corner and the reminder was deferred. The core
// retries rather than dropping the reminder: the two run on unrelated intervals and do collide.
- (BOOL)showWaterReminderDeferred;
// YES while the long-break countdown bubble is up.
- (BOOL)countdownVisible;
- (void)hideWaterReminder;
- (void)hideNotification;

// Brewing bubble. Same skin4 panel and corner as the hydration reminder, but it carries the glass of the
// tea being brewed rather than the water one, and it stays up for as long as the steep lasts instead of
// counting down to its own dismissal.
// autoDismissMs of 0 leaves the bubble up until it is replaced or hidden; the completion notice passes a
// few seconds so the tea does not end with a permanent marker on screen.
- (void)showTeaReminderWithCaption:(NSString *)caption image:(nullable NSImage *)glass
                            msLeft:(long)msLeft autoDismissMs:(long)autoDismissMs;
- (void)updateTeaReminderCaption:(NSString *)caption msLeft:(long)msLeft;
- (void)hideTeaReminder;
// YES while a brewing bubble is up. The menu blocks "pour" then, so a steep cannot be started behind one.
- (BOOL)teaReminderVisible;

// Everything, immediately. Used on quit and when monitoring is suspended.
- (void)hideAll;

@property(nonatomic, readonly) BOOL anyVisible;

@end

NS_ASSUME_NONNULL_END

#endif // EB_WINDOWS_H