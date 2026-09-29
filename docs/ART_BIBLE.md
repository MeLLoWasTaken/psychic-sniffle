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

Bodies are signed distance fields (`tools/blender/body_sdf.py`) on the skeleton's joints, extracted as one closed mesh and reduced to about 9,000 triangles. Fast shape preview: `python3 tools/blender/preview_body.py --build heavy --out previews/body_iter/heavy.png`.

| Build | Height | Used by | Notes |
| --- | --- | --- | --- |
| heavy | 1.96 m | Plate wearers | Broad, top-heavy, thick limbs, hands 1.22x |
| lean | 1.88 m | Cloth and leather wearers | Torso and limbs 0.8x, smaller muscles |

## Lessons from reviews

- The Skin modifier alone makes thin tubes, and metaball masses read as a segmented mannequin. Bodies are signed distance fields: tapered capsules joint to joint, blended with smooth unions.
- Round ellipsoids for the torso gave an hourglass, female-looking silhouette. A heroic male torso uses rounded boxes: flat, square pec plates, a thick straight waist, hips narrower than the chest.
- Thigh tops wider than the pelvis create an hourglass from the front; keep the outer edge of the thigh inside the hip line.
- A hand seen edge-on from the front looks like a thin point; judge hand size from the side and three-quarter views.
- Blender's Pointiness value is per vertex, so it highlights whole low-poly parts. Edge highlights use a Bevel-normal comparison instead.

- Warm key light plus warm fog plus a brown sky horizon turned whole scenes orange-brown. Keep the sun warm, but make the sky horizon, fog and ambient light cool (blue-grey), and keep stone base colors neutral grey. The shadow side of stone should read cool.
- A dark wood color on a block that sits in shadow reads as a black hole from the player camera; set wood base colors to about 0.4 value or brighter.

## Lighting presets

Presets live in `data/lighting/<id>.json` (sun, fill, sky, ambient light, fog, post-processing) and maps name one. `dusk_grim` is the default arena look: low warm sun from the south-west, cool sky fill, blue-grey volumetric fog, AgX tonemapping.

## Arena greybox

`scenes/maps/map_builder.gd` builds every arena from its map data, so art always matches gameplay collision. Colliders carry a `tag` (pillar, wall, gate, gallows, prop); the art kit (M1-15) replaces the greybox shape for each tag. Team colors: crimson for team A (west room), steel blue for team B (east room), shown on the gates and room floors. Review views: `tools/screenshot.sh res://scenes/tests/map_view.tscn <out.png> 1920 1080 60 --view top|overview|player`.

## Environment kits

- One asset spec per piece (`data/assets/<kit>_<piece>.json`), built by `tools/blender/build_kit_<kit>.py`. Standard sizes: floor tiles and wall segments 4 m wide, walls 6 m tall, so the map builder can tile and stretch them slightly to fit colliders.
- Stones, planks and bars are separate beveled parts with slight random offsets, each with its own tint, then joined and baked. Keep shapes chunky; detail comes from the gaps and bevels, not texture noise.
- Pieces that mount on a surface use the "face" pivot (the mounting face on y = 0).

## Approved references

None yet. The first entries are expected at the M1-22 art gate.
