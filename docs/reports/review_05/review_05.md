# Review pass 5 and the M2 gate, 2026-10-02

Since review 4: M2-04, M2-04b, M2-07, M2-08, M2-09, M2-10 and M2-15, plus X-06, X-18, X-19 and X-20. Every M2 item is now done. This pass runs the DESIGN.md review list and checks the M2 gate.

## M2 gate (docs/DESIGN.md: "Every combat rule has passing tests; every action is rebindable; UI layouts save and load")

| Gate condition | Result |
| --- | --- |
| Every combat rule has passing tests | **Pass.** `docs/combat_rules.md` lists every rule of DESIGN.md's combat system and arena rules with its tests; `tests/test_combat_rules_doc.py` fails when a rule names no existing test. The last two open rules are now covered: the energy users' fixed 1.0 s global cooldown (a test unit; no energy class until M3) and the adjustable spell queue window (M2-13's settings test). |
| Every action is rebindable | **Pass.** A new test rebinds every action of the default profile in turn and checks that the input map answers to the new chord and not the old key (`test_every_action_can_be_rebound_and_the_new_key_works`). Other tests cover chords, mouse buttons 1-5 and the wheel, conflicts, target modes, export and import. |
| UI layouts save and load | **Pass.** `test_profiles_save_switch_follow_a_spec_and_travel_as_codes` saves a named layout, reloads it from disk, switches per spec, exports and imports it; a further test holds an edited layout at all five design resolutions. |

All checks pass on CI for every commit of this pass. The gate is ready for the human's sign-off. DESIGN.md's risk table also asks for human playtests from M2 on; the human cannot run the game locally, so bot results remain the only balance measure.

## Review checklist

| Check | Result |
| --- | --- |
| Balance, simulated bots | Nightly on CI: 3,000 matches per bracket, 24 talent builds per spec (3 named, 21 random), every arena in turn (the foundry included). 2v2: Arcanist 49%, Oracle 47%, Warblade 57%. 3v3: Arcanist 47%, Oracle 53%, Warblade 53%. 1v1: Arcanist 72%, Oracle 35%, Warblade 43% (outside 40-60%). Teams outside 40-60%: 2v2 two Warblades 65%, Oracle-Warblade 61%, two Oracles 22%; 3v3 Oracle-Oracle-Warblade 65%, three Oracles 24%, Arcanist-Arcanist-Warblade 39%, three Arcanists 32%. Matches end by a kill 97-98% of the time in 2v2 and 3v3. In 1v1, 229 of 500 Oracle mirrors reach the 12-minute limit. |
| Talent builds (M2-04) | Every spec has at least 3 viable builds in every bracket. No node is favoured by the top builds in 2v2 or 3v3. In 1v1, the Arcanist's top builds take Keen Focus 92% of the time, against 58% of all its builds: the first favoured node the new check has found. It goes with the Arcanist's duel strength (F-08). |
| Lineup against the art bible | Unchanged since review 3 (no character art changed). |
| Arena screenshots | `arenas_side_by_side.png` (one camera, match start). Three distinct places: a dusk courtyard in warm grey stone, a cold blue crypt, a sooty brick-and-iron foundry lit by fire. Players read in all three (`previews/m2_09/wading_1280.png`, `previews/m2_10/foundry_players_1280.png`). The first arena is now the plainest: smooth pillars and a gallows block that reads as a crate (new item F-19). |
| Performance, 20 players | CI (4 cores, 21 Godot processes): server tick 3.2 ms average, 23 ms 95th percentile, 44 ms max; bot clients 12.6-16.7 snapshots a second (they starve each other, X-19, F-14). Workspace (2 cores): server 4.0 ms average, peak memory 87 MB for the server and at most 85 MB per bot client. Peak memory is new in the profile. A rendered frame time needs a GPU machine (F-02). |

## Problems found and fixed during the pass

- Leaving a match could fail to tell the server (the client's disconnect waited for unacknowledged packets, then the host closed). Fixed, with a transport test.
- The client predicted twists one tick ahead of the server. Fixed.
- Sound builds are not reproducible across machines (X-21): generator changes wait for a rebuild the human listens to.
- An intermittent 3.2 m prediction correction in the lagged 2v2 check (X-22): the check now prints the details next time.

## Backlog changes

- Done: X-06 (CI), X-19 (profile on CI).
- New: F-19 (Gallows Courtyard kit to the newer kits' level).
- Next, in order: F-08 (1v1 balance with random builds: the Arcanist at 72%, Keen Focus favoured, Oracle mirrors timing out); F-19; X-22; F-18 (foundry follow-ups); then M3 split into items (the remaining classes in waves).
