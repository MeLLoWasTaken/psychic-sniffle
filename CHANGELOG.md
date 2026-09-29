# Changelog

One entry per build-loop iteration, newest first. Format: date, backlog ID, what changed, how it was checked.

## 2026-09-29 — M1-17 Hand-painted texture bake
- `bake_piece` now also bakes a tangent-space normal map from Cycles bevel shading, so low-poly edges look rounded and catch light, and a glow map for emissive parts only (a character with a glowing crystal no longer glows all over).
- Worn edges come and go in broad patches along each edge (chipped paint) instead of a uniform outline.
- Preview lighting reads the game's lighting preset; a soft rim light keeps the backs of models readable.
- Baked materials are single-sided (closed meshes), which halves the pixels Godot shades for them.
- Checked: before-and-after sheets of the test crate; the exported glTF carries base color, roughness/metallic and normal textures. The arena kit was rebuilt with normal maps.

## 2026-09-29 — M1-16 Parametric body (done, attempt 3)
- New body method: a signed distance field (`tools/blender/sdf.py`, `body_sdf.py`). Limbs are tapered capsules joint to joint; torso masses are rounded boxes; muscles, hands with separate fingers, feet and facial features are blended with smooth unions, then extracted with marching cubes (5 mm grid, about 8 s) and reduced to 9,000 triangles.
- Review iterations (fast preview script `preview_body.py`): limbs 30-40% thicker; ellipsoid torso read as an hourglass with breast-like pecs, replaced by rounded boxes with flat pec plates and a straight waist; thigh tops narrowed inside the hip line; deltoids blended into the traps; hands enlarged (heavy 1.22x).
- Checked: both builds pass asset validation (closed meshes, feet at z = 0); pose test deforms cleanly. The face is still crude; recorded in KNOWN_ISSUES.md for the M1-22 art gate.

## 2026-09-29 — M1-15 Arena art kit and lighting v1
- `tools/blender/kit.py` and `build_kit_gallows.py` build a 10-piece Gallows Courtyard kit from asset specs: flagstone floor tile (1,632 triangles), coursed stone wall (5,952), corner quoins, pillar with a shackle ring, iron portcullis, stone lintel, wooden gallows platform with frame and nooses (6,976), iron brazier with glowing coals, and banners in crimson and steel blue with an original ring-and-chevron emblem.
- The painted look (broad color variation between stones, light from above, worn edges, dark crevices, no fine noise) is baked into textures. Faces hidden against other parts get almost no texture space; a first version of that check blacked out a drum face next to a small iron plate, fixed by requiring every sample point on a face to be covered.
- `MapBuilder` dresses maps that name a kit: tiled floors, facades on every open wall side, quoins on corners, paved wall tops, pillars, gallows, portcullises that rise when the gates open, lintels, and decorations from map data (braziers with fire lights, banners). Collision stays on the greybox bodies, so gameplay and the line-of-sight test are unchanged. Repeated tiles and walls are drawn in batches.
- Lighting: bounced light (VoxelGI) baked at map load in about 5 s, and a split-tone color grade (cool shadows, warm highlights) from the lighting preset.
- Validation: asset specs can declare a "face" pivot; maps must have a spec for every kit piece they use.
- Checked: all 13 assets pass validation; the dressed arena has 706,000 visible triangles (test, budget 1.5 million); screenshots reviewed (`previews/maps/kit_player.png`, `kit_overview.png`); contact sheets in `previews/kit/`. Remaining polish listed as F-05.

## 2026-09-29 — M1-14 Arena greybox: Gallows Courtyard
- New layout: a 39 by 36 m courtyard with four pillars and a central gallows block, and a gated starting room beyond each end. The first layout's full-width gates left two long strips behind them where healers got cornered.
- `scenes/maps/map_builder.gd` builds any arena from its map data: greybox shapes with a 1 m grid, perimeter walls, team-colored gates and room floors (crimson west, steel blue east), gates that sink into the floor when they open, collision on `world` and `los_blocker` physics layers, and lighting from the new `data/lighting/dusk_grim.json` preset.
- Review scene `scenes/tests/map_view.tscn` with top, overview and player-camera views and 1.8 m stand-in players; `tools/screenshot.sh` now passes extra arguments to the scene.
- Fixed from the screenshots: the scene went orange-brown again (brown sky horizon and warm fog; now cool) and the gallows block read as a black hole from the player camera (wood brightened).
- Validator: spawn points must stand clear of every collider; maps must name a known lighting preset.
- Balance on the new map: the Warblade side won 68% until the Oracle bot was fixed (it had no heal to cast between 40% and 75% health while a melee was on it); now 55% over 60 matches, mirrors 28-29 and 26-34, 177 of 180 matches ended by a kill.
- Checked: 78 Godot tests pass, including map tests (scene collision agrees with the server's line of sight on 800 random sightlines, and fails when a pillar is moved 1.5 m), path between rooms only with gates open, gates stop blocking when open. Screenshots: `previews/maps/gallows_top.png`, `gallows_overview.png`, `gallows_player.png`.

## 2026-09-29 — M1-13 Bot AI v1
- Bots read a "view" of the world with the same shape on the server (batch simulation) and on a network client, and play from per-spec data in `data/bots/`: targeting (healer first, damage dealers first, lowest health), ranges, kiting, hiding behind pillars when low, and priority rules with conditions. Added `MatchRunner` (one match's rules, shared by the server and the batch simulator), `NavGrid` (A* paths around pillars and gates) and `tools/batch_sim.gd` (thousands of matches in-process, with an optional trace that records why each bot skipped each ability).
- Bugs found by simulation and fixed: an Arcanist and an Oracle dispelled and reapplied the same cheap buff for minutes; a Warblade stuck on a corner of the central block (bots skipped a waypoint whose next leg was blocked; also the reason the Warblade could only win duels from one side); kiting healers backed into corners; the team whose units were created first won 79% of mirror matches because units always acted in id order (now a seeded shuffle per tick); Wide Hew refunded more rage than it cost.
- Network: the client predicts effect expiry and fear movement; corrections caused by effects the server applies (stuns, roots, charges) are counted separately; an aura expiring on the snapshot tick was sent as permanent; the server dropped inputs that arrived out of order. Result at 150 ms with 2% loss and combat: 0 prediction corrections in three runs. Test bots leave cleanly when an arena match ends; `check_all` now includes a networked 2v2 arena match to a kill.
- Balance pass: Warblade, Arcanist and Oracle numbers adjusted (Frost Bolt 7,800, Ruin Strike 4,200, Wide Hew 2,500, Grim Hack 2,000 and others).
- Checked: 100 simulated 2v2 matches (Warblade and Oracle against Arcanist and Oracle): 99 ended by a kill, 0 errors, median 3:24, Warblade side 59%. Mirror match-ups within chance of 50%. 73 Godot tests pass, including new bot behaviour tests (interrupts, defensives, heals the lowest ally, breaks line of sight) and a regression test for the corner bug. Report: `docs/reports/bots_m1-13_2026-09-29.json`.

## 2026-09-29 — M1-10 to M1-12 Three starter kits
- Warblade Carnage (rage, two-handed sword), Arcanist Rime (mana, frost, staff) and Oracle Grace (mana healer, mace): 14 abilities each on the bars, filling the kit template, with 21 new auras. All names are original; several first-draft names that matched another game's abilities were replaced before commit.
- New engine features for the kits: a charge (gap-closer stopped by pillars) and conditions on crowd-controlled targets (shatter-style bonus damage, a stun usable only on frozen targets).
- Checked: validator passes the kits as complete (template and CC-category rules); 13 new tests cover rage building and spending, execute, healing reduction, charge, shatter, school lock, blink out of roots, immunity, dispel, dampened healing and fear movement. 60 Godot tests pass.

## 2026-09-29 — M1-01 to M1-09 Combat core
- Added `game/core/combat.gd`: data-driven abilities (instant, cast, channel), GCD with haste and a 0.75 s floor, 400 ms spell queue, cooldowns and costs, mana and rage, auras (periodic effects, stacking, refresh rules, modifiers, absorbs, immunities), the damage and healing formula with armor and crits, casting rules (moving cancels, re-checks at completion), interrupts with school locks, crowd control with diminishing returns (100/50/25/immune, 18 s reset, 8 s cap), break-on-damage, Break Free, fear movement, roots and slows, dispels, knockbacks, blinks, area effects, line of sight at cast start and finish, and auto-attack.
- Added `game/core/arena_match.gd`: 60 s preparation behind gate colliders, dampening from 3:00 (1:00 in 1v1), win on elimination, draw at 20:00.
- Server rebuilt on the combat system with `skirmish` and `arena` modes; inputs carry ability presses; snapshots carry spec, resource, cast bar, auras, match state and the player's own cooldowns; combat events go out batched and reliable. Protocol version 2.
- Fixed from tests: casts completed one tick late (off by one); 20 players with 4 auras each needed 110 KB/s, over the 96 KB/s budget, so snapshots now use compact encoding (positions in centimetres, 8-bit ids, aura time as ticks remaining; the player's own unit stays full precision).
- Checked: 47 Godot tests pass (26 new combat and arena tests covering every M1-01..M1-09 criterion); clean and 150 ms lag matches still show 0 prediction corrections.

## 2026-09-29 — Weapon-type impacts and a lower heal ring (human feedback)
- Feedback: the v2 hit sounded blunt; a sword should sound like a slash. The single hit became three families, each with three seeded variations and a Godot `AudioStreamRandomizer` (slight pitch and volume changes per play): `impact_blunt` (the v2 hit: maces, hammers, staves, fists), `impact_slash` (swords, axes, polearms: a smooth bright-to-dark swish, a short metal edge, a wet cut, a light thud) and `impact_pierce` (daggers, spears, arrows: a tight noise thunk and a sharp tip click).
- Specs now declare a weapon (`type`, `hands`); `tuning.json` maps weapon types to impact sounds, and the validator requires a sound for every weapon type used.
- Feedback: lower the heal's ring. Bells moved down an octave (440, 554, 659 Hz) with soft overtones so they stay bell-like.
- Fixed from spectrograms: the slash edge rang for half a second at 3.2 kHz (shortened to about 50 ms); the slash sweep switched filters abruptly (now crossfaded). Fixed in the tests: the tonality detector's wide median misread steep filter edges in noise as tones (31-bin median now; still flags the chime-like v1 hit at 92%).

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
