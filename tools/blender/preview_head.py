"""Fast look at overhaul heads (backlog G-02) while tuning anatomy.add_head: no rig, no export.

  python3 tools/blender/preview_head.py --out previews/g_02/head.png [--types male,female]
      [--faces neutral,...] [--voxel 0.0015] [--tris 2400]

One row per (body type, face preset): front, three-quarter and side close-ups of the dense surface,
then the same three of the game mesh (reduced to --tris, roughly the head's share of a body).
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
import hair  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402
import sdf  # noqa: E402

SKIN = "#b08a70"


def head_mesh(body_type: str, face: str, voxel: float):
    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[body_type]).items()}
    shape = anatomy.body_shape(j, body_type, face=face)
    cut = float(j["chest_top"][2]) - 0.02
    keep = sdf.Shape([p for p in shape.prims if p.hi[2] > cut and abs((p.lo[0] + p.hi[0]) / 2) < 0.2])
    lo, hi = keep.bounds(margin=0.02)
    lo[2] = cut - 0.01
    lo[0], hi[0] = max(lo[0], -0.2), min(hi[0], 0.2)

    def fn(P):
        return np.maximum(sdf.eval_points(keep, P), cut - P[:, 2])
    return sdf.extract_field(fn, lo, hi, voxel), j


EYE_C = np.array([0.031, -0.082, 0.12])     # head-local eyeball centre and radius (anatomy.add_head)
EYE_R = 0.0122


def paint_eyes(o, j, body_type) -> None:
    """Whites, a dark iris and a pupil on the eyeballs, as the game's albedo has them (the eyes
    otherwise look shut in skin colour)."""
    hz, s = anatomy.head_frame(j, body_type)
    white = bpy.data.materials.new("eye_white")
    white.diffuse_color = (0.8, 0.78, 0.74, 1)
    white.use_nodes = True
    white.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.8, 0.77, 0.72, 1)
    iris = bpy.data.materials.new("eye_iris")
    iris.use_nodes = True
    iris.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.08, 0.05, 0.03, 1)
    o.data.materials.append(white)
    o.data.materials.append(iris)
    for poly in o.data.polygons:
        c = np.array(poly.center[:])
        L = np.array([abs(c[0]) / s, c[1] / s, (c[2] - hz) / s])
        d = np.linalg.norm(L - EYE_C)
        if d < EYE_R + 0.0009:
            q = L - EYE_C
            poly.material_index = 2 if (q[1] < -EYE_R * 0.6 and np.hypot(q[0], q[2]) < 0.0063) else 1


def mesh_obj(name, verts, faces, tris):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts.tolist(), [], faces.tolist())
    me.validate()
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    bpy.context.view_layer.objects.active = o
    if tris and len(faces) > tris:
        d = o.modifiers.new("d", "DECIMATE")
        d.ratio = tris / len(faces)
        bpy.ops.object.modifier_apply(modifier="d")
    o.select_set(True)
    bpy.ops.object.shade_smooth()
    o.select_set(False)
    o.data.materials.append(common.painted_material("skin_" + name, SKIN, roughness=0.55, edge_highlight=0.0,
                                                    cavity_darken=0.35))
    return o


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--types", default="male,female")
    ap.add_argument("--faces", default="neutral")
    ap.add_argument("--voxel", type=float, default=0.0015)
    ap.add_argument("--hair", default="", help="comma-separated hair styles: one row each (with --faces first face)")
    ap.add_argument("--beard", default="", help="a beard style shown with every row")
    ap.add_argument("--tris", type=int, default=2400)
    ap.add_argument("--cell", type=int, default=360)
    ap.add_argument("--samples", type=int, default=24)
    ap.add_argument("--dist", type=float, default=1.15, help="camera distance (smaller: closer)")
    ap.add_argument("--dense-only", action="store_true", help="only the dense surface's three views")
    args = ap.parse_args(argv)
    common.reset_scene()
    scene = bpy.context.scene
    common.setup_lighting("dusk_grim")
    fill = bpy.data.objects.new("fill", bpy.data.lights.new("fill", type="SUN"))
    fill.data.energy = 1.8
    fill.rotation_euler = (math.radians(70), 0, math.radians(25))
    scene.collection.objects.link(fill)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.lens = 85
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = "AgX"
    scene.world.color = (0.08, 0.085, 0.1)
    scene.render.resolution_x = scene.render.resolution_y = args.cell
    from PIL import Image, ImageDraw
    rows = []
    for t in [x for x in args.types.split(",") if x]:
        combos = [(fc, "") for fc in args.faces.split(",") if fc]
        if args.hair:
            combos = [(combos[0][0], h) for h in args.hair.split(",") if h]
        for face, style in combos:
            (verts, faces), j = head_mesh(t, face, args.voxel)
            objs = [mesh_obj(f"{t}_{face}_{style}_hi", verts, faces, 0)]
            paint_eyes(objs[0], j, t)
            if not args.dense_only:
                objs.append(mesh_obj(f"{t}_{face}_{style}_lo", verts, faces, args.tris))
            extras = []
            for kind, sty in (("hair", style), ("beard", args.beard if t == "male" else "")):
                if not sty or sty == "none":
                    continue
                hv, hf = hair.build_mesh(j, t, sty, beard=kind == "beard")
                ho = mesh_obj(f"{t}_{kind}_{sty}", hv, hf, 0)
                ho.data.materials.clear()
                ho.data.materials.append(common.painted_material(f"hair_{sty}", "#3b2a1e", roughness=0.5,
                                                                 edge_highlight=0.15, cavity_darken=0.6))
                extras.append(ho)
            centre = Vector(j["head"]) + Vector((0, -0.01, 0.1))
            tiles = []
            for o in objs:
                for other in bpy.data.objects:
                    if other.type == "MESH":
                        other.hide_render = other is not o and other not in extras
                for yaw in (0, 35, 90):
                    a = math.radians(yaw)
                    d = Vector((math.sin(a), -math.cos(a), 0.05)).normalized()
                    cam.location = centre + d * args.dist
                    cam.rotation_euler = (centre - cam.location).to_track_quat("-Z", "Y").to_euler()
                    tmp = args.out.with_name(f"_{args.out.stem}_{o.name}_{yaw}.png")
                    tmp.parent.mkdir(parents=True, exist_ok=True)
                    scene.render.filepath = str(tmp)
                    bpy.ops.render.render(write_still=True)
                    tiles.append(tmp)
            game = f" | game {len(objs[1].data.polygons)} tris" if len(objs) > 1 else ""
            rows.append((f"{t} {face} {style}: dense {len(faces)} tris{game}", tiles))
            for o in objs + extras:
                bpy.data.objects.remove(o, do_unlink=True)
    c = args.cell
    sheet = Image.new("RGB", (c * max(len(r[1]) for r in rows), (c + 22) * len(rows)), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    for r, (label, tiles) in enumerate(rows):
        draw.text((6, r * (c + 22) + 5), label, fill=(220, 220, 220))
        for i, p in enumerate(tiles):
            sheet.paste(Image.open(p).convert("RGB"), (i * c, r * (c + 22) + 22))
            p.unlink()
    sheet.save(args.out)
    print("saved", args.out)


if __name__ == "__main__":
    main()
