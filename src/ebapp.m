#import "ebapp.h"

#import <AudioToolbox/AudioToolbox.h>
#import <ServiceManagement/ServiceManagement.h>
#import <time.h>

#import "ebdetect.h"
#import "ebtrace.h"
#include <stdio.h>
#import "ebsettingsui.h"
#import "ebtea.h"
#import "ebtext.h"

static NSString *const kBundleID = @"local.eyeleo.EyeLeo";

// Eyeleo's single mute menu has no state, so the menu is rebuilt when it opens.
@interface EBAppDelegate ()
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong, nullable) NSImage *statusIconActive;
@property(nonatomic, strong, nullable) NSImage *statusIconPaused;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong, nullable) EBSettingsWindow *settingsWindow;
@property(nonatomic, strong, nullable) dispatch_source_t schedulerTimer;
@property(nonatomic) uint64_t lastTickNanos;
@property(nonatomic) BOOL reportedFirstTick;

// Brewing state. Held by value rather than as an object: it is a handful of integers, it is copied into
// the tick handler, and nothing outside this file needs to reach through a reference to read it.
@property(nonatomic) EBTeaConfig teaConfig;
@property(nonatomic) EBTeaSession tea;
@property(nonatomic) BOOL teaConfigLoaded;
@property(nonatomic) BOOL teaSuspended;
@end

// How long the "ready" notice stays up. Long enough to read, short enough not to become furniture: a
// bubble left on screen after the tea is brewed is the thing this whole change set out to remove.
static const long EBTeaReadyNoticeMs = 5000;

// How close a running steep has to be to its end before brewing is allowed to hold the rest of the app
// back. A steep is a minute or two at most for every tea but the herbal one, and holding a break for the
// sake of a countdown that is nearly over costs the user nothing. Past this, the brewing loses: the app
// exists to get people out of their eyes, and a reminder that can be pushed back eight minutes by
// starting a pot of chamomile is not doing its job.
static const long EBTeaEventDeferCapSec = 150;

@implementation EBAppDelegate

#pragma mark - Launch

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    EBTraceLap("single-instance check");

    if ([self alreadyRunning]) {
        NSLog(@"[EyeLeo] another instance is already running; exiting");
        [NSApp terminate:nil];
        return;
    }

    _core = [[EBCore alloc] init];
    _overlays = [[EBOverlayController alloc] init];
    _core.delegate = self;
    _overlays.delegate = self;

    // The original shipped with _fastMode as a commented-out switch. Here the debugging aids are
    // environment variables so a full cycle of breaks can be watched without recompiling:
    //   EYELEO_FAST_MODE=1        run timers up to 8x faster
    //   EYELEO_DEBUG=1            trace state transitions to stderr
    //   EYELEO_TEST_EXERCISE      force which exercise a short break shows, 1..10
    //   EYELEO_TEST_INTERVAL_MIN  clamp both break intervals to N minutes
    //   EYELEO_TEST_WATER_SEC     first hydration reminder after N seconds instead of the interval
    //   EYELEO_TEST_TEA_SEC       start brewing after N seconds, 1..600
    //   EYELEO_TEST_TEA_NAME      which tea, by the name from tea.conf; default green
    NSDictionary *env = NSProcessInfo.processInfo.environment;

    if ([env[@"EYELEO_FAST_MODE"] isEqualToString:@"1"]) {
        _core.fastMode = YES;
        NSLog(@"[EyeLeo] EYELEO_FAST_MODE=1, timers are accelerated");
    }

    EBTraceLap("settings load");
    BOOL loaded = [_core loadSettings];

    // Read at startup rather than when the menu is first opened, which is what this used to do and why
    // it had to stay lazy. Now that tea.conf is created from the bundle on the first run, there is
    // something to do at launch: the file has to exist before anyone can go looking for it. The cost is
    // one file read per launch, and in exchange the menu is right from the first click and a broken line
    // is reported while there is still a log to read it in.
    _teaConfig = EBLoadTeaConfig();
    _teaConfigLoaded = YES;
    EBTraceLap("tea config");

    // Overrides beat the stored settings, which is what makes them usable for testing: the
    // sandboxed preferences cache in cfprefsd is not reliably writable from outside the app.
    NSString *testExercise = env[@"EYELEO_TEST_EXERCISE"];
    if (testExercise.length) {
        int n = testExercise.intValue;
        if (n >= 1 && n <= EBNumExercises)
            _overlays.forcedExercise = (EBExercise)n;
        NSLog(@"[EyeLeo] EYELEO_TEST_EXERCISE=%@ -> exercise %d", testExercise, (int)_overlays.forcedExercise);
        _core.persistenceSuspended = YES;
    }

    // A brewing session is short enough to watch, so the first steep can be made to start after N
    // seconds instead of waiting for the menu.
    NSString *testTea = env[@"EYELEO_TEST_TEA_SEC"];
    if (testTea) {
        int secs = testTea.intValue;
        if (secs > 0 && secs <= 600) {
            NSLog(@"[EyeLeo] EYELEO_TEST_TEA_SEC=%d, brewing starts in %d s", secs, secs);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs - 1) * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                               NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"test"
                                                                              action:NULL
                                                                       keyEquivalent:@""];
                                // The tea is named rather than numbered, so a config change can be
                                // checked against any tea, not just the first one in the list. The name is
                                // carried through as it is and resolved when the action runs: at this
                                // point the config may not have been read yet, and reading it here would
                                // load it on every launch that happens to set this variable.
                                const char *nameEnv = getenv("EYELEO_TEST_TEA_NAME");
                                item.representedObject = @(nameEnv ? nameEnv : "green");
                               [self startTea:item];
                           });
        }
    }

    NSString *testWater = env[@"EYELEO_TEST_WATER_SEC"];
    if (testWater.length) {
        _core.waterTestFireSec = MAX(testWater.intValue, 1);
        NSLog(@"[EyeLeo] EYELEO_TEST_WATER_SEC=%d, first hydration reminder after %d s",
              _core.waterTestFireSec, _core.waterTestFireSec);
        // Never persist a test run's settings, same as the other overrides.
        _core.persistenceSuspended = YES;
    }

    NSString *testInterval = env[@"EYELEO_TEST_INTERVAL_MIN"];
    NSString *testOnly = env[@"EYELEO_TEST_ONLY"];
    if (testInterval.length || testOnly.length) {
        EBSettings s = _core.settings;
        if (testInterval.length) {
            int minutes = testInterval.intValue;
            if (minutes > 0) {
                s.bigPauseInterval = minutes;
                s.miniPauseInterval = minutes;
                NSLog(@"[EyeLeo] EYELEO_TEST_INTERVAL_MIN=%d, break intervals overridden", minutes);
            }
        }
        if ([testOnly isEqualToString:@"short"]) {
            s.bigPauseEnabled = NO;
            s.miniPauseEnabled = YES;
            NSLog(@"[EyeLeo] EYELEO_TEST_ONLY=short, long breaks disabled");
        } else if ([testOnly isEqualToString:@"long"]) {
            s.bigPauseEnabled = YES;
            s.miniPauseEnabled = NO;
            NSLog(@"[EyeLeo] EYELEO_TEST_ONLY=long, short breaks disabled");
        }
        _core.settings = s;
        // An accelerated run must never persist its one-minute intervals into the real settings.
        _core.persistenceSuspended = YES;
    }
    EBStats stats = _core.stats;
    [_core startWithFirstLaunch:!loaded lastShutdown:stats.lastShutdown];

    [self installStatusItem];
    EBTraceLap("status item");
    [self observeSystemEvents];
    [self startScheduler];
    EBTraceLap("scheduler armed");
    [self refreshStatusItem];
    EBTraceLap("ready");

    // EYELEO_TEST_OPEN_SETTINGS=1 smoke-tests the settings window without a human clicking the
    // menu bar item, which is the only way to exercise it on a machine with no input injection.
    if ([env[@"EYELEO_TEST_OPEN_SETTINGS"] isEqualToString:@"1"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{
                           [self openSettings];
                       });
    }
}

- (BOOL)alreadyRunning {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: kBundleID;
    NSUInteger count = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].count;
    return count > 1;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopScheduler];
    [_overlays hideAll];

    EBStats stats = _core.stats;
    stats.lastShutdown = [[NSDate date] timeIntervalSince1970];
    stats.seenSettings = _settingsWindow != nil || stats.seenSettings;
    _core.stats = stats;
    [_core saveSettings];

    [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    self.statusItem = nil;
}

- (void)observeSystemEvents {
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self
           selector:@selector(didWake)
               name:NSWorkspaceDidWakeNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(willSleep)
               name:NSWorkspaceWillSleepNotification
             object:nil];

    // A display change invalidates every cached layout, so drop the overlays.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(screenParametersChanged)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];
}

// Mirrors EyeApp::OnSessionUnlock: restart both intervals rather than resuming a timer that
// was counting down while the machine was asleep.
- (void)didWake {
    [_core resumeFromPause];
    [self refreshStatusItem];
}

- (void)willSleep {
    [_overlays hideAll];
    [_core saveSettings];
}

- (void)screenParametersChanged {
    [_overlays hideAll];
    [self refreshStatusItem];
}

#pragma mark - Scheduler

- (uint64_t)nowNanos {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * NSEC_PER_SEC + (uint64_t)ts.tv_nsec;
}

- (void)startScheduler {
    [self stopScheduler];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    self.lastTickNanos = [self nowNanos];
    [self rearmScheduler:timer];
    __weak EBAppDelegate *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf schedulerFired];
    });
    dispatch_resume(timer);
    self.schedulerTimer = timer;
}

// Arms the timer for the interval the core asked for. Elapsed time is measured from the
// monotonic clock rather than assumed equal to the interval, so a late wake-up does not
// shorten or extend a break.
- (void)rearmScheduler:(dispatch_source_t)timer {
    uint64_t interval = (uint64_t)(_core.nextTickIntervalMs * NSEC_PER_MSEC);
    if (interval == 0)
        interval = NSEC_PER_SEC;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval,
                              50 * NSEC_PER_MSEC);
}

- (void)schedulerFired {
    uint64_t now = [self nowNanos];
    long elapsedMs = (long)((now - self.lastTickNanos) / NSEC_PER_MSEC);
    self.lastTickNanos = now;
    if (elapsedMs <= 0)
        elapsedMs = 1;

    if (!self.reportedFirstTick) {
        self.reportedFirstTick = YES;
        EBTraceLap("first tick");
    }
    [_core tickWithElapsedMs:elapsedMs];
    [self tickTeaWithMs:elapsedMs];
    [self rearmScheduler:self.schedulerTimer];
    [self refreshStatusItem];
}

// Brewing runs on the same scheduler as the breaks, so a steep ends on time whatever else is happening,
// and stops when monitoring is suspended like everything else.
- (void)tickTeaWithMs:(long)elapsedMs {
    if (!EBTeaSessionValid(&_tea))
        return;
    BOOL russian = EBRussianNow();

    // The timer runs even while a break is up, so a steep can run out during one. That is the honest
    // reading: nobody poured anything during the break.
    if (EBTeaSessionAdvance(&_tea, elapsedMs)) {
        // A steep ran out, the last one included. The same moment on Windows, and the same one sound:
        // the leaves have given what they were going to give, and whether another pour follows is the
        // pourer's decision rather than part of the event.
        if (_core.settings.soundsEnabled)
            [self playSteepEndSound];

        NSString *caption = EBTeaSessionCaption(&_teaConfig, &_tea, russian);
        if (_tea.finished) {
            // The last steep ran out: the tea is brewed. Say so once, briefly, then clear the screen.
            [_overlays showTeaReminderWithCaption:caption
                                            image:[self brewingVessel]
                                           msLeft:0
                                    autoDismissMs:EBTeaReadyNoticeMs];
            if (EBTraceOn())
                fprintf(stderr, "[EB] tea ready: %s\n", caption.UTF8String);
            return;
        }
        // A steep ended and the next is not started. The bubble has nothing left to count, so it goes down
        // rather than sitting at zero; the Pour item brings the next one up.
        [_overlays hideTeaReminder];
        if (EBTraceOn())
            fprintf(stderr, "[EB] steep ran out, awaiting the next pour: %s\n", caption.UTF8String);
        return;
    }
    [_overlays updateTeaReminderCaption:EBTeaSessionCaption(&_teaConfig, &_tea, russian) msLeft:_tea.msLeft];
}

// The vessel for whatever is in the pot, named after the tea in tea.conf. Nil when there is no session,
// which every caller has already established by the time it asks.
- (nullable NSImage *)brewingVessel {
    const EBTeaScheme *tea = EBTeaSessionTea(&_teaConfig, &_tea);
    return tea ? [EBAssets.shared drinkImageNamed:@(tea->name)] : nil;
}

// Choosing a tea starts its first steep immediately.
- (void)startTea:(NSMenuItem *)sender {
    // The represented object is the tea's name, not its position. A name is what identifies a tea, it is
    // what the test hook can set without the config having been read yet, and looking it up is a walk
    // over a list of seven.
    NSString *name = sender.representedObject;
    if (![name isKindOfClass:[NSString class]] || name.length == 0)
        return;
    if (!_teaConfigLoaded) {
        _teaConfig = EBLoadTeaConfig();
        _teaConfigLoaded = YES;
    }
    int tea = EBTeaSchemeIndexOfName(&_teaConfig, name.UTF8String);
    if (tea < 0)
        return; // not in the list: a tea deleted from tea.conf, or a name that never was one
    // A break owns the screen, so brewing cannot start during one. The brewing bubble itself does not
    // block: switching teas mid-session has to stay possible, and it is only on screen while nothing else
    // is.
    if (_overlays.anyVisible && !_overlays.teaReminderVisible)
        return;

    EBTeaSessionStart(&_tea, &_teaConfig, tea);
    if (!EBTeaSessionValid(&_tea)) {
        EBTeaSessionStop(&_tea);
        return;
    }
    BOOL russian = EBRussianNow();
    NSString *caption = EBTeaSessionCaption(&_teaConfig, &_tea, russian);
    [_overlays showTeaReminderWithCaption:caption
                                    image:[self brewingVessel]
                                   msLeft:_tea.msLeft
                            autoDismissMs:0];
    if (EBTraceOn())
        fprintf(stderr, "[EB] brewing started: %s\n", caption.UTF8String);
}

// Pours the next steep. This is the only place the step number moves; the timer alone never does it.
- (void)pourNextSteep:(id)sender {
    if (!EBTeaSessionValid(&_tea))
        return;
    // A break owns the screen, so the bubble cannot come back up underneath one. The menu already reflects
    // this, but a stale menu can still deliver the action.
    if (_overlays.anyVisible && !_overlays.teaReminderVisible)
        return;

    BOOL russian = EBRussianNow();
    if (!EBTeaSessionPour(&_tea, &_teaConfig))
        return; // still steeping, nothing pending, or the session already ended
    NSString *caption = EBTeaSessionCaption(&_teaConfig, &_tea, russian);

    [_overlays showTeaReminderWithCaption:caption
                                    image:[self brewingVessel]
                                   msLeft:_tea.msLeft
                            autoDismissMs:0];
    if (EBTraceOn())
        fprintf(stderr, "[EB] poured: %s\n", caption.UTF8String);
}

- (void)stopScheduler {
    if (self.schedulerTimer) {
        dispatch_source_cancel(self.schedulerTimer);
        self.schedulerTimer = nil;
    }
}

#pragma mark - Status item

- (void)installStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    // Loaded once: refreshStatusItem runs on every tick, and re-reading from disk each second
    // would be pointless I/O.
    //
    // imageNamed: rather than initWithContentsOfFile:, because it is what picks up the @2x
    // variant and reports the image as 22pt. Handing NSImage a bare 44px file makes it a 44pt
    // image, which is twice the menu bar thickness and collapses the button to zero height.
    self.statusIconActive = [NSImage imageNamed:@"StatusActive"];
    self.statusIconPaused = [NSImage imageNamed:@"StatusPaused"];
    for (NSImage *image in @[ self.statusIconActive, self.statusIconPaused ]) {
        // Template images are painted in the menu bar foreground colour, which is what lets one
        // asset work in both the light and the dark appearance.
        image.template = YES;
    }
    self.statusItem.button.image = self.statusIconActive;
    self.statusItem.button.toolTip = NSLocalizedString(@"tb_popup_default", @"tooltip");

    self.menu = [[NSMenu alloc] init];
    // NSMenu autoenables its items by default, which means AppKit decides who is clickable at every open
    // and ignores what the builder assigned: any item with an implemented action comes back enabled. With
    // nothing implementing NSMenuValidation, that took the Pour item's rule away from the line that
    // computes it, and also the strict-mode lock below. Turning it off is what makes those assignments
    // mean anything. Every action on this menu is implemented, so nothing is left clickable by default
    // that would only beep.
    self.menu.autoenablesItems = NO;
    self.menu.delegate = self;
    self.statusItem.menu = self.menu;

    if (EBTraceOn()) {
        // The menu bar lays the item out asynchronously, so report once it has happened.
        NSStatusItem *item = self.statusItem;
        NSImage *icon = self.statusIconActive;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{
                           NSRect f = item.button.window.frame;
                           fprintf(stderr,
                                   "[EB] status item: icon=%s size=%.0fx%.0f template=%d "
                                   "button=%.0f,%.0f %.0fx%.0f visible=%d bar=%.0f\n",
                                   icon ? "ok" : "NIL", icon.size.width, icon.size.height, icon.isTemplate,
                                   f.origin.x, f.origin.y, f.size.width, f.size.height,
                                   item.button.window.isVisible, NSStatusBar.systemStatusBar.thickness);
                       });
    }
}


- (void)menuWillOpen:(NSMenu *)menu {
    [self rebuildMenu];
}

// The brewing section: Pour, then New tea with one entry per tea.
//
// Pour starts the next steep, so it is only offered while something is brewing. Choosing a tea from the
// submenu starts its first steep straight away: brewing is the point of picking one, and asking for a
// second click to begin would be a step for nothing. The tick on the current tea marks the one in progress.
- (void)rebuildTeaMenuLocked:(BOOL)locked {
    if (!_teaConfigLoaded) {
        _teaConfig = EBLoadTeaConfig();
        _teaConfigLoaded = YES;
    }
    BOOL brewing = EBTeaSessionValid(&_tea);

    // The title carries how long the next steep will run, because that is the one number worth knowing
    // before deciding to pour, and it is visible without hovering.
    NSString *pourTitle = NSLocalizedString(@"tb_menu_pour", @"menu");
    int nextSec = EBTeaSessionNextSeconds(&_teaConfig, &_tea);
    if (nextSec > 0)
        pourTitle = [NSString stringWithFormat:@"%@ · %d %@", pourTitle, nextSec,
                                               EBRussianNow() ? @"с" : @"s"];
    NSMenuItem *pour = [self.menu addItemWithTitle:pourTitle
                                            action:@selector(pourNextSteep:)
                                     keyEquivalent:@""];
    // Offered exactly when there is something to pour: a steep has run out and another one is left. It is
    // not disabled while the bubble is up, because the bubble is how the user knows a steep ended.
    pour.enabled = !locked && brewing && _tea.awaiting && !_tea.finished;

    NSMenuItem *newTea = [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_new_tea", @"menu")
                                              action:NULL
                                       keyEquivalent:@""];
    NSMenu *teaMenu = [[NSMenu alloc] init];
    teaMenu.autoenablesItems = NO; // as above, for the same reason as the other two menus
    // The teas are whatever tea.conf lists, in the order it lists them. Reading the list rather than a
    // fixed one is the whole point of the file: a tea added to it turns up here without a rebuild, and
    // one taken out of it disappears, which is a choice somebody has been able to make all along.
    for (int i = 0; i < _teaConfig.count; i++) {
        const EBTeaScheme *tea = &_teaConfig.schemes[i];
        NSMenuItem *item = [teaMenu addItemWithTitle:EBTeaDisplayName(tea->name)
                                               action:@selector(startTea:)
                                        keyEquivalent:@""];
        item.representedObject = @(tea->name);
        item.enabled = !locked;
        item.state = (brewing && _tea.tea == i) ? NSControlStateValueOn : NSControlStateValueOff;
        // The schedule as a tooltip, so the item title stays just the name. Whether AppKit paints a
        // tooltip on a menu item inside a status item menu is worth checking by eye; the Pour item above
        // carries the number that matters either way.
        item.toolTip = EBTeaSchemeSummary(&_teaConfig, i, EBRussianNow());
    }
    newTea.submenu = teaMenu;

    [self.menu addItem:[NSMenuItem separatorItem]];
}

- (void)rebuildMenu {
    [self.menu removeAllItems];

    EBSettings s = _core.settings;
    // The original refuses to open the tray menu during a strict-mode long break, so that the
    // break cannot be dismissed from it. Disabling every item is the AppKit equivalent.
    BOOL locked = s.strictModeEnabled && _core.nextState == EBStateRelaxing;

    [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_settings", @"menu")
                          action:@selector(openSettings)
                   keyEquivalent:@","];
    [self.menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *pause = [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_pause_monitoring", @"menu")
                                             action:NULL
                                      keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] init];
    submenu.autoenablesItems = NO; // as above: the strict-mode lock has to be able to reach these
    [submenu addItemWithTitle:NSLocalizedString(@"tb_menu_pause_monitoring_1", @"menu")
                       action:@selector(pauseForHour:)
                keyEquivalent:@""];
    [submenu addItemWithTitle:NSLocalizedString(@"tb_menu_pause_monitoring_2", @"menu")
                       action:@selector(pauseForThreeHours:)
                keyEquivalent:@""];
    pause.submenu = submenu;
    if (_core.paused) {
        [submenu addItem:[NSMenuItem separatorItem]];
        [submenu addItemWithTitle:NSLocalizedString(@"tb_menu_resume_monitoring", @"menu")
                           action:@selector(resumeMonitoring:)
                    keyEquivalent:@""];
    }

    [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_take_break_now", @"menu")
                          action:@selector(takeBreakNow:)
                   keyEquivalent:@""];

    [self rebuildTeaMenuLocked:locked];

    NSMenuItem *login = [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_open_at_login", @"menu")
                                             action:@selector(toggleLoginItem:)
                                      keyEquivalent:@""];
    login.state = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;

    [self.menu addItem:[NSMenuItem separatorItem]];
    [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_quit", @"menu")
                          action:@selector(quit:)
                   keyEquivalent:@"q"];

    // Strict mode takes everything away, and only ever subtracts: the rules above decide what is normally
    // clickable. Assigning !locked instead also handed the Pour item its click back on every ordinary menu
    // open, which is why it stayed live before a tea was chosen and during every steep.
    if (locked) {
        for (NSMenuItem *item in self.menu.itemArray)
            item.enabled = NO;
        for (NSMenuItem *item in submenu.itemArray)
            item.enabled = NO;
    }
}

- (void)refreshStatusItem {
    NSString *title = [_core statusTitleWithLanguage:NSLocale.currentLocale.languageCode];
    self.statusItem.button.image = _core.paused ? self.statusIconPaused : self.statusIconActive;
    self.statusItem.button.toolTip = title.length ? title : NSLocalizedString(@"tb_popup_default", @"tooltip");
    _overlays.strictMode = _core.settings.strictModeEnabled;
    _overlays.canCloseNotifications = _core.settings.canCloseNotifications;
}

#pragma mark - Menu actions

- (void)openSettings {
    if (self.settingsWindow) {
        [self.settingsWindow.window makeKeyAndOrderFront:nil];
        [NSApp activate];
        return;
    }

    EBSettingsWindow *window = [[EBSettingsWindow alloc] initWithSettings:_core.settings
                                                                   stats:_core.stats
                                                            startAtLogin:[self loginItemEnabled]];
    __weak EBAppDelegate *weakSelf = self;
    window.onSave = ^(EBSettings settings, BOOL startAtLogin) {
        weakSelf.core.settings = settings;
        [weakSelf.core settingsDidClose];
        EBStats stats = weakSelf.core.stats;
        stats.seenSettings = YES;
        weakSelf.core.stats = stats;
        [weakSelf.core saveSettings];
        if (startAtLogin != [weakSelf loginItemEnabled])
            [weakSelf setLoginItemEnabled:startAtLogin];
        [weakSelf refreshStatusItem];
    };
    window.onDemo = ^(BOOL longBreak) {
        [weakSelf.settingsWindow close];
        weakSelf.settingsWindow = nil;
        if (longBreak)
            [weakSelf.core startDemoBreak];
        else
            [weakSelf presentDemoShortBreak];
    };
    window.onQueryStartAtLogin = ^BOOL {
        return [weakSelf loginItemEnabled];
    };
    window.onSetStartAtLogin = ^BOOL(BOOL enabled) {
        return [weakSelf setLoginItemEnabled:enabled];
    };
    self.settingsWindow = window;

    window.window.delegate = (id)self;
    [window showWindow:nil];
    [NSApp activate];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.settingsWindow.window)
        self.settingsWindow = nil;
}

- (void)pauseForHour:(id)sender {
    [_core requestPauseForMinutes:EBDisableActivity1Min];
    [self refreshStatusItem];
}

- (void)pauseForThreeHours:(id)sender {
    [_core requestPauseForMinutes:EBDisableActivity2Min];
    [self refreshStatusItem];
}

- (void)resumeMonitoring:(id)sender {
    [_core resumeFromPause];
    [self refreshStatusItem];
}

- (void)takeBreakNow:(id)sender {
    [_core takeLongBreakNow];
    [self refreshStatusItem];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

- (void)toggleLoginItem:(id)sender {
    [self setLoginItemEnabled:![self loginItemEnabled]];
    [self rebuildMenu];
}

#pragma mark - Login item

- (BOOL)loginItemEnabled {
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
}

// SMAppService requires the user's consent the first time; a refusal is reported to the
// caller so the settings window can put its checkbox back.
- (BOOL)setLoginItemEnabled:(BOOL)enabled {
    NSError *error = nil;
    if (enabled) {
        if (![SMAppService.mainAppService registerAndReturnError:&error])
            NSLog(@"[EyeLeo] login item registration failed: %@", error.localizedDescription);
    } else {
        if (![SMAppService.mainAppService unregisterAndReturnError:&error])
            NSLog(@"[EyeLeo] login item removal failed: %@", error.localizedDescription);
    }
    return [self loginItemEnabled] == enabled;
}

#pragma mark - EBCoreDelegate

- (int)displayCount {
    return MAX(1, (int)NSScreen.screens.count);
}

- (int)fullscreenDisplay {
    return EBFullscreenDisplay();
}

- (void)hideFrontmostApp {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front)
        return;
    // The macOS analogue of ShowWindow(hwnd, SW_FORCEMINIMIZE).
    if (![front hide])
        NSLog(@"[EyeLeo] could not hide %@", front.localizedName);
}

- (void)presentLongBreakWithSeconds:(int)seconds demo:(BOOL)demo {
    (void)demo; // the demo differs only in length, which the core already applied
    [self suspendTeaForBreak];
    [_overlays showLongBreakWithSeconds:seconds];
}

- (void)dismissLongBreak {
    [_overlays hideLongBreakAnimated:YES];
    [self resumeTeaAfterBreak];
}

- (void)presentCountdownWithMsLeft:(long)msLeft display:(int)display {
    [_overlays showCountdownWithMsLeft:msLeft onDisplay:display];
}

- (void)dismissCountdown {
    [_overlays hideCountdownAnimated:YES];
}

- (void)presentWaterReminderWithVolumeMl:(int)ml seconds:(int)seconds {
    [_overlays showWaterReminderWithVolumeMl:ml seconds:seconds];
}

- (BOOL)waterReminderDeferred {
    return [_overlays showWaterReminderDeferred];
}

// Whether a brewing steep is close enough to its end to hold the rest of the app back.
//
// Awaiting counts as NOT blocking: the timer has already run out, the bubble is down, and how long the
// leaf sits in the pot before the next pour is the pourer's business, not something to be polite about.
// Nothing is brewing, so there is nothing to wait for.
- (BOOL)teaBlocksEvents {
    if (!EBTeaSessionValid(&_tea) || _tea.awaiting || _tea.finished)
        return NO;
    return _tea.msLeft <= EBTeaEventDeferCapSec * 1000L;
}

// A break takes the screen, so brewing gets out of its way. The session itself is kept rather than
// dropped: the tea is still steeping, the bubble just is not on top of the break. It comes back when the
// break clears.
- (void)suspendTeaForBreak {
    if (!EBTeaSessionValid(&_tea))
        return;
    _teaSuspended = _overlays.teaReminderVisible;
    if (!_teaSuspended)
        return;
    [_overlays hideTeaReminder];
    if (EBTraceOn())
        fprintf(stderr, "[EB] tea bubble suspended for a break\n");
}

// Brings the brewing bubble back after a break, if the tea is still going. Called once the overlays are
// clear, so nothing lands underneath the break that follows.
//
// A session that ran out during the break comes back showing that its steep is done and waiting, which is
// what happened: the timer was never stopped.
- (void)resumeTeaAfterBreak {
    if (!_teaSuspended || !EBTeaSessionValid(&_tea) || _tea.finished)
        return;
    _teaSuspended = NO;
    // A steep that ran out during the break has nothing to count, so no bubble comes back: the Pour item is
    // what brings the next one up, same as when the break is not involved.
    if (_tea.awaiting)
        return;
    BOOL russian = EBRussianNow();
    [_overlays showTeaReminderWithCaption:EBTeaSessionCaption(&_teaConfig, &_tea, russian)
                                    image:[self brewingVessel]
                                   msLeft:_tea.msLeft
                            autoDismissMs:0];
    if (EBTraceOn())
        fprintf(stderr, "[EB] tea bubble restored after the break\n");
}

- (void)presentBeforeBreak {
    [_overlays showBeforeBreakOnDisplay:0];
}

- (void)dismissBeforeBreak {
    [_overlays hideBeforeBreakAnimated:YES];
}

- (void)presentWaiting {
    [_overlays showWaiting];
}

- (void)dismissWaiting {
    [_overlays hideWaitingAnimated:YES];
}

- (void)presentShortBreakShowCount:(unsigned)showCount fullscreen:(BOOL)fullscreen {
    [self suspendTeaForBreak];
    [_overlays showShortBreakWithCount:showCount
                             durationMs:(long)_core.settings.miniPauseDuration * 1000
                             fullscreen:fullscreen
                           windowNearby:_core.settings.windowNearby];
}

- (void)dismissShortBreak {
    [_overlays hideShortBreakAnimated:YES];
}

- (void)updateStatusTitle:(NSString *)title isPaused:(BOOL)paused {
    [self refreshStatusItem];
}

- (void)postNotificationKey:(NSString *)key duration:(NSString *)duration {
    if (!_core.settings.showNotifications)
        return;

    NSString *text = NSLocalizedString(key, @"notification");
    if (duration.length)
        text = [NSString stringWithFormat:text, duration];

    if (text.length == 0 || [text isEqualToString:key])
        return; // missing string: show nothing rather than a raw key

    [_overlays showNotificationWithText:text seconds:10];
}

- (void)playBreakEndSound {
    // kSystemSoundID_UserPreferredAlert resolves to the user's chosen alert sound and needs no
    // permission; it is the macOS analogue of the Windows SystemExclamation alias.
    AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert);
}

- (void)playSteepEndSound {
    // "Submerge" in the Russian settings is the system sound whose file is called Submarine: a low tone
    // going under. Which of the two names is the right one is a translation detail, and the file is what
    // exists, so Submarine is what is asked for. A named system sound rather than an alert ID, because
    // there is no alert that means "a steep ran out" and the user is entitled to pick something else by
    // changing the sound. Cached because a named sound is read off disk and a session asks for it once
    // per steep, six to eight times.
    static NSSound *steep = nil;
    if (!steep)
        steep = [NSSound soundNamed:@"Submarine"];
    [steep play];
}

- (void)terminateApp {
    [NSApp terminate:nil];
}

#pragma mark - EBOverlayDelegate

- (void)presentDemoShortBreak {
    EBSettings s = _core.settings;
    EBStats stats = _core.stats;
    stats.shortBreakCount++;
    _core.stats = stats;
    [_overlays showShortBreakWithCount:0
                             durationMs:(long)s.miniPauseDuration * 1000
                             fullscreen:s.miniPauseFullscreen
                           windowNearby:s.windowNearby];
}

- (void)overlayDidRequestSkipLongBreak {
    [_overlays hideLongBreakAnimated:NO];
    [_core skipBigBreak];
    [self refreshStatusItem];
}

- (void)overlayDidRequestRefuse {
    [_overlays hideBeforeBreakAnimated:NO];
    [_core refuseBigPause];
    [self refreshStatusItem];
}

- (void)overlayDidRequestPostpone {
    [_overlays hideBeforeBreakAnimated:NO];
    [_core postponeBigPause];
    [self refreshStatusItem];
}

- (void)overlayDidRequestAccept {
    // The dialog counts down to this, so the long break starts from here.
    [_overlays hideBeforeBreakAnimated:NO];
    [_core acceptLongBreak];
    [self refreshStatusItem];
}

- (void)overlayDidRequestCloseShortBreak {
    // The short break interval already restarted when the break was presented, so closing it
    // early needs nothing from the core.
    [_overlays hideShortBreakAnimated:YES];
    [self refreshStatusItem];
}

@end