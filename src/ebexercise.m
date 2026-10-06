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
    NSImage *_current;
}

- (instancetype)initWithExercise:(EBExercise)exercise {
    if ((self = [super init])) {
        _exercise = exercise;
        _state = 0;
        _timeout = 400;

        if (exercise == EBExerciseWindow)
            _current = EBAssets.shared.windowImage;
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

    default:
        break;
    }
}

@end