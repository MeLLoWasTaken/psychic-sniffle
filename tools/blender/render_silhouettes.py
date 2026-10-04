"""The 30 m grayscale check (docs/DESIGN.md quality gates): plate classes side by side, small and in
gray, as a player sees them across an arena.

    python3 tools/blender/render_silhouettes.py --out previews/g_04/silhouettes_30m.png

Shows each overhaul default set (armor sets with default_for) assembled on the male body with its
spec's weapon, next to the plate characters not yet rebuilt (their current models), at the size a
1.9 m character has 30 m away through a 70 degree camera at 1080p (about 60 px tall), and again at
three times that size for reading. Grayscale, flat light from the front, a plain background.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import animation  # noqa: E402
import common  # noqa: E402
import render_appearance as ra  # noqa: E402
import render_set as rs  # noqa: E402

REPO = common.REPO


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "g_04" / "silhouettes_30m.png")
    args = ap.parse_args(argv)
    out = args.out if args.out.is_absolute() else REPO / args.out
    common.reset_scene()
    scene = bpy.context.scene
    world = bpy.data.worlds.new("flat")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.5, 0.5, 0.5, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
    scene.world = world
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(60), 0, math.radians(20))
    scene.collection.objects.link(sun)
    entries = []   # (label, objects)
    x = 0.0
    anim = animation.load_set("humanoid")
    # overhaul default sets
    for path in sorted((REPO / "data" / "armor_sets").glob("*.json")):
        st = json.loads(path.read_text())
        if st.get("armor_type") != "plate" or not st.get("default_for"):
            continue
        spec = next((s for s in st["dyes"] if s != "default"), "default")
        char = json.loads((REPO / "data" / "assets" / f"char_{spec}.json").read_text()) if spec != "default" else {}
        weapon = char.get("params", {}).get("weapon")
        offhand = char.get("params", {}).get("offhand")
        body, wobj, _a, hold = rs.assemble("male", st["id"], spec, "neutral", "cropped", "#c99a78", weapon, offhand)
        objs = [body.mesh, body.rig] + [p for v in body.pieces.values() for p in v] + ([wobj] if wobj else [])
        animation.pose_rig(body.rig, animation.sample_clip(anim, "combat_idle", "male")[6],
                           animation.wrist_rule(anim, hold, "combat_idle", "male") if hold else None)
        entries.append((f"{st['name']} (new)", objs, body.rig))
    # current plate characters of the other classes
    for cid in ("char_warblade_carnage", "char_deathsworn_frostgrave", "char_templar_vanguard"):
        spec = json.loads((REPO / "data" / "assets" / f"{cid}.json").read_text())
        objs = ra.import_glb(REPO / spec["out"])
        rig = next((o for o in objs if o.type == "ARMATURE"), None)
        entries.append((f"{cid.removeprefix('char_')} (current)", objs, rig))
    for label, objs, rig in entries:
        root = rig if rig is not None else objs[0]
        root.location.x += x
        x += 1.6
    bpy.context.view_layer.update()
    # grayscale: everything one neutral material, so only the silhouette and shading read
    gray = bpy.data.materials.new("gray")
    gray.use_nodes = True
    gray.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.25, 0.25, 0.25, 1.0)
    for _l, objs, _r in entries:
        for o in objs:
            if o.type == "MESH":
                o.data.materials.clear()
                o.data.materials.append(gray)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.type = "ORTHO"
    width = x + 0.4
    cam.data.ortho_scale = width
    cam.location = Vector((x / 2 - 0.8, -30.0, 1.0))
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in {e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items} else "CYCLES"
    if scene.render.engine == "CYCLES":
        scene.cycles.samples = 8
        scene.cycles.device = "CPU"
    px_per_m = 60 / 1.9
    scene.render.resolution_x = int(width * px_per_m)
    scene.render.resolution_y = int(width * px_per_m * 0.42)
    cam.data.sensor_fit = "HORIZONTAL"
    small = out.with_name("_sil_small.png")
    scene.render.filepath = str(small)
    bpy.ops.render.render(write_still=True)
    from PIL import Image, ImageDraw, ImageOps
    im = ImageOps.grayscale(Image.open(small)).convert("RGB")
    big = im.resize((im.width * 3, im.height * 3), Image.NEAREST)
    sheet = Image.new("RGB", (big.width, im.height + big.height + 40), (40, 40, 40))
    sheet.paste(im, (0, 20))
    sheet.paste(big, (0, im.height + 40))
    d = ImageDraw.Draw(sheet)
    d.text((4, 4), "30 m (actual size)", fill=(230, 230, 230))
    for i, (label, _o, _r) in enumerate(entries):
        d.text((int((i * 1.6 + 0.2) * px_per_m * 3), im.height + 24), label, fill=(230, 230, 230))
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    small.unlink()
    print("saved", out)


if __name__ == "__main__":
    main()
