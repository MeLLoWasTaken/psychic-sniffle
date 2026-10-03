"""Fast look at the overhaul bodies (backlog G-01) while tuning anatomy.py: no rig, no export.

  python3 tools/blender/preview_anatomy.py --out previews/g_01/bodies.png [--types male,female]
      [--voxel 0.004] [--tris 16000] [--compare heavy,lean]

One row per body type: front, three-quarter, side and back at one orthographic scale, then a head
and a torso close-up. --compare adds the old builds (body_sdf.py) in the same views for a side by
side. --tris 0 keeps the full extracted surface.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
import numpy as np  # noqa: E402
from mathutils import Vector  # noqa: E402

import anatomy  # noqa: E402
import body_sdf  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402

SKIN = "#b08a70"


def make_body(build: str, voxel: float, tris: int) -> bpy.types.Object:
    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[build]).items()}
    if build in anatomy.TYPES:
        verts, faces = anatomy.body_mesh(j, build, voxel)
    else:
        verts, faces = body_sdf.body_mesh(j, build, voxel)
    mesh = bpy.data.meshes.new(build)
    mesh.from_pydata(verts.tolist(), [], faces.tolist())
    mesh.validate()
    obj = bpy.data.objects.new(build, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    if tris and len(faces) > tris:
        dec = obj.modifiers.new("decimate", "DECIMATE")
        dec.ratio = tris / len(faces)
        bpy.ops.object.modifier_apply(modifier="decimate")
    bpy.ops.object.shade_smooth()
    obj.data.materials.append(common.painted_material("skin_" + build, SKIN, roughness=0.6, edge_highlight=0.0,
                                                      cavity_darken=0.35))
    print(f"{build}: {len(faces)} extracted, {len(obj.data.polygons)} kept", flush=True)
    return obj


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--types", default="male,female")
    ap.add_argument("--compare", default="")
    ap.add_argument("--voxel", type=float, default=0.004)
    ap.add_argument("--tris", type=int, default=16000)
    ap.add_argument("--cell", type=int, default=420)
    ap.add_argument("--samples", type=int, default=24)
    args = ap.parse_args(argv)
    common.reset_scene()
    scene = bpy.context.scene
    common.setup_lighting("dusk_grim")
    fill = bpy.data.objects.new("front_fill", bpy.data.lights.new("front_fill", type="SUN"))
    fill.data.energy = 1.6
    fill.rotation_euler = (math.radians(65), 0, math.radians(20))
    scene.collection.objects.link(fill)
    bpy.ops.mesh.primitive_plane_add(size=60)
    bpy.context.active_object.data.materials.append(common.painted_material("g", "#2a2723", edge_highlight=0))
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = "AgX"
    scene.render.resolution_x = args.cell
    scene.render.resolution_y = int(args.cell * 1.5)

    builds = [b for b in args.types.split(",") if b] + [b for b in args.compare.split(",") if b]
    bodies = {b: make_body(b, args.voxel, args.tris) for b in builds}
    tallest = max(max(v.co.z for v in o.data.vertices) for o in bodies.values())
    from PIL import Image, ImageDraw
    rows = []
    for b, obj in bodies.items():
        for o in bodies.values():
            o.hide_render = o is not obj
        jt = humanoid.joints(humanoid.BUILDS[b])
        tiles = []
        views = [("front", 0), ("three-quarter", 35), ("side", 90), ("back", 180)]
        for label, yaw in views:
            cam.data.type = "ORTHO"
            cam.data.ortho_scale = tallest * 1.08
            a = math.radians(yaw)
            target = Vector((0, 0, tallest * 0.5))
            cam.location = target + Vector((math.sin(a), -math.cos(a), 0.0)) * 12
            cam.rotation_euler = (math.radians(90), 0, a)
            tiles.append(_shot(scene, args.out, f"{b}_{label}"))
        for label, yaw, centre, size in (("head", 25, jt["head"] + Vector((0, 0, 0.11)), 0.36),
                                         ("torso", 20, jt["chest"] + Vector((0, 0, -0.06)), 0.9)):
            cam.data.type = "PERSP"
            cam.data.lens = 85
            a = math.radians(yaw)
            d = Vector((math.sin(a), -math.cos(a), 0.08)).normalized()
            cam.location = centre + d * size * 3.2
            cam.rotation_euler = (centre - cam.location).to_track_quat("-Z", "Y").to_euler()
            tiles.append(_shot(scene, args.out, f"{b}_{label}"))
        rows.append((b, tiles))
    w, h = args.cell, int(args.cell * 1.5)
    sheet = Image.new("RGB", (w * 6, (h + 24) * len(rows)), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    for r, (b, tiles) in enumerate(rows):
        for i, path in enumerate(tiles):
            sheet.paste(Image.open(path).convert("RGB"), (i * w, r * (h + 24) + 24))
            path.unlink()
        tris = len(bodies[b].data.polygons)
        draw.text((6, r * (h + 24) + 6), f"{b}  {tris} triangles  (front, three-quarter, side, back, head, torso)",
                  fill=(220, 220, 220))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print("saved", args.out)


def _shot(scene, out: Path, label: str) -> Path:
    tmp = out.with_name(f"_{out.stem}_{label}.png")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(tmp)
    bpy.ops.render.render(write_still=True)
    return tmp


if __name__ == "__main__":
    main()
