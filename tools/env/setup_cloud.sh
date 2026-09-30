#!/usr/bin/env bash
# Set up a fresh cloud workspace (Ubuntu 24.04, no GPU) for this project.
#
#   tools/env/setup_cloud.sh            # install everything, restore or build Godot
#   GODOT_JOBS=2 tools/env/setup_cloud.sh
#
# What it does:
#   1. apt: build tools, X11/audio headers for Godot, Mesa software GL and Vulkan, Xvfb
#   2. pip: bpy (Blender 4.5 LTS as a Python module), scons, test and audio libraries (pedalboard: sound processing, X-04)
#   3. Godot 4.7.2: restores a cached binary if one exists, otherwise compiles from source
#      (GitHub release downloads are blocked in the cloud workspace; git clone is allowed)
#   4. GdUnit4 test framework into game/addons (if the Godot project exists)
#
# Safe to run more than once.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GODOT_TAG="4.7.2-stable"
GDUNIT_TAG="v6.2.1"
TOOLS_DIR="${TOOLS_DIR:-/home/claude/tools}"
CACHE_DIR="$REPO/tools/env/cache"
GODOT_BIN="$CACHE_DIR/godot"
JOBS="${GODOT_JOBS:-$(nproc)}"

log() { printf '\n== %s\n' "$*"; }

log "apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq \
  build-essential pkg-config git xvfb \
  libx11-dev libxcursor-dev libxinerama-dev libxi-dev libxrandr-dev \
  libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev libudev-dev libfontconfig-dev \
  mesa-vulkan-drivers libgl1-mesa-dri vulkan-tools mesa-utils >/dev/null

log "python packages"
pip install -q --break-system-packages \
  "bpy==4.5.4" scons jsonschema pytest pillow numpy soundfile scipy matplotlib resvg-py "pedalboard==0.9.25"

log "Godot $GODOT_TAG"
mkdir -p "$CACHE_DIR"
PARTS=("$REPO"/tools/env/bin/godot-4.7.2-linux-x86_64.xz.part*)
if [[ -x "$GODOT_BIN" ]] && "$GODOT_BIN" --version 2>/dev/null | grep -q "^4.7.2.stable"; then
  echo "cached binary found: $("$GODOT_BIN" --version)"
elif [[ -f "${PARTS[0]}" ]]; then
  # Binary committed to the repo as split xz parts (Git LFS uploads are blocked in the cloud
  # workspace). Reassemble, check against the recorded SHA-256, and install.
  echo "restoring binary from tools/env/bin ..."
  cat "${PARTS[@]}" | xz -dc > "$GODOT_BIN.tmp"
  expected="$(cat "$REPO/tools/env/bin/godot-4.7.2-linux-x86_64.sha256")"
  actual="$(sha256sum "$GODOT_BIN.tmp" | cut -c1-64)"
  if [[ "$expected" != "$actual" ]]; then
    echo "checksum mismatch for restored Godot binary"; rm -f "$GODOT_BIN.tmp"; exit 1
  fi
  mv "$GODOT_BIN.tmp" "$GODOT_BIN"
  chmod +x "$GODOT_BIN"
else
  mkdir -p "$TOOLS_DIR"
  if [[ ! -d "$TOOLS_DIR/godot-src" ]]; then
    git clone --depth 1 --branch "$GODOT_TAG" https://github.com/godotengine/godot.git "$TOOLS_DIR/godot-src"
  fi
  echo "compiling with $JOBS jobs (1 to 2 hours on 2 cores)..."
  (cd "$TOOLS_DIR/godot-src" && scons platform=linuxbsd target=editor -j"$JOBS")
  cp "$TOOLS_DIR/godot-src/bin/godot.linuxbsd.editor.x86_64" "$GODOT_BIN"
fi
ln -sf "$GODOT_BIN" /usr/local/bin/godot
godot --version

if [[ -f "$REPO/game/project.godot" && ! -d "$REPO/game/addons/gdUnit4" ]]; then
  log "GdUnit4 $GDUNIT_TAG"
  tmp="$(mktemp -d)"
  git clone --depth 1 --branch "$GDUNIT_TAG" https://github.com/MikeSchulze/gdUnit4.git "$tmp/gdUnit4"
  mkdir -p "$REPO/game/addons"
  cp -r "$tmp/gdUnit4/addons/gdUnit4" "$REPO/game/addons/"
  rm -rf "$tmp"
fi

"$REPO/tools/install_hooks.sh"

log "done"
echo "Godot:   $(godot --version)"
echo "Blender: $(python3 -c 'import bpy; print(bpy.app.version_string)' 2>/dev/null | tail -1)"
