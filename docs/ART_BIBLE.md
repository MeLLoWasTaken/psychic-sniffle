# Art bible

Rules for every visual asset. docs/DESIGN.md "Art direction" sets the goals; this file holds the concrete conventions and approved references. Add a reference render here each time an asset passes review.

## Conventions

- 1 Blender unit = 1 metre. Origin at the feet (lowest point at z = 0, within 1 cm), centred on x and y.
- Characters face -Y in Blender; up is +Z; the character's left is +X. The glTF exporter converts to Godot's axes.
- Rest pose is an A-pose with arms 50 degrees below horizontal.
- Budgets: characters 15,000 to 25,000 triangles at LOD0 including armor (a bare body is about 6,000 to 9,000); props 500 to 5,000; texture sizes are powers of two.
- Materials: base color with lighter worn edges and darker crevices. Metallic stays at or below 0.3; metal is painted dark with bright worn edges rather than shown as a reflective surface.
- Until the texture bake exists (backlog M1-17), exported models carry flat base colors.

## Standard humanoid skeleton

Every humanoid uses these 20 bones (defined in `tools/blender/humanoid.py`, `BONES`). Animation clips target these names, so they must never change.

| Bone | Parent | From joint | To joint |
| --- | --- | --- | --- |
| root | none | ground | pelvis |
| pelvis | root | pelvis | spine |
| spine | pelvis | spine | chest |
| chest | spine | chest | neck |
| neck | chest | neck | head |
| head | neck | head | head_top |
| clavicle_l / clavicle_r | chest | chest_top | shoulder |
| upperarm_l / upperarm_r | clavicle | shoulder | elbow |
| forearm_l / forearm_r | upperarm | elbow | wrist |
| hand_l / hand_r | forearm | wrist | hand_end |
| thigh_l / thigh_r | pelvis | hip | knee |
| calf_l / calf_r | thigh | knee | ankle |
| foot_l / foot_r | calf | ankle | toe |

Suffix `_l` is the character's left (+X), `_r` its right (-X).

## Body builds

| Build | Height | Used by | Notes |
| --- | --- | --- | --- |
| heavy | 1.95 m | Plate wearers | Broad, top-heavy; bulk 1.0 |
| lean | 1.85 m | Cloth and leather wearers | Narrower shoulders; bulk 0.74 (currently broken: masses separate) |

## Lessons from reviews

- The Skin modifier alone makes thin tubes; it cannot give the heavy silhouette. Bodies use metaball masses instead.
- Metaball surfaces sit inside their radius: at threshold 0.1 and stiffness 2, the surface is at 0.795 of the radius (measured). Radii are scaled up to compensate.
- Blender's Pointiness value is per vertex, so it highlights whole low-poly parts. Edge highlights use a Bevel-normal comparison instead.

## Approved references

None yet. The first entries are expected at the M1-22 art gate.
