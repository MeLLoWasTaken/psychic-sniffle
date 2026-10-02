# Review pass 4 (M2-01 to M2-16, M1-32 to M1-34, X-12 to X-15, F-16), 2026-10-01

About 22 backlog items since review 3, past the every-10-items mark. This pass checks the
DESIGN.md review list and re-orders the backlog.

## Results against the review checklist (docs/DESIGN.md, "Review pass")

| Check | Result |
| --- | --- |
| Balance, 1,000 bot matches per bracket | **1v1** (first nightly run on CI, every unit on a random talent build): Warblade 62%, Oracle 8%, Arcanist 78%; the Arcanist had one viable build and two of its nodes were in every top build. Duel tuning with bracket auras is under way (M2-07, see below). **2v2 and 3v3** did not finish: the first CI run hit the 4-hour job limit, and the sharded rerun stopped when the repository's Actions allowance ran out (X-20). Review 3's 2v2 numbers (all specs 52-54%) predate talents; a local 2v2 run with talents is the next balance task (M2-04, M2-08). |
| Lineup against the art bible | Unchanged since review 3 (no character art changed): `lineup/`, silhouette overlap Arcanist/Oracle 0.73-0.75, Warblade 0.54-0.58 against both. |
| Arena screenshots | Gallows Courtyard unchanged apart from its new twist (the gallows collapse at 5:00; `previews/m2_16/`). New: Flooded Crypt (`previews/m2_09/`): a roofless crypt under a cold moon, distinct from the gallows in palette, materials (moss, damp, wet streaks) and silhouettes (niched walls, ribbed columns, carved tombs). Players stand out against the lighter floor. The crypt reads emptier than the gallows; its four blockers sit in a large nave. |
| Performance, 20 players | Workspace, 2 cores, 21 Godot processes: server tick 4.2 ms average, 38 ms 95th percentile, 113 ms max; clients starve at 6-12 snapshots a second. At the review 3 commit, measured the same way today: 2.9 ms server, 17-25 snapshots a second, so bot clients are about twice as heavy now (X-19, F-14). The nightly profile now records client rates and checks the server budget (8 ms average). |

## Duel tuning (M2-07)

Duel balance is data: standing, visible auras per bracket by role or spec (`tuning.arena.bracket_auras`).
Local rounds (named builds; 60 then 150 duels):

| Round | Warblade | Oracle | Arcanist | Arcanist v Oracle | Arcanist v Warblade | Oracle v Warblade |
| --- | --- | --- | --- | --- | --- | --- |
| No auras (60) | 100% | 20% | 30% | 60% | 0% | 0% |
| 1 (60) | 30% | 65% | 55% | 70% | 40% | 100% |
| 2 (60) | 55% | 55% | 40% | 70% | 10% | 80% |
| 3 (60) | 85% | 0% | 65% | 100% | 30% | 0% |
| 4 (150) | 40% | 36% | 74% | 92% | 56% | 64% |
| 5 (150) | 28% | 76% | 46% | 12% | 80% | 64% |
| 6 (150) | 60% | 38% | 52% | 56% | 48% | 32% |
| 7-9 (150) | 38-48% | 50-60% | 52% | 56% | 48% | 56-76% |
| Check, new seed (210) | 31% | 63% | 56% | 49% | 63% | 74% |
| Check after +4% Warblade, new seed (300) | 56% | 44% | 50% | 50% | 50% | 38% |

Single duels are chaotic, so 10 per match-up swing widely; rounds of 150 are the minimum, and a tune fitted on one seed can miss on another (rounds 7-9 against the 210-duel check). The last check, 300 duels on a seed not used for tuning, has every spec within 40-60% and every match-up within 35-65%. A 1,000-duel confirmation is running on the workspace. (Match-ups: share of the first-named spec.) Oracle
mirrors always reach the 12-minute limit: dampening from 1:00 at 1% per 10 s reaches only 66% by then.

## Problems found

- The gallows collapse in the map data had never been implemented (now M2-16).
- The camera stayed on the player's corpse after death (F-16, fixed).
- pedalboard's native code crashed CI runners (X-14, replaced).
- The 20-player profile failed on client snapshot rates that measure machine load, not the game (X-19).
- The private repository's Actions allowance ran out (X-20); the nightly schedule is off.

## Backlog changes

- New: M2-16 (twists, done), X-18 (nightly results), X-19 (bot client cost), X-20 (Actions allowance), F-16 (done), F-17 (mix headroom).
- Next, in order: finish M2-07 duel tuning; 2v2 and 3v3 balance with talents on the workspace (M2-04, M2-08); M2-09 leftovers; M2-10 (third arena); M2-15 (M2 gate).

## Update, 2026-10-02

The repository is public, so CI runs again (X-20).

- 1,000-duel confirmation (CI, named builds): Arcanist 46.5%, Oracle 50.4%, Warblade 52.9%. Match-ups: Arcanist-Oracle 43%, Arcanist-Warblade 48%, Oracle-Warblade 45%. M2-07 is done. 249 of 1,000 duels were draws, nearly all mirrors (F-08).
- Nightly with random talent builds (CI, 1,000 per bracket):

| Bracket | Arcanist | Oracle | Warblade | Teams outside 40-60% |
| --- | --- | --- | --- | --- |
| 1v1 | 79% | 33% | 37% | Arcanist beats Warblade 99% |
| 2v2 | 51% | 43% | 57% | two Warblades 63%, two Oracles 20% |
| 3v3 | 48% | 52% | 53% | Oracle-Warblade-Warblade 61%, three Oracles 24%, three Arcanists 36% |

- Two-healer 3v3 teams are down from 74-78% (review 2) to 60%. M2-08 is done.
- Talent trees: 18-21 talents per spec are in at least 85% of random legal builds, so "no node in over 90% of top builds" cannot pass until the trees offer more paths (M2-04b).
- Performance on a 4-core runner: server tick 3.4 ms average; bot clients 13-17 snapshots a second (X-19).
- Flooded Crypt now shows ripples and splashes and plays wading footsteps in the flood (`previews/m2_09/wading_1280.png`). M2-09 is done.
