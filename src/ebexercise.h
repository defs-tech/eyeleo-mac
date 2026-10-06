// Exercise selection and the personage animation, ported from
// source/code/excercises.cpp and MiniPauseControls::Init (minipause_wnd.cpp:224).
//
// The original misspells "exercise" as "excercise" throughout; the spelling is corrected here
// because this is new code rather than a copy.

#ifndef EB_EXERCISE_H
#define EB_EXERCISE_H

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, EBExercise) {
    EBExerciseNone = 0,
    EBExerciseRoll,        // look left/right/up/down in turn
    EBExerciseLookVert,    // up and down
    EBExerciseLookHorz,    // left and right
    EBExerciseCloseTightly,
    EBExerciseBlink,
    EBExerciseWindow,      // look at distant objects; excluded unless "window nearby" is on
    EBExerciseStretch,
};

static const int EBNumExercises = 7; // exercises 1..7

@interface EBExercisePicker : NSObject

// Port of the pick loop in MiniPauseControls::Init: up to 32 attempts, never the same
// exercise twice in a row, and never "look at the window" when that setting is off.
+ (EBExercise)pickAfter:(EBExercise)last windowNearby:(BOOL)windowNearby;

// How many distinct phrasings exist for this exercise (the original probes keys 1..19).
+ (int)lineCountFor:(EBExercise)exercise;

// Random phrasing, 1-based.
+ (int)pickLineFor:(EBExercise)exercise;

+ (NSString *)textFor:(EBExercise)exercise line:(int)line;

@end

// Port of ExcerciseAnim. Timeouts are reproduced exactly, including the quirk that
// "look at the window" and "stretch" never animate.
@interface EBExerciseAnimation : NSObject

- (instancetype)initWithExercise:(EBExercise)exercise NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) EBExercise exercise;
@property(nonatomic, readonly, nullable) NSImage *image;

// Call once per 100 ms.
- (void)advance;

@end

NS_ASSUME_NONNULL_END

#endif // EB_EXERCISE_H