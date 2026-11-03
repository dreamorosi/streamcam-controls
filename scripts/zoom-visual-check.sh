#!/bin/bash
# Adapted from the diagnose skill's human-in-the-loop template. The user judges
# live framing; the script records only that verdict and USB readback metadata.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() {
    printf '\n>>> %s\n' "$1"
    read -r -p "    [Enter when done] " _
}

capture() {
    local var="$1" question="$2" answer
    printf '\n>>> %s\n' "$question"
    read -r -p "    > " answer
    printf -v "$var" '%s' "$answer"
}

if [[ "${1:-}" == --record ]]; then
    python3 "$ROOT/scripts/check-zoom.py" --result "$2"
    exit
fi
if [[ "${1:-}" != --run ]]; then
    step "Keep the live preview open and the camera/scene still. Zoom will cycle 100, 138, 200, 400 for 3 seconds each, then restore."
fi
python3 "$ROOT/scripts/check-zoom.py"
if [[ "${1:-}" == --run ]]; then
    printf '\nReport whether framing changed beyond 138. Record with --record plateau, changes, or unclear.\n'
    exit
fi
capture RESULT "Did zoom stop increasing above 138? Enter plateau, changes, or unclear."
python3 "$ROOT/scripts/check-zoom.py" --result "$RESULT"
