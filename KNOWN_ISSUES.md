# Known issues

Problems that are open, with what was tried. Newest first.

| Date | Issue | Tried so far | Next step |
| --- | --- | --- | --- |
| 2026-09-29 | Scripted character bodies look like segmented mannequins, well short of the stylized target | v1 Skin modifier (thin tubes); v2 metaball masses with measured size correction (chunky but segmented); lean build leaves gaps | Try stronger blending and sculpt-style smoothing; if the M1-22 art gate still fails, ask the human about a CC0 base mesh (open decision "Character art source") |
| 2026-09-28 | Godot build restarted after the workspace rebooted mid-compile | Resumed; SCons redid most files | Cache the finished binary in the project's remote repository (M0-02) |
| 2026-09-28 | No GPU in the cloud workspace, so absolute frame-rate targets (60 fps on the recommended and minimum PCs) cannot be measured | Software rendering (llvmpipe, lavapipe) works for screenshots | Run the GPU checks on a real GPU machine at each milestone gate |
| 2026-09-28 | Eevee preview renders take about 100 s each without a GPU | Cycles on CPU takes about 15 s at 640×480 | Use Cycles or Workbench for quick checks; Eevee only for final review renders |
