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

## Animation

Every humanoid clip is authored as a few key poses in `data/animations/humanoid.json` and baked frame by frame (30 fps) by `tools/blender/build_animations.py` into one library per body build (`game/assets/animations/anims_<build>.glb`, asset specs `anims_<build>.json`). Characters of a build share its library; `CharacterRig` in the game plays it on each character's own skeleton.

- Poses use joint terms, not bone axes: torso and head bend, twist, lean or tilt; thighs swing and spread; calves bend; feet point; clavicles raise and swing; upper arms swing and raise; forearms bend; hands curl and cock. Degrees, positive as the set's description says. `animation.check_axes` proves every term moves the skeleton the documented way on every build.
- Motion between keys is a smooth curve that never overshoots a key. A key can set `ease`: "in" for a strike landing (accelerates into the key), "out" for snapping out of one.
- Follow-through: chest, neck, head, forearms, hands and feet trail their parents by `overlap_s`; clavicles shrug as the arms lift past 50 degrees forward or 25 sideways.
- Weapons sit in the right fist by the set's `weapon_grip`: the grip point and each hold's blade direction are given in rest-pose character terms, so they fit every build. Swords and maces are held "forward" (blade forward from the fist); staffs are held "upright", with a wrist rule that keeps them upright through arm swings, baked as `<clip>_upright` copies of every clip.
- Clip names are lower snake case: idle, combat_idle, run, strafe_left, strafe_right, backpedal, jump, cast_start, cast_loop, cast_release, cast_release_<school> (frost and holy so far), channel, attack_1, attack_2, attack_3, ranged_shot, hit, stunned, feared_run, death, victory. A clip's length is a whole number of frames.
- Motion capture (X-01): a clip may take bones from a fitted capture (`capture` in the clip: `source`, `bones`, `gains`, `relative`). `tools/blender/build_capture.py` fits a BVH window from `data/capture_sources` to the skeleton as term values (`data/captures`); the clip's keys add on top. Run and idle use captures; `tools/blender/compare_capture.py` measures foot slide against the running speed and renders side and three-quarter sheets for comparing candidates.
- Review: pose sheets (`previews/animations/<character>_<locomotion|casting|combat>.png`, six frames per clip) and the clipping report (`anims_<build>_clipping.json`). Idle, combat idle, run and the cast clips must be free of clipping: no vertex more than 1.5 cm inside another body part or the weapon, outside the shoulder and hip zones.

## Lessons from reviews

- Pose sheets must pose the rig with its baked tracks removed; left in place, the tracks override the pose on every render and every frame looks the same.
- A staff held rigidly tips over whenever the elbow bends; a separate hold with a wrist rule keeps it upright. Its foot must stay well above the ground (grip 0.7 m from the foot), or the running feet kick it.
- Captured arms swing across the chest and past the hip; plate armour does not allow that, so plate builds keep scripted arm swings (X-10).
- Captured runs are much slower than a game's 7 m/s: scale the thigh swing (stride) and measure foot slide rather than guessing.
- Heavy plate needs the arms wider than the lean build does; poses are tuned against the heavy build's clipping report first.
- At a character's body density (4,000-6,500 triangles) fingers merge into mitts. Hands are covered by gauntlets or gloves extracted on a 2.5-3 mm grid with their own budget; the weapon hand is a fist around the grip, the other relaxed.
- A face in a hood reads as a void only when the hood's rim stands about 12 cm in front of it; glowing eyes must sit in front of the face surface (brow and cheeks otherwise hide them) and glow strongly (emission 7).
- Masks, visors and ornaments are placed from the face's actual forward-most point (the nose tip is 12 cm in front of the head centre); a mask built as an offset of the crude face sank into it.
- Ornament plates on small parts (a knuckle plate on a fist) read as floating slabs; keep ornaments close to the surface.
- Character materials darken and cool toward the feet and brighten toward the head (height gradient), which draws the eye to the face and hands.
- Break up large plain areas with layered pieces in an accent color: the Oracle's cream robe gained a wine stole, gold hem band, bordered panel and an emblem.

- The Skin modifier alone makes thin tubes, and metaball masses read as a segmented mannequin. Bodies are signed distance fields: tapered capsules joint to joint, blended with smooth unions.
- Round ellipsoids for the torso gave an hourglass, female-looking silhouette. A heroic male torso uses rounded boxes: flat, square pec plates, a thick straight waist, hips narrower than the chest.
- Thigh tops wider than the pelvis create an hourglass from the front; keep the outer edge of the thigh inside the hip line.
- A hand seen edge-on from the front looks like a thin point; judge hand size from the side and three-quarter views.
- Blender's Pointiness value is per vertex, so it highlights whole low-poly parts. Edge highlights use a Bevel-normal comparison instead.

- Warm key light plus warm fog plus a brown sky horizon turned whole scenes orange-brown. Keep the sun warm, but make the sky horizon, fog and ambient light cool (blue-grey), and keep stone base colors neutral grey. The shadow side of stone should read cool.
- A dark wood color on a block that sits in shadow reads as a black hole from the player camera; set wood base colors to about 0.4 value or brighter.
- The empty dusk sky above 6 m walls made the arena look unfinished from the player camera; a skyline of towers, rooftops and a keep 35 to 70 m out fills the upper third of the frame without competing with the players, as long as it stays darker than the arena stone.
- Judge floor decals in the top view, not the player view: at the player camera's grazing angle a 2 m grime band along a wall 15 m away is only a few pixels tall, which made a correct first pass look missing. Check placement and coverage with a loud debug color first; the grime that reads is 2 to 3 m wide with a plateau near the wall.
- Banner pieces start at their hem (lowest point at z = 0), so a decor entry's `y` is the hem height, not the bracket height.
- In Blender scripts, an object's matrix only refreshes when the view layer updates: setting `.location` and then baking with `matrix_world` silently drops the move. Update the view layer first (`apply_xf` in the dressing builder), and bake a primitive's own placement before moving a group of parts.

## Lighting presets

Presets live in `data/lighting/<id>.json` (sun, fill, sky, ambient light, fog, post-processing) and maps name one. `dusk_grim` is the default arena look: low warm sun from the south-west, cool sky fill, blue-grey volumetric fog, AgX tonemapping.

## Arena greybox

`scenes/maps/map_builder.gd` builds every arena from its map data, so art always matches gameplay collision. Colliders carry a `tag` (pillar, wall, gate, gallows, prop); the art kit (M1-15) replaces the greybox shape for each tag. Team colors: crimson for team A (west room), steel blue for team B (east room), shown on the gates and room floors. Review views: `tools/screenshot.sh res://scenes/tests/map_view.tscn <out.png> 1920 1080 60 --view top|overview|player|room_a|room_b` (the room views look out of each starting room through the open gate).

## Environment kits

- One asset spec per piece (`data/assets/<kit>_<piece>.json`), built by `tools/blender/build_kit_<kit>.py`. Standard sizes: floor tiles and wall segments 4 m wide, walls 6 m tall, so the map builder can tile and stretch them slightly to fit colliders.
- Stones, planks and bars are separate beveled parts with slight random offsets, each with its own tint, then joined and baked. Keep shapes chunky; detail comes from the gaps and bevels, not texture noise.
- Pieces that mount on a surface use the "face" pivot (the mounting face on y = 0).
- Dressing (F-05) is map data under `dressing`, placed by the map builder, never hand-placed: ramparts crown every facade segment (`wall_top.parapet`), wall tops use their own long-slab walk piece so they never read as courtyard floor, the outside of the walls gets facades too (`outer_facades`), and a gatehouse on the wall top hides each raised portcullis. `variants` swaps repeated pieces for look-alikes by weight (worn floor tiles, broken merlons, a second wall coursing) so a 4 m repeat does not show.
- Skyline: low-detail silhouettes (a few hundred to 5,000 triangles) standing at least 10 m beyond the bounds, with no collision, no shadows and no bounced light. Keep them darker and cooler than the arena stone (far stone about #4d4b46, roofs #34383f) so they recede; a quarter or fewer of their windows glow warm.
- Props are visual only. They hug a wall (within about 0.9 m of its face) or sit in a room corner, stay under 2.5 m, and never stand in the lanes between pillars; anything meant to block movement or sight must be a collider in the map data instead. Repeated props are batched (one multimesh per piece).
- Floor variation without texture noise: worn tile variants, grime decals along every wall base and around pillars, broad faint stains across the open floor, a few drains, and puddle decals (dark, glossy). Decal textures are generated from smooth shapes (gradients and overlapping round blobs).
- Fixture fire is data (`data/ambient_effects/<id>.json`): flame tongues from a noise shader, a dozen embers, a thin smoke plume and a light that flickers from a sum of unrelated sines, so braziers never pulse together.

## Spell effects

- Every ability's stages are data (`data/effects/<ability id>.json`) naming generic styles; colors come only from the school table in `data/effect_palettes/default.json` (the same color always means the same school; physical is pale steel). Check a palette change with `effects_view --mode schools` and `tools/effects_hues.py` (hues at least 30 degrees apart as seen in game).
- A few bright, simple shapes carry each effect (fresnel shells, orbs, rings, crescents, crystals); particles only add motion, a dozen or two per emitter. Keep glow intensities moderate: AgX and bloom wash anything much brighter toward white and the school is lost.
- Ground circles: the outline carries the area (red-tinted for enemies, pale for allies); the fill only tints, or large circles paint the floor.
- Casting is shown at the hands and by a ring at the feet; crowd control has one fixed shape per kind (stun crystals, disorient swirl, silence halo, root spikes, ice block), chunkier than any other effect.
- Review views: `tools/screenshot.sh res://scenes/tests/effects_view.tscn <out.png> 1600 900 30 --mode schools|grid [--spec <id>] [--caster-team 0|1]`.

## Approved references

None yet. The first entries are expected at the M1-22 art gate.
