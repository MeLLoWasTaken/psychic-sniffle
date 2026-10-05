#!/usr/bin/env python3
"""Validate exported .glb assets against their spec in data/assets.

Checks (docs/DESIGN.md, "Asset pipeline", Validation):
  - triangle count inside the spec's tri_budget
  - metric scale: bounding box within sane limits for the asset kind
  - origin at the feet: lowest point at z = 0 (within 1 cm), centred on x and y (pivot "face":
    centred on x, with the mounting face on y = 0; pivot "axis": the origin on the collider's axis,
    the bounding box within 15 cm of it)
  - no non-manifold edges (holes or edges shared by more than two faces)
  - every image texture is square-free power-of-two sized
  - characters only: required bone names and animation clips (list grows with backlog M1-16/M1-21)

Usage:
  python3 tools/validate_asset.py            # every asset spec whose .glb exists
  python3 tools/validate_asset.py test_crate # one asset
Exit code 0 when all pass, 1 otherwise.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import bpy  # must come first: it makes the bmesh module importable
import bmesh

REPO = Path(__file__).resolve().parent.parent

SIZE_LIMITS_M = {  # max bounding-box edge per kind
    "character": 3.5, "weapon": 3.0, "prop": 12.0, "environment_kit": 60.0, "icon": 5.0, "test": 5.0,
    "piece": 2.5,
}
sys.path.insert(0, str(REPO / "tools" / "blender"))
import humanoid  # noqa: E402  (standard skeleton, docs/ART_BIBLE.md)

REQUIRED_BONES: list[str] = humanoid.BONE_NAMES
import animation  # noqa: E402  (animation sets, backlog M1-21)


def _is_pow2(n: int) -> bool:
    return n > 0 and (n & (n - 1)) == 0


def check(spec: dict) -> list[str]:
    errors: list[str] = []
    glb = REPO / spec["out"]
    if not glb.exists():
        return [f"{glb.relative_to(REPO)} does not exist (run the builder first)"]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(glb))
    if spec["kind"] == "animation":
        return check_animation_library(spec)
    # Blender's glTF importer adds display-shape meshes for bones (an "Icosphere"); they are not
    # part of the file, so skip every mesh used as a bone custom shape.
    bone_shapes = {pb.custom_shape for o in bpy.data.objects if o.type == "ARMATURE"
                   for pb in o.pose.bones if pb.custom_shape}
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and o not in bone_shapes]
    if not meshes:
        return ["no meshes in file"]

    deps = bpy.context.evaluated_depsgraph_get()
    tris = 0
    xs, ys, zs = [], [], []
    non_manifold = 0
    for o in meshes:
        ev = o.evaluated_get(deps)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        tris += len(me.loop_triangles)
        for v in me.vertices:
            w = o.matrix_world @ v.co
            xs.append(w.x); ys.append(w.y); zs.append(w.z)
        bm = bmesh.new()
        bm.from_mesh(me)
        # glTF splits vertices along hard edges to store sharp normals; weld them back before
        # checking, or every hard edge would look like a hole.
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        non_manifold +=sum(1 for e in bm.edges if not e.is_manifold)
        bm.free()
        ev.to_mesh_clear()

    budget = spec["tri_budget"]
    if not budget["min"] <= tris <= budget["max"]:
        errors.append(f"triangles {tris} outside budget {budget['min']}..{budget['max']}")

    size = max(max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))
    limit = SIZE_LIMITS_M[spec["kind"]]
    if size > limit:
        errors.append(f"largest dimension {size:.2f} m exceeds {limit} m for kind '{spec['kind']}' (check scale)")
    if size < 0.05:
        errors.append(f"largest dimension {size:.3f} m is implausibly small (check scale)")

    grip_pivot = spec.get("pivot", "centre") == "grip"
    piece = spec["kind"] == "piece"   # armor and appearance pieces sit where they are worn (G-02, G-03)
    if piece:
        if min(zs) < -0.01 or max(zs) > 2.1:
            errors.append(f"piece spans z {min(zs):.2f}..{max(zs):.2f}; it should sit on a standing character")
    elif grip_pivot:
        if not (min(zs) < 0 < max(zs)):
            errors.append(f"grip pivot: the origin should be inside the weapon, but z spans {min(zs):.2f}..{max(zs):.2f}")
    elif abs(min(zs)) > 0.01:
        errors.append(f"lowest point at z = {min(zs):.3f} m; origin must be at the feet (z = 0)")
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    face_pivot = spec.get("pivot", "centre") == "face"
    # pivot "axis": built around its collider's axis (the origin), so asymmetric details (shackles,
    # a ladder, a hanging cage) may move the bounding box a little off it
    tol = 0.15 if spec.get("pivot", "centre") == "axis" else 0.05
    if piece:
        tol = 0.75   # sits where worn: an off-hand shield hangs half a metre out on the forearm
    if abs(cx) > tol or (abs(cy) > tol and not face_pivot):
        errors.append(f"not centred: bounding-box centre at x={cx:.3f}, y={cy:.3f}")
    if face_pivot and not (min(ys) <= 0.15 and max(ys) >= -0.15):
        errors.append(f"face pivot: the mounting face should lie on y = 0, but y spans {min(ys):.2f}..{max(ys):.2f}")

    if non_manifold:
        errors.append(f"{non_manifold} non-manifold edges")

    for img in bpy.data.images:
        w, h = img.size
        if w and h and not (_is_pow2(w) and _is_pow2(h)):
            errors.append(f"texture '{img.name}' is {w}x{h}; sizes must be powers of two")

    if piece:  # skinned to the standard skeleton, so the game can put it on any body of its build
        bones = {b.name for o in bpy.data.objects if o.type == "ARMATURE" for b in o.data.bones}
        if not bones.issubset(set(REQUIRED_BONES)) or not bones:
            errors.append("a piece needs the standard skeleton (and no other bones)")
    if spec["kind"] == "character":
        bones = {b.name for o in bpy.data.objects if o.type == "ARMATURE" for b in o.data.bones}
        for b in REQUIRED_BONES:
            if b not in bones:
                errors.append(f"missing bone '{b}'")
        # clips live in the shared library for the body build (kind "animation")
        libs = [json.loads(p.read_text()) for p in (REPO / "data" / "assets").glob("*.json")]
        if not any(a["kind"] == "animation" and a.get("body_build") == spec.get("body_build") for a in libs):
            errors.append(f"no animation library for body build '{spec.get('body_build')}'")

    print(f"  {spec['id']}: {tris} tris, {size:.2f} m, {non_manifold} non-manifold edges")
    return errors


def check_animation_library(spec: dict) -> list[str]:
    """Skeleton, required clips and clip lengths of a shared animation library."""
    errors = []
    bones = {b.name for o in bpy.data.objects if o.type == "ARMATURE" for b in o.data.bones}
    for b in REQUIRED_BONES:
        if b not in bones:
            errors.append(f"missing bone '{b}'")
    anim = animation.load_set(spec["params"]["set"])
    fps = bpy.context.scene.render.fps / bpy.context.scene.render.fps_base
    actions = {a.name: a for a in bpy.data.actions}
    clips = sorted(set(animation.REQUIRED_CLIPS) | set(anim["clips"]))
    wanted = [(c, None) for c in clips] + [(c, h) for h in animation.hold_variants(anim) for c in clips]
    for clip, hold in wanted:
        name = animation.variant_name(clip, hold)
        act = actions.get(name)
        if act is None:
            errors.append(f"missing animation '{name}'")
            continue
        if clip in anim["clips"]:
            start, end = act.frame_range
            length = (end - start) / fps
            want = (animation.frame_count(anim["clips"][clip], anim["fps"]) - 1) / anim["fps"]
            if abs(length - want) > 1.0 / anim["fps"]:
                errors.append(f"animation '{name}' lasts {length:.3f} s, expected {want:.3f} s")
    print(f"  {spec['id']}: {len(actions)} clips, {len(bones)} bones")
    return errors


def main(argv: list[str]) -> int:
    specs = sorted((REPO / "data" / "assets").glob("*.json"))
    if argv:
        specs = [p for p in specs if p.stem in argv]
    failed = 0
    checked = 0
    for path in specs:
        spec = json.loads(path.read_text())
        if not (REPO / spec["out"]).exists() and not argv:
            continue
        checked += 1
        errs = check(spec)
        for e in errs:
            print(f"ERROR assets/{path.name}: {e}")
        failed += bool(errs)
    if failed:
        print(f"FAIL asset validation: {failed} of {checked} asset(s) failed")
        return 1
    print(f"PASS asset validation: {checked} asset(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
