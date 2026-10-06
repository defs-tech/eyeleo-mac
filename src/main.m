#import <AppKit/AppKit.h>
#import <mach/mach_time.h>

#import "ebapp.h"
#import "ebtrace.h"

static EBAppDelegate *gDelegate = nil;

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        EBTraceMarkLaunch();
        NSApplication *app = NSApplication.sharedApplication;
        // Menu-bar only: no Dock tile, no app switcher entry. LSUIElement in Info.plist asks for
        // the same thing at launch, and setting it here keeps that behaviour even when the
        // binary is run outside its bundle during debugging.
        app.activationPolicy = NSApplicationActivationPolicyAccessory;

        gDelegate = [[EBAppDelegate alloc] init];
        app.delegate = gDelegate;

        [app run];
    }
    return 0;
}