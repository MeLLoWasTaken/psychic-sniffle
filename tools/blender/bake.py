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


def unwrap(obj: bpy.types.Object, angle_deg: float = 66.0, margin: float = 0.004) -> None:
    """Smart UV project and pack, islands scaled by their surface area."""
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
    for mat, node in added:
        mat.node_tree.nodes.remove(node)


def bake_asset(low: bpy.types.Object, high: bpy.types.Object | None, out_dir: Path, name: str,
               size: int = 2048, samples: int = 24) -> bpy.types.Material:
    """Unwrap `low`, bake albedo and roughness from its painted materials (kit.bake_piece) and,
    when `high` is given, a normal map from it; the low mesh ends with one plain material."""
    out_dir.mkdir(parents=True, exist_ok=True)
    unwrap(low)
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
