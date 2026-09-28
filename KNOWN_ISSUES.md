# Known issues

Problems that are open, with what was tried. Newest first.

| Date | Issue | Tried so far | Next step |
| --- | --- | --- | --- |
| 2026-09-28 | No GPU in the cloud workspace, so absolute frame-rate targets (60 fps on the recommended and minimum PCs) cannot be measured | Software rendering (llvmpipe, lavapipe) works for screenshots | Run the GPU checks on a real GPU machine at each milestone gate |
| 2026-09-28 | Eevee preview renders take about 100 s each without a GPU | Cycles on CPU takes about 15 s at 640×480 | Use Cycles or Workbench for quick checks; Eevee only for final review renders |
