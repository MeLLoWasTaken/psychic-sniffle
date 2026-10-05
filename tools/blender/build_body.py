"""Build a bare parametric body on the standard skeleton (backlog M1-16).

Usage:
  python3 tools/blender/build_body.py --spec data/assets/body_heavy.json --previews previews/body_heavy
Optional:
  --pose-test   also render the body with arms raised and a knee bent, to check skin weights
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
import anatomy  # noqa: E402
import appearance_bake  # noqa: E402
import numpy as np  # noqa: E402
import bake  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402


def pose_test(rig: bpy.types.Object) -> None:
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="POSE")
    pb = rig.pose.bones
    pb["upperarm_l"].rotation_mode = "XYZ"
    pb["upperarm_l"].rotation_euler = (0, math.radians(-70), 0)
    pb["forearm_l"].rotation_mode = "XYZ"
    pb["forearm_l"].rotation_euler = (math.radians(-60), 0, 0)
    pb["thigh_r"].rotation_mode = "XYZ"
    pb["thigh_r"].rotation_euler = (math.radians(-50), 0, 0)
    pb["calf_r"].rotation_mode = "XYZ"
    pb["calf_r"].rotation_euler = (math.radians(70), 0, 0)
    pb["spine"].rotation_mode = "XYZ"
    pb["spine"].rotation_euler = (0, 0, math.radians(15))
    bpy.ops.object.mode_set(mode="OBJECT")


def add_face_keys(body: bpy.types.Object, body_type: str) -> None:
    """One shape key per face preset (data/appearance/faces.json) on the head's vertices (G-02)."""
    import json
    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[body_type]).items()}
    co = np.array([v.co[:] for v in body.data.vertices])
    neck_z = float(j["neck"][2])
    body.shape_key_add(name="Basis", from_mix=False)
    faces = json.loads((common.REPO / "data" / "appearance" / "faces.json").read_text())["options"]
    for opt in faces:
        if not opt.get("params"):
            continue  # the neutral face is the basis
        off = anatomy.face_offsets(j, body_type, opt["id"], co, neck_z)
        key = body.shape_key_add(name=f"face_{opt['id']}", from_mix=False)
        key.data.foreach_set("co", (co + off).astype(np.float32).ravel())
        print(f"  face_{opt['id']}: {int((np.linalg.norm(off, axis=1) > 1e-4).sum())} vertices move, "
              f"up to {np.linalg.norm(off, axis=1).max() * 1000:.1f} mm", flush=True)


def main() -> None:
    args = common.parse_args("Build a bare parametric body",
                             lambda p: p.add_argument("--pose-test", action="store_true"))
    spec = common.load_spec(args.spec)
    common.reset_scene()
    build = spec["body_build"]
    params = spec.get("params", {})
    high = None
    if build in anatomy.TYPES:  # overhaul body (G-01): dense source for a baked normal map
        body, high = humanoid.build_body_anatomy(build, spec["id"], target_tris=int(params.get("target_tris", 14000)),
                                                 voxel=float(params.get("voxel", 0.003)),
                                                 head_share=float(params.get("head_share", 0.0)))
    else:
        body = humanoid.build_body_sdf(build, spec["id"], target_tris=int(params.get("target_tris", 9000)))
    body.data.materials.append(common.painted_material("skin", spec["palette"]["skin"], roughness=0.7,
                                                       edge_highlight=0.0, cavity_darken=0.5))
    if high is not None:
        size = int(spec.get("texture_size", 2048))
        neck_z = humanoid.joints(humanoid.BUILDS[build])["neck"].z
        # the face is seen close: its islands get 2.5 times the texels their area would give
        bake.bake_asset(body, high, (common.REPO / spec["out"]).parent, spec["id"], size=size,
                        detail=lambda c: 2.5 if c.z > neck_z else 1.0, cavity=float(params.get("cavity", 1.0)))
        bpy.data.objects.remove(high)
        j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[build]).items()}
        appearance_bake.write_masks(body, j, build, (common.REPO / spec["out"]).parent, spec["id"], size=size,
                                    albedo=bpy.data.images[f"{spec['id']}_albedo"])
    rig = humanoid.build_armature(build, f"{spec['id']}_rig")
    humanoid.bind(body, rig)
    if high is not None:
        add_face_keys(body, build)
    tris = common.triangle_count([body])
    print(f"BODY {spec['id']} build={build} tris={tris}")
    if args.previews:
        common.render_contact_sheet([body], args.previews / f"{spec['id']}_sheet.png", engine=args.engine,
                                    cell=args.preview_size, title=f"{spec['id']} {tris} tris")
        if args.pose_test:
            pose_test(rig)
            common.render_contact_sheet([body], args.previews / f"{spec['id']}_pose.png", engine=args.engine,
                                        cell=args.preview_size, title="pose test")
            bpy.context.view_layer.objects.active = rig
            bpy.ops.object.mode_set(mode="POSE")
            bpy.ops.pose.select_all(action="SELECT")
            bpy.ops.pose.transforms_clear()
            bpy.ops.object.mode_set(mode="OBJECT")
    if high is None:
        common.flatten_materials_for_export([body])
    out = common.export_glb(args.out or Path(spec["out"]), [body, rig])
    print(f"BUILT {spec['id']} -> {out}")


if __name__ == "__main__":
    main()
