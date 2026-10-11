#import "ebtea.h"

#import "ebcore.h"

// The schedules the app falls back on when tea.conf lists no teas, and the ones shipped in the template
// file. The short ones are gongfu lengths, where each steep runs longer than the last because the leaves
// have already opened; the herbal one is in the same units and is simply much longer.
static const struct {
    const char *name;
    double temperature;
    int seconds[EBMaxSteeps];
    int count;
} kBuiltInTeas[] = {
    { "green", 80.0, { 10, 15, 20, 25, 30, 35, 0, 0 }, 6 },
    { "white", 85.0, { 10, 15, 20, 25, 30, 0, 0, 0 }, 5 },
    { "oolong", 85.0, { 15, 25, 35, 45, 60, 75, 0, 0 }, 6 },
    { "black", 90.0, { 20, 30, 40, 50, 60, 70, 0, 0 }, 6 },
    { "red", 95.0, { 7, 10, 15, 20, 25, 30, 0, 0 }, 6 },
    { "puer", 99.0, { 20, 30, 40, 50, 60, 70, 80, 90 }, 8 },
    { "herbal", 100.0, { 300, 360, 420, 480, 0, 0, 0, 0 }, 4 },
};
enum { kNumBuiltInTeas = (int)(sizeof(kBuiltInTeas) / sizeof(kBuiltInTeas[0])) };

// Longest single steep accepted. Herbal is the longest that ships, at 300, so an hour is well clear of any
// real schedule and only catches a typo like an extra zero.
enum { kMaxSteepSeconds = 3600 };

// The name is the whole identity of a tea: it keys its picture file and its menu entry, so it is held to a
// shape that cannot go wrong on either. Lowercase Latin, one word, no spaces, starting with a letter.
//
// Uppercase is refused rather than folded. A macOS volume is case-insensitive by default, so Tea.png and
// tea.png would be one file, and a name that differs only in case would quietly pick up another's picture.
static BOOL NameIsValid(NSString *name) {
    if (name.length == 0 || name.length > 24)
        return NO;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL letter = (c >= 'a' && c <= 'z');
        BOOL digit = (c >= '0' && c <= '9');
        // Digits and underscores may follow the first letter but not start the name.
        if (!letter && !(i > 0 && (digit || c == '_')))
            return NO;
    }
    return YES;
}

// intValue answers 0 for text that is not a number at all, which would turn a typo into a silently dropped
// steep. A scanner with nothing left over is what separates "30" from "30x".
static BOOL ParseSteepSeconds(NSString *text, int *out) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    int v = 0;
    if (![scanner scanInt:&v] || !scanner.isAtEnd || v <= 0 || v > kMaxSteepSeconds)
        return NO;
    *out = v;
    return YES;
}

static BOOL ParseTemperature(NSString *text, double *out) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double v = 0;
    if (![scanner scanDouble:&v] || !scanner.isAtEnd || v <= 0 || v > 100)
        return NO;
    *out = v;
    return YES;
}

// A refusal is only visible to whoever turned tracing on, which is the point: a rejected line is a
// mistake in a file nobody is supposed to be editing by hand, and the day it matters is the day somebody
// is. It is not an error dialog over the top of an app that is otherwise working.
static void Reject(NSUInteger lineNo, NSString *reason) {
    if (EBTraceOn())
        fprintf(stderr, "[EB] tea.conf line %lu rejected: %s\n", (unsigned long)lineNo + 1, reason.UTF8String);
}

static void Report(NSString *message) {
    if (EBTraceOn())
        fprintf(stderr, "[EB] tea.conf: %s\n", message.UTF8String);
}

static EBTeaConfig MakeBuiltInConfig(void) {
    EBTeaConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.schemes = calloc((size_t)kNumBuiltInTeas, sizeof(EBTeaScheme));
    cfg.count = kNumBuiltInTeas;
    for (int i = 0; i < cfg.count; i++) {
        EBTeaScheme *scheme = &cfg.schemes[i];
        scheme->name = strdup(kBuiltInTeas[i].name);
        scheme->temperatureC = kBuiltInTeas[i].temperature;
        scheme->count = kBuiltInTeas[i].count;
        scheme->seconds = calloc((size_t)(kBuiltInTeas[i].count), sizeof(int));
        for (int j = 0; j < scheme->count; j++)
            scheme->seconds[j] = kBuiltInTeas[i].seconds[j];
    }
    return cfg;
}

NSString *EBTeaConfigPath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                            .firstObject;
    return [support stringByAppendingPathComponent:@"EyeLeo/tea.conf"];
}

// Puts the template from the bundle where the user can find and edit it.
//
// Without this the file exists only as something the user has to create blind, and the Windows build
// has had it seeded from the installer's copy for several versions. Two copies of the same thing is the
// arrangement the other build already uses and the reason it is worth matching here: one file to edit,
// in a place an ordinary person can reach, instead of one to guess at.
//
// Never overwrites: an existing file is the user's, and this runs before anything has been read, so it
// only ever happens once per install.
//
// The sandbox is no obstacle to this and entitlements.plist stays as it is: an app may always read its
// own bundle and write anywhere inside its own container, and both paths are one of those two. The
// container itself only comes into being once the app has written something, so the directory is made
// here rather than assumed.
BOOL SeedTeaConfigTo(NSString *path) {
    NSFileManager *files = NSFileManager.defaultManager;
    if ([files fileExistsAtPath:path])
        return NO;

    NSString *template = [NSBundle.mainBundle pathForResource:@"tea" ofType:@"conf"];
    if (!template) {
        Report(@"no tea.conf template in the bundle, leaving the file to be created by hand");
        return NO;
    }

    NSError *error = nil;
    if (![files createDirectoryAtPath:path.stringByDeletingLastPathComponent
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&error]) {
        Report([NSString stringWithFormat:@"the folder for tea.conf could not be created: %@",
                                      error.localizedDescription]);
        return NO;
    }
    if (![files copyItemAtPath:template toPath:path error:&error]) {
        Report([NSString stringWithFormat:@"tea.conf could not be created: %@", error.localizedDescription]);
        return NO;
    }

    Report(@"tea.conf created from the template in the app bundle");
    return YES;
}

BOOL SeedTeaConfig(void) { return SeedTeaConfigTo(EBTeaConfigPath()); }

EBTeaConfig EBLoadTeaConfig(void) {
    SeedTeaConfig();

    NSString *text = [NSString stringWithContentsOfFile:EBTeaConfigPath()
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (!text)
        return MakeBuiltInConfig(); // nothing readable there: the built-in schedules are the answer
    return EBParseTeaConfig(text);
}

EBTeaConfig EBParseTeaConfig(NSString *text) {

    // Lines look like:  name, temperature, seconds...  with # for a comment and blank lines ignored.
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSMutableDictionary *> *parsed = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSUInteger lineNo = 0; lineNo < lines.count; lineNo++) {
        NSString *line = [lines[lineNo] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"])
            continue;

        NSArray<NSString *> *parts = [line componentsSeparatedByString:@","];
        NSString *name = [parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!NameIsValid(name)) {
            Reject(lineNo, [NSString stringWithFormat:@"\"%@\" is not a usable name: one lowercase Latin "
                                                      @"word, letters, then digits or underscores",
                                                      name]);
            continue;
        }
        if ([seen containsObject:name]) {
            Reject(lineNo, [NSString stringWithFormat:@"%@ is already defined above", name]);
            continue;
        }
        if (parts.count < 3) {
            Reject(lineNo, [NSString stringWithFormat:@"%@ has too few fields, expected name, temperature, "
                                                  @"then one time per steep",
                                                  name]);
            continue;
        }

        double temperature = 0;
        if (!ParseTemperature(parts[1], &temperature)) {
            Reject(lineNo, [NSString stringWithFormat:@"%@: temperature must be a number over 0 and up to 100",
                                                  name]);
            continue;
        }

        NSMutableArray<NSNumber *> *seconds = [NSMutableArray array];
        BOOL malformed = NO;
        for (NSUInteger i = 2; i < parts.count && !malformed; i++) {
            int v = 0;
            NSString *field = [parts[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!ParseSteepSeconds(field, &v)) {
                Reject(lineNo, [NSString stringWithFormat:@"%@: \"%@\" is not a steep time in whole seconds",
                                                  name, field]);
                malformed = YES;
            } else if ((int)seconds.count >= EBMaxSteeps) {
                Reject(lineNo, [NSString stringWithFormat:@"%@: more than %d steeps", name, EBMaxSteeps]);
                malformed = YES;
            } else {
                [seconds addObject:@(v)];
            }
        }
        if (malformed || seconds.count == 0)
            continue;

        [seen addObject:name];
        [parsed addObject:[@{ @"name": name, @"temp": @(temperature), @"seconds": seconds } mutableCopy]];
    }

    // A file that lists no teas is read as no file at all. Otherwise a single bad line would leave the
    // list empty and the menu bare, which reads as breakage rather than as what it is: a file with a
    // mistake in it, reported under EYELEO_DEBUG and left alone.
    if (parsed.count == 0) {
        Report(@"no usable teas in tea.conf, using the built-in schedules");
        return MakeBuiltInConfig();
    }

    EBTeaConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.count = (int)parsed.count;
    cfg.schemes = calloc((size_t)cfg.count, sizeof(EBTeaScheme));
    for (int i = 0; i < cfg.count; i++) {
        NSDictionary *entry = parsed[i];
        NSString *name = entry[@"name"];
        NSArray<NSNumber *> *seconds = entry[@"seconds"];
        EBTeaScheme *scheme = &cfg.schemes[i];
        scheme->name = strdup(name.UTF8String);
        scheme->temperatureC = [entry[@"temp"] doubleValue];
        scheme->count = (int)seconds.count;
        scheme->seconds = calloc((size_t)scheme->count, sizeof(int));
        for (int j = 0; j < scheme->count; j++)
            scheme->seconds[j] = seconds[j].intValue;
    }

    Report([NSString stringWithFormat:@"%d teas from tea.conf: %@", cfg.count,
                                      [[parsed valueForKey:@"name"] componentsJoinedByString:@", "]]);
    return cfg;
}

void EBTeaConfigFree(EBTeaConfig *config) {
    for (int i = 0; i < config->count; i++) {
        free(config->schemes[i].name);
        free(config->schemes[i].seconds);
    }
    free(config->schemes);
    memset(config, 0, sizeof(*config));
}

int EBTeaSchemeIndexOfName(const EBTeaConfig *config, const char *name) {
    if (!name || !*name)
        return -1;
    for (int i = 0; i < config->count; i++) {
        if (strcmp(config->schemes[i].name, name) == 0)
            return i;
    }
    return -1;
}

const EBTeaScheme *EBTeaSessionTea(const EBTeaConfig *config, const EBTeaSession *s) {
    if (!config || !s || s->tea < 0 || s->tea >= config->count)
        return NULL;
    return &config->schemes[s->tea];
}

int EBTeaSessionSteepSeconds(const EBTeaConfig *config, const EBTeaSession *s) {
    const EBTeaScheme *sc = EBTeaSessionTea(config, s);
    if (!sc || s->steep < 0 || s->steep >= s->count || s->steep >= sc->count)
        return 0;
    return sc->seconds[s->steep];
}

BOOL EBTeaSessionValid(const EBTeaSession *s) { return s->tea >= 0 && s->count > 0; }

void EBTeaSessionStart(EBTeaSession *out, const EBTeaConfig *config, int tea) {
    memset(out, 0, sizeof(*out));
    out->tea = -1;
    if (tea < 0 || tea >= config->count)
        return;
    const EBTeaScheme *sc = &config->schemes[tea];
    if (sc->count <= 0 || !sc->seconds)
        return;
    out->tea = tea;
    out->steep = 0;
    out->count = sc->count;
    out->msLeft = (long)sc->seconds[0] * 1000;
    out->awaiting = NO;
    out->finished = NO;
}

void EBTeaSessionStop(EBTeaSession *s) {
    memset(s, 0, sizeof(*s));
    s->tea = -1;
}

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

NSString *EBTeaDisplayName(const char *name) {
    if (!name || !*name)
        return @"";

    // A key with no entry comes back as the key rather than as nil, so a missing translation has to be
    // recognised by comparing against the key that was asked for. Let it through and the menu shows
    // "tea_name_jasmine" where a tea is supposed to be, which is the one thing a fallback must not do.
    NSString *key = [NSString stringWithFormat:@"tea_name_%s", name];
    NSString *translated = [NSBundle.mainBundle localizedStringForKey:key value:nil table:nil];
    if (translated.length > 0 && ![translated isEqualToString:key])
        return translated;

    // The name from tea.conf is the fallback rather than an empty line, so a tea added to the file is
    // legible before anyone has written anything for it.
    return @(name);
}

NSString *EBTeaSessionCaption(const EBTeaConfig *config, const EBTeaSession *s, BOOL russian) {
    if (!EBTeaSessionValid(s))
        return @"";
    const EBTeaScheme *sc = EBTeaSessionTea(config, s);
    double temp = sc ? sc->temperatureC : 0;

    // The wording is assembled here rather than as a format string in the .strings file: the step count is
    // a number that has to sit inside a sentence in two languages, and Russian puts it in a different place.
    NSString *name = EBTeaDisplayName(sc ? sc->name : "");

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

NSString *EBTeaSchemeSummary(const EBTeaConfig *config, int tea, BOOL russian) {
    if (tea < 0 || tea >= config->count)
        return @"";
    const EBTeaScheme *sc = &config->schemes[tea];
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