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
#import <AppKit/AppKit.h>

#import "ebcore.h"
#import "ebgeometry.h"
#import "ebtext.h"
#import "ebassets.h"
#import "ebexercise.h"
#import "ebtea.h"

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

// NSBitmapImageRep has no constructor that takes a path, and NSImage would add a resolution and an
// orientation that say nothing about the file. Read the bytes and let the rep parse them.
static NSBitmapImageRep *RepFromPath(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? [[NSBitmapImageRep alloc] initWithData:d] : nil;
}

static void Checkf(BOOL cond, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void Checkf(BOOL cond, NSString *fmt, ...) {
    gChecks++;
    if (cond)
        return;
    gFailures++;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("  FAIL  %s\n", msg.UTF8String);
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
@property(nonatomic) int nPresentWater;
@property(nonatomic) int nLastWaterMl;
@property(nonatomic) int nLastWaterSec;
// Set by the test to simulate the long-break countdown owning the bottom-right corner.
@property(nonatomic) BOOL waterDeferred;
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

- (void)presentWaterReminderWithVolumeMl:(int)ml seconds:(int)seconds {
    _nPresentWater++;
    _nLastWaterMl = ml;
    _nLastWaterSec = seconds;
}

- (BOOL)waterReminderDeferred {
    return _waterDeferred;
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
    // The hydration reminder counts as scheduled work: it has its own checkbox, so leaving it on means
    // the user asked for something to keep happening. Covered separately in the reminder test.
    off.waterReminderEnabled = NO;
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

// A plist written by any tool that understands the format stores <true/>/<false/>, which is a
// CFBoolean and not a CFNumber. Reading only CFNumber made every such value look absent and fall back
// to the default, so a checkbox turned off in the file sprang back on in the app.
static void TestBooleansFromAnyPlistWriter(void) {
    printf("booleans written as true/false\n");
    NSString *domain = @"local.eyeleo.EyeLeoTestsBooleans";
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Library/Preferences/%@.plist", domain]];

    NSDictionary *stored = @{
        @"eyeleo": @{
            @"sounds": @{ @"enabled": @NO },
            @"strict_mode": @{ @"enabled": @YES },
            // A number where the app writes a number, to prove both encodings work side by side.
            @"mini_pause_fullscreen": @{ @"enabled": @0 },
            @"window_nearby": @{ @"enabled": @1 },
        }
    };
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:stored
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:NULL];
    [xml writeToFile:path atomically:YES];

    // CFPreferences caches per domain, so the freshly written file has to be registered with it
    // rather than merely sitting on disk.
    CFPreferencesSetAppValue((__bridge CFStringRef)@"eyeleo",
                             (__bridge CFPropertyListRef)stored[ @"eyeleo" ],
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);

    EBCore *core = [[EBCore alloc] init];
    core.preferencesDomain = domain;
    Check([core loadSettings], @"loaded a plist written by another writer");
    Check(!core.settings.soundsEnabled, @"a false written as <false/> reads as false, not the default true");
    Check(core.settings.strictModeEnabled, @"a true written as <true/> reads as true");
    Check(!core.settings.miniPauseFullscreen, @"a 0 still reads as false");
    Check(core.settings.windowNearby, @"a 1 still reads as true");
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
    s.waterReminderEnabled = NO;
    s.waterIntervalMin = 45;
    s.waterVolumeMl = 150;
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
    Check(!reloaded.settings.waterReminderEnabled, @"water reminder persisted as off");
    CheckEq(reloaded.settings.waterIntervalMin, 45, @"water interval persisted");
    CheckEq(reloaded.settings.waterVolumeMl, 150, @"water portion persisted");
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

static void TestPersonageFramesAndExercises(void) {
    printf("personage frames and exercises\n");
    // The name array in ebassets.m is indexed by the raw enum value and sized by this constant, so if the
    // two ever disagree a frame loads the wrong picture. The test binary runs outside the bundle, so
    // mainBundle cannot find the artwork; check the files in the source tree instead, which is the same
    // list that ships. Anything missing here would load as nil in the app and leave the exercise showing
    // nothing at all.
    Check(EBNumPersonageFrames == 17, @"seventeen personage frames");
    Check(EBNumExercises == 10, @"ten exercises");
    NSString *root = [@(__FILE__) stringByDeletingLastPathComponent];
    root = [root stringByDeletingLastPathComponent]; // tests/ -> project root
    static NSString *const kExpected[17] = {
        @"leopard_default", @"leopard_look_left", @"leopard_look_right", @"leopard_look_up",
        @"leopard_look_down", @"leopard_blink", @"leopard_close_tightly", @"leopard_shoulders_up",
        @"leopard_shoulders_down", @"leopard_stretch_neutral", @"leopard_stretch_left",
        @"leopard_stretch_right", @"leopard_stretch_up_neutral", @"leopard_stretch_up",
        @"leopard_stretch_upper", @"leopard_eyes_open", @"leopard_eyes_closed",
    };
    for (int f = 0; f < EBNumPersonageFrames; f++) {
        NSString *path = [root stringByAppendingPathComponent:
                                       [@"Resources/Personages" stringByAppendingPathComponent:
                                                      [kExpected[f] stringByAppendingPathExtension:@"png"]]];
        Checkf([[NSFileManager defaultManager] fileExistsAtPath:path], @"personage frame %d (%@) exists", f,
               kExpected[f]);
    }

    // Every frame an exercise cycles through has to be the same pixel size, and the frame it opens on
    // has to come from that same cycle. The short break sizes its picture view once, from the frame the
    // animation starts on, and afterwards swaps only the image, so a cycle that opened on a picture of
    // a different size left its later frames drawn into the wrong box. This is not hypothetical: that
    // is exactly what the shoulders exercise did when it was first added, since it had no case in the
    // animation's initialiser and fell through to the painted head before swapping to the real frames.
    // Reading the sizes off the shipped files for the same reason as the existence check above.
    NSString *personages = [root stringByAppendingPathComponent:@"Resources/Personages"];
    for (int e = 1; e <= EBNumExercises; e++) {
        EBExercise exercise = (EBExercise)e;
        NSUInteger count = EBExerciseFrameCount(exercise);
        if (exercise == EBExerciseWindow)
            Checkf(count == 0, @"exercise %d looks out of the window and animates no artwork", e);
        for (NSUInteger i = 0; i < count; i++) {
            EBPersonageFrame frame = EBExerciseFrameAt(exercise, i);
            EBPersonageFrame first = EBExerciseFrameAt(exercise, 0);
            Checkf(frame >= 0 && frame < EBNumPersonageFrames && first >= 0 && first < EBNumPersonageFrames,
                   @"exercise %d frame %lu indexes a real frame", e, (unsigned long)i);
            if (frame < 0 || frame >= EBNumPersonageFrames || first < 0 || first >= EBNumPersonageFrames)
                continue;
            NSBitmapImageRep *rep = RepFromPath([personages stringByAppendingPathComponent:
                                                               [kExpected[frame] stringByAppendingPathExtension:
                                                                            @"png"]]);
            NSBitmapImageRep *firstRep = RepFromPath([personages stringByAppendingPathComponent:
                                                                  [kExpected[first] stringByAppendingPathExtension:
                                                                           @"png"]]);
            Checkf(rep && firstRep, @"exercise %d frame %lu (%@) decodes", e, (unsigned long)i, kExpected[frame]);
            if (rep && firstRep)
                Checkf(rep.pixelsWide == firstRep.pixelsWide && rep.pixelsHigh == firstRep.pixelsHigh,
                       @"exercise %d frame %lu (%@) matches its opening frame %@ in size (%ldx%ld vs %ldx%ld)",
                       e, (unsigned long)i, kExpected[frame], kExpected[first], (long)rep.pixelsWide,
                       (long)rep.pixelsHigh, (long)firstRep.pixelsWide, (long)firstRep.pixelsHigh);
        }
    }

    // A generated frame must carry real transparency, or it would show as a magenta rectangle over the
    // dimmed desktop.
    for (int f = 7; f < EBNumPersonageFrames; f++) {
        NSString *path = [root stringByAppendingPathComponent:
                                       [@"Resources/Personages" stringByAppendingPathComponent:
                                                      [kExpected[f] stringByAppendingPathExtension:@"png"]]];
        NSBitmapImageRep *r = RepFromPath(path);
        Checkf(r && r.hasAlpha, @"frame %@ carries an alpha channel", kExpected[f]);
    }

    // Every exercise has to have text in every language, and the count has to be contiguous from 1:
    // lineCountFor walks up until the first gap, so a missing line 3 would silently shorten the set.
    // Read the .strings files rather than going through NSLocalizedString: the test binary is not the
    // bundle, so lookups there find nothing and every exercise would appear to have no text at all.
    for (NSString *lang in @[ @"en", @"ru" ]) {
        NSString *path = [root stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"%@.lproj/Localizable.strings", lang]];
        NSString *body = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        Checkf(body.length > 0, @"%@.strings readable", lang);
        if (!body.length)
            continue;
        for (int e = 1; e <= EBNumExercises; e++) {
            for (int i = 1; i <= 5; i++) {
                NSString *key = [NSString stringWithFormat:@"\"mini_pause_text_%d_%d\"", e, i];
                Checkf([body rangeOfString:key].location != NSNotFound, @"%@ has %@", lang, key);
            }
            // Line 6 must not exist: the counter would then report six phrasings.
            NSString *key6 = [NSString stringWithFormat:@"\"mini_pause_text_%d_6\"", e];
            Checkf([body rangeOfString:key6].location == NSNotFound, @"%@ stops before %@", lang, key6);
        }
    }
}

// The frame cycling itself is exercised here rather than in the bundle either: EBExerciseAnimation
// reaches for its artwork through mainBundle, which is the wrong bundle when the tests run. So the
// animation object is checked for behaviour that does not depend on the image, and the artwork it
// would ask for is checked by name above.
static void TestDrinkVessels(void) {
    printf("drink vessels\n");
    // Seven vessels, one per drink. A missing file would leave the reminder with an empty gap where the
    // glass goes, and the tea types would all look the same, so check the files the way the frames were
    // checked: in the source tree, because the test binary is not the bundle.
    Check(EBNumDrinks == 8, @"eight drinks");
    NSString *root = [@(__FILE__) stringByDeletingLastPathComponent];
    root = [root stringByDeletingLastPathComponent];
    static NSString *const kDrinks[8] = { @"tea_green", @"tea_white", @"tea_oolong", @"tea_black",
                                          @"tea_red", @"tea_puer", @"tea_herbal", @"tea_water" };
    for (int i = 0; i < EBNumDrinks; i++) {
        NSString *path = [root stringByAppendingPathComponent:
                                       [@"Resources" stringByAppendingPathComponent:
                                          [kDrinks[i] stringByAppendingPathExtension:@"png"]]];
        Checkf([[NSFileManager defaultManager] fileExistsAtPath:path], @"%@ exists", kDrinks[i]);
        NSBitmapImageRep *r = RepFromPath(path);
        Checkf(r != nil, @"%@ decodes", kDrinks[i]);
        if (r)
            Checkf(r.hasAlpha, @"%@ carries an alpha channel", kDrinks[i]);
    }
    // Each vessel has to fit the 71x44 pt slot, or it would overlap the text column in the bubble. The
    // stored bitmaps are twice that.
    for (int i = 0; i < EBNumDrinks; i++) {
        NSString *path = [root stringByAppendingPathComponent:
                                       [@"Resources" stringByAppendingPathComponent:
                                          [kDrinks[i] stringByAppendingPathExtension:@"png"]]];
        NSBitmapImageRep *r = RepFromPath(path);
        if (!r)
            continue;
        Checkf(r.pixelsWide <= 142 && r.pixelsHigh <= 88, @"%@ fits the 142x88 slot (%ldx%ld)", kDrinks[i],
               (long)r.pixelsWide, (long)r.pixelsHigh);
    }
    // Out of range values have to come back nil rather than the wrong vessel: drinkImage: indexes its
    // array with the raw value.
    Check([EBAssets.shared drinkImage:EBDrinkNone] == nil, @"no glass for the empty kind");
    Check([EBAssets.shared drinkImage:(EBDrinkKind)EBNumDrinks] == nil, @"no glass past the last kind");
    Check([EBAssets.shared drinkImage:(EBDrinkKind)99] == nil, @"no glass for a nonsense kind");
}

static void TestAnimationCadence(void) {
    printf("animation cadence\n");
    // Every animated exercise must actually advance. "Look at the window" is the one the original
    // deliberately never animated, so it is the only one allowed to sit still.
    static const int kAnimating[] = { 1, 2, 3, 4, 5, 7, 8, 9, 10 };
    for (size_t i = 0; i < sizeof(kAnimating) / sizeof(kAnimating[0]); i++) {
        EBExerciseAnimation *a = [[EBExerciseAnimation alloc] initWithExercise:(EBExercise)kAnimating[i]];
        CATransform3D before = a.transform;
        for (int t = 0; t < 40; t++)
            [a advance];
        CATransform3D after = a.transform;
        // Identity either way: every exercise swaps artwork now, so nothing moves.
        Checkf(before.m11 == 1.0f && before.m22 == 1.0f && before.m42 == 0.0f,
               @"exercise %d starts on an identity transform", kAnimating[i]);
        Checkf(after.m11 == 1.0f && after.m22 == 1.0f && after.m42 == 0.0f,
               @"exercise %d keeps an identity transform", kAnimating[i]);
    }
    // Exercise 6 looks out of the window and is meant to hold still.
    EBExerciseAnimation *window = [[EBExerciseAnimation alloc] initWithExercise:EBExerciseWindow];
    for (int t = 0; t < 40; t++)
        [window advance];
    Check(window.transform.m11 == 1.0f, @"window exercise holds still");
}

static void TestTeaConfigAndSession(void) {
    printf("tea config and session\n");
    // With no tea.conf on disk the built-in schedule has to be returned rather than an empty set, since a
    // fresh install has nothing configured and the feature still has to work.
    EBTeaConfig cfg = EBLoadTeaConfig();
    Check(cfg.count >= 7, @"defaults cover the seven teas");

    // The defaults are the researched ones, so check a couple of them rather than only that something
    // parsed: the point of the table is that the numbers were looked up.
    int green = (int)EBDrinkGreen - 1;
    Check(cfg.schemes[green].count == 6, @"green tea has six steeps");
    CheckEq(cfg.schemes[green].seconds[0], 10, @"first green steep is 10 s");
    CheckEq(cfg.schemes[green].seconds[5], 35, @"last green steep is 35 s");
    int puer = (int)EBDrinkPuer - 1;
    Check(cfg.schemes[puer].count == 8, @"pu-erh has eight steeps");
    CheckEq(cfg.schemes[puer].seconds[7], 90, @"last pu-erh steep is 90 s");
    int herbal = (int)EBDrinkHerbal - 1;
    CheckEq(cfg.schemes[herbal].seconds[0], 300, @"herbal first steep is 300 s");
    int red = (int)EBDrinkRed - 1;
    Check(cfg.schemes[red].count == 6, @"red tea has six steeps");
    CheckEq(cfg.schemes[red].temperatureC, 95, @"red tea is 95 C");
    CheckEq(cfg.schemes[red].seconds[0], 7, @"first red steep is 7 s");
    CheckEq(cfg.schemes[red].seconds[5], 30, @"last red steep is 30 s");

    // Water has no steeping schedule, so there is nothing to brew.
    Check(cfg.schemes[(int)EBDrinkWater - 1].seconds == NULL, @"water has no schedule");

    EBTeaSession s;
    EBTeaSessionStart(&s, &cfg, EBDrinkGreen);
    Check(EBTeaSessionValid(&s), @"session started");
    CheckEq(s.steep, 0, @"starts on the first steep");
    CheckEq(s.msLeft, 10000, @"first steep is 10 s");
    CheckEq(s.count, 6, @"session knows the steep count");
    Check(!s.awaiting, @"not waiting before the first steep runs out");
    Check(!s.finished, @"not finished at the start");

    // A tick must not move the step on. Brewing is paced by whoever is pouring, and the earlier version
    // ran all six in a row unattended.
    Check(!EBTeaSessionAdvance(&s, 9000), @"still steeping before the time is up");
    CheckEq(s.msLeft, 1000, @"time counted down");
    Check(EBTeaSessionAdvance(&s, 2000), @"steep runs out on time");
    CheckEq(s.steep, 0, @"step does not advance on its own");
    Check(s.awaiting, @"waits for the next pour");
    CheckEq(s.msLeft, 0, @"timer rests at zero");

    // Time going by while waiting changes nothing at all.
    for (int i = 0; i < 50; i++)
        EBTeaSessionAdvance(&s, 1000);
    CheckEq(s.steep, 0, @"still on the first steep after waiting");
    Check(s.awaiting, @"still waiting");

    // Pouring mid-steep is refused, so a running timer is never thrown away.
    EBTeaSession mid;
    EBTeaSessionStart(&mid, &cfg, EBDrinkGreen);
    Check(!EBTeaSessionPour(&mid, &cfg), @"cannot pour while a steep is running");
    CheckEq(mid.steep, 0, @"still on the first steep after a refused pour");

    // Pouring on request moves the step and sets the next time.
    Check(EBTeaSessionPour(&s, &cfg), @"pour starts the next steep");
    CheckEq(s.steep, 1, @"moved to the second steep");
    CheckEq(s.msLeft, 15000, @"second steep is 15 s");
    Check(!s.awaiting, @"no longer waiting");
    Check(!s.finished, @"session continues");
    CheckEq(EBTeaSessionNextSeconds(&cfg, &s), 0, @"no next steep to report yet");

    // The full schedule, one steep per Pour, and the session ends by itself once the last steep runs out.
    // It used to need one more press to finish, which left a bubble on screen waiting for a pour that had
    // nothing to start.
    // Counted on a fresh session so the number of presses is unambiguous.
    EBTeaSession whole;
    EBTeaSessionStart(&whole, &cfg, EBDrinkGreen);
    int guard = 0;
    int pours = 0;
    while (!whole.finished && guard++ < 1000) {
        EBTeaSessionAdvance(&whole, 1000);
        if (whole.awaiting && EBTeaSessionPour(&whole, &cfg))
            pours++;
    }
    Check(whole.finished, @"a whole session finishes on its own");
    // Six steeps, so five presses: the last one runs out by itself rather than being poured.
    CheckEq(pours, 5, @"one press per steep except the last");

    // Carry on the session under test from wherever it is now.
    while (!s.finished && guard++ < 2000) {
        EBTeaSessionAdvance(&s, 1000);
        if (s.awaiting)
            EBTeaSessionPour(&s, &cfg);
    }
    Check(s.finished, @"session finishes on its own");
    CheckEq(s.steep, 5, @"stopped on the last steep");
    Check(!s.awaiting, @"nothing left to pour");

    // The moment the last steep runs out is the moment the session closes, with no press at all.
    EBTeaSession tail;
    EBTeaSessionStart(&tail, &cfg, EBDrinkGreen);
    for (int i = 0; i < 5; i++) {
        while (!tail.awaiting && !tail.finished)
            EBTeaSessionAdvance(&tail, 1000);
        EBTeaSessionPour(&tail, &cfg);
    }
    CheckEq(tail.steep, 5, @"on the final steep");
    Check(!tail.finished, @"not finished while the final steep runs");
    while (!tail.finished)
        EBTeaSessionAdvance(&tail, 1000);
    Check(tail.finished, @"the final steep finishing closes the session by itself");
    Check(!EBTeaSessionPour(&tail, &cfg), @"nothing to pour once it has closed");
    Check([EBTeaSessionCaption(&cfg, &tail, NO).lowercaseString containsString:@"ready"],
          @"and it reads as ready");

    // Pours past the end do nothing.
    Check(!EBTeaSessionPour(&s, &cfg), @"cannot pour a finished session");
    EBTeaSessionAdvance(&s, 5000);
    Check(s.finished, @"stays finished");

    // The wording has to follow the state, so the number on screen never claims a step that has not begun.
    EBTeaSession fresh;
    EBTeaSessionStart(&fresh, &cfg, EBDrinkGreen);
    NSString *first = EBTeaSessionCaption(&cfg, &fresh, NO);
    Check([first containsString:@"1"], @"caption numbers the first steep");
    EBTeaSessionAdvance(&fresh, 11000);
    NSString *ranOut = EBTeaSessionCaption(&cfg, &fresh, NO);
    Check([ranOut containsString:@"done"], @"caption says the steep is done");
    Check(![ranOut containsString:@"Steep 2"], @"caption does not name the next steep yet");
    EBTeaSessionPour(&fresh, &cfg);
    NSString *second = EBTeaSessionCaption(&cfg, &fresh, NO);
    Check([second containsString:@"2"], @"caption names the second steep after pouring");
    fresh.steep = fresh.count - 1;
    Check([EBTeaSessionCaption(&cfg, &fresh, NO).lowercaseString containsString:@"last"],
          @"caption marks the last steep");
    fresh.finished = YES;
    Check([EBTeaSessionCaption(&cfg, &fresh, NO).lowercaseString containsString:@"ready"],
          @"caption says ready at the end");
    NSString *ru = EBTeaSessionCaption(&cfg, &fresh, YES);
    Check(ru.length > 0, @"russian caption exists");

    // Water cannot be brewed.
    EBTeaSession water;
    EBTeaSessionStart(&water, &cfg, EBDrinkWater);
    Check(!EBTeaSessionValid(&water), @"water is not brewable");
    EBTeaSession none;
    EBTeaSessionStart(&none, &cfg, EBDrinkNone);
    Check(!EBTeaSessionValid(&none), @"nothing is not brewable");

    // The tooltip carries the whole schedule, since the item title is only the tea's name.
    NSString *sum = EBTeaSchemeSummary(&cfg, EBDrinkGreen, NO);
    Check([sum containsString:@"10"], @"summary lists the first steep");
    Check([sum containsString:@"35"], @"summary lists the last steep");
    Check([sum containsString:@"6"], @"summary states how many steeps");
    NSString *sumRu = EBTeaSchemeSummary(&cfg, EBDrinkPuer, YES);
    Check([sumRu containsString:@"8"], @"russian summary states the steep count");
    Check([sumRu containsString:@"с"], @"russian summary marks the unit");
    Check(EBTeaSchemeSummary(&cfg, EBDrinkWater, NO).length > 0,
          @"water has a summary even without a schedule");

    EBTeaConfigFree(&cfg);
}

static void TestWarningInterval(void) {
    printf("warning interval bounds\n");
    // The notice needs room to count down before the dialog opens, so its floor is the shortest
    // delay the settings popup offers, 20s.
    Check(EBWarningIntervalMinMin * 60 * 1000 > EBLongBreakConfirmationSec * 1000,
          @"warning floor leaves room for the confirmation countdown");
    Check(EBWarningIntervalMinMin * 60 == 20, @"warning floor is 20 seconds");
}

static void TestWaterReminder(void) {
    printf("hydration reminder\n");

    // Defaults: on, 30 minutes, 100 ml. The total is 200 ml/hour delivered as two sips rather than
    // one 200 ml glass.
    EBCore *fresh = MakeCore(NULL);
    EBSettings d = fresh.defaultSettings;
    Check(d.waterReminderEnabled, @"water reminder is on by default");
    Check(d.waterIntervalMin == EBWaterIntervalDefaultMin, @"default interval is 30 minutes");
    Check(d.waterVolumeMl == EBWaterVolumeDefaultMl, @"default portion is 100 ml");
    Check(60 / d.waterIntervalMin * d.waterVolumeMl == 200, @"default total is 200 ml/hour");

    // The interval list carries 25 minutes, which the owner asked for explicitly.
    int intervals = (int)(sizeof(kWaterIntervalsMin) / sizeof(int));
    Check(intervals == 8, @"eight interval steps");
    BOOL has25 = NO;
    for (int i = 0; i < intervals; i++)
        if (kWaterIntervalsMin[i] == 25)
            has25 = YES;
    Check(has25, @"25 minutes is an offered interval");

    // Every interval and volume the popup offers must survive clamping untouched, otherwise the
    // stored value and the displayed item drift apart.
    EBCore *core = MakeCore(NULL);
    int bad = 0;
    for (int i = 0; i < intervals; i++)
        for (int v = 0; v < (int)(sizeof(kWaterVolumesMl) / sizeof(int)); v++) {
            EBSettings s = core.settings;
            s.waterIntervalMin = kWaterIntervalsMin[i];
            s.waterVolumeMl = kWaterVolumesMl[v];
            EBSettings c = [core clampSettings:s];
            if (c.waterIntervalMin != kWaterIntervalsMin[i] || c.waterVolumeMl != kWaterVolumesMl[v])
                bad++;
        }
    Check(bad == 0, @"every offered interval and portion survives clamping");

    // Off-list values snap to the nearest offered one instead of being clamped to a numeric range:
    // EBIndexOfInt answers 0 for anything it does not know, which would display the first item while
    // the app kept using a value the user never picked.
    EBSettings s = core.settings;
    s.waterIntervalMin = 37;
    Check([core clampSettings:s].waterIntervalMin == 30, @"37 minutes snaps to the nearest offered, 30");
    s.waterIntervalMin = 1000;
    Check([core clampSettings:s].waterIntervalMin == 120, @"1000 minutes snaps to the largest offered, 120");
    s.waterVolumeMl = 0;
    Check([core clampSettings:s].waterVolumeMl == 50, @"0 ml snaps to the smallest offered, 50");

    // Safety ceiling. NIOSH warns above 1414 ml/hour, where water intoxication becomes a risk; no
    // combination of offered settings may reach it.
    int worstMl = 0;
    for (int i = 0; i < intervals; i++) {
        for (int v = 0; v < (int)(sizeof(kWaterVolumesMl) / sizeof(int)); v++) {
            int ml = 60 / kWaterIntervalsMin[i] * kWaterVolumesMl[v];
            if (ml > worstMl)
                worstMl = ml;
        }
    }
    Check(worstMl == 1000, @"worst offered combination is 1000 ml/hour");
    Check(worstMl < 1414, @"no settings combination reaches the 1414 ml/hour ceiling");

    // The reminder fires from the idle branch, so it must not present while a countdown owns the
    // corner. The core retries a minute later rather than stacking the two bubbles.
    Recorder *rec = nil;
    EBCore *c2 = MakeCore(&rec);
    EBSettings fast = c2.defaultSettings;
    fast.bigPauseEnabled = NO;
    fast.miniPauseEnabled = NO;
    fast.waterReminderEnabled = YES;
    fast.waterIntervalMin = 15;
    c2.settings = fast;
    [c2 startWithFirstLaunch:NO lastShutdown:0];

    // Drive the interval out in 1 s steps, which is what the scheduler actually does. Passing
    // tickWithElapsedMs:900000 in one call would not exercise the countdown at all.
    rec.waterDeferred = YES;
    for (int i = 0; i < 15 * 60; i++)
        [c2 tickWithElapsedMs:1000];
    Check(rec.nPresentWater == 0, @"no reminder while the countdown holds the corner");

    // Deferred, so the retry is a minute out rather than a full interval later.
    rec.waterDeferred = NO;
    for (int i = 0; i < 61; i++)
        [c2 tickWithElapsedMs:1000];
    Check(rec.nPresentWater == 1, @"reminder appears once the corner is free");
    Check(rec.nLastWaterMl == fast.waterVolumeMl, @"reminder carries the configured portion");
    Check(rec.nLastWaterSec == EBWaterReminderSec, @"reminder uses the configured auto-dismiss");

    // The next reminder comes a full interval later, not on the next tick.
    [c2 tickWithElapsedMs:1000];
    Check(rec.nPresentWater == 1, @"no immediate repeat after showing");
    for (int i = 0; i < 14 * 60; i++)
        [c2 tickWithElapsedMs:1000];
    Check(rec.nPresentWater == 1, @"still quiet just before the interval elapses");
    for (int i = 0; i < 2 * 60; i++)
        [c2 tickWithElapsedMs:1000];
    Check(rec.nPresentWater == 2, @"next reminder after a full interval");

    // Switching the reminder off must stop it.
    EBSettings off = c2.settings;
    off.waterReminderEnabled = NO;
    c2.settings = off;
    for (int i = 0; i < 60 * 60; i++)
        [c2 tickWithElapsedMs:1000];
    Check(rec.nPresentWater == 2, @"a disabled reminder stays silent");
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
        TestPersonageFramesAndExercises();
        TestTeaConfigAndSession();
        TestDrinkVessels();
        TestAnimationCadence();
        TestWarningInterval();
        TestWaterReminder();
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
        TestBooleansFromAnyPlistWriter();
        TestPersistRoundTrip();
        TestOverLimitSettingsClampedOnSave();
        TestDemoBreakLength();

        printf("\n%d checks, %d failures\n", gChecks, gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}