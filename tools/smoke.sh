#!/bin/bash
# End-to-end smoke test: does the built app actually work?
#
# Runs the core unit tests, the localization coverage check, and then drives two accelerated break
# cycles against the real binary, asserting on the EYELEO_DEBUG trace. Everything it checks is
# something the app reported about itself, so it verifies behaviour rather than mere absence of
# crashes.
#
#   ./tools/smoke.sh
#
# Exits non-zero if any check fails. Takes about two minutes, because it waits for real timers.

set -uo pipefail
cd "$(dirname "$0")/.."

BIN="build/EyeLeo.app/Contents/MacOS/EyeLeo"
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
check() {
    # check <description> <file> <pattern>
    # grep -E: patterns like ".+" are ERE, and in plain grep "+" is a literal plus
    if grep -qE "$3" "$2" 2>/dev/null; then
        green "  PASS  $1"
        PASS=$((PASS + 1))
    else
        red "  FAIL  $1"
        FAIL=$((FAIL + 1))
    fi
}

APP_PID=""

launch() {
    # shellcheck disable=SC2068
    env "$@" "$BIN" >"$LOG" 2>&1 &
    APP_PID=$!
}

# Kills the instance and reaps it, so bash does not print "Terminated" for the background job.
stop_app() {
    if [[ -n "$APP_PID" ]]; then
        kill "$APP_PID" >/dev/null 2>&1
        wait "$APP_PID" 2>/dev/null
        APP_PID=""
    fi
    pkill -f 'MacOS/EyeLeo' >/dev/null 2>&1
    sleep 1
}

# Waits until <file> contains <pattern> or <seconds> elapse. Returns 0 on match.
wait_for() {
    local file=$1 pattern=$2 limit=${3:-60} waited=0
    while ((waited < limit * 10)); do
        grep -qE "$pattern" "$file" 2>/dev/null && return 0
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

if [[ ! -x "$BIN" ]]; then
    red "no build at $BIN — run make first"
    exit 2
fi

echo "== unit tests =="
if out=$(make test 2>&1); then
    green "  PASS  $(echo "$out" | grep -o '[0-9]* checks, [0-9]* failures' | tail -1)"
    PASS=$((PASS + 1))
else
    red "  FAIL  unit tests"
    echo "$out" | tail -20
    FAIL=$((FAIL + 1))
fi

echo
echo "== localization =="
clang -O2 -fobjc-arc -mmacosx-version-min=26.0 -Isrc -o build/checkstrings \
    tools/check_strings.m src/ebtext.m src/ebcore.m tests/ebdetect_stub.c -framework Foundation 2>/dev/null
for lang in en ru; do
    missing=$(./build/checkstrings "build/EyeLeo.app" "$lang" 2>/dev/null | sed -n 's/^keys checked: [0-9]*, missing: //p')
    if [[ "${missing:-1}" == "0" ]]; then
        green "  PASS  $lang: every key resolves"
        PASS=$((PASS + 1))
    else
        red "  FAIL  $lang: ${missing:-?} keys missing"
        FAIL=$((FAIL + 1))
    fi
done

# A locked or sleeping screen has no foreground session, so macOS never lets a background-only app
# take key focus. The focus checks below are meaningless there and are reported as skipped.
SCREEN_LOCKED=0
front=$(./build/windows 2>/dev/null | sed -n 's/^frontmost: \([^ ]*\).*/\1/p')
if [[ "$front" == "com.apple.loginwindow" || -z "$front" ]]; then
    SCREEN_LOCKED=1
fi

echo
echo "== menu bar item =="
LOG="build/smoke-menubar.log"
stop_app
launch EYELEO_DEBUG=1
if wait_for "$LOG" 'status item:' 15; then
    check "status icon loaded and is 22pt" "$LOG" 'icon=ok size=22x22 template=1'
    check "status button is on screen" "$LOG" 'visible=1'
    # A button with zero height is present and invisible; that was the original bug.
    if grep -q 'button=[0-9.]*,[0-9.]* [0-9]*x[1-9]' "$LOG"; then
        green "  PASS  button has non-zero height"
        PASS=$((PASS + 1))
    else
        red "  FAIL  button has zero height (menu bar item would be invisible)"
        FAIL=$((FAIL + 1))
    fi
else
    red "  FAIL  no status item trace"
    FAIL=$((FAIL + 1))
fi
stop_app

echo
echo "== short break cycle =="
LOG="build/smoke-short.log"
stop_app
launch EYELEO_DEBUG=1 EYELEO_FAST_MODE=1 EYELEO_TEST_INTERVAL_MIN=1 EYELEO_TEST_ONLY=short
if wait_for "$LOG" 'dim layer:' 90; then
    check "screen is dimmed during the break" "$LOG" 'dim layer: .* dim=0\.78 blur=off'

    # The regression this catches: the dimming layer window exists and is full screen, but its
    # alpha is still 0, so nothing is drawn. Only the window server knows the real alpha, so this
    # asks it rather than trusting the app's own trace.
    clang -O2 -fobjc-arc -mmacosx-version-min=26.0 -o build/windows tools/windows.m -framework AppKit 2>/dev/null
    listing=$(./build/windows EyeLeo 2>/dev/null)
    if grep -qE 'alpha=1\.[0-9]+' <<<"$listing" && grep -qE 'bounds=[0-9]+,[0-9]+ 1[0-9]{3}x[0-9]+' <<<"$listing"; then
        green "  PASS  dimming layer is on screen at full window alpha"
        PASS=$((PASS + 1))
    else
        red "  FAIL  no full screen layer at alpha 1.0 (dimming would be invisible)"
        FAIL=$((FAIL + 1))
    fi
    # Clicking the dimming layer used to bring it to the front of its level and push the exercise
    # panel behind it. It now sits one level lower, which makes that ordering impossible.
    if grep -q 'layer=3' <<<"$listing" && grep -q 'layer=2' <<<"$listing"; then
        green "  PASS  panel and dimming layer are on separate window levels"
        PASS=$((PASS + 1))
    else
        red "  FAIL  panel and dimming layer share a level; a click will hide the panel"
        FAIL=$((FAIL + 1))
    fi
    # activation settles 400 ms after the window is ordered in, so this line is never there yet
    if wait_for "$LOG" 'capture settled' 10; then
        if ((SCREEN_LOCKED)); then
            printf '  SKIP  keyboard capture (screen is locked, no foreground session)\n'
        else
            check "keyboard is taken" "$LOG" 'capture settled: appActive=1 key=1'
        fi
    else
        red "  FAIL  activation never settled"
        FAIL=$((FAIL + 1))
    fi
    if wait_for "$LOG" 'restore focus to' 40; then
        check "focus goes back afterwards" "$LOG" 'restore focus to ".+"'
    else
        red "  FAIL  focus was never returned"
        FAIL=$((FAIL + 1))
    fi
else
    red "  FAIL  the short break never appeared"
    FAIL=$((FAIL + 3))
fi
stop_app

echo
echo "== long break cycle =="
LOG="build/smoke-long.log"
stop_app
launch EYELEO_DEBUG=1 EYELEO_FAST_MODE=1 EYELEO_TEST_INTERVAL_MIN=5 EYELEO_TEST_ONLY=long
if wait_for "$LOG" 'idle -> none' 90; then
    check "countdown leads into the break" "$LOG" 'idle -> none'
fi
if wait_for "$LOG" 'none -> relaxing' 90; then
    check "long break screen shown" "$LOG" 'none -> relaxing'
    check "long break dims without blurring" "$LOG" 'dim layer: .* dim=0\.78 blur=off'
    wait_for "$LOG" 'capture settled' 10
    if ((SCREEN_LOCKED)); then
        printf '  SKIP  keyboard capture (screen is locked, no foreground session)\n'
    else
        check "keyboard taken on the long break too" "$LOG" 'capture settled: appActive=1 key=1'
    fi
else
    red "  FAIL  the long break never started"
    FAIL=$((FAIL + 2))
fi
stop_app

echo
echo "== result =="
if ((FAIL == 0)); then
    green "$PASS checks passed, 0 failed"
    exit 0
fi
red "$PASS checks passed, $FAIL failed"
red "traces from the last run are in build/smoke-*.log"
exit 1
