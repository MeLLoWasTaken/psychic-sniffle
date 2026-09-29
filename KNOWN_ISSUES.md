# Known issues

Problems that are open, with what was tried. Newest first.

| Date | Issue | Tried so far | Next step |
| --- | --- | --- | --- |
| 2026-09-29 | Scripted character bodies are smooth and the face is crude (clay-like features), short of a hand-sculpted stylized character | v1 Skin modifier (thin tubes); v2 metaballs (segmented); v3 signed-distance-field body with blocky torso and blended muscles: continuous surface, heroic proportions, clean deformation (accepted for M1-16) | Judge at the M1-22 art gate with armor on; if faces or bodies still fall short, ask the human about a CC0 base mesh (open decision "Character art source") |
| 2026-09-28 | No GPU in the cloud workspace, so absolute frame-rate targets (60 fps on the recommended and minimum PCs) cannot be measured | Software rendering (llvmpipe, lavapipe) works for screenshots | Run the GPU checks on a real GPU machine at each milestone gate |
| 2026-09-28 | Eevee preview renders take about 100 s each without a GPU | Cycles on CPU takes about 15 s at 640×480 | Use Cycles or Workbench for quick checks; Eevee only for final review renders |
