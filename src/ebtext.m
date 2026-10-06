#import "ebtext.h"
#import "ebcore.h"

BOOL EBRussianLanguage(NSString *language) {
    if (!language)
        return NO;
    return [language hasPrefix:@"ru"];
}

static BOOL gForceRussian = NO;
static NSBundle *gStringsBundle = nil;

void EBSetStringsBundle(NSBundle *bundle) {
    gStringsBundle = bundle;
}

NSString *EBLocalizedString(NSString *key) {
    NSBundle *bundle = gStringsBundle ?: NSBundle.mainBundle;
    NSString *value = [bundle localizedStringForKey:key value:@"" table:@"Localizable"];
    if (value.length == 0)
        return key; // a missing key must be obvious, not silently empty
    return value;
}

void EBSetRussianForTesting(BOOL force) {
    gForceRussian = force;
}

BOOL EBRussianNow(void) {
    if (gForceRussian)
        return YES;
    return EBRussianLanguage(NSLocale.currentLocale.languageCode);
}

static NSString *SuffixForCategory(int category) {
    switch (category) {
    case 0:
        return @".one";
    case 1:
        return @".few";
    default:
        return @".many";
    }
}

NSString *EBPluralWord(long n, NSString *unit, BOOL russian) {
    int cat = EBPluralCategory(n, russian);
    return EBLocalizedString([NSString stringWithFormat:@"unit.%@%@", unit, SuffixForCategory(cat)]);
}

static NSString *Unit(long n, NSString *unit, BOOL russian) {
    return [NSString stringWithFormat:@"%ld %@", n, EBPluralWord(n, unit, russian)];
}

// Coarse form, no seconds: "2 hours 5 minutes" / "2 часа 5 минут".
NSString *EBSecondsText(long seconds, BOOL russian) {
    if (seconds < 0)
        seconds = 0;
    long h = seconds / 3600;
    long m = (seconds % 3600) / 60;
    long s = seconds % 60;

    if (h > 0) {
        if (m == 0)
            return Unit(h, @"hour", russian);
        return [NSString stringWithFormat:@"%@ %@", Unit(h, @"hour", russian), Unit(m, @"minute", russian)];
    }
    if (m > 0)
        return Unit(m, @"minute", russian);
    return Unit(s, @"second", russian);
}

NSString *EBTimeLeftText(long ms, BOOL russian, BOOL forceSeconds) {
    long h = 0, m = 0, s = 0;
    EBTimeMode mode = EBTimeSpec(ms, forceSeconds, russian, &h, &m, &s);

    switch (mode) {
    case EBTimeModeTooManyHours:
        return EBLocalizedString(@"time.too_many_hours");

    case EBTimeModeClock:
        if (h > 0)
            return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
        return [NSString stringWithFormat:@"%ld:%02ld", m, s];

    case EBTimeModeHoursAndMinutes:
    default:
        if (h > 0) {
            if (m == 0)
                return Unit(h, @"hour", russian);
            return [NSString stringWithFormat:@"%@ %@", Unit(h, @"hour", russian), Unit(m, @"minute", russian)];
        }
        return Unit(m, @"minute", russian);
    }
}

NSString *EBMinutesLabel(int minutes, BOOL russian) {
    return Unit(minutes, @"minute", russian);
}