"""High-detail environment pieces (backlog E-01; docs/DESIGN.md Budgets, 2026-10-04).

A kit piece is first built as before, from bevelled blocks, lathed shapes and struts. With
`params.detail = "sculpted"` in its asset spec, every part is then given a dense, sculpted
version (the normal map's source) and a game version reduced from it:

- stone: the block is remeshed at about 1 cm and its surface broken up: chips knocked out of
  the edges and corners (deepest where two faces meet), a lumpy face, and fine pitting;
- wood: grain running along the timber, softened edges and splits near the ends;
- iron: hammer dents and slightly rounded edges;
- anything else (mortar beds, rope, cloth, emissive parts) is kept as built.

The game mesh's triangles are shared out by surface area so the piece lands on its budget
(`params.target_tris`, or the middle of its `tri_budget`), and normal, colour and roughness
maps are baked from the dense version (tools/blender/bake.py).
"""
from __future__ import annotations

import math

import bpy
import numpy as np
from mathutils import Vector, noise

import common

STONE = {"stone", "flag", "stone_worn", "quoin"}
WOOD = {"wood", "dark_wood", "timber", "boards"}
IRON = {"iron"}


def kind_of(obj: bpy.types.Object) -> str:
    names = {m.name.split(".")[0] for m in obj.data.materials if m}
    if names & STONE:
        return "stone"
    if names & WOOD:
        return "wood"
    if names & IRON:
        return "iron"
    return "none"


def _arrays(obj):
    me = obj.data
    n = len(me.vertices)
    co = np.empty(n * 3, dtype=np.float32)
    me.vertices.foreach_get("co", co)
    nr = np.empty(n * 3, dtype=np.float32)
    me.vertices.foreach_get("normal", nr)
    return co.reshape(-1, 3), nr.reshape(-1, 3)


def sharp_edges(obj: bpy.types.Object, min_deg: float = 25.0):
    """End points (A, B) of the edges where the surface turns by more than `min_deg`."""
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    a, b = [], []
    lim = math.radians(min_deg)
    for e in bm.edges:
        if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > lim:
            a.append(e.verts[0].co[:])
            b.append(e.verts[1].co[:])
        elif len(e.link_faces) < 2:
            a.append(e.verts[0].co[:])
            b.append(e.verts[1].co[:])
    bm.free()
    return np.array(a, float).reshape(-1, 3), np.array(b, float).reshape(-1, 3)


def edge_distance(P: np.ndarray, A: np.ndarray, B: np.ndarray, chunk: int = 4000) -> np.ndarray:
    """Distance from each point to the nearest segment A[i]-B[i]."""
    if len(A) == 0:
        return np.full(len(P), 1.0)
    out = np.empty(len(P))
    ab = B - A
    L2 = np.maximum((ab * ab).sum(1), 1e-12)
    for i in range(0, len(P), chunk):
        p = P[i:i + chunk, None, :]
        t = np.clip(((p - A[None]) * ab[None]).sum(-1) / L2[None], 0, 1)
        q = A[None] + ab[None] * t[..., None]
        out[i:i + chunk] = np.sqrt(((p - q) ** 2).sum(-1)).min(1)
    return out


def _corner_weight(P: np.ndarray, A: np.ndarray, B: np.ndarray, r: float = 0.08) -> np.ndarray:
    """How close each point is to a corner: 1 where two or more sharp edges' ends meet near it."""
    if len(A) == 0:
        return np.zeros(len(P))
    ends = np.concatenate([A, B])
    # corners: edge end points shared by three or more sharp edges (rounded to 1 mm)
    key = np.round(ends, 3)
    uniq, counts = np.unique(key, axis=0, return_counts=True)
    corners = uniq[counts >= 3]
    if len(corners) == 0:
        return np.zeros(len(P))
    d = np.min(np.linalg.norm(P[:, None, :] - corners[None, :, :], axis=2), axis=1)
    return np.exp(-(d / r) ** 2)


def _remesh(obj: bpy.types.Object, voxel: float) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    m = obj.modifiers.new("remesh", "REMESH")
    m.mode = "VOXEL"
    m.voxel_size = voxel
    m.adaptivity = 0.0
    bpy.ops.object.modifier_apply(modifier=m.name)


def _fbm(P: np.ndarray, scale: float, octaves: int = 4, seed: float = 0.0) -> np.ndarray:
    off = Vector((seed * 17.1, seed * 31.7, seed * 5.3))
    return np.array([noise.fractal(Vector(p) * scale + off, 0.6, 2.0, octaves) for p in P])


def _cells(P: np.ndarray, scale: float, seed: float = 0.0) -> np.ndarray:
    off = Vector((seed * 11.3, seed * 7.9, seed * 23.1))
    return np.array([noise.cell(Vector(p) * scale + off) for p in P])


def sculpt(obj: bpy.types.Object, kind: str, rng, voxel: float = 0.01) -> bpy.types.Object:
    """A dense, sculpted copy of `obj` (see the module docstring for what each kind gets)."""
    hi = obj.copy()
    hi.data = obj.data.copy()
    hi.name = f"{obj.name}_high"
    bpy.context.scene.collection.objects.link(hi)
    if kind == "none":
        return hi
    A, B = sharp_edges(obj, 25.0 if kind != "wood" else 35.0)
    size = max(obj.dimensions)
    _remesh(hi, min(voxel, max(size / 40.0, 0.004)))
    P, N = _arrays(hi)
    seed = rng.uniform(0, 100)
    e = edge_distance(P, A, B)
    if kind == "stone":
        # chips knocked out along the edges (big shallow scallops, deepest where faces meet),
        # corners worn round, a lumpy face and fine pitting
        edge_w = np.exp(-(e / 0.06) ** 2)
        cells = _cells(P, 4.5, seed)
        chip = np.clip((cells - 0.35) / 0.65, 0, 1) ** 0.8 * 0.045 + 0.008
        corner = np.exp(-(e / 0.12) ** 2) * np.clip(_corner_weight(P, A, B), 0, 1) * 0.02
        lump = _fbm(P, 1.6, 3, seed) * 0.012
        pit = _fbm(P, 22.0, 2, seed + 1) * 0.0022
        disp = -edge_w * chip * (0.55 + 0.45 * _fbm(P, 7.0, 2, seed + 2)) - corner + lump + pit
    elif kind == "wood":
        # grain along the timber's long axis (the first principal axis of its vertices)
        c = P - P.mean(0)
        axis = np.linalg.svd(c[:: max(1, len(c) // 4000)], full_matrices=False)[2][0]
        along = c @ axis
        q = c - along[:, None] * axis[None]
        warp = _fbm(P * np.array([1, 1, 1]), 3.0, 2, seed) * 0.02
        ring = np.sin((np.linalg.norm(q, axis=1) + warp) * 260.0)
        grain = (ring > 0.6) * 0.0012 + 0.0006 * ring
        ends = np.clip((np.abs(along) - (np.abs(along).max() - 0.25)) / 0.25, 0, 1)
        split = (np.abs(np.sin(np.arctan2(q[:, 1], q[:, 0]) * 3 + seed)) < 0.06) * ends * 0.006
        edge_w = np.exp(-(e / 0.02) ** 2)
        disp = -grain - split - edge_w * 0.004 * (0.5 + 0.5 * _fbm(P, 12.0, 2, seed))
    else:  # iron
        cells = _cells(P, 30.0, seed)
        disp = -0.0012 * cells - np.exp(-(e / 0.01) ** 2) * 0.0015
    P = P + N * disp[:, None].astype(np.float32)
    hi.data.vertices.foreach_set("co", P.astype(np.float32).ravel())
    hi.data.update()
    return hi


def reduce(obj: bpy.types.Object, tris: int) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_add(type="TRIANGULATE")
    bpy.ops.object.modifier_apply(modifier=obj.modifiers[-1].name)
    n = len(obj.data.polygons)
    if n > tris:
        d = obj.modifiers.new("d", "DECIMATE")
        d.ratio = max(tris / n, 0.001)
        bpy.ops.object.modifier_apply(modifier=d.name)


def _area(obj) -> float:
    return sum(p.area for p in obj.data.polygons)


def build_hd(parts: list, spec: dict, rng):
    """Sculpt and reduce every part; return (low, high) objects, the low one on budget."""
    budget = spec.get("tri_budget", {})
    target = int(spec.get("params", {}).get("target_tris", (budget.get("min", 5000) + budget.get("max", 25000)) / 2))
    voxel = float(spec.get("params", {}).get("sculpt_voxel", 0.01))
    kinds = [kind_of(o) for o in parts]
    for o in parts:
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.modifier_add(type="TRIANGULATE")
        bpy.ops.object.modifier_apply(modifier=o.modifiers[-1].name)
    fixed = sum(len(o.data.polygons) for o, k in zip(parts, kinds) if k == "none")
    areas = [(_area(o) ** 0.85 if k != "none" else 0.0) for o, k in zip(parts, kinds)]
    total = max(sum(areas), 1e-9)
    left = max(target - fixed, len(parts) * 40)
    lows, highs = [], []
    for o, k, a in zip(parts, kinds, areas):
        hi = sculpt(o, k, rng, voxel)
        highs.append(hi)
        if k == "none":
            lows.append(o)
            continue
        lo = hi.copy()
        lo.data = hi.data.copy()
        lo.name = o.name
        bpy.context.scene.collection.objects.link(lo)
        reduce(lo, max(40, int(left * a / total)))
        _copy_tint(o, lo)
        lows.append(lo)
        bpy.data.objects.remove(o)
    low = common.join_objects(lows, spec["id"])
    high = common.join_objects(highs, f"{spec['id']}_high")
    print(f"  {spec['id']}: sculpted {sum(k != 'none' for k in kinds)} of {len(parts)} parts, "
          f"{len(high.data.polygons)} dense -> {len(low.data.polygons)} triangles (target {target})", flush=True)
    return low, high


def _copy_tint(src: bpy.types.Object, dst: bpy.types.Object) -> None:
    """Carry the per-part colour variation (kit.set_tint's colour attribute) onto the new mesh."""
    import kit
    attr = src.data.color_attributes.get(kit.TINT_ATTR)
    if attr is None or len(attr.data) == 0:
        return
    kit.set_tint(dst, attr.data[0].color[:3])
