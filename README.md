# EyeLeo for macOS

A native macOS rewrite of the EyeLeo tray application (Windows/C++/wxWidgets, CC BY-NC 4.0):
it counts down to a long break, prompts you about it, and interrupts with short eye exercises.
Same state machine, same features, same wording, rebuilt on AppKit for one laptop.

Runs on macOS 26.0 or newer, Apple silicon. Menu-bar only: no Dock tile, no app switcher entry.

## Build and run

```
make            # build/EyeLeo.app, ad-hoc signed and sandboxed
make test       # core state machine unit tests, no window server needed
make run        # build, then launch
make smoke      # end-to-end: unit tests, localization, menu bar item, and both break cycles
make measure    # size, cold start, footprint, and a security summary
```

Requires only the Xcode command line tools. There are no third-party dependencies: no CocoaPods,
no Swift package, no wxWidgets. pugixml is not needed either, because the original only used it to
read two small XML files.

Move `build/EyeLeo.app` to `/Applications` before enabling **Open at login**, otherwise
LaunchServices cannot register a reliable login item.

## Why Objective-C and not Swift

The brief asked for the smallest possible memory footprint, and that is decided by the language,
not by micro-optimisation. Swift puts `libswiftCore` and its runtime metadata in every process;
SwiftUI adds several megabytes more of its own. Neither is recoverable later. Objective-C with
AppKit is the floor for a menu-bar utility: 200 KB of binary and no runtime to drag in.

SwiftUI is not used at all. The settings window is plain AppKit views in an `NSStackView`.

## Measured results

From `make measure` on an M2 MacBook Air:

| Metric | Measured | Budget |
| --- | --- | --- |
| Binary | 202 KB | 3 MB |
| Bundle with assets | 1.7 MB | — |
| Cold start to app ready | ~140 ms | 500 ms |
| `phys_footprint` idle | 10 MB | 12 MB |
| `phys_footprint` during a break | 13 MB | 25 MB |

The app's own share of startup is about 75 ms; the rest of the measured window is process creation.
Overlays are created on demand and destroyed when a break ends, so an idle EyeLeo holds no windows
and no decoded images.

How the footprint stays low:

- one `dispatch_source` per concern (state machine, 100 ms overlay tick, 1 s overlay tick, fade)
  rather than a timer per window as in the original;
- monotonic `clock_gettime` instead of allocating an `NSDate` per tick;
- countdown labels are formatted with `snprintf` and only turned into an `NSString` when the visible
  text actually changes, once a second rather than ten times;
- decoded images are released when a break ends;
- `-Os`, `-fvisibility=hidden`, `-Wl,-dead_strip`, stripped.

## Security

The application asks the operating system for **nothing**. No permission dialog can appear, because
no API that triggers one is called.

- App Sandbox, and the only entitlement in `entitlements.plist` is
  `com.apple.security.app-sandbox`. No network client, no file access outside the container.
- No networking symbols are linked at all (`make measure` checks this), so it cannot phone home even
  if a future change tried to.
- The original hooked the mouse and keyboard globally. On macOS that would mean an Accessibility or
  Input Monitoring grant. Instead, activity is read with
  `CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, ...)`, which
  reports session-wide input activity with no grant. Fullscreen detection uses
  `CGWindowListCopyWindowInfo`, which exposes window bounds without Screen Recording.
- Notifications are drawn as the app's own bubble rather than through `UNUserNotificationCenter`,
  which would have required the Notifications grant.
- The only thing written to disk is `settings.xml` in the app container, via `CFPreferences`. There
  is no log file: the original opened and closed `log.txt` on every single message, which was both
  slow and a quiet record of when you were working.
- Ad-hoc signed (`codesign -s -`). `codesign --verify --strict` passes. Not notarised, which is fine
  for a private build but means Gatekeeper will object if you move it to another Mac.

`make measure` re-checks the entitlements and the networking symbols, so a future change that
widens the surface fails loudly in the report rather than silently.

## What the app does

Full parity with EyeLeo 1.3.6:

- menu bar with Settings, *Disable breaks for* (1 hour / 3 hours), *Take a long break now*,
  *Open at login*, Quit;
- a state machine ported one-for-one from `EyeApp::ExecuteTask`, including the six-second "are you
  ready" beat before a long break, the eight-minute inactivity auto-relax, the fullscreen-blocked
  retry that gives up after five minutes, and resuming a countdown across a restart if the machine
  was away for less than thirty minutes;
- long break: full screen, black, leopard, a rotating tip, a clock that always shows seconds, and a
  Skip button that strict mode removes;
- short break: the original `skin2` panel with a random exercise, an animation, a countdown, an
  optional fullscreen mode, and dismissal by right click when that setting is on;
- the seven exercises with the "never twice in a row" rule and the original's animation timings,
  including the two that never animate;
- the milestone asides at short-break counts 30, 80, 120, 150, 400, 600, 1000 and 1400;
- pause and resume, single instance, statistics;
- English and Russian, with correct Russian plurals.

## The two-stage warning before a long break

The notice and the offer to postpone are separate beats, ~24 seconds apart in real time:

1. The bottom-right bubble appears when `timeLeftToBigPause` drops to `warningInterval`, 30 seconds by
   default, and counts down. The remaining time is snapped to exactly `warningInterval` at that point
   so the bubble always starts on a round number.
2. The centred dialog with the three buttons appears when `timeLeftToBigPause` drops to
   `EBLongBreakConfirmationSec`, 6 seconds, and counts down 6 to 0 before it accepts a click.

This is what the Windows original did: the bubble starts 30 seconds out and is still ticking with 5
seconds left when the dialog opens over it.

If you ever see the two arrive together, you are running with `EYELEO_FAST_MODE=1`. That multiplies
elapsed time by 8 for the long break, so the 24-second gap collapses to about 3 seconds while the
dialog's own 6-second counter still runs in real seconds. The thresholds are not what changed.

`warningInterval` has a floor of 20 seconds, the shortest delay the settings popup offers, enforced in
`clampSettings`. The popup only offers 20/30/60/90 seconds, so the floor exists for a hand-edited or
corrupted settings file: below 6 seconds the notice would have no time to count down at all.

## What was added in the port

The original had seven exercises and that is still true of exercises 1..7: same ids, same wording in
both languages, same artwork. Nothing was removed or reworded. Three things were added.

**Three exercises, ids 8, 9 and 10.** "Close your eyes fully and gently, ten times" holds the closed-eyes
frame longer than the open one, because the point is a complete unhurried blink rather than a fast one.
"Raise and lower your shoulders" is a bust of the leopard with the shoulders up and down, and "cover
your eyes with both paws" alternates between open eyes and eyes behind both paws. All three are drawn
frames like every other exercise, and each has five phrasings per language.

**Every animated exercise now swaps real artwork.** This is the biggest reversal in the port. Shoulders
were first animated in code: two composited layers, head and torso, moved by `CATransform3D`, on the
reasoning that a single generated pair would come out inconsistent and make the rosettes crawl across
the fur. That reasoning was right about the failure and wrong about the cure. The two layers produced a
sliding picture rather than a movement, and the mismatch between a rotating head and a lifting torso
read as a bad composite rather than as a body.

The cure was in the tool, not in the animation. `tools/mkframes.m` aligns every generated frame of a
set on measurable anchors inside the artwork, so a frame pair is registered by construction instead of by
hope; `CATransform3D` is now the identity for every exercise and `transform` exists only to keep the
header honest. The rosettes do not crawl because both frames were measured against the same anchor.

`tools/mkframes.m` has five modes, `full`, `bust`, `eyes`, `shoulders` and `cups`. It removes the flat
background by keying magenta, rejects stray pixels left inside the keyed region, resamples with an area
average, aligns the frames of a set, and refuses to write anything whose size disagrees with its sibling
or whose transparency is not real. It also writes `preview_*.png`, rendered on the panel's own dark
background: judging a small figure by eye in this environment was repeatedly misleading, and several
rounds of "the asset looks fine, the panel looks wrong" came down to something only visible against the
background it will actually sit on.

The bust for the shoulder exercise is cut from the same artwork as the long break rather than
regenerated, so the two share a face. It is 276x220 px, shown at 138x110 pt. The generated frames carry no
DPI metadata, so `EBAssets` halves them at load: everything from `EBFrameShouldersUp` up is 2× the
original's 1× frames, and the seven inherited frames are 1×. Getting that wrong in either direction
either doubles the picture or halves it to the size of a thumbnail.

**The long break moves through real frames.** It was the one screen with no motion at all. It cycles a
full-body figure through four poses, standing, leaning left, standing, leaning right, two seconds each,
so one full sway takes eight seconds. The four are generated by the same tool as the exercises and
aligned on the same anchors.

Sizing them needed more than a bounding box. The leaning poses throw a raised arm outside the figure, so
measuring the bounding box made the leaning frames larger than the standing one, and scaling all four by
the bounding box made the standing figure shrink in the middle of its own cycle. The tool normalises on
the width of the calf instead, which is the one thing that stays put in every pose. The figure ends up at
155x340 pt on a 1470x956 display.

Generating the full body was attempted earlier and produced a quadruped, which is why the first version
of this screen reused the bust and swayed it in code. The frames exist now, so the sway is drawn.

**A hydration reminder.** Same `skin4` bubble, same bottom-right corner, same 209x71 footprint as the
long-break countdown, and now the same for tea, with a vessel in place of the portrait. It is a drawn
image rather than code-drawn glass: seven cups, keyed through the `cups` mode of `tools/mkframes.m`,
which keeps their real alpha instead of cutting it against the flat background the artwork was drawn on.
Advisory only: it never takes input and never captures the keyboard.

The values behind it. The 15-20 minute figure you will find in occupational health guidance is for
work in heat, where sweat loss is real; it does not transfer to sitting at a desk. The relevant study
for sedentary office workers (PMC8998380) found a baseline of about 763 ml/day and measured its
questionnaire against 30-60 minute intervals, not 15-20. So the default is 30 minutes / 100 ml: still
200 ml an hour, but delivered as two sips rather than one 200 ml glass, which is also what NIOSH means
by preferring shorter intervals over large amounts infrequently.

The reminder counts working time only: it is decremented inside the idle branch, so a break pauses it
rather than letting reminders pile up against someone who was away from the desk. It also does not fire
while the app is in auto-relax, which after eight idle minutes is where a machine nobody is sitting at
sits. Both are deliberate, and both are worth knowing about when testing: a fifteen minute test on an
untouched machine will not show a reminder, because auto-relax arrives at minute eight.

The interval list is 15/20/25/30/45/60/90/120 and the portion list 50-250 ml. The worst combination
those two lists allow is 15 min x 250 ml = 1000 ml/hour, against the 1414 ml/hour ceiling above which
NIOSH warns about water intoxication. No settings combination can breach it, and a test asserts it.

**A tea timer, with water as one more kind of it.** The same bubble, the same menu, the same countdown,
so water is the tea menu's first entry rather than a second feature. Six teas ship with the usual steep
times, white and green 10-15-20-25-30, oolong 15-25-35-45-60-75, black 20-30-40-50-60-70, puer
20-30-40-50-60-70-80-90 and herbal 300-360-420-480, all in seconds. They live in `tea.conf` next to
`settings.xml`, which is edited through the app rather than by hand in the container.

Steeping is deliberately manual. An automatic timer cannot know when you have actually poured the water
off the leaves, so a countdown would be wrong for anyone who looks away, and the fix for that is a
button rather than a smarter guess. The menu item counts down to the next steep, the bubble hides once a
steep has been taken, and after the last one the bubble says the tea is ready and closes itself after
five seconds. Tooltips on the menu list each kind's whole scheme at once, so choosing between them does
not require starting one.

Two things the timer does not do. It does not stop for a break, because a steep that pauses while the
user is looking at a screen is a bug, not a courtesy; and it does not remember the chosen tea on the next
launch, so the tick mark is about this session only. Both were choices, not omissions.

## Reading settings written by other tools

`PutBool` stores 0/1, so the app's own files are numbers where a flag is expected. That meant
`ReadBool`, which went through the number reader, silently ignored any `<true/>` or `<false/>` — and
that is exactly how plists are written by `defaults`, `PlistBuddy`, or anything that edits the file as
XML. The symptom was a checkbox that turned itself back on. Both encodings are accepted now, and a
test writes a plist with real booleans and checks that `<false/>` is read as false rather than as
absent.

Related: writing the plist file directly, even with `plistlib`, changes nothing observable, because
`CFPreferencesCopyAppValue` is served from `cfprefsd`'s cache. See the gotchas section.

## Taking the keyboard and mouse during a break

You asked for the break to actually stop you working: dim the screen and take the keyboard and mouse
so the user really rests. That is implemented, with one honest caveat.

**Mouse — fully handled and verified.** A full-screen transparent window is ordered above every
other application for the duration of a break, above the panel itself. Clicks and scrolls anywhere on
the screen land on our window and go no further. For the long break the overlay already covers the
screen; for the short break this separate shield is what stops you carrying on around a 461×156 panel.

**Keyboard — verified working.** A background-only (`LSUIElement`) app is never granted key focus:
the frontmost application simply stays whatever it was, so keystrokes keep reaching your editor and
the break would be decorative. The only public route is to raise the activation policy to `Regular`
for the duration of the break, activate, and make the overlay key — which is what the code does, and
is the same fight the original had with `BigPauseWindow::_restoreFocus`. The cost is a Dock icon and
an app menu while the break is up; both disappear afterwards.

Measured, from `EYELEO_DEBUG=1`:

```
[EB] capture input: appActive=0 key=0 windows=2
[EB] capture settled: appActive=1 key=1 main=0 front=local.eyeleo.EyeLeo
[EB] restore focus to "NyaTerm"
```

The first line is the moment of the call, before the system has finished activating; the second is
400 ms later and shows the app frontmost with the overlay as key window, which is what actually
diverts the keyboard. The third is focus going back to whatever you were using. A second break then
behaves identically, so nothing leaks between cycles.

The alternative — an `CGEventTap` that swallows key events — would guarantee the block, but it
requires the Accessibility permission, which would break the "asks for nothing" property above. That
trade was not taken.

## Traps worth knowing about

- **A generated icon can be silently blank.** `mkicon.m` scaled its bitmap context CTM by the pixel
  size while the drawing code used pixel coordinates, so every glyph landed far outside the canvas.
  The PNGs were valid, loaded fine, reported `isTemplate = YES` and drew *nothing* — which is why the
  first version of the status item was invisible even though `isVisible` was `YES` and the button was
  correctly positioned. `mkicon.m` now refuses to write a glyph with no opaque pixels.
- **Menu bar images must be 22pt, not 44.** `NSStatusBar.thickness` on this machine is 22 pt, and
  `NSImage` reads a bare PNG as pixels *equals* points. A single 44x44 asset therefore becomes a 44pt
  image, and the status item button collapses to `38x0`. Both scales must ship, `StatusActive.png` at
  22x22 and `StatusActive@2x.png` at 44x44, loaded with `+[NSImage imageNamed:]` to resolve the `@2x`.
- **AppKit measures from the bottom.** The Windows layout used top-left coordinates, so porting it
  literally put the exercise image at `y = -70`, hanging off the bottom of the panel and over the
  title. The panel layout is now expressed once in AppKit coordinates.
- **Probe the right window.** The short break puts a click shield in the window list *before* the
  panel, and the shield is deliberately never key. Checking `firstObject.isKeyWindow` reports a false
  negative; the panel is the one that captures input.
- **Timers must not share a priority chain.** One dispatch timer driving every overlay, ordered by
  importance, lets a 1-second countdown swallow a 100-millisecond one — the before-break dialog then
  never counts down. Two timers, one per rate.
- **`NSAnimationContext` is not reliable here.** A window alpha fade through the `animator` proxy does
  not complete for a non-active `LSUIElement` app, so the completion handler never ran and the short
  break never dismissed itself. The fade is stepped by a timer of our own instead.

## Running it and looking at it

```
make                      # build and sign build/EyeLeo.app
open build/EyeLeo.app     # menu bar only, no Dock icon
```

To see one specific exercise rather than waiting for it to come up in a draw of ten:

```
EYELEO_DEBUG=1 EYELEO_FAST_MODE=1 \
EYELEO_TEST_INTERVAL_MIN=1 EYELEO_TEST_ONLY=short EYELEO_TEST_EXERCISE=9 \
  ./build/EyeLeo.app/Contents/MacOS/EyeLeo
```

Running the binary directly rather than through `open` is deliberate: it is how `EYELEO_DEBUG` reaches
it. In debug mode the trace prints the panel layout, which is how the artwork placement is checked: the
picture, the title and the countdown are each traced with their frames, and a wrong size there means the
exercise opened on a frame of the wrong size.

The hydration reminder is the one thing that cannot be reached quickly otherwise, since its interval
bottoms out at fifteen minutes:

```
EYELEO_DEBUG=1 EYELEO_TEST_WATER_SEC=6 ./build/EyeLeo.app/Contents/MacOS/EyeLeo
```

## Debugging and test hooks

All off unless the environment variable is set. `EYELEO_DEBUG` also traces every state transition.

| Variable | Effect |
| --- | --- |
| `EYELEO_DEBUG=1` | state machine trace, startup stage timings, overlay traces |
| `EYELEO_FAST_MODE=1` | accelerates timers up to 8×, the port of `EyeApp::_fastMode` |
| `EYELEO_TEST_INTERVAL_MIN=N` | overrides both break intervals to N minutes |
| `EYELEO_TEST_ONLY=short\|long` | enables only one kind of break |
| `EYELEO_TEST_EXERCISE=N` | forces exercise N on the next short break |
| `EYELEO_TEST_OPEN_SETTINGS=1` | opens the settings window at launch |
| `EYELEO_TEST_WATER_SEC=N` | fires the hydration reminder after N seconds |
| `EYELEO_TEST_TEA_SEC=N` | fires the tea bubble after N seconds |
| `EYELEO_TEST_TEA_KIND=name` | which tea or water the tea bubble shows |

The overrides beat stored settings on purpose: `cfprefsd` caches preferences per app, so editing the
container plist from a shell is not reliably visible to the sandboxed app. That is why they exist
rather than a plist-editing step in the runbook.

While any `EYELEO_TEST_*` override is active the app sets `persistenceSuspended`, and `saveSettings`
becomes a no-op. Without it an accelerated run rewrites the break intervals into the real settings on
every break, which is exactly the kind of damage a test should not do.

## Dimming during a break

Every break is built the same way: a full screen **dim layer** underneath, and a fully opaque content
window on top.

Both breaks dim the screen identically: black at alpha **0.78**, no blur. The value was arrived at by
looking at the result — 0.62 and then 0.90 were both reported as unreadably dark, 0.78 as right — and
the short break was then aligned with it.

There is no backdrop blur. It was tried and removed: `NSVisualEffectMaterialHUDWindow` is itself a
dark material, so it flattened everything behind the overlay before the dim layer was even applied,
and the light variant still read as heavier than the long break's plain dim. Leaving a checkbox
that did nothing would have been worse, so the setting is gone rather than dead.

Only the dim layer is see-through. The exercise image, the text, the clock and the buttons fade to
full opacity — the Windows build animated its windows to 210/255, which on macOS would have dimmed
the content along with the desktop. The dim layer is also what swallows clicks aimed at whatever you
were working in.

The dimming layer sits **one window level below** the content (`NSFloatingWindowLevel - 1` against
`NSFloatingWindowLevel`). Within a single level, clicking a window brings it to the front of that
level, so a click anywhere outside the exercise panel used to push the panel behind the dimming
layer. Separate levels make the order absolute instead of dependent on what was clicked, and the
layer is still above ordinary application windows so it keeps swallowing their clicks.

Buttons get an explicit opaque `bezelColor`. On a transparent window over a dimmed desktop the stock
rounded bezel is drawn with its own translucency and reads as see-through, which made the Skip button
look washed out next to the fully opaque text and artwork.

The panels are drawn rather than imaged. The `skin2/skin3/skin4` PNGs from the Windows build have a
solid white border which was the *window shape* mask (`SetShape(region(bitmap, *wxWHITE))`) and was
never meant to be drawn; drawing them on macOS produced a white outline around every panel. They are
still used for their sizes, and the dark rounded background is drawn instead.

## Two gotchas worth knowing about

**The countdown bubble must be placed against `visibleFrame`, not `frame`.** The long-break notice
used to be positioned against the full display, so it started at y=0, which is where the Dock is. On a
60 pt Dock, 60 of its 71 points were under the panel and only the top sliver was visible. Every floating
overlay now goes through `EBBottomRightRect` or `EBCenteredRect`, which take the work area.

**Editing the settings plist behind cfprefsd's back changes nothing.** `CFPreferencesCopyAppValue` is
served from `cfprefsd`'s cache, and writing `~/Library/Containers/.../local.eyeleo.EyeLeo.plist` with
`plistlib` does not invalidate it. The symptom is convincing and completely misleading: the file on
disk holds the new value, a fresh process still reports the old one, and the trace looks like a broken
read. `killall -u $USER cfprefsd` makes the new value appear, which is what proved the code was fine.
Edit settings through the app, or through `defaults write` on the domain, not by writing the file.

**The panel sizes its picture view once, from the frame an animation opens on.** The short break creates
the panel, sets the image view's frame from whatever the animation is showing at that moment, and from
then on swaps only the image. An exercise whose opening frame was a different size therefore drew its
later frames into the wrong box, scaled or cropped, with nothing in the trace to say so. It happened for
real: the shoulders exercise had no case in the animation's initialiser, fell through to the inherited
painted head, and only swapped to the real frames on the first tick. The panel traced `156x98`, the
inherited head, in front of frames that are `138x110`. Both the frame it opens on and every frame it
cycles to now come from one table in `ebexercise.m`, and a test walks that table against the shipped
files and fails if any two frames of a cycle disagree on size. It fails with the sizes in the message,
which is how the fix was confirmed rather than assumed.

**A transform is not what the eye reads as movement.** Worth keeping from the version this replaced:
rotating a head about its own bottom edge while lifting a separate torso underneath did not read as a
stretch, it read as a composite coming apart. Swapping between two aligned poses does read as the
movement. The same panels that could not be moved convincingly in code could not be redrawn either, and
the answer turned out to be in the tool.

## Deliberate differences from the Windows original

- **Activity detection and fullscreen detection are permission-free.** Discussed above; this is the
  single biggest win of the port.
- **Notifications are in-app bubbles**, not system notifications, to avoid the Notifications grant.
- **Logging is gone.** The original wrote every state change to `log.txt` by reopening the file each
  time. `os_log` is used instead, for real problems only.
- **No installer.** NSIS, the `.manifest` file it referenced and the MSVC runtime DLLs have no
  equivalent here. The app is a bundle you drag to `/Applications`.
- **No `config.xml` in the working directory.** The original loaded its language and version from a
  file relative to the process working directory, which broke if you launched it from anywhere else.
  Language now follows the system and assets live in the bundle.
- **Single instance by bundle id.** The original used a named Win32 mutex.
- **The Russian plural rule was corrected.** `getSecondStr` tested `n/10 != 1` where the rule needs
  `n%100 != 11`, so it mis-rendered numbers like 21 and 101. The port implements the real rule and
  keeps the original's wording; `tools/check_strings.m` prints it for inspection.
- **The demo break keeps the original's odd rule.** `demo && strictMode` (main.cpp:776) means the
  settings-window "try long break" button gives a full-length break unless strict mode is on. Preserved
  rather than quietly changed, and covered by a test.

## Screen sizes and multiple displays

Nothing in the layout is hardcoded to a resolution. Every overlay is sized from the display at the
moment it is shown, in points, so the same code covers a 1280x800 MacBook Air, a 5K Studio Display
and anything in between.

Two coordinate spaces are in play, and mixing them up is exactly how an overlay ends up under the
Dock:

- `NSScreen.frame` is the whole display, menu bar and Dock included. The dimming layer and the long
  break screen use it, because they are meant to cover the display edge to edge.
- `NSScreen.visibleFrame` is the work area, frame minus menu bar and Dock. Anything that floats above
  the desktop is centred or pinned inside it: the short break panel, the countdown bubble, the
  before-break dialog, the notification, the waiting banner.

On this machine (1470x956 at @2x, 60pt Dock) that difference is worth 13.5 points: centred on `frame`
the panel sat low, close to the Dock; centred on `visibleFrame` it sits in the middle of the work
area.

Retina is a non-issue. Layout is in points throughout, the menu bar icons ship @2x, and the artwork
is drawn at its natural point size, so a 156x98 point leopard is 156x98 on every display.

With several displays connected:

- every display gets a dimming layer, so the whole desktop is blocked;
- the panel content goes on display 0, the primary display, in each of the three break overlays.

That second point is a deliberate divergence. The original created a `MiniPauseWindow` per
non-fullscreen display, so with two monitors you got two copies of the panel and had to decide which
to click. One panel on the primary display is predictable; the cost is that a break shown while you
are reading an external monitor appears on the built-in one.

Two defensive details: if a display's work area is smaller than the panel, the panel and everything
inside it are scaled down proportionally instead of hanging off the edges; and a change to display
parameters, which covers re-resolution, rearrangement, plugging a monitor in or out and the Dock
appearing or hiding, tears down every overlay so nothing is left stranded at the wrong size.

`NSWindow.frame` is a readonly property. To move or resize a window, use `setFrame:display:`.

## Layout

```
src/ebcore.{h,m}       state machine, settings, statistics; no AppKit, so it is unit-testable
src/ebdetect.{h,m}    activity and fullscreen detection, the only CoreGraphics dependency
src/ebtext.{h,m}      localized durations and plural rules
src/ebassets.{h,m}    lazy image loading
src/ebexercise.{h,m}  exercise choice and the personage animation
src/ebwindows.{h,m}   the five overlays
src/ebgeometry.{h,m}   overlay placement as pure functions, unit-tested against synthetic screens
src/ebsettingsui.{h,m} settings window
src/ebtea.{h,m}      tea.conf parsing and the brewing session, no AppKit beyond strings
src/ebapp.{h,m}       menu bar, menu, scheduler, single instance, login item
src/ebtrace.{h,m}     startup and state tracing
tools/mkframes.m      builds every generated frame and vessel: keys off the flat background, aligns a
                      frame set on anchors inside the artwork, and writes a preview to judge it against
tools/gen_strings.py  regenerates both .strings files from the original langpacks
tools/mkicon.m        draws the menu bar template icons and the app icon
tools/measure.sh      the numbers above
tools/check_strings.m localization coverage and plural spot-checks
tools/windows.m       lists on-screen windows (bounds only; needs no permission)
tools/smoke.sh       end-to-end check of the built app, not just the core
tests/                499 checks over the core state machine, the overlay geometry, the settings file and
                      the generated artwork, plus a localization coverage check over 176 keys
```

## Tests

The original ships none. The state machine is where a port silently eats the user's breaks, so it is
covered: checks over the full break cycle, pause and resume, inactivity auto-relax, fullscreen blocking
and strict mode, the give-up path, restart resume, settings round-trip and clamping, plus the plural
rules. `tests/ebdetect_stub.c` replaces the CoreGraphics detector so the tests run without a window
server. `tools/smoke.sh` adds 19 end-to-end checks against the built app, so an overlay that never
appears on screen fails the build and not just a unit.

## Provenance

The Windows original by Alexander Garustovich is CC BY-NC 4.0 (see `license.txt` in the original
repository). Its assets, wording and behaviour are reused here under that licence, so this build is
non-commercial and must keep the attribution. `Resources/` starts as a copy of the original
`bin/Resources` and `bin/Personages`; the personage frames from `leopard_shoulders_up` up and all the
tea vessels are generated for this port by `tools/mkframes.m` and are covered by the same licence. The
Russian translations for the fourteen exercise phrasings the
original never translated were written for this port; the rest of the Russian text is the original's.
