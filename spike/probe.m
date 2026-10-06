// Phase 0 probe: verifies that the three assumptions the whole design rests on hold
// on a machine with zero TCC permissions granted.
//
//  1. CGEventSourceSecondsSinceLastEventType(.combinedSessionState) yields activity
//     time without any Accessibility / Input Monitoring grant.
//  2. CGWindowListCopyWindowInfo yields window bounds without Screen Recording.
//  3. Baseline footprint of a plain NSStatusItem app.
//
// Prints a machine-readable verdict, then exits.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/task_info.h>

static uint64_t PhysFootprintKB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint / 1024;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        printf("=== TCC status (queried WITHOUT prompting) ===\n");
        printf("AXIsProcessTrusted          = %s   (Accessibility)\n", AXIsProcessTrusted() ? "true" : "false");
        printf("CGPreflightScreenCapture    = %s   (Screen Recording)\n",
               CGPreflightScreenCaptureAccess() ? "true" : "false");

        printf("\n=== 1. activity detection via CGEventSource (no permission needed) ===\n");
        CGEventSourceStateID states[2] = {
            kCGEventSourceStateCombinedSessionState,
            kCGEventSourceStateHIDSystemState,
        };
        const char *names[2] = {"combinedSessionState", "HIDSystemState"};
        double first[2], second[2];
        for (int i = 0; i < 2; i++) {
            first[i] = CGEventSourceSecondsSinceLastEventType(states[i], kCGAnyInputEventType);
            printf("  %-20s first=%.3f s", names[i], first[i]);
            if (first[i] < 0)
                printf("  (UNSUPPORTED)");
            printf("\n");
        }
        printf("  (sleeping 1.5 s, no input generated)\n");
        [NSThread sleepForTimeInterval:1.5];
        for (int i = 0; i < 2; i++) {
            second[i] = CGEventSourceSecondsSinceLastEventType(states[i], kCGAnyInputEventType);
            printf("  %-20s second=%.3f s  delta=%+.3f s\n", names[i], second[i], second[i] - first[i]);
        }
        int activity_ok = (first[0] >= 0 && second[0] > first[0]);
        printf("VERDICT activity_combined_session = %s\n", activity_ok ? "OK" : "FAIL");

        printf("\n=== 2. window bounds via CGWindowList (no Screen Recording needed?) ===\n");
        CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        if (!wins) {
            printf("  CGWindowListCopyWindowInfo returned NULL\n");
            printf("VERDICT window_bounds = FAIL\n");
            activity_ok = 0;
        } else {
            CFIndex n = CFArrayGetCount(wins);
            printf("  on-screen windows visible: %ld\n", (long)n);
            int shown = 0, with_bounds = 0;
            for (CFIndex i = 0; i < n && shown < 8; i++) {
                CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
                CFStringRef owner = CFDictionaryGetValue(w, kCGWindowOwnerName);
                CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
                if (!owner || !b)
                    continue;
                CGRect r;
                if (!CGRectMakeWithDictionaryRepresentation(b, &r))
                    continue;
                with_bounds++;
                char own[256] = {0};
                CFStringGetCString(owner, own, sizeof(own), kCFStringEncodingUTF8);
                int layer = 0;
                CFNumberRef lv = CFDictionaryGetValue(w, kCGWindowLayer);
                if (lv)
                    CFNumberGetValue(lv, kCFNumberIntType, &layer);
                if (shown >= 3 || r.size.width > 400)
                    printf("    owner=\"%s\" bounds=%.0f,%.0f %.0fx%.0f layer=%d\n",
                           own, r.origin.x, r.origin.y, r.size.width, r.size.height, layer);
                shown++;
            }
            CFRelease(wins);
            printf("VERDICT window_bounds = %s (%d windows with readable bounds)\n",
                   with_bounds > 0 ? "OK" : "FAIL", with_bounds);
            if (with_bounds == 0)
                activity_ok = 0;
        }

        printf("\n=== 3. footprint ===\n");
        NSStatusItem *item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        item.button.title = @"probe";
        [NSApp finishLaunching];
        printf("phys_footprint after NSStatusItem = %llu KB\n", PhysFootprintKB());
        printf("\nRESULT=%s\n", activity_ok ? "ALL_ASSUMPTIONS_HOLD" : "SOME_ASSUMPTION_FAILED");
        exit(activity_ok ? 0 : 1);
    }
}