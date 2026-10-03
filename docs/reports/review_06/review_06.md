# Review pass 6, 2026-10-03

Since review 5: F-19 (Gallows Courtyard kit), F-18 (bots step out of a crucible's way; a calmer foundry floor), X-22 (prediction corrections under lag), M3-01 (Templar class and Radiance kit), M3-02 (Templar character), M3-03 (Radiance sounds and effects), M3-05 (Vanguard kit), M3-06 (Vanguard character) and M3-07 (Zealot kit and character): ten items. M3-08 (runes and a second resource on the HUD), M3-09 (Deathsworn class and Frostgrave kit) and a first Radiance balance pass were done while the balance runs for this review were on CI; they count toward review 7.

## Review checklist

| Check | Result |
| --- | --- |
| Balance, simulated bots | Nightly on CI at ad00bac (all three Templar specs, before the Radiance pass): 3,000 matches per bracket, 24 talent builds per spec (3 named, 21 random), every arena in turn. **2v2**: every spec inside 40-60% (Arcanist 50%, Oracle 42%, Radiance 50%, Vanguard 57%, Zealot 56%, Warblade 49%). **3v3**: every spec inside (Arcanist 48%, Oracle 45%, Radiance 54%, Vanguard 53%, Zealot 57%, Warblade 50%). **1v1**: Vanguard 67%, Radiance 60%, Zealot 40%, Oracle 43%, Arcanist 48%, Warblade 24%. The Warblade loses every duel to Vanguard and Radiance (143 of 143 each) and 82% to the Zealot; Radiance also wins every duel against the Zealot. Matches end by a kill 93% of the time in 1v1 (Oracle duels draw 63 of 143) and 99% in 2v2 and 3v3. Teams outside 40-60% in 2v2: Radiance with the Zealot 71%, two Vanguards 71%, Radiance with a Warblade 64%, two Warblades 29%, two Oracles 28%, two Radiances 25%, Oracle with Radiance 17%. |
| Talent builds | Every spec has at least 3 viable builds in every bracket except the Warblade in 1v1 (2), a side effect of its duel losses. No node is favoured by the top builds beyond chance. |
| Lineup against the art bible | Six characters (`lineup_idle.png`, `lineup_silhouettes_idle.png`, `arena_lineup.png`). The three Templar specs share one silhouette (winged great helm) and differ by colour: cream, blue, crimson; the Zealot carries an upright sun glaive instead of the shield. Silhouette overlap with the Warblade: Radiance and Vanguard 0.82, Zealot 0.70 to 0.82; other pairs 0.52 to 0.74. In grayscale the Templars are the brightest figures and the Warblade the darkest. |
| Arena screenshots | `arenas_side_by_side.png` (match start, one camera per arena). The courtyard now matches the crypt and the foundry in detail: octagonal stone pillars with courses, corbels and shackles; a timber gallows on an ashlar plinth with a trapdoor and a cage. The foundry floor reads calmer (pavers in long courses). Review 5's finding (the courtyard as the plainest arena) is closed. |
| Performance, 20 players | CI (4 cores, 21 Godot processes): server tick 1.6 ms average, 3.3 ms 95th percentile, 16 ms max; bot clients 59.8-60.1 snapshots a second (12.6-16.7 at review 5); peak memory 135 MB for the server, 87 MB per bot client at most. A rendered frame time still needs a GPU machine (F-02, the human's playtest from Monday). |

## What the numbers say

- Team brackets are healthy with six specs. The new Templar specs sit at 50 to 57% in both team brackets.
- Duels are not. A tank (72,000 health and a defensive kit) and a plate healer win most duels, and the Warblade, which has no answer to plate plus self-healing, falls to 24%. A traced Radiance duel shows the cause: plate takes 30% off the Warblade's damage, Radiance's mana never runs low, and it settles at 30,000 to 40,000 health; dampening begins too late in 1v1 to matter. The first Radiance pass (softer attacks, weaker instant heal, stronger cast heal) did not change six local duels.
- DESIGN.md's M3 gate asks that each new spec win 40 to 60% in bot simulations, without naming brackets; M3-04's criterion includes 1v1. Whether tanks and healers should be held to the 1v1 range is a question for the human (below). Until then the criterion stands as written.

## Question for the human

Should 1v1 balance (40 to 60%) apply to tanks and healers too? Options: (a) yes, every spec in every bracket (tanks and healers then need duel-specific weaknesses, such as faster 1v1 dampening, which would change a DESIGN.md rule); (b) 1v1 balance is measured among damage specs only, with tanks and healers still playable in 1v1 but reported separately; (c) tanks are not queued for 1v1. Recommendation: (b), the usual practice for duel modes.

## Backlog changes

- Done: F-19, F-18, X-22, M3-01, M3-02, M3-03, M3-05, M3-06, M3-07; also M3-08 and M3-09 during the pass.
- M3-04 widened to all three Templar specs, with the 1v1 numbers above and the first Radiance pass recorded.
- New follow-ups: M3-10 Deathsworn character, M3-11 Frostgrave sounds and effects; Frostgrave balance on the next nightly (dispatched at cac5431).
- Next, in order: M3-04 (Templar balance; the 1v1 question decides its scope); Frostgrave balance; M3-10; M3-11; then Bloodbound (tank, pulls) and Plague (minions), Stormcaller, Warblade Berserker, Arcanist Pyre and Aether; wave 1 gate.
