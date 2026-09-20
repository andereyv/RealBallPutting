#!/usr/bin/env bash
# Pull session recordings from the Quest to the Mac and (after verifying the copy) delete them on the headset.
#
#   tools/pull_recordings.sh              # pull, verify, delete on the Quest (keeps the newest one there)
#   tools/pull_recordings.sh --dry-run    # show what would be pulled/deleted, delete nothing
#   tools/pull_recordings.sh --keep 3     # leave the 3 newest recordings on the Quest
#   tools/pull_recordings.sh --no-delete  # only pull
#
# A recording is deleted on the Quest ONLY when every file exists on the Mac with exactly the same size.
set -u
QUEST_IP="${QUEST_IP:-192.168.2.23:5555}"
DEV_DIR="/storage/emulated/0/Android/data/com.example.realballputting/files/recordings"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sessions/files/recordings"

KEEP=1; DRY=0; DELETE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --no-delete) DELETE=0 ;;
    --keep) KEEP="$2"; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
  shift
done

adb connect "$QUEST_IP" >/dev/null 2>&1
adb -s "$QUEST_IP" shell true >/dev/null 2>&1 || { echo "❌ Quest not reachable at $QUEST_IP"; exit 1; }
mkdir -p "$DEST"

RECS=$(adb -s "$QUEST_IP" shell "ls -1 $DEV_DIR 2>/dev/null" | tr -d '\r' | grep '^rec_' | sort)
[ -n "$RECS" ] || { echo "No recordings on the Quest."; exit 0; }

TOTAL=$(echo "$RECS" | wc -l | tr -d ' ')
SKIP=$((TOTAL - KEEP))
echo "📼 $TOTAL recording(s) on the Quest; keeping the $KEEP newest there."
i=0
for rec in $RECS; do
  i=$((i + 1))
  if [ "$i" -gt "$SKIP" ]; then echo "   … $rec (kept on the Quest)"; continue; fi

  if [ ! -d "$DEST/$rec" ]; then
    echo "⬇️  $rec"
    [ "$DRY" = 1 ] || adb -s "$QUEST_IP" pull "$DEV_DIR/$rec" "$DEST/" >/dev/null || { echo "   ❌ pull failed, keeping it on the Quest"; continue; }
  else
    echo "✔️  $rec already on the Mac"
  fi
  [ "$DRY" = 1 ] && continue

  # verify: every file on the Quest must exist locally with the same size (re-pull once if it doesn't match)
  attempt=0
  ok=0
  while [ "$attempt" -lt 2 ] && [ "$ok" != 1 ]; do
  attempt=$((attempt + 1))
  ok=1
  while read -r line; do
    [ -z "$line" ] && continue
    size=${line%% *}; name=${line#* }
    local_file="$DEST/$rec/$name"
    if [ ! -f "$local_file" ]; then echo "   ⚠️  missing locally: $name"; ok=0; continue; fi
    lsize=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file")
    [ "$lsize" = "$size" ] || { echo "   ⚠️  size differs for $name ($lsize vs $size)"; ok=0; }
  done <<< "$(adb -s "$QUEST_IP" shell "cd $DEV_DIR/$rec && for f in *; do echo \$(stat -c%s \$f) \$f; done" | tr -d '\r')"

  if [ "$ok" != 1 ] && [ "$attempt" = 1 ]; then
    echo "   ↻ re-pulling $rec"
    rm -rf "$DEST/$rec"
    adb -s "$QUEST_IP" pull "$DEV_DIR/$rec" "$DEST/" >/dev/null || break
  fi
  done

  if [ "$ok" = 1 ] && [ "$DELETE" = 1 ]; then
    adb -s "$QUEST_IP" shell "rm -rf $DEV_DIR/$rec" && echo "   🗑  deleted on the Quest"
  elif [ "$ok" != 1 ]; then
    echo "   ⏭  kept on the Quest (copy not verified)"
  fi
done
echo "✅ Done. Local copies: $DEST"
du -sh "$DEST" 2>/dev/null
