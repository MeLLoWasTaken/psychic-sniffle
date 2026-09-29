"""Fast look at an SDF body while tuning its shape: no rig, no export.

  python3 tools/blender/preview_body.py --build heavy --out previews/body_iter/heavy.png

Renders front, side, three-quarter and a head close-up into one sheet.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import common  # noqa: E402
import humanoid  # noqa: E402


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="heavy")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--cell", type=int, default=512)
    args = ap.parse_args(argv)
    common.reset_scene()
    body = humanoid.build_body_sdf(args.build, "body", target_tris=12000, voxel=0.006)
    body.data.materials.append(common.painted_material("skin", "#9a7a62", roughness=0.7, edge_highlight=0.0,
                                                       cavity_darken=0.5))
    from PIL import Image, ImageDraw
    scene = bpy.context.scene
    common.setup_lighting("dusk_grim")
    # softer preview light: a front fill so the face reads
    data = bpy.data.lights.new("front_fill", type="SUN")
    data.energy = 1.5
    lamp = bpy.data.objects.new("front_fill", data)
    lamp.rotation_euler = (math.radians(70), 0, math.radians(10))
    scene.collection.objects.link(lamp)
    bpy.ops.mesh.primitive_plane_add(size=20)
    bpy.context.active_object.data.materials.append(common.painted_material("g", "#2a2723", edge_highlight=0))
    cam_data = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 24
    scene.cycles.use_denoising = True
    scene.render.resolution_x = args.cell
    scene.render.resolution_y = args.cell
    scene.view_settings.view_transform = "AgX"
    h = max(v.co.z for v in body.data.vertices)
    views = [("front", 0, Vector((0, 0, h * 0.5)), h * 1.25, 50),
             ("side", 90, Vector((0, 0, h * 0.5)), h * 1.25, 50),
             ("three-quarter", 35, Vector((0, 0, h * 0.5)), h * 1.25, 50),
             ("head", 25, Vector((0, 0, h * 0.9)), 0.55, 85)]
    tiles = []
    for label, yaw, target, dist, lens in views:
        cam_data.lens = lens
        a = math.radians(yaw)
        d = Vector((math.sin(a), -math.cos(a), 0.12)).normalized()
        cam.location = target + d * dist * (50 / 35)
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
        tmp = args.out.with_name(f"_{args.out.stem}_{label}.png")
        tmp.parent.mkdir(parents=True, exist_ok=True)
        scene.render.filepath = str(tmp)
        bpy.ops.render.render(write_still=True)
        tiles.append((label, tmp))
    sheet = Image.new("RGB", (args.cell * len(tiles), args.cell + 24), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    for i, (label, tmp) in enumerate(tiles):
        sheet.paste(Image.open(tmp).convert("RGB"), (i * args.cell, 24))
        draw.text((i * args.cell + 6, 6), label, fill=(220, 220, 220))
        tmp.unlink()
    sheet.save(args.out)
    print("saved", args.out)


if __name__ == "__main__":
    main()
