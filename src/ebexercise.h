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
    // Added in the port, ids 8 and 9. Nothing existing was removed or reworded: the two new
    // exercises simply join the pool, and every id 1..7 keeps its original text and artwork.
    EBExerciseBlinkFully,  // close the eyes fully and gently, ten times
    EBExerciseNeckShoulders, // roll and release the shoulders
};

static const int EBNumExercises = 9; // exercises 1..9, matching the original's 1..7 plus the two new

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

// The second layer of the neck and shoulders exercise: the head, drawn separately from the torso so
// the two can move independently. Nil for every other exercise, which is what tells the panel to
// lay out a single image instead of a pair.
@property(nonatomic, readonly, nullable) NSImage *headImage;

// Offsets the artwork must be drawn at, on top of its position in the panel. Identity for every
// exercise that swaps artwork instead of moving it. CATransform3D rather than CGAffineTransform
// because it is assigned straight to CALayer.transform.
@property(nonatomic, readonly) CATransform3D transform;
// Applied to the head layer, which pivots at its own bottom edge so a rotation reads as tilting at
// the neck rather than spinning the face.
@property(nonatomic, readonly) CATransform3D headTransform;

// Call once per 100 ms.
- (void)advance;

@end

NS_ASSUME_NONNULL_END

#endif // EB_EXERCISE_H