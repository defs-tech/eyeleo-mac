#import "ebdetect.h"

#import <AppKit/AppKit.h>

double EBIdleSeconds(void) {
    return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
}

// A window counts as fullscreen when it covers a display frame exactly and sits on a
// normal window layer. Comparing against visibleFrame instead of frame would also match
// maximised windows, which are not what the original treats as blocking.
static BOOL WindowCoversDisplay(CGRect win, CGRect display) {
    if (display.size.width <= 0 || display.size.height <= 0)
        return false;
    return fabs(win.origin.x - display.origin.x) < 2.0 && fabs(win.origin.y - display.origin.y) < 2.0 &&
           fabs(win.size.width - display.size.width) < 2.0 && fabs(win.size.height - display.size.height) < 2.0;
}

int EBFullscreenDisplay(void) {
    @autoreleasepool {
        NSArray<NSScreen *> *screens = NSScreen.screens;
        if (screens.count == 0)
            return -1;

        CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        if (!wins)
            return -1;

        int found = -1;
        // CG coordinates are already in the same top-left space NSScreen.frame uses.
        for (CFIndex i = 0; i < CFArrayGetCount(wins) && found < 0; i++) {
            CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
            if (!w)
                continue;

            int layer = 0;
            CFNumberRef lv = CFDictionaryGetValue(w, kCGWindowLayer);
            if (lv)
                CFNumberGetValue(lv, kCFNumberIntType, &layer);
            if (layer != 0)
                continue; // ignore menu bar, docks, tooltips

            CFNumberRef alphaRef = CFDictionaryGetValue(w, kCGWindowAlpha);
            if (alphaRef) {
                double alpha = 1.0;
                if (CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha) && alpha < 0.99)
                    continue; // ignore fades and shadows
            }

            CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
            CGRect r;
            if (!b || !CGRectMakeWithDictionaryRepresentation(b, &r))
                continue;

            for (NSUInteger d = 0; d < screens.count; d++) {
                if (WindowCoversDisplay(r, screens[d].frame)) {
                    found = (int)d;
                    break;
                }
            }
        }
        CFRelease(wins);
        return found;
    }
}