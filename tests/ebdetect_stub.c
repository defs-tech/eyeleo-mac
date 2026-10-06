// Test seam for the core: lets the unit tests drive "how idle is the user" and
// "is something fullscreen" deterministically, without a window server.

#include "ebdetect.h"

static double g_idleSeconds = 0.0;
static int g_fullscreenDisplay = -1;

void EBTestSetIdleSeconds(double s) {
    g_idleSeconds = s;
}

void EBTestSetFullscreenDisplay(int display) {
    g_fullscreenDisplay = display;
}

double EBIdleSeconds(void) {
    return g_idleSeconds;
}

int EBFullscreenDisplay(void) {
    return g_fullscreenDisplay;
}