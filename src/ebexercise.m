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

@implementation EBExerciseAnimation {
    int _state;
    int _timeout; // in 100 ms steps, as in the original
    int _shoulderPhase;
    NSImage *_current;
}

- (instancetype)initWithExercise:(EBExercise)exercise {
    if ((self = [super init])) {
        _exercise = exercise;
        _state = 0;
        _timeout = 400;
        _shoulderPhase = 0;

        if (exercise == EBExerciseWindow)
            _current = EBAssets.shared.windowImage;
        else if (exercise == EBExerciseNeckShoulders)
            _current = [EBAssets.shared personage:EBFrameShoulders];
        else
            _current = [EBAssets.shared personage:EBFrameDefault];
    }
    return self;
}

- (NSImage *)image {
    return _current;
}

- (void)advance {
    // Faithful to the original: these two never animate and never even tick down.
    if (_exercise == EBExerciseWindow || _exercise == EBExerciseStretch)
        return;

    _timeout -= 100;
    if (_timeout > 0)
        return;

    switch (_exercise) {
    case EBExerciseLookHorz:
        _current = [EBAssets.shared personage:_state ? EBFrameLookLeft : EBFrameLookRight];
        _state = _state ? 0 : 1;
        _timeout = 1200;
        break;

    case EBExerciseLookVert:
        _current = [EBAssets.shared personage:_state ? EBFrameLookUp : EBFrameLookDown];
        _state = _state ? 0 : 1;
        _timeout = 1200;
        break;

    case EBExerciseRoll: {
        static const EBPersonageFrame order[4] = {
            EBFrameLookLeft, EBFrameLookUp, EBFrameLookRight, EBFrameLookDown,
        };
        _current = [EBAssets.shared personage:order[_state]];
        if (++_state == 4)
            _state = 0;
        _timeout = 1200;
    } break;

    case EBExerciseBlink:
        _current = [EBAssets.shared personage:_state ? EBFrameBlink : EBFrameDefault];
        _state = _state ? 0 : 1;
        _timeout = 200;
        break;

    case EBExerciseCloseTightly:
        _current = [EBAssets.shared personage:_state ? EBFrameCloseTightly : EBFrameDefault];
        _state = _state ? 0 : 1;
        _timeout = 2000;
        break;

    case EBExerciseBlinkFully:
        // Same cadence as the plain blink, but on the closed-eyes frame for longer than its open
        // frame: the point is a complete, unhurried blink, not a fast one.
        _current = [EBAssets.shared personage:_state ? EBFrameCloseTightly : EBFrameDefault];
        _state = _state ? 0 : 1;
        _timeout = _state ? 500 : 200;
        break;

    case EBExerciseNeckShoulders:
        // Deliberately not an image swap. Generating three separate frames was tried and the leopard's
        // rosettes came out differently in each one, so the markings crawled during the animation. A
        // single baked bust is moved instead, which makes that impossible by construction.
        _shoulderPhase = (_shoulderPhase + 1) % 4;
        _timeout = 350;
        break;

    default:
        break;
    }
}

// How far the bust rides up, in points of the panel's own coordinate space -- not a fraction of the
// artwork. The artwork is 156x98, so 3.4 pt is about 3.5% of it: enough to read as a shoulder lift,
// small enough that the ears do not climb into the title. Getting this wrong by treating the value
// as a fraction produced a 0.04 pt move, invisible in practice.
static const double kShoulderLiftPt = 3.4;

- (CATransform3D)transform {
    if (_exercise != EBExerciseNeckShoulders)
        return CATransform3DIdentity;

    // Four phases per cycle: low, high, low, rest. The rest phase is what makes the movement read as
    // deliberate rather than as a twitch, and matches the unhurried pace of the original's exercises.
    // CALayer's y axis points up, so a lift is a positive translation.
    static const double kOffsets[4] = { 0.0, 1.0, 0.0, -0.35 };
    double lift = kOffsets[_shoulderPhase] * kShoulderLiftPt;
    return CATransform3DMakeTranslation(0, (float)lift, 0);
}

@end