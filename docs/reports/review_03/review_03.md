# Review pass 3 and M1 gate (X-01 to X-06, M1-28 to M1-31, F-05), 2026-10-01

## Results against the review checklist (docs/DESIGN.md, "Review pass")

| Check | Result |
| --- | --- |
| Balance, 1,000 bot matches, 2v2 (the M1 bracket) | **A bot bug was found first:** target ties went to the lowest unit id. With every enemy at full health, how a team was listed decided whether its plate or its cloth member took the focus; one matchup went from 12% to 92% on listing order alone. So the review 2 tables were unreliable, and the first review 3 run too. Fixed (ties go to lighter armor, then the nearer enemy), with regression tests and order checks. After the fix, every match ends by a kill, team sides are 48/52, and the median match is 1:30. Specs: Arcanist 54%, Oracle 52%, Warblade 52% (target 40-60%). The two main compositions (caster and healer vs melee and healer) are 48-52 head to head. Outside the target are compositions without a healer against those with one, as in review 2. Reports: `sim_2v2.json`, `summary_2v2.json`. 1v1 and 3v3 (M2 brackets) come from the nightly CI run on larger machines (F-08). |
| Lineup against the art bible | Passes the silhouette and grayscale tests at 30 m (`lineup/`). The run now uses motion capture; silhouette overlap Arcanist/Oracle 0.73-0.75 (two robed casters), Warblade 0.54-0.58 against both. |
| Arena screenshots | Before: plain and repetitive (empty floors, bare walls, flat sky, floor tiles on the wall tops). F-05 rebuilt the dressing: skyline, gatehouses, ramparts, turrets, props, banners, floor wear and brazier fire (`arena_*.png` before, `arena_after_*.png`). Players still stand out. |
| Performance, 20 players | Networked server: 2.0 ms average, 9.2 ms 95th percentile, 39 ms max per tick, on 2 cores shared by 21 Godot processes. That machine load holds snapshots at 57.6 per second, the same limit as review 2; the nightly CI job measures on larger machines. The 20-player match's input log replays to the same state hash. |
| Client frame time (M1-31) | Software renderer (llvmpipe, 2 shared cores): practice 2v2 at 1280x720 5.2 s and 1920x1080 8.7 s per frame (fill-bound), about 400 draw calls, 300k primitives, 115 MB static memory, 0.6 ms physics per frame (`client_frames_*.json`). F-05 raised the player view from 87 to 182 draw calls. Absolute fps needs a GPU machine (F-02). |
| Server tick, 4 players (M1-31) | 0.30 ms average, 0.45 ms 95th percentile over a full 2v2 at 150 ms latency; one 55 ms spike to find (M1-32). |

## M1 gate

M1's exit criterion: "A full 2v2 match plays start to finish with humans or bots, at 60 fps".

- **Passes:**
  - A full match, menu to scoreboard to menu, with a human-controlled unit (driven by keyboard and mouse events) and bots: `tools/match_flow_e2e.py` in check_all.
  - Bot matches over the network, including 150 ms latency, 30 ms jitter and 2% loss, without desync or stuck casts (M1-30).
  - Every match replays to the same state hash (M1-29).
- **Not measurable here:** 60 fps. Neither this workspace nor GitHub's runners have a GPU, so this stays pending (F-02, KNOWN_ISSUES).

**Result:** M1 is passed for everything this environment can check; the frame-rate check needs a GPU machine.

## Problems found and fixed

- Bot target choice depended on unit id order (above).
- Run and idle now use CMU motion capture where it measured better. The run's feet slide 27% of the running speed during contact, against 46% for the scripted run.
- The four sounds the human approved are now processed, by the human's choice; the slash was redesigned, and the mace pitched lower.

## Backlog changes

- **Done:** X-01 (capture run and idle), X-02 (look-at, foot grounding), X-03 (icons, fonts), X-04 (sound processing), X-05 (measured, no change kept), M1-28 (match flow), M1-29 (replay), M1-30 (network test), M1-31 (baseline and gate), F-05 (arena dressing).
- **New:** X-07 to X-11, M1-32, F-15.
- **Next, in order:**
  1. M1-32 match flow follow-ups (prep camera, end screen, tick spike).
  2. F-06 two-handed guard and melee clean-up.
  3. X-07 cloth spring bones.
  4. F-15 and X-08 to X-11 polish.
  5. Split M2 into items.

## Needs the human

1. **Accept the M1 gate?** It is passed except the 60 fps check, which needs a GPU machine.
2. **Name the game.** The menu says "Arena PvP" as a working title.
3. **Listen to the redesigned slash and the lower mace** (sent 2026-09-30).
