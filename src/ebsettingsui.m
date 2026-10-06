#import "ebsettingsui.h"

#import "ebtext.h"

// Value lists ported verbatim from settings_wnd.cpp:13-33.
static const int kBigPauseIntervals[] = { 20, 25, 30, 35, 40, 45, 50, 60, 90, 120 };
static const int kBigPauseDurations[] = { 2, 3, 4, 5, 7, 10, 15, 20 };
static const double kWarningDelays[] = { 20.0 / 60.0, 0.5, 1.0, 1.5 }; // 20s, 30s, 60s, 90s
// Hydration lists, added in the port. Defined here rather than reused from ebcore.h so the popup and
// the clamping logic can never disagree about what a valid value is; the test asserts the two match.
static const int kWaterIntervalSteps[] = { 15, 20, 25, 30, 45, 60, 90, 120 };
static const int kWaterVolumeSteps[] = { 50, 100, 150, 200, 250 };
static const int kMiniPauseIntervals[] = { 5, 8, 10, 15, 20, 30 };
static const int kMiniPauseDurations[] = { 8, 15, 20 };

static NSString *LocalizedListItem(NSString *keyFormat, int index) {
    return NSLocalizedString(([NSString stringWithFormat:keyFormat, index]), @"settings dropdown item");
}

@interface EBSettingsWindow ()
@property(nonatomic) EBSettings settings;
@property(nonatomic) NSPopUpButton *bigIntervalButton;
@property(nonatomic) NSPopUpButton *bigDurationButton;
@property(nonatomic) NSPopUpButton *warningButton;
@property(nonatomic) NSPopUpButton *miniIntervalButton;
@property(nonatomic) NSPopUpButton *miniDurationButton;
@property(nonatomic) NSPopUpButton *waterIntervalButton;
@property(nonatomic) NSPopUpButton *waterVolumeButton;
@property(nonatomic) NSButton *bigEnabled;
@property(nonatomic) NSButton *waterEnabled;
@property(nonatomic) NSButton *miniEnabled;
@property(nonatomic) NSButton *warningEnabled;
@property(nonatomic) NSButton *sounds;
@property(nonatomic) NSButton *strictMode;
@property(nonatomic) NSButton *windowNearby;
@property(nonatomic) NSButton *canCloseNotifications;
@property(nonatomic) NSButton *inactivityTracking;
@property(nonatomic) NSButton *showNotifications;
@property(nonatomic) NSButton *miniFullscreen;
@property(nonatomic) NSButton *startAtLogin;
@property(nonatomic) BOOL applyingInitialState;
@end

@implementation EBSettingsWindow

- (instancetype)initWithSettings:(EBSettings)settings
                           stats:(EBStats)stats
                    startAtLogin:(BOOL)startAtLogin {
    NSRect frame = NSMakeRect(0, 0, 600, 520);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable
                                                      backing:NSBackingStoreBuffered
                                                        defer:YES];
    if ((self = [super initWithWindow:window])) {
        _settings = settings;
        window.title = NSLocalizedString(@"settings_title", @"settings window title");
        window.releasedWhenClosed = NO;
        [self buildWithStats:stats startAtLogin:startAtLogin];
    }
    return self;
}

#pragma mark - Widgets

- (NSTextField *)caption:(NSString *)key {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = NSLocalizedString(key, @"settings caption");
    label.font = [NSFont systemFontOfSize:12];
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (NSButton *)checkbox:(NSString *)key target:(id)target {
    NSButton *box = [NSButton checkboxWithTitle:NSLocalizedString(key, @"settings checkbox")
                                          target:target
                                          action:NULL];
    box.font = [NSFont systemFontOfSize:12];
    return box;
}

- (NSPopUpButton *)popupWithKeyFormat:(NSString *)format count:(int)count target:(id)target {
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:count];
    for (int i = 1; i <= count; i++)
        [titles addObject:LocalizedListItem(format, i)];
    NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [button addItemsWithTitles:titles];
    button.target = target;
    button.action = @selector(controlChanged:);
    button.font = [NSFont systemFontOfSize:12];
    [button setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}

- (NSStackView *)rowWith:(NSArray<NSView *> *)views {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 8;
    return stack;
}

- (NSStackView *)groupWithTitle:(NSString *)key rows:(NSArray<NSView *> *)rows {
    NSStackView *box = [NSStackView stackViewWithViews:rows];
    box.orientation = NSUserInterfaceLayoutOrientationVertical;
    box.alignment = NSLayoutAttributeLeading;
    box.spacing = 6;

    NSTextField *title = [self caption:key];
    title.font = [NSFont boldSystemFontOfSize:12];

    NSStackView *outer = [NSStackView stackViewWithViews:@[ title, box ]];
    outer.orientation = NSUserInterfaceLayoutOrientationVertical;
    outer.alignment = NSLayoutAttributeLeading;
    outer.spacing = 4;
    return outer;
}

#pragma mark - Layout

- (void)buildWithStats:(EBStats)stats startAtLogin:(BOOL)startAtLogin {
    _applyingInitialState = YES;

    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSZeroRect];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _bigEnabled = [self checkbox:@"tb_menu_take_break_now" target:NULL];
    _bigEnabled.title = NSLocalizedString(@"settings_big_pause_label_1", @"long break section");
    _bigEnabled.font = [NSFont boldSystemFontOfSize:12];
    _bigEnabled.target = self;
    _bigEnabled.action = @selector(controlChanged:);

    _bigIntervalButton = [self popupWithKeyFormat:@"settings_big_pause_value_1_%d"
                                            count:(int)(sizeof(kBigPauseIntervals) / sizeof(int))
                                            target:self];
    _bigDurationButton = [self popupWithKeyFormat:@"settings_big_pause_value_2_%d"
                                            count:(int)(sizeof(kBigPauseDurations) / sizeof(int))
                                            target:self];

    _warningEnabled = [self checkbox:@"settings_big_pause_warning_label" target:self];
    _warningButton = [self popupWithKeyFormat:@"settings_big_pause_warning_value_%d"
                                       count:(int)(sizeof(kWarningDelays) / sizeof(double))
                                       target:self];

    _miniEnabled = [self checkbox:@"settings_mini_pause_label" target:self];
    _miniIntervalButton = [self popupWithKeyFormat:@"settings_mini_pause_value_%d"
                                             count:(int)(sizeof(kMiniPauseIntervals) / sizeof(int))
                                             target:self];
    _miniDurationButton = [self popupWithKeyFormat:@"settings_mini_pause_duration_value_%d"
                                             count:(int)(sizeof(kMiniPauseDurations) / sizeof(int))
                                             target:self];

    NSView *longBreak = [self groupWithTitle:@"settings_general_panel_label"
                                        rows:@[
                                            _bigEnabled,
                                            [self rowWith:@[ [self caption:@"settings_big_pause_label_1"],
                                                             _bigIntervalButton,
                                                             [self caption:@"settings_big_pause_label_2"],
                                                             _bigDurationButton ]],
                                            [self rowWith:@[ _warningEnabled, _warningButton ]],
                                        ]];

    NSView *shortBreak = [self groupWithTitle:@"settings_mini_pause_label"
                                         rows:@[
                                             _miniEnabled,
                                             [self rowWith:@[ _miniIntervalButton, _miniDurationButton ]],
                                         ]];

    _waterEnabled = [self checkbox:@"settings_water_reminder_label" target:self];
    _waterIntervalButton = [self popupWithKeyFormat:@"settings_water_interval_value_%d"
                                              count:(int)(sizeof(kWaterIntervalSteps) / sizeof(int))
                                              target:self];
    _waterVolumeButton = [self popupWithKeyFormat:@"settings_water_volume_value_%d"
                                            count:(int)(sizeof(kWaterVolumeSteps) / sizeof(int))
                                            target:self];

    NSView *water = [self groupWithTitle:@"settings_water_group_label"
                                    rows:@[
                                        _waterEnabled,
                                        [self rowWith:@[ [self caption:@"settings_water_interval_label"],
                                                         _waterIntervalButton,
                                                         [self caption:@"settings_water_volume_label"],
                                                         _waterVolumeButton ]],
                                    ]];

    _sounds = [self checkbox:@"settings_enable_sounds_label" target:self];
    _strictMode = [self checkbox:@"settings_enable_strict_mode_label" target:self];
    _windowNearby = [self checkbox:@"settings_have_window_nearby" target:self];
    _canCloseNotifications = [self checkbox:@"settings_can_close_notifications_label" target:self];
    _inactivityTracking = [self checkbox:@"settings_can_enable_inactivity_tracking" target:self];
    _showNotifications = [self checkbox:@"settings_show_notifications" target:self];
    _miniFullscreen = [self checkbox:@"settings_mini_pause_fullscreen" target:self];
    _startAtLogin = [self checkbox:@"settings_start_at_login" target:self];
    _startAtLogin.action = @selector(toggleStartAtLogin:);

    NSView *behaviour = [self groupWithTitle:@"settings_settings_tab"
                                        rows:@[
                                            _sounds, _strictMode, _windowNearby, _canCloseNotifications,
                                            _inactivityTracking, _showNotifications, _miniFullscreen,
                                            _startAtLogin,
                                        ]];

    NSStackView *settingsTab =
        [NSStackView stackViewWithViews:@[ longBreak, shortBreak, water, behaviour ]];
    settingsTab.orientation = NSUserInterfaceLayoutOrientationVertical;
    settingsTab.alignment = NSLayoutAttributeLeading;
    settingsTab.spacing = 16;
    settingsTab.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);

    // --- Information tab
    NSTextField *info = [[NSTextField alloc] initWithFrame:NSZeroRect];
    info.stringValue = NSLocalizedString(@"information_info_1", @"about text");
    info.font = [NSFont systemFontOfSize:12];
    info.editable = NO;
    info.selectable = NO;
    info.bezeled = NO;
    info.bordered = NO;
    info.drawsBackground = NO;

    NSString *statsText = [NSString stringWithFormat:NSLocalizedString(@"information_stats_fmt", @"stats"),
                                                    @(stats.longBreakCount), @(stats.shortBreakCount),
                                                    @(stats.earlySkipCount + stats.lateSkipCount),
                                                    @(stats.postponeCount), @(stats.refuseCount)];
    NSTextField *statsLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    statsLabel.stringValue = [NSString stringWithFormat:@"%@\n\n%@",
                                                        NSLocalizedString(@"information_stats", @"stats header"),
                                                        statsText];
    statsLabel.font = [NSFont systemFontOfSize:12];
    statsLabel.editable = NO;
    statsLabel.selectable = NO;
    statsLabel.bezeled = NO;
    statsLabel.bordered = NO;
    statsLabel.drawsBackground = NO;

    NSTextField *author = [[NSTextField alloc] initWithFrame:NSZeroRect];
    author.stringValue = NSLocalizedString(@"information_author", @"author");
    author.font = [NSFont systemFontOfSize:11];
    author.textColor = NSColor.secondaryLabelColor;
    author.editable = NO;
    author.selectable = NO;
    author.bezeled = NO;
    author.bordered = NO;
    author.drawsBackground = NO;

    NSStackView *infoStack = [NSStackView stackViewWithViews:@[ info, statsLabel, author ]];
    infoStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    infoStack.alignment = NSLayoutAttributeLeading;
    infoStack.spacing = 12;
    infoStack.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);

    NSTabViewItem *settingsItem = [[NSTabViewItem alloc] initWithIdentifier:@"settings"];
    settingsItem.label = NSLocalizedString(@"settings_settings_tab", @"tab label");
    settingsItem.view = settingsTab;

    NSTabViewItem *infoItem = [[NSTabViewItem alloc] initWithIdentifier:@"info"];
    infoItem.label = NSLocalizedString(@"settings_information_tab", @"tab label");
    infoItem.view = infoStack;
    tabs.tabViewItems = @[ settingsItem, infoItem ];

    // --- Demo buttons pinned to the bottom of the window.
    NSButton *tryShort = [NSButton buttonWithTitle:NSLocalizedString(@"settings_try_short_break_button", @"")
                                             target:self
                                             action:@selector(tryShort:)];
    NSButton *tryLong = [NSButton buttonWithTitle:NSLocalizedString(@"settings_try_long_break_button", @"")
                                            target:self
                                            action:@selector(tryLong:)];
    NSButton *save = [NSButton buttonWithTitle:NSLocalizedString(@"settings_save_and_close_button", @"")
                                          target:self
                                          action:@selector(saveAndClose:)];
    tryShort.keyEquivalent = @"";
    tryLong.keyEquivalent = @"";
    save.keyEquivalent = @"\r";

    NSStackView *buttons = [NSStackView stackViewWithViews:@[ tryShort, tryLong, save ]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 10;

    NSView *content = self.window.contentView;
    [tabs setTranslatesAutoresizingMaskIntoConstraints:NO];
    [buttons setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content addSubview:tabs];
    [content addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [tabs.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [tabs.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [buttons.topAnchor constraintEqualToAnchor:tabs.bottomAnchor constant:10],
        [buttons.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [buttons.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [buttons.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:20],
    ]];

    [self populateFromSettings];
    _startAtLogin.state = startAtLogin ? NSControlStateValueOn : NSControlStateValueOff;
    _applyingInitialState = NO;
    [self updateEnabledStates];
}

#pragma mark - Populating

static NSInteger EBIndexOfInt(int value, const int *list, int count) {
    for (int i = 0; i < count; i++)
        if (list[i] == value)
            return i;
    return 0;
}

static NSInteger EBIndexOfDouble(double value, const double *list, int count) {
    for (int i = 0; i < count; i++)
        if (fabs(list[i] - value) < 0.00001)
            return i;
    return 0;
}

- (void)populateFromSettings {
    EBSettings s = _settings;
    _bigEnabled.state = s.bigPauseEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _miniEnabled.state = s.miniPauseEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _warningEnabled.state = s.warningEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _sounds.state = s.soundsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _strictMode.state = s.strictModeEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _windowNearby.state = s.windowNearby ? NSControlStateValueOn : NSControlStateValueOff;
    _canCloseNotifications.state = s.canCloseNotifications ? NSControlStateValueOn : NSControlStateValueOff;
    _inactivityTracking.state = s.inactivityTracking ? NSControlStateValueOn : NSControlStateValueOff;
    _showNotifications.state = s.showNotifications ? NSControlStateValueOn : NSControlStateValueOff;
    _miniFullscreen.state = s.miniPauseFullscreen ? NSControlStateValueOn : NSControlStateValueOff;
    _waterEnabled.state = s.waterReminderEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    [_waterIntervalButton selectItemAtIndex:EBIndexOfInt(s.waterIntervalMin, kWaterIntervalSteps, (int)(sizeof(kWaterIntervalSteps) / sizeof(int)))];
    [_waterVolumeButton selectItemAtIndex:EBIndexOfInt(s.waterVolumeMl, kWaterVolumeSteps, (int)(sizeof(kWaterVolumeSteps) / sizeof(int)))];

    [_bigIntervalButton selectItemAtIndex:EBIndexOfInt(s.bigPauseInterval, kBigPauseIntervals, (int)(sizeof(kBigPauseIntervals) / sizeof(int)))];
    [_bigDurationButton selectItemAtIndex:EBIndexOfInt(s.bigPauseDuration, kBigPauseDurations, (int)(sizeof(kBigPauseDurations) / sizeof(int)))];
    [_warningButton selectItemAtIndex:EBIndexOfDouble(s.warningInterval, kWarningDelays, (int)(sizeof(kWarningDelays) / sizeof(double)))];
    [_miniIntervalButton selectItemAtIndex:EBIndexOfInt(s.miniPauseInterval, kMiniPauseIntervals, (int)(sizeof(kMiniPauseIntervals) / sizeof(int)))];
    [_miniDurationButton selectItemAtIndex:EBIndexOfInt(s.miniPauseDuration, kMiniPauseDurations, (int)(sizeof(kMiniPauseDurations) / sizeof(int)))];
}

- (EBSettings)collectSettings {
    EBSettings s = _settings;
    s.bigPauseEnabled = _bigEnabled.state == NSControlStateValueOn;
    s.miniPauseEnabled = _miniEnabled.state == NSControlStateValueOn;
    s.warningEnabled = _warningEnabled.state == NSControlStateValueOn;
    s.soundsEnabled = _sounds.state == NSControlStateValueOn;
    s.strictModeEnabled = _strictMode.state == NSControlStateValueOn;
    s.windowNearby = _windowNearby.state == NSControlStateValueOn;
    s.canCloseNotifications = _canCloseNotifications.state == NSControlStateValueOn;
    s.inactivityTracking = _inactivityTracking.state == NSControlStateValueOn;
    s.showNotifications = _showNotifications.state == NSControlStateValueOn;
    s.miniPauseFullscreen = _miniFullscreen.state == NSControlStateValueOn;
    s.waterReminderEnabled = _waterEnabled.state == NSControlStateValueOn;

    s.bigPauseInterval = kBigPauseIntervals[_bigIntervalButton.indexOfSelectedItem];
    s.bigPauseDuration = kBigPauseDurations[_bigDurationButton.indexOfSelectedItem];
    s.warningInterval = kWarningDelays[_warningButton.indexOfSelectedItem];
    s.miniPauseInterval = kMiniPauseIntervals[_miniIntervalButton.indexOfSelectedItem];
    s.miniPauseDuration = kMiniPauseDurations[_miniDurationButton.indexOfSelectedItem];
    s.waterIntervalMin = kWaterIntervalSteps[_waterIntervalButton.indexOfSelectedItem];
    s.waterVolumeMl = kWaterVolumeSteps[_waterVolumeButton.indexOfSelectedItem];
    return s;
}

- (void)controlChanged:(id)sender {
    [self updateEnabledStates];
}

- (void)updateEnabledStates {
    BOOL big = _bigEnabled.state == NSControlStateValueOn;
    _bigIntervalButton.enabled = big;
    _bigDurationButton.enabled = big;
    _warningButton.enabled = _warningEnabled.state == NSControlStateValueOn;
    _miniIntervalButton.enabled = _miniEnabled.state == NSControlStateValueOn;
    _miniDurationButton.enabled = _miniEnabled.state == NSControlStateValueOn;
    _waterIntervalButton.enabled = _waterEnabled.state == NSControlStateValueOn;
    _waterVolumeButton.enabled = _waterEnabled.state == NSControlStateValueOn;
}

#pragma mark - Actions

- (void)saveAndClose:(id)sender {
    if (self.onSave)
        self.onSave([self collectSettings], _startAtLogin.state == NSControlStateValueOn);
    [self.window close];
}

- (void)tryShort:(id)sender {
    if (self.onDemo)
        self.onDemo(NO);
    [self.window close];
}

- (void)tryLong:(id)sender {
    if (self.onDemo)
        self.onDemo(YES);
    [self.window close];
}

- (void)toggleStartAtLogin:(id)sender {
    if (self.applyingInitialState)
        return;

    BOOL want = _startAtLogin.state == NSControlStateValueOn;
    BOOL granted = self.onSetStartAtLogin ? self.onSetStartAtLogin(want) : NO;
    if (!granted) {
        // SMAppService needs the user's consent in System Settings; put the checkbox back
        // rather than leaving a switch that does nothing.
        _startAtLogin.state = want ? NSControlStateValueOff : NSControlStateValueOn;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"settings_start_at_login", @"login item");
        alert.informativeText = NSLocalizedString(@"settings_start_at_login_tooltip", @"login item");
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

@end