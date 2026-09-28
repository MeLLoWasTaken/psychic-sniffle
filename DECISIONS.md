# Decisions

Every choice not specified in docs/DESIGN.md, newest first. One line of reasoning each. Choices that are expensive to reverse need the human's approval, noted in the entry.

| Date | Decision | Reason | Approved by |
| --- | --- | --- | --- |
| 2026-09-28 | Blender runs as the `bpy` 4.5.4 Python module (Blender 4.5 LTS) in the cloud workspace | download.blender.org is blocked; PyPI is allowed; 4.5 is the current long-term-support line | Model |
| 2026-09-28 | Godot is compiled from the `4.7.2-stable` source tag | GitHub release binaries are blocked in the cloud workspace; `git clone` is allowed | Model |
| 2026-09-28 | Server tick rate 60 Hz with 60 Hz delta-compressed snapshots; tick budget under 8 ms; client bandwidth under 96 KB/s | Requested by the human (up from 30 Hz) | Human |
| 2026-09-28 | Engine: Godot 4.7 | Only engine of the three that a model can build, run, test and screenshot from text files on headless Linux; renderer covers the stylized art direction | Human deferred to the model's judgment |
