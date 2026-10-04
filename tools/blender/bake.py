"""High-to-low texture bakes for the overhaul assets (backlog G-01, G-03).

A game mesh (low) gets a tangent-space normal map carrying the detail of a dense version of the
same surface (high): muscle definition on bodies; engraving, rivets, mail and stitching on armor.
Base color and roughness come from the low mesh's own painted materials, baked as kit.bake_piece
does, so the results load the same way in Godot (albedo, orm, normal PNGs beside the .glb).
"""
from __future__ import annotations

import math
from pathlib import Path

import bpy

import kit


def scale_islands(obj: bpy.types.Object, factor_of) -> int:
    """Scale UV islands about their centres by `factor_of(island centre in object space)` before
    packing, so the face (say) gets more texels than its area alone would give it."""
    import numpy as np
    me = obj.data
    uv = me.uv_layers.active.data
    n_loops = len(me.loops)
    co = np.empty(n_loops * 2, dtype=np.float32)
    uv.foreach_get("uv", co)
    co = co.reshape(-1, 2)
    # islands: faces joined where they share an edge whose two loops carry the same UVs
    parent = list(range(len(me.polygons)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    edge_faces: dict = {}
    for poly in me.polygons:
        ls = list(poly.loop_indices)
        for i, li in enumerate(ls):
            lj = ls[(i + 1) % len(ls)]
            va, vb = me.loops[li].vertex_index, me.loops[lj].vertex_index
            key = (min(va, vb), max(va, vb))
            uvs = {va: tuple(np.round(co[li], 6)), vb: tuple(np.round(co[lj], 6))}
            if key in edge_faces:
                other, ouv = edge_faces[key]
                if ouv == uvs:
                    ra, rb = find(poly.index), find(other)
                    if ra != rb:
                        parent[ra] = rb
            else:
                edge_faces[key] = (poly.index, uvs)
    islands: dict = {}
    for poly in me.polygons:
        islands.setdefault(find(poly.index), []).append(poly)
    scaled = 0
    for polys in islands.values():
        centre = sum((p.center for p in polys), polys[0].center * 0) / len(polys)
        f = float(factor_of(centre))
        if abs(f - 1.0) < 1e-3:
            continue
        loops = [li for p in polys for li in p.loop_indices]
        c = co[loops].mean(axis=0)
        co[loops] = c + (co[loops] - c) * f
        scaled += 1
    uv.foreach_set("uv", co.ravel())
    return scaled


def unwrap(obj: bpy.types.Object, angle_deg: float = 66.0, margin: float = 0.004, detail=None) -> None:
    """Smart UV project and pack, islands scaled by their surface area (times `detail(centre)`
    when given: a texel-density factor per island)."""
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    me = obj.data
    while me.uv_layers:
        me.uv_layers.remove(me.uv_layers[0])
    me.uv_layers.new(name="UVMap")
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle_deg), island_margin=margin)
    if detail is not None:
        bpy.ops.object.mode_set(mode="OBJECT")
        scale_islands(obj, detail)
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, scale=True, margin=margin)
    bpy.ops.object.mode_set(mode="OBJECT")


def bake_normal(low: bpy.types.Object, high: bpy.types.Object, image: bpy.types.Image,
                extrusion: float = 0.012, max_ray: float = 0.03, samples: int = 4) -> None:
    """Bake `high`'s shading normals into `image` on `low`'s UVs (selected to active)."""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    prev_samples = scene.cycles.samples
    scene.cycles.samples = samples
    bake = scene.render.bake
    bake.use_selected_to_active = True
    bake.cage_extrusion = extrusion
    bake.max_ray_distance = max_ray
    bake.normal_space = "TANGENT"
    bake.margin = 8
    bake.use_clear = True
    added = []
    for mat in [m for m in low.data.materials if m]:
        nt = mat.node_tree
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = image
        nt.nodes.active = node
        added.append((mat, node))
    if not high.data.materials:
        high.data.materials.append(low.data.materials[0])
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type="NORMAL")
    bake.use_selected_to_active = False
    scene.cycles.samples = prev_samples
    tame_normals(image)
    for mat, node in added:
        mat.node_tree.nodes.remove(node)


def tame_normals(image: bpy.types.Image, min_z: float = 0.45) -> int:
    """Flatten texels whose baked normal leans further than `min_z` allows from the surface:
    rays that hit the far side of a deep cavity (nostrils, a mouth line, gaps between plates)
    leave near-sideways normals that render as black smudges on the game mesh."""
    import numpy as np
    w, h = image.size
    px = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(px)
    px = px.reshape(-1, 4)
    n = px[:, :3] * 2.0 - 1.0
    bad = n[:, 2] < min_z
    if bad.any():
        t = np.clip((min_z - n[bad, 2]) / min_z, 0.0, 1.0)[:, None]
        flat = np.array([0.0, 0.0, 1.0])
        m = n[bad] * (1 - t) + flat * t
        m /= np.linalg.norm(m, axis=1, keepdims=True)
        px[bad, :3] = m * 0.5 + 0.5
        image.pixels.foreach_set(px.ravel())
        image.update()
    return int(bad.sum())


def bake_asset(low: bpy.types.Object, high: bpy.types.Object | None, out_dir: Path, name: str,
               size: int = 2048, samples: int = 24, detail=None) -> bpy.types.Material:
    """Unwrap `low`, bake albedo and roughness from its painted materials (kit.bake_piece) and,
    when `high` is given, a normal map from it; the low mesh ends with one plain material."""
    out_dir.mkdir(parents=True, exist_ok=True)
    unwrap(low, detail=detail)
    normal = None
    if high is not None:
        normal = bpy.data.images.new(f"{name}_normal", size, size, alpha=False)
        normal.colorspace_settings.name = "Non-Color"
        bake_normal(low, high, normal)
        normal.filepath_raw = str(out_dir / f"{normal.name}.png")
        normal.file_format = "PNG"
        normal.save()
        high.hide_render = True  # it overlaps the low surface: left visible it shadows the albedo's occlusion
    kit.bake_piece(low, out_dir, name, size=size, samples=samples, bevel_normal=0.0, keep_uvs=True)
    mat = low.data.materials[0]
    if normal is not None:
        nt = mat.node_tree
        bsdf = nt.nodes["Principled BSDF"]
        t_nrm = nt.nodes.new("ShaderNodeTexImage")
        t_nrm.image = normal
        nmap = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(t_nrm.outputs["Color"], nmap.inputs["Color"])
        nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    return mat
