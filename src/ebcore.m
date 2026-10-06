#import "ebcore.h"
#import "ebdetect.h"
#import "ebtext.h"

#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>


// Opt-in state machine tracing. Off unless EYELEO_DEBUG=1, because a menu-bar utility that
// writes to the unified log every tick is worse than useless.
BOOL EBTraceOn(void) {
    static int cached = -1;
    if (cached < 0)
        cached = [NSProcessInfo.processInfo.environment[@"EYELEO_DEBUG"] isEqualToString:@"1"] ? 1 : 0;
    return cached == 1;
}

static const char *EBStateName(EBState s) {
    switch (s) {
    case EBStateNone: return "none";
    case EBStateFirstLaunch: return "first_launch";
    case EBStateSuspended: return "suspended";
    case EBStateIdle: return "idle";
    case EBStateWaitingScreen: return "waiting";
    case EBStateStartBigPause: return "start_big_pause";
    case EBStateAutoRelax: return "auto_relax";
    case EBStateRelaxing: return "relaxing";
    case EBStateDestroy: return "destroy";
    }
    return "?";
}

// ---------------------------------------------------------------------------------------------
// Time spec

// Mirrors the intent of getTimeStr (source/code/timeloc.cpp): hours and minutes normally, a
// clock reading once seconds matter, and Russian "2 hours" collapsed to "more than an hour"
// because that is what the original shipped.
// The plural category below is deliberately *not* the original's getSecondStr, which tested
// n/10 != 1 and therefore mis-rendered 111 ("111 секунд" instead of "111 секунд" aside,
// 21 and 101 were wrong). Correct rule: one for n%10==1 && n%100!=11, few for n%10 in 2..4
// && n%100 not in 12..14, many otherwise.
EBTimeMode EBTimeSpec(long ms, BOOL forceSeconds, BOOL russian, long *outHours, long *outMinutes, long *outSeconds) {
    long totalSeconds = ms / 1000;
    if (totalSeconds < 0)
        totalSeconds = 0;
    long h = totalSeconds / 3600;
    long m = (totalSeconds % 3600) / 60;
    long s = totalSeconds % 60;

    if (outHours)
        *outHours = h;
    if (outMinutes)
        *outMinutes = m;
    if (outSeconds)
        *outSeconds = s;

    if (forceSeconds)
        return EBTimeModeClock;
    if (russian && h >= 2)
        return EBTimeModeTooManyHours;
    if (h > 0)
        return EBTimeModeHoursAndMinutes;
    if (m == 0)
        return EBTimeModeClock;
    if (m > 4)
        return EBTimeModeHoursAndMinutes;
    return EBTimeModeClock;
}

int EBPluralCategory(long n, BOOL russian) {
    if (!russian)
        return (n == 1) ? 0 : 2;
    long n10 = n % 10, n100 = n % 100;
    if (n10 == 1 && n100 != 11)
        return 0;
    if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14))
        return 1;
    return 2;
}

// ---------------------------------------------------------------------------------------------
// Settings persistence. Section and key names match the original settings.xml so that a
// file exported from the Windows build remains readable.

static CFMutableDictionaryRef SectionFor(CFMutableDictionaryRef root, CFStringRef section) {
    CFMutableDictionaryRef s = (CFMutableDictionaryRef)CFDictionaryGetValue(root, section);
    if (!s) {
        s = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(root, section, s);
        CFRelease(s);
    }
    return s;
}

static void PutInt(CFMutableDictionaryRef root, CFStringRef section, CFStringRef key, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(SectionFor(root, section), key, n);
    CFRelease(n);
}

static void PutDouble(CFMutableDictionaryRef root, CFStringRef section, CFStringRef key, double v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    CFDictionarySetValue(SectionFor(root, section), key, n);
    CFRelease(n);
}

static void PutBool(CFMutableDictionaryRef root, CFStringRef section, CFStringRef key, bool v) {
    PutInt(root, section, key, v ? 1 : 0);
}

static CFNumberRef NumberIn(CFDictionaryRef root, CFStringRef section, CFStringRef key) {
    if (!root || CFGetTypeID(root) != CFDictionaryGetTypeID())
        return NULL;
    CFDictionaryRef s = CFDictionaryGetValue(root, section);
    if (!s || CFGetTypeID(s) != CFDictionaryGetTypeID())
        return NULL;
    CFNumberRef n = CFDictionaryGetValue(s, key);
    if (!n || CFGetTypeID(n) != CFNumberGetTypeID())
        return NULL;
    return n;
}

static int ReadInt(CFDictionaryRef root, CFStringRef section, CFStringRef key, int fallback) {
    CFNumberRef n = NumberIn(root, section, key);
    if (!n)
        return fallback;
    int v = fallback;
    CFNumberGetValue(n, kCFNumberIntType, &v);
    return v;
}

static bool ReadBool(CFDictionaryRef root, CFStringRef section, CFStringRef key, bool fallback) {
    return ReadInt(root, section, key, fallback ? 1 : 0) != 0;
}

static double ReadDouble(CFDictionaryRef root, CFStringRef section, CFStringRef key, double fallback) {
    CFNumberRef n = NumberIn(root, section, key);
    if (!n)
        return fallback;
    double v = fallback;
    CFNumberGetValue(n, kCFNumberDoubleType, &v);
    return v;
}

static unsigned ReadUInt(CFDictionaryRef root, CFStringRef section, CFStringRef key) {
    int v = ReadInt(root, section, key, 0);
    return v < 0 ? 0 : (unsigned)v;
}

// ---------------------------------------------------------------------------------------------
// EBCore

@interface EBCore ()
// Readwrite internally; the public header keeps these read-only.
@property(nonatomic) long timeLeftToBigPause;
@property(nonatomic) long timeLeftToMiniPause;
- (void)changeState:(EBState)next interval:(long)intervalMs;
- (void)repeatState;
- (void)restartBigPauseInterval;
- (void)restartMiniPauseInterval;
- (void)setBigPauseTime:(long)ms;
- (void)startLongBreakWithDemo:(BOOL)demo;
- (void)dismissLongBreak;
- (void)autoRelax;
- (EBSettings)clampSettings:(EBSettings)s;
@end

@implementation EBCore {
    EBState _currentState;
    long _tickIntervalMs;
    long _relaxingTimeLeft;
    long _fullscreenBlockDuration;
    long _timeUntilWaitingWnd;
    long _inactivityTime;
    int _postponeCount;
    BOOL _showedLongBreakCountdown;
    BOOL _destroying;
}

- (instancetype)init {
    if ((self = [super init])) {
        _settings = [self defaultSettings];
        _currentState = EBStateNone;
        _nextState = EBStateNone;
        _tickIntervalMs = 1000;
        _stats.firstLaunch = YES;
    }
    return self;
}

// Not owned: either the bundle's identifier or the string retained by preferencesDomain.
- (CFStringRef)storageId {
    if (_preferencesDomain)
        return (__bridge CFStringRef)_preferencesDomain;
    CFStringRef id = CFBundleGetIdentifier(CFBundleGetMainBundle());
    return id ? id : CFSTR("local.eyeleo.EyeLeo");
}

- (EBSettings)defaultSettings {
    // EyeApp::ResetSettings, source/code/main.cpp:1192
    EBSettings s;
    s.bigPauseEnabled = YES;
    s.bigPauseInterval = 50;
    s.bigPauseDuration = 5;
    s.miniPauseEnabled = YES;
    s.miniPauseInterval = 10;
    s.miniPauseDuration = 8;
    s.warningEnabled = YES;
    s.warningInterval = 0.5;
    s.soundsEnabled = YES;
    s.strictModeEnabled = NO;
    s.windowNearby = YES;
    s.canCloseNotifications = NO;
    s.inactivityTracking = YES;
    s.showNotifications = YES;
    s.miniPauseFullscreen = NO;
    return s;
}

// Clamp ported from EyeApp::CheckSettings, without its assert(false) noise.
- (EBSettings)clampSettings:(EBSettings)s {
    if (s.bigPauseInterval > EBBigPauseIntervalMaxMin)
        s.bigPauseInterval = EBBigPauseIntervalMaxMin;
    if (s.bigPauseDuration > EBBigPauseDurationMaxMin)
        s.bigPauseDuration = EBBigPauseDurationMaxMin;
    if (s.miniPauseInterval > EBMiniPauseIntervalMaxMin)
        s.miniPauseInterval = EBMiniPauseIntervalMaxMin;
    if (s.miniPauseDuration > EBMiniPauseDurationMaxMin)
        s.miniPauseDuration = EBMiniPauseDurationMaxMin;
    if (s.warningInterval > EBWarningIntervalMaxMin)
        s.warningInterval = EBWarningIntervalMaxMin;
    if (s.warningInterval < EBWarningIntervalMinMin)
        s.warningInterval = EBWarningIntervalMinMin;
    if (s.miniPauseInterval < EBMiniPauseIntervalMinMin)
        s.miniPauseInterval = EBMiniPauseIntervalMinMin;
    return s;
}

#pragma mark - Settings

- (BOOL)loadSettings {
    CFPropertyListRef stored = CFPreferencesCopyAppValue(CFSTR("eyeleo"), [self storageId]);
    if (!stored)
        return NO; // nothing written yet: fresh install

    NSDictionary *root = CFBridgingRelease(stored);
    if (![root isKindOfClass:NSDictionary.class])
        return NO;
    CFDictionaryRef r = (__bridge CFDictionaryRef)root;

    CFStringRef big = CFSTR("big_pause"), mini = CFSTR("mini_pause"), warn = CFSTR("warning");
    CFStringRef sounds = CFSTR("sounds"), strict = CFSTR("strict_mode"), nearby = CFSTR("window_nearby");
    CFStringRef closeable = CFSTR("can_close_notifications"), inactivity = CFSTR("inactivity_tracking");
    CFStringRef showNotif = CFSTR("show_notifications"), miniFs = CFSTR("mini_pause_fullscreen");
    CFStringRef stats = CFSTR("statistics");
    CFStringRef enabled = CFSTR("enabled"), interval = CFSTR("interval"), duration = CFSTR("duration");

    EBSettings s = _settings;
    s.bigPauseEnabled = ReadBool(r, big, enabled, s.bigPauseEnabled);
    s.bigPauseInterval = ReadInt(r, big, interval, s.bigPauseInterval);
    s.bigPauseDuration = ReadInt(r, big, duration, s.bigPauseDuration);
    s.miniPauseEnabled = ReadBool(r, mini, enabled, s.miniPauseEnabled);
    s.miniPauseInterval = ReadInt(r, mini, interval, s.miniPauseInterval);
    s.miniPauseDuration = ReadInt(r, mini, duration, s.miniPauseDuration);
    s.warningEnabled = ReadBool(r, warn, enabled, s.warningEnabled);
    s.warningInterval = ReadDouble(r, warn, interval, s.warningInterval);
    s.soundsEnabled = ReadBool(r, sounds, enabled, s.soundsEnabled);
    s.strictModeEnabled = ReadBool(r, strict, enabled, s.strictModeEnabled);
    s.windowNearby = ReadBool(r, nearby, enabled, s.windowNearby);
    s.canCloseNotifications = ReadBool(r, closeable, enabled, s.canCloseNotifications);
    s.inactivityTracking = ReadBool(r, inactivity, enabled, s.inactivityTracking);
    s.showNotifications = ReadBool(r, showNotif, enabled, s.showNotifications);
    s.miniPauseFullscreen = ReadBool(r, miniFs, enabled, s.miniPauseFullscreen);

    // Corrections the original applies for old versions, from EyeApp::LoadSettings.
    if (s.miniPauseInterval < EBMiniPauseIntervalMinMin)
        s.miniPauseInterval = EBMiniPauseIntervalMinMin;
    if (s.miniPauseDuration == 0)
        s.miniPauseDuration = 8;
    _settings = [self clampSettings:s];

    EBStats st = _stats;
    st.firstLaunch = ReadBool(r, stats, CFSTR("first_launch"), YES);
    st.seenSettings = ReadBool(r, stats, CFSTR("seen_settings"), NO);
    st.longBreakCount = ReadUInt(r, stats, CFSTR("long_break_count"));
    st.earlySkipCount = ReadUInt(r, stats, CFSTR("early_skip_count"));
    st.lateSkipCount = ReadUInt(r, stats, CFSTR("late_skip_count"));
    st.refuseCount = ReadUInt(r, stats, CFSTR("refuse_count"));
    st.postponeCount = ReadUInt(r, stats, CFSTR("postpone_count"));
    st.autoBreakCount = ReadUInt(r, stats, CFSTR("auto_break_count"));
    st.shortBreakCount = ReadUInt(r, stats, CFSTR("short_break_count"));
    st.lastBigPauseTimeLeft = ReadInt(r, stats, CFSTR("last_big_pause_time_left"), 0);
    st.lastMiniPauseTimeLeft = ReadInt(r, stats, CFSTR("last_mini_pause_time_left"), 0);
    st.lastShutdown = ReadDouble(r, stats, CFSTR("last_shutdown"), 0);
    _stats = st;

    return YES;
}

- (void)saveSettings {
    if (self.persistenceSuspended)
        return;
    _stats.lastBigPauseTimeLeft = self.timeLeftToBigPause;
    _stats.lastMiniPauseTimeLeft = self.timeLeftToMiniPause;

    EBSettings s = [self clampSettings:_settings];
    _settings = s;

    CFMutableDictionaryRef root = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                            &kCFTypeDictionaryValueCallBacks);
    CFStringRef big = CFSTR("big_pause"), mini = CFSTR("mini_pause"), warn = CFSTR("warning");
    CFStringRef sounds = CFSTR("sounds"), strict = CFSTR("strict_mode"), nearby = CFSTR("window_nearby");
    CFStringRef closeable = CFSTR("can_close_notifications"), inactivity = CFSTR("inactivity_tracking");
    CFStringRef showNotif = CFSTR("show_notifications"), miniFs = CFSTR("mini_pause_fullscreen");
    CFStringRef enabled = CFSTR("enabled"), interval = CFSTR("interval"), duration = CFSTR("duration");

    PutBool(root, big, enabled, s.bigPauseEnabled);
    PutInt(root, big, interval, s.bigPauseInterval);
    PutInt(root, big, duration, s.bigPauseDuration);
    PutBool(root, mini, enabled, s.miniPauseEnabled);
    PutInt(root, mini, interval, s.miniPauseInterval);
    PutInt(root, mini, duration, s.miniPauseDuration);
    PutBool(root, warn, enabled, s.warningEnabled);
    PutDouble(root, warn, interval, s.warningInterval);
    PutBool(root, sounds, enabled, s.soundsEnabled);
    PutBool(root, strict, enabled, s.strictModeEnabled);
    PutBool(root, nearby, enabled, s.windowNearby);
    PutBool(root, closeable, enabled, s.canCloseNotifications);
    PutBool(root, inactivity, enabled, s.inactivityTracking);
    PutBool(root, showNotif, enabled, s.showNotifications);
    PutBool(root, miniFs, enabled, s.miniPauseFullscreen);

    CFStringRef stats = CFSTR("statistics");
    PutBool(root, stats, CFSTR("first_launch"), _stats.firstLaunch);
    PutBool(root, stats, CFSTR("seen_settings"), _stats.seenSettings);
    PutInt(root, stats, CFSTR("long_break_count"), (int)_stats.longBreakCount);
    PutInt(root, stats, CFSTR("early_skip_count"), (int)_stats.earlySkipCount);
    PutInt(root, stats, CFSTR("late_skip_count"), (int)_stats.lateSkipCount);
    PutInt(root, stats, CFSTR("refuse_count"), (int)_stats.refuseCount);
    PutInt(root, stats, CFSTR("postpone_count"), (int)_stats.postponeCount);
    PutInt(root, stats, CFSTR("auto_break_count"), (int)_stats.autoBreakCount);
    PutInt(root, stats, CFSTR("short_break_count"), (int)_stats.shortBreakCount);
    if (_stats.lastShutdown > 0)
        PutDouble(root, stats, CFSTR("last_shutdown"), _stats.lastShutdown);
    PutInt(root, stats, CFSTR("last_big_pause_time_left"), (int)_stats.lastBigPauseTimeLeft);
    PutInt(root, stats, CFSTR("last_mini_pause_time_left"), (int)_stats.lastMiniPauseTimeLeft);

    CFStringRef domain = [self storageId];
    CFPreferencesSetAppValue(CFSTR("eyeleo"), root, domain);
    CFPreferencesAppSynchronize(domain);
    CFRelease(root);
}

- (void)settingsDidClose {
    long bigInterval = (long)_settings.bigPauseInterval * 1000 * 60;
    if (_settings.bigPauseEnabled) {
        if (bigInterval < self.timeLeftToBigPause)
            self.timeLeftToBigPause = bigInterval;
        if (self.timeLeftToBigPause == 0)
            [self restartBigPauseInterval];
    } else {
        self.timeLeftToBigPause = 0;
    }

    long miniInterval = (long)_settings.miniPauseInterval * 1000 * 60;
    if (_settings.miniPauseEnabled) {
        if (miniInterval < self.timeLeftToMiniPause)
            self.timeLeftToMiniPause = miniInterval;
        if (self.timeLeftToMiniPause == 0) {
            [self restartMiniPauseInterval];
            if (_nextState == EBStateSuspended)
                [self changeState:EBStateIdle interval:1000];
        }
    } else {
        self.timeLeftToMiniPause = 0;
    }
    [self saveSettings];
}

#pragma mark - Interval bookkeeping

- (void)changeState:(EBState)next interval:(long)intervalMs {
    if (EBTraceOn())
        fprintf(stderr, "[EB] %s -> %s (every %ldms)\n", EBStateName(_currentState), EBStateName(next),
                intervalMs);
    _tickIntervalMs = intervalMs;
    _nextState = next;
}

- (long)nextTickIntervalMs {
    return _tickIntervalMs > 0 ? _tickIntervalMs : 1000;
}

- (void)repeatState {
    [self changeState:_currentState interval:_tickIntervalMs];
}

- (BOOL)paused {
    return _nextState == EBStateSuspended;
}

#pragma mark - Countdown bookkeeping

- (void)restartBigPauseInterval {
    _postponeCount = 0;
    _inactivityTime = 0;
    _showedLongBreakCountdown = NO;
    self.timeLeftToBigPause = _settings.bigPauseEnabled ? (long)_settings.bigPauseInterval * 1000 * 60 : 0;
    [self changeState:EBStateIdle interval:1000];
}

- (void)restartMiniPauseInterval {
    self.timeLeftToMiniPause = _settings.miniPauseEnabled ? (long)_settings.miniPauseInterval * 1000 * 60 : 0;
}

- (void)setBigPauseTime:(long)ms {
    _postponeCount = 0;
    _inactivityTime = 0;
    if (ms < EBMinIntervalMs)
        ms = EBMinIntervalMs;
    long cap = (long)_settings.bigPauseInterval * 1000 * 60;
    if (ms > cap)
        ms = cap;
    self.timeLeftToBigPause = _settings.bigPauseEnabled ? ms : 0;
    [self changeState:EBStateIdle interval:1000];
}

#pragma mark - Lifecycle

- (void)startWithFirstLaunch:(BOOL)firstLaunch lastShutdown:(double)lastShutdown {
    _stats.firstLaunch = firstLaunch;
    _stats.lastShutdown = lastShutdown;
    [self restartMiniPauseInterval];

    if (firstLaunch) {
        [self changeState:EBStateFirstLaunch interval:1000];
        return;
    }

    // Resume where we left off, but only if the machine was away for less than 30 minutes.
    if (lastShutdown > 0) {
        NSTimeInterval went = [[NSDate date] timeIntervalSince1970] - lastShutdown;
        if (went > 0 && went <= 30 * 60) {
            long p = (long)(went * 1000);
            long bigLeft = _stats.lastBigPauseTimeLeft - p;
            long miniLeft = _stats.lastMiniPauseTimeLeft - p;
            if (bigLeft < -1000 * 60 * 3) {
                [self restartBigPauseInterval];
                [self restartMiniPauseInterval];
            } else {
                if (bigLeft < 1000 * 60)
                    bigLeft = 1000 * 60;
                [self setBigPauseTime:bigLeft];
                if (miniLeft < 1000 * 60)
                    miniLeft = 1000 * 60;
                self.timeLeftToMiniPause = _settings.miniPauseEnabled ? miniLeft : 0;
            }
            return;
        }
    }
    [self restartBigPauseInterval];
}

#pragma mark - State machine

// Port of EyeApp::ExecuteTask, source/code/main.cpp:491
- (void)tickWithElapsedMs:(long)msElapsed {
    _currentState = _nextState;
    _nextState = EBStateNone;

    id<EBCoreDelegate> d = self.delegate;
    if (!d)
        return;

    if (EBTraceOn())
        fprintf(stderr, "[EB] tick state=%s elapsed=%ldms big=%ld mini=%ld\n",
                EBStateName(_currentState), msElapsed, self.timeLeftToBigPause,
                self.timeLeftToMiniPause);

    if (_settings.inactivityTracking && _currentState != EBStateSuspended && _currentState != EBStateAutoRelax) {
        // The original polled the cursor position because Windows offered no alternative.
        // macOS answers directly, and this also sees keyboard activity.
        if (EBIdleSeconds() >= 1.0)
            _inactivityTime += msElapsed;
        else
            _inactivityTime = 0;
    }

    switch (_currentState) {
    case EBStateSuspended: {
        [self repeatState];
        _inactivityTime -= msElapsed * (_fastMode ? 2 : 1);
        if (_inactivityTime <= 0) {
            [d postNotificationKey:@"tb_notification_start_after_pause" duration:nil];
            [self restartBigPauseInterval];
            [self restartMiniPauseInterval];
            [self saveSettings];
        }
    } break;

    case EBStateFirstLaunch: {
        [d postNotificationKey:@"tb_notification_first_launch"
                      duration:EBSecondsText((long)_settings.bigPauseInterval * 60, EBRussianNow())];
        _stats.firstLaunch = NO;
        [self restartBigPauseInterval];
        [self restartMiniPauseInterval];
        [self saveSettings];
    } break;

    case EBStateIdle: {
        if (_settings.bigPauseEnabled || _settings.miniPauseEnabled) {
            [self repeatState];

            if (_settings.inactivityTracking && _inactivityTime >= EBAutoRelaxAfterMs) {
                [self autoRelax];
                break;
            }

            long confirmMs = EBLongBreakConfirmationSec * 1000L;

            if (_settings.bigPauseEnabled && self.timeLeftToBigPause > 0) {
                self.timeLeftToBigPause -= msElapsed * (_fastMode ? 8 : 1);

                if (_settings.warningEnabled && _settings.warningInterval > 0 && !_showedLongBreakCountdown &&
                    self.timeLeftToBigPause <= (long)(_settings.warningInterval * 60 * 1000) &&
                    self.timeLeftToBigPause > confirmMs) {
                    // Show the countdown on the first display that a fullscreen app is not covering.
                    int fullscreen = [d fullscreenDisplay];
                    int displays = [d displayCount];
                    for (int i = 0; i < displays; i++) {
                        if (i == fullscreen)
                            continue;
                        self.timeLeftToBigPause = (long)(_settings.warningInterval * 60 * 1000);
                        [d presentCountdownWithMsLeft:self.timeLeftToBigPause display:i];
                        _showedLongBreakCountdown = YES;
                        break;
                    }
                }

                if (self.timeLeftToBigPause <= confirmMs) {
                    [self changeState:EBStateStartBigPause interval:100];
                    break;
                }
            }

            if (_settings.miniPauseEnabled) {
                if (self.timeLeftToMiniPause > 0)
                    self.timeLeftToMiniPause -= msElapsed * (_fastMode ? 2 : 1);
                if (!_showedLongBreakCountdown && self.timeLeftToMiniPause <= 0) {
                    _stats.shortBreakCount++;
                    // The original does this at the tail of StartMiniPause(); without it the
                    // short break re-fires on every single tick.
                    [self restartMiniPauseInterval];
                    [d presentShortBreakShowCount:_stats.shortBreakCount
                                       fullscreen:_settings.miniPauseFullscreen];
                    [self saveSettings];
                }
            }
        } else {
            [self changeState:EBStateSuspended interval:300];
        }
    } break;

    case EBStateWaitingScreen: {
        [self repeatState];
        _fullscreenBlockDuration += msElapsed;
        _timeUntilWaitingWnd += msElapsed;

        if (_timeUntilWaitingWnd >= 1000 * 60 && _fullscreenBlockDuration < 1000 * 60 * 3)
            [d presentWaiting];

        if (_fullscreenBlockDuration >= 1000 * 60 * 5) {
            // The long break waited long enough; cancel it for this cycle.
            [self restartBigPauseInterval];
            [self saveSettings];
        } else if ([d fullscreenDisplay] >= 0) {
            [self changeState:EBStateWaitingScreen interval:3000];
        } else {
            [d dismissWaiting];
            [self changeState:EBStateStartBigPause interval:3000];
        }
    } break;

    case EBStateStartBigPause: {
        int fullscreen = [d fullscreenDisplay];
        if (_settings.strictModeEnabled) {
            if (fullscreen >= 0) {
                [d hideFrontmostApp];
                [self changeState:EBStateStartBigPause interval:2000];
            } else {
                [self startLongBreakWithDemo:NO];
            }
        } else if (fullscreen < 0) {
            [d presentBeforeBreak];
        } else {
            [d presentWaiting];
            _fullscreenBlockDuration = 0;
            _timeUntilWaitingWnd = 0;
            [self changeState:EBStateWaitingScreen interval:1000];
        }
    } break;

    case EBStateAutoRelax: {
        [self repeatState];
        _inactivityTime += msElapsed;
        if (EBIdleSeconds() < 1.0) {
            [d postNotificationKey:@"tb_notification_auto_relax_ended"
                          duration:EBSecondsText((long)_settings.bigPauseInterval * 60, EBRussianNow())];
            [self restartBigPauseInterval];
            [self restartMiniPauseInterval];
        }
    } break;

    case EBStateRelaxing: {
        _relaxingTimeLeft -= msElapsed;
        if (_relaxingTimeLeft < 0) {
            if (_settings.soundsEnabled)
                [d playBreakEndSound];
            [self dismissLongBreak];
            [self saveSettings];
        } else {
            [self repeatState];
        }
    } break;

    case EBStateDestroy: {
        _destroying = YES;
        [d terminateApp];
    } break;

    case EBStateNone:
    default:
        break;
    }
}

#pragma mark - Transitions driven by UI

- (void)startLongBreakWithDemo:(BOOL)demo {
    if ([self.delegate fullscreenDisplay] >= 0) {
        [self.delegate presentWaiting];
        _fullscreenBlockDuration = 0;
        _timeUntilWaitingWnd = 0;
        [self changeState:EBStateWaitingScreen interval:1000];
        return;
    }

    _showedLongBreakCountdown = NO;
    [self.delegate dismissCountdown];
    [self.delegate dismissBeforeBreak];

    BOOL shortDemo = demo && _settings.strictModeEnabled;
    int seconds = shortDemo ? EBDemoBreakSec : _settings.bigPauseDuration * 60;

    _stats.longBreakCount++;
    _relaxingTimeLeft = (long)seconds * 1000;
    [self.delegate presentLongBreakWithSeconds:seconds demo:shortDemo];
    [self changeState:EBStateRelaxing interval:300];
}

- (void)skipBigBreak {
    long fullPeriod = (long)_settings.bigPauseDuration * 1000 * 60;
    long early = fullPeriod / EBEarlySkipFractionDen * EBEarlySkipFractionNum;
    if (_relaxingTimeLeft > early)
        _stats.earlySkipCount++;
    else
        _stats.lateSkipCount++;
    [self dismissLongBreak];
}

- (void)refuseBigPause {
    _stats.refuseCount++;
    [self restartBigPauseInterval];
    [self saveSettings];
}

- (void)postponeBigPause {
    _showedLongBreakCountdown = NO;
    _stats.postponeCount++;
    _postponeCount++;
    _inactivityTime = 0;
    self.timeLeftToBigPause = EBPostponeMs;
    [self changeState:EBStateIdle interval:1000];
    if (self.timeLeftToMiniPause <= 3000)
        self.timeLeftToMiniPause = 3000; // nudge an imminent short break aside
}

- (void)dismissLongBreak {
    [self.delegate dismissLongBreak];
    [self.delegate dismissCountdown];
    [self restartBigPauseInterval];
    [self restartMiniPauseInterval];
    [self saveSettings];
}

- (void)autoRelax {
    _inactivityTime = 0;
    self.timeLeftToBigPause = 0;
    self.timeLeftToMiniPause = 0;
    _stats.autoBreakCount++;
    [self.delegate dismissLongBreak];
    [self.delegate dismissShortBreak];
    [self.delegate dismissCountdown];
    [self.delegate dismissWaiting];
    [self.delegate dismissBeforeBreak];
    [self changeState:EBStateAutoRelax interval:500];
}

- (void)takeLongBreakNow {
    EBState s = _nextState;
    if (s == EBStateIdle || s == EBStateAutoRelax || s == EBStateRelaxing)
        [self startLongBreakWithDemo:NO];
    [self.delegate dismissWaiting];
}

- (void)acceptLongBreak {
    [self.delegate dismissBeforeBreak];
    [self.delegate dismissCountdown];
    [self startLongBreakWithDemo:NO];
}

- (void)startDemoBreak {
    [self startLongBreakWithDemo:YES];
}

- (void)requestPauseForMinutes:(int)minutes {
    EBState s = _nextState;
    if (s == EBStateIdle || s == EBStateNone || s == EBStateWaitingScreen) {
        _inactivityTime = minutes * 1000L * 60;
        [self.delegate dismissCountdown];
        [self.delegate dismissWaiting];
        [self.delegate dismissBeforeBreak];
        [self.delegate dismissLongBreak];
        [self.delegate dismissShortBreak];
        [self changeState:EBStateSuspended interval:300];
    } else if (s == EBStateSuspended) {
        [self resumeFromPause];
    }
}

- (void)resumeFromPause {
    [self restartBigPauseInterval];
    [self restartMiniPauseInterval];
    [self saveSettings];
}

- (NSString *)statusTitleWithLanguage:(NSString *)language {
    BOOL russian = EBRussianLanguage(language);
    if (_nextState == EBStateAutoRelax)
        return NSLocalizedString(@"status.error", @"menu bar tooltip during auto-relax");
    if (_nextState == EBStateSuspended)
        return [NSString stringWithFormat:NSLocalizedString(@"status.paused_fmt", @"paused tooltip"),
                                          EBSecondsText(_inactivityTime / 1000, russian)];
    if (_settings.bigPauseEnabled)
        return [NSString stringWithFormat:NSLocalizedString(@"status.active_fmt", @"active tooltip"),
                                          EBSecondsText(self.timeLeftToBigPause / 1000, russian)];
    return NSLocalizedString(@"status.default", @"menu bar tooltip when breaks are off");
}

@end