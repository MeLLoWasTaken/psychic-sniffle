# Changelog

One entry per build-loop iteration, newest first. Format: date, backlog ID, what changed, how it was checked.

## 2026-10-01 — M2-07 1v1 bracket (rules, pickups, menu; balance runs next)
- "Play 1v1 vs a bot" in the main menu: a duel on a local match server against one bot. Dampening starts at 1:00, and a 1v1 is a draw at 12:00 (now tested).
- Regeneration pickups, as DESIGN.md asks for 1v1 and 2v2:
  - two spots light up once at 1:30; the first living player in reach takes one;
  - each gives Renewal (health over 10 s, dampened) and Clarity (mana over 10 s);
  - drawn as a pale green wisp with a soft light, with sounds when they appear and when taken;
  - hurt bots go for a nearby one.
  - The server sends the active spots in each snapshot (protocol version 6). The validator checks that every 1v1 or 2v2 map has clear pickup spots.
- The Play presets list bot allies instead of one partner, ready for 3v3.
- Checked:
  - rules tests (12-minute draw; pickups only in 1v1 and 2v2, at 1:30; nearest takes; health and mana restored);
  - a bot reaches a pickup; snapshots carry pickups; the menu entry;
  - a real 1v1 run end to end with no errors or warnings (local server, bot opponent, client: preparation, fight, end screen, scoreboard, menu);
  - all core, net and client tests pass.

## 2026-10-01 — CI: audio tests no longer call pedalboard's EQ
- Two CI runs crashed natively inside pedalboard's EQ filter (the known intermittent crash). The shelf and peak EQ are now scipy biquads with the same formulas JUCE uses; the output matches pedalboard's within 0.006% (about -85 dB), and the 80 sounds were rebuilt because their hash covers the generator code.
- check_all's CI annotation now starts with the crash header instead of keeping only the tail.
- Checked: all 493 audio tests, including a new one that checks each EQ's gain at DC, Nyquist and its frequency.

## 2026-10-01 — M2-06 spellbook and tooltips from data
- `AbilityText` computes tooltip text from data, using the player's talented copies: cast type, cooldown, cost, range, and each effect with numbers by the combat formula, plus the auras an ability applies. It is the in-game twin of the codex generator.
- Hand-written descriptions show this build's numbers: a number matching an untalented one is replaced by the talented one ("A steady heal for 13,000").
- HUD tooltips:
  - hovering an action bar button shows its ability;
  - hovering an aura on a unit frame shows what it does and its time left;
  - your own abilities and auras show your talented numbers; other players' auras show base data.
- The talent screen has a Spellbook tab: every ability of the spec, including those the loadout grants. Abilities changed by talents are marked, and hovering one shows the full tooltip.
- Small fixes:
  - durations read "1 min 22 s" instead of "1.37 min" (codex too);
  - long card lines end with an ellipsis;
  - build names read "Choir of Dawn".
- Checked:
  - every ability's description agrees with its data (talent abilities included);
  - talents change the shown numbers;
  - HUD tooltips for a button and an aura;
  - spellbook contents and layout;
  - 43 tests in those suites; the spellbook screenshot was reviewed and its problems fixed.

## 2026-10-01 — M2-05 talent screen and loadouts
- The main menu has a Talents button. The talent screen draws the class tree, spec tree and PvP row from the data: node positions, connecting lines, gate lines with their point badges, icons, ranks, point counters and tooltips (both options for choice nodes).
  - Left click adds a rank (on a choice node, the half clicked picks the option); right click removes one. A change that breaks the rules is refused with the reason ("Requires ...", "Spend 8 points in the rows above first", "Other talents depend on ...").
  - Loadouts: up to 10 per spec, selected on the right; Save, Save as new, Delete, Reset, Export (copies the code) and Import (pastes it). In a match the screen is read-only.
- Play and Practice send the active loadout. Practice bots and networked bots play their default build. Abilities granted by talents get action bar slots.
- `game/tools/ui_shot.gd`: a screenshot of one menu screen without the game flow, for checking layouts.
- Checked: 12 talent screen tests plus a bar test for every build's granted abilities; all 296 Godot tests pass. Screenshots of the Warblade and Arcanist screens and the main menu were reviewed: the Import and Done buttons overlapped, and gate labels printed over nodes. Both are fixed.

## 2026-10-01 — M2-04 talent trees for Warblade, Arcanist and Oracle (trees done; balance runs next)
- Three class trees (40 to 41 nodes), three spec trees (40 to 42 nodes, gates at 8 and 20, three capstones each) and three PvP rows of 12, all original names with icons. Written by three agents in parallel, one per class, then integrated and checked here.
- 15 new abilities from active nodes and choices, each with a visual effect and sounds:
  - Warblade: Hurtling Bound, Iron Oath, Gaoler's Chain, Reaping Turn or Bonecleaver, Wrench Grip;
  - Arcanist: Gale Glyph, Hourglass Ward, Hoarfrost Snare, Calving Ice;
  - Oracle: Cleansing Peal, Burden of Penance, Plea of Mercy, Canticle of Morning, Hallowed Stillness.
- About 50 new auras, mostly hidden passives (armor, damage taken, movement, cast speed).
- Three named builds per spec in the bot profiles:
  - Carnage: headsman, butcher, gaoler;
  - Rime: shatter burst, control root, survival kite;
  - Grace: radiant mender, choir of dawn, dread warden.
- 323 icon glyphs rendered and credited.
- Bots now decide with their build's numbers.
- New validator rules:
  - burst cooldowns stay 60 to 180 s however talents stack;
  - an aura may not share an ability's id;
  - talent effects that replace a field must come before edits inside it.
- Fixes: Red Mist's text said 25% (it is 20%); Lingering Grace's said 1,500 (it is 2,000).
- Checked: all 284 Godot tests, the Python tests and data validation pass; a six-match smoke run of mixed builds ended every match by a kill with no errors, but matches ran long (up to 11 minutes). The balance runs will look at that.

## 2026-10-01 — M2-03 talent system
- `game/core/talents.gd`:
  - checks a loadout against its trees (ranks, choice options, points, gates at 8 and 20, connections, 3 PvP slots);
  - turns a loadout into one player's numbers: patched copies of the abilities and auras it changes, the player's own health, stats and resource maximums, granted abilities and permanent passive auras;
  - encodes and decodes the shared text form.
- Combat looks abilities and auras up through the player's talented copies. An aura applied by a talented player keeps that player's numbers on its target. No class-specific code.
- Loadouts arrive with the player's hello message (protocol version 5). The server rejects illegal ones. `MatchRunner.set_talents` works during preparation and is refused once the gates open; the replay log records loadouts.
- Validator: talent effect paths must name a real field (a number when the effect adds), unit fields must be ones talents can change, granted auras must exist, and no two nodes may share a screen position.
- The draft Iron Hide talent now grants a passive armor aura; the codex shows granted abilities, passives and choice options.
- Checked: 14 talent tests (fixture trees plus the real pipeline: lock at the gates, a talented match replays to the same hash, the hello message), all 135 core and net tests, the validator fixtures and data validation.

## 2026-10-01 — M2-02 crowd control by category
- `game/test/core/test_crowd_control.gd` (12 tests) covers each category from DESIGN.md:
  - stun, incapacitate and disorient take control; silence blocks spells only; root stops movement only; disarm blocks weapon attacks and auto attack only;
  - break rules: incapacitate on any damage, disorient past 10% of max health (added up over hits), roots by their data, the rest never;
  - Break Free removes every category; knockback pushes the full distance every time with no diminishing returns;
  - every category steps 100%, 50%, 25%, immune, keeps its own count, and resets 18 s after its last effect ends; nothing lasts past 8 s.
- A data test fails if a crowd-control aura's break rule disagrees with its category.
- Checked: all 12 pass, and breaking the disarm and incapacitate rules in the code makes them fail.

## 2026-10-01 — M2-01 combat rules matrix; spellsever lock 4 s
- `docs/combat_rules.md` lists all 42 combat and arena rules from DESIGN.md with the test that proves each. `tests/test_combat_rules_doc.py` fails if a rule names no test (or no backlog item for later work), or names a test that does not exist.
- New tests for the eight rules that had none:
  - only the strongest slow applies;
  - power bonus, damage-taken modifiers and the PvP modifier each scale damage;
  - Break Free waits 90 s;
  - an offensive dispel strips one magic buff and leaves debuffs and non-magic buffs;
  - health comes from the role template (60,000; tanks 72,000);
  - data checks: interrupt locks 3 to 4 s, interrupt cooldowns 15 to 24 s (a healer's may be longer), all healing at 40 m and most ranged abilities at 40 m.
- Spellsever locked a school for 5 s, past the design's 3 to 4 s. It now locks for 4 s; its test checks the lock is still on one tick before 4 s and off at 4 s.
- Checked: the combat and kit suites (40 Godot tests), the Python rule tests and data validation pass.

## 2026-10-01 — M1-32: deeper starting rooms, action bars hide at match end
- Gallows Courtyard starting rooms are 8 m deep instead of 4.5 m, so the camera no longer hits the back wall during preparation. Spawns sit 3 m behind the gate.
- The action bar, cast bar and loss-of-control display hide when the match ends (`hide_on_match_end` in the HUD layout).
- Checked: map and HUD tests; 42 bot matches all ended in a kill (median 93 s).

## 2026-10-01 — M1 gate passed; codex; slash v4; melee hits land on the strike
- The human passed the M1 gate.
- New "Arena PvP Codex" page, generated from data (`tools/codex/build_codex.py`): every ability with icons and computed numbers, and the talent trees (placeholders until M2).
  - Six descriptions behind the M1-13 balance pass were corrected, and the validator now rejects such drift.
- Slash: four different readings were sent, and the human picked D. It is now impact_slash and both greatsword hits:
  - a whoosh swelling into the contact, a crisp cut, a wet tear, and a bright steel ring sliding down in pitch;
  - new layer types `whoosh` and gliding, scraping resonances.
- Melee hits now sound and show when the blade lands. Before, they played when the swing started, almost half a second early. The animator reports the strike of the next swing, and sounds start before it by their own lead-in.
- `tools/match_video.sh`: a reference video of a recorded match, drawn with Godot's Movie Maker at 30 fps with game audio.

## 2026-10-01 — Review pass 3 and the M1 gate
- Balance, 2v2 (1,000 matches), after fixing the bot targeting bug the review found:
  - Arcanist 54%, Oracle 52%, Warblade 52%.
  - Main compositions 48-52 head to head; every match ends by a kill; median 1:30.
- The lineup passes the 30 m silhouette and grayscale tests. The arena was the weakest visual and got its dressing (F-05).
- 20-player server: 2.0 ms average per tick. 4-player server: 0.30 ms. The client frame-time baseline is recorded on the software renderer.
- M1 gate: a full 2v2 plays from menu to scoreboard with a human-controlled unit and bots, over a lossy network, without desync, and replays exactly. Only the 60 fps check is open; it needs a GPU machine.
- Report: `docs/reports/review_03/review_03.md`.

## 2026-09-30 — F-05: Gallows Courtyard dressing; bot targeting fix
- The arena now reads as a walled fortress in a town:
  - a skyline of keep, towers, a bell tower and town houses;
  - gatehouses that hide the raised portcullises, ramparts and a wall walk, and corner turrets;
  - props, long team banners, drains, and worn, stained and grimy tiles with puddles;
  - animated brazier fire with a flickering light.
- 23 new kit pieces, all built by Blender scripts and placed from map data. Gameplay colliders are unchanged (fingerprint test).
- The player view went from 87 to 182 draw calls and from 347k to 528k primitives.
- Review pass 3 found that bot target choice depended on unit id order: how a team was listed flipped one matchup from 12% to 92%.
  - Ties now go to the lighter armor, then the nearer enemy.
  - Listing order no longer changes outcomes (7 vs 5 and 10 vs 7 wins of 24).
  - 3 regression tests; the 2v2 balance sims are being rerun.

## 2026-09-30 — M1-30: network test
- New full-mode check: a 2v2 arena of bots at 150 ms latency, 30 ms jitter and 2% loss must reach a kill with:
  - no stuck casts (a cast shown more than 0.25 s past its end);
  - every client's view of the ended match equal to the server's unit health at the same tick;
  - own-movement corrections within limits;
  - an exact replay.
- First run: 4.8 minutes of match time, 434 casts, 0 stuck; all four clients agree with the server; corrections at most 0.125 m.
- 2 tests prove the stuck-cast detector and the end-of-match record.

## 2026-09-30 — M1-29: replay test
- Every match records an input log: every applied input and every world edit (join, leave, preparation hold, respawn), with its tick. The server writes it on finish; Play vs bots always records.
- `Replay.run` rebuilds the match from the log. Every networked match in check_all, and the end-to-end match, now replays its log and must reach the server's final state hash.
- A 2v2 fought to a kill (5,513 ticks, 21,260 entries) replays in 1 s with the same hash.
- 4 GdUnit tests: exact replay, one changed input changes the hash, world edits, floats exact through the file.

## 2026-09-30 — M1-28: match flow
- Main menu:
  - Spec cards, then Play 2v2 vs bots, Practice, Settings (read-only) and Quit, styled with the HUD's fonts and named in `data/menus`.
  - Play starts a local match server and three bots and joins over the network.
- Match screens: loading, preparation countdown behind the gates, the fight with the HUD, a Victory/Defeat banner, then a scoreboard (damage, healing, kills, interrupts per unit and team) and back to the menu. An Escape menu and failure screens complete the set.
- Fixes found on the way:
  - The player's unit faced yaw 0 on joining.
  - The renderer skipped about 6% of ticks.
  - The local server asked Godot about processes it had already reaped.
- Checked:
  - `tools/match_flow_e2e.py` plays a full match through the real buttons and keyboard and mouse events, and checks the scoreboard against the server's totals.
  - 11 MatchFlow tests and 4 networked tests (server killed, leaving, a server that cannot start, port probe).
  - Screenshots at 1920×1080 and 1280×720 in `previews/match_flow/`.

## 2026-09-30 — Sound feedback, X-05
- The human preferred the processed versions of all four approved sounds, so every sound is now processed.
- Slash v3 (impact_slash and both greatsword hits), after human feedback that it still did not sound like a slash:
  - A contact tick, then a bright draw that sweeps downward and fades over about 0.2 s, a grainy scrape, a short edge ring and a fibrous tear.
  - Plate adds a clang; cloth adds a heavier tear.
  - A new `slash` chain brightens it; the spectrograms show the falling sweep.
- The mace and blunt hits are pitched 3-4 semitones lower (`impact_low` chain), after human feedback.
- The dagger hit got denser (`impact_tight`), which brought the impact category's loudness spread back under its limit.
- The default impact chain's body lift went from 3.5 to 4.0 dB.
- Each impact chain now has its own goal test; 490 audio tests pass, including weapon and armour identity.
- X-05 mesh quality: pymeshlab, pyfqmr and Taubin smoothing were measured on every character piece at equal triangle budgets. None kept: cleaner triangles, but they lost detail. Follow-up X-11.
- scikit-image added to the pinned requirements (it was used but not listed).

## 2026-09-30 — X-01: motion-capture run and idle
- New capture pipeline:
  - `tools/blender/mocap.py` reads CMU BVH files.
  - `build_capture.py` fits them to the standard skeleton as animation terms, so captured clips share the scripted pipeline. It uses a least-squares solve on our own pose code, finds cycles by autocorrelation, and applies seam correction and the shared phase convention.
  - Clips take a `capture` with bones, gains and a relative mode; their keys add on top.
- Run:
  - Legs, torso and hips come from CMU 09_01, with the stride scaled 1.7× for the heroic look.
  - Foot slide dropped to 27% of the running speed, from 46% for the scripted run, with more weight and push-off in the sheets.
  - Arms stay scripted: the captured free arm could not clear heavy plate in 3 attempts (X-10).
- Idle: the upper-body movement from CMU 82_08 (breathing, shoulder shifts, looking around) over the scripted posture. The first version also took the hips and legs; its feet slid 1.8 cm/s, which X-02's flat-floor tests caught.
- Strafes, backpedal and jump stay scripted; the database has no sideways or backward running at game speed, and captured jumps start with a crouch.
- Checked:
  - Clipping gate passes on Warblade, Arcanist and Oracle.
  - Side-by-side sheets reviewed (`compare_capture.py`); libraries rebuilt.
  - 6 new Python tests and 5 validator fixtures.
- CI: check_all reports failures as GitHub annotations, because job logs are not reachable from the workspace. The first CI runs found a native crash in the Python tests on the runner (being traced).

## 2026-09-30 — X-02, X-03, X-04, X-06: improvements from available tools
- X-03 icons and fonts:
  - 47 game-icons.net glyphs (CC BY 3.0: Lorc, Delapouite, Skoll) cover all 67 abilities and auras, drawn as engraved glyphs in an iron frame over the school gradient.
  - A glow shows when a cooldown ends and while an execute is usable.
  - Cinzel and Fira Sans (OFL) replace the default font.
  - The validator checks icon images and fonts; 8 new Godot tests.
- X-04 sound processing:
  - Every generated sound goes through a data-driven studio chain: EQ, saturation, transient shaping, compression, a clean limiter, chorus or phaser, plate reverb and pitch variation.
  - Build checks catch clipping and cut-off tails.
  - Arena reverb is set per map, and the world ducks about 5 dB under CC warnings.
  - Impacts gained low-mid body (24% → 28%) with less harshness (15% → 12%); the CC warning's lead over the loudest other sound grew from 4.5 to 5.8 LU.
  - The three human-approved sounds stay exactly as approved (decoded samples checked identical); their processed versions wait for the listening pass.
  - Greatsword hits use the light chain, so they keep sounding like a slash rather than a blunt hit.
- X-02 runtime character polish (narrowed; spring bones moved to X-07):
  - Head, neck and chest turn toward the target, limited and eased, and switched off in crowd control, death and big swings.
  - Feet stand on uneven floors (TwoBoneIK3D) and stay planted while turning in place; level floors are an exact no-op.
  - Cost is 27-56 µs per character; 13 tests.
- X-06 CI:
  - `check` runs the full tools/check_all on every push.
  - `nightly` runs 1,000 matches per bracket and the 20-player profile on separate GitHub runners (`tools/sim/nightly.py`).
  - Pip packages are pinned in `tools/env/requirements.txt`.
- Checked:
  - Full tools/check_all passed locally.
  - The workers reviewed icon sheets, HUD screenshots at 1280×720 to 2560×1440, spectrogram before/after sheets and rig screenshots (`previews/icons`, `previews/hud`, `previews/audio/x04`, `previews/rig_modifiers`).

## 2026-09-30 — Review pass 2 and M1-22 art gate
- Balance, 1,000 simulated matches per bracket (`docs/reports/review_02/`):
  - Every match in all three brackets now ends by a kill, and team sides are even.
  - 2v2 (the M1 bracket): all specs within 40-60% (Arcanist 48%, Oracle 59%, Warblade 54%); the two main compositions are 47-53 head to head, with a median of 3:11.
  - 1v1 and 3v3 are M2 brackets, so their imbalances are queued as F-08: the Oracle wins 2% of duels against the Warblade, and two-healer teams dominate 3v3.
- Bugs found by the simulations:
  - 98% of 1v1 mirrors timed out because two low Warblades circled a pillar, each hiding from the other. Bots now break line of sight only when it helps, and never for more than 8 s.
  - The Oracle bot never attacked a full-health target.
  - A 1v1 time-limit change was reverted after finding DESIGN.md's mode table.
- Performance, 20 bots:
  - The networked server averaged 1.8 ms per tick, with a 9.3 ms 95th percentile on 2 cores shared by 21 processes.
  - A 20-unit match in one process costs 7 ms per tick with every bot brain deciding each tick (F-14).
  - Memory: about 125 MB for the server, 2.8 GB across all processes.
- Art gate (M1-22):
  - Lineup, silhouette and grayscale tests pass.
  - The human chose to stay fully scripted and iterate.
  - The iteration:
    - Right fists close around the grip (the thumb had been modelled on the back of the hand), with per-build grip data checked against the body.
    - Gauntlets and gloves are built on 2.5-3 mm grids.
    - Faces are hidden by design: the Arcanist's deep hood with glowing frost eyes, the Oracle's gold mask and coif.
    - Robe folds; the Oracle's wine stole, gold hem band, bordered panel and sun-and-rays emblem.
    - Painted height gradient on character materials.
    - A slimmer idle for the lean build.
    - Robe skirts no longer part at the front (F-07).
    - The Warblade's attacks use both hands on the greatsword (two-bone reach baked into `_two_handed` clips).
- Tools:
  - `build_character.py --no-bake` renders geometry sheets, close-ups and the pose test in minutes.
  - `render_lineup.py` runs the silhouette and grayscale tests.
  - `tools/sim/analyze_batch.py` summarises balance runs.
- Checked:
  - Asset validation (21 assets, 0 non-manifold edges; Warblade 24,794, Arcanist 17,898 and Oracle 22,598 triangles, two LODs each).
  - Clipping gate clean for all three characters.
  - All tests pass.
  - Lineup screenshot reviewed.

## 2026-09-30 — M1-27 Basic HUD
- The HUD is data: `data/hud_layouts/default.json` (new schema `hud_layout.schema.json`) places two action bars, a player cast bar, player, target, focus, party (4) and arena (3) frames, the match timer, the loss-of-control alert and combat text by anchor and offset on a 1920×1080 base, with styles, CC labels and glyphs, error messages, icon glyph rules and the action bar fill rules. The settings profile gains `interface` (layout id, `ui_scale`, `min_text_px` 11, combat text on/off); the default keybinds gain bar 2 slots 7-12 (Shift+7 to Shift+=). `Data` loads `hud_layouts`.
- `game/ui/`: `Hud` (CanvasLayer; builds elements from the layout, reads views, events and the controller, lays out with the resolution, `ui_scale` and the text-size floor), `HudLogic` (bar assignment, button states, aura order, active CC; no drawing, so tests check it directly), `HudStyle` (colors, outlined text, iron-framed panels, bars, square cooldown sweeps, placeholder icons: school gradient, glyph from 20 shapes, initials), `ActionBar`, `UnitFrame` (portrait turning into a big CC icon, class-colored health with absorbs, resource, cast bar, auras, arena Break Free box and DR tracker), `CastBar` (interruptible, channel and uninterruptible styles, "Interrupted" held), `MatchTimer`, `LossOfControlAlert`, `CombatText` (projected through the camera, rising, crits popping, stepped apart when units are close, capped at 40).
- `PlayerController`: `bar_actions` (key -> ability, filled by the HUD), `press_ability()` for clicks, one press sent per tick in order, `set_focus` (Shift+F) sets `focus_id`, `set_target()` for frame clicks, an `ability_pressed` signal (button flash). The server's spell queue window does the queuing.
- Practice scene: creates the HUD and feeds it the renderer's view and the tick's events (`--no-hud` hides it). Clicks play `ui_click` through `AudioDirector.play_ui`.
- Validator: bar actions bound in every keybind profile, per-spec assignments inside the kit, complete kits fit the bars, every used CC category has a label and glyph, glyph patterns compile, settings name an existing layout (3 new fixtures).
- Fixed from the screenshots: physical icons nearly black (now worn bronze with per-symbol shading), all frost abilities sharing one crystal glyph (ordered glyph rules), combat text of nearby units overlapping, white health text unreadable on the Oracle's cream bar (fills darkened to a luminance cap), the alert covering the character's head, key labels on empty slots, "1:13" spilling out of 38 px boxes (now "2m"); frames colliding at 1280×720 were found by the layout test and moved.
- Checked: data validation and 266 python tests pass; 19 new Godot tests in `test/ui/test_hud.gd` (layout; bar slots and key labels for all three specs; cooldown and GCD sweeps from the view; range, resource, CC and execute states; target and focus follow the targeting and frame clicks; aura order and drawn sizes; arena Break Free and interrupts; combat text spawn, crit size, filtering, cap, expiry, projection and overlap; loss-of-control for stun, stun over root, fear, a real simulated stun, and nothing for others; timer and dampening against `ArenaMatch`; key, click and scripted presses reaching the input and the simulation; no overlaps or off-screen elements at 1280×720, 1920×1080 and 2560×1440; the practice scene feeds the HUD); all 192 Godot tests pass. `tools/godot_smoke.sh` could not bind port 24600 while another job's 20-bot network match held it (not related to this change). Screenshots reviewed: `previews/hud/hud_1280x720.png`, `hud_1920x1080.png`, `hud_2560x1440.png`, `hud_combat_text_1920x1080.png`.

## 2026-09-30 — M1-25 Spell effects v1
- Effects are data: `data/effects/<ability id>.json` (44 entries, new schema `effect.schema.json`) names a generic style for each stage an ability has: cast glow (orbs at the hands and a turning ring at the feet while the cast bar or channel runs), projectile, impact (burst, shards, rays, spark, hail, ring, flash; on the target, on every hit, or on the caster), ground circle (nova or zone, radius from the ability), melee swing trail, charge dust or blink, and the visual of each aura it applies (shield, ice block, stun, disorient, root, silence, heal-over-time motes, drips, slowing mist, empower glow, speed). School colors, relation outlines and the budget are `data/effect_palettes/default.json` (new schema): the DESIGN.md table for all 10 schools, spread in hue, plus pale steel for physical.
- `game/client/effects/`: `EffectsData` (lookups), `EffectLibrary` (builders from fresnel shells, orbs, rings, crescents, crystals, ground circles and small GPU particle emitters; meshes and materials cached and shared), `Vfx` (one live effect: anchors, scaling, shader progress, spinners, fade, stop and linger), `EffectsDirector` (views and events to effects, following unit anchors and hand bones, flying projectiles, budget with priority eviction, freeing finished effects), four shaders in `effects/shaders/` (fresnel glow, ice, ground circle with relation outline, swing arc). `WorldRenderer` creates the director and forwards views, events and frames, so bots' and the player's abilities all show effects in the practice scene.
- Validator: coverage of every finished kit's abilities, stages that fit the ability, one visual per applied aura, CC auras in CC styles, palette covers every school (6 new fixtures, `tests/test_validate_effects.py`).
- Review tools: `scenes/tests/effects_view.tscn` (`--mode schools` one cell per school, `--no-effects`, `--layout`; `--mode grid --spec <id>` every ability of a kit frozen mid-effect, via `EffectsDirector.preview_ability`) and `tools/effects_hues.py` (mean hue, saturation and value of each school's effect pixels, pairwise check).
- Fixed from the screenshots: labels hidden under the next row; the first palette measured fire/holy 17 degrees apart, time/frost 21 and nature/fel 24 (retuned hues, tinted cores, lower glow intensity); a 12 m enemy heal zone painted the whole courtyard yellow (fill down to 13%, the outline carries the area); cast glows unreadable from the game camera (bigger orbs and a ring at the feet); stun and root markers too thin (chunkier rings, bigger crystals, taller spikes).
- Checked: data validation and python tests pass; 14 new Godot tests in `test/client/test_effects.gd` (coverage; every ability plays all its stages and leaves nothing behind; cast glow spawned and freed; the view ends a glow; projectile caster to target then impact; enemy ground red outline, ally neutral, radius and centre from data; zone on the target; aura visuals from events and from the view; CC within the aura cap; swings alternate sides and spark; charge dust along the path; budget bounds; 30 s practice fight within budget with no leaked nodes and everything ending when the units leave); full Godot suite 173 tests pass. School check: all 45 pairs pass (`previews/effects/school_hues.json`; closest fire/holy 31 degrees, nature/fel 31, fire/blood 18 but 0.21 apart in value). Screenshots reviewed: `previews/effects/schools.png`, `grid_warblade_carnage.png`, `grid_arcanist_rime.png`, `grid_oracle_grace.png`, `practice_fight_1.png`, `practice_fight_2.png`. Open (F-12): effect opacity and camera-shake settings, distinct shapes for major buffs, pale physical CC markers, spell lights and decals, GPU frame time.

## 2026-09-30 — M1-26 Sound v1
- Sounds are data: 80 recipes in `data/sounds/<id>.json` (new schema `sound.schema.json`), each a list of layers rendered by `tools/audio/layers.py` (noise bands and sweeps, tones, formant saws for voices and choirs, resonant noise for metal, ice and wood, crackle, sub drops, envelopes, repeats) or a builtin Python recipe (the five approved M0-16 sounds, rebuilt sample-identical). `tools/audio/synth.py --data` builds what changed (recipe hash in `sfx/manifest.json`) into 121 Ogg files and 25 randomizers and keeps files whose samples did not change, so rebuilds do not churn binaries. Every ability of the three kits has its sounds: frost and holy cast starts and loops, a hailstorm channel loop, a release and an impact per ability, weapon swings and hits for greatsword (heavy slash), mace (blunt crack) and staff (wooden thud) on plate and on cloth, plate and cloth footsteps and landings, interface click, target tick and error, the CC warning and an incoming-CC warning.
- `data/sound_map/default.json` (new schema) says which sound plays when: per ability cast start, cast loop, release and impact (`@weapon_swing` / `@weapon_hit` from the caster's weapon and the target's armor), periodic aura ticks, weapons (moved from `tuning.json`), footsteps, buses, attenuation profiles, category priorities and copy caps, the 64-voice cap and the never-drop rule. `tools/audio/sound_data.py` (called by the validator) requires an entry for every ability, cast start and loop for casts and channels, a recipe for every sound named, weapon and armor coverage, and reads two rules from the recipe text: impacts hold no tone above 200 Hz, no layer is cut off while still loud (6 new fixtures).
- `game/client/audio/`: `SoundBank` (data, streams, resolution) and `AudioDirector` (events and views to voices: 3D world sounds on the self, allies or enemies bus by who caused them, 2D interface and warnings, cast loops following their caster and fading out, footsteps every stride of ground travel, landings, the CC warning once per application on the local player, voice pool with priority stealing and per-sound caps, voices ending by game time). `WorldRenderer` creates one and forwards views, events and frames (next to the effects hook). Bus layout: Interface raised to 0 dB so no effect can reach the listener louder than the warning; hard limiter on Master.
- Fixed from spectrograms (`tools/audio/review.py`, sheets in `previews/audio/`): layers still ringing at the recipe's end stopped dead (vertical edges at 0.6-1.1 s in frost_cast_start, rime_bolt_release, rime_fan_release, frost_effigy_impact; now a fade, longer durations and the validator rule); crackle grains smeared into broadband clicks because the noise was filtered before gating (now band-limited after); hail ticks in the hailstorm loop spiked above 10 kHz (click score 82 -> 4.5); Dread Roar's envelope was cut at 1.1 s; the staff hit was 93% sub and did not read as wood (now a short mid-band knock); the greatsword's slash sweep was buried under the thud; the CC warning came out at -0.8 dBFS, above its target (data recipes now correct the encoded peak strictly).
- What the spectrograms show: greatsword hits a bright band sweeping from about 10 kHz down to 3 kHz in the first 150 ms; mace hits a broadband crack collapsing into energy below 1 kHz, the longest low tail; staff hits a short 250 Hz-2 kHz burst gone in about 0.1 s; plate and cloth differ most clearly for the mace (5% of the energy in 700 Hz-1.6 kHz on plate, 1% on cloth); for the greatsword and staff the armor difference is subtler (low-end share and decay; the test only requires one feature to separate by 3 spreads), so the plate clang may be hard to hear on those; the CC warning is a dense harmonic stack in two hits, the loudest file by 6 LU integrated. Still visible: end fades 27-30 dB below the peak over 90-150 ms look like edges on the -120 dB colour scale (break_free, shield_breaker_impact, rime_fan_release; not expected to be audible); faint horizontal lines about 90 dB down after sharp cracks (winters_lash_release, frost_step, hail_impact), probably the Vorbis encoder's floor.
- For the human to spot-check by ear (practice fight with sound: `godot --path game res://scenes/game/practice.tscn -- --player-bot`; files in `game/assets/audio/sfx`): (1) the six weapon hits `hit_{greatsword,mace,staff}_{plate,cloth}_0*`: slash, crack and wood, whether the staff is too light or clicky, and whether plate and cloth are told apart for the greatsword and staff; (2) `cc_warning` and `cc_incoming`: urgent and distinct, not grating; they are the only tonal "alarm" sounds; (3) the formant-voice sounds `holy_cast_loop`, `heal_chorus`, `seraphic_surge`, `dread_roar`, `psalm_of_dread`: likely to sound synthetic or buzzy (a roar from a filtered sawtooth may read as a robot rather than a beast); (4) heals `heal_quick`, `heal_chorus`, `bloody_resolve`: weighty enough after the M0-16 feedback; (5) footsteps in the fight: cadence, plate vs cloth, level against combat; (6) `interrupt_impact` reads as "your cast broke"; (7) the mix: cast loops (-6 and -8 dBFS peak) against impacts, allies' bus at -3 dB; (8) headphones at high volume on `winters_lash_release` and `hail_impact` for encoder artifacts.
- Checked: data validation passes; python tests 263 pass (`tests/test_audio.py` 230 checks, was 15: every file's peak, integrated and loudest-400 ms loudness under the CC warning's, impacts 0-9% tonal against a 20% limit, heals 67-100% below 250 Hz against 40%, smooth sounds do not click, loops join, weapon hits differ by weapon on every variation and by armor, plate footsteps heavier, files match their recipes, rebuilds give identical samples; 6 validator fixtures). Godot: 21 new tests in `test/audio` (data coverage and resolution, nothing louder than the warning after bus gains; events to sound ids, buses and 3D/2D; loops start, follow and stop; CC warning once per application, never for others or roots, off by setting; incoming warning; footstep cadence at full and half speed; landing; culling; voice cap in a 20-unit brawl with enemy stuns never dropped; 30 s practice 3v3 within the cap with the CC warning count matching applications counted from the view; a 6-voice cap forcing steals); the full suite of 173 passes; `check_all --quick` passes. Open (F-11): the listening pass, aura loops, signature layers for four Warblade strikes, occlusion, audio settings, HUD clicks, the engine's play/stop cost in this build (KNOWN_ISSUES.md).

## 2026-09-30 — M1-24 Character animation hookup
- `game/client/character_animator.gd`: one AnimationTree per character, built in code on the rig's AnimationPlayer (hold variants included). Locomotion is a 2D blend space on the velocity relative to facing (idle/combat-idle blend at the centre, run, backpedal, strafes around it), eased so there are no pops, with moving clips played at ground speed (0.6-1.4x) and a jump one-shot on take-off. Actions (cast start then loop while the view's cast bar runs, the school's release on success, channel, attack 1-2-3 cycle for melee abilities and auto-attacks, ranged shot, release for instant spells, throttled hit reaction) play through bone filters: spine and above while moving, full body when standing. Stun and incapacitate play stunned, fear plays the feared run, over everything, and fade back to locomotion; death holds; winners play victory.
- Everything that is a choice is data: `data/anim_states/humanoid.json` (new folder, schema `anim_states.schema.json`) holds fade times, the blend-space points, speed limits, the "in combat" rule, the body split, action priorities, the ordered ability rules (no per-class code), crowd-control clips. `tools/validate_data.py` checks clips exist in the animation set, bones are standard and split cleanly, the last rule catches every ability, overrides name real abilities (3 new fixtures).
- `WorldRenderer` creates an animator per character and feeds it the unit's view entry and the combat events (`push_events`); `draw(alpha, delta)` advances animation, so paused scenes hold their pose. `LocalMatch` keeps its events for `take_events()`. Practice scene options for screenshots: `--player-bot`, `--follow <spec>`, `--cam-yaw`, `--cam-pitch`, `--cam-zoom`.
- Checked: data validation and python tests pass (18); 15 new animator tests in `test/client/test_character_animator.gd` (blend space follows forward, backward and sideways velocity with speed scaling; combat idle; cast start -> loop -> frost and holy releases; interrupt and channel; instant spells; melee cycle and ranged shot; legs keep running under a swing; hit throttle; stun with recovery; fear; death holds; victory; jump; every ability resolves; every clip reachable) and 2 new practice tests (15 s of the practice scene with no errors, every unit's animator changes state, a cast and running seen; renderer drives an animator from views and events); full Godot suite 138 tests pass. Screenshots reviewed: `previews/game/anim_cast.png` (Arcanist in its cast loop, hand toward the target, staff upright), `anim_melee.png` (Warblade and the enemy Oracle mid-swing, weapons in hand). Open (F-10): the cast loop reads small from the game camera, gait cycles differ in length, auto-attacks need no facing, the jump has no landing, a leak at exit from M1-23's match code.

## 2026-09-30 — M1-23 Camera, controls and targeting UI
- Keybinds: `game/client/keybinds.gd` registers every action of a keybind profile in Godot's InputMap (keys and mouse buttons 1 to 5 and the wheel, with Shift, Ctrl and Alt), replacing older events, and gives readable labels for the action bars. The default profile gains `camera_orbit` (left button), `camera_steer` (right button), wheel zoom and `clear_target` (Escape); the schema now checks key names.
- Controls: `PlayerController` turns keys and mouse into the bots' input dictionary, so the server path is unchanged: W/S, A/D turn (strafe with the right button), Q/E strafe, Space, both buttons to run; right drag steers, left drag orbits the camera and leaves it there. Mouse sensitivity, invert, turn speed, camera and targeting numbers are a settings profile (`data/settings/default.json`, new schema, loaded by `Data`).
- Camera: `ThirdPersonCamera` orbits a shoulder-height pivot, zooms 2 to 25 m with easing, clamps pitch, and pulls in front of pillars, walls and the floor. `ArenaRay` casts rays and spheres against the server's map colliders in 3D, so tests need no physics frame.
- Targeting: `Targeting` picks the unit under the cursor (capsule per unit, hidden behind walls), keeps the target on an empty click, and orders Tab by angle from the screen centre in 10 degree bands, then by distance, within 40 m and in sight, falling back to the nearest enemy like the server. Inputs carry a `clear_target` flag so Escape or selecting an ally also clears the server's target and stops auto-attack (protocol version 4).
- Practice scene `scenes/game/practice.tscn`: `LocalMatch` runs the server's MatchRunner in-process with bots, the player's input entering the same seeded turn order; `WorldRenderer` draws the kit arena's units from the world view (interpolated between ticks, idle/run/backpedal/strafe/death clips, red or green target ring), so M1-28 can swap in the network client. Command-line options for spec, teams, scripted input (`ScriptedInput`), fast-forward and pause make screenshots and headless runs repeatable.
- Checked: data validation and python tests pass; 33 new Godot tests in `test/client` pass (keybinds 4, controls 10, camera 7, targeting 8, practice and renderer 4), including 10 simulated seconds of the practice scene with scripted input and no errors; the full suite passes except `test_animations` weapon grip, which belongs to the two-handed grip work in progress on the Warblade (F-06), not this change; a 30 s network bot match passes on protocol 4. Screenshots reviewed: `previews/game/practice_target.png`, `practice_zoomed.png` (camera behind the Warblade, which faces away from it; enemy Oracle ringed in red; no camera inside geometry). Open: the ring reads small beyond about 15 m, Tab has no memory of recently cycled enemies (F-09).

## 2026-09-29 — M1-21 Animation set v1
- 22 clips authored as key poses in `data/animations/humanoid.json` (idle, combat idle, run, strafes, backpedal, jump, cast start, loop and release with frost and holy variants, channel, three melee attacks, ranged shot, hit, stunned, feared run, death, victory), in joint terms (bend, swing, raise, curl...) rather than bone axes. `tools/blender/animation.py` converts them with axes measured on the skeleton and checked on every build, fills frames with a smooth non-overshooting curve plus per-key eases, delays extremities for follow-through, and shrugs the clavicles as the arms lift.
- `tools/blender/build_animations.py` bakes one library per body build (`game/assets/animations/anims_heavy.glb`, `anims_lean.glb`, 44 clips each including the upright-staff variants) and reviews it on every finished character: pose sheets in `previews/animations/` and a clipping report.
- Clipping check: pieces of each character are welded back into closed meshes; a vertex more than 1.5 cm inside another body part or the weapon fails. Idle, combat idle, run and all cast clips are clean on all three characters, after widening the arms and knees in those poses, an earlier clavicle shrug, and moving the staff's grip lower.
- Weapons: grip and hold directions are data in rest-pose terms, the same in Blender and in the game; staffs use an upright hold whose wrist rule keeps them within 20 degrees of vertical in every clip but death.
- Game: `CharacterRig` loads the build's library onto each character's own skeleton with loop flags from data, picks hold variants and attaches the weapon; `map_view` takes `--anim` and `--anim-time`; `Data` loads the animations folder.
- Bugs found on the way: the export used Blender's 24 fps, so every clip played 25% slow (the asset validator and a Godot test now check lengths); preview renders all showed one pose because the baked tracks overrode it; Godot's importer renames `cast_loop` to `cast` (mapped back by name).
- Checked: data and asset validation, 6 animation tests (lengths, track retargeting on all characters, loop flags, grips, bones driven, staff upright while running) and 3 character tests pass; pose sheets reviewed; clipping reports `anims_heavy_clipping.json`, `anims_lean_clipping.json`. Open: melee clips still clip in overhead frames and two-handed weapons swing one-handed (F-06); robe skirts part at the front in the run (F-07).

## 2026-09-29 — M1-18, M1-19, M1-20 Warblade, Arcanist and Oracle
- Three armored characters built from asset specs by `tools/blender/build_character.py` on the signed-distance-field bodies: the Warblade in horned, spiked plate with brass trim (24,896 triangles), the Arcanist in a hooded, torn-hem robe with frost crystals (16,300), the Oracle in white and gold vestments with a crown and rayed halo (17,100). Armor pieces are signed-distance shells over the body, rigid on one bone or following the body's skin weights (cloth); one mesh and one 2048 px painted texture set per character.
- Weapons (`build_weapon.py`): greatsword (1.78 m), frost staff (2.4 m, glowing crystal head), flanged mace (0.95 m), each with its origin at the grip.
- Build fixes: marching-cubes samples landing exactly on the surface and tiny separate specks left holes after export; edge collapse under 2 mm pinched thin rims; the staff's crystal cones overlapped face to face; skin weights slightly above 1. All four assets now have 0 non-manifold edges.
- The texture bake shrank each hidden face into its own UV island, which stopped Godot's importer from simplifying the cloth characters past one level of detail; hidden patches now shrink as a unit and every character gets two lower LODs (about 50% and 25%).
- Checked: asset validation passes for all 21 assets; character tests cover all three characters and weapons (skeleton, budgets, 2 LODs, grip at the origin; weapon length bound widened to 0.5-2.6 m for the staff, see DECISIONS.md); contact sheets and pose tests reviewed.

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
