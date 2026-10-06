// App shell: menu bar item, menu, scheduler, single-instance guard, login item.

#ifndef EB_APP_H
#define EB_APP_H

#import <AppKit/AppKit.h>

#import "ebcore.h"
#import "ebwindows.h"

NS_ASSUME_NONNULL_BEGIN

@interface EBAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, EBCoreDelegate, EBOverlayDelegate>

@property(nonatomic, readonly) EBCore *core;
@property(nonatomic, readonly) EBOverlayController *overlays;

- (void)openSettings;

@end

NS_ASSUME_NONNULL_END

#endif // EB_APP_H