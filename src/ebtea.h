// Gongfu-style brewing: pick a tea, then pour it steep by steep while the timer runs.
//
// The steeping times are not in the app. They live in tea.conf next to the saved settings, so the numbers
// can be adjusted without a rebuild. Nothing is validated: a malformed line is ignored and brewing
// carries on with whatever parsed, which is what a plain text file edited by hand should do.

#ifndef EB_TEA_H
#define EB_TEA_H

#import <Foundation/Foundation.h>

#import "ebassets.h"

NS_ASSUME_NONNULL_BEGIN

// One tea and the schedule of its steeps.
typedef struct {
    EBDrinkKind kind;
    double temperatureC;              // for the caption
    int *seconds;                      // seconds per steep, owned
    int count;
} EBTeaScheme;

typedef struct {
    EBTeaScheme schemes[EBNumDrinks]; // indexed by EBDrinkKind
    int count;                         // how many are filled
} EBTeaConfig;

// Reads tea.conf. A missing file is not an error: the built-in defaults are returned instead, so the
// feature works on a fresh install with nothing configured.
EBTeaConfig EBLoadTeaConfig(void);

// Where tea.conf lives, for the comment shown in the settings.
NSString *EBTeaConfigPath(void);

// A brewing session. Held by value so the countdown owns a copy and the menu can inspect it without
// reaching through the app delegate.
typedef struct {
    EBDrinkKind kind;      // EBDrinkNone when nothing is brewing
    int steep;             // which steep is running, 0-based
    int count;             // how many steeps the tea has
    long msLeft;           // of the current steep
    BOOL awaiting;         // the steep ran out and the next waits for the menu
    BOOL finished;         // every steep has been poured
} EBTeaSession;

void EBTeaSessionStart(EBTeaSession *out, const EBTeaConfig *config, EBDrinkKind kind);
void EBTeaSessionStop(EBTeaSession *s);
BOOL EBTeaSessionValid(const EBTeaSession *s);
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

// The display name of a tea, for the menu.
NSString *EBTeaName(EBDrinkKind kind, BOOL russian);

// Text for the notification: the tea name, the step, the temperature. Wording follows the session state,
// so a steep that has run out reads as finished rather than as the next one already under way.
NSString *EBTeaSessionCaption(const EBTeaConfig *config, const EBTeaSession *s, BOOL russian);

// The whole schedule in one line, for the tooltip on the menu item: "6 steeps: 10, 15, 20 s".
NSString *EBTeaSchemeSummary(const EBTeaConfig *config, EBDrinkKind kind, BOOL russian);

// Frees the seconds arrays held by a config.
void EBTeaConfigFree(EBTeaConfig *config);

NS_ASSUME_NONNULL_END

#endif // EB_TEA_H