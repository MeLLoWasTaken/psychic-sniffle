# Changelog

One entry per build-loop iteration, newest first. Format: date, backlog ID, what changed, how it was checked.

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
