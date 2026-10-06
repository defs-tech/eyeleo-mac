#import "ebapp.h"

#import <AudioToolbox/AudioToolbox.h>
#import <ServiceManagement/ServiceManagement.h>
#import <time.h>

#import "ebdetect.h"
#import "ebtrace.h"
#include <stdio.h>
#import "ebsettingsui.h"
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
@end

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
    //   EYELEO_TEST_INTERVAL_MIN  clamp both break intervals to N minutes
    NSDictionary *env = NSProcessInfo.processInfo.environment;

    if ([env[@"EYELEO_FAST_MODE"] isEqualToString:@"1"]) {
        _core.fastMode = YES;
        NSLog(@"[EyeLeo] EYELEO_FAST_MODE=1, timers are accelerated");
    }

    EBTraceLap("settings load");
    BOOL loaded = [_core loadSettings];

    // Overrides beat the stored settings, which is what makes them usable for testing: the
    // sandboxed preferences cache in cfprefsd is not reliably writable from outside the app.
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
    [self rearmScheduler:self.schedulerTimer];
    [self refreshStatusItem];
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

    NSMenuItem *login = [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_open_at_login", @"menu")
                                             action:@selector(toggleLoginItem:)
                                      keyEquivalent:@""];
    login.state = [self loginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;

    [self.menu addItem:[NSMenuItem separatorItem]];
    [self.menu addItemWithTitle:NSLocalizedString(@"tb_menu_quit", @"menu")
                          action:@selector(quit:)
                   keyEquivalent:@"q"];

    for (NSMenuItem *item in self.menu.itemArray)
        item.enabled = !locked;
    for (NSMenuItem *item in submenu.itemArray)
        item.enabled = !locked;
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
    [_overlays showLongBreakWithSeconds:seconds];
}

- (void)dismissLongBreak {
    [_overlays hideLongBreakAnimated:YES];
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