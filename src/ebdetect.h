// Pure C so it can be compiled either into the app or replaced by a test stub.

#ifndef EB_DETECT_H
#define EB_DETECT_H

#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

// Seconds since the last user input event of any type.
// Uses CGEventSourceStateCombinedSessionState, which reports session-wide input activity
// without any TCC grant. Verified on this machine: AXIsProcessTrusted() false while values
// still advance. Do NOT substitute kCGEventSourceStatePrivate: it hangs under the sandbox.
double EBIdleSeconds(void);

// Index into NSScreen.screens of the display covered by a frontmost fullscreen window, or -1
// when nothing is fullscreen (also -1 when the check cannot be made).
//
// CGWindowListCopyWindowInfo exposes owner name and bounds without Screen Recording permission,
// so fullscreen detection costs no user-facing permission either.
int EBFullscreenDisplay(void);

#ifdef __cplusplus
}
#endif

#endif // EB_DETECT_H