// Startup tracing, active only under EYELEO_DEBUG=1.
//
// Cold start was measured against a 300 ms budget, so each stage reports its own cost. Without
// this the only visible signal was "slow", which is not actionable. Labels are plain C strings on
// purpose: NSString formatting was producing garbage for these fields.

#ifndef EB_TRACE_H
#define EB_TRACE_H

// Records the process start. No output unless EYELEO_DEBUG=1.
void EBTraceMarkLaunch(void);

// Prints the time since launch and since the previous lap.
void EBTraceLap(const char *label);

#endif // EB_TRACE_H
