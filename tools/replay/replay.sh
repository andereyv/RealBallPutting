#!/bin/bash
# Replay a Quest session recording through the real tracker + speed code on the Mac.
#
#   tools/replay/replay.sh                 # newest recording in tools/sessions
#   tools/replay/replay.sh <rec_dir>
#
# Needs: a JDK (javac; the one used for Android builds is fine) and Godot 4.7.2 (set GODOT=/path/to/Godot if not found).
set -e
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REC="${1:-$(ls -dt "$PROJ"/tools/sessions/files/recordings/rec_* 2>/dev/null | head -1)}"
[ -d "$REC" ] || { echo "No recording found. Run tools/pull_sessions.sh first or pass a rec_ folder."; exit 1; }

# --- Java (JDK) ---
if ! command -v javac >/dev/null 2>&1; then
  if [ -x /usr/libexec/java_home ]; then export JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null)"; fi
  [ -n "$JAVA_HOME" ] && export PATH="$JAVA_HOME/bin:$PATH"
fi
command -v javac >/dev/null 2>&1 || { echo "javac not found - install a JDK or set JAVA_HOME"; exit 1; }

# --- Godot 4.7.2 ---
if [ -z "$GODOT" ]; then
  for app in $(mdfind 'kMDItemCFBundleIdentifier == org.godotengine.godot' 2>/dev/null) /Applications/Godot*.app; do
    bin="$app/Contents/MacOS/Godot"
    if [ -x "$bin" ] && "$bin" --version 2>/dev/null | grep -q '^4\.7\.2'; then GODOT="$bin"; break; fi
  done
fi

OUT="$PROJ/tools/replay/build"
mkdir -p "$OUT"
javac -nowarn -d "$OUT" "$PROJ/android/build/src/main/java/com/godot/game/PuttTracker.java" "$PROJ/tools/replay/ReplayRunner.java"
echo "=== Tracker replay: $REC"
java -cp "$OUT" ReplayRunner "$REC"

if [ -n "$GODOT" ]; then
  echo "=== Speed (Godot $("$GODOT" --version | head -1))"
  "$GODOT" --headless --path "$PROJ" --script tools/replay/replay_speed.gd -- "$REC" 2>/dev/null | grep -v -i -E "openxr|hmd was not|godot will start|check logged|^\s*at:|^$"
else
  echo "(Godot 4.7.2 not found - set GODOT=/path/to/Godot.app/Contents/MacOS/Godot to also compute speeds)"
fi
