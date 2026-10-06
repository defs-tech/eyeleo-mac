// Lists on-screen windows so overlay behaviour can be verified without Screen Recording.
//
// CGWindowListCopyWindowInfo exposes owner names and bounds without any permission; only the
// window *images* and *titles* are gated. That is enough to confirm that EyeLeo put an overlay
// of the expected size in the expected place.
//
//   clang -O2 -fobjc-arc -o build/windows tools/windows.m -framework AppKit
//   ./build/windows              list everything
//   ./build/windows EyeLeo       only windows owned by EyeLeo

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

static BOOL MatchesOwner(CFDictionaryRef w, NSString *filter) {
    CFStringRef owner = CFDictionaryGetValue(w, kCGWindowOwnerName);
    if (!owner)
        return NO;
    NSString *name = (__bridge NSString *)owner;
    if (!filter)
        return YES; // no filter means list everything
    return [name rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *KindOf(CFDictionaryRef w) {
    int layer = 0;
    CFNumberRef lv = CFDictionaryGetValue(w, kCGWindowLayer);
    if (lv)
        CFNumberGetValue(lv, kCFNumberIntType, &layer);
    if (layer != 0)
        // Report the number: two windows at the same level reorder when clicked, which is exactly
        // the bug that let the dimming layer cover the exercise panel.
        return [NSString stringWithFormat:@"layer=%d", layer];
    CFNumberRef onscreen = CFDictionaryGetValue(w, kCGWindowIsOnscreen);
    int on = 0;
    if (onscreen)
        CFNumberGetValue(onscreen, kCFNumberIntType, &on);
    return on ? @"normal" : @"offscreen";
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *filter = argc > 1 ? @(argv[1]) : nil;

        CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        if (!wins) {
            fprintf(stderr, "CGWindowListCopyWindowInfo returned NULL\n");
            return 2;
        }

        // Who actually holds keyboard focus. This is the ground truth for "did the break take
        // the keyboard"; NSApp.isActive inside the app is not, for a background-only app.
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        printf("frontmost: %s (pid %d)\n", front.bundleIdentifier.UTF8String ?: "(none)",
               front.processIdentifier);

        // Report the display layout too: overlay positions are relative to it.
        for (NSScreen *screen in NSScreen.screens)
            printf("display: %.0f,%.0f %.0fx%.0f backingScale=%.0f\n", screen.frame.origin.x,
                   screen.frame.origin.y, screen.frame.size.width, screen.frame.size.height,
                   screen.backingScaleFactor);

        int matched = 0;
        for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
            CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
            if (!w || !MatchesOwner(w, filter))
                continue;

            CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
            CGRect r = CGRectZero;
            if (b)
                CGRectMakeWithDictionaryRepresentation(b, &r);

            CFStringRef owner = CFDictionaryGetValue(w, kCGWindowOwnerName);
            char ownerBuf[256] = {0};
            if (owner)
                CFStringGetCString(owner, ownerBuf, sizeof(ownerBuf), kCFStringEncodingUTF8);

            double alpha = 1.0;
            CFNumberRef av = CFDictionaryGetValue(w, kCGWindowAlpha);
            if (av)
                CFNumberGetValue(av, kCFNumberDoubleType, &alpha);
            int onscreen = 0;
            CFNumberRef os = CFDictionaryGetValue(w, kCGWindowIsOnscreen);
            if (os)
                CFNumberGetValue(os, kCFNumberIntType, &onscreen);

            printf("  owner=\"%s\" bounds=%.0f,%.0f %.0fx%.0f alpha=%.2f onscreen=%d %s\n", ownerBuf,
                   r.origin.x, r.origin.y, r.size.width, r.size.height, alpha, onscreen,
                   [KindOf(w) UTF8String]);
            matched++;
        }
        CFRelease(wins);
        printf("matched=%d\n", matched);
        return matched > 0 ? 0 : 1;
    }
}