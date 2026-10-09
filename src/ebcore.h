// Core state machine, settings and statistics.
//
// Deliberately free of AppKit: everything here is plain C data plus CoreFoundation,
// so the state machine can be unit-tested without a window server (see tests/).
// All presentation goes through EBCoreDelegate.

#ifndef EB_CORE_H
#define EB_CORE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Port of the original `enum EStates` (source/code/main.h:16), same order and meaning.
typedef NS_ENUM(int, EBState) {
    EBStateNone = 0,
    EBStateFirstLaunch,
    EBStateSuspended,
    EBStateIdle,
    EBStateWaitingScreen,
    EBStateStartBigPause,
    EBStateAutoRelax,
    EBStateRelaxing,
    EBStateDestroy,
};

// Port of eyeleo::settings (source/code/settings.cpp) plus the CheckSettings() clamps
// from EyeApp::CheckSettings, which also serve as the valid ranges of the settings UI.
enum {
    EBLongBreakConfirmationSec = 6,
    EBDisableActivity1Min = 60,
    EBDisableActivity2Min = 180,
    EBBigPauseIntervalMaxMin = 120,
    EBBigPauseDurationMaxMin = 30,
    EBMiniPauseIntervalMinMin = 5,
    EBMiniPauseIntervalMaxMin = 30,
    EBMiniPauseDurationMaxMin = 20,
    EBAutoRelaxAfterMs = 8 * 60 * 1000,
    EBMinIntervalMs = 91 * 1000, // lower clamp when restoring a countdown
    EBPostponeMs = 180 * 1000,   // "give me 3 minutes"
    EBDemoBreakSec = 5,          // demo long break from the settings window
    EBEarlySkipFractionNum = 35,
    EBEarlySkipFractionDen = 100,
};

// Max warning interval, 3 minutes. Kept out of the enum above because it is not an integer.
static const double EBWarningIntervalMaxMin = 3.0;
// The settings popup offers 20/30/60/90s (settings_wnd.cpp:13-33); 20s is its floor. Clamping the floor
// matters because the notice is worthless below it: anything not larger than
// EBLongBreakConfirmationSec leaves no room to count down before the dialog opens.
static const double EBWarningIntervalMinMin = 20.0 / 60.0;

// How long the hydration bubble stays up. Long enough to read the instruction and reach for a glass,
// short enough not to become the thing that is being complained about.
static const int EBWaterReminderSec = 15;

// Hydration reminders. Both lists come from the settings popup and are the only combinations a user
// can pick, so the clamp in clampSettings pulls a value back onto its list rather than inventing a
// bound: a hand-edited plist must not be able to produce an interval the popup cannot show.
//
// The default is 30 min / 100 ml, so the hourly total is 200 ml delivered as two comfortable sips
// rather than one 200 ml glass. NIOSH notes that shorter intervals work better than large amounts
// infrequently, which is what the small default portion follows. The worst combination the popup
// allows is 15 min x 250 ml = 1000 ml/hour, comfortably under the 1414 ml/hour ceiling above which
// water intoxication becomes a risk; no settings combination can breach it.
static const int kWaterIntervalsMin[] = { 15, 20, 25, 30, 45, 60, 90, 120 };
static const int kWaterVolumesMl[] = { 50, 100, 150, 200, 250 };
static const int EBWaterIntervalDefaultMin = 30;
static const int EBWaterVolumeDefaultMl = 100;

typedef struct {
    BOOL bigPauseEnabled;
    int bigPauseInterval; // minutes
    int bigPauseDuration; // minutes
    BOOL miniPauseEnabled;
    int miniPauseInterval; // minutes
    int miniPauseDuration; // minutes
    BOOL warningEnabled;
    double warningInterval; // minutes
    BOOL soundsEnabled;
    BOOL strictModeEnabled;
    BOOL windowNearby;
    BOOL canCloseNotifications;
    BOOL inactivityTracking;
    BOOL showNotifications;
    BOOL miniPauseFullscreen;
    BOOL waterReminderEnabled;
    int waterIntervalMin;
    int waterVolumeMl;
} EBSettings;

typedef struct {
    BOOL firstLaunch;
    BOOL seenSettings;
    unsigned longBreakCount;
    unsigned earlySkipCount;
    unsigned lateSkipCount;
    unsigned refuseCount;
    unsigned postponeCount;
    unsigned autoBreakCount;
    unsigned shortBreakCount;
    long lastBigPauseTimeLeft;  // ms
    long lastMiniPauseTimeLeft; // ms
    double lastShutdown;         // unix seconds; 0 means "never"
} EBStats;

// How the UI should render a remaining-time value.
typedef NS_ENUM(int, EBTimeMode) {
    EBTimeModeTooManyHours = 0, // ru only: "больше часа"
    EBTimeModeHoursAndMinutes,  // "2 hours 5 minutes" / "2 часа 5 минут"
    EBTimeModeClock,            // "4:59" — seconds always visible
};

// Splits a remaining-time value. forceSeconds mirrors the v1.3.6 behaviour of always
// showing seconds on the long break screen; otherwise seconds appear only under 3 minutes.
EBTimeMode EBTimeSpec(long ms, BOOL forceSeconds, BOOL russian, long *outHours, long *outMinutes, long *outSeconds);

// Russian plural category: 0 = one (1, 21, 31...), 1 = few (2-4, 22-24...), 2 = many.
int EBPluralCategory(long n, BOOL russian);

// Opt-in tracing, off unless EYELEO_DEBUG=1. Shared by every layer so the state machine, the
// overlays and the scheduler can all be watched in one log.
BOOL EBTraceOn(void);

// Everything the core needs from the app layer.
@protocol EBCoreDelegate <NSObject>
- (int)displayCount;
- (int)fullscreenDisplay; // index of the display covered by a fullscreen app, or -1
- (void)hideFrontmostApp; // strict mode: get the blocking app out of the way
- (void)presentLongBreakWithSeconds:(int)seconds demo:(BOOL)demo;
- (void)dismissLongBreak;
- (void)presentCountdownWithMsLeft:(long)msLeft display:(int)display;
- (void)dismissCountdown;
- (void)presentBeforeBreak;
- (void)dismissBeforeBreak;
- (void)presentWaiting;
- (void)dismissWaiting;
- (void)presentShortBreakShowCount:(unsigned)showCount fullscreen:(BOOL)fullscreen;
// Added in the port: the hydration reminder. waterReminderDeferred is YES when the long-break countdown
// owns the bottom-right corner, in which case the core must not present and should retry later.
- (void)presentWaterReminderWithVolumeMl:(int)ml seconds:(int)seconds;
- (BOOL)waterReminderDeferred;
// YES while a brewing steep is close enough to its end to hold the short break, the hydration reminder and
// the long break back. The core asks this before presenting any of them and simply waits: the counters
// behind those are written so that holding them costs nothing and they fire on the first free tick.
- (BOOL)teaBlocksEvents;
- (void)dismissShortBreak;
- (void)updateStatusTitle:(NSString *)title isPaused:(BOOL)paused;
- (void)postNotificationKey:(NSString *)key duration:(nullable NSString *)duration;
- (void)playBreakEndSound;
- (void)terminateApp;
@end

@interface EBCore : NSObject

@property(nonatomic, weak) id<EBCoreDelegate> delegate;
// Struct properties are returned by value, so callers that want to change one field read the
// struct, edit it, and assign the whole thing back: `EBSettings s = core.settings; s.x = ..; core.settings = s;`
@property(nonatomic) EBSettings settings;
// Owned by the core; readwrite only so the unit tests can seed counters.
@property(nonatomic) EBStats stats;
@property(nonatomic, readonly) BOOL destroying;

// Where settings are kept. Defaults to the bundle identifier; unit tests point this at a
// scratch domain so they never touch the real preferences.
@property(nonatomic, copy, nullable) NSString *preferencesDomain;

// Stops saveSettings from writing. Set while the EYELEO_TEST_* overrides are active: those rewrite
// the break intervals, and without this an accelerated smoke run would persist a one-minute
// interval into the user's real configuration on every break.
@property(nonatomic) BOOL persistenceSuspended;

// Time remaining, in ms.
@property(nonatomic, readonly) long timeLeftToBigPause;
@property(nonatomic, readonly) long timeLeftToMiniPause;

@property(nonatomic, readonly) EBState nextState;
@property(nonatomic, readonly) BOOL paused;

// Debug accelerator, port of EyeApp::_fastMode. When on, elapsed time is multiplied so a
// full cycle of breaks can be watched by hand. Never enable for normal use.
@property(nonatomic) BOOL fastMode;

// Test hook. The hydration interval bottoms out at 15 minutes, which makes the feature impossible to
// exercise end to end: every attempt at verifying it costs a quarter of an hour, and over a wait that
// long the machine falls into auto-relax, where the reminder correctly stays silent -- so a failure
// looks exactly like a pass. With this set, the first reminder fires after the given number of seconds.
// Guarded by persistenceSuspended like the other overrides, so a test run cannot persist it.
@property(nonatomic) int waterTestFireSec;

// Starts in STATE_FIRST_LAUNCH (fresh install) or STATE_IDLE (restored timers).
- (void)startWithFirstLaunch:(BOOL)firstLaunch lastShutdown:(double)lastShutdown;

// Called once per scheduler tick with the wall time since the previous tick.
- (void)tickWithElapsedMs:(long)msElapsed;

// Interval the scheduler should use for the next tick, in ms.
- (long)nextTickIntervalMs;

- (void)requestPauseForMinutes:(int)minutes;
- (void)resumeFromPause;
- (void)takeLongBreakNow;
// The before-break dialog's accept path. Must start the break from any state: while the dialog
// is up the core is parked in STATE_NONE, exactly as in the original, so the tray-menu entry
// point (takeLongBreakNow) would refuse to act. Port of StartBigPause() as the dialog calls it.
- (void)acceptLongBreak;
// Entry point for the settings window's "try it out" button. Port of StartBigPause(true);
// note the original only shortens it when strict mode is on.
- (void)startDemoBreak;

// Called by the app when the user dismissed the "before break" dialog.
- (void)refuseBigPause;
// Called by the app when the user pressed "give me a few minutes".
- (void)postponeBigPause;
// Called by the app when the skip button was pressed during a long break.
- (void)skipBigBreak;

- (EBSettings)defaultSettings;
// Returns NO when nothing has been stored yet, which the app treats as a first launch.
- (BOOL)loadSettings;
- (void)saveSettings;

// Recomputes break durations after the settings window closed.
- (void)settingsDidClose;

// Exposed for the tests: the same clamp the app applies on load and on save. Reading it through the
// public settings property instead would not distinguish "clamped to 30" from "already 30".
- (EBSettings)clampSettings:(EBSettings)s;

// Tooltip text for the menu bar, honouring the paused and disabled cases.
- (nullable NSString *)statusTitleWithLanguage:(NSString *)language;

@end

NS_ASSUME_NONNULL_END

#endif // EB_CORE_H