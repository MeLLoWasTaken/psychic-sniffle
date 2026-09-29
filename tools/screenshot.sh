#!/usr/bin/env bash
# Capture a screenshot of a Godot scene without a GPU (Mesa lavapipe Vulkan under Xvfb).
#   tools/screenshot.sh res://scenes/tests/lit_test.tscn previews/shots/lit_test.png [width height] [frames] [scene args...]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENE="$1"; OUT="$2"; W="${3:-1920}"; H="${4:-1080}"; FRAMES="${5:-60}"
mkdir -p "$(dirname "$REPO/$OUT")"
OUT_ABS="$(cd "$(dirname "$REPO/$OUT")" && pwd)/$(basename "$OUT")"
xvfb-run -a -s "-screen 0 ${W}x${H}x24" \
  godot --path "$REPO/game" --rendering-driver vulkan --audio-driver Dummy --resolution "${W}x${H}" "$SCENE" \
  -- --screenshot "$OUT_ABS" --frames "$FRAMES" "${@:6}"
