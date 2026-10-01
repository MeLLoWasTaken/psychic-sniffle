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

### M1-15 Arena art kit and lighting v1 `[done]`
- [x] Blender-built modular kit (`tools/blender/build_kit_gallows.py`, 10 pieces): flagstone floor, coursed stone wall and corner, pillar, iron portcullis and stone lintel, wooden gallows platform with nooses, brazier, banners in crimson and steel blue. Painted look baked into textures (pulled forward from M1-17 for environment pieces).
- [x] Baked bounced light (VoxelGI, baked when the map loads in about 5 s), volumetric fog, bloom, AgX filmic tonemapping, and a split-tone color grade from `data/lighting/dusk_grim.json`.
- [x] 706,000 visible triangles (budget 1.5 million, tested); screenshots reviewed against the art bible (`previews/maps/kit_player.png`, `kit_overview.png`).
- [x] Color balance: stone stays grey with cool shadows and warm light; accent colors only from banners and fire.

**Characters**

### M1-16 Standard skeleton and parametric body `[done]`
- [x] One humanoid skeleton with fixed bone names, written to `docs/ART_BIBLE.md`.
- [x] Heavy (1.96 m) and lean (1.88 m) body builds, about 7.5 heads tall with oversized hands and feet and broad shoulders. Method changed from the Skin modifier (attempt 1, thin tubes) and metaballs (attempt 2, segmented) to a signed-distance-field body (attempt 3, `tools/blender/body_sdf.py`): tapered limbs, blocky torso masses and muscles blended with smooth unions into one continuous surface.
- [x] Asset validation passes (9,000 triangles each, closed meshes); contact sheets and the pose test (raised arm, bent knee, twisted spine) reviewed: deformation is clean.
- Known limits, carried to M1-22: the face is crude (clay-like features); the body surface is very smooth. Helmets and hoods cover most of the head for the first three classes.

### M1-17 Hand-painted texture bake `[done]`
- [x] Bake pipeline (`tools/blender/kit.py`, `bake_piece`) producing base color (light from above, darkened crevices, lightened edges, per-part color variation), roughness/metallic, a tangent-space normal map from Cycles bevel shading (rounded edges on low-poly parts), and a glow map for emissive parts. Characters use one 2048 px set; props 512-1024 px.
- [x] Before-and-after sheets of the test crate (`previews/test_crate/test_crate_before_bake.png`, `test_crate_baked.png`): painted look, no photo textures, no fine noise.
- [x] Edge highlights read as worn, chipped paint in broad patches (a low-frequency wear mask), not thin outlines.
- [x] Preview lighting comes from the game's lighting preset (`data/lighting/dusk_grim.json`) plus a soft rim light; the backs of models are readable.

### M1-18 Warblade plate armor kit and two-handed weapon `[done]`
- [x] Angular plate with spikes, rivets, dents and wear (horned helm, spiked pauldrons, brass trim); oversized greatsword (1.78 m).
- [x] 24,896 triangles at LOD0, plus 2 LODs generated at import (12,448 and 6,000); armor rigidly parented to bones; 0 non-manifold edges.
- [x] No clipping in idle, run and cast poses: checked in M1-21 with the animation set (clipping report `previews/animations/anims_heavy_clipping.json`).

### M1-19 Arcanist cloth kit and staff `[done]`
- [x] Heavy hooded robe with torn hems and frost crystals on the shoulders; frost staff (2.4 m, iron bands, glowing crystal head).
- [x] 16,300 triangles, LODs 8,150 and 4,074; 0 non-manifold edges; no clipping in idle, run and cast poses (M1-21).

### M1-20 Oracle cloth kit and weapon `[done]`
- [x] White and gold vestments, crown and rayed halo; flanged mace (0.95 m). The grayscale silhouette test against the Arcanist runs at M1-22.
- [x] 17,100 triangles, LODs 8,550 and 4,274; 0 non-manifold edges; no clipping in idle, run and cast poses (M1-21).

### M1-21 Animation set v1 `[done]`
- [x] Clipping check for all three characters in the idle, run and cast poses (moved from M1-18..M1-20, which could only use a static pose test): no vertex deeper than 1.5 cm inside another body part or the weapon in idle, combat idle, run, cast start, cast loop, cast release (default, frost, holy) and channel, sampled every second frame.
- [x] Idle, combat idle, run, strafe left and right, backpedal, jump, cast start, cast loop, cast release (plus frost and holy variants), channel, 3 melee attacks, ranged shot, hit reaction, stunned, feared run, death, victory (22 clips in `data/animations/humanoid.json`).
- [x] Keyframed by script from pose data with eased curves (`tools/blender/animation.py`, `build_animations.py`); one library per body build shared by its characters; played in the game by `CharacterRig` with data-driven weapon grips.
- [x] Pose sheets reviewed for stiffness (`previews/animations/<character>_<locomotion|casting|combat>.png`) and a game screenshot mid-run (`godot_run.png`); clip names in the art bible. Found and queued: small cast releases, one-handed swings of two-handed weapons and overhead clipping in melee clips (F-06), robe skirts parting at the front (F-07).

### M1-22 Lineup render and M1 art gate `[done]`
- [x] Lineup of the three characters in the arena lighting preset (`previews/lineup/lineup_idle.png`, in game; `tools/blender/render_lineup.py` for the tests below).
- [x] Grayscale test: each class is identifiable by silhouette at 30 m (about 57 px tall with the game camera): staff and hood, halo, horns and bulk; distinct brightness in grayscale (`previews/lineup/silhouettes_*.png`, `grayscale_*.png`, overlap figures in `silhouettes.json`).
- [x] "Character art source" and "animation source" decided and recorded in DECISIONS.md: the human chose to stay fully scripted and reach quality by iteration; scripted keyframes for animation.
- [x] Art iteration from the gate review: fists and gloves on fine grids, hidden faces by design (hood with glowing eyes, gold mask and coif, closed helm), robe folds, stole, trims and emblem, painted height gradient, slimmer idle for the lean build, robe skirts that no longer part (F-07), two-handed grip in the Warblade's attacks.

**Client and feel**

### M1-23 Camera, controls and targeting UI `[done]`
- [x] Default keybinds loaded from a keybind profile file (the full rebinding screen comes in M2): `Keybinds.load_profile` registers every action of `data/keybinds/<id>.json` in the InputMap with its key or mouse button and Shift/Ctrl/Alt, replacing older events; the default profile gains camera orbit and steer (mouse buttons), zoom (wheel) and clear target (Escape); key names are checked by the schema (`test/client/test_keybinds.gd`).
- [x] Player controls produce the bot input dictionary (the server path is unchanged): W/S forward and back, A/D turn (strafe with the right button held), Q/E strafe, Space jump, both buttons run forward; right drag steers character and camera, left drag orbits only the camera, which stays where it is left; mouse sensitivity, invert, keyboard turn speed from `data/settings/default.json` (`test_player_controller.gd`, 10 tests).
- [x] Third-person camera at shoulder height, wheel zoom 2 to 25 m with smoothing, pitch limits, and pull-in in front of pillars, walls and the floor using the server's map colliders (`test_camera.gd`, 7 tests).
- [x] Targeting: left or right click selects the unit whose body (1.9 by 0.5 m capsule) is under the cursor, not through walls; empty ground keeps the target; Tab takes enemies in front of the camera within 40 m and in sight, by angle from the screen centre then distance, and cycles; Escape clears; the server's target follows (`clear_target` input flag, protocol 4). A ground ring marks the target, red for enemies, green for allies (`test_targeting.gd`, 8 tests).
- [x] Practice scene `scenes/game/practice.tscn`: in-process 2v2 on Gallows Courtyard, the player's Warblade (or `--spec`) against three bots, drawn from the world view (the same dictionary the network client builds) with interpolation between ticks, idle/run/backpedal/strafe/death clips; runs 10 simulated seconds of scripted input without errors and the player moves (`test_practice.gd`).
- [x] Screenshots from the player camera reviewed: `previews/game/practice_target.png` (default zoom, enemy Oracle targeted), `practice_zoomed.png` (four notches out).

### M1-24 Character animation hookup `[done]`
- [x] Locomotion blend tree driven by movement: `CharacterAnimator` (one AnimationTree per character) blends idle or combat idle, run, backpedal and strafes in a 2D blend space on the velocity relative to facing, eased (0.12 s), with moving clips played at ground speed / full speed within 0.6-1.4; jump one-shot on take-off; combat idle while casting, with a living hostile target within 40 m, or after damage in the last 5 s (`test_character_animator.gd`: forward, backward, both strafes, slowed, capped, standing, easing; combat idle; jump).
- [x] Cast, channel and attack animations triggered by ability data and events: cast start then cast loop while the view's cast bar runs, `cast_release_<school>` (else `cast_release`) on success, channel while channeling, attack 1-2-3 cycling for melee abilities and auto-attacks (restarting after 3 s), ranged shot for physical ranged instants, release for instant spells, throttled hit reaction on hits of 5% of maximum health or more; which ability plays what is ordered rules in `data/anim_states/humanoid.json` (schema and validator checks), no per-class code (tests: frost and holy releases, interrupt, channel, instant spells, melee cycle, ranged shot, hit throttle, every ability resolves).
- [x] Crowd control overrides everything: stunned for stun and incapacitate, feared run for disorient (movement from the server), faded in 0.1 s and out 0.25 s back to locomotion; death plays once and holds; victory for the winners' living units at match end (tests: stun with cast and recovery into running, fear, stun over fear, root is no override, death stays, victory).
- [x] Upper/lower split with bone filters: actions play on spine and above while moving and full-body when standing (legs join in 0.2 s); the legs of a character swinging on the run match a character only running (test compares bone poses).
- [x] Practice scene: every unit animates from the view and the event stream (`LocalMatch.take_events` -> `WorldRenderer.push_events`); 15 simulated seconds with no errors, every animator changes state, a cast and running are seen (`test_practice.gd`). Screenshots reviewed: `previews/game/anim_cast.png` (Arcanist cast loop), `anim_melee.png` (Warblade and enemy Oracle mid-swing).

### M1-25 Spell effects v1 `[done]`
- [x] Effects for every ability in the three kits, following the school color table: one entry per ability in `data/effects/<ability id>.json` (44, schema `effect.schema.json`) naming generic styles for up to seven stages (cast glow at the hands plus a ring at the feet while the cast bar or channel runs, projectile, impact, ground circle with the ability's radius, melee swing trail with hit sparks, charge dust or blink, and the visual of each aura it applies); colors from the school table in `data/effect_palettes/default.json` (all 10 schools). The validator checks every finished-kit ability has an entry (or `"none"` with a reason), stages fit the ability, each applied aura has exactly one visual and crowd control uses a CC style (6 fixtures, 3 tests). `EffectsDirector` plays them from views and events with no per-ability code (`test/client/test_effects.gd`: every ability plays all its stages and cleans up; cast glow spawned and freed; view without a cast ends the glow; projectile flies caster to target and triggers the impact; aura visuals on applied/removed events and from the view; CC always shown within the per-unit cap; swings and sparks; charge dust).
- [x] Enemy ground effects have a red-tinted outline; the player's and allies' a neutral one; relation from the view (caster team vs the local player's); enemy ground effects outrank allied ones in the budget (test).
- [x] Budget for 20 players: at most 200 live effects and 4,000 particles, 4 aura visuals per unit (CC first), 24 impacts per tick, lower priority evicted first; finished effects freed, meshes and materials shared. A 30 s practice fight stays within it, every child of the director is a tracked live effect, the node count does not creep, and every effect ends when the units leave (test).
- [x] Screenshot test: each school identifiable by color alone. `scenes/tests/effects_view.tscn --mode schools` lays out the same four effects per school under the arena lighting (`previews/effects/schools.png`); `tools/effects_hues.py` measures each school's effect pixels against the same frame without effects: all 45 pairs pass (hues at least 30 degrees apart, or pale/dark schools apart in saturation or value), closest fire/holy 31 degrees, nature/fel 31; fire/blood 18 degrees apart but 0.21 apart in value (`previews/effects/school_hues.json`).
- [x] Practice scene hook: `WorldRenderer` creates the `EffectsDirector` and forwards views, events and frames. Screenshots reviewed: ability grids `previews/effects/grid_<spec>.png` (Warblade and Arcanist cast by an enemy: red outlines; Oracle by an ally: neutral), practice fight `practice_fight_1.png` (enemy frost nova with red outline, root, stun, swing), `practice_fight_2.png` (Arcanist and Oracle casting: hand glows and feet rings in frost and holy).

### M1-26 Sound v1 `[done]`
- [x] Sounds for every ability in the three kits (cast, release, impact), melee swings, footsteps and interface clicks: 80 recipes in `data/sounds/<id>.json` (layers, or a builtin Python recipe for the 5 approved M0-16 sounds) built by `tools/audio/synth.py --data` into 121 Ogg files and 25 randomizers; `data/sound_map/default.json` maps all 44 abilities (cast start and loop for the 5 casts and the channel, release, impact; `@weapon_swing` / `@weapon_hit` resolve from the caster's weapon and the target's armor), two periodic auras, 13 weapon types, plate and cloth footsteps and landings, interface click, target tick and error (`test/audio/test_sound_data.gd`).
- [x] Human feedback rules hold for every file: impacts measure below 20% tonal (all 0-9%), heals keep over 40% of their energy below 250 Hz (67-100%), smooth sounds (casts, heals, swings, loops, buffs) do not click, loops join at the seam; weapon hits differ by weapon on every variation (greatsword owns the band above 2 kHz, mace the weight below 250 Hz, staff the 250 Hz-2 kHz mids with the shortest ring) and by armor; plate footsteps are heavier and louder than cloth (`tests/test_audio.py`). The validator rejects tonal impact recipes and layers cut off while still loud (6 new fixtures).
- [x] Audio buses from DESIGN.md (`default_bus_layout.tres`, Interface raised to 0 dB, a -0.5 dB hard limiter on Master); world sounds are 3D (inverse distance, full level within 10 m, -12 dB at 40 m, culled beyond 60 m; footsteps 5/35 m; area crowd control 16/90 m) on the self, allies or enemies bus by who caused them; interface and warnings are 2D (`test/audio/test_audio_director.gd`).
- [x] Distinct CC warning, 2D, once per crowd-control application (stun, incapacitate, disorient, silence) on the local player, several in one tick counting once; an incoming warning when an enemy starts a crowd-control cast at the player (DESIGN.md); can be turned off. No sound is louder than it: every file at least 1 LU quieter in integrated and in loudest-400 ms loudness (BS.1770) and not above its peak, and no bus path lifts a sound past it (python and Godot tests).
- [x] Voice limits: at most 64 voices, pooled players, priority and per-sound caps with stealing, voices ending by game time; enemy crowd control, burst and warnings never dropped. Holds in a 20-unit brawl (400 sounds/s) and in 30 s of a practice 3v3, and with a 6-voice cap (`test/audio/test_practice_audio.gd`, which also counts CC applications from the view independently).
- [x] Practice scene: `WorldRenderer` creates an `AudioDirector` and forwards views, events and frames to it (next to the effects hook).
- Spectrograms reviewed (`previews/audio/sheet_*.png` and one PNG per representative sound); the human's listening pass is part of the M1 gate (M1-31), with the list in CHANGELOG.md.

### M1-27 Basic HUD `[done]`
- [x] Layout is data: `data/hud_layouts/default.json` (schema `hud_layout.schema.json`; the settings profile's new `interface` section names it, with `ui_scale`, `min_text_px`, `combat_text`). Every element has a type, anchor, offset, optional scale, opacity and visibility; the validator checks bar actions are bound in every keybind profile, per-spec slot assignments stay inside the kit, complete kits fit on the bars, every CC category used by auras has a label and glyph (3 new fixtures). `Hud` builds every element from it (`test/ui/test_hud.gd`: layout loaded, all elements built).
- [x] Two action bars of 12 buttons: slots follow the spec's ability list (Break Free last, with its own Shift+R bind; auto attack left off), keybind labels from the loaded profile shortened by the layout (1..0, -, =, S1..); placeholder icons drawn from data (school color, glyph from the icon symbol, initials); cooldown sweep and seconds over the real cooldown length, GCD sweep, red tint and key label out of range, blue short of resource, gray while crowd-controlled or school-locked, gold border when an execute becomes usable (tests: slots and labels for the three specs, cooldown and GCD fractions from the view, range/resource/CC/execute states, layout assignments).
- [x] Ability presses: a slot's key or a click on its button queues the ability in the controller's input dictionary (one per tick, in order; exact modifier match so 1 and Shift+1 differ; scripted InputEventAction takes the same path); the server's 400 ms spell queue window applies; clicks play `ui_click` on the Interface bus; a key press reaches the simulation (tests).
- [x] Player, target, focus (Shift+F now sets it), party and arena enemy frames: portrait, spec and name, class-colored health with absorbs, resource, cast bars (amber interruptible, green draining channel, steel with a lock when uninterruptible; "Interrupted" held 0.7 s); arena frames numbered with Break Free cooldown (from its cast event) and a DR tracker; clicking a frame targets that unit; the target's arena frame is outlined (tests: target and focus follow the targeting, frame click, arena Break Free and interrupt).
- [x] Auras on frames with seconds left: crowd control first and 1.5× larger, then major defensives and offensives at 1.2×, then the rest, debuffs before buffs; a controlled unit's portrait becomes a big CC icon with glyph, short label and seconds (test: order, sizes and drawn order).
- [x] Floating combat text over the unit through the camera: damage dealt and taken, heals, crits larger with a pop, CC applied by name; texts of nearby units step apart; at most 40 live, gone after 1.3 s; failed presses show "Out of range" and the like under the timer (tests: spawn, crit size, filtering, cap, expiry, projection and rise, overlap avoidance).
- [x] Match timer (countdown to the gates in preparation, stops at the end) and dampening percentage from the view; loss-of-control alert in the centre with the CC's glyph, label, effect name, seconds and a draining bar for stun, incapacitate, fear, silence, disarm and root on the local player, hidden otherwise (tests: timer and dampening against `ArenaMatch`; stun, stun over root, fear, nothing for others' CC; a real stun in the simulation appears and clears).
- [x] Scaling: the 1920×1080 logical layout under canvas_items stretch, times `ui_scale`, grown so the smallest text reaches 11 screen pixels (1.18× at 720p); test lays out at 1280×720, 1920×1080 and 2560×1440 and checks no element (including its auras, cast bar and arena extras) overlaps another or leaves the screen, and the smallest text size.
- [x] Practice scene hook (`--no-hud` to hide it); screenshots reviewed mid-fight: `previews/hud/hud_1280x720.png`, `hud_1920x1080.png`, `hud_2560x1440.png` (player feared, allied healer casting, enemy on Break Free cooldown with DR), `hud_combat_text_1920x1080.png` (player rooted, both enemies stunned and interrupted, combat text). Fixed from them: dark unreadable physical icons, duplicate glyphs within a school, overlapping combat text, low-contrast health text on pale class colors, the alert covering the character's head, frames colliding at 720p, key labels on empty slots, "1:13" overflowing small boxes.

**Match flow and verification**

### M1-28 Match flow `[done]`
- [x] Menu → "Play 2v2 vs bots" → preparation room → gates open → fight → end screen with damage and healing scoreboard → back to menu (`game/ui/main_menu.gd`, `game/client/match_flow.gd`, `local_server.gd`, `match_scoreboard.gd`; menus in `data/menus`).
- [x] A human player can play a full match with a bot partner against two bots: `tools/match_flow_e2e.py` clicks the real buttons and plays to a kill through keyboard and mouse events (259 s, in check_all full mode); the scoreboard equals the server's totals. Failure paths (server lost, cannot start, leaving) end at the menu.

### M1-33 Slash sound, chosen by the human `[done]`
- [x] Build the human's pick (D) of the four slash readings (`previews/audio/slash_candidates/`, KNOWN_ISSUES 2026-10-01) into impact_slash, hit_greatsword_plate and hit_greatsword_cloth as data, keeping the weapon and armor identity tests; adjust build rules only by an explicit DECISIONS entry (B and D carry a metallic ring the tonal rule may flag).

### M1-34 Reference video of a bot match `[done]`
- [x] `tools/match_video.sh`: a recorded networked 2v2 drawn through the client with Godot's Movie Maker at 30 fps with game audio, encoded to MP4; shared with the human.
- Done 2026-10-01: 2:52 (preparation, a 2:30 fight, end screen, scoreboard), sent at 1080p (27 MB, two-pass to fit the 30 MB file limit; the tool now makes that copy) and 720p. The software renderer took 6 h 12 min (4.3 s a frame at half-resolution 3D). The recording predates the deeper starting rooms, nameplates and the gallows collapse.
- Found in it: (1) the player's Warblade died at about 1:15 and the camera stayed on the body for the last 1:20 of the match (F-16); (2) the mix touches 0 dBFS on 534 samples (F-17).

### F-16 Spectating after death `[done]`
- [x] When the player dies in an arena, the camera can follow a living teammate (cycle with a key; the HUD's frames stay), as in the reference video's last 80 s where it showed a corpse; tests for the camera target and the cycle order.
- Done 2026-10-01: the camera follows the first living teammate by id, Tab (the target key, useless while dead) moves to the next, a line says who is watched; reviewed on the reference recording at 1:40 (`previews/f_16/spectating_1280.png`). Recordings drawn later follow the partner by themselves.

### F-17 Master bus headroom `[todo]`
- [ ] The reference video's mix reached 0 dBFS on 534 samples (mean -17.8 dB): add a limiter or lower the master so a busy fight never clips; measure on a recorded match.

### M1-32 Match flow follow-ups `[todo]`
- [x] The preparation camera sat very close: the starting rooms were 4.5 m deep with spawns 2.2 m from the back wall. Rooms deepened to 8 m (bounds 25 to 28.5 m), spawns 3 m behind the gate; bots unaffected (42 of 42 matches to a kill, median 93 s); `previews/m1_32/prep_room_1280x720.png`.
- [x] Action bars, the cast bar and the loss-of-control alert hide once the match has ended (`hide_on_match_end` in the HUD layout).
- [ ] Bots log a warning when the player leaves mid-match; `LocalServer.stop()` blocks up to 2 s.
- [ ] The server tick peaked once at 43 ms (average 0.30 ms): find the spike (M1-31 profile).
- [ ] The game has no name yet; the menu says "Arena PvP" (working title in `data/menus/main.json`). Ask the human.

### M1-29 Replay test `[done]`
- [x] Every match records its input log (`game/core/input_log.gd`: every applied input and every world edit, joining, leaving, preparation hold and respawn, with its tick and phase; Godot binary format so floats stay exact). The server writes it with `--input-log`; Play vs bots always does.
- [x] Replaying it reproduces the same final state hash (`game/core/replay.gd`, `godot -s res://tools/replay.gd -- --log <file>`): checked after every networked match in `tools/sim/run_match.py` (all three check_all network matches, including 150 ms and 2% loss) and in the end-to-end match; a networked 2v2 fought to a kill (5,513 ticks, 21,260 entries) replays in 1 s. GdUnit: a bot arena match replays exactly, one changed input changes the hash, world edits replay, floats survive the file.

### M1-30 Network test `[done]`
- [x] A full bot 2v2 at 150 ms latency, 2% loss and 30 ms jitter completes without desync or stuck casts: new check_all (full) check "network 2v2 arena at 150 ms, 30 ms jitter, 2% loss". First run: 17,345 ticks (4.8 min of match time) to a kill; every client's first view of the ended match equals the server's health for every unit at that tick; no cast shown past its end tick (detector tested); own-movement corrections at most 0.125 m; the input log replays to the same hash.

### M1-31 Performance baseline and M1 gate review `[done]`
- [x] Server tick time for a 4-player match recorded: 0.30 ms average, 0.45 ms 95th percentile over a full lagged 2v2 (17,345 ticks); one 55 ms spike (M1-32).
- [x] Client frame time on the software renderer recorded as a relative baseline (`docs/reports/review_03/client_frames_*.json`, capture `--frame-report`): practice 2v2 before F-05 at 1280x720 5.2 s and 1920x1080 8.7 s per frame on llvmpipe (2 cores, shared), about 400 draw calls, 300k primitives average; F-05 dressing raised the player view from 87 to 182 draw calls and 347k to 528k primitives. GPU fps check pending in KNOWN_ISSUES.md (2026-09-28).
- [x] Full review pass (`docs/reports/review_03/review_03.md`); the M1 gate passes except the 60 fps check, which needs a GPU machine (F-02). Result in CHANGELOG.md.

---

## Improvements from available tools (decided 2026-09-30)

The human asked to incorporate any readily available offering that improves the end result, in every area. Checked from the cloud workspace: PyPI and GitHub (git) are reachable; asset websites and Hugging Face are not; no GPU. Licences recorded in CREDITS.md.

### X-01 Motion-capture locomotion from the CMU database `[done]` (narrowed; see below)
- [x] Import CMU BVH clips, fit them to the standard skeleton as animation terms (`tools/blender/mocap.py`, `build_capture.py`; sources in `data/capture_sources`, fitted curves in `data/captures`), so captured clips use the same pipeline (build offsets, holds, clipping gate, bake).
- [x] Stylise by data: per-channel gains around the mean, the clip's keys added on top, and a relative mode that keeps only the captured movement.
- [x] Compared side by side (`tools/blender/compare_capture.py`: foot slide, floor contact, bounce, side and three-quarter sheets). Kept: run (legs, torso, hips from CMU 09_01, stride gain 1.7: foot slide 27% of running speed against 46% for the scripted run; weapon arm and free arm stay scripted) and idle (CMU 82_08 upper-body movement over the scripted posture: breathing, shoulder shifts, looking around; hips and legs keyed so the feet stay planted). Strafes and backpedal stay scripted: the database has sideways and backward motion only as walks of about 1 m/s, against 7 and 4.2 m/s in the game. Jump stays scripted: captured jumps start with a crouch the game's instant take-off does not have, and the game's 8 m/s launch is far beyond a human jump.

### X-10 Captured free arm on plate builds `[todo]`
- [ ] The run's captured free arm swings across the chest and past the hip, which heavy plate does not allow (3 attempts: 3.5-7.6 cm contacts; raising the arm 24° still left 3.9 cm). The run uses the scripted free arm for now. Try a per-build arm corridor (limit the capture's arm direction to a cone that clears the torso and legs of each build) so the captured swing can be kept.
- [ ] Remaining foot slide on the run (27%): foot locking on the baked clip (a leg IK pass in the bake that pins the supporting foot) or a runtime stride-matching modifier.

### X-02 Runtime character polish from Godot's built-in modifiers `[done]` (narrowed: spring bones split to X-07)
- [x] Foot grounding with TwoBoneIK3D (ray per foot, pelvis drop, slope tilt; exact no-op on level floors) and feet planted while turning in place; head, neck and chest turn toward the target with LookAtModifier3D (±70° yaw, +30/−35° pitch, eased, off in crowd control, death and big swings).
- [x] All tunable in `data/anim_states/humanoid.json` `rig_modifiers`; graphics toggle and 35 m cut-off; 13 tests; review scene `rig_view.tscn`. Cost 27-56 µs per character.

### X-07 Spring bones on loose cloth `[todo]`
- [ ] Add cloth bones to the character build (hood tip, stole ends, sash tail, tabard, skirt panels; the Oracle's robe stretches at the captured run's full leg extension), skinned from the Blender scripts, and drive them with SpringBoneSimulator3D and collision capsules on the legs and body; tunable in data; screenshots in motion.

### X-08 Rig modifier follow-ups (from X-02) `[todo]`
- [ ] The player's own character looks along the camera (hook `RigModifiers.look_override`, wired in `world_renderer.gd`).
- [ ] Jump detection relative to the floor under the character (today any height above 0.02 m counts as airborne), before any map has steps or ramps.
- [ ] The Warblade's hanging sword dips into a step when the pelvis drops.

### X-03 Ability icons and typography `[done]`
- [x] Ability icons from game-icons.net (CC BY 3.0, attribution in CREDITS.md), chosen per ability in data and rendered in the game's style (school-colour gradient, bevelled iron frame, glow for off-cooldown), replacing the initials glyphs.
- [x] HUD and menu fonts from Google Fonts (SIL Open Font License): a display face for titles and names and a readable face for numbers and small text; minimum sizes kept.

### X-04 Studio-grade sound processing `[done]`
- [x] Add pedalboard (PyPI) effects to the sound build: convolution or algorithmic reverb, compression, saturation, EQ; an arena reverb on the world buses in Godot.
- [x] All existing audio tests still pass (peaks, tonality, clicks, CC warning loudest); spectrogram review; list for the human's listening pass.

### X-05 Mesh quality pass `[done]` (no change kept)
- [x] Tried pymeshlab quadric and isotropic remeshing, pyfqmr and Taubin smoothing on all 69 character pieces at equal triangle budgets (slivers, normal error, Hausdorff shape error, time, close-ups). Blender Decimate stays: the others have cleaner triangles but lose shape and detail (DECISIONS 2026-09-30).

### X-11 Body smoothing shrink `[todo]`
- [ ] The body's Corrective Smooth shrinks it by 4-7 mm RMS and blurs the face, knuckles and knees. Widen the Oracle's mask and coif offsets (skin pokes through at the chin and ear without the smooth), drop the smooth, rerun the clipping gate and compare close-ups.


### X-12 Client prediction with talented auras `[done]`
- [x] Snapshots carry which player's version an aura is (or its speed effect), so the client predicts a talented slow or speed boost exactly; a test where a talented slow is predicted without a correction.
- Done 2026-10-01: the player's own unit in each snapshot carries the movement speed values of its auras whose talented speed differs from the data (protocol 10); the client predicts with them. The test checks that the client's speed from a decoded snapshot equals the server's for a talented 50% Chilled (the data alone gives 40%), which is what keeps prediction from needing a correction.


### X-13 Visual effects for talent-applied auras `[done]`
- [x] The effects validator accepts entries for auras that only talents apply (bound_dazed, windpipe_crushed, stiff_neck and others), and those auras get readable effects like the kit's.
- Done 2026-10-01: the validator reads which auras talents make an ability apply (apply_aura entries in talent effects on "<ability>.effects") and counts talent-granted abilities as covered; it then required seven visuals, now added: speed streaks for the two Break Free speed boosts, a body glow for Stiff Neck's crowd control immunity, drips for Seared by Judgment (healing taken down), a small shield for Peal Shelter, mist at the feet for Bound Dazed, and the silence halo for Windpipe Crushed.

### X-14 Sound processing without native plugins `[done]`
- [x] The five pedalboard effects (distortion, compressor, chorus, phaser, reverb) are our own numpy and scipy code matching pedalboard within 1e-3 of peak (most within 1e-6); pedalboard is only a test reference, run in a separate process so a crash skips those comparisons. Done 2026-10-01 after pedalboard's Distortion crashed a CI run with an illegal instruction.

### X-15 Renderer skipped ticks in the CI match flow `[todo]`
- [ ] The CI run of 26e3202 failed the match-flow check with 418 of 8543 ticks not drawn (4.9%, limit 2%) and 14.6% of ticks without a new snapshot; earlier runs passed. Find out whether it is runner speed or a change in M2-13 (settings applied at match start), once the workspace CPU is free to run the check locally.
- 2026-10-01: the CI run of 7576b97 failed the same check differently: the client timed out in the match step after 870 s with no tick drawn while the bots stayed connected. The same check passed locally on aa36784 (227 s, 1.2% of ticks not drawn, with the video render using the CPU). The check now prints the run's last client and server log lines on failure, so the next CI annotation shows where it stopped.

### X-18 Nightly balance results (first run, 2026-10-01) `[todo]`
- [ ] 1v1 (1,000 duels, random builds): Warblade 62%, Oracle 8%, Arcanist 78%; the Arcanist has 1 viable build; two Arcanist nodes are in every top build (turning_hours, gliding_ice). 2v2 and 3v3 hit the 4-hour job limit (now split into 6 and 8 parallel shards); the 20-player profile failed without saying why (it now reports the end of its output as errors). Feed into M2-07 (1v1 tuning) and M2-04 (trees).

### X-19 20-player profile on CI `[todo]`
- [ ] The nightly 20-player profile fails: on a 4-core runner the 20 bot clients receive 5 to 6 snapshots a second (expected 60). Review 3 measured 57.6 per second on the 2-core workspace, so either the clients got much heavier since (talents, settings, twists) or the runner is starved; profile one bot client and compare with review 3.

### X-06 Continuous integration on GitHub Actions `[doing]`
- [ ] Run tools/check_all on every push, and a nightly job on a multi-core runner for the balance simulations and the 20-player performance profile (the workspace has 2 cores, which skews those numbers).
- 2026-10-01: the nightly schedule (03:17 UTC) has not fired on two nights (no scheduled runs in the history); the workflow was started by hand with workflow_dispatch. The balance jobs now run one simulation process per core and simulate random talent builds (M2-04).

### X-09 Follow-ups from X-03 and X-04 `[todo]`
- [x] Listening pass on the approved sounds: the human preferred every processed version; the slash still did not read as a slash (redone as v3) and the mace should be lower (impact_low).
- [ ] Human listening pass on slash v3 and the lowered mace (`impact_slash`, `hit_greatsword_plate`, `hit_greatsword_cloth`, `hit_mace_plate`, `impact_blunt`), then the rest of the processed sounds (start with `cc_warning`, `hit_mace_plate`, `hit_greatsword_plate`, `break_free`, `rime_bolt_release`, `frost_cast_start`, `red_mist`, `holy_heal`, then a practice fight in Gallows Courtyard for the room and the duck), and a choice for the three approved sounds kept unprocessed: approved original or processed alternative (`previews/audio/x04/listening_ab/`).
- [ ] Tune the world duck under the CC warning by ear; acoustics file for every new map; model the reverb's stereo spread in the numpy check.
- [ ] Lighter out-of-range tint on action buttons (the red covers the glyph); spec icons for unit-frame portraits; regenerate the combat-text review screenshot.

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

### F-05 Gallows Courtyard dressing polish `[done]`
- [x] Skyline beyond the walls (keep, round towers, bell tower, two rows of town houses; no collision or shadows).
- [x] Gatehouse above each gate hides the raised portcullis.
- [x] Ramparts and a wall walk on the wall tops; the floor ring outside the walls is gone.
- [x] Props (crates, barrels, chains, rubble, weapon racks, long team banners, drains) and animated brazier fire with flickering light (`data/ambient_effects`).
- [x] Floor variation: worn tiles, grime along wall bases and pillars, stains, puddles. Gameplay colliders unchanged (fingerprint test).

### F-15 Arena dressing follow-ups (from F-05) `[todo]`
- [ ] Draw calls roughly doubled (player view 87 to 182): check on a GPU machine; merge the three flame meshes per brazier.
- [ ] Puddles read as dark patches: reflection probe or screen-space reflections.
- [ ] Props have no collision (players walk through crates at the walls): add low colliders deliberately if it reads badly in play.
- [ ] A brazier crackle sound.

### F-06 Two-handed grip, melee clean-up and stronger releases `[todo]`
- [ ] Melee windups are long for instant abilities (strikes at 0.41-0.49 s): shorten them so the blade lands sooner after the press; impact sounds and visuals follow the strike automatically (DECISIONS 2026-10-01).
- [x] The left hand reaches for the hilt of a two-handed weapon in the three melee attacks (two-bone reach baked into `<clip>_two_handed` clips; the handle moves toward the midline and in front of the body).
- [ ] Two-handed guard in combat idle: with both hands on the handle, the left upper arm and its pauldron sink up to 7 cm into the breastplate near the collarbone (heavy build, deep plate). Needs a stance redesign or pauldrons that partly follow the clavicle; until then combat idle keeps the one-handed guard, which passes the clipping gate.
- [ ] Cast releases read small from the game camera: exaggerate the push and hold the follow-through a few frames longer.
- [ ] Melee attacks, ranged shot, feared run and victory still pass arms through the torso or pauldrons in overhead frames (up to 11 cm in attack_1); bring them under the same 1.5 cm clipping limit as the gated clips, heavy build first.

### F-07 Robe skirt deformation `[done]`
- [x] Arcanist and Oracle robe skirts stay closed at the front: below the waist, skirt weights fold calf into thigh, give part of the leg weight to the pelvis (most near the waist) and let the middle follow both thighs halfway (`soften_skirt`).
- [x] Pose test shows no dark gap at the robe front; the clipping check still passes.

### F-08 1v1 balance (for M2, when 1v1 becomes a supported bracket) `[todo]`
- [ ] Review pass 2 (1,000 simulated duels): Arcanist beats Warblade 66% and Oracle 100%; Oracle beats Warblade 2%. In 3v3 (M2) the Oracle wins 61% overall because two-healer teams win 74-78%; bring 3v3 specs within 40-60%. Healers may lose duels more often than not, but not almost always: give the Oracle a way to win a long duel (damage over time, a stronger Castigate under dampening, or mana-free pressure) and bring every duel match-up within 35-65%.
- [ ] Mirrors now end by a kill (they timed out 98% of the time before the hiding fix); keep that above 90%.

### F-09 Controls and targeting polish (found in M1-23) `[todo]`
- [ ] Tab remembers the enemies it went through recently, so three enemies whose angle order changes while they move are never skipped or repeated before all were visited.
- [ ] The target ring reads small beyond about 15 m at 1280×720: judge it again with nameplates and the target frame (M1-27), and scale it with distance or add a marker above the target if it still does not read.
- [ ] Camera collision covers visual-only kit parts above the map colliders (the gallows frame and nooses, banners) or those parts get colliders.
- [ ] Cursor capture while dragging and cursor return on release checked by a person on a real display (headless tests cannot move the OS cursor).
- [ ] Mouseover targets and the target modes per bind from DESIGN.md (M2 keybinding page). Focus exists since M1-27 (Shift+F sets it, the focus frame shows it); nothing casts at the focus yet.

### F-10 Animation hookup polish (found in M1-24) `[todo]`
- [ ] The cast loop reads small from the game camera (one hand reaching forward); with F-06's stronger releases, give the loop a two-handed or staff-raised gather so a cast is readable at 30 m (DESIGN.md "readable chaos").
- [ ] Run, strafe and backpedal have different cycle lengths (0.73, 0.7, 0.8 s); on diagonals the feet can shuffle. Sync the cycles (equal lengths or phase-matched blending) and judge a diagonal run on a pose sheet.
- [ ] Auto-attacks need no facing, so a unit can swing at a target behind it (seen in the practice fight). Decide whether melee swings require facing (M2 combat rules) or the character turns toward its target while swinging.
- [ ] Jump lands on a 0.2 s fade from a 0.9 s clip for 0.8 s of air time; add a short land clip or end the jump on touchdown.
- [ ] The practice scene reports leaked objects at exit (36 instances; the scripts still in use are the match's: `MatchRunner`, `Sim`, `Combat`, `BotBrain`...). Probably a reference cycle, e.g. `MatchRunner.bot_system`'s closure registered on its own `Sim` (M1-23 code, harmless at quit); find it with `--verbose` and break it when the match ends.

### F-11 Sound polish (found in M1-26) `[todo]`
- [ ] Human listening pass on the M1-26 sounds (list in CHANGELOG.md 2026-09-30); fold the feedback into the recipes and DECISIONS.md like the M0-16 rounds.
- [ ] Aura loops (DESIGN.md: each ability has cast start, cast loop, release, impact and aura loop): quiet loops while frozen, feared, silenced, shielded or empowered, following the unit, within the voice cap.
- [ ] Signature sounds for the Warblade's core strikes: Grim Hack, Wide Hew, Gashing Blow and Crippling Slash share the greatsword swing and hit (plus the wet gash layer); give each a layer of its own so every ability reads by ear (DESIGN.md "a distinct sound per stage").
- [ ] Occlusion: sounds behind pillars and walls (the server's line-of-sight colliders) low-passed and a few dB quieter, so a hidden caster sounds hidden.
- [ ] Settings (M2 settings suite): per-bus volume sliders, output device, mute when unfocused, CC warning on/off (`AudioDirector.cc_warning_enabled` exists; nothing sets it yet).
- [x] The HUD (M1-27) plays `ui_click` through `AudioDirector.play_ui` for action buttons and unit frame clicks.
- [ ] `AudioStreamPlayer.play()` plus `stop()` cost about 0.4 ms each in the headless debug build (KNOWN_ISSUES.md); measure on a release build with a real audio device at M1-31 and, if it holds, avoid stopping voices that are about to be restarted.

### F-12 Spell effects polish (found in M1-25) `[todo]`
- [ ] Settings from DESIGN.md: opacity of other players' effects and camera shake (none yet) in the graphics settings (M2 settings suite).
- [ ] Buffs share generic styles (empower glow, shield bubble), so Red Mist, Deep Winter and Seraphic Surge differ only by color: give major cooldowns their own shape (wings, frost crown, blood haze) so an enemy's burst reads before its damage.
- [ ] Physical crowd control (Pommel Crack, Warpath Charge, Dread Roar) is drawn in pale steel and reads weaker than colored CC in `practice_fight_1.png`; judge again with nameplates and the loss-of-control alert (M1-27) and add a shared CC accent if it still does not read at 30 m.
- [ ] DESIGN.md effect tools not used yet: dynamic lights from spells (cap 16 visible), ground decals (circles are flat quads at y = 0, fine for flat arenas), dissolve and heat-distortion shaders.
- [ ] Fire and blood are 18 degrees apart in hue (told apart by value); recheck with the first blood or fire class (M3) in a real fight.
- [ ] Frame time of effects in a 20-player battleground on a GPU (particles budget 4,000) with F-02.

### F-13 HUD polish (found in M1-27) `[todo]`
- [ ] Real icons: the placeholder icons (school gradient, glyph, initials) read mostly by initials, and the Warblade's physical kit is all one bronze; the Blender icon generator from DESIGN.md "Icons" (128 px, painted frame), fed by the same icon data.
- [ ] Nameplates over characters (DESIGN.md: class color, health, cast bar, important debuffs) and a target-of-target frame; judge the F-09 target ring again with them.
- [ ] Player-adjustable spell queue window (0-400 ms, DESIGN.md Gameplay page): send the setting to the server with the inputs, or hold presses client-side until the window opens.
- [ ] At 1280×720 the smallest text (aura seconds, cast bar names, DR marks) sits at the 11 px floor; check on a real display and raise `min_text_px` or the aura size if it strains.
- [ ] Enemy frames show the spec's initials, not a spec icon; the arena DR marks (½, ¼, IMM) are small on 22 px squares.
- [ ] Iron-and-parchment interface art (DESIGN.md interface rules): frames are flat dark panels with a bronze line for now.
- [ ] A performance check of the HUD's per-frame `_draw` at 20 units (raid frames, M4) on the software renderer and a GPU.

### F-14 Bot brain cost at battleground size `[todo]`
- [ ] Review pass 2: a 20-unit match costs 7 ms per tick in one process with every bot deciding every tick (the networked server without brains averaged 1.8 ms). Bots decide at 10-20 Hz with movement between decisions, and cache line-of-sight and paths, so 20 bots cost under 2 ms per tick. Needed before M4.
- [ ] Re-measure the networked 20-player run on a machine with more than 2 cores (on 2 cores with 21 processes the server's 95th percentile tick was 9.3 ms and snapshots 57.9 per second, from CPU contention).

### F-02 GPU frame-rate measurement `[blocked: needs a GPU machine]`
- [ ] Record fps for the M1 vertical slice on recommended and minimum PC profiles at the M1 gate.

---

## M2 — Combat depth and settings (split 2026-10-01)

Exit gate (DESIGN.md): every combat rule has passing tests; every action is rebindable; UI layouts save and load. Order: the M1 follow-ups above first (M1-32, F-06), then these.

### M2-01 Combat rules test matrix `[done]`
- [x] `docs/combat_rules.md`: every rule in DESIGN.md "Core combat system" (GCD and its haste floor, spell queue window, cast and channel rules, moving while casting, school lock, strongest slow only, damage formula terms, armor, resources, DR steps and reset, the 8 s CC cap, Break Free, dispel types, LoS at cast start and finish, ranges, arena rules) with the test that covers it.
- [x] A test for every rule that has none; a check that fails when a rule in the document names no test. (Rules owned by later items name them: energy GCD M3, queue window setting M2-13, CC break rules M2-02, targeting keybinds M2-11, 1v1 time limit M2-07.)

### M2-02 Full crowd control and diminishing returns `[done]`
- [x] Disarm (no weapon abilities or auto attack, own DR category) and knockback (displacement, no DR) in data and combat; at least one ability of each in the slice kits or a test-only ability.
- [x] Every category's break rule from DESIGN.md (incapacitate on any damage, disorient over 10% of max health, roots by data), the 8 s cap, DR 100/50/25/immune resetting 18 s after the last effect ends; tests per category.
- Done with test-only disarm and knockback abilities; the slice kits get one of each when a class wave needs it. The code already handled both; M2-02 added the tests (`game/test/core/test_crowd_control.gd`; breaking the disarm and incapacitate rules in the code makes them fail) and a data rule tying every crowd-control aura to its category's break rule.

### M2-03 Talent system `[done]`
- [x] Node types passive, active (grants an ability), choice and capstone; gates at 8 and 20 points; a node unlocks when a connected node above is fully ranked; 30 + 30 points and 3 PvP slots.
- [x] Talent effects apply to units at match start from data paths (ability numbers, aura numbers, unit stats, cooldowns), with no per-class code; talents lock when the gates open.
- [x] Validator: unreachable nodes, broken references, wrong point totals, duplicate positions.
- Follow-ups: the client predicts movement with untalented aura data (a talented slow mispredicts until the next snapshot corrects it; X-12); the arena frame's enemy Break Free timer uses the untalented 90 s (M2-14, fixed); talent-granted abilities need action bar slots (M2-05); bots and the batch simulator need loadouts for build simulations (M2-04).

### M2-04 Talent trees for the three slice specs `[doing]`
- [x] Warblade, Arcanist and Oracle class trees (about 40 nodes), Carnage, Rime and Grace spec trees (about 40), 12 PvP talents each; original names; icons from game-icons.net in the HUD style.
- [ ] At least three viable builds per spec in bot simulations (each within 40-60%), and no node taken by more than 90% of the top simulated builds.
- Trees, builds, new abilities and icons are in (2026-10-01). Left: the bot simulations for the second criterion, after the reference video render frees the CPU; a six-match smoke run had matches up to 11 minutes, so survival and healing talents likely need trimming.
- 2026-10-01: the simulation for the second criterion is built. `tools/sim/nightly.py --random-builds 9` gives every unit a random build of its spec (the three named builds or one of nine random legal builds, `Talents.random_build`), runs the matches in parallel processes, and reports each build's win rate over non-mirror compositions, how many are viable, and the share of each node among each spec's top half of builds. A local 2v2 match takes about 23 s of one core, so the 1,000-match runs go to the nightly workflow on 4-core runners (dispatched by hand: the schedule has not fired yet, X-06).
- Follow-ups: auras applied only through talents cannot have visual effects yet (X-13); bots read their own talented numbers but not an enemy's.

### M2-05 Talent screen and loadouts `[done]`
- [x] The screen draws itself from the data (positions, connecting lines, icons, tooltips, point counters); up to 10 loadouts per spec; export and import as a short text string; locked in a match.
- Follow-up: changing talents during a networked match's preparation needs a protocol message for MatchRunner.set_talents and a way to open the screen from the pause menu (M2-05b).

### M2-05b Talents during preparation `[done]`
- [x] During a match's preparation the player can open the talent screen from the pause menu and switch loadouts; the change reaches the server (a reliable message calling MatchRunner.set_talents), the action bars update, and after the gates open the screen opens read-only. Tests for the message, the server's refusal after the gates, and the bars.
- Done (2026-10-01): a Talents button in the in-match and practice menus; protocol 9 adds a TALENTS message both ways (request, and the server's answer with the loadout in use or why it refused); the HUD rebuilds its bars when the loadout changes.

### M2-06 Spellbook and tooltips from data `[done]`
- [x] Ability and aura tooltips in the HUD and a spellbook screen, generated from data with the codex's computed numbers (no hand-written numbers that can drift).

### M2-07 1v1 bracket `[doing]`
- [ ] Rules: dampening from 1:00, 12-minute limit, health and mana pickups at 1:30; menu entry "Play 1v1 vs a bot"; balance per F-08 (each spec 40-60% in 1,000 simulated duels).
- Done 2026-10-01: the rules (dampening from 1:00, the 12-minute limit, pickups at 1:30 in 1v1 and 2v2), the menu entry, bots that take pickups. Left: the 1,000-duel balance run per F-08, after the reference video frees the CPU.
- 2026-10-01, tuning: duel balance is data, as standing auras per bracket by role or spec (`tuning.arena.bracket_auras`; visible, undispellable): Duelist's Resolve (healers), Measured Blade (Carnage), Steady Footing (Rime, physical damage only). Untuned, 60 named-build duels gave Warblade 100%, Arcanist 30%, Oracle 20%. Three local rounds of 60 duels swung widely (Oracle 0-65%) because single duels are chaotic and 10 per match-up is too few; the rest of the tuning runs 1,000 duels on CI (`.github/workflows/duels.yml`, 8 shards). Oracle mirrors always reach the 12-minute limit (dampening reaches only 66% by then).

### M2-08 3v3 bracket `[doing]`
- [ ] Three-player teams through the whole flow (menu, prep, scoreboard), arena enemy frames 1 to 3; balance per F-08 (two-healer teams no longer dominate).
- Done 2026-10-01: three-player teams through the whole flow (menu, preparation, scoreboard), three arena frames. Left: the balance run per F-08 (two-healer teams), after the reference video frees the CPU.

### M2-16 Arena twists `[done]`
- [x] A data-driven twist system on match time (docs/DESIGN.md: each map has one twist), server-authoritative and replayable, with the client's prediction, the camera and the map visuals following the same clock; Gallows Courtyard's gallows collapse at 5:00 after a warning at 4:50 (a banner, event text and sounds), opening the centre for movement and line of sight and leaving a low wreck and a dust burst. Tests for the stages, the collapse on the server with a replay, the client, the map and the announcements; validator rules for twist data.
- [x] Screenshot of the wreck reviewed (`previews/m2_16/gallows_before_1280.png`, `gallows_wreck_1280.png`, from `tools/ui_shot.gd --screen map --match-time <s>`): the first version was a few sparse planks and a bright white puff; now beams, planks and broken plinth stones cover the footprint and the dust is dim grit.
- Found while planning M2-09: the gallows collapse was described in the map data but never implemented. Next twist types: flood (M2-09) and a rotating obstacle (M2-10).

### M2-09 Second arena `[doing]`
- [ ] About 40 m across, 3 to 5 line-of-sight blockers, two starting rooms, one twist (for example a collapsing bridge); kit pieces by Blender script; navigation and bots work; screenshots against the art bible.
- 2026-10-01, Flooded Crypt: a sunken, roofless crypt at night (`data/maps/flooded_crypt.json`, lighting `moonlit_crypt`), 39 x 36 m, two columns and two great tombs (4 blockers), the same starting rooms and gates as Gallows Courtyard. Twist: at 3:00 the nave floods (water rises during the 15 s warning) and wading slows everyone to 70% outside the side aisles and gate landings; the slow is part of movement on server and client alike (`ArenaGeometry.ground_speed`), so prediction needs nothing new. Kit `crypt`: 15 Blender-built pieces (`tools/blender/build_kit_crypt.py`; walls with burial niches and pilasters, broken-ribbed columns, carved tombs, grille gates, gatehouse, braziers, bone piles, grave slabs, ruined skyline), moss, rising damp and wet streaks added to the shared kit materials. Two flood sounds. Matches now pick an arena at random from the preset's list (`maps`), and recordings carry their arena. Bots: 6 test matches all ended by a kill. Bots path around flooded cells when the aisles are not much longer, and after the gallows collapse they path through the centre (the navigation grid now follows twists). Left: a splash when wading; review screenshots with players taken (`previews/m2_09/`).

### M2-10 Third arena `[todo]`
- [ ] As M2-09 with a different twist (rotating obstacle, flood or shrinking safe zone) and a distinct look and lighting preset.

### M2-11 Keybinding screen `[done]`
- [x] Every action, bar button and interface toggle rebindable; Shift, Ctrl and Alt; mouse buttons 1 to 5 and wheel; a target mode per bind (target, focus, mouseover, self, arena 1 to 3); conflict warning; reset to default; import and export.
- Follow-up: mouseover reads units in the world; hovering a unit frame does not count as mouseover yet (M2-14, fixed).

### M2-12 HUD edit mode `[done]`
- [x] Toggle with labeled outlines; drag to move with grid snap; scale 50-200%; opacity; per-element options; layouts saved as named profiles (optionally per spec), exported and imported as text; checked at the five DESIGN.md resolutions.

### M2-13 Settings suite `[done]`
- [x] Interface, Gameplay, Graphics, Audio and Accessibility pages with every setting in DESIGN.md; each applies instantly except resolution; saved per profile.
- Follow-ups: nameplate settings take effect when nameplates exist (M2-14, fixed); "reduce camera shake" has nothing to reduce until the camera shakes.

### M2-14 Arena HUD for 2v2 and 3v3 `[done]`
- [x] Arena enemy frames with spec icon, cast bar, Break Free cooldown and a DR tracker per CC category; focus target frame and cast bar; nameplates with class color, health, cast bar and important debuffs.
- [x] Screenshot reviewed on a stand-in 3v3 scene (`tools/ui_shot.gd --screen nameplates`: figures in a lit room with the real HUD, a cast, crowd control, a defensive and a marked target); it showed a plate's aura row overlapping the plate above, fixed by making the row part of the plate. The planned screenshot of a real networked fight could not run while the reference video renders (two Godot clients on two cores stall the match start); it moves to M2-14c.
- Done (2026-10-01): spec icons in frame portraits (spec data `icon`); nameplates as a HUD layout element following the three nameplate settings; a unit frame under the pointer counts as mouseover; the arena Break Free box uses the cooldown the server started (talents included; cast_success events carry `cooldown_ticks`).
- Follow-ups: clicking or hovering a nameplate does not target or count as mouseover yet (M2-14b, done); nameplates do not fade with distance or line of sight.

### M2-14c Nameplates in a real 3v3 fight `[done]`
- [x] A screenshot of a networked 3v3 fight with nameplates, reviewed (plates over real character models, at real distances and with movement).
- Done 2026-10-01 (`previews/m2_14/fight_3v3_nameplates_1280.png`, a recorded 3v3 played back through the client): plates read over the models, the target plate is marked, the rooted partners show big ROOT portraits. Fixed from it: floating combat text was drawn under the plates (the draw order was reversed); a test now checks it. A live 3v3 with the software renderer stalls long enough at the first fight for the server to drop the client (six bots, a server and a software-rendered client on two cores), so screenshots of 3v3 fights use recordings.

### M2-14b Nameplate clicks and mouseover `[done]`
- [x] A click on a nameplate targets its unit and the pointer over a plate counts as mouseover, like unit frames; tests with the plate rectangles. Done 2026-10-01 (the nearest plate wins where plates overlap; hidden plates catch nothing).

### M2-15 Review pass and M2 gate `[todo]`
- [ ] Full review pass; the M2 gate checked and written to CHANGELOG.md.

## Later milestones (split into items when the milestone starts)

- **M3** Remaining 10 classes in waves of 3 or 4, each with kits, bots, models, animations, effects and sounds.
- **M4** Capture-the-flag and resource-control battlegrounds, raid frames, scoreboard, minimap, bot fill.
- **M5** Art and audio polish, rated matchmaking with Glicko-2, accessibility options, performance work, balance.
