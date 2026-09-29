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


def main() -> None:
    args = common.parse_args("Build a bare parametric body",
                             lambda p: p.add_argument("--pose-test", action="store_true"))
    spec = common.load_spec(args.spec)
    common.reset_scene()
    build = spec["body_build"]
    body = humanoid.build_body_sdf(build, spec["id"], target_tris=int(spec.get("params", {}).get("target_tris", 9000)))
    body.data.materials.append(common.painted_material("skin", spec["palette"]["skin"], roughness=0.7,
                                                       edge_highlight=0.0, cavity_darken=0.5))
    rig = humanoid.build_armature(build, f"{spec['id']}_rig")
    humanoid.bind(body, rig)
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
    common.flatten_materials_for_export([body])
    out = common.export_glb(args.out or Path(spec["out"]), [body, rig])
    print(f"BUILT {spec['id']} -> {out}")


if __name__ == "__main__":
    main()
