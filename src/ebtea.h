// Gongfu-style brewing: pick a tea, then pour it steep by steep while the timer runs.
//
// The steeping times are not in the app. They live in tea.conf next to the saved settings, so the numbers
// can be adjusted without a rebuild, and a tea can be added the same way: its name is its identity. There
// is no enum of teas and no fixed set of them, so nothing here has to be recompiled for a new one to exist.
//
// Lines are taken or refused whole, and a refusal says why under EYELEO_DEBUG=1. What is not written in
// the file is not added to it either: tea.conf is read, never rewritten.

#ifndef EB_TEA_H
#define EB_TEA_H

#import <Foundation/Foundation.h>

#import "ebconfig.h"

NS_ASSUME_NONNULL_BEGIN

// How many steeps one tea may have. Eight is the longest schedule that ships (pu-erh), so it is the
// ceiling rather than an arbitrary number. The Windows build keeps them in a fixed array of this size.
enum { EBMaxSteeps = 8 };

// The display names a tea line may carry, as en="..." and ru="...". Both are optional and either may be
// absent: what a tea has no name for is shown under its name from tea.conf.
typedef struct {
    char *en;                            // owned, or NULL
    char *ru;                            // owned, or NULL
} EBTeaNames;

// One tea and the schedule of its steeps.
typedef struct {
    char *name;                          // from tea.conf, ASCII lowercase, owned
    EBTeaNames names;                    // display names, as written on the same line
    double temperatureC;                 // for the caption
    int *seconds;                        // seconds per steep, owned
    int count;
} EBTeaScheme;

typedef struct {
    EBTeaScheme *schemes;                // owned, and in tea.conf order: the order is the menu order
    int count;
} EBTeaConfig;

// Puts the tea.conf template from the bundle where it can be found and edited, if there is nothing
// there yet. Returns whether one was created. Never touches an existing file.
BOOL SeedTeaConfig(void);

// The same, with the destination given rather than taken from the container. Split out so the tests can
// aim it at a scratch directory: a test binary is not sandboxed, so EBTeaConfigPath() would resolve to
// the real Application Support folder and the test would write into the user's own files.
BOOL SeedTeaConfigTo(NSString *path);

// Reads tea.conf, creating it from the bundle's template first if it is not there. A missing file, and a
// file that lists no usable tea, both return the built-in schedules instead, so the feature works on a
// fresh install with nothing configured.
EBTeaConfig EBLoadTeaConfig(void);

// The same parsing, on text handed in directly. Separated from the file so it can be tested against whole
// configurations rather than only against whatever happens to be on disk. Never returns an empty config:
// text with no usable tea in it yields the built-in schedules, exactly as the file case does.
EBTeaConfig EBParseTeaConfig(NSString *text);

// A brewing session. Held by value so the countdown owns a copy and the menu can inspect it without
// reaching through the app delegate. It refers to its tea by index rather than by pointer: the config is
// loaded once and lives as long as the app, and an index keeps the struct free of ownership rules.
typedef struct {
    int tea;             // index into the config, -1 when nothing is brewing
    int steep;           // which steep is running, 0-based
    int count;           // how many steeps the tea has
    long msLeft;         // of the current steep
    BOOL awaiting;       // the steep ran out and the next waits for the menu
    BOOL finished;       // every steep has been poured
} EBTeaSession;

void EBTeaSessionStart(EBTeaSession *out, const EBTeaConfig *config, int tea);
void EBTeaSessionStop(EBTeaSession *s);
BOOL EBTeaSessionValid(const EBTeaSession *s);

// The tea behind a session, or NULL when there is none.
const EBTeaScheme *_Nullable EBTeaSessionTea(const EBTeaConfig *config, const EBTeaSession *s);

// Which tea a name refers to, or -1. Matches exactly: names are already lowercase by the time they reach
// here, and folding case here would reintroduce the file-name ambiguity the parser exists to prevent.
int EBTeaSchemeIndexOfName(const EBTeaConfig *config, const char *name);

int EBTeaSessionSteepSeconds(const EBTeaConfig *config, const EBTeaSession *s);

// Advance by a tick. Returns YES when the steep has run out, which leaves the session awaiting.
//
// The tick never moves to the next steep on its own. Brewing is meant to be paced by whoever is pouring:
// one steep, then the leaf sits in the pot for as long as they decide before the next. Auto-advancing
// ran all six in a row unattended, which is the opposite of how this is done.
BOOL EBTeaSessionAdvance(EBTeaSession *s, long elapsedMs);

// Moves on to the next steep, by request. Returns NO when there is nothing to pour: no session, still
// steeping, or already finished.
BOOL EBTeaSessionPour(EBTeaSession *s, const EBTeaConfig *config);

// How many seconds the next steep will run for, or 0 if there is none.
int EBTeaSessionNextSeconds(const EBTeaConfig *config, const EBTeaSession *s);

// The name to show a tea under, in the language asked for: the one written on its tea.conf line, or the
// name from tea.conf itself. The tea's own name is the fallback rather than an empty line, so a tea added
// with no translation is legible rather than nameless.
NSString *EBTeaDisplayName(const EBTeaScheme *tea, BOOL russian);

// Text for the notification: the tea name, the step, the temperature. Wording follows the session state,
// so a steep that has run out reads as finished rather than as the next one already under way.
NSString *EBTeaSessionCaption(const EBTeaConfig *config, const EBTeaSession *s, BOOL russian);

// The whole schedule in one line, for the tooltip on the menu item: "6 steeps: 10, 15, 20 s".
NSString *EBTeaSchemeSummary(const EBTeaConfig *config, int tea, BOOL russian);

// Frees the names and seconds arrays held by a config.
void EBTeaConfigFree(EBTeaConfig *config);

NS_ASSUME_NONNULL_END

#endif // EB_TEA_H