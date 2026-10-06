// Settings window: two tabs, matching the original's layout (settings_wnd.cpp).
//
// The five dropdowns keep the original's fixed value lists rather than becoming free numeric
// fields, so the stored values stay within the ranges the core clamps to:
//   interval      {20,25,30,35,40,45,50,60,90,120} minutes
//   duration      {2,3,4,5,7,10,15,20} minutes
//   warning delay {20, 30, 60, 90} seconds
//   short interval{5,8,10,15,20,30} minutes
//   short duration{8,15,20} seconds

#ifndef EB_SETTINGSUI_H
#define EB_SETTINGSUI_H

#import <AppKit/AppKit.h>

#import "ebcore.h"

NS_ASSUME_NONNULL_BEGIN

@interface EBSettingsWindow : NSWindowController

- (instancetype)initWithSettings:(EBSettings)settings
                           stats:(EBStats)stats
                    startAtLogin:(BOOL)startAtLogin;

// Called when the user saves or closes the window.
@property(nonatomic, copy, nullable) void (^onSave)(EBSettings settings, BOOL startAtLogin);
// "Try short break" / "Try long break".
@property(nonatomic, copy, nullable) void (^onDemo)(BOOL longBreak);
// Login item state, owned by the app through SMAppService.
@property(nonatomic, copy, nullable) BOOL (^onQueryStartAtLogin)(void);
@property(nonatomic, copy, nullable) BOOL (^onSetStartAtLogin)(BOOL enabled);

@end

NS_ASSUME_NONNULL_END

#endif // EB_SETTINGSUI_H