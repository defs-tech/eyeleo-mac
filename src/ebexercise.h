// Exercise selection and the personage animation, ported from
// source/code/excercises.cpp and MiniPauseControls::Init (minipause_wnd.cpp:224).
//
// The original misspells "exercise" as "excercise" throughout; the spelling is corrected here
// because this is new code rather than a copy.

#ifndef EB_EXERCISE_H
#define EB_EXERCISE_H

#import <AppKit/AppKit.h>
#import "ebassets.h"

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
    // Added in the port, ids 8, 9 and 10. Nothing existing was removed or reworded: the new exercises
    // simply join the pool, and every id 1..7 keeps its original text.
    EBExerciseBlinkFully,  // close the eyes fully and gently, ten times
    EBExerciseNeckShoulders, // roll and release the shoulders
    EBExercisePalming,      // cover the eyes with both paws
};

static const int EBNumExercises = 10; // exercises 1..10, the original's 1..7 plus three new ones

// The drawn frames one exercise cycles through, in order. Both the frame the short break sizes its
// picture for and every frame shown afterwards are read from this one list, so an exercise can never
// open on one picture and swap to another of a different size. Looking out of the window does not
// animate artwork at all, and the remaining exercises hold a single static head, so both report 0.
// Every frame within a cycle is guaranteed to be the same pixel size; the test enforces it against
// the shipped files.
NSUInteger EBExerciseFrameCount(EBExercise exercise);

// The frame at index within the cycle above, wrapping for animation purposes but not for this
// accessor: an index past the end yields EBFrameDefault, which is also what a static exercise holds.
EBPersonageFrame EBExerciseFrameAt(EBExercise exercise, NSUInteger index);

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

// Port of ExcerciseAnim, with the timeouts of the original kept exactly except for "stretch", which
// the original never animated at all and which now cycles through real frames.
@interface EBExerciseAnimation : NSObject

- (instancetype)initWithExercise:(EBExercise)exercise NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) EBExercise exercise;
@property(nonatomic, readonly, nullable) NSImage *image;

// Offsets the artwork must be drawn at, on top of its position in the panel. Identity for every
// exercise that swaps artwork instead of moving it. CATransform3D rather than CGAffineTransform
// because it is assigned straight to CALayer.transform.
@property(nonatomic, readonly) CATransform3D transform;

// Call once per 100 ms.
- (void)advance;

@end

NS_ASSUME_NONNULL_END

#endif // EB_EXERCISE_H