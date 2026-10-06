// Localization of durations. Kept apart from the state machine so the plural rules
// can be unit-tested and so the core stays free of AppKit string plumbing.

#ifndef EB_TEXT_H
#define EB_TEXT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL EBRussianLanguage(NSString *_Nullable language);

// Russian according to the user's current locale, with an explicit override for tests.
BOOL EBRussianNow(void);

// Localized word for `n` units ("minute"/"minutes", "минута"/"минуты"/"минут").
NSString *EBPluralWord(long n, NSString *unit, BOOL russian);

// "5 minutes", "1 minute 20 seconds", "2 часа 5 минут"
NSString *EBSecondsText(long seconds, BOOL russian);

// Remaining-time text honouring EBTimeSpec. forceSeconds always shows the clock form,
// which is what the long break screen uses.
NSString *EBTimeLeftText(long ms, BOOL russian, BOOL forceSeconds);

// Forces the plural language, for the localization checker. Only the checker uses this.
void EBSetRussianForTesting(BOOL force);

// Redirects string lookup away from the main bundle. The app never calls this; the
// localization checker uses it to read a built EyeLeo.app from the outside.
void EBSetStringsBundle(NSBundle *_Nullable bundle);

// Localized lookup honouring EBSetStringsBundle.
NSString *EBLocalizedString(NSString *key);

// Compact minutes label for the settings window, e.g. "50 min".
NSString *EBMinutesLabel(int minutes, BOOL russian);

NS_ASSUME_NONNULL_END

#endif // EB_TEXT_H