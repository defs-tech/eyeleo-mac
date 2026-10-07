#import "ebtea.h"

#import "ebtext.h"

// The default schedule, used when tea.conf is absent or unreadable. The short ones are gongfu lengths,
// where each steep runs longer than the last because the leaves have already opened; the herbal one is in
// the same units and is simply much longer.
static const struct {
    EBDrinkKind kind;
    double temperature;
    int seconds[8];
    int count;
} kDefaults[] = {
    { EBDrinkGreen, 80.0, { 10, 15, 20, 25, 30, 35, 0, 0 }, 6 },
    { EBDrinkWhite, 85.0, { 10, 15, 20, 25, 30, 0, 0, 0 }, 5 },
    { EBDrinkOolong, 85.0, { 15, 25, 35, 45, 60, 75, 0, 0 }, 6 },
    { EBDrinkBlack, 90.0, { 20, 30, 40, 50, 60, 70, 0, 0 }, 6 },
    { EBDrinkPuer, 99.0, { 20, 30, 40, 50, 60, 70, 80, 90 }, 8 },
    { EBDrinkHerbal, 100.0, { 300, 360, 420, 480, 0, 0, 0, 0 }, 4 },
};

static int SchemeIndex(EBDrinkKind kind) {
    // Config schemes are indexed by EBDrinkKind, which has EBDrinkNone at 0, so the slot is kind - 1.
    return (kind > EBDrinkNone && kind <= EBDrinkWater) ? (int)kind - 1 : -1;
}

static void FillDefaults(EBTeaConfig *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    for (size_t i = 0; i < sizeof(kDefaults) / sizeof(kDefaults[0]); i++) {
        int slot = SchemeIndex(kDefaults[i].kind);
        if (slot < 0 || slot >= EBNumDrinks)
            continue;
        EBTeaScheme *sc = &cfg->schemes[slot];
        sc->kind = kDefaults[i].kind;
        sc->temperatureC = kDefaults[i].temperature;
        sc->count = kDefaults[i].count;
        sc->seconds = calloc((size_t)MAX(kDefaults[i].count, 1), sizeof(int));
        for (int j = 0; j < kDefaults[i].count; j++)
            sc->seconds[j] = kDefaults[i].seconds[j];
        cfg->count++;
    }
}

// Maps a name from the config onto a kind. The file is written by hand, so a few spellings are accepted
// for each tea: nobody remembers whether they typed puer, pu-er or puerh.
static EBDrinkKind KindForName(NSString *name) {
    NSString *n = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                      .lowercaseString;
    if ([n isEqualToString:@"green"] || [n isEqualToString:@"зеленый"] || [n isEqualToString:@"зелёный"])
        return EBDrinkGreen;
    if ([n isEqualToString:@"white"] || [n isEqualToString:@"белый"])
        return EBDrinkWhite;
    if ([n isEqualToString:@"oolong"] || [n isEqualToString:@"oolon"] || [n isEqualToString:@"Ulun"] ||
        [n isEqualToString:@"улун"])
        return EBDrinkOolong;
    if ([n isEqualToString:@"black"] || [n isEqualToString:@"чёрный"] || [n isEqualToString:@"черный"])
        return EBDrinkBlack;
    if ([n isEqualToString:@"puer"] || [n isEqualToString:@"pu-er"] || [n isEqualToString:@"puerh"] ||
        [n isEqualToString:@"пуэр"])
        return EBDrinkPuer;
    if ([n isEqualToString:@"herbal"] || [n isEqualToString:@"травяной"] || [n isEqualToString:@"grass"])
        return EBDrinkHerbal;
    return EBDrinkNone;
}

NSString *EBTeaConfigPath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                            .firstObject;
    return [support stringByAppendingPathComponent:@"EyeLeo/tea.conf"];
}

EBTeaConfig EBLoadTeaConfig(void) {
    EBTeaConfig cfg;
    FillDefaults(&cfg);

    NSString *path = EBTeaConfigPath();
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!text)
        return cfg; // no file yet: the defaults are the answer, not a failure

    // Lines look like:  name, temperature, seconds...  with # for a comment and blank lines ignored.
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"])
            continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@","];
        if (parts.count < 3)
            continue;
        EBDrinkKind kind = KindForName(parts[0]);
        int slot = SchemeIndex(kind);
        if (slot < 0)
            continue; // an unknown name, or water, which has no steeping schedule

        NSMutableArray<NSNumber *> *secs = [NSMutableArray array];
        for (NSUInteger i = 2; i < parts.count; i++) {
            NSString *p = [parts[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            int v = p.intValue;
            // A zero or negative time would make the countdown never move, so drop it rather than take it.
            if (v > 0)
                [secs addObject:@(v)];
        }
        if (secs.count == 0)
            continue; // a line with no usable times keeps the built-in schedule for that tea

        double temp = parts[1].doubleValue;
        EBTeaScheme *sc = &cfg.schemes[slot];
        if (sc->seconds) {
            // The tea is already in the list from the defaults; overwrite rather than add a second copy.
            free(sc->seconds);
        } else {
            cfg.count++;
        }
        sc->kind = kind;
        sc->temperatureC = temp > 0 ? temp : sc->temperatureC;
        sc->count = (int)secs.count;
        sc->seconds = calloc(secs.count, sizeof(int));
        for (NSUInteger i = 0; i < secs.count; i++)
            sc->seconds[i] = secs[i].intValue;
    }
    return cfg;
}

void EBTeaConfigFree(EBTeaConfig *config) {
    for (int i = 0; i < EBNumDrinks; i++) {
        free(config->schemes[i].seconds);
        config->schemes[i].seconds = NULL;
    }
    memset(config, 0, sizeof(*config));
}

int EBTeaSessionSteepSeconds(const EBTeaConfig *config, const EBTeaSession *s) {
    int slot = SchemeIndex(s->kind);
    if (slot < 0 || s->steep < 0 || s->steep >= s->count)
        return 0;
    const EBTeaScheme *sc = &config->schemes[slot];
    if (s->steep >= sc->count)
        return 0;
    return sc->seconds[s->steep];
}

BOOL EBTeaSessionValid(const EBTeaSession *s) { return s->kind != EBDrinkNone && s->count > 0; }

void EBTeaSessionStart(EBTeaSession *out, const EBTeaConfig *config, EBDrinkKind kind) {
    memset(out, 0, sizeof(*out));
    int slot = SchemeIndex(kind);
    if (slot < 0)
        return;
    const EBTeaScheme *sc = &config->schemes[slot];
    if (sc->count <= 0)
        return;
    out->kind = kind;
    out->steep = 0;
    out->count = sc->count;
    out->msLeft = (long)sc->seconds[0] * 1000;
    out->awaiting = NO;
    out->finished = NO;
}

void EBTeaSessionStop(EBTeaSession *s) { memset(s, 0, sizeof(*s)); }

// Counts one steep down. When it runs out the session parks in "awaiting" rather than starting the next
// one: the leaf steeps in the pot until someone decides to pour again, and that pause is the whole point
// of brewing by hand. A tick is the only thing that changes here.
BOOL EBTeaSessionAdvance(EBTeaSession *s, long elapsedMs) {
    if (!EBTeaSessionValid(s) || s->finished || s->awaiting)
        return NO;
    s->msLeft -= elapsedMs;
    if (s->msLeft > 0)
        return NO;
    s->msLeft = 0;
    // The last steep running out is the end of the brewing. Closing the session here rather than waiting
    // for a Pour is what makes the completion message appear on its own: there is no last pour left to
    // start, so a final press would have nothing to do.
    if (s->steep + 1 >= s->count) {
        s->finished = YES;
        s->awaiting = NO;
        return YES;
    }
    s->awaiting = YES;
    return YES;
}

// The one place the step number moves. Called from the Pour menu item, nowhere else.
BOOL EBTeaSessionPour(EBTeaSession *s, const EBTeaConfig *config) {
    if (!EBTeaSessionValid(s) || s->finished)
        return NO;
    // Pouring while a steep is still running would throw its remaining time away, so it is refused until
    // the timer has actually run out.
    if (!s->awaiting)
        return NO;
    // Unreachable in normal use: Advance closes the session when the final steep runs out, so awaiting
    // always means there is another one after this. Guarded rather than assumed, so a schedule that
    // arrives through some other route cannot run the index past the end.
    if (s->steep + 1 >= s->count)
        return NO;
    s->steep++;
    s->msLeft = (long)EBTeaSessionSteepSeconds(config, s) * 1000;
    s->awaiting = NO;
    return YES;
}

int EBTeaSessionNextSeconds(const EBTeaConfig *config, const EBTeaSession *s) {
    if (!EBTeaSessionValid(s) || s->finished || !s->awaiting)
        return 0;
    if (s->steep + 1 >= s->count)
        return 0;
    EBTeaSession next = *s;
    next.steep++;
    return EBTeaSessionSteepSeconds(config, &next);
}

NSString *EBTeaName(EBDrinkKind kind, BOOL russian) {
    switch (kind) {
    case EBDrinkGreen: return russian ? @"Зелёный чай" : @"Green tea";
    case EBDrinkWhite: return russian ? @"Белый чай" : @"White tea";
    case EBDrinkOolong: return russian ? @"Улун" : @"Oolong";
    case EBDrinkBlack: return russian ? @"Чёрный чай" : @"Black tea";
    case EBDrinkPuer: return russian ? @"Пуэр" : @"Pu-erh";
    case EBDrinkHerbal: return russian ? @"Травяной чай" : @"Herbal tea";
    case EBDrinkWater: return russian ? @"Вода" : @"Water";
    default: return russian ? @"Чай" : @"Tea";
    }
}

NSString *EBTeaSessionCaption(const EBTeaConfig *config, const EBTeaSession *s, BOOL russian) {
    if (!EBTeaSessionValid(s))
        return @"";
    int slot = SchemeIndex(s->kind);
    double temp = slot >= 0 ? config->schemes[slot].temperatureC : 0;

    // The wording is assembled here rather than as a format string in the .strings file: the step count is
    // a number that has to sit inside a sentence in two languages, and Russian puts it in a different place.
    NSString *name = EBTeaName(s->kind, russian);

    if (s->finished) {
        return russian ? [NSString stringWithFormat:@"%@ готов", name]
                       : [NSString stringWithFormat:@"%@ is ready", name];
    }

    // The steep has run out and the next one is not under way. This wording exists for the log and for the
    // completion path rather than for the screen: the bubble is taken down the moment a steep ends, since a
    // countdown sitting at zero with nothing to count is just clutter.
    if (s->awaiting)
        return russian ? [NSString stringWithFormat:@"Пролив %d завершён", s->steep + 1]
                       : [NSString stringWithFormat:@"Steep %d done", s->steep + 1];

    BOOL last = s->steep == s->count - 1;
    if (last) {
        return russian ? [NSString stringWithFormat:@"Последний пролив %@, %.0f°C", name, temp]
                       : [NSString stringWithFormat:@"Last pour of %@, %.0f°C", name, temp];
    }
    return russian ? [NSString stringWithFormat:@"Пролив %d из %d, %.0f°C", s->steep + 1, s->count, temp]
                   : [NSString stringWithFormat:@"Steep %d of %d, %.0f°C", s->steep + 1, s->count, temp];
}

NSString *EBTeaSchemeSummary(const EBTeaConfig *config, EBDrinkKind kind, BOOL russian) {
    int slot = SchemeIndex(kind);
    if (slot < 0)
        return @"";
    const EBTeaScheme *sc = &config->schemes[slot];
    if (sc->count <= 0 || !sc->seconds)
        return russian ? @"схема не задана" : @"no schedule";
    NSMutableString *list = [NSMutableString string];
    for (int i = 0; i < sc->count; i++) {
        if (i > 0)
            [list appendString:@", "];
        [list appendFormat:@"%d", sc->seconds[i]];
    }
    if (russian)
        return [NSString stringWithFormat:@"%d %@: %@ с", sc->count,
                                          sc->count == 1 ? @"пролив" : @"проливов", list];
    return [NSString stringWithFormat:@"%d %@: %@ s", sc->count, sc->count == 1 ? @"steep" : @"steeps", list];
}