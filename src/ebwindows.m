#import "ebwindows.h"

#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdio.h>

#import "ebassets.h"
#import "ebcore.h"
#import "ebexercise.h"
#import "ebgeometry.h"
#import "ebtext.h"

// Fades reach full opacity. The Windows build animated windows to 210/255, which on macOS would
// also fade the exercise image, the text and the buttons. Everything except the dim layer is now
// fully opaque, so only the dimming is see-through.
static const CGFloat kOverlayAlpha = 1.0;
static const NSTimeInterval kFadeIn = 0.38;
static const NSTimeInterval kFadeOut = 0.28;
static const NSTimeInterval kSecondsPerTick = 0.1;
// How far every break dims the rest of the screen. Tuned by looking at the result:
// 0.62 -> 0.90 -> 0.78 for the long break (judged right), and the short break now uses the same
// value with no blur, which is what makes the two breaks look the same.
static const CGFloat kBreakDim = 0.78;

// Panel colour. The skin PNGs that came with the Windows build cannot be used as-is: their white
// border was the window *shape* mask (SetShape(region(bitmap, *wxWHITE))), so on Windows it was
// never drawn. Drawing them on macOS showed a white outline. The panels are drawn instead.
static const CGFloat kPanelRed = 0.11, kPanelGreen = 0.11, kPanelBlue = 0.12;
static const CGFloat kPanelRadius = 10.0;

@class EBOverlayController;

#pragma mark - Shared building blocks

static NSScreen *EBDisplay(int index) {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (index >= 0 && index < (int)screens.count)
        return screens[index];

    // No window server session, or an index that no longer exists after a display was unplugged.
    // Messaging nil yields a zero rect, which would place the overlay nowhere and say nothing about
    // why, so make it visible in the trace.
    if (screens.count == 0 && EBTraceOn())
        fprintf(stderr, "[EB] no screens available, overlay on display %d has nowhere to go\n", index);

    return NSScreen.mainScreen ?: screens.firstObject;
}

static NSColor *EBAmber(void) {
    return [NSColor colorWithSRGBRed:1.0 green:200 / 255.0 blue:70 / 255.0 alpha:1];
}

static NSColor *EBPanelColor(void) {
    return [NSColor colorWithCalibratedRed:kPanelRed green:kPanelGreen blue:kPanelBlue alpha:1.0];
}

// A dark rounded panel. Fully opaque on purpose: the see-through part of a break is the dim layer.
static NSView *PanelBackground(NSSize size) {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = EBPanelColor().CGColor;
    view.layer.cornerRadius = kPanelRadius;
    return view;
}

static NSTextField *Label(NSString *text, CGFloat pointSize, NSColor *color, NSTextAlignment align, BOOL bold) {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.stringValue = text ?: @"";
    field.font = bold ? [NSFont boldSystemFontOfSize:pointSize] : [NSFont systemFontOfSize:pointSize];
    field.textColor = color;
    field.alignment = align;
    field.editable = NO;
    field.selectable = NO;
    field.bezeled = NO;
    field.bordered = NO;
    field.drawsBackground = NO;
    field.lineBreakMode = NSLineBreakByWordWrapping;
    field.maximumNumberOfLines = 0;
    return field;
}

static NSButton *FlatButton(NSString *title, id target, SEL action) {
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 112, 26)];
    button.buttonType = NSButtonTypeMomentaryPushIn;
    button.title = title;
    button.font = [NSFont systemFontOfSize:12];
    button.bezelStyle = NSBezelStyleRounded;
    // The overlays sit on a transparent window over a dimmed desktop. The stock rounded bezel is
    // drawn with its own translucency and reads as see-through there, so the colour is set
    // explicitly: the button must be as opaque as the text and the artwork next to it.
    button.bezelColor = [NSColor colorWithCalibratedRed:0.30 green:0.30 blue:0.32 alpha:1.0];
    button.contentTintColor = NSColor.whiteColor;
    button.target = target;
    button.action = action;
    return button;
}

// Catches right clicks for the "let me dismiss this" setting. Overlays never take key focus,
// so a view is the right place for this rather than the window.
@interface EBTapCatcherView : NSView
@property(nonatomic, weak) EBOverlayController *controller;
@end

#pragma mark - Base overlay window

@interface EBOverlayWindow : NSPanel
@property(nonatomic, readonly) int displayIndex;
// True for the two overlays that must actually stop the user working: they take key focus so
// keystrokes land here instead of in the app underneath, and they consume mouse events.
@property(nonatomic, readonly) BOOL capturesInput;
- (instancetype)initWithContentView:(NSView *)view onDisplay:(int)display capturesInput:(BOOL)captures;
@end

@implementation EBOverlayWindow

- (instancetype)initWithContentView:(NSView *)view onDisplay:(int)display capturesInput:(BOOL)captures {
    // A non-activating panel can never become key, which is exactly what an advisory overlay wants
    // and exactly what a break must not be: the whole point is to keep the keyboard out of the
    // application the user was working in.
    NSWindowStyleMask mask = NSWindowStyleMaskBorderless;
    if (!captures)
        mask |= NSWindowStyleMaskNonactivatingPanel;

    self = [super initWithContentRect:view.frame styleMask:mask backing:NSBackingStoreBuffered defer:YES];
    if (!self)
        return nil;

    _displayIndex = display;
    _capturesInput = captures;
    self.contentView = view;
    self.opaque = NO;
    self.backgroundColor = NSColor.clearColor;
    self.hasShadow = NO;
    self.level = NSFloatingWindowLevel;
    self.floatingPanel = YES;
    self.becomesKeyOnlyIfNeeded = YES;
    self.hidesOnDeactivate = NO;
    self.worksWhenModal = YES;
    self.releasedWhenClosed = YES;
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    // Follow the user across Spaces and stay visible over a fullscreen app.
    self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                              NSWindowCollectionBehaviorFullScreenAuxiliary |
                              NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorIgnoresCycle;
    return self;
}

- (BOOL)canBecomeKeyWindow {
    return self.capturesInput;
}

- (BOOL)canBecomeMainWindow {
    return NO;
}

@end

#pragma mark - Controller

@interface EBOverlayController ()
@property(nonatomic, strong) NSMutableArray<EBOverlayWindow *> *longBreakWnds;
@property(nonatomic, strong) NSMutableArray<EBOverlayWindow *> *longBreakDimWnds;
@property(nonatomic, strong) NSMutableArray<EBOverlayWindow *> *shortBreakWnds;
// Full screen dimming layers underneath the short break. Kept apart from the panel so the fade can
// bring them to full opacity while the panel still fades to the 82% the original used.
@property(nonatomic, strong) NSMutableArray<EBOverlayWindow *> *shieldWnds;
@property(nonatomic, strong) NSMutableArray<EBOverlayWindow *> *beforeBreakWnds;
@property(nonatomic, strong) NSMutableArray<EBOverlayWindow *> *waitingWnds;
@property(nonatomic, strong, nullable) EBOverlayWindow *countdownWnd;
@property(nonatomic, strong, nullable) EBOverlayWindow *notificationWindow;
@property(nonatomic, strong, nullable) EBOverlayWindow *waterWnd;
@property(nonatomic, strong, nullable) NSImageView *longArt;
@property(nonatomic, strong, nullable) NSTextField *waterTime;
@property(nonatomic, strong, nullable) EBOverlayWindow *teaWnd;
@property(nonatomic, strong, nullable) NSTextField *teaCaption;
@property(nonatomic, strong, nullable) NSTextField *teaTime;
@property(nonatomic) NSUInteger teaDismissToken;
@property(nonatomic) long waterMsLeft;

@property(nonatomic, strong, nullable) NSTextField *longClock;
@property(nonatomic, strong, nullable) NSImageView *shortImage;
@property(nonatomic, strong, nullable) NSTextField *shortTime;
@property(nonatomic, strong, nullable) NSTextField *countdownTime;
@property(nonatomic, strong, nullable) NSButton *beforeReadyButton;
@property(nonatomic, strong, nullable) EBExerciseAnimation *animation;

// Two independent timers, because the overlays run at different rates and must not starve each
// other: 100 ms drives the short-break animation and the before-break ready countdown, 1 s
// drives the long-break clock and the pre-break bubble. The original gave every window its own
// task; sharing one prioritised timer let the bubble swallow the dialog's countdown, so the
// dialog's ready timer never fired.
@property(nonatomic, strong, nullable) dispatch_source_t fastTimer;
@property(nonatomic, strong, nullable) dispatch_source_t slowTimer;

// Fades are stepped by a timer of our own rather than by NSAnimationContext. The animator proxy
// does not reliably complete for a non-active LSUIElement app: the window kept its old alpha and
// the completion handler never ran, so a short break never dismissed itself.
@property(nonatomic, strong, nullable) dispatch_source_t fadeTimer;
@property(nonatomic, strong) NSMutableArray *fadeJobs;

// The app that was frontmost before a break grabbed focus, so focus can go back afterwards.
// The original had the same idea in BigPauseWindow::_restoreFocus.
@property(nonatomic, strong, nullable) NSRunningApplication *suspendedApplication;

@property(nonatomic) long longBreakMsLeft;
@property(nonatomic) int longStretchPhase;
@property(nonatomic) int longStretchTick;
@property(nonatomic) long shortBreakMsLeft;
@property(nonatomic) long countdownMsLeft;
@property(nonatomic) int beforeReadySeconds;
@property(nonatomic) BOOL shortBreakClosable;

- (void)fastTick;
- (void)slowTick;
- (void)stepLongBreakStretch;
- (void)startFastTimer;
- (void)startSlowTimer;
- (void)stopFastTimer;
- (void)stopSlowTimer;
- (void)stopTimersIfIdle;
- (BOOL)slowTickHasWork;
- (void)restoreFocusIfHeld;
- (void)stepFades;
- (void)stopFade;
- (void)fadeIn:(NSArray<EBOverlayWindow *> *)windows;
- (void)fadeIn:(NSArray<EBOverlayWindow *> *)windows toAlpha:(CGFloat)alpha;
- (void)fadeOut:(NSArray<EBOverlayWindow *> *)windows;
- (nullable NSString *)milestoneTextForCount:(unsigned)count;
- (EBOverlayWindow *)makeShieldForDisplay:(int)display;
@end

// One fade in flight. Several run at once: a break fades its dimming layer and its content
// separately, and a single shared fade state meant the second call cancelled the first, leaving
// the dimming layer at alpha 0 -- present, full screen, and completely invisible.
@interface EBFadeJob : NSObject
@property(nonatomic, strong) NSArray<EBOverlayWindow *> *windows;
@property(nonatomic) CGFloat fromAlpha;
@property(nonatomic) CGFloat toAlpha;
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic) NSTimeInterval elapsed;
@property(nonatomic) BOOL hideWhenDone;
@end

@implementation EBFadeJob
@end

@implementation EBOverlayController

- (instancetype)init {
    if ((self = [super init])) {
        _longBreakWnds = [NSMutableArray array];
        _longBreakDimWnds = [NSMutableArray array];
        _shortBreakWnds = [NSMutableArray array];
        _shieldWnds = [NSMutableArray array];
        _fadeJobs = [NSMutableArray array];
        _beforeBreakWnds = [NSMutableArray array];
        _waitingWnds = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    if (_fastTimer)
        dispatch_source_cancel(_fastTimer);
    if (_slowTimer)
        dispatch_source_cancel(_slowTimer);
    if (_fadeTimer)
        dispatch_source_cancel(_fadeTimer);
}

- (BOOL)countdownVisible {
    return self.countdownWnd.isVisible;
}

- (BOOL)anyVisible {
    for (NSArray *group in @[ self.longBreakWnds, self.longBreakDimWnds, self.shortBreakWnds,
                              self.shieldWnds, self.beforeBreakWnds, self.waitingWnds ]) {
        for (EBOverlayWindow *w in group)
            if (w.isVisible)
                return YES;
    }
    return self.countdownWnd.isVisible;
}

#pragma mark - Window plumbing

- (EBOverlayWindow *)windowWithView:(NSView *)view onDisplay:(int)display capturesInput:(BOOL)captures {
    EBOverlayWindow *window = [[EBOverlayWindow alloc] initWithContentView:view onDisplay:display capturesInput:captures];
    NSScreen *screen = EBDisplay(display);
    NSRect full = screen.frame;

    if (NSWidth(view.frame) >= NSWidth(full) - 1 && NSHeight(view.frame) >= NSHeight(full) - 1) {
        // Covers the display edge to edge, menu bar and Dock included: the dimming layer and the
        // long break screen.
        [window setFrame:full display:NO];
    } else {
        // Floats above the desktop, so it is centred in the work area. Centring on frame would put
        // it under the Dock or the menu bar. The original used the client area for the same reason.
        NSRect work = screen.visibleFrame;
        NSSize want = EBFittedSize(NSMakeSize(NSWidth(view.frame), NSHeight(view.frame)), work);
        if (want.width < NSWidth(view.frame) || want.height < NSHeight(view.frame)) {
            // Only reachable on a display smaller than the artwork. Scale the content with the
            // window instead of letting the panel hang off the edges.
            if (EBTraceOn())
                fprintf(stderr, "[EB] panel %.0fx%.0f does not fit work area %.0fx%.0f, shrinking\n",
                        view.frame.size.width, view.frame.size.height, NSWidth(work), NSHeight(work));
            CGFloat sx = want.width / NSWidth(view.frame);
            CGFloat sy = want.height / NSHeight(view.frame);
            for (NSView *sub in view.subviews)
                sub.frame = NSMakeRect(NSMinX(sub.frame) * sx, NSMinY(sub.frame) * sy, NSWidth(sub.frame) * sx,
                                       NSHeight(sub.frame) * sy);
            view.frame = NSMakeRect(0, 0, want.width, want.height);
        }
        // NSWindow.frame is readonly; setFrame:display: is the way to move and resize a window.
        [window setFrame:EBCenteredRect(NSMakeSize(NSWidth(view.frame), NSHeight(view.frame)), work)
                 display:NO];
    }
    return window;
}

// Shows overlays without touching focus: used by the countdown, the before-break dialog, the
// waiting banner and the notification bubble. All of those are advisory.
- (void)presentPassiveWindows:(NSArray<EBOverlayWindow *> *)windows {
    for (EBOverlayWindow *w in windows)
        [w orderFrontRegardless];
}

// Shows overlays that must stop the user working. Activating the app is what moves the keyboard:
// an LSUIElement app that never becomes active leaves keystrokes going to whatever was in front,
// so the break would be decorative.
- (void)presentCapturingWindows:(NSArray<EBOverlayWindow *> *)windows {
    // Only remember what is worth handing focus back to, and only while there is a foreground session
    // to hand it to. A break that lands on a locked screen finds the login window in front, and by the
    // time it ends that login window is gone, so restoring focus to it did nothing except leave the
    // activation policy below switched over. sessionIsActive is the honest test for this: it is what the
    // screen being locked actually does, rather than a list of system bundle identifiers that would be
    // incomplete the first time another one showed up.
    if (!self.suspendedApplication && self.sessionActive)
        self.suspendedApplication = NSWorkspace.sharedWorkspace.frontmostApplication;

    // A background-only (LSUIElement) app is never granted key focus: the frontmost application
    // simply stays whatever it was, so keystrokes keep going to the user's editor. Raising the
    // activation policy to Regular for the duration of the break is the only public way to take
    // the keyboard without asking for the Accessibility permission an event tap would need.
    // The cost is a Dock icon and an app menu while the break is up.
    NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
    [NSApp activateIgnoringOtherApps:YES];
    for (EBOverlayWindow *w in windows)
        [w makeKeyAndOrderFront:nil];

    if (EBTraceOn())
        fprintf(stderr, "[EB] capture input: appActive=%d key=%d windows=%lu\n", NSApp.isActive,
                windows.firstObject.isKeyWindow, (unsigned long)windows.count);

    // Activation is asynchronous, so the flags above only describe the moment of the call.
    // Re-check once the system has finished making us frontmost.
    if (EBTraceOn()) {
        // Probe the window that actually captures input: in the short break the first entry is the
        // click shield, which is deliberately never key.
        EBOverlayWindow *probe = windows.firstObject;
        for (EBOverlayWindow *w in windows)
            if (w.capturesInput)
                probe = w;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
            fprintf(stderr, "[EB] capture settled: appActive=%d key=%d main=%d front=%s\n", NSApp.isActive,
                    probe.isKeyWindow, probe.isMainWindow, front ? front.bundleIdentifier.UTF8String : "?");
        });
    }
}

// Gives the keyboard back to whatever the user was working in before the break.
- (void)restoreSuspendedApplication {
    NSRunningApplication *previous = self.suspendedApplication;
    self.suspendedApplication = nil;

    // Back to a background-only app before anything can return early, so the Dock icon disappears and
    // the next break starts from the same state as this one did.
    //
    // Every early return below used to sit above this line, which meant the policy stayed Regular for
    // the rest of the session whenever nothing was captured, when the frontmost app was this one, or
    // when it had quit during the break. The last of those is what a locked screen does: a break arriving
    // on the login window remembers it, the lock is lifted, the login window is gone by then, and the app
    // was left as a normal application with a Dock icon and an app menu. Once that had happened once, the
    // next break captured EyeLeo itself and the third early return made it permanent.
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;


    if (!previous)
        return; // nothing was captured, so there is nothing to give back
    if (EBTraceOn())
        fprintf(stderr, "[EB] restore focus to \"%s\"\n", previous.localizedName.UTF8String);
    if (previous.processIdentifier == NSProcessInfo.processInfo.processIdentifier)
        return;
    if (previous.isTerminated)
        return;
    // Plain activation: NSApplicationActivateIgnoringOtherApps is deprecated since macOS 14 and
    // has no effect, so it would silently fail to hand focus back.
    [previous activateWithOptions:0];
}

- (void)teardown:(NSMutableArray<EBOverlayWindow *> *)windows {
    for (EBOverlayWindow *w in windows)
        [w orderOut:nil];
    [windows removeAllObjects];
}

// Drops windows that have finished fading out of every group, then stops the UI timer if
// nothing is left on screen.
- (void)retireWindows:(NSArray<EBOverlayWindow *> *)windows {
    for (EBOverlayWindow *w in windows)
        [w orderOut:nil];
    [_longBreakWnds removeObjectsInArray:windows];
    [_longBreakDimWnds removeObjectsInArray:windows];
    [_shortBreakWnds removeObjectsInArray:windows];
    [_shieldWnds removeObjectsInArray:windows];
    [_beforeBreakWnds removeObjectsInArray:windows];
    [_waitingWnds removeObjectsInArray:windows];
    [self stopTimersIfIdle];
}

- (int)displayCount {
    return MAX(1, (int)NSScreen.screens.count);
}

#pragma mark - UI timer

- (dispatch_source_t)makeTimerWithInterval:(NSTimeInterval)interval handler:(dispatch_block_t)handler {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, handler);
    dispatch_resume(timer);
    return timer;
}

- (void)startFastTimer {
    if (EBTraceOn())
        fprintf(stderr, "[EB] startFastTimer\n");
    [self stopFastTimer];
    __weak EBOverlayController *weakSelf = self;
    self.fastTimer = [self makeTimerWithInterval:kSecondsPerTick
                                         handler:^{
                                             [weakSelf fastTick];
                                         }];
}

- (void)stopFastTimer {
    if (_fastTimer) {
        dispatch_source_cancel(_fastTimer);
        _fastTimer = nil;
    }
}

- (void)startSlowTimer {
    [self stopSlowTimer];
    __weak EBOverlayController *weakSelf = self;
    self.slowTimer = [self makeTimerWithInterval:1.0
                                         handler:^{
                                             [weakSelf slowTick];
                                         }];
}

- (void)stopSlowTimer {
    if (_slowTimer) {
        dispatch_source_cancel(_slowTimer);
        _slowTimer = nil;
    }
}

// 100 ms: short-break animation, then the before-break ready countdown.
- (void)fastTick {
    if (self.shortBreakMsLeft > 0) {
        [self.animation advance];
        // Every animated exercise swaps its artwork now, so this is a straight image assignment. The
        // transform is still applied because it is part of the animation interface, and because it is
        // identity for every exercise that exists.
        self.shortImage.image = self.animation.image;
        self.shortImage.layer.transform = self.animation.transform;
        self.shortBreakMsLeft -= 100;
        self.shortTime.stringValue = EBTimeLeftText(MAX(self.shortBreakMsLeft, 0), EBRussianNow(), NO);
        if (self.shortBreakMsLeft <= 0)
            [self hideShortBreakAnimated:YES];
    }

    if (self.shortBreakMsLeft <= 0)
        [self stopFastTimer];
}

// 1 s: the pre-break bubble, the long-break clock, then the before-break ready countdown.
- (void)slowTick {
    if (self.countdownTime) {
        self.countdownMsLeft -= 1000;
        if (self.countdownMsLeft <= 0) {
            // The original lets the bubble run out on its own timer.
            [self hideCountdownAnimated:YES];
        } else {
            self.countdownTime.stringValue = EBTimeLeftText(self.countdownMsLeft, EBRussianNow(), NO);
        }
    }

    if (self.longArt)
        [self stepLongBreakStretch];

    if (self.waterTime) {
        self.waterMsLeft -= 1000;
        if (self.waterMsLeft <= 0) {
            [self hideWaterReminder];
        } else {
            self.waterTime.stringValue = EBTimeLeftText(self.waterMsLeft, EBRussianNow(), NO);
            if (EBTraceOn())
                fprintf(stderr, "[EB] water bubble now shows '%s'\n", self.waterTime.stringValue.UTF8String);
        }
    }

    if (self.longClock) {
        self.longBreakMsLeft -= 1000;
        self.longClock.stringValue =
            [NSString stringWithFormat:NSLocalizedString(@"big_pause_time_left_text", @""),
                                       EBTimeLeftText(MAX(self.longBreakMsLeft, 0), EBRussianNow(), YES)];
    }

    if (self.beforeReadyButton) {
        // The original waits out a six second timer before accepting, which is a deliberate
        // "are you really ready" beat rather than a click requirement. It runs here rather than
        // on the 100 ms timer because it counts seconds, not tenths.
        self.beforeReadySeconds--;
        if (EBTraceOn())
            fprintf(stderr, "[EB] slow tick, ready in %d\n", self.beforeReadySeconds);
        if (self.beforeReadySeconds <= 0)
            [self.delegate overlayDidRequestAccept];
        else
            self.beforeReadyButton.title =
                [NSString stringWithFormat:NSLocalizedString(@"before_pause_accept_button", @""),
                                            self.beforeReadySeconds];
    }

    if (![self slowTickHasWork])
        [self stopSlowTimer];
}

#pragma mark - Long break

// A slow alternating lean, the way someone rolls their shoulders during a long break. Six seconds to
// each side is far slower than the short break's motion on purpose: this runs for minutes, not
// seconds, and anything quicker reads as a twitch. The anchor point is the bottom of the frame so the
// figure leans from the hips instead of pivoting around its own middle.
// The long break cycles through three drawn poses instead of tilting one picture: a standing figure,
// a lean to the left with the right arm up, and a lean to the right with the left arm up. Frames rather
// than a transform, because a rotated single image read as a sliding picture rather than as a body.
- (void)stepLongBreakStretch {
    static const EBPersonageFrame kOrder[4] = { EBFrameStretchNeutral, EBFrameStretchLeft,
                                                EBFrameStretchNeutral, EBFrameStretchRight };
    // Two ticks per pose, so a phase lasts two seconds. A stretch is meant to be unhurried, and at one
    // second the leopard read as fidgeting rather than holding the position.
    if ((self.longStretchTick++ % 2) != 0)
        return;
    self.longStretchPhase = (self.longStretchPhase + 1) % 4;
    self.longArt.image = [EBAssets.shared personage:kOrder[self.longStretchPhase]];
    if (EBTraceOn())
        fprintf(stderr, "[EB] long break frame %d\n", self.longStretchPhase);
}

- (void)showLongBreakWithSeconds:(int)seconds {
    [self hideLongBreakAnimated:NO];
    [self teardown:_longBreakDimWnds];
    _longBreakMsLeft = (long)seconds * 1000;

    BOOL russian = EBRussianNow();
    for (int d = 0; d < self.displayCount; d++) {
        // Same construction as the short break: a dim layer that owns the transparency, and a
        // content window that stays fully opaque so the leopard, the clock and the Skip button are
        // not dimmed along with the desktop.
        EBOverlayWindow *dimLayer = [self makeShieldForDisplay:d];
        [self.longBreakDimWnds addObject:dimLayer];

        NSRect screen = EBDisplay(d).frame;
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, screen.size.width, screen.size.height)];

        if (d == 0) {
            CGFloat centreX = NSWidth(view.frame) / 2.0;
            CGFloat cursorY = NSHeight(view.frame) - 200;

            NSImage *titleImage = EBAssets.shared.title;
            if (titleImage) {
                NSImageView *title =
                    [[NSImageView alloc] initWithFrame:NSMakeRect(17, NSHeight(view.frame) - 15 - titleImage.size.height,
                                                                  titleImage.size.width, titleImage.size.height)];
                title.image = titleImage;
                [view addSubview:title];
            }

            // The full figure rather than a bust: the long break is the one screen that justifies it,
            // and a five minute break is long enough to show a stretch rather than just a head.
            NSImage *leopard = [EBAssets.shared personage:EBFrameStretchNeutral];
            if (!leopard)
                leopard = [EBAssets.shared personage:EBFrameDefault];
            if (leopard) {
                // No scale factor here. The stretch frames are drawn at the height this screen can give
                // them, and personage: has already halved them from their stored pixel size to points.
                // The bust this replaced was 98px tall and was multiplied by 1.6; carrying that over to a
                // 348pt figure made it 557pt, which reached past the Dock and off the bottom.
                //
                // Capped against the screen as well. The figure starts 200pt from the top and the tip, the
                // clock and the Skip button need about 250pt below it, so on a short display an uncapped
                // 348pt figure would push the Skip button off the bottom edge.
                CGFloat artH = leopard.size.height;
                CGFloat artW = leopard.size.width;
                CGFloat room = NSHeight(view.frame) - 200 - 250;
                if (artH > room) {
                    artW *= room / artH;
                    artH = room;
                }
                if (artH < 40) {
                    artH = 40;
                    artW = leopard.size.width * 40.0 / leopard.size.height;
                }
                NSImageView *portrait =
                    [[NSImageView alloc] initWithFrame:NSMakeRect(centreX - artW / 2.0,
                                                                  cursorY - artH, artW, artH)];
                portrait.image = leopard;
                [view addSubview:portrait];
                self.longArt = portrait;
                cursorY -= artH + 20;
                if (EBTraceOn())
                    fprintf(stderr, "[EB] long break figure %.0fx%.0f pt on a %.0fx%.0f screen, top y=%.0f\n",
                            artW, artH, NSWidth(view.frame), NSHeight(view.frame), cursorY + artH);
            }

            static NSString *const tips[3] = { @"big_pause_text_1", @"big_pause_text_2", @"big_pause_text_3" };
            NSTextField *tip = Label(NSLocalizedString(tips[arc4random_uniform(3)], @"long break tip"), 14,
                                     NSColor.whiteColor, NSTextAlignmentCenter, NO);
            tip.frame = NSMakeRect(centreX - 300, cursorY - 70, 600, 70);
            [view addSubview:tip];
            cursorY -= 90;

            NSTextField *clock = Label(EBTimeLeftText(_longBreakMsLeft, russian, YES), 12,
                                       [NSColor colorWithSRGBRed:210 / 255.0 green:210 / 255.0 blue:210 / 255.0
                                                           alpha:1],
                                       NSTextAlignmentCenter, NO);
            clock.frame = NSMakeRect(centreX - 100, cursorY - 40, 200, 30);
            [view addSubview:clock];
            _longClock = clock;
            cursorY -= 50;

            if (!self.strictMode) {
                NSButton *skip = FlatButton(NSLocalizedString(@"big_pause_skip_button", @""), self,
                                            @selector(skipLongBreak:));
                skip.frame = NSMakeRect(centreX - 56, cursorY - 26, 112, 26);
                [view addSubview:skip];
            }
        }

        EBOverlayWindow *window = [self windowWithView:view onDisplay:d capturesInput:YES];
        window.alphaValue = 0;
        [self.longBreakWnds addObject:window];
        [dimLayer orderFrontRegardless];
    }

    [self presentCapturingWindows:_longBreakWnds];
    [self startSlowTimer];
    [self fadeIn:_longBreakDimWnds toAlpha:1.0];
    [self fadeIn:_longBreakWnds];
}

- (void)skipLongBreak:(id)sender {
    [self.delegate overlayDidRequestSkipLongBreak];
}

- (void)hideLongBreakAnimated:(BOOL)animated {
    [self restoreSuspendedApplication];
    _longClock = nil;
    _longBreakMsLeft = 0;
    _longArt = nil;
    _longStretchPhase = 0;
    _longStretchTick = 0;
    if (animated && (_longBreakWnds.count || _longBreakDimWnds.count)) {
        [self fadeOut:_longBreakDimWnds];
        [self fadeOut:_longBreakWnds];
    } else {
        [self teardown:_longBreakDimWnds];
        [self teardown:_longBreakWnds];
    }
    [self stopTimersIfIdle];
    [EBAssets.shared purgePersonage];
}

#pragma mark - Short break

- (void)showShortBreakWithCount:(unsigned)showCount
                      durationMs:(long)durationMs
                      fullscreen:(BOOL)fullscreen
                    windowNearby:(BOOL)windowNearby {
    [self hideShortBreakAnimated:NO];

    NSImage *panel = EBAssets.shared.panel;
    NSImage *titleImage = EBAssets.shared.title;
    if (!panel)
        return;

    _shortBreakClosable = self.canCloseNotifications;
    _shortBreakMsLeft = durationMs;

    // Exercise and phrasing are chosen once per short break, as in the original.
    EBExercise exercise = self.forcedExercise != EBExerciseNone
                             ? self.forcedExercise
                             : [EBExercisePicker pickAfter:EBExerciseNone windowNearby:windowNearby];
    NSString *text = [EBExercisePicker textFor:exercise line:[EBExercisePicker pickLineFor:exercise]];

    // On specific break counts an aside replaces the exercise text.
    NSString *milestone = [self milestoneTextForCount:showCount];
    if (milestone)
        text = milestone;

    _animation = [[EBExerciseAnimation alloc] initWithExercise:exercise];
    BOOL russian = EBRussianNow();

    for (int d = 0; d < self.displayCount; d++) {
        // The dimming layer sits under everything and covers the whole display. It is what gives
        // the break the "the screen goes quiet" effect the Windows build had, and it is also what
        // swallows clicks aimed at whatever the user was working in.
        NSRect screen = EBDisplay(d).frame;
        EBOverlayWindow *shield = [self makeShieldForDisplay:d];
        [self.shieldWnds addObject:shield];

        NSView *view;
        if (fullscreen) {
            // Full screen mode keeps its content in a transparent full screen window; the dimming
            // comes from the dim layer, so there is no second black background to maintain.
            view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, screen.size.width, screen.size.height)];
        } else {
            view = PanelBackground(panel.size);
        }

        // The original laid the panel out in top-left coordinates (wxWidgets); AppKit measures from
        // the bottom, so the vertical positions are expressed as "distance from the top" and
        // converted once. Getting this wrong put the exercise image on top of the EyeLeo title.
        CGFloat panelHeight = NSHeight(view.frame);
        if (d == 0) {
            // The Windows layout put the title 12pt from the top; the height here is the image's own.
            CGFloat titleTop = 12, titleHeight = titleImage.size.height;
            CGFloat titleBottom = panelHeight - titleTop - titleHeight;

            if (titleImage) {
                NSImageView *title =
                    [[NSImageView alloc] initWithFrame:NSMakeRect(40, titleBottom, titleImage.size.width,
                                                                  titleImage.size.height)];
                title.image = titleImage;
                [view addSubview:title];
            }

            // Everything here is measured from the bottom of the panel, like AppKit. The image sits
            // just below the title; the original started it at 38 from the top, which overlapped the
            // title, and mixing the two coordinate systems put it off the panel.
            CGFloat artTop = titleBottom - 6;
            NSImage *art = _animation.image;

            if (art) {
                // One picture. It used to be two layers here, a head over a torso moving independently,
                // which read as a sliding image; every animated exercise now swaps between drawn frames
                // instead, so the panel only ever has one image to place.
                NSImageView *image =
                    [[NSImageView alloc] initWithFrame:NSMakeRect(18, artTop - art.size.height, art.size.width,
                                                                  art.size.height)];
                image.image = art;
                [view addSubview:image];
                _shortImage = image;
            }

            NSTextField *label = Label(text, 13, NSColor.whiteColor, NSTextAlignmentCenter, NO);
            label.frame = fullscreen ? NSMakeRect(NSWidth(view.frame) / 2 - 260, NSHeight(view.frame) / 2 - 40, 520, 80)
                                    : NSMakeRect(196, panelHeight / 2 - 44, 250, 88);
            [view addSubview:label];

            NSTextField *time = Label(EBTimeLeftText(durationMs, russian, NO), 14, EBAmber(),
                                      NSTextAlignmentCenter, YES);
            time.frame = fullscreen ? NSMakeRect(NSWidth(view.frame) / 2 - 100, NSHeight(view.frame) / 2 - 95, 200, 34)
                                    : NSMakeRect(356, 12, 90, 26);
            [view addSubview:time];
            _shortTime = time;
        }

        if (_shortBreakClosable) {
            EBTapCatcherView *catcher = [[EBTapCatcherView alloc] initWithFrame:view.bounds];
            catcher.controller = self;
            [view addSubview:catcher positioned:NSWindowAbove relativeTo:nil];
        }

        EBOverlayWindow *window = [self windowWithView:view onDisplay:d capturesInput:YES];
        window.alphaValue = 0;
        [self.shortBreakWnds addObject:window];
        [shield orderFrontRegardless];
    }

    if (EBTraceOn() && self.shortBreakWnds.count) {
        NSView *panel = self.shortBreakWnds.firstObject.contentView;
        fprintf(stderr, "[EB] panel %.0fx%.0f, exercise=%d\n", NSWidth(panel.frame), NSHeight(panel.frame),
                (int)exercise);
        for (NSView *sub in panel.subviews)
            fprintf(stderr, "[EB]   %-16s %.0f,%.0f %.0fx%.0f\n", NSStringFromClass(sub.class).UTF8String,
                    NSMinX(sub.frame), NSMinY(sub.frame), NSWidth(sub.frame), NSHeight(sub.frame));
    }

    [self presentCapturingWindows:_shortBreakWnds];
    [self startFastTimer];
    [self fadeIn:self.shieldWnds toAlpha:1.0];
    [self fadeIn:_shortBreakWnds];
}

- (void)shortBreakRightClicked:(id)sender {
    if (_shortBreakClosable)
        [self.delegate overlayDidRequestCloseShortBreak];
}

- (void)hideShortBreakAnimated:(BOOL)animated {
    [self restoreSuspendedApplication];
    _shortImage = nil;
    _shortTime = nil;
    _animation = nil;
    _shortBreakMsLeft = 0;
    _shortBreakClosable = NO;
    if (animated && (_shortBreakWnds.count || _shieldWnds.count)) {
        [self fadeOut:self.shieldWnds];
        [self fadeOut:_shortBreakWnds];
    } else {
        [self teardown:_shieldWnds];
        [self teardown:_shortBreakWnds];
    }
    [self stopTimersIfIdle];
    [EBAssets.shared purgePersonage];
}

#pragma mark - Countdown

- (void)showCountdownWithMsLeft:(long)msLeft onDisplay:(int)display {
    [self hideCountdownAnimated:NO];
    if (EBTraceOn())
        fprintf(stderr, "[EB] countdown shown, %ld ms left, display %d\n", msLeft, display);

    // Same 209x71 footprint as the original skin4.png, drawn dark instead of imaged: that PNG's
    // white border was the window shape mask and shows up as a white outline when drawn.
    NSImage *bubble = EBAssets.shared.bubble;
    if (!bubble)
        return;

    NSView *view = PanelBackground(bubble.size);

    NSImage *leopard = EBAssets.shared.noticeLeopard;
    CGFloat artWidth = 0;
    if (leopard) {
        artWidth = leopard.size.width + 8;
        NSImageView *portrait =
            [[NSImageView alloc] initWithFrame:NSMakeRect(6, (bubble.size.height - leopard.size.height) / 2.0,
                                                           leopard.size.width, leopard.size.height)];
        portrait.image = leopard;
        [view addSubview:portrait];
    }

    CGFloat textLeft = 6 + artWidth;
    CGFloat textWidth = bubble.size.width - textLeft - 10;

    NSTextField *caption = Label(NSLocalizedString(@"notification_wnd_label", @""), 11, NSColor.whiteColor,
                                 NSTextAlignmentCenter, NO);
    caption.frame = NSMakeRect(textLeft, bubble.size.height / 2.0 - 6, textWidth, 16);
    [view addSubview:caption];

    _countdownMsLeft = msLeft;
    NSTextField *time = Label(EBTimeLeftText(msLeft, EBRussianNow(), NO), 13, EBAmber(), NSTextAlignmentCenter,
                              YES);
    time.frame = NSMakeRect(textLeft, bubble.size.height / 2.0 - 28, textWidth, 20);
    [view addSubview:time];
    _countdownTime = time;

    EBOverlayWindow *window = [self windowWithView:view onDisplay:display capturesInput:NO];
    // The bubble sits in the bottom-right corner, as on Windows -- but inside the work area. Against
    // the full display frame it started at y=0, which is where the Dock is: on this machine 60 of the
    // bubble's 71 points sat under the Dock and only the top sliver was visible. A break countdown
    // is the one thing that must never be half hidden.
    [window setFrame:EBBottomRightRect(bubble.size, EBDisplay(display).visibleFrame, 0) display:NO];
    window.alphaValue = 1;
    _countdownWnd = window;
    [window orderFrontRegardless];
    [self startSlowTimer];
}

- (void)updateCountdownMsLeft:(long)msLeft {
    _countdownMsLeft = msLeft;
    _countdownTime.stringValue = EBTimeLeftText(msLeft, EBRussianNow(), NO);
}

- (void)hideCountdownAnimated:(BOOL)animated {
    _countdownTime = nil;
    _countdownMsLeft = 0;
    if (_countdownWnd) {
        [_countdownWnd orderOut:nil];
        _countdownWnd = nil;
    }
    [self stopTimersIfIdle];
}

#pragma mark - Before break

- (void)showBeforeBreakOnDisplay:(int)display {
    [self hideBeforeBreakAnimated:NO];

    NSImage *panel = EBAssets.shared.panel;
    if (!panel)
        return;

    NSView *view = PanelBackground(panel.size);

    NSTextField *text = Label(NSLocalizedString(@"before_pause_text", @""), 15, NSColor.whiteColor,
                              NSTextAlignmentCenter, NO);
    text.frame = NSMakeRect(40, 62, panel.size.width - 80, 66);
    [view addSubview:text];

    NSButton *refuse = FlatButton(NSLocalizedString(@"before_pause_refuse_button", @""), self, @selector(refuse:));
    refuse.frame = NSMakeRect(46, 22, 112, 26);
    [view addSubview:refuse];

    NSButton *postpone =
        FlatButton(NSLocalizedString(@"before_pause_postpone_button", @""), self, @selector(postpone:));
    postpone.frame = NSMakeRect(175, 22, 112, 26);
    [view addSubview:postpone];

    _beforeReadySeconds = EBLongBreakConfirmationSec;
    NSButton *ready = FlatButton(
        [NSString stringWithFormat:NSLocalizedString(@"before_pause_accept_button", @""), _beforeReadySeconds],
        self, @selector(accept:));
    ready.frame = NSMakeRect(304, 22, 112, 26);
    [view addSubview:ready];
    _beforeReadyButton = ready;

    if (EBTraceOn())
        fprintf(stderr, "[EB] before-break dialog shown, ready in %ds\n", _beforeReadySeconds);

    EBOverlayWindow *window = [self windowWithView:view onDisplay:display capturesInput:NO];
    window.alphaValue = 0;
    [_beforeBreakWnds addObject:window];
    [window orderFrontRegardless];
    [self startSlowTimer];
    [self fadeIn:_beforeBreakWnds];
}

- (void)refuse:(id)sender {
    [self.delegate overlayDidRequestRefuse];
}

- (void)postpone:(id)sender {
    [self.delegate overlayDidRequestPostpone];
}

- (void)accept:(id)sender {
    [self.delegate overlayDidRequestAccept];
}

- (void)hideBeforeBreakAnimated:(BOOL)animated {
    _beforeReadyButton = nil;
    _beforeReadySeconds = 0;
    if (animated && _beforeBreakWnds.count)
        [self fadeOut:_beforeBreakWnds];
    else
        [self teardown:_beforeBreakWnds];
    [self stopTimersIfIdle];
}

#pragma mark - Waiting

- (void)showWaiting {
    if (_waitingWnds.count)
        return;

    NSImage *bar = EBAssets.shared.bar;
    if (!bar)
        return;

    for (int d = 0; d < self.displayCount; d++) {
        NSView *view = PanelBackground(bar.size);

        if (d == 0) {
            NSTextField *text = Label(NSLocalizedString(@"waiting_text", @""), 13, NSColor.whiteColor,
                                      NSTextAlignmentCenter, NO);
            text.frame = NSMakeRect(0, (bar.size.height - 30) / 2.0, bar.size.width, 30);
            [view addSubview:text];
        }

        EBOverlayWindow *window = [self windowWithView:view onDisplay:d capturesInput:NO];
        window.alphaValue = 0;
        [_waitingWnds addObject:window];
        [window orderFrontRegardless];
    }
    [self fadeIn:_waitingWnds];
}

- (void)hideWaitingAnimated:(BOOL)animated {
    if (animated && _waitingWnds.count)
        [self fadeOut:_waitingWnds];
    else
        [self teardown:_waitingWnds];
}

- (void)showNotificationWithText:(NSString *)text seconds:(NSTimeInterval)seconds {
    [self hideNotification];

    NSImage *bubble = EBAssets.shared.bubble;
    if (!bubble || text.length == 0)
        return;

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, bubble.size.width * 1.6, bubble.size.height * 1.6)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = EBPanelColor().CGColor;
    view.layer.cornerRadius = kPanelRadius;

    NSTextField *label = Label(text, 11, NSColor.whiteColor, NSTextAlignmentCenter, NO);
    label.frame = NSMakeRect(10, 10, NSWidth(view.frame) - 20, NSHeight(view.frame) - 20);
    label.alignment = NSTextAlignmentCenter;
    [view addSubview:label];

    EBOverlayWindow *window = [self windowWithView:view onDisplay:0 capturesInput:NO];
    [window setFrame:EBBottomRightRect(NSMakeSize(NSWidth(view.frame), NSHeight(view.frame)),
                                      NSScreen.mainScreen.visibleFrame, 20)
          display:NO];
    window.alphaValue = 0;
    self.notificationWindow = window;
    [window orderFrontRegardless];
    [self fadeIn:@[ window ]];

    __weak EBOverlayController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf hideNotification];
    });
}

- (void)hideNotification {
    if (self.notificationWindow) {
        [self.notificationWindow orderOut:nil];
        self.notificationWindow = nil;
    }
}

#pragma mark - Hydration reminder

// Same bubble, same corner, same 209x71 footprint as the long-break countdown, so the two read as
// one family of notices. What differs is the payload: a drawn glass instead of the leopard, and a
// countdown to dismissal rather than a time remaining until a break.
- (void)showWaterReminderWithVolumeMl:(int)ml seconds:(NSTimeInterval)seconds {
    [self hideWaterReminder];

    NSImage *bubble = EBAssets.shared.bubble;
    if (!bubble)
        return;

    NSView *view = PanelBackground(bubble.size);

    CGFloat artW = 71, artX = 6;
    CGFloat artY = (bubble.size.height - 44) / 2.0;
    // The vessel is a picture rather than the drawn glass this replaced. Each drink has its own glass,
    // so a tea reminder and the water reminder are distinguishable at a glance, and both are lit the
    // same way. If the bitmap is missing the space is left empty rather than showing a broken image.
    NSImage *glass = [EBAssets.shared drinkImageNamed:@"water"];
    if (glass) {
        NSImageView *art = [[NSImageView alloc] initWithFrame:NSMakeRect(artX, artY, artW, 44)];
        art.image = glass;
        [view addSubview:art];
    }

    CGFloat textLeft = artX + artW + 8;
    CGFloat textWidth = bubble.size.width - textLeft - 10;

    // The text column is only about 114 pt wide, so the caption carries just the instruction. The
    // portion size would not fit next to it, and it belongs in the settings anyway.
    NSTextField *caption = Label(NSLocalizedString(@"water_reminder_label", @""), 11, NSColor.whiteColor,
                                 NSTextAlignmentCenter, NO);
    caption.frame = NSMakeRect(textLeft, bubble.size.height / 2.0 - 6, textWidth, 16);
    [view addSubview:caption];

    NSTextField *time = Label(EBTimeLeftText((long)(seconds * 1000), EBRussianNow(), NO), 13, EBAmber(),
                              NSTextAlignmentCenter, YES);
    time.frame = NSMakeRect(textLeft, bubble.size.height / 2.0 - 28, textWidth, 20);
    [view addSubview:time];
    // The number counts down on the shared 1 s timer, the same way the long-break bubble does.
    // Hiding the bubble from a dispatch_after alone left the number frozen at its initial value.
    _waterTime = time;
    _waterMsLeft = (long)(seconds * 1000);

    EBOverlayWindow *window = [self windowWithView:view onDisplay:0 capturesInput:NO];
    [window setFrame:EBBottomRightRect(bubble.size, NSScreen.mainScreen.visibleFrame, 0) display:NO];
    window.alphaValue = 1;
    self.waterWnd = window;
    [window orderFrontRegardless];
    [self startSlowTimer];

    if (EBTraceOn())
        fprintf(stderr, "[EB] water reminder shown, %d ml, dismiss in %.0fs\n", ml, seconds);

    // No dispatch_after: the 1 s timer above reaches zero and hides the bubble, which is what keeps
    // the number and the dismissal on one clock instead of two that can disagree.
}

// The long-break countdown owns the same corner, and the two timers are unrelated: a 50 minute break
// interval and a 30 minute water interval coincide often enough that one will replace the other.
// Declining rather than stacking keeps the countdown visible, which is the notice that matters more.
//
// The brewing bubble sits in that corner as well, and a short break covers the screen. Neither moves for
// the water: the countdown would be replaced by a bottle of water, and a reminder shown behind something
// else is a reminder not shown at all.
- (BOOL)showWaterReminderDeferred {
    if (self.countdownVisible)
        return YES;
    if (self.teaWnd)
        return YES;
    return _shortBreakMsLeft > 0 || _shortBreakWnds.count > 0;
}

- (void)hideWaterReminder {
    if (self.waterWnd) {
        [self.waterWnd orderOut:nil];
        self.waterWnd = nil;
    }
    _waterTime = nil;
    _waterMsLeft = 0;
}

// The brewing bubble. Built like the hydration one, from the same skin4 panel in the same corner, but the
// vessel is the tea's own glass and there is no dismissal countdown: a steep lasts as long as it lasts,
// and the number is how much of it is left.
- (void)showTeaReminderWithCaption:(NSString *)caption
                             image:(NSImage *)glass
                            msLeft:(long)msLeft
                   autoDismissMs:(long)autoDismissMs {
    [self hideTeaReminder];

    NSImage *bubble = EBAssets.shared.bubble;
    if (!bubble)
        return;

    NSView *view = PanelBackground(bubble.size);
    CGFloat artW = 71, artX = 6;
    CGFloat artY = (bubble.size.height - 44) / 2.0;
    if (glass) {
        NSImageView *art = [[NSImageView alloc] initWithFrame:NSMakeRect(artX, artY, artW, 44)];
        art.image = glass;
        [view addSubview:art];
    }
    CGFloat textLeft = artX + artW + 8;
    CGFloat textWidth = bubble.size.width - textLeft - 10;

    // Two lines: what is brewing and which steep it is, then the time left on this one. The caption is
    // longer than the water one's single instruction, so it gets the room it needs.
    NSTextField *cap = Label(caption, 11, NSColor.whiteColor, NSTextAlignmentCenter, NO);
    cap.frame = NSMakeRect(textLeft, bubble.size.height / 2.0 + 6, textWidth, 28);
    [view addSubview:cap];
    self.teaCaption = cap;

    NSTextField *time = Label(EBTimeLeftText(msLeft, EBRussianNow(), NO), 13, EBAmber(),
                              NSTextAlignmentCenter, YES);
    time.frame = NSMakeRect(textLeft, bubble.size.height / 2.0 - 14, textWidth, 20);
    [view addSubview:time];
    self.teaTime = time;

    EBOverlayWindow *window = [self windowWithView:view onDisplay:0 capturesInput:NO];
    [window setFrame:EBBottomRightRect(bubble.size, NSScreen.mainScreen.visibleFrame, 0) display:NO];
    window.alphaValue = 1;
    self.teaWnd = window;
    [window orderFrontRegardless];

    // Take the token before scheduling and compare it when the timer fires. Without the check, a bubble
    // already replaced by the next steep would be taken down by the previous notice's timer.
    self.teaDismissToken++;
    if (autoDismissMs > 0) {
        NSUInteger token = self.teaDismissToken;
        __weak EBOverlayController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)autoDismissMs * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
                           if (weakSelf && weakSelf.teaDismissToken == token)
                               [weakSelf hideTeaReminder];
                       });
    }

    if (EBTraceOn())
        fprintf(stderr, "[EB] tea bubble up: \"%s\", %ld ms left\n", caption.UTF8String, msLeft);
}

// Refreshes in place rather than rebuilding: a rebuild would put the bubble behind whatever was drawn
// over it, and the steep can last several minutes.
- (void)updateTeaReminderCaption:(NSString *)caption msLeft:(long)msLeft {
    if (!self.teaWnd)
        return;
    self.teaCaption.stringValue = caption;
    self.teaTime.stringValue = EBTimeLeftText(MAX(msLeft, 0), EBRussianNow(), NO);
}

- (void)hideTeaReminder {
    // Bumped so a pending auto-dismiss for the bubble being taken down now does nothing.
    self.teaDismissToken++;
    if (self.teaWnd) {
        [self.teaWnd orderOut:nil];
        self.teaWnd = nil;
    }
    _teaCaption = nil;
    _teaTime = nil;
    if (EBTraceOn())
        fprintf(stderr, "[EB] tea bubble hidden\n");
}

- (BOOL)teaReminderVisible {
    return self.teaWnd != nil;
}

- (void)hideAll {
    [self restoreSuspendedApplication];
    [self hideNotification];
    [self hideWaterReminder];
    [self hideTeaReminder];
    [self teardown:_longBreakWnds];
    [self teardown:_longBreakDimWnds];
    [self teardown:_shortBreakWnds];
    [self teardown:_shieldWnds];
    [self teardown:_beforeBreakWnds];
    [self teardown:_waitingWnds];
    [_countdownWnd orderOut:nil];
    _countdownWnd = nil;
    _countdownTime = nil;
    _countdownMsLeft = 0;
    _longClock = nil;
    _longBreakMsLeft = 0;
    _longArt = nil;
    _longStretchPhase = 0;
    _longStretchTick = 0;
    _shortImage = nil;
    _shortTime = nil;
    _shortBreakMsLeft = 0;
    _shortBreakClosable = NO;
    _beforeReadyButton = nil;
    _beforeReadySeconds = 0;
    _animation = nil;
    [self stopFastTimer];
    [self stopSlowTimer];
    [self stopFade];
    [EBAssets.shared purgePersonage];
}

#pragma mark - Fades

- (void)restoreFocusIfHeld {
    if (self.suspendedApplication)
        [self restoreSuspendedApplication];
}

// Full screen dimming layer. A semi-transparent black fill, which is what the Windows build did with
// SetTransparent() over a black background. No backdrop blur: both breaks now dim identically.
- (EBOverlayWindow *)makeShieldForDisplay:(int)display {
    NSRect screen = EBDisplay(display).frame;
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, screen.size.width, screen.size.height)];


    // The dim itself. This is what the Windows build did with SetTransparent() over black, and it
    // is the part that makes the rest of the screen visibly go quiet.
    NSView *dim = [[NSView alloc] initWithFrame:root.frame];
    dim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    dim.wantsLayer = YES;
    dim.layer.backgroundColor = [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:kBreakDim].CGColor;
    [root addSubview:dim];

    EBOverlayWindow *shield = [self windowWithView:root onDisplay:display capturesInput:NO];
    // One level below the content window. Within a single level, clicking a window brings it to the
    // front of that level, so clicking the dimming layer used to push the exercise panel behind it.
    // Separate levels make the order absolute rather than dependent on what was clicked, and the
    // layer is still above ordinary application windows, so it keeps swallowing their clicks.
    shield.level = NSFloatingWindowLevel - 1;
    [shield setFrame:screen display:NO];
    shield.alphaValue = 0;
    if (EBTraceOn())
        fprintf(stderr, "[EB] dim layer: %.0fx%.0f dim=%.2f blur=off\n", screen.size.width,
                screen.size.height, kBreakDim);
    return shield;
}

// Whether the one-second clock still has something left to advance. The tick asks this at its end and
// the hide paths ask it before switching the clock off, and they have to ask it the same way. They did
// not: this list was the clock's own, while stopTimersIfIdle's was shorter and left out the hydration
// reminder and the before-break countdown. So a reminder whose bubble was still on screen had its clock
// switched off underneath it, and the last seconds stayed frozen on screen for good, with nothing left
// to take the bubble down.
- (BOOL)slowTickHasWork {
    return self.countdownTime != nil || self.longClock != nil || self.beforeReadyButton != nil ||
           self.waterTime != nil;
}

- (void)stopTimersIfIdle {
    if (_shortBreakMsLeft <= 0 && !_beforeReadyButton)
        [self stopFastTimer];
    if (![self slowTickHasWork])
        [self stopSlowTimer];
}

// 60 steps a second is smooth enough for a third of a second and costs almost nothing, because the
// timer only exists while at least one fade is running.
static const NSTimeInterval kFadeStep = 1.0 / 60.0;

- (void)fadeWindows:(NSArray<EBOverlayWindow *> *)windows
                 to:(CGFloat)target
           duration:(NSTimeInterval)duration
       hideWhenDone:(BOOL)hide {
    if (windows.count == 0 || duration <= 0)
        return;

    EBFadeJob *job = [[EBFadeJob alloc] init];
    job.windows = windows;
    job.fromAlpha = windows.firstObject.alphaValue;
    job.toAlpha = target;
    job.duration = duration;
    job.hideWhenDone = hide;
    [self.fadeJobs addObject:job];

    if (!self.fadeTimer) {
        __weak EBOverlayController *weakSelf = self;
        self.fadeTimer = [self makeTimerWithInterval:kFadeStep
                                             handler:^{
                                                 [weakSelf stepFades];
                                             }];
    }
}

- (void)stepFades {
    NSMutableArray<EBOverlayWindow *> *toRetire = [NSMutableArray array];

    for (EBFadeJob *job in self.fadeJobs) {
        job.elapsed += kFadeStep;
        double t = job.elapsed / MAX(job.duration, 0.0001);
        if (t > 1.0)
            t = 1.0;

        // ease in/out, close enough to the original's feel
        CGFloat eased = (CGFloat)(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2);
        CGFloat alpha = job.fromAlpha + (job.toAlpha - job.fromAlpha) * eased;
        for (EBOverlayWindow *w in job.windows)
            w.alphaValue = alpha;

        if (t < 1.0)
            continue;
        if (job.hideWhenDone)
            [toRetire addObjectsFromArray:job.windows];
    }

    NSArray<EBFadeJob *> *running = [self.fadeJobs filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(EBFadeJob *job, id _) {
            return job.elapsed < job.duration;
        }]];
    self.fadeJobs = [running mutableCopy];

    if (toRetire.count)
        [self retireWindows:toRetire];

    if (self.fadeJobs.count == 0 && self.fadeTimer) {
        dispatch_source_cancel(self.fadeTimer);
        self.fadeTimer = nil;
    }
}

- (void)stopFade {
    if (self.fadeTimer) {
        dispatch_source_cancel(self.fadeTimer);
        self.fadeTimer = nil;
    }
    self.fadeJobs = [NSMutableArray array];
}

- (void)fadeIn:(NSArray<EBOverlayWindow *> *)windows {
    [self fadeWindows:windows to:kOverlayAlpha duration:kFadeIn hideWhenDone:NO];
}

- (void)fadeIn:(NSArray<EBOverlayWindow *> *)windows toAlpha:(CGFloat)alpha {
    // The dimming layers go to full window opacity: the transparency that darkens the screen lives
    // in the layer's own background, so fading the window to 82% would dim it twice and lighten it.
    [self fadeWindows:windows to:alpha duration:kFadeIn hideWhenDone:NO];
}

- (void)fadeOut:(NSArray<EBOverlayWindow *> *)windows {
    [self fadeWindows:windows to:0 duration:kFadeOut hideWhenDone:YES];
}

#pragma mark - Milestones

// Port of the specialMessages table in minipause_wnd.cpp: on these short-break counts an aside
// replaces the exercise text.
- (NSString *)milestoneTextForCount:(unsigned)count {
    static const unsigned counts[] = { 30, 80, 120, 150, 400, 600, 1000, 1400 };
    static NSString *const keys[] = {
        @"mini_pause_text_settings",  @"mini_pause_text_donate",         @"mini_pause_text_tell_friend",
        @"mini_pause_text_posture",   @"mini_pause_text_check_eyeleo",   @"mini_pause_text_donate",
        @"mini_pause_text_donate",    @"mini_pause_text_donate",
    };
    for (NSUInteger i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
        if (counts[i] == count)
            return NSLocalizedString(keys[i], @"short break milestone");
    }
    return nil;
}

@end

@implementation EBTapCatcherView

- (void)rightMouseDown:(NSEvent *)event {
    [self.controller shortBreakRightClicked:self];
}

@end