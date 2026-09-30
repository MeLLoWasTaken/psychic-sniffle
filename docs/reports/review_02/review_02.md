# Review pass 2 (M1-11 to M1-27), 2026-09-30

## Results against the review checklist (docs/DESIGN.md, "Review pass")

| Check | Result |
| --- | --- |
| Balance, 1,000 bot matches per bracket | Every match in 1v1, 2v2 and 3v3 ends by a kill; team sides even (49-53%). 2v2, the M1 bracket: Arcanist 48%, Oracle 59%, Warblade 54% (target 40-60%); the two main compositions 47-53 head to head, median 3:11. 1v1 (M2): Arcanist beats Warblade 66%, Oracle loses almost every duel. 3v3 (M2): Oracle 61% because two-healer teams win 74-78%. Both queued as F-08. Reports: `sim_1v1.json`, `sim_2v2.json`, `sim_3v3.json`. |
| Lineup against the art bible | Passes the silhouette and grayscale tests at 30 m. Close-up quality fell short (faces, hands, plain cloth); the human chose to stay fully scripted and iterate. After iteration: fists and gloves, hidden faces (hood with glowing eyes, gold mask, closed helm), cloth folds and layered trims, painted height gradient, robe skirts that stay closed. `previews/lineup/`. |
| Arena screenshots | Unchanged since M1-15; the practice scene now shows the arena from the player camera (`previews/game/`). Dressing polish remains in F-05. |
| Performance, 20 players | Networked server: tick average 1.8 ms, 95th percentile 9.3 ms, max 33 ms, 57.9 snapshots per second, on a 2-core workspace running 21 Godot processes (review 1: 0.24 ms average, on a larger machine). One-process 20-unit match: 7 ms per tick including every bot brain (F-14). Memory: server about 125 MB, all 21 processes 2.8 GB. GPU frame rate still not measurable here (F-02). |

## Problems found and fixed

- 98% of 1v1 mirrors timed out: two low bots hid from each other behind a pillar for the whole match. Bots now break line of sight only from threats it helps against, only with a healer alive, and for at most 8 s.
- The Oracle bot never attacked a full-health target.
- A two-handed weapon was swung with one hand; the left hand now grips the handle in the attacks.
- The animation export ran at 24 fps (every clip 25% slow); preview renders showed one pose.

## Backlog changes

- M1-22 done; M1-23 to M1-27 done (camera and targeting, animation hookup, effects, sound, HUD) through background agents.
- New or updated follow-ups: F-06 (two-handed guard, melee clip clean-up, stronger releases), F-08 (1v1 and 3v3 balance), F-10 to F-13 (polish found in M1-24 to M1-27), F-14 (bot brain cost at battleground size).
- Next: M1-28 match flow, M1-29 replay test, M1-30 network test, M1-31 performance baseline and M1 gate.

## Needs the human

1. Listen to the new sounds (CHANGELOG, M1-26, lists what to check).
2. Try the controls on a real display (cursor capture while dragging is untested).
