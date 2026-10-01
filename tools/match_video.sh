#!/usr/bin/env bash
# Reference video of a full bot match with game sound, as a player sees it (HUD included).
#
#   tools/match_video.sh [recording.bin] [out.mp4] [render scale]
#
# 1. Records a real networked 2v2 (local server and bots as processes; the player's Warblade is
#    played by ScriptedPilot through keyboard and mouse events), unless a recording is given.
# 2. Draws the recording through the client with Godot's Movie Maker at a fixed 30 fps, so the
#    video plays at real speed however slowly the software renderer draws (about 2 s a frame at
#    1920x1080 with the 3D scene at half resolution; a 2.5-minute match takes about 3 hours).
#    Movie Maker also records the game's audio.
# 3. Encodes H.264 + AAC with ffmpeg.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO/previews/video"
REC="${1:-}"
OUT="${2:-$OUT_DIR/match_reference.mp4}"
SCALE="${3:-0.5}"
mkdir -p "$OUT_DIR"
if [[ -z "$REC" ]]; then
  REC="$OUT_DIR/match_rec.bin"
  echo "recording a match (real time, a few minutes) ..."
  godot --headless --path "$REPO/game" -- --auto-flow play --pilot --prep 10 --port-min 25620 \
    --record "$REC" --flow-report "$OUT_DIR/match_rec.json" > "$OUT_DIR/match_rec.log" 2>&1
fi
AVI="$OUT_DIR/match_full.avi"
echo "drawing the match at 30 fps (slow on the software renderer) ..."
xvfb-run -a -s "-screen 0 1920x1080x24" godot --path "$REPO/game" --rendering-driver vulkan \
  --write-movie "$AVI" --fixed-fps 30 res://scenes/client_main.tscn -- --auto-flow play \
  --playback "$REC" --render-scale "$SCALE" --scoreboard-s 6 --flow-timeout 100000 > "$OUT_DIR/render.log" 2>&1
echo "encoding ..."
ffmpeg -v error -y -i "$AVI" -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -vf scale=1920:1080 \
  -c:a aac -b:a 160k -movflags +faststart "$OUT"
# a copy under the 30 MB file limit for sending in the conversation: two-pass at a bitrate that
# fits the length (the half-resolution 3D picture loses almost nothing at it)
SMALL="${OUT%.mp4}_small.mp4"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AVI")
KBPS=$(python3 -c "print(max(400, int(28 * 8192 / float('$DUR')) - 140))")
(cd "$OUT_DIR" && ffmpeg -v error -y -i "$AVI" -c:v libx264 -preset slow -b:v "${KBPS}k" -pass 1 -an -f mp4 \
  -vf scale=1920:1080 /dev/null && ffmpeg -v error -y -i "$AVI" -c:v libx264 -preset slow -b:v "${KBPS}k" -pass 2 \
  -pix_fmt yuv420p -vf scale=1920:1080 -c:a aac -b:a 128k -movflags +faststart "$SMALL"; rm -f ffmpeg2pass*)
echo "video: $OUT (and $SMALL, under 30 MB)"
