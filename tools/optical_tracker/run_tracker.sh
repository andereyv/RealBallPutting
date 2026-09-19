#!/usr/bin/env bash
# Runner for Optical Real-Ball Tracker using the local virtual environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python"

if [ ! -f "$VENV_PYTHON" ]; then
    echo "Virtual environment not found. Setting up..."
    python3 -m venv "$SCRIPT_DIR/.venv"
    "$SCRIPT_DIR/.venv/bin/pip" install opencv-python numpy
fi

exec "$VENV_PYTHON" "$SCRIPT_DIR/webcam_ball_tracker.py" "$@"
