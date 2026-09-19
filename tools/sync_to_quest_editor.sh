#!/bin/bash
# ==============================================================================
# sync_to_quest_editor.sh - Sync project files to Meta Quest Godot Editor
# Allows editing scenes, UI, and physics directly in VR using Godot Quest Editor.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

QUEST_IP="${QUEST_IP:-192.168.2.23:5555}"
DEST_PATH="/sdcard/Documents/RealBallPutting"

echo "🔌 Checking ADB connection..."
if ! adb devices | grep -q "device$"; then
    adb connect "$QUEST_IP" || true
fi

echo "📁 Ensuring directory exists on Quest: $DEST_PATH"
adb shell mkdir -p "$DEST_PATH"

echo "🔄 Syncing project files to Quest Documents..."
# Push project excluding build caches, git, and local temp files
adb push "$PROJECT_DIR/project.godot" "$DEST_PATH/"
adb push "$PROJECT_DIR/scenes" "$DEST_PATH/"
adb push "$PROJECT_DIR/scripts" "$DEST_PATH/"
adb push "$PROJECT_DIR/shaders" "$DEST_PATH/"
adb push "$PROJECT_DIR/textures" "$DEST_PATH/" 2>/dev/null || true
adb push "$PROJECT_DIR/yolov8n.onnx" "$DEST_PATH/" 2>/dev/null || true
adb push "$PROJECT_DIR/openxr_action_map.tres" "$DEST_PATH/" 2>/dev/null || true

echo "✨ Project synced to $DEST_PATH!"
echo "👉 You can now open Godot Editor in your Quest headset and open project at: $DEST_PATH"
