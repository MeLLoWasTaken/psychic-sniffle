"""Build the pipeline test prop: a chunky, iron-banded wooden crate.

Usage:
  python3 tools/blender/build_test_prop.py --spec data/assets/test_crate.json --previews previews/test_crate
  blender -b -P tools/blender/build_test_prop.py -- --spec data/assets/test_crate.json
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
import common  # noqa: E402
import kit  # noqa: E402


def box(name, size, loc, rot=(0, 0, 0), bevel=0.0, segments=1, mat=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    if bevel:
        m = o.modifiers.new("bevel", "BEVEL")
        m.width = bevel
        m.segments = segments
        m.limit_method = "ANGLE"
    if mat:
        o.data.materials.append(mat)
    return o


def rivet(loc, normal_axis, mat):
    rot = {"x": (0, math.pi / 2, 0), "y": (math.pi / 2, 0, 0), "z": (0, 0, 0)}[normal_axis]
    bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.028, depth=0.03, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.data.materials.append(mat)
    return o


def build(spec: dict) -> bpy.types.Object:
    rng = common.seeded_random(spec["seed"])
    s = spec["params"]["size_m"]
    h = s / 2
    pal = spec["palette"]
    wood = kit.kit_material("crate_wood", pal["wood"], roughness=0.85, mottle=0.15, mottle_scale=1.5)
    # Hand-painted style: metal is painted, not mirror-like, so keep metallic low.
    iron = kit.kit_material("crate_iron", pal["iron"], roughness=0.5, metallic=0.3, edge=0.55)

    parts = []
    # core block, slightly inset so planks sit proud of it
    parts.append(box("core", (s * 0.94, s * 0.94, s * 0.94), (0, 0, h), mat=wood))

    # planks: three per side face, each slightly wonky
    plank_w = s / 3
    for face, axis in (("+x", 0), ("-x", 0), ("+y", 1), ("-y", 1)):
        sign = 1 if face[0] == "+" else -1
        for i in range(3):
            off = -s / 2 + plank_w * (i + 0.5)
            jitter = rng.uniform(-0.012, 0.012)
            tilt = rng.uniform(-0.025, 0.025)
            if axis == 0:
                loc = (sign * (h - 0.02 + jitter), off, h)
                size = (0.06, plank_w * 0.94, s * 0.96)
                rot = (tilt, 0, 0)
            else:
                loc = (off, sign * (h - 0.02 + jitter), h)
                size = (plank_w * 0.94, 0.06, s * 0.96)
                rot = (0, tilt, 0)
            parts.append(box(f"plank_{face}_{i}", size, loc, rot, bevel=0.012, segments=1, mat=wood))
    # lid planks
    for i in range(3):
        off = -s / 2 + plank_w * (i + 0.5)
        parts.append(box(f"lid_{i}", (plank_w * 0.94, s * 0.98, 0.07), (off, 0, s - 0.01 + rng.uniform(-0.01, 0.01)),
                         (0, rng.uniform(-0.02, 0.02), 0), bevel=0.014, mat=wood))

    # iron bands around the top and bottom, thick and chunky
    band_t, band_h = 0.035, 0.11
    for z in (0.12, s - 0.12):
        parts.append(box(f"band_x_{z:.2f}_a", (s + 0.1, band_t, band_h), (0, h + 0.03, z), bevel=0.008, mat=iron))
        parts.append(box(f"band_x_{z:.2f}_b", (s + 0.1, band_t, band_h), (0, -h - 0.03, z), bevel=0.008, mat=iron))
        parts.append(box(f"band_y_{z:.2f}_a", (band_t, s + 0.1, band_h), (h + 0.03, 0, z), bevel=0.008, mat=iron))
        parts.append(box(f"band_y_{z:.2f}_b", (band_t, s + 0.1, band_h), (-h - 0.03, 0, z), bevel=0.008, mat=iron))
        for x in (-s * 0.33, 0, s * 0.33):
            parts.append(rivet((x, -h - 0.05, z), "y", iron))
            parts.append(rivet((x, h + 0.05, z), "y", iron))
            parts.append(rivet((-h - 0.05, x, z), "x", iron))
            parts.append(rivet((h + 0.05, x, z), "x", iron))

    # vertical corner brackets
    for cx in (-1, 1):
        for cy in (-1, 1):
            parts.append(box(f"corner_{cx}_{cy}", (0.09, 0.09, s * 1.02), (cx * (h + 0.015), cy * (h + 0.015), h),
                             bevel=0.01, mat=iron))

    for o in parts:
        common.apply_all_modifiers(o)
        kit.clear_uvs(o)
        kit.set_tint(o, kit.random_tint(rng, 0.12, 0.04))  # each plank and band a little different
    crate = common.join_objects(parts, spec["id"])
    common.origin_to_feet(crate)
    bpy.ops.object.shade_auto_smooth(angle=math.radians(35))
    return crate


def main() -> None:
    args = common.parse_args("Build the pipeline test prop")
    spec = common.load_spec(args.spec)
    common.reset_scene()
    obj = build(spec)
    tris = common.triangle_count([obj])
    if args.previews:
        sheet = common.render_contact_sheet([obj], args.previews / f"{spec['id']}_sheet.png",
                                            engine=args.engine, cell=args.preview_size,
                                            title=f"{spec['id']}  {tris} tris")
        print(f"PREVIEW {sheet}")
    kit.bake_piece(obj, common.REPO / "previews" / "kit_textures", spec["id"], size=int(spec.get("texture_size", 512)))
    if args.previews:
        common.render_contact_sheet([obj], args.previews / f"{spec['id']}_baked.png", engine=args.engine,
                                    cell=args.preview_size, title="after bake (exported look)")
    out = common.export_glb(args.out or Path(spec["out"]), [obj])
    print(f"BUILT {spec['id']} tris={tris} -> {out}")


if __name__ == "__main__":
    main()
