#import "ebtrace.h"

#import <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t gStartTicks = 0;
static uint64_t gLastTicks = 0;
static int gLap = 0;
static int gEnabled = 0;

static double MsSince(uint64_t since) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info(&tb);
    });
    return (double)(mach_absolute_time() - since) * (double)tb.numer / (double)tb.denom / 1e6;
}

void EBTraceMarkLaunch(void) {
    const char *env = getenv("EYELEO_DEBUG");
    gEnabled = env && env[0] == '1';
    if (!gEnabled)
        return;
    gStartTicks = mach_absolute_time();
    gLastTicks = gStartTicks;
}

void EBTraceLap(const char *label) {
    if (!gEnabled || !gStartTicks)
        return;
    gLap++;
    fprintf(stderr, "[EB] startup %2d  %-26s  +%6.1f ms  (total %6.1f ms)\n", gLap, label, MsSince(gLastTicks),
            MsSince(gStartTicks));
    fflush(stderr);
    gLastTicks = mach_absolute_time();
}
