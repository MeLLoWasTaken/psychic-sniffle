# Changelog

One entry per build-loop iteration, newest first. Format: date, backlog ID, what changed, how it was checked.

## 2026-09-29 — Sound revisions from human listening feedback
- `weapon_impact` v2. Feedback: v1 "doesn't sound like a weapon hit; more like you scored a point". Cause: v1 was built on sustained pure tones (93% of its energy above 200 Hz sat in narrow tonal peaks), which is how a chime is built. v2 layers a broadband crack, a falling low thud with sub, a low-mid body, a crackling crunch, and metal made of narrow resonant noise bands that fade within about 0.1 s; tonal share is now 0%.
- `holy_heal` v2. Feedback: "pretty decent, but needs to sound meatier"; the light, high ring alone lacked weight. v2 adds a rising build-up, a soft deep impact where the heal lands, a warm chord with a low octave and sub, and moves the bells down an octave at a lower level. Energy below 250 Hz rose from 20% to 84%. Two clicks found in the spectrogram (build-up noise stopping instantly; the chord's level jumping in one sample) were fixed.
- Added `tests/test_audio.py`: impacts must not be tonal, smooth sounds must not click (detector verified against a deliberate click), heals must carry low-end weight, nothing louder than the CC warning level.
- `frost_cast_loop` unchanged (feedback: sounds fine). Previous versions kept in `previews/audio/v1/` for comparison.

## 2026-09-29 — M0-17 Review pass 1
- 20-bot match: server tick average 0.24 ms (p95 0.46 ms), 38.7 KB/s per client, every bot at 60.0 snapshots per second. Report: `docs/reports/perf_20bots_2026-09-29.json`.
- Fixed from this run: the server stopped before late-launched bots finished (harness); ENet's packet throttle dropped up to 17% of snapshots under CPU load (now pinned open); a client shutdown race.
- Review written to `docs/reports/review_01.md`; follow-ups F-01 (delta compression) and F-02 (GPU fps) added to the backlog.

## 2026-09-29 — M0-10 to M0-14 Networking, movement, targeting, bots; M0 exit gate passed
- Added the network layer: binary protocol (`game/net/protocol.gd`), ENet transport with a latency, jitter and loss simulator (`transport.gd`), authoritative server (`server.gd`), client with prediction, reconciliation and interpolation (`client.gd`), and bots (`bot_brain.gd`, `scenes/bot_main.tscn`).
- Added `tools/sim/run_match.py`, which runs a server and bots as separate processes and checks logs, snapshot rate, round trip and prediction corrections. `check_all` now includes a 30 s match with and without simulated lag.
- Fixed from test runs: first-contact spawn placement was counted as an 18 m correction (teleports now excluded); round trip was 46 ms locally because the network was polled only once per tick (now every frame, 8 to 10 ms); dropped and repeated inputs caused 0.93 m corrections and lost targeting under lag (now exactly-once input handling, 0 corrections); a post-shutdown network poll logged errors.
- **M0 exit gate passed:** 2 bots for 5 minutes, 18,180 ticks (average 0.078 ms, p95 0.12 ms), 262 hits and 4 kills with respawns, 60.0 snapshots per second per bot, 0 prediction corrections, 0 errors or warnings. Report: `docs/reports/m0_gate_2026-09-29.json`.
- At 150 ms lag, 30 ms jitter and 2% loss: 0 corrections, 58.8 snapshots per second (60 minus the 2% loss), 168 ms round trip. Report: `docs/reports/lag150_2026-09-29.json`.

## 2026-09-29 — M0-04 Screenshot capture without a GPU
- Added a `Capture` autoload (any scene can be captured with `-- --screenshot out.png --frames N`) and `tools/screenshot.sh`.
- Checked: `previews/shots/lit_test.png` at 1920×1080 shows the imported crate, shadows, volumetric fog and a glowing brazier. Noted a color-balance issue for M1-15.

## 2026-09-29 — M0-02, M0-03, M0-07, M0-08, M0-09 Godot running; checks wired up
- Godot 4.7.2 compiled from source (48 minutes after a workspace restart) and installed; `tools/env/setup_cloud.sh` rebuilds the whole environment.
- Godot project skeleton boots as client and as server with no errors or warnings; data loads through the `Data` autoload.
- GdUnit4 6.2.1 installed; `tools/run_tests.sh` runs tests headless (a deliberately failing test returns exit code 100). `tools/check_all` runs 5 checks; a pre-commit hook runs it.
- Fixed-step simulation core (`game/core/sim.gd`, `unit.gd`) passes its 4 tests: 600 ticks = 10.0 s, frame-rate independence, same seed gives the same state hash, different seed differs.
- Audio buses from the design added (`default_bus_layout.tres`); tests confirm routing, loading and playback. The frost loop was imported as a one-shot, caught by a test; the generator now writes Godot's loop flag.
- `check_all` caught the glTF importer adding a bone display mesh to rigged models; the asset validator now ignores bone display shapes.
- Created `docs/ART_BIBLE.md` with the standard skeleton, conventions and review lessons.
- Still open in M0-02: storing the compiled Godot binary outside the workspace needs the project's GitHub repository.

## 2026-09-29 — M1-16 Parametric body (in progress, started early)
- Standard 20-bone skeleton, armature generation and automatic skin weights work; a pose test (raised arm, bent knee, twisted spine) deforms cleanly.
- Body v1 (Skin modifier) was too thin. Body v2 uses metaball masses with a measured size correction; the heavy build is chunky but still reads as a segmented mannequin, and the lean build separates into pieces. Logged in KNOWN_ISSUES.md.

## 2026-09-28 — M0-16 Sound synth prototype (partial)
- Added `tools/audio/synth.py` with three recipes: `weapon_impact`, `frost_cast_loop` (seamless loop) and `holy_heal`, plus spectrogram rendering for review.
- Fixed problems found in the spectrograms: clicks where the dry signal was cut off while tones still rang; a volume jump in the envelope release; encoded peaks above target.
- Checked: spectrograms in `previews/audio/` show no clicks; peaks at -2.9, -6.1 and -3.9 dBFS against targets of -3, -6 and -4. Godot playback check waits for the Godot build.

## 2026-09-28 — M0-15 Blender pipeline smoke test (partial)
- Added `tools/blender/common.py` (scene setup, painted-look placeholder material, glTF export, `dusk_grim` lighting preset, 4-view contact sheet), `tools/blender/build_test_prop.py` (iron-banded crate) and `tools/validate_asset.py`.
- Fixed two problems found by looking at the renders: edge highlights used per-vertex Pointiness, which lit whole low-poly parts (now a Bevel-normal comparison); procedural colors exported as white (flat colors are written into the export until the M1-17 bake).
- Checked: crate is 1,680 triangles, 1.13 m, origin at the feet, 0 non-manifold edges; contact sheet reviewed (`previews/test_crate/test_crate_sheet.png`). Godot import check waits for the Godot build.

## 2026-09-28 — M0-05 and M0-06 Data schemas and validator
- Added JSON Schemas for class, spec, ability, aura, talent tree, tuning, map, asset spec and keybind profile, with example data (Warblade class, Carnage spec draft, Ruin Strike, Auto Attack, Break Free, a bleed aura, three draft talent trees, Gallows Courtyard, the test crate spec, default keybinds).
- `data/tuning.json` holds every starting number from the design (60 Hz tick, GCD, DR, dampening, timers, health, armor). Resource pool sizes and regeneration rates were not in the design; starting values are recorded in DECISIONS.md.
- Added `tools/validate_data.py` and 12 broken-data fixtures. Checked: `pytest tests` passes 14 tests (real data valid; every fixture caught with the expected message).

## 2026-09-28 — M0-01 Repository skeleton
- Added docs/DESIGN.md (snapshot of the living design doc), BACKLOG.md with all M0 and M1 items, DECISIONS.md, KNOWN_ISSUES.md, CLAUDE.md and README.md.
- Checked the cloud workspace: Blender 4.5 renders with Cycles, Workbench and Eevee without a GPU; Godot source cloned and compiling.
