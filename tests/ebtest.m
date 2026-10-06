// Unit tests for the ported state machine and time-formatting rules.
//
// The original project ships no tests at all, and the state machine is the part where a
// mistake silently eats the user's breaks, so it is worth pinning down here. These run
// without a window server: ebdetect is replaced by tests/ebdetect_stub.c.
//
//   ./build/ebtest
//
// Localized text itself is not asserted: NSLocalizedString needs a bundle, so only the
// pure logic behind it (plural category, time spec) is checked.

#import <Foundation/Foundation.h>

#import "ebcore.h"
#import "ebgeometry.h"
#import "ebtext.h"

void EBTestSetIdleSeconds(double s);
void EBTestSetFullscreenDisplay(int display);

static int gChecks = 0, gFailures = 0;

static void Check(BOOL cond, NSString *what) {
    gChecks++;
    if (!cond) {
        gFailures++;
        printf("  FAIL  %s\n", what.UTF8String);
    }
}

static void CheckEq(long got, long want, NSString *what) {
    gChecks++;
    if (got != want) {
        gFailures++;
        printf("  FAIL  %s: got %ld, want %ld\n", what.UTF8String, got, want);
    }
}

// ---------------------------------------------------------------------------------------------
// Recorder. Counters are n-prefixed so they can never collide with a delegate method name.

@interface Recorder : NSObject <EBCoreDelegate>
@property(nonatomic) int nDisplayCount;
@property(nonatomic) int nFullscreenDisplay;
@property(nonatomic) int nDisplayCountCalls;
@property(nonatomic) int nHideFrontmostCalls;
@property(nonatomic) int nPresentLongBreak;
@property(nonatomic) int nDismissLongBreak;
@property(nonatomic) int nPresentCountdown;
@property(nonatomic) int nDismissCountdown;
@property(nonatomic) int nPresentBeforeBreak;
@property(nonatomic) int nDismissBeforeBreak;
@property(nonatomic) int nPresentWaiting;
@property(nonatomic) int nDismissWaiting;
@property(nonatomic) int nPresentShortBreak;
@property(nonatomic) int nDismissShortBreak;
@property(nonatomic) int nSoundCount;
@property(nonatomic) int nTerminateCount;
@property(nonatomic) long nLastCountdownMs;
@property(nonatomic) int nLastLongBreakSeconds;
@property(nonatomic) BOOL nLastLongBreakDemo;
@property(nonatomic) unsigned nLastShortBreakCount;
@property(nonatomic) BOOL nLastShortBreakFullscreen;
@property(nonatomic) NSMutableArray<NSString *> *nNotifications;
@end

@implementation Recorder

- (instancetype)init {
    if ((self = [super init])) {
        _nDisplayCount = 1;
        _nFullscreenDisplay = -1;
        _nNotifications = [NSMutableArray array];
    }
    return self;
}

- (int)displayCount {
    _nDisplayCountCalls++;
    return _nDisplayCount;
}

- (int)fullscreenDisplay {
    return _nFullscreenDisplay;
}

- (void)hideFrontmostApp {
    _nHideFrontmostCalls++;
}

- (void)presentLongBreakWithSeconds:(int)seconds demo:(BOOL)demo {
    _nPresentLongBreak++;
    _nLastLongBreakSeconds = seconds;
    _nLastLongBreakDemo = demo;
}

- (void)dismissLongBreak {
    _nDismissLongBreak++;
}

- (void)presentCountdownWithMsLeft:(long)msLeft display:(int)display {
    _nPresentCountdown++;
    _nLastCountdownMs = msLeft;
}

- (void)dismissCountdown {
    _nDismissCountdown++;
}

- (void)presentBeforeBreak {
    _nPresentBeforeBreak++;
}

- (void)dismissBeforeBreak {
    _nDismissBeforeBreak++;
}

- (void)presentWaiting {
    _nPresentWaiting++;
}

- (void)dismissWaiting {
    _nDismissWaiting++;
}

- (void)presentShortBreakShowCount:(unsigned)showCount fullscreen:(BOOL)fullscreen {
    _nPresentShortBreak++;
    _nLastShortBreakCount = showCount;
    _nLastShortBreakFullscreen = fullscreen;
}

- (void)dismissShortBreak {
    _nDismissShortBreak++;
}

- (void)updateStatusTitle:(NSString *)title isPaused:(BOOL)paused {
}

- (void)postNotificationKey:(NSString *)key duration:(NSString *)duration {
    [_nNotifications addObject:key];
}

- (void)playBreakEndSound {
    _nSoundCount++;
}

- (void)terminateApp {
    _nTerminateCount++;
}

@end

// ---------------------------------------------------------------------------------------------


// Ticks the core in `stepMs` increments until `cond` holds. Returns steps taken, or -1 on
// timeout. Hand-counting ticks is what made the first version of these tests wrong.
static long DriveTo(EBCore *core, long (^cond)(void), long maxSteps, long stepMs) {
    for (long i = 0; i < maxSteps; i++) {
        if (cond())
            return i;
        [core tickWithElapsedMs:stepMs];
    }
    return cond() ? maxSteps : -1;
}

static EBCore *MakeCore(Recorder **outRecorder) {
    EBCore *core = [[EBCore alloc] init];
    core.preferencesDomain = @"local.eyeleo.EyeLeoTests";
    Recorder *rec = [[Recorder alloc] init];
    core.delegate = rec;
    EBTestSetIdleSeconds(0.0);
    rec.nFullscreenDisplay = -1;
    if (outRecorder)
        *outRecorder = rec;
    return core;
}

static void TestPlurals(void) {
    printf("plural category\n");
    CheckEq(EBPluralCategory(1, YES), 0, @"ru 1 -> one");
    CheckEq(EBPluralCategory(21, YES), 0, @"ru 21 -> one");
    CheckEq(EBPluralCategory(101, YES), 0, @"ru 101 -> one");
    CheckEq(EBPluralCategory(2, YES), 1, @"ru 2 -> few");
    CheckEq(EBPluralCategory(24, YES), 1, @"ru 24 -> few");
    CheckEq(EBPluralCategory(5, YES), 2, @"ru 5 -> many");
    CheckEq(EBPluralCategory(11, YES), 2, @"ru 11 -> many");
    CheckEq(EBPluralCategory(12, YES), 2, @"ru 12 -> many");
    CheckEq(EBPluralCategory(14, YES), 2, @"ru 14 -> many");
    CheckEq(EBPluralCategory(111, YES), 2, @"ru 111 -> many");
    CheckEq(EBPluralCategory(112, YES), 2, @"ru 112 -> many");
    CheckEq(EBPluralCategory(1, NO), 0, @"en 1 -> one");
    CheckEq(EBPluralCategory(0, NO), 2, @"en 0 -> many");
    CheckEq(EBPluralCategory(2, NO), 2, @"en 2 -> many");
}

static void TestTimeSpec(void) {
    printf("time spec\n");
    long h = 0, m = 0, s = 0;

    Check(EBTimeSpec(45 * 1000, NO, NO, &h, &m, &s) == EBTimeModeClock, @"en 45s -> clock");
    CheckEq(s, 45, @"en 45s seconds");

    Check(EBTimeSpec(5 * 60 * 1000, NO, NO, &h, &m, &s) == EBTimeModeHoursAndMinutes, @"en 5m -> coarse");
    Check(EBTimeSpec(4 * 60 * 1000, NO, NO, &h, &m, &s) == EBTimeModeClock, @"en 4m -> clock");

    Check(EBTimeSpec(90 * 60 * 1000, NO, NO, &h, &m, &s) == EBTimeModeHoursAndMinutes, @"en 1h30 -> coarse");
    CheckEq(h, 1, @"en 1h30 hours");
    CheckEq(m, 30, @"en 1h30 minutes");

    Check(EBTimeSpec(120 * 60 * 1000, NO, YES, &h, &m, &s) == EBTimeModeTooManyHours, @"ru 2h -> too many");
    Check(EBTimeSpec(119 * 60 * 1000, NO, YES, &h, &m, &s) == EBTimeModeHoursAndMinutes, @"ru 1h59 -> coarse");

    Check(EBTimeSpec(3 * 60 * 60 * 1000, YES, YES, &h, &m, &s) == EBTimeModeClock, @"forceSeconds overrides");
    CheckEq(h, 3, @"forceSeconds hours");

    Check(EBTimeSpec(-5000, NO, NO, &h, &m, &s) == EBTimeModeClock, @"negative -> clock");
    CheckEq(s, 0, @"negative clamps to zero");
}

static void TestDefaults(void) {
    printf("defaults\n");
    EBCore *core = [[EBCore alloc] init];
    EBSettings d = core.settings;
    CheckEq(d.bigPauseInterval, 50, @"default big pause interval");
    CheckEq(d.bigPauseDuration, 5, @"default big pause duration");
    CheckEq(d.miniPauseInterval, 10, @"default mini pause interval");
    CheckEq(d.miniPauseDuration, 8, @"default mini pause duration");
    Check(d.bigPauseEnabled && d.miniPauseEnabled, @"both breaks on by default");
    Check(d.inactivityTracking, @"inactivity tracking on by default");
    Check(!d.strictModeEnabled, @"strict mode off by default");
}

static void TestFirstLaunch(void) {
    printf("first launch\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:YES lastShutdown:0];

    Check(core.nextState == EBStateFirstLaunch, @"starts in first launch state");
    [core tickWithElapsedMs:1000];
    CheckEq(rec.nNotifications.count, 1, @"posts exactly one notification");
    Check([rec.nNotifications.firstObject isEqual:@"tb_notification_first_launch"], @"first_launch notification");
    Check(!core.stats.firstLaunch, @"first launch flag cleared");
    Check(core.nextState == EBStateIdle, @"returns to idle");
    CheckEq(core.timeLeftToBigPause, 50LL * 60 * 1000, @"big pause interval armed");
    CheckEq(core.timeLeftToMiniPause, 10LL * 60 * 1000, @"mini pause interval armed");
}

static void TestIdleCountdownToBigBreak(void) {
    printf("idle -> long break\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];

    // The warning window opens at 30s remaining, so step until it appears.
    long steps = DriveTo(core, ^long { return rec.nPresentCountdown > 0; }, 50 * 60, 1000);
    Check(steps >= 0, @"countdown window appeared");
    CheckEq(rec.nPresentCountdown, 1, @"countdown window shown once");
    CheckEq(rec.nLastCountdownMs, 30LL * 1000, @"countdown armed for the warning interval");

    steps = DriveTo(core, ^long { return rec.nPresentBeforeBreak > 0; }, 600, 100);
    Check(steps >= 0, @"before-break dialog appeared");
    CheckEq(rec.nPresentBeforeBreak, 1, @"before-break dialog shown");
    CheckEq(rec.nPresentCountdown, 1, @"countdown not repeated");

    [core refuseBigPause];
    CheckEq(core.stats.refuseCount, 1, @"refusal counted");
    CheckEq(core.timeLeftToBigPause, 50LL * 60 * 1000, @"interval restarted after refusal");
}

static void TestPostponeAndFullLongBreak(void) {
    printf("long break lifecycle\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];

    [core postponeBigPause];
    CheckEq(core.timeLeftToBigPause, 180LL * 1000, @"postpone gives three minutes");
    CheckEq(core.stats.postponeCount, 1, @"postpone counted");

    [core takeLongBreakNow];
    CheckEq(rec.nPresentLongBreak, 1, @"long break presented");
    CheckEq(rec.nLastLongBreakSeconds, 5 * 60, @"long break uses the configured duration");
    Check(!rec.nLastLongBreakDemo, @"menu-triggered break is not a demo");
    CheckEq(core.stats.longBreakCount, 1, @"long break counted");
    Check(core.nextState == EBStateRelaxing, @"entered relaxing");

    int guard = 0;
    while (core.nextState == EBStateRelaxing && guard++ < 5000)
        [core tickWithElapsedMs:300];

    CheckEq(rec.nSoundCount, 1, @"sound played once at the end");
    CheckEq(rec.nDismissLongBreak, 1, @"overlay dismissed");
    Check(core.nextState == EBStateIdle, @"back to idle");
}

static void TestSkipClassification(void) {
    printf("skip classification\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];

    [core takeLongBreakNow];
    [core tickWithElapsedMs:300];
    [core skipBigBreak];
    CheckEq(core.stats.earlySkipCount, 1, @"early skip counted");

    // The early threshold is 35% of 300s = 105s, so 210s of ticking is safely past it.
    [core takeLongBreakNow];
    for (int i = 0; i < 700; i++)
        [core tickWithElapsedMs:300];
    Check(core.nextState == EBStateRelaxing, @"still inside the break when we skip");
    [core skipBigBreak];
    CheckEq(core.stats.lateSkipCount, 1, @"late skip counted");
    CheckEq(core.stats.earlySkipCount, 1, @"early skip not double counted");
}

static void TestShortBreak(void) {
    printf("short break\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];

    for (int i = 0; i < 10 * 60; i++)
        [core tickWithElapsedMs:1000];

    CheckEq(rec.nPresentShortBreak, 1, @"short break shown");
    CheckEq(rec.nLastShortBreakCount, 1, @"short break counter is 1 on the first one");
    Check(!rec.nLastShortBreakFullscreen, @"short break honours the non-fullscreen default");

    for (int i = 0; i < 10 * 60 + 5; i++)
        [core tickWithElapsedMs:1000];
    CheckEq(rec.nPresentShortBreak, 2, @"short break repeats on its own interval");
    CheckEq(rec.nLastShortBreakCount, 2, @"short break counter advances");
}

static void TestPauseAndResume(void) {
    printf("pause and resume\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];

    [core requestPauseForMinutes:60];
    Check(core.paused, @"entered paused state");

    int guard = 0;
    while (core.paused && guard++ < 20000)
        [core tickWithElapsedMs:300];
    Check(!core.paused, @"resumed after an hour");
    Check([rec.nNotifications containsObject:@"tb_notification_start_after_pause"], @"resumption notified");

    [core requestPauseForMinutes:60];
    Check(core.paused, @"pause requested again");
    [core resumeFromPause];
    Check(!core.paused, @"manual resume works");
}

static void TestAutoRelax(void) {
    printf("auto relax\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];

    EBTestSetIdleSeconds(600);
    for (int i = 0; i < 9 * 60; i++)
        [core tickWithElapsedMs:1000];

    CheckEq(core.stats.autoBreakCount, 1, @"auto relax triggered");
    Check(core.nextState == EBStateAutoRelax, @"entered auto relax");

    EBTestSetIdleSeconds(0.0);
    [core tickWithElapsedMs:500];
    Check(core.nextState == EBStateIdle, @"auto relax ends on activity");
    Check([rec.nNotifications containsObject:@"tb_notification_auto_relax_ended"], @"auto relax end notified");
}

static void TestFullscreenBlocking(void) {
    printf("fullscreen handling\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];
    rec.nDisplayCount = 2;

    rec.nFullscreenDisplay = 1;
    long steps = DriveTo(core, ^long { return core.nextState == EBStateStartBigPause; }, 60 * 60, 1000);
    Check(steps >= 0, @"reached the long break decision point");
    [core tickWithElapsedMs:100];
    CheckEq(rec.nPresentBeforeBreak, 0, @"before-break suppressed by fullscreen");
    CheckEq(rec.nPresentWaiting, 1, @"waiting overlay shown instead");
    Check(core.nextState == EBStateWaitingScreen, @"entered waiting state");

    rec.nFullscreenDisplay = -1;
    [core tickWithElapsedMs:3000];
    Check(core.nextState == EBStateStartBigPause, @"waiting resolved into the break");
    [core tickWithElapsedMs:100];
    CheckEq(rec.nPresentBeforeBreak, 1, @"before-break shown after fullscreen cleared");

    // Strict mode instead pushes the blocking app away and retries.
    EBSettings strict = core.settings;
    strict.strictModeEnabled = YES;
    core.settings = strict;
    [core refuseBigPause]; // back to a clean idle interval
    rec.nFullscreenDisplay = 0;
    int before = rec.nHideFrontmostCalls;
    DriveTo(core, ^long { return core.nextState == EBStateStartBigPause; }, 60 * 60, 1000);
    [core tickWithElapsedMs:100];
    CheckEq(rec.nHideFrontmostCalls, before + 1, @"strict mode hides the blocking app");
}

static void TestWaitingGivesUp(void) {
    printf("waiting gives up\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];
    rec.nDisplayCount = 1;

    rec.nFullscreenDisplay = 0;
    DriveTo(core, ^long { return core.nextState == EBStateStartBigPause; }, 60 * 60, 1000);
    [core tickWithElapsedMs:100];
    Check(core.nextState == EBStateWaitingScreen, @"entered waiting");

    DriveTo(core, ^long { return core.nextState != EBStateWaitingScreen; }, 10 * 60, 1000);

    Check(core.nextState == EBStateIdle, @"cancelled and back to idle");
    CheckEq(core.timeLeftToBigPause, 50LL * 60 * 1000, @"interval restarted after giving up");
}

static void TestBothBreaksDisabled(void) {
    printf("both breaks disabled\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];
    EBSettings off = core.settings;
    off.bigPauseEnabled = NO;
    off.miniPauseEnabled = NO;
    core.settings = off;
    [core tickWithElapsedMs:1000];
    Check(core.nextState == EBStateSuspended, @"suspends when nothing is scheduled");
}

static void TestCountdownAvoidsFullscreenDisplay(void) {
    printf("countdown display choice\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];
    rec.nDisplayCount = 2;

    rec.nFullscreenDisplay = 0;
    long steps = DriveTo(core, ^long { return rec.nPresentCountdown > 0; }, 50 * 60, 1000);
    Check(steps >= 0, @"countdown appeared");
    CheckEq(rec.nPresentCountdown, 1, @"countdown shown on the free display");
    CheckEq(core.timeLeftToBigPause, 30LL * 1000, @"countdown re-arms the timer");
}

static void TestResumeAcrossRestart(void) {
    printf("resume across restart\n");
    NSString *domain = @"local.eyeleo.EyeLeoTestsResume";

    EBCore *seed = [[EBCore alloc] init];
    seed.preferencesDomain = domain;
    Recorder *seedRec = [[Recorder alloc] init];
    seed.delegate = seedRec;
    seedRec.nFullscreenDisplay = -1;
    EBTestSetIdleSeconds(0.0);
    [seed startWithFirstLaunch:NO lastShutdown:0];

    // Wind the live countdown down to nine minutes, then persist. saveSettings always records
    // the live timers, so the test cannot simply assign the stored value.
    for (int i = 0; i < 41 * 60; i++)
        [seed tickWithElapsedMs:1000];
    CheckEq(seed.timeLeftToBigPause, 9LL * 60 * 1000, @"seed countdown is nine minutes");

    EBStats seeded = seed.stats;
    seeded.lastShutdown = [[NSDate date] timeIntervalSince1970] - 60; // quit one minute ago
    seed.stats = seeded;
    [seed saveSettings];

    EBCore *core = [[EBCore alloc] init];
    core.preferencesDomain = domain;
    Check([core loadSettings], @"settings reloaded from storage");
    CheckEq(core.stats.longBreakCount, 0, @"stats round-trip");

    [core startWithFirstLaunch:NO lastShutdown:core.stats.lastShutdown];
    long left = core.timeLeftToBigPause;
    Check(left > 450000 && left <= 480000, @"countdown resumed at about eight minutes");

    // A long absence must restart everything instead.
    [core startWithFirstLaunch:NO lastShutdown:[[NSDate date] timeIntervalSince1970] - 3600];
    CheckEq(core.timeLeftToBigPause, 50LL * 60 * 1000, @"long absence restarts the interval");
}

static void TestPersistRoundTrip(void) {
    printf("settings round-trip\n");
    NSString *domain = @"local.eyeleo.EyeLeoTestsRoundTrip";

    EBCore *core = [[EBCore alloc] init];
    core.preferencesDomain = domain;
    EBSettings s = core.settings;
    s.bigPauseInterval = 37;
    s.bigPauseDuration = 11;
    s.miniPauseInterval = 7;
    s.miniPauseDuration = 3;
    s.warningInterval = 1.5;
    s.strictModeEnabled = YES;
    s.windowNearby = NO;
    s.canCloseNotifications = YES;
    s.showNotifications = NO;
    s.miniPauseFullscreen = YES;
    core.settings = s;
    EBStats seededStats = core.stats;
    seededStats.longBreakCount = 12;
    seededStats.shortBreakCount = 34;
    core.stats = seededStats;
    [core saveSettings];

    EBCore *reloaded = [[EBCore alloc] init];
    reloaded.preferencesDomain = domain;
    Check([reloaded loadSettings], @"reload succeeded");
    CheckEq(reloaded.settings.bigPauseInterval, 37, @"big pause interval persisted");
    CheckEq((long)(reloaded.settings.warningInterval * 2), 3, @"warning interval persisted as a fraction");
    Check(reloaded.settings.strictModeEnabled, @"strict mode persisted");
    Check(!reloaded.settings.windowNearby, @"window nearby persisted");
    Check(reloaded.settings.canCloseNotifications, @"closeable notifications persisted");
    Check(!reloaded.settings.showNotifications, @"show notifications persisted");
    Check(reloaded.settings.miniPauseFullscreen, @"mini pause fullscreen persisted");
    CheckEq(reloaded.stats.longBreakCount, 12, @"long break count persisted");
    CheckEq(reloaded.stats.shortBreakCount, 34, @"short break count persisted");
}

static void TestOverLimitSettingsClampedOnSave(void) {
    printf("over-limit settings clamped\n");
    EBCore *core = [[EBCore alloc] init];
    core.preferencesDomain = @"local.eyeleo.EyeLeoTestsClamp";
    EBSettings s = core.settings;
    s.bigPauseInterval = 500;
    s.bigPauseDuration = 90;
    s.miniPauseDuration = 99;
    s.warningInterval = 12;
    core.settings = s;
    [core saveSettings];
    CheckEq(core.settings.bigPauseInterval, EBBigPauseIntervalMaxMin, @"interval clamped");
    CheckEq(core.settings.bigPauseDuration, EBBigPauseDurationMaxMin, @"duration clamped");
    CheckEq(core.settings.miniPauseDuration, EBMiniPauseDurationMaxMin, @"mini duration clamped");
    Check(core.settings.warningInterval <= EBWarningIntervalMaxMin, @"warning interval clamped");
}

static void TestDemoBreakLength(void) {
    printf("demo break\n");
    Recorder *rec;
    EBCore *core = MakeCore(&rec);
    [core startWithFirstLaunch:NO lastShutdown:0];

    // Strict mode on: the demo collapses to five seconds, which is the original's rule
    // (main.cpp:776, `demo && _enableStrictMode`).
    EBSettings strict = core.settings;
    strict.strictModeEnabled = YES;
    core.settings = strict;
    [core startDemoBreak];
    CheckEq(rec.nPresentLongBreak, 1, @"demo break shown");
    CheckEq(rec.nLastLongBreakSeconds, EBDemoBreakSec, @"strict demo lasts five seconds");
    Check(rec.nLastLongBreakDemo, @"flagged as a demo");

    DriveTo(core, ^long { return core.nextState != EBStateRelaxing; }, 200, 300);
    CheckEq(rec.nDismissLongBreak, 1, @"demo break ends on its own");

    // Strict mode off: preserved behaviour is a full-length break, so the user sees the real thing.
    EBSettings loose = core.settings;
    loose.strictModeEnabled = NO;
    core.settings = loose;
    rec.nPresentLongBreak = 0;
    [core startDemoBreak];
    CheckEq(rec.nLastLongBreakSeconds, 5 * 60, @"non-strict demo keeps the full duration");
}

static void TestWarningInterval(void) {
    printf("warning interval bounds\n");
    // The notice needs room to count down before the dialog opens, so its floor is the shortest
    // delay the settings popup offers, 20s.
    Check(EBWarningIntervalMinMin * 60 * 1000 > EBLongBreakConfirmationSec * 1000,
          @"warning floor leaves room for the confirmation countdown");
    Check(EBWarningIntervalMinMin * 60 == 20, @"warning floor is 20 seconds");
}

static void TestGeometry(void) {
    printf("overlay geometry\n");

    // Realistic displays, work area (visibleFrame) roughly as macOS reports it.
    struct { const char *name; CGFloat w, h, menu, dock; } screens[] = {
        { "MacBook Air 14 built-in", 1512, 982, 24, 70 },
        { "MacBook Air 13 built-in", 1440, 900, 24, 0 },
        { "scaled down 1280x800", 1280, 800, 24, 0 },
        { "Studio Display 5K", 5120, 2880, 24, 0 },
        { "absurdly small 800x600", 800, 600, 24, 0 },
    };

    NSSize panel = NSMakeSize(461, 156);
    for (unsigned i = 0; i < sizeof(screens) / sizeof(screens[0]); i++) {
        NSRect frame = NSMakeRect(0, 0, screens[i].w, screens[i].h);
        NSRect work = NSInsetRect(frame, 0, 0);
        work.size.height -= screens[i].menu + screens[i].dock;

        NSSize fitted = EBFittedSize(panel, work);
        Check(fitted.width <= NSWidth(work) && fitted.height <= NSHeight(work),
              [NSString stringWithFormat:@"%@: panel fits the work area", @(screens[i].name)]);

        NSRect centred = EBCenteredRect(fitted, work);
        Check(NSMinX(centred) >= NSMinX(work) && NSMaxX(centred) <= NSMaxX(work),
              [NSString stringWithFormat:@"%@: panel stays inside horizontally", @(screens[i].name)]);
        Check(NSMinY(centred) >= NSMinY(work) && NSMaxY(centred) <= NSMaxY(work),
              [NSString stringWithFormat:@"%@: panel clears the Dock and the menu bar", @(screens[i].name)]);

        // Centring must land in the middle of the work area, not the middle of the display.
        CGFloat midX = NSMinX(work) + NSWidth(work) / 2.0;
        Check(fabs(NSMidX(centred) - midX) < 1.0,
              [NSString stringWithFormat:@"%@: horizontally centred on the work area", @(screens[i].name)]);
    }

    // Two displays side by side with different sizes: each overlay must land on its own screen.
    NSRect left = NSMakeRect(0, 0, 1512, 982);
    NSRect right = NSMakeRect(1512, 0, 2560, 1440);
    Check(NSMaxX(left) == NSMinX(right), @"displays are adjacent");
    NSRect onLeft = EBCenteredRect(panel, left);
    NSRect onRight = EBCenteredRect(panel, right);
    Check(fabs(NSMidX(onLeft) - NSMidX(left)) < 1.0, @"left display: panel centred on the left screen");
    Check(fabs(NSMidX(onRight) - NSMidX(right)) < 1.0, @"right display: panel centred on the right screen");
    Check(NSMaxX(onLeft) <= NSMinX(right), @"left display: panel does not spill onto the right screen");
    Check(NSMinX(onRight) >= NSMaxX(left), @"right display: panel does not spill onto the left screen");

    // Corner placement, used by the countdown and notification bubbles.
    NSRect work = NSMakeRect(0, 0, 1512, 982 - 94);
    NSRect corner = EBBottomRightRect(NSMakeSize(209, 71), work, 0);
    Check(NSMaxX(corner) <= NSMaxX(work), @"bubble stays inside the work area on the right");
    Check(NSMinY(corner) >= NSMinY(work), @"bubble stays inside the work area at the bottom");
    // Sitting just above the Dock means the bubble's bottom edge is the bottom of the work area,
    // not that its coordinate equals the work area's height.
    Check(fabs(NSMinY(corner) - NSMinY(work)) < 0.5, @"bubble sits just above the Dock");
    Check(fabs(NSMaxX(corner) - NSMaxX(work)) < 0.5, @"bubble is flush with the right edge of the work area");

    // Degenerate input must not produce a zero or negative size.
    NSSize degenerate = EBFittedSize(panel, NSMakeRect(0, 0, 0, 0));
    Check(degenerate.width >= 1 && degenerate.height >= 1, @"degenerate work area clamps to 1x1");

    // A negative-origin display (some external monitors report this) must still centre correctly.
    NSRect offset = NSMakeRect(-2560, -300, 2560, 1440);
    NSRect onOffset = EBCenteredRect(panel, offset);
    Check(NSMinX(onOffset) >= NSMinX(offset) && NSMaxX(onOffset) <= NSMaxX(offset),
          @"overlay stays on a display with a negative origin");
}

int main(void) {
    @autoreleasepool {
        printf("EyeLeo macOS core tests\n\n");
        TestWarningInterval();
        TestGeometry();
        TestPlurals();
        TestTimeSpec();
        TestDefaults();
        TestFirstLaunch();
        TestIdleCountdownToBigBreak();
        TestPostponeAndFullLongBreak();
        TestSkipClassification();
        TestShortBreak();
        TestPauseAndResume();
        TestAutoRelax();
        TestFullscreenBlocking();
        TestWaitingGivesUp();
        TestBothBreaksDisabled();
        TestCountdownAvoidsFullscreenDisplay();
        TestResumeAcrossRestart();
        TestPersistRoundTrip();
        TestOverLimitSettingsClampedOnSave();
        TestDemoBreakLength();

        printf("\n%d checks, %d failures\n", gChecks, gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}