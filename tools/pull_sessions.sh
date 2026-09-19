#!/usr/bin/env bash
# Pull recorded putt sessions and snapshots from Quest 3 to local Mac folder

DEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sessions"
mkdir -p "$DEST_DIR"

DEVICE=$(adb devices | grep -E "device$" | head -n 1 | awk '{print $1}')

if [ -z "$DEVICE" ]; then
    echo "❌ No ADB device found. Connect Quest 3 via USB or Wi-Fi first."
    exit 1
fi

echo "📦 Pulling putt sessions from Quest ($DEVICE)..."
adb -s "$DEVICE" pull /storage/emulated/0/Android/data/com.example.realballputting/files/ "$DEST_DIR/"
echo "✅ Sessions pulled to: $DEST_DIR"
