# Backlog

Ordered work items. Always take the top item that is not done and not blocked. Each item must be finishable in one pass of the build loop (docs/DESIGN.md, "The iterative build loop"). If it is not, split it here first.

Status tags: `[todo]`, `[doing]`, `[done]`, `[blocked: reason]`.
Acceptance criteria are written before work starts. Refine them during step 2 of the loop if needed, but never loosen them to make an item pass. Record any loosening in DECISIONS.md with a reason.

## Environment notes (cloud workspace, verified 2026-09-28)

- 2 CPU cores, 7 GB RAM, no GPU. Software rendering through Mesa: llvmpipe for OpenGL, lavapipe for Vulkan (`mesa-vulkan-drivers`). Virtual display through `xvfb-run`.
- Blender 4.5 LTS works as the `bpy` Python module (`pip install bpy==4.5.4 --break-system-packages`). Measured on a test scene at 640×480: Cycles CPU 14 s, Workbench 2 s, Eevee 104 s.
- Network: PyPI, npm, Ubuntu apt and `git clone` from GitHub work. GitHub release downloads, download.blender.org and tuxfamily.org are blocked by policy. Do not try to route around blocks.
- Godot cannot be downloaded as a binary here, so it is compiled from source (`git clone --branch 4.7.2-stable`, `scons platform=linuxbsd target=editor`). This takes 1 to 2 hours on 2 cores. The binary is committed in `tools/env/bin/`; `tools/env/setup_cloud.sh` restores it (no compile needed).
- The container is temporary. Work that is not pushed to a remote repository or delivered as files is lost when the session ends.
- Absolute frame-rate targets can only be checked on a GPU machine. Here, record relative numbers and flag GPU checks as pending in KNOWN_ISSUES.md.

---

## M0 — Foundations

Exit gate: two bots join a server, move, target and auto-attack for 5 minutes with no errors.

### M0-01 Repository skeleton and living files `[done]`
- [x] `docs/DESIGN.md`, `BACKLOG.md`, `DECISIONS.md`, `CHANGELOG.md`, `KNOWN_ISSUES.md`, `CLAUDE.md` and `README.md` exist.
- [x] Git repository initialized on branch `main` with a first commit.

### M0-02 Reproducible tool setup `[done]`
- [x] `tools/env/setup_cloud.sh` installs apt packages, `bpy`, `scons` and GdUnit4 prerequisites, and builds or restores Godot 4.7.2, from a clean container.
- [x] The compiled Godot editor binary is stored where it survives the session (a release asset or LFS file in the project's own remote repository), and the script restores it instead of recompiling when it is available.
- [x] `godot --version` prints `4.7.2.stable`; `godot --headless --quit` exits with code 0.
- [x] Stored as split xz parts in `tools/env/bin/` (Git LFS uploads are blocked in the cloud workspace); setup restores it in seconds after checking its SHA-256.

### M0-03 Godot project skeleton `[done]`
- [x] `/game/project.godot` uses the Forward+ renderer, with the folder layout from DESIGN.md (`core`, `net`, `ui`, `assets`, `scenes`).
- [x] Autoloads: `Data` (loads `/data` JSON at start), `Log` (structured logging to file and stdout).
- [x] Entry scenes: `client_main.tscn` (menu stub) and `server_main.tscn`. `--server` on the command line starts the server scene.
- [x] `godot --headless --path game --quit-after 120` exits 0 with no errors or warnings in the log.

### M0-04 Screenshot capture without a GPU `[done]`
- [x] `tools/screenshot.sh <scene> <out.png> [width height]` runs Godot under `xvfb-run` with lavapipe (Forward+) and saves a frame after a set number of frames.
- [x] Produces a correct, non-black 1920×1080 PNG of a test scene with a lit mesh, fog and bloom enabled.
- [x] Time per screenshot recorded in DECISIONS.md. If Forward+ fails on lavapipe, fall back to the Compatibility renderer for screenshots only and log it in KNOWN_ISSUES.md.

### M0-05 Data schemas `[done]`
- [x] JSON Schema files in `/data/schemas` for: class, spec, ability, aura, talent tree, tuning, map, asset spec, keybind profile.
- [x] One valid example file per schema in `/data`.
- [x] `/data/tuning.json` holds every starting number from DESIGN.md "Core combat system" (GCD, queue window, run speed, health, armor reductions, DR, dampening, arena timers).

### M0-06 Data validator `[done]`
- [x] `tools/validate_data.py` checks every file against its schema and resolves all cross-references (spec → abilities, talent → ability, ability → aura, asset → spec).
- [x] Talent tree checks: no unreachable nodes, gate values valid, point totals match the design.
- [x] Passes on the real data; fails with a clear message on each of at least 6 broken fixtures in `tests/data_fixtures/`.

### M0-07 Test framework `[done]`
- [x] GdUnit4 installed in `game/addons` (cloned from its Git repository at a tagged version compatible with Godot 4.7).
- [x] `tools/run_tests.sh` runs all tests headless and returns non-zero on any failure.
- [x] One passing sample test, and proof that a failing test fails the command.

### M0-08 `tools/check_all` and pre-commit hook `[done]`
- [x] Runs data validation, unit tests and asset validation (when assets exist), then prints one pass or fail line per check.
- [x] Exits non-zero if any check fails. A Git pre-commit hook runs it.

### M0-09 Fixed-step simulation core `[done]`
- [x] `game/core/sim.gd` advances the world at exactly 60 ticks per second, independent of frame rate.
- [x] Entity model: unit with id, team, position, facing, health, resources and an aura list.
- [x] Seeded random number generator per match. Unit test: 600 ticks = 10.0 s of sim time; the same seed and inputs give the same state hash.

### M0-10 Network layer `[done]`
- [x] ENet server and client: connect, handshake with protocol version, clean disconnect.
- [x] Client-to-server input messages and server-to-client snapshots at 60 Hz, each with a sequence number.
- [x] Headless server plus 2 headless clients on one machine: the server log shows 60 ± 1 snapshots per second per client for 60 s.

### M0-11 Latency and packet-loss simulator `[done]`
- [x] A network shim that adds delay (0 to 300 ms), jitter (0 to 50 ms) and loss (0 to 10%), set from the command line.
- [x] Measured round-trip time matches the setting within 10%, on top of the local base round trip (about 10 ms; see DECISIONS.md). Checked at 150 ms (168 ms measured) and 300 ms (316 ms).

### M0-12 Movement with prediction `[done]`
- [x] Server-authoritative movement: 7 m/s run, jump, collision with floor and walls.
- [x] Client-side prediction and reconciliation for the local player; interpolation 50 ms (3 ticks) behind for others.
- [x] At 150 ms latency and 2% loss, over a 60 s bot run: largest correction under 0.5 m, average correction under 0.1 m.

### M0-13 Targeting and auto-attack `[done]`
- [x] Tab targeting (nearest enemy in front), click targeting and focus target, handled by the server.
- [x] Melee auto-attack: range 5 m, swing every 2.0 s, damage from `tuning.json`.
- [x] Unit tests for range and swing timer; the bot log shows swings only when in range.

### M0-14 Bot harness and M0 gate `[done]`
- [x] Headless bot client using the same protocol as players, with basic behaviors: wander, chase target, auto-attack.
- [x] `tools/sim/run_match.py --bots 2 --minutes 5` starts a server and bots and writes a match summary JSON.
- [x] **Gate:** 5 minutes with 2 bots, zero errors or warnings in server and client logs.

### M0-15 Blender pipeline smoke test `[done]`
- [x] `tools/blender/common.py`: reset scene, metric units, glTF export, preview camera rig, contact-sheet renderer (front, side, back, three-quarter).
- [x] `tools/validate_asset.py`: triangle budget, scale, origin, centring, texture sizes, non-manifold check. Facing is checked for characters once the standard skeleton exists (M1-16).
- [x] A test prop builds, exports to `.glb`, imports into Godot without warnings, and its contact sheet is reviewed.

### M0-16 Sound approach decision and synth prototype `[done]`
- [x] `tools/audio/synth.py` generates 3 test sounds (weapon impact, frost cast loop, holy heal) as `.ogg`.
- [x] The sounds import and play in Godot through the correct audio buses.
- [x] Sound source decision recorded in DECISIONS.md (DESIGN.md says decide at the start of M0).

### M0-17 Review pass 1 `[done]`
- [x] Run the review pass from DESIGN.md (minus balance simulations, which need specs).
- [x] Update this backlog and CHANGELOG.md.

---

## M1 — Vertical slice: 2v2 arena

Exit gate: a full 2v2 match plays start to finish with humans or bots, at 60 fps (fps checked on a GPU machine; in the cloud, check server tick time and a complete match).

The slice specs are Warblade Carnage (melee, rage), Arcanist Rime (casting, interrupts, roots) and Oracle Grace (healing, dispels).

**Combat core**
- [x] Report: `docs/reports/review_01.md`.

### M1-01 Data-driven ability system `[done]`
- [x] Ability fields: id, school, cast type (instant, cast, channel), cast time, cooldown, charges, triggers GCD, cost, range, needs line of sight, target type, effect list.
- [x] Three test abilities defined only in data (instant damage, 2.0 s cast, 3 s channel with ticks) work with no ability-specific code.
- [x] Unit tests cover each cast type.

### M1-02 Global cooldown and spell queue `[done]`
- [x] GCD 1.5 s with haste down to a 0.75 s floor; fixed 1.0 s option for energy specs.
- [x] A press within the 400 ms queue window fires on the first tick after the GCD ends. Tests cover press times of 500, 400 and 100 ms before the GCD ends.

### M1-03 Resources: mana and rage `[done]`
- [x] Mana with regeneration; rage built from dealing and taking damage, decaying out of combat. Values from `tuning.json`.
- [x] Abilities fail with a clear reason when the cost can't be paid. Unit tests for each resource.

### M1-04 Aura system `[done]`
- [x] Buffs and debuffs with duration, stacks, periodic ticks, dispel type and source.
- [x] Refresh and stacking rules defined in data. Unit tests for expiry, stacking, periodic damage and dispel.

### M1-05 Damage, healing and combat log `[done]`
- [x] Formula from DESIGN.md: base, power, crit ×1.5, armor or resistance, target modifiers, PvP modifier.
- [x] Every hit, heal, aura change and interrupt writes a combat log event.
- [x] Unit tests with hand-calculated expected numbers for each armor type.

### M1-06 Casting rules and interrupts `[done]`
- [x] Moving cancels casts unless the ability is `castable_while_moving`.
- [x] Interrupts end the cast and lock that school for the duration in data (3 to 4 s). Tests cover the lock and a cast from a different school going through.

### M1-07 Crowd control, diminishing returns and Break Free `[done]`
- [x] CC categories needed by the slice: stun, incapacitate, disorient, silence, root. Break-on-damage rules per category.
- [x] Diminishing returns 100%, 50%, 25%, immune, resetting 18 s after the last CC in that category ends; 8 s cap on any single CC.
- [x] Break Free removes all CC, 90 s cooldown. Unit tests for the full DR sequence, the reset timer and Break Free.

### M1-08 Line of sight `[done]`
- [x] A ray from caster eye to target chest against the `los_blocker` layer, checked at cast start and cast finish.
- [x] Test: a cast finishing after the target steps behind a pillar fails with "out of line of sight".

### M1-09 Arena match rules `[done]`
- [x] 60 s preparation phase with closed gates, then gates open.
- [x] Dampening from 3:00: healing reduced 1% every 10 s. Draw at 20:00. Win when a team is fully dead.
- [x] Tests run the rules with sim time sped up.

**Specs and bots**

### M1-10 Warblade Carnage kit `[done]`
- [x] 14 to 18 abilities that fill the ability kit template, defined in data with original names.
- [x] Unique mechanics (execute below a health threshold, rage spending) have unit tests.
- [x] Data validation passes.

### M1-11 Arcanist Rime kit `[done]`
- [x] Kit fills the template, including a root, a freeze (incapacitate), a shatter combo on frozen targets and a counterspell interrupt.
- [x] Unit tests for the shatter combo and the interrupt lock.

### M1-12 Oracle Grace kit `[done]`
- [x] Kit fills the template, including single-target and area heals, a magic dispel, a fear (disorient) and a personal defensive.
- [x] Unit tests for dispel and healing under dampening.

### M1-13 Bot AI v1 `[done]`
- [x] Priority-list rotations for the three specs, stored as data per spec (`data/bots/*.json`).
- [x] Bots interrupt enemy casts, use defensives below 35% health, heal the lowest ally (healer), and break line of sight when losing (`test/core/test_bot_behaviour.gd`).
- [x] In 100 simulated 2v2 matches, at least 90% end in a kill rather than a draw, and no match crashes: 99 of 100 ended by a kill, 0 errors (`docs/reports/bots_m1-13_2026-09-29.json`).

**Arena**

### M1-14 Arena greybox: Gallows Courtyard `[done]`
- [x] About 40 m across (39 by 36 m courtyard), 4 pillars, a central gallows block, two gated starting rooms, spawn points, and `los_blocker` collision (physics layer 2) on pillars and walls. The scene is built from the map data by `scenes/maps/map_builder.gd`.
- [x] Bot navigation on this map (bots path between the rooms only when the gates are open); line-of-sight rules tested on this map, and the scene's collision agrees with the server's line of sight on 800 random sightlines (`test/core/test_map.gd`).
- [x] Top-down, overview and player-view screenshots reviewed (`previews/maps/`).

### M1-15 Arena art kit and lighting v1 `[todo]`
- [ ] Blender-built modular kit: stone floor, walls, pillars, gates, braziers, gallows, banners in team colors.
- [ ] Baked lighting, volumetric fog, bloom, filmic tonemapping and a map color grade matching the art bible.
- [ ] Under 1.5 million visible triangles; screenshots reviewed against the art bible.

**Characters**
- [ ] Color balance: warm key light and warm fog together turned the M0-04 test scene uniformly orange-brown; keep cool ambient and fill so iron and stone stay readable. (Greybox pass: cool sky horizon and fog in `data/lighting/dusk_grim.json` fixed it for plain stone; recheck with painted textures.)

### M1-16 Standard skeleton and parametric body `[doing]` (started early while M0 waited on the Godot build)
- [x] One humanoid skeleton with fixed bone names, written to `docs/ART_BIBLE.md`.
- [ ] Heavy and lean body builds from the Skin-modifier method, about 7 heads tall with oversized hands, feet and shoulders.
- [ ] Asset validation passes; contact sheets reviewed.
- [ ] Status 2026-09-29: skeleton, armature and automatic weights work (pose test deforms cleanly). Body v2 uses metaball masses; heavy build is chunky but reads as a segmented mannequin; lean build is broken (masses shrink without moving, leaving gaps). Next: fuller blending between masses, build-specific offsets for lean, then a head with real features.

### M1-17 Hand-painted texture bake `[todo]`
- [ ] Bake pipeline producing 2048 px base color (light from above, darkened crevices, lightened edges), plus normal and roughness maps.
- [ ] Before-and-after contact sheets show the painted look; no photo textures and no fine noise.
- [ ] Edge highlights read as worn paint on the edges, not as thin outlines (found in the M0-15 test crate).
- [ ] The `dusk_grim` preview lighting keeps the back of a model readable, not near-black (found in the M0-15 test crate).

### M1-18 Warblade plate armor kit and two-handed weapon `[todo]`
- [ ] Angular plate with spikes, rivets, dents and wear; oversized two-handed weapon.
- [ ] 15,000 to 25,000 triangles at LOD0, plus 2 LODs; armor rigidly parented to bones.
- [ ] No clipping in idle, run and cast poses.

### M1-19 Arcanist cloth kit and staff `[todo]`
- [ ] Heavy cloth with torn hems, frost accents; staff.
- [ ] Same budgets and checks as M1-18.

### M1-20 Oracle cloth kit and weapon `[todo]`
- [ ] Silhouette clearly different from the Arcanist (the grayscale test in M1-22 must pass).
- [ ] Same budgets and checks as M1-18.

### M1-21 Animation set v1 `[todo]`
- [ ] Idle, combat idle, run, strafe left and right, backpedal, jump, cast start, cast loop, cast release, channel, 3 melee attacks, hit reaction, stunned, feared run, death, victory.
- [ ] Keyframed by script from pose data with eased curves; shared by all three characters.
- [ ] Preview sheets or turntable frames reviewed for stiffness; all clips named per the art bible.

### M1-22 Lineup render and M1 art gate `[todo]`
- [ ] Lineup of the three characters in the arena lighting preset.
- [ ] Grayscale test: each class is identifiable by silhouette at 30 m.
- [ ] Decide the "character art source" and "animation source" open decisions and record them in DECISIONS.md. If the result falls short, ask the human before switching to CC0 or artist-made bases.

**Client and feel**

### M1-23 Camera, controls and targeting UI `[todo]`
- [ ] Third-person camera with zoom, mouse steering and strafe; click-to-target and tab targeting.
- [ ] Default keybinds loaded from a keybind profile file (the full rebinding screen comes in M2).

### M1-24 Character animation hookup `[todo]`
- [ ] Locomotion blend tree (run, strafe, backpedal, jump) driven by movement.
- [ ] Cast, channel and attack animations triggered by ability data; CC states play stunned or feared animations.

### M1-25 Spell effects v1 `[todo]`
- [ ] Effects for every ability in the three kits, following the school color table.
- [ ] Enemy ground effects have a red-tinted outline.
- [ ] Screenshot test: each school identifiable by color alone.

### M1-26 Sound v1 `[todo]`
- [ ] Sounds for every ability in the three kits (cast, release, impact), melee swings, footsteps and interface clicks.
- [ ] Audio buses from DESIGN.md; distinct CC warning sound; no sound louder than that warning.

### M1-27 Basic HUD `[todo]`
- [ ] Two action bars with cooldown sweeps and keybind labels; player, target, focus and party frames; arena enemy frames with cast bars.
- [ ] Buffs and debuffs with CC shown larger; floating combat text; match timer and dampening percentage; loss-of-control alert.
- [ ] Screenshots at 1280×720, 1920×1080 and 2560×1440 reviewed.

**Match flow and verification**

### M1-28 Match flow `[todo]`
- [ ] Menu → "Play 2v2 vs bots" → preparation room → gates open → fight → end screen with damage and healing scoreboard → back to menu.
- [ ] A human player can play a full match with a bot partner against two bots.

### M1-29 Replay test `[todo]`
- [ ] Every match records its input log; replaying it reproduces the same final state hash.

### M1-30 Network test `[todo]`
- [ ] A full bot 2v2 at 150 ms latency, 2% loss and 30 ms jitter completes without desync or stuck casts.

### M1-31 Performance baseline and M1 gate review `[todo]`
- [ ] Server tick time for a 4-player match recorded (target well under 8 ms).
- [ ] Client frame time on the software renderer recorded as a relative baseline; GPU fps check added to KNOWN_ISSUES.md as pending if no GPU machine is available.
- [ ] Full review pass; the M1 gate is checked and the result written to CHANGELOG.md.

---

## Follow-ups from review pass 1

### F-01 Delta-compressed snapshots and distance-based send rates `[todo]`
- [ ] Snapshots send only fields that changed since the last acknowledged snapshot.
- [ ] Units far from the receiving player are sent at a reduced rate.
- [ ] 20 players at 60 Hz stay under 48 KB/s per client (half the budget). Needed before M4.

### F-03 Smooth server-caused position corrections on screen `[todo]`
- [ ] When a stun, root, charge or blink the client could not predict moves the player's own character, blend the camera and model to the corrected position over about 100 ms instead of snapping (up to 1.5 m at 150 ms round trip).

### F-04 Bot movement polish `[todo]`
- [ ] Healers near a pillar sometimes alternate between two movement goals (hide and stay near the ally) and stall; about 10 stall events per match. Add hysteresis to goal changes.
- [ ] Recheck the small team-1 edge seen across 209 matches after the turn-order fix (55%, not statistically significant) at the next review pass.

### F-02 GPU frame-rate measurement `[blocked: needs a GPU machine]`
- [ ] Record fps for the M1 vertical slice on recommended and minimum PC profiles at the M1 gate.

---

## Later milestones (split into items when the milestone starts)

- **M2** Full CC and DR set (disarm, knockback), talent trees and talent screen, 1v1 and 3v3 brackets, two more arenas, full keybinding screen, UI edit mode, settings suite.
- **M3** Remaining 10 classes in waves of 3 or 4, each with kits, bots, models, animations, effects and sounds.
- **M4** Capture-the-flag and resource-control battlegrounds, raid frames, scoreboard, minimap, bot fill.
- **M5** Art and audio polish, rated matchmaking with Glicko-2, accessibility options, performance work, balance.
