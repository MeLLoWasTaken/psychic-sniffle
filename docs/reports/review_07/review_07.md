# Review pass 7, 2026-10-10

Since review 6: M3-08, M3-09 (both finished during review 6 and counted here), M3-04 (Templar balance), M3-10 (Deathsworn character), M3-11 (Frostgrave sounds), M3-12 (Bloodbound), M3-13 (eight specs in the menu); then the graphics overhaul: G-01 to G-06, G-11 to G-16, G-07 and G-08. That is 21 items, so this pass is overdue. Its focus is the human's latest request ("continue adding detail to every asset; continue working toward a AAA visual standard"), and the list of gaps below sets the art order.

## Review checklist

| Check | Result |
| --- | --- |
| Balance, simulated bots | No ability, spec, talent or tuning data has changed since the nightly at 952db81 (`git diff 952db81 HEAD -- data game/core`: art specs, armor sets, appearance options, menus, settings and the appearance code only). Its results stand: every spec inside 40-60% in every bracket, and 83 of 83 Oracle duels ended in a kill. No new balance run was needed. |
| Talent builds | Unchanged since the same nightly: at least 3 viable builds per spec per bracket. |
| Lineup against the art bible | `lineup_a.png` (Radiance, Vanguard, Zealot, Warblade) and `lineup_b.png` (Frostgrave, Bloodbound, Arcanist, Oracle), the new assembled characters in Godot. All eight specs now wear their class's new set. Silhouettes read apart: the flat-topped helm with shield or glaive (Templar), horns and spiked pauldrons (Warblade), ice crown and torn skirt (Deathsworn), hood with bell sleeves and capelet (Arcanist), halo and white robe (Oracle). **The weapons are the weakest assets on screen**: 300 to 5,000 triangle loft models with 1024 px textures next to armor of about 117,000 triangles (the mace and glaive read as blocks, the runeblade's teeth as a stepped outline). Also seen: the Arcanist robe is a plain field of blue whose trims read as white stripes; the Templar spaulders are still plain domes; the two Deathsworn specs differ only by dye (as designed). The lineup's name labels overlap when the names are long (a test-scene problem). |
| Arena screenshots | `arena_gallows_courtyard.png`, `arena_flooded_crypt.png`, `arena_burning_foundry.png` (the player's camera at match start). The sculpted floor and pillars from E-01 hold up at play distance. Gaps: (1) **lighting and atmosphere**: the foundry is murky (mean luminance of the lower two thirds 0.105, against 0.224 in the courtyard) and the crypt is dim (0.176). The skies are flat fills (crypt: luminance standard deviation 0.012 in the top fifth) and the skyline buildings are untextured silhouettes. (2) **The kits outside E-01**: brick walls tile as a regular grid; the crypt's broken central column reads as a bundle of sticks; sarcophagi and crates are plain boxes. (3) The in-game player is still the old character model, because the new models stay behind a setting until G-10. |
| Performance, 20 players | `rig_view.tscn --mode perf --looks --count 20`: 2,343,552 triangles at full detail (117,177 per character, against 49,427 at G-05 and 22,559 for the old models). CPU time for animation and the rig: 3.03 ms a frame for 20 with the rig modifiers on, 1.29 ms with them off (1.74 ms, 87 us per character, for foot grounding and the other modifiers); skinning runs on the GPU. Server tick and memory: unchanged code since review 6's CI numbers (1.6 ms average tick). A GPU frame time still needs a GPU machine (KNOWN_ISSUES). |

## What the review says

The characters are now near the target: dense modelled armor with baked detail, faces with painted features, eight specs with distinct silhouettes. The two areas that keep the game from reading as a finished retail product are what the characters hold and where they stand.

Ranked gaps to a AAA stylized standard, by how much of the screen they affect and how far they are from the target:

1. **Weapons** (G-09, under way). They are in every frame and are roughly a tenth of the target's detail. The new pipeline (dense fields baked to 8,000-20,000 triangles at 2048 px) is in progress.
2. **Arena lighting and atmosphere** (new E-06). Two of three arenas are too dark to show the detail already built, and all three skies are flat fills. This changes every screenshot for little geometry cost.
3. **Environment kits** (E-01 remainder, E-02 to E-04). Walls, props and hero pieces outside the three E-01 pieces are still at the old detail.
4. **The switch to the new characters** (G-10). Players still see the old models in matches.
5. **Polish on the new sets** (new G-17): the Arcanist robe's large plain areas and stripe-like trims, the Templar spaulders as domes, the fur ruff reading as bark, the torn cape strips as narrow cuts, the boxy male cranium, and the Oracle fit (G-08b).
6. **Hair** (in G-17): the long styles are still a solid curtain with grooves rather than locks.

## Backlog changes

- Done since review 6: the 21 items listed above.
- G-09 continues first: the weapon pipeline and the seven designs (six rebuilt and the Zealot's two-handed sword).
- New **E-06 Arena lighting and atmosphere**: per arena, a painted sky with structure (clouds, moon or smoke) and exposure, fog and fill lights adjusted so the play area reads. Measurable on the player-camera screenshot: lower two thirds' mean luminance 0.18 to 0.40, its 5th to 95th percentile spread at least 0.25, and the sky band's luminance standard deviation at least 0.03. Today: courtyard 0.224 / 0.28 / 0.044 (passes); crypt 0.176 / 0.27 / 0.012; foundry 0.105 / 0.20 / 0.017.
- New **G-17 Character polish from review 7**: the items in gap 5, plus hair locks, each checked side by side with the current sheet.
- Order: G-09, E-06, E-01 remainder, E-02 to E-04 alternating with G-17 and G-08b during long bakes, G-10 (gate, with the human's review), E-05; then wave 1 continues (Deathsworn Plague).
