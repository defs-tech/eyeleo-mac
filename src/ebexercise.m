#import "ebexercise.h"
#import "ebassets.h"

static NSString *KeyFor(EBExercise exercise, int line) {
    return [NSString stringWithFormat:@"mini_pause_text_%d_%d", (int)exercise, line];
}

@implementation EBExercisePicker

+ (int)lineCountFor:(EBExercise)exercise {
    if (exercise == EBExerciseNone)
        return 0;

    // The original walks up from 1 and stops at the first gap, capped at 19.
    int n = 0;
    for (int i = 1; i < 20; i++) {
        NSString *value = [[NSBundle mainBundle] localizedStringForKey:KeyFor(exercise, i)
                                                                   value:nil
                                                                   table:@"Localizable"];
        if (value.length == 0 || [value isEqualToString:KeyFor(exercise, i)])
            break;
        n = i;
    }
    return n;
}

+ (int)pickLineFor:(EBExercise)exercise {
    int count = [self lineCountFor:exercise];
    if (count <= 0)
        return 0;
    return arc4random_uniform((uint32_t)count) + 1;
}

+ (NSString *)textFor:(EBExercise)exercise line:(int)line {
    if (exercise == EBExerciseNone || line <= 0)
        return @"";
    return NSLocalizedString(KeyFor(exercise, line), @"short break exercise text");
}

+ (EBExercise)pickAfter:(EBExercise)last windowNearby:(BOOL)windowNearby {
    EBExercise exercise = EBExerciseNone;
    for (int tries = 0; tries < 32; tries++) {
        exercise = (EBExercise)(arc4random_uniform(EBNumExercises) + 1);
        if (!windowNearby && exercise == EBExerciseWindow)
            continue;
        if (exercise != last)
            break;
    }
    return exercise;
}

@end

// One entry per drawn frame an exercise moves through: which picture, and the exact _timeout value
// the original assigned when that picture became current. advance() subtracts 100 per tick, so these
// are the original's own values rather than clean millisecond counts; keeping them verbatim means the
// cadence is unchanged by this refactor.
typedef struct {
    EBPersonageFrame frame;
    int hold;
} EBFrameStep;

// Rolls through the look directions. The original showed the static head first and only entered this
// loop on the first tick, so it listed the same default frame twice; the cycle starts directly on the
// first move instead.
static const EBFrameStep kLookHorz[] = {{EBFrameLookRight, 1200}, {EBFrameLookLeft, 1200}};
static const EBFrameStep kLookVert[] = {{EBFrameLookDown, 1200}, {EBFrameLookUp, 1200}};
static const EBFrameStep kRoll[] = {
    {EBFrameLookLeft, 1200},
    {EBFrameLookUp, 1200},
    {EBFrameLookRight, 1200},
    {EBFrameLookDown, 1200},
};
static const EBFrameStep kBlink[] = {{EBFrameDefault, 200}, {EBFrameBlink, 200}};
static const EBFrameStep kCloseTightly[] = {{EBFrameDefault, 2000}, {EBFrameCloseTightly, 2000}};
// Same cadence as the plain blink, but on the closed-eyes frame for longer than its open frame: the
// point is a complete, unhurried blink, not a fast one.
static const EBFrameStep kBlinkFully[] = {{EBFrameDefault, 200}, {EBFrameCloseTightly, 500}};
// Two drawn frames rather than a transform. Moving one baked picture was tried first and read as a
// sliding image, not as shoulders; swapping between two poses reads as the movement itself.
// tools/mkframes.m aligns the pair so the markings do not crawl between them.
static const EBFrameStep kShoulders[] = {{EBFrameShouldersUp, 350}, {EBFrameShouldersDown, 350}};
// Arms down, arms up, then a backward bend, then back to standing. The original never animated this
// exercise at all, so the three frames and this cadence are both new.
static const EBFrameStep kStretch[] = {
    {EBFrameStretchUpNeutral, 500},
    {EBFrameStretchUp, 500},
    {EBFrameStretchUpper, 500},
};
// Eyes open, then covered by both paws. Held longer than it takes to show, because the point is the
// darkness and the warmth of the paws, not a blink.
static const EBFrameStep kPalming[] = {{EBFrameEyesOpen, 700}, {EBFrameEyesClosed, 500}};

static const EBFrameStep *StepsFor(EBExercise exercise, NSUInteger *outCount) {
    switch (exercise) {
    case EBExerciseLookHorz:
        *outCount = sizeof(kLookHorz) / sizeof(kLookHorz[0]);
        return kLookHorz;
    case EBExerciseLookVert:
        *outCount = sizeof(kLookVert) / sizeof(kLookVert[0]);
        return kLookVert;
    case EBExerciseRoll:
        *outCount = sizeof(kRoll) / sizeof(kRoll[0]);
        return kRoll;
    case EBExerciseBlink:
        *outCount = sizeof(kBlink) / sizeof(kBlink[0]);
        return kBlink;
    case EBExerciseCloseTightly:
        *outCount = sizeof(kCloseTightly) / sizeof(kCloseTightly[0]);
        return kCloseTightly;
    case EBExerciseBlinkFully:
        *outCount = sizeof(kBlinkFully) / sizeof(kBlinkFully[0]);
        return kBlinkFully;
    case EBExerciseNeckShoulders:
        *outCount = sizeof(kShoulders) / sizeof(kShoulders[0]);
        return kShoulders;
    case EBExerciseStretch:
        *outCount = sizeof(kStretch) / sizeof(kStretch[0]);
        return kStretch;
    case EBExercisePalming:
        *outCount = sizeof(kPalming) / sizeof(kPalming[0]);
        return kPalming;
    case EBExerciseNone:
    case EBExerciseWindow:
    default:
        *outCount = 0;
        return NULL;
    }
}

static int HoldFor(EBExercise exercise, NSUInteger index) {
    NSUInteger count = 0;
    const EBFrameStep *steps = StepsFor(exercise, &count);
    return (steps && index < count) ? steps[index].hold : 200;
}

NSUInteger EBExerciseFrameCount(EBExercise exercise) {
    NSUInteger count = 0;
    StepsFor(exercise, &count);
    return count;
}

EBPersonageFrame EBExerciseFrameAt(EBExercise exercise, NSUInteger index) {
    NSUInteger count = 0;
    const EBFrameStep *steps = StepsFor(exercise, &count);
    return (steps && index < count) ? steps[index].frame : EBFrameDefault;
}

@implementation EBExerciseAnimation {
    int _state;
    int _timeout; // in 100 ms steps, as in the original
    NSImage *_current;
}

- (instancetype)initWithExercise:(EBExercise)exercise {
    if ((self = [super init])) {
        _exercise = exercise;
        _state = 0;
        _timeout = 400;

        // Window is the one exercise whose artwork is not a personage frame.
        _current = (exercise == EBExerciseWindow) ? EBAssets.shared.windowImage
                                                   : [EBAssets.shared personage:EBExerciseFrameAt(exercise, 0)];
    }
    return self;
}

- (NSImage *)image {
    return _current;
}

- (void)advance {
    // Faithful to the original: looking out of the window never animates and never even ticks down.
    NSUInteger count = EBExerciseFrameCount(_exercise);
    if (count == 0)
        return;

    _timeout -= 100;
    if (_timeout > 0)
        return;

    _state = (_state + 1) % (int)count;
    _current = [EBAssets.shared personage:EBExerciseFrameAt(_exercise, (NSUInteger)_state)];
    _timeout = HoldFor(_exercise, (NSUInteger)_state);
}

- (CATransform3D)transform {
    // Every exercise that animates now swaps artwork instead of moving it, so nothing is ever drawn
    // offset from its position in the panel.
    return CATransform3DIdentity;
}

@end