#!/usr/bin/env bash
# Run all Godot unit tests (GdUnit4) headless. Exit code is non-zero on any failure.
#   tools/run_tests.sh                 # everything under game/test
#   tools/run_tests.sh res://test/core # one folder
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-res://test}"
cd "$REPO/game"
godot --headless --path . --import >/dev/null 2>&1 || true
# --remote-debug to an unbound port stops Godot's interactive debugger from waiting for input
# on a script error (see addons/gdUnit4/runtest.sh).
godot --headless --path . -s -d --remote-debug tcp://127.0.0.1:0 \
  res://addons/gdUnit4/bin/GdUnitCmdTool.gd --ignoreHeadlessMode -a "$TARGET" -c
code=$?
godot --headless --path . --quiet -s res://addons/gdUnit4/bin/GdUnitCopyLog.gd >/dev/null 2>&1 || true
exit $code
