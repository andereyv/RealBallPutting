#!/bin/bash
# Floor-tracking work in progress (Fix 14). Compiles either the committed tracker (baseline) or the committed tracker
# with patch_tracker.py applied (wip) and replays the regression set in tools/sessions/regression.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; PROJ="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-wip}"
SRC="$PROJ/android/build/src/main/java/com/godot/game/PuttTracker.java"
OUT="$PROJ/tools/replay/build/$MODE"; GEN="$OUT/src/com/godot/game"
rm -rf "$OUT"; mkdir -p "$GEN"
cp "$SRC" "$GEN/PuttTracker.java"
[ "$MODE" = "wip" ] && python3 "$HERE/patch_tracker.py" "$GEN/PuttTracker.java"
javac -nowarn -d "$OUT" "$GEN/PuttTracker.java" "$PROJ/tools/replay/ReplayRunner.java"
python3 "$HERE/regress.py" "$OUT"
