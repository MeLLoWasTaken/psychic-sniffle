# Review pass 1 (M0-17), 2026-09-29

M0 is complete apart from storing the Godot binary outside the workspace (M0-02, waiting on the project's GitHub repository). The exit gate passed, and the foundations hold up at battleground size.

## Results against the review checklist (docs/DESIGN.md, "Review pass")

| Check | Result |
| --- | --- |
| Balance simulations | Not applicable yet: no specs are implemented. First run after M1-13. |
| Character lineup against the art bible | Heavy and lean bodies rendered (`previews/body_*`). Heavy is chunky but reads as a segmented mannequin; lean separates into pieces. Fails the art bar; logged in KNOWN_ISSUES.md. |
| Arena screenshots | No arena yet. Engine lighting test (`previews/shots/lit_test.png`) renders shadows, fog and bloom correctly, but is uniformly orange; noted on M1-15. |
| Performance profile, 20 players | 20 bots for 45 s: server tick average 0.24 ms, p95 0.46 ms, max 1.7 ms (budget 8 ms); 38.7 KB/s per client (budget 96 KB/s, no delta compression yet); every bot received 60.0 snapshots per second. Report: `perf_20bots_2026-09-29.json`. Frame rate on a GPU machine: not measurable here. |

## Problems found and fixed during M0

- Networking: exactly-once input handling removed 0.9 m prediction errors under lag; ENet's packet throttle was silently dropping up to 17% of snapshots under CPU load and is now pinned open; shutdown races in server and client; latency measurement now polls every frame.
- Pipeline: edge-highlight shading, glTF color export, Vorbis peak levels, audio clicks and the loop flag, bone display meshes confusing the asset validator.
- Harness: server now outlives staggered bot launches.

## Backlog changes

- M1 proceeds in order. M1-16 (bodies) stays in progress; the art-quality risk is the top concern for the M1-22 gate.
- Added follow-ups: delta-compressed snapshots and reduced send rate for distant players (needed before M4 at larger player counts, not before); record frame-rate numbers on a GPU machine at the M1 gate.

## Needs the human

1. Create an empty private GitHub repository so work and the compiled Godot binary persist beyond this workspace.
2. Listen to the three generated test sounds and say what sounds wrong.
3. Early heads-up on the M1 art gate: fully scripted characters may not reach the target look; a CC0 base mesh is the fallback in the design's open decisions.
