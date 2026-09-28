"""Shared helpers for headless Blender build scripts.

Works both with the `bpy` Python module (cloud workspace: `python3 script.py ...`) and inside
a Blender binary (`blender -b -P script.py -- ...`).

Conventions (docs/DESIGN.md, "Asset pipeline"):
  - 1 Blender unit = 1 metre, origin at the feet (lowest point at z = 0).
  - Characters face -Y in Blender (Blender's front view); the glTF exporter converts to Godot axes.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from pathlib import Path

import bpy
from mathutils import Vector

REPO = Path(__file__).resolve().parents[2]

# Lighting presets shared with the game (map data "lighting_preset"). Values are starting points;
# keep them in sync with the matching Godot environment resources.
LIGHTING_PRESETS = {
    "dusk_grim": {
        "world_color": (0.030, 0.033, 0.045),
        "world_strength": 1.0,
        "key": {"energy": 3.2, "color": (1.0, 0.72, 0.48), "rotation_deg": (58, 0, 38)},
        "fill": {"energy": 0.6, "color": (0.45, 0.55, 0.85), "rotation_deg": (70, 0, 220)},
        "rim": {"energy": 4.5, "color": (0.85, 0.90, 1.0), "rotation_deg": (100, 0, 160)},
    },
}


# ----------------------------------------------------------------------------- arguments

def parse_args(description: str, extra: callable | None = None) -> argparse.Namespace:
    """Parse arguments after '--' (Blender binary) or all arguments (bpy module)."""
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--spec", type=Path, required=True, help="Asset spec JSON in data/assets")
    parser.add_argument("--out", type=Path, help="Override the spec's output .glb path")
    parser.add_argument("--previews", type=Path, help="Folder for preview renders")
    parser.add_argument("--engine", default="CYCLES", choices=["CYCLES", "BLENDER_EEVEE_NEXT", "BLENDER_WORKBENCH"])
    parser.add_argument("--preview-size", type=int, default=512, help="Pixel size of each contact-sheet cell")
    if extra:
        extra(parser)
    return parser.parse_args(argv)


def load_spec(path: Path) -> dict:
    path = path if path.is_absolute() else REPO / path
    return json.loads(path.read_text())


def seeded_random(seed: int) -> random.Random:
    return random.Random(seed)


# ----------------------------------------------------------------------------- scene

def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0


def hex_to_linear(hex_color: str) -> tuple[float, float, float, float]:
    """sRGB hex string to linear RGBA, which is what Blender material inputs expect."""
    h = hex_color.lstrip("#")
    srgb = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb]
    return (*lin, 1.0)


def painted_material(name: str, hex_color: str, roughness: float = 0.8, metallic: float = 0.0,
                     edge_highlight: float = 0.25, cavity_darken: float = 0.45) -> bpy.types.Material:
    """Stylized material: base color, lighter worn edges and darker crevices.

    Uses the Geometry 'Pointiness' output (Cycles only) and Ambient Occlusion node. This is a
    placeholder for the full hand-painted texture bake (backlog M1-17); baked textures replace it.
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    bsdf = nodes["Principled BSDF"]
    base = hex_to_linear(hex_color)

    # Edge mask: compare a rounded (Bevel node) normal with the true normal. They differ only
    # near hard edges. Pointiness is per-vertex and marks whole low-poly parts, so it is not used.
    geo = nodes.new("ShaderNodeNewGeometry")
    bevel = nodes.new("ShaderNodeBevel")
    bevel.samples = 8
    bevel.inputs["Radius"].default_value = 0.012
    dot = nodes.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    links.new(bevel.outputs["Normal"], dot.inputs[0])
    links.new(geo.outputs["Normal"], dot.inputs[1])
    edge_ramp = nodes.new("ShaderNodeMapRange")
    edge_ramp.clamp = True
    edge_ramp.inputs["From Min"].default_value = 0.985
    edge_ramp.inputs["From Max"].default_value = 0.999
    edge_ramp.inputs["To Min"].default_value = 1.0
    edge_ramp.inputs["To Max"].default_value = 0.0
    links.new(dot.outputs["Value"], edge_ramp.inputs["Value"])

    ao = nodes.new("ShaderNodeAmbientOcclusion")
    ao.inputs["Distance"].default_value = 0.15

    base_rgb = nodes.new("ShaderNodeRGB")
    base_rgb.outputs[0].default_value = base

    lighten = nodes.new("ShaderNodeMix")
    lighten.data_type = "RGBA"
    lighten.blend_type = "SCREEN"
    links.new(base_rgb.outputs[0], lighten.inputs[6])
    lighten.inputs[7].default_value = (1.0, 0.95, 0.85, 1.0)
    edge_mul = nodes.new("ShaderNodeMath")
    edge_mul.operation = "MULTIPLY"
    edge_mul.inputs[1].default_value = edge_highlight
    links.new(edge_ramp.outputs["Result"], edge_mul.inputs[0])
    links.new(edge_mul.outputs[0], lighten.inputs["Factor"])

    darken = nodes.new("ShaderNodeMix")
    darken.data_type = "RGBA"
    darken.blend_type = "MULTIPLY"
    links.new(lighten.outputs[2], darken.inputs[6])
    links.new(ao.outputs["AO"], darken.inputs[7])
    darken.inputs["Factor"].default_value = cavity_darken

    links.new(darken.outputs[2], bsdf.inputs["Base Color"])
    bsdf.inputs["Base Color"].default_value = base
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    mat["flat_base_color"] = list(base)
    mat.diffuse_color = base
    return mat


def flatten_materials_for_export(objs) -> None:
    """Replace procedural base-color networks with the flat base color.

    glTF can only carry image textures or constant colors, so procedural shading exports as
    white. Until the hand-painted texture bake exists (backlog M1-17), export flat colors.
    """
    for o in objs:
        for mat in getattr(o.data, "materials", []):
            if mat is None or "flat_base_color" not in mat:
                continue
            bsdf = mat.node_tree.nodes["Principled BSDF"]
            for link in list(bsdf.inputs["Base Color"].links):
                mat.node_tree.links.remove(link)
            bsdf.inputs["Base Color"].default_value = tuple(mat["flat_base_color"])


def apply_all_modifiers(obj: bpy.types.Object) -> None:
    bpy.context.view_layer.objects.active = obj
    for mod in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)


def join_objects(objs: list[bpy.types.Object], name: str) -> bpy.types.Object:
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    return obj


def origin_to_feet(obj: bpy.types.Object) -> None:
    """Move geometry so the lowest point sits at z = 0 and the object is centred on x and y."""
    mesh = obj.data
    xs = [v.co.x for v in mesh.vertices]
    ys = [v.co.y for v in mesh.vertices]
    zs = [v.co.z for v in mesh.vertices]
    offset = Vector(((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, min(zs)))
    for v in mesh.vertices:
        v.co -= offset
    obj.location = (0, 0, 0)


def triangle_count(objs) -> int:
    total = 0
    deps = bpy.context.evaluated_depsgraph_get()
    for o in objs:
        if o.type != "MESH":
            continue
        mesh = o.evaluated_get(deps).to_mesh()
        mesh.calc_loop_triangles()
        total += len(mesh.loop_triangles)
        o.evaluated_get(deps).to_mesh_clear()
    return total


# ----------------------------------------------------------------------------- export

def export_glb(path: Path, objects: list[bpy.types.Object] | None = None) -> Path:
    path = path if path.is_absolute() else REPO / path
    path.parent.mkdir(parents=True, exist_ok=True)
    if objects is not None:
        bpy.ops.object.select_all(action="DESELECT")
        for o in objects:
            o.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=str(path),
        export_format="GLB",
        use_selection=objects is not None,
        export_apply=True,
        export_yup=True,
        export_animations=True,
    )
    return path


# ----------------------------------------------------------------------------- previews

def setup_lighting(preset: str = "dusk_grim") -> None:
    p = LIGHTING_PRESETS[preset]
    world = bpy.data.worlds.new(f"world_{preset}")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (*p["world_color"], 1.0)
    bg.inputs["Strength"].default_value = p["world_strength"]
    bpy.context.scene.world = world
    for role in ("key", "fill", "rim"):
        cfg = p[role]
        data = bpy.data.lights.new(f"light_{role}", type="SUN")
        data.energy = cfg["energy"]
        data.color = cfg["color"]
        data.angle = math.radians(3)
        light = bpy.data.objects.new(f"light_{role}", data)
        light.rotation_euler = [math.radians(a) for a in cfg["rotation_deg"]]
        bpy.context.scene.collection.objects.link(light)


def _bounds(objs) -> tuple[Vector, Vector]:
    pts = [o.matrix_world @ Vector(c) for o in objs if o.type == "MESH" for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


def render_contact_sheet(objs, out_png: Path, engine: str = "CYCLES", cell: int = 512,
                         preset: str = "dusk_grim", title: str = "") -> Path:
    """Render front, side, back and three-quarter views and tile them into one image."""
    from PIL import Image, ImageDraw

    out_png = out_png if out_png.is_absolute() else REPO / out_png
    out_png.parent.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    setup_lighting(preset)

    # ground plane to catch shadows
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.name = "_preview_ground"
    ground.data.materials.append(painted_material("_ground", "#2a2723", roughness=0.95, edge_highlight=0))

    lo, hi = _bounds(objs)
    center = (lo + hi) / 2
    size = max((hi - lo).length, 0.5)

    cam_data = bpy.data.cameras.new("_preview_cam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("_preview_cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam

    scene.render.engine = engine
    scene.render.resolution_x = cell
    scene.render.resolution_y = cell
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "AgX"
    if engine == "CYCLES":
        scene.cycles.device = "CPU"
        scene.cycles.samples = 32
        scene.cycles.use_denoising = True

    # (label, yaw in degrees around Z). Yaw 0 looks at the -Y face (the model's front).
    views = [("front", 0), ("side", 90), ("back", 180), ("three-quarter", 35)]
    tiles = []
    dist = size * 1.9
    for label, yaw in views:
        a = math.radians(yaw)
        direction = Vector((math.sin(a), -math.cos(a), 0.35)).normalized()
        cam.location = center + direction * dist
        look = center - cam.location
        cam.rotation_euler = look.to_track_quat("-Z", "Y").to_euler()
        tmp = out_png.with_name(f"_{out_png.stem}_{label}.png")
        scene.render.filepath = str(tmp)
        bpy.ops.render.render(write_still=True)
        tiles.append((label, tmp))

    sheet = Image.new("RGB", (cell * len(tiles), cell + 28), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    for i, (label, tmp) in enumerate(tiles):
        sheet.paste(Image.open(tmp).convert("RGB"), (i * cell, 28))
        draw.text((i * cell + 8, 8), label, fill=(220, 220, 220))
        tmp.unlink()
    if title:
        draw.text((cell * len(tiles) - 8 - 7 * len(title), 8), title, fill=(160, 160, 160))
    sheet.save(out_png)

    # remove preview-only objects so a later export is unaffected
    for o in (ground, cam):
        bpy.data.objects.remove(o, do_unlink=True)
    for o in [o for o in bpy.data.objects if o.name.startswith("light_")]:
        bpy.data.objects.remove(o, do_unlink=True)
    return out_png
