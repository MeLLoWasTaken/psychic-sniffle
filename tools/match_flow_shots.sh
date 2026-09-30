#!/usr/bin/env bash
# Screenshots of the match flow (backlog M1-28) at 1920x1080 and 1280x720, into previews/match_flow/:
# main menu, settings, preparation room with the countdown, the fight with the HUD, the end banner
# and the end screen.
#
#   tools/match_flow_shots.sh [recording.bin] [fight seconds]
#
# The software renderer (lavapipe) takes seconds per arena frame, so a live client cannot keep a
# 60 Hz connection while drawing. Instead a real networked match is recorded headless first (local
# server and bots as processes, the player's controls driven by ScriptedPilot, as in
# tools/match_flow_e2e.py), then the client draws that recording through the same renderer, HUD
# and match screens, fast-forwarding between shots. Pass an existing recording to skip step 1.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/previews/match_flow"
REC="${1:-}"
FIGHT="${2:-34}"
mkdir -p "$OUT" "$REPO/previews/matches"
if [[ -z "$REC" ]]; then
  REC="$REPO/previews/matches/match_flow_rec.bin"
  echo "recording a match (real time, a few minutes) ..."
  godot --headless --path "$REPO/game" -- --auto-flow play --pilot --prep 20 --no-kit --no-gi --port-min 25520 \
    --record "$REC" --flow-report "$REPO/previews/matches/match_flow_rec.json" > "$REPO/previews/matches/match_flow_rec.log" 2>&1
fi
for size in "1920 1080" "1280 720"; do
  read -r W H <<< "$size"
  "$REPO/tools/screenshot.sh" res://scenes/client_main.tscn "previews/match_flow/menu_${W}x${H}.png" "$W" "$H" 30
  "$REPO/tools/screenshot.sh" res://scenes/client_main.tscn "previews/match_flow/settings_${W}x${H}.png" "$W" "$H" 30 --open-settings
  "$REPO/tools/screenshot.sh" res://scenes/client_main.tscn "previews/match_flow/scoreboard_${W}x${H}.png" "$W" "$H" 100000000 \
    --auto-flow play --playback "$REC" --scoreboard-s 600 --flow-timeout 2900 --shot-when scoreboard \
    --also-shot "prep=$OUT/prep_${W}x${H}.png,fight@${FIGHT}=$OUT/fight_${W}x${H}.png,ended=$OUT/ended_${W}x${H}.png"
done
echo "screenshots in previews/match_flow/"
