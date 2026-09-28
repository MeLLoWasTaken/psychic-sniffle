# Decisions

Every choice not specified in docs/DESIGN.md, newest first. One line of reasoning each. Choices that are expensive to reverse need the human's approval, noted in the entry.

| Date | Decision | Reason | Approved by |
| --- | --- | --- | --- |
| 2026-09-28 | Sound source: effects are synthesized by `tools/audio/synth.py` by default; CC0 sample libraries are allowed for sounds synthesis handles poorly (voices, footsteps on varied surfaces, cloth) | Synthesis is reproducible and editable as text, fits the loop, and has no licensing risk; the model reviews spectrograms because it cannot listen, so the human should spot-check by ear at each milestone gate | Model; human to confirm by ear |
| 2026-09-28 | Sound files are Ogg Vorbis, 48 kHz mono; the generator measures the encoded peak and corrects it | Vorbis encoding raised peaks by up to 1.3 dB, which could break the "nothing louder than the CC warning" rule | Model |
| 2026-09-28 | Stylized materials keep metallic at or below 0.3; metal is painted dark with bright worn edges | Higher metallic values mirror the brown ground and warm key light, so iron read as wood in the test crate | Model |
| 2026-09-28 | Until the texture bake (M1-17), exports carry flat base colors | glTF cannot store procedural shader networks; they exported as white | Model |
| 2026-09-28 | Starting resource values: mana 50,000 (400/s), rage 100 (decays 2/s out of combat), energy 100 (10/s), combo points 5, focus 100 (5/s), runes 6 (10 s recharge), runic power 100, fury 100, essence 5 (5 s recharge) | The design names the resources but not their numbers; these are tuning placeholders for balance simulations to adjust | Model |
| 2026-09-28 | Jump: 8 m/s up with 20 m/s² gravity (about 1.6 m jump height); backpedal at 60% speed; auto-attack 1,200 damage every 2.0 s | Not specified in the design; values give classic MMO movement feel | Model |
| 2026-09-28 | Draft content (`status: draft`) gets structural checks only; the kit template and talent point totals apply once marked `complete` | Lets data grow incrementally without failing validation, while still enforcing the design rules on finished specs | Model |
| 2026-09-28 | Blender runs as the `bpy` 4.5.4 Python module (Blender 4.5 LTS) in the cloud workspace | download.blender.org is blocked; PyPI is allowed; 4.5 is the current long-term-support line | Model |
| 2026-09-28 | Godot is compiled from the `4.7.2-stable` source tag | GitHub release binaries are blocked in the cloud workspace; `git clone` is allowed | Model |
| 2026-09-28 | Server tick rate 60 Hz with 60 Hz delta-compressed snapshots; tick budget under 8 ms; client bandwidth under 96 KB/s | Requested by the human (up from 30 Hz) | Human |
| 2026-09-28 | Engine: Godot 4.7 | Only engine of the three that a model can build, run, test and screenshot from text files on headless Linux; renderer covers the stylized art direction | Human deferred to the model's judgment |
