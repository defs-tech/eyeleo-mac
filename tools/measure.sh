#!/bin/bash
# Reports the numbers the design was aiming at: binary size, cold start, and memory at idle and
# during a break. Budgets come from README.md; the script only measures, it does not judge.
#
#   ./tools/measure.sh
#
# Requires a build first (make). Uses EYELEO_DEBUG to time the first scheduler tick and
# EYELEO_FAST_MODE/EYELEO_TEST_INTERVAL_MIN to trigger a break without waiting 50 minutes.

set -uo pipefail   # deliberately no -e: a failed optional measurement must not abort the report

cd "$(dirname "$0")/.."

APP="build/EyeLeo.app"
BIN="$APP/Contents/MacOS/EyeLeo"
BUDGET_IDLE_KB=12288   # 12 MB
BUDGET_BREAK_KB=25600  # 25 MB
BUDGET_BINARY_KB=3072  # 3 MB
BUDGET_START_MS=500   # process spawn plus harness polling; the app's own share is ~75 ms

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
row() { printf '  %-34s %10s   (budget %s)\n' "$1" "$2" "$3"; }

if [[ ! -x "$BIN" ]]; then
    red "no build at $BIN — run make first"
    exit 1
fi

pkill -f 'MacOS/EyeLeo' >/dev/null 2>&1 || true
sleep 1

echo "== size =="
BIN_KB=$(( $(stat -f%z "$BIN") / 1024 ))
BUNDLE_KB=$(( $(du -sk "$APP" | cut -f1) ))
row "binary" "${BIN_KB} KB" "$(( BUDGET_BINARY_KB )) KB"
row "bundle (with resources)" "${BUNDLE_KB} KB" "-"
[[ $BIN_KB -le $BUDGET_BINARY_KB ]] && green "  binary within budget" || red "  binary OVER budget"

echo
echo "== linked libraries =="
otool -L "$BIN" | tail -n +2 | awk '{print "  " $1}' | sed 's/ (.*//'

echo
echo "== cold start (process spawn -> app ready) =="
LOG=$(mktemp)
# perl's Time::HiRes costs a few ms to start; python3 would add ~100 ms to the measurement
START=$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time')
EYELEO_DEBUG=1 "$BIN" >"$LOG" 2>&1 &
APP_PID=$!
for _ in $(seq 1 200); do
    if grep -q 'ready' "$LOG" 2>/dev/null; then break; fi
    sleep 0.01
done
TICK_AT=$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time')
START_MS=$(perl -e "printf \"%d\", ($TICK_AT - $START) * 1000")
row "spawn to app ready" "${START_MS} ms" "${BUDGET_START_MS} ms"
[[ $START_MS -le $BUDGET_START_MS ]] && green "  start within budget" || red "  start OVER budget"

echo
echo "== memory at idle (menu bar only) =="
sleep 2
# footprint is the right tool but it refuses some processes, so vmmap is the fallback. Note the
# units differ: footprint prints "Footprint: 10 MB", vmmap prints "Physical footprint: 9.8M".
footprint_mb() {
    local mb kb
    mb=$(footprint -p "$1" 2>/dev/null | head -1 \
        | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]+MB' | grep -oE '[0-9]+(\.[0-9]+)?' || true)
    if [[ -n "${mb:-}" ]]; then
        echo "${mb%%.*}"
        return
    fi
    kb=$(vmmap -summary "$1" 2>/dev/null | grep -i 'physical footprint:' \
        | grep -oE '[0-9]+(\.[0-9]+)?[KMG]' | head -1 || true)
    # strip the fractional part before any arithmetic: bash will not do arithmetic on "9.8"
    case "$kb" in
        *K) echo $(( ${kb%K} / 1024 )) ;;
        *G) echo $(( ${kb%G} * 1024 )) ;;
        *M) echo "${kb%M}" | cut -d. -f1 ;;
        *) echo 0 ;;
    esac
}

IDLE_KB=$(footprint_mb "$APP_PID")
row "footprint, idle" "${IDLE_KB} MB" "$(( BUDGET_IDLE_KB / 1024 )) MB"
RSS_IDLE=$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ' || true)
RSS_IDLE=${RSS_IDLE:-0}
row "resident, idle" "$(( RSS_IDLE / 1024 )) MB" "-"

echo
echo "== memory during a short break =="
pkill -f 'MacOS/EyeLeo' >/dev/null 2>&1 || true
sleep 1
LOG2=$(mktemp)
EYELEO_DEBUG=1 EYELEO_FAST_MODE=1 EYELEO_TEST_INTERVAL_MIN=1 EYELEO_TEST_ONLY=short \
    "$BIN" >"$LOG2" 2>&1 &
APP_PID=$!
PEAK=0

for _ in $(seq 1 60); do
    sleep 1
    NOW=$(footprint_mb "$APP_PID")
    [[ -z "${NOW:-}" ]] && continue
    [[ "$NOW" -gt "$PEAK" ]] && PEAK=$NOW
    grep -q 'fast timer armed' "$LOG2" 2>/dev/null && break
done
row "peak footprint, during break" "${PEAK:-?} MB" "$(( BUDGET_BREAK_KB / 1024 )) MB"
[[ "${PEAK:-9999}" -le $(( BUDGET_BREAK_KB / 1024 )) ]] && green "  break within budget" || red "  break OVER budget"

echo
echo "== security =="
echo -n "  entitlements: "
codesign -d --entitlements - "$APP" 2>/dev/null | grep -o 'com\.apple\.security\.[a-z.-]*' | sort -u | tr '\n' ' ' || true
echo
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'network'; then
    red "  network entitlement present"
else
    green "  no network entitlement"
fi
if nm -u "$BIN" 2>/dev/null | grep -qE 'NSURLSession|CFNetwork|CFSocket|_socket$|connect$'; then
    red "  binary references networking symbols"
else
    green "  no networking symbols referenced"
fi

pkill -f 'MacOS/EyeLeo' >/dev/null 2>&1 || true
rm -f "$LOG" "$LOG2"
echo
echo "done"