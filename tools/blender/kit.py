"""Helpers for modular environment kits (backlog M1-15): shaped stone, wood and iron parts,
a painted-look material, and a texture bake so the look survives export to glTF.

The painted look (docs/ART_BIBLE.md): base color with light from above, darkened crevices,
lightened edges, broad color variation between stones, and no fine noise. Blender computes
it with a procedural shader; `bake_piece` renders that shader into a base-color texture and
a roughness/metallic texture, then swaps in a plain material that glTF can carry.
"""
from __future__ import annotations

import math
import random
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector

import common

TINT_ATTR = "tint"  # per-part color variation, stored as a face-corner color attribute


# ----------------------------------------------------------------------------- materials

def kit_material(name: str, hex_color: str, roughness: float = 0.85, metallic: float = 0.0,
                 edge: float = 0.3, cavity: float = 0.55, top_light: float = 0.18, mottle: float = 0.12,
                 mottle_scale: float = 0.45, emission: float = 0.0, height_grad: float = 0.0,
                 height_m: float = 2.0, moss: float = 0.0, moss_color: str = "#4b5a33",
                 moss_scale: float = 1.4, damp: float = 0.0, damp_m: float = 1.5,
                 streaks: float = 0.0, soot: float = 0.0, soot_m: float = 4.0,
                 heat: float = 0.0, heat_color: str = "#3d2b36", heat_m: float = 0.0,
                 heat_scale: float = 1.2) -> bpy.types.Material:
    """Painted-look material. Every channel is broad and soft (no fine noise):
    - base color times the per-part tint attribute
    - mottle: very low-frequency brightness variation (mottle_scale is in 1/m)
    - top_light: surfaces facing up are lighter (light from above, baked in)
    - edge: worn, lighter edges (Bevel-normal comparison)
    - cavity: darker crevices (ambient occlusion)
    - height_grad: characters darken and cool toward the feet and brighten toward the head
      (object-space height over height_m), which draws the eye to the face and upper body
    Weathering for damp places (all 0 by default):
    - moss: broad patches of moss_color on upward-facing surfaces and in crevices
    - damp: darker, greener stone below a wavy line about damp_m above the piece's floor
    - streaks: long vertical wet stains running down the faces
    Weathering for hot, smoky places (all 0 by default, so other kits are unchanged):
    - soot: smoke-blackening that thickens toward soot_m above the piece's floor, on undersides
      and in long vertical streaks and broad blotches
    - heat: heat-tempered metal or scorched brick: broad patches of heat_color, everywhere or
      (heat_m > 0) rising to full strength at heat_m above the floor (a crucible's rim)
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    n, l = nt.nodes, nt.links
    bsdf = n["Principled BSDF"]
    base = common.hex_to_linear(hex_color)

    rgb = n.new("ShaderNodeRGB")
    rgb.outputs[0].default_value = base
    tint = n.new("ShaderNodeAttribute")
    tint.attribute_type = "GEOMETRY"
    tint.attribute_name = TINT_ATTR
    tinted = _mix(nt, "MULTIPLY", rgb.outputs[0], tint.outputs["Color"], 1.0)

    # mottle: object-space noise at a very large scale
    tex = n.new("ShaderNodeTexCoord")
    noise = n.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = mottle_scale
    noise.inputs["Detail"].default_value = 1.0
    noise.inputs["Roughness"].default_value = 0.3
    l.new(tex.outputs["Object"], noise.inputs["Vector"])
    mot = n.new("ShaderNodeMapRange")
    mot.inputs["To Min"].default_value = 1.0 - mottle
    mot.inputs["To Max"].default_value = 1.0 + mottle
    l.new(noise.outputs["Fac"], mot.inputs["Value"])
    mottled = _mix(nt, "MULTIPLY", tinted, _gray(nt, mot.outputs["Result"]), 1.0)

    # light from above: normal.z in [-1, 1] -> brightness
    geo = n.new("ShaderNodeNewGeometry")
    sep = n.new("ShaderNodeSeparateXYZ")
    l.new(geo.outputs["Normal"], sep.inputs["Vector"])
    up = n.new("ShaderNodeMapRange")
    up.inputs["From Min"].default_value = -1.0
    up.inputs["From Max"].default_value = 1.0
    up.inputs["To Min"].default_value = 1.0 - top_light
    up.inputs["To Max"].default_value = 1.0 + top_light
    l.new(sep.outputs["Z"], up.inputs["Value"])
    lit = _mix(nt, "MULTIPLY", mottled, _gray(nt, up.outputs["Result"]), 1.0)
    if height_grad > 0:
        pos = n.new("ShaderNodeSeparateXYZ")
        l.new(tex.outputs["Object"], pos.inputs["Vector"])
        hr = n.new("ShaderNodeMapRange")
        hr.clamp = True
        hr.inputs["From Min"].default_value = 0.0
        hr.inputs["From Max"].default_value = height_m
        l.new(pos.outputs["Z"], hr.inputs["Value"])
        ramp = n.new("ShaderNodeValToRGB")
        low = 1.0 - height_grad
        ramp.color_ramp.elements[0].color = (low * 0.9, low * 0.95, low * 1.05, 1.0)   # cool, dark feet
        ramp.color_ramp.elements[1].position = 0.85
        ramp.color_ramp.elements[1].color = (1.0 + height_grad * 0.25, 1.0 + height_grad * 0.22, 1.0 + height_grad * 0.15, 1.0)
        l.new(hr.outputs["Result"], ramp.inputs["Fac"])
        lit = _mix(nt, "MULTIPLY", lit, ramp.outputs["Color"], 1.0)
    low = None
    if damp > 0 or streaks > 0:
        lit, low = _weathering(nt, lit, tex, damp, damp_m, streaks)
    if moss > 0:
        lit = _moss(nt, lit, tex, sep, moss, moss_color, moss_scale, low)
    if soot > 0:
        lit = _soot(nt, lit, tex, sep, soot, soot_m)
    if heat > 0:
        lit = _heat(nt, lit, tex, heat, heat_color, heat_m, heat_scale)

    # worn edges
    bevel = n.new("ShaderNodeBevel")
    bevel.samples = 8
    bevel.inputs["Radius"].default_value = 0.03
    dot = n.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    l.new(bevel.outputs["Normal"], dot.inputs[0])
    l.new(geo.outputs["Normal"], dot.inputs[1])
    em = n.new("ShaderNodeMapRange")
    em.clamp = True
    em.inputs["From Min"].default_value = 0.93
    em.inputs["From Max"].default_value = 0.995
    em.inputs["To Min"].default_value = edge
    em.inputs["To Max"].default_value = 0.0
    l.new(dot.outputs["Value"], em.inputs["Value"])
    # wear comes and goes along an edge in broad patches (chipped paint), instead of a uniform
    # outline around every edge
    wear_noise = n.new("ShaderNodeTexNoise")
    wear_noise.inputs["Scale"].default_value = 4.0
    wear_noise.inputs["Detail"].default_value = 1.5
    l.new(tex.outputs["Object"], wear_noise.inputs["Vector"])
    wear = n.new("ShaderNodeMapRange")
    wear.clamp = True
    wear.inputs["From Min"].default_value = 0.38
    wear.inputs["From Max"].default_value = 0.62
    wear.inputs["To Min"].default_value = 0.15
    wear.inputs["To Max"].default_value = 1.0
    l.new(wear_noise.outputs["Fac"], wear.inputs["Value"])
    edge_mask = n.new("ShaderNodeMath")
    edge_mask.operation = "MULTIPLY"
    l.new(em.outputs["Result"], edge_mask.inputs[0])
    l.new(wear.outputs["Result"], edge_mask.inputs[1])
    light_col = n.new("ShaderNodeRGB")
    light_col.outputs[0].default_value = (1.0, 0.96, 0.88, 1.0)
    edged = _mix(nt, "SCREEN", lit, light_col.outputs[0], edge_mask.outputs["Value"])

    # crevices
    ao = n.new("ShaderNodeAmbientOcclusion")
    ao.samples = 16
    ao.inputs["Distance"].default_value = 0.35
    final = _mix(nt, "MULTIPLY", edged, ao.outputs["AO"], cavity)

    l.new(final, bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission > 0:
        l.new(final, bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = emission
    mat["painted_color_socket"] = final.node.name
    mat["kit_roughness"] = roughness
    mat["kit_metallic"] = metallic
    mat["kit_emission"] = emission
    mat.diffuse_color = base
    return mat


def _gray(nt, value_socket):
    c = nt.nodes.new("ShaderNodeCombineColor")
    for ch in ("Red", "Green", "Blue"):
        nt.links.new(value_socket, c.inputs[ch])
    return c.outputs["Color"]


def _mix(nt, blend: str, a, b, fac):
    m = nt.nodes.new("ShaderNodeMix")
    m.data_type = "RGBA"
    m.blend_type = blend
    if isinstance(fac, (int, float)):
        m.inputs["Factor"].default_value = fac
    else:
        nt.links.new(fac, m.inputs["Factor"])
    for sock, idx in ((a, 6), (b, 7)):
        if isinstance(sock, tuple):
            m.inputs[idx].default_value = sock
        else:
            nt.links.new(sock, m.inputs[idx])
    return m.outputs[2]


def _map(nt, value_socket, from_min: float, from_max: float, to_min: float, to_max: float, clamp: bool = True):
    r = nt.nodes.new("ShaderNodeMapRange")
    r.clamp = clamp
    r.inputs["From Min"].default_value = from_min
    r.inputs["From Max"].default_value = from_max
    r.inputs["To Min"].default_value = to_min
    r.inputs["To Max"].default_value = to_max
    nt.links.new(value_socket, r.inputs["Value"])
    return r.outputs["Result"]


def _math(nt, op: str, a, b):
    m = nt.nodes.new("ShaderNodeMath")
    m.operation = op
    for i, s in enumerate((a, b)):
        if isinstance(s, (int, float)):
            m.inputs[i].default_value = s
        else:
            nt.links.new(s, m.inputs[i])
    return m.outputs["Value"]


def _noise(nt, vector_socket, scale: float, detail: float = 1.0):
    nz = nt.nodes.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = scale
    nz.inputs["Detail"].default_value = detail
    nz.inputs["Roughness"].default_value = 0.4
    nt.links.new(vector_socket, nz.inputs["Vector"])
    return nz.outputs["Fac"]


def _weathering(nt, color, tex, damp: float, damp_m: float, streaks: float):
    """Rising damp below a wavy line about damp_m up, and long vertical wet streaks. Returns the
    color and the damp mask (None without damp), which also lets moss creep up the damp faces."""
    mask_out = None
    if damp > 0:
        pos = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(tex.outputs["Object"], pos.inputs["Vector"])
        wobble = _map(nt, _noise(nt, tex.outputs["Object"], 0.6), 0.3, 0.7, -0.35 * damp_m, 0.35 * damp_m)
        line = _math(nt, "ADD", pos.outputs["Z"], wobble)
        mask = _map(nt, line, damp_m * 0.5, damp_m, damp, 0.0)
        color = _mix(nt, "MULTIPLY", color, (0.36, 0.48, 0.38, 1.0), mask)
        mask_out = mask
    if streaks > 0:
        stretch = nt.nodes.new("ShaderNodeVectorMath")
        stretch.operation = "MULTIPLY"
        stretch.inputs[1].default_value = (2.2, 2.2, 0.15)
        nt.links.new(tex.outputs["Object"], stretch.inputs[0])
        mask = _map(nt, _noise(nt, stretch.outputs["Vector"], 1.0), 0.47, 0.6, 0.0, streaks)
        color = _mix(nt, "MULTIPLY", color, (0.45, 0.52, 0.48, 1.0), mask)
    return color, mask_out


def _moss(nt, color, tex, normal_xyz, amount: float, moss_hex: str, scale: float, low=None):
    """Broad moss patches on upward faces, in crevices and (with a damp mask `low`) low on damp faces."""
    up = _map(nt, normal_xyz.outputs["Z"], 0.3, 0.85, 0.0, 1.0)
    ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
    ao.samples = 8
    ao.inputs["Distance"].default_value = 0.2
    crevice = _map(nt, ao.outputs["AO"], 0.35, 0.85, 0.8, 0.0)
    where = _math(nt, "MAXIMUM", up, crevice)
    if low is not None:
        where = _math(nt, "MAXIMUM", where, _math(nt, "MULTIPLY", low, 0.8))
    patches = _map(nt, _noise(nt, tex.outputs["Object"], scale, 2.0), 0.4, 0.56, 0.0, 1.0)
    mask = _math(nt, "MULTIPLY", _math(nt, "MULTIPLY", where, patches), amount)
    return _mix(nt, "MIX", color, common.hex_to_linear(moss_hex), mask)


def _soot(nt, color, tex, normal_xyz, amount: float, soot_m: float):
    """Smoke-blackening: thicker higher up (a wavy line rising to soot_m), under overhangs, in
    long vertical streaks and in broad blotches. Multiplies toward a warm near-black."""
    pos = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tex.outputs["Object"], pos.inputs["Vector"])
    wobble = _map(nt, _noise(nt, tex.outputs["Object"], 0.5), 0.3, 0.7, -0.3 * soot_m, 0.3 * soot_m)
    rise = _map(nt, _math(nt, "ADD", pos.outputs["Z"], wobble), soot_m * 0.25, soot_m, 0.0, 0.85)
    under = _map(nt, normal_xyz.outputs["Z"], -0.9, -0.2, 1.0, 0.0)
    stretch = nt.nodes.new("ShaderNodeVectorMath")
    stretch.operation = "MULTIPLY"
    stretch.inputs[1].default_value = (2.6, 2.6, 0.18)
    nt.links.new(tex.outputs["Object"], stretch.inputs[0])
    streak = _map(nt, _noise(nt, stretch.outputs["Vector"], 1.0), 0.48, 0.62, 0.0, 1.0)
    blotch = _map(nt, _noise(nt, tex.outputs["Object"], 0.9, 2.0), 0.45, 0.62, 0.0, 0.7)
    mask = _math(nt, "MAXIMUM", _math(nt, "MAXIMUM", rise, under), _math(nt, "MAXIMUM", streak, blotch))
    mask = _math(nt, "MINIMUM", _math(nt, "MULTIPLY", mask, amount), 1.0)
    return _mix(nt, "MULTIPLY", color, (0.3, 0.26, 0.23, 1.0), mask)


def _heat(nt, color, tex, amount: float, heat_hex: str, heat_m: float, scale: float):
    """Heat-tempered metal or scorched brick: broad patches of heat_hex, everywhere or rising to
    full strength at heat_m above the floor."""
    patches = _map(nt, _noise(nt, tex.outputs["Object"], scale, 2.0), 0.38, 0.6, 0.25, 1.0)
    if heat_m > 0:
        pos = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(tex.outputs["Object"], pos.inputs["Vector"])
        high = _map(nt, pos.outputs["Z"], heat_m * 0.75, heat_m, 0.0, 1.0)
        patches = _math(nt, "MULTIPLY", patches, high)
    mask = _math(nt, "MULTIPLY", patches, amount)
    return _mix(nt, "MIX", color, common.hex_to_linear(heat_hex), mask)


# ----------------------------------------------------------------------------- geometry

def clear_uvs(obj: bpy.types.Object) -> None:
    """Remove UV maps from a primitive; the bake creates one UV map for the whole piece."""
    while obj.data.uv_layers:
        obj.data.uv_layers.remove(obj.data.uv_layers[0])


def set_tint(obj: bpy.types.Object, color: tuple[float, float, float]) -> None:
    """Fill the per-part tint attribute (face corners) with one color."""
    me = obj.data
    attr = me.color_attributes.get(TINT_ATTR) or me.color_attributes.new(TINT_ATTR, "FLOAT_COLOR", "CORNER")
    for d in attr.data:
        d.color = (color[0], color[1], color[2], 1.0)


def random_tint(rng: random.Random, spread: float = 0.12, warm: float = 0.03) -> tuple[float, float, float]:
    v = 1.0 + rng.uniform(-spread, spread)
    w = rng.uniform(-warm, warm)
    return (v * (1 + w), v, v * (1 - w))


def block(name: str, size, loc, rot=(0, 0, 0), bevel: float = 0.03, segments: int = 1, mat=None,
          tint=(1.0, 1.0, 1.0), taper: float = 0.0) -> bpy.types.Object:
    """A beveled box (stone block, plank, beam). `taper` shrinks the top face (0..0.5)."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0))
    o = bpy.context.active_object
    o.name = name
    clear_uvs(o)
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    if taper:
        for v in o.data.vertices:
            if v.co.z > 0:
                v.co.x *= 1 - taper
                v.co.y *= 1 - taper
    o.location = loc
    o.rotation_euler = rot
    bpy.ops.object.transform_apply(location=True, rotation=True)
    if bevel:
        m = o.modifiers.new("bevel", "BEVEL")
        m.width = bevel
        m.segments = segments
        m.limit_method = "ANGLE"
        common.apply_all_modifiers(o)
    if mat:
        o.data.materials.append(mat)
    set_tint(o, tint)
    return o


def cylinder(name: str, radius: float, depth: float, loc, rot=(0, 0, 0), sides: int = 16,
             radius_top: float | None = None, bevel: float = 0.0, mat=None, tint=(1.0, 1.0, 1.0)) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cone_add(vertices=sides, radius1=radius,
                                    radius2=radius if radius_top is None else radius_top,
                                    depth=depth, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    clear_uvs(o)
    if bevel:
        m = o.modifiers.new("bevel", "BEVEL")
        m.width = bevel
        m.segments = 1
        m.limit_method = "ANGLE"
        m.angle_limit = math.radians(50)
        common.apply_all_modifiers(o)
    if mat:
        o.data.materials.append(mat)
    set_tint(o, tint)
    return o


def apply_transforms(objs) -> None:
    """Bake each object's location, rotation and scale into its vertices."""
    from mathutils import Matrix
    for o in objs:
        o.data.transform(o.matrix_world)
        o.matrix_world = Matrix.Identity(4)


def strut(name: str, p0, p1, radius: float, sides: int = 6, mat=None, tint=(1.0, 1.0, 1.0)) -> bpy.types.Object:
    """A cylinder from point p0 to point p1 (legs, braces, chains)."""
    a, b = Vector(p0), Vector(p1)
    d = b - a
    rot = Vector((0, 0, 1)).rotation_difference(d.normalized()).to_euler()
    return cylinder(name, radius, d.length, (a + b) / 2, rot=tuple(rot), sides=sides, mat=mat, tint=tint)


def jitter_vertices(obj: bpy.types.Object, rng: random.Random, amount: float) -> None:
    """Move each vertex a little (chipped, hand-cut stone). Coincident vertices move together
    so the mesh stays closed."""
    moves: dict[tuple, Vector] = {}
    for v in obj.data.vertices:
        key = (round(v.co.x, 4), round(v.co.y, 4), round(v.co.z, 4))
        if key not in moves:
            moves[key] = Vector((rng.uniform(-amount, amount), rng.uniform(-amount, amount),
                                 rng.uniform(-amount, amount)))
        v.co += moves[key]


def fuse_touching_parts(obj: bpy.types.Object, dist: float = 1e-5) -> int:
    """Where two joined parts meet face to face (two cones base to base, a block on a block),
    their touching faces coincide. Welded, as the exporter's consumers and the asset validator
    do, those faces leave edges shared by three or four faces. Delete every face that has a
    coincident twin, then weld, so the parts fuse into one closed surface. Returns the number
    of faces removed."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    target = bmesh.ops.find_doubles(bm, verts=bm.verts, dist=dist)["targetmap"]
    seen: dict[frozenset, list] = {}
    for f in bm.faces:
        seen.setdefault(frozenset(target.get(v, v) for v in f.verts), []).append(f)
    twins = [f for fs in seen.values() if len(fs) > 1 for f in fs]
    if twins:
        bmesh.ops.delete(bm, geom=twins, context="FACES")
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    bm.to_mesh(obj.data)
    bm.free()
    return len(twins)


# ----------------------------------------------------------------------------- baking

def bake_piece(obj: bpy.types.Object, out_dir: Path, name: str, size: int = 1024, samples: int = 48,
               keep_unbaked: list[bpy.types.Object] | None = None, bevel_normal: float = 0.012,
               keep_uvs: bool = False) -> None:
    """Bake the painted materials of `obj` into textures and replace them with one plain
    material: base color from `<name>_albedo.png`, roughness and metallic from `<name>_orm.png`
    (glTF layout: G = roughness, B = metallic), and a tangent-space normal map from Cycles'
    Bevel shading (`bevel_normal` metres; 0 skips it), which rounds hard edges on low-poly
    parts so they catch light without extra geometry. Emissive parts should be separate objects
    in `keep_unbaked`; they keep their own material."""
    out_dir.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.render.bake.margin = 8
    scene.render.bake.use_clear = True

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    me = obj.data
    if not keep_uvs:  # (bake.bake_asset unwraps first, so its normal bake shares these UVs)
        while me.uv_layers:
            me.uv_layers.remove(me.uv_layers[0])
        me.uv_layers.new(name="UVMap")
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.006)
        bpy.ops.object.mode_set(mode="OBJECT")
        buried = shrink_buried_uvs(obj)
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.select_all(action="SELECT")
        bpy.ops.uv.pack_islands(rotate=True, scale=True, margin=0.004)
        bpy.ops.object.mode_set(mode="OBJECT")
        print(f"  {name}: {buried} of {len(me.polygons)} faces are hidden and get almost no texture space")

    albedo = bpy.data.images.new(f"{name}_albedo", size, size, alpha=False)
    orm = bpy.data.images.new(f"{name}_orm", size, size, alpha=False)
    orm.colorspace_settings.name = "Non-Color"

    mats = [m for m in me.materials if m]
    saved: list[tuple] = []
    for pass_img, channel in ((albedo, "color"), (orm, "orm")):
        for mat in mats:
            nt = mat.node_tree
            out = next(nd for nd in nt.nodes if nd.type == "OUTPUT_MATERIAL")
            prev = out.inputs["Surface"].links[0].from_socket
            emit = nt.nodes.new("ShaderNodeEmission")
            if channel == "color":
                src = _find_socket(nt, mat)
                nt.links.new(src, emit.inputs["Color"])
            else:
                emit.inputs["Color"].default_value = (1.0, float(mat.get("kit_roughness", 0.8)),
                                                      float(mat.get("kit_metallic", 0.0)), 1.0)
            nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
            img_node = nt.nodes.new("ShaderNodeTexImage")
            img_node.image = pass_img
            nt.nodes.active = img_node
            saved.append((mat, out, prev, emit, img_node))
        scene.cycles.samples = samples if channel == "color" else 1   # roughness and metal are flat colours
        bpy.ops.object.bake(type="EMIT")
        scene.cycles.samples = samples
        for mat, out, prev, emit, img_node in saved:
            mat.node_tree.links.new(prev, out.inputs["Surface"])
            mat.node_tree.nodes.remove(emit)
            mat.node_tree.nodes.remove(img_node)
        saved.clear()
        path = out_dir / f"{pass_img.name}.png"
        pass_img.filepath_raw = str(path)
        pass_img.file_format = "PNG"
        pass_img.save()

    normal = None
    if bevel_normal > 0:
        normal = bpy.data.images.new(f"{name}_normal", size, size, alpha=False)
        normal.colorspace_settings.name = "Non-Color"
        added = []
        for mat in mats:
            nt = mat.node_tree
            bsdf = nt.nodes["Principled BSDF"]
            bev = nt.nodes.new("ShaderNodeBevel")
            bev.samples = 8
            bev.inputs["Radius"].default_value = bevel_normal
            nt.links.new(bev.outputs["Normal"], bsdf.inputs["Normal"])
            img_node = nt.nodes.new("ShaderNodeTexImage")
            img_node.image = normal
            nt.nodes.active = img_node
            added.append((mat, bev, img_node))
        scene.render.bake.normal_space = "TANGENT"
        scene.cycles.samples = 16  # the bevel normal is smooth; few samples are enough
        bpy.ops.object.bake(type="NORMAL")
        scene.cycles.samples = samples
        for mat, bev, img_node in added:
            mat.node_tree.nodes.remove(bev)
            mat.node_tree.nodes.remove(img_node)
        normal.filepath_raw = str(out_dir / f"{normal.name}.png")
        normal.file_format = "PNG"
        normal.save()

    emissive = any(float(m.get("kit_emission", 0)) > 0 for m in mats)
    glow = None
    if emissive:
        # a glow texture: the painted color on emissive materials, black everywhere else
        glow = bpy.data.images.new(f"{name}_emit", size, size, alpha=False)
        added = []
        for mat in mats:
            nt = mat.node_tree
            out = next(nd for nd in nt.nodes if nd.type == "OUTPUT_MATERIAL")
            prev = out.inputs["Surface"].links[0].from_socket
            emit = nt.nodes.new("ShaderNodeEmission")
            if float(mat.get("kit_emission", 0)) > 0:
                nt.links.new(_find_socket(nt, mat), emit.inputs["Color"])
            else:
                emit.inputs["Color"].default_value = (0.0, 0.0, 0.0, 1.0)
            nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
            img_node = nt.nodes.new("ShaderNodeTexImage")
            img_node.image = glow
            nt.nodes.active = img_node
            added.append((mat, out, prev, emit, img_node))
        scene.cycles.samples = 16
        bpy.ops.object.bake(type="EMIT")
        scene.cycles.samples = samples
        for mat, out, prev, emit, img_node in added:
            mat.node_tree.links.new(prev, out.inputs["Surface"])
            mat.node_tree.nodes.remove(emit)
            mat.node_tree.nodes.remove(img_node)
        glow.filepath_raw = str(out_dir / f"{glow.name}.png")
        glow.file_format = "PNG"
        glow.save()
    glow_strength = max([float(m.get("kit_emission", 0)) for m in mats] + [0.0])
    final = bpy.data.materials.new(f"{name}_baked")
    final.use_nodes = True
    final.use_backface_culling = True  # closed meshes: glTF then marks the material single-sided
    nt = final.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    t_alb = nt.nodes.new("ShaderNodeTexImage")
    t_alb.image = albedo
    t_orm = nt.nodes.new("ShaderNodeTexImage")
    t_orm.image = orm
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(t_alb.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(t_orm.outputs["Color"], sep.inputs["Color"])
    nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    if normal is not None:
        t_nrm = nt.nodes.new("ShaderNodeTexImage")
        t_nrm.image = normal
        nmap = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(t_nrm.outputs["Color"], nmap.inputs["Color"])
        nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    if glow is not None:
        t_glow = nt.nodes.new("ShaderNodeTexImage")
        t_glow.image = glow
        nt.links.new(t_glow.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = glow_strength
    me.materials.clear()
    me.materials.append(final)
    # the tint attribute is baked in now; drop it so glTF does not export it as vertex color
    if me.color_attributes.get(TINT_ATTR):
        me.color_attributes.remove(me.color_attributes[TINT_ATTR])


def _uv_continuous(e, f, g, uv) -> bool:
    """True when faces f and g use the same UVs along their shared edge e (no UV seam)."""
    for v in e.verts:
        a = next(l[uv].uv for l in f.loops if l.vert is v)
        b = next(l[uv].uv for l in g.loops if l.vert is v)
        if (a - b).length_squared > 1e-12:
            return False
    return True


def shrink_buried_uvs(obj: bpy.types.Object, probe: float = 0.06, extent: float = 0.001) -> int:
    """Faces that touch another part or the ground (a drum's top under the next drum, a
    stone's back against the wall, a body under a robe) are never seen. Shrink their UVs so
    the texture goes to visible surfaces. A face is buried when a short ray from its centre
    along its normal hits the same mesh, or when it faces down at ground level. Returns the
    count.

    Buried faces shrink together, one patch per connected run of buried faces within a UV
    island, to at most `extent` UV units. Shrinking each face on its own would give every one
    its own UV island, and the seams around them stop Godot's level-of-detail generator from
    simplifying those areas at all (it stalled at one LOD on the robed characters)."""
    from mathutils.bvhtree import BVHTree
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    tree = BVHTree.FromBMesh(bm)
    uv = bm.loops.layers.uv.active
    min_z = min(v.co.z for v in bm.verts)
    buried = set()
    for f in bm.faces:
        c = f.calc_center_median()
        n = f.normal
        hidden = n.z < -0.9 and c.z < min_z + 0.02
        if not hidden:
            # covered only if the centre and points near every corner are all covered
            samples = [c] + [c.lerp(v.co, 0.85) for v in f.verts]
            hidden = all(tree.ray_cast(pt + n * 0.002, n, probe)[0] is not None for pt in samples)
        if hidden:
            buried.add(f)
    seen: set = set()
    for start in buried:
        if start in seen:
            continue
        patch, stack = [], [start]
        seen.add(start)
        while stack:
            f = stack.pop()
            patch.append(f)
            for e in f.edges:
                for g in e.link_faces:
                    if g in buried and g not in seen and _uv_continuous(e, f, g, uv):
                        seen.add(g)
                        stack.append(g)
        loops = [l for f in patch for l in f.loops]
        us = [l[uv].uv.x for l in loops]
        vs = [l[uv].uv.y for l in loops]
        centre = Vector(((min(us) + max(us)) / 2, (min(vs) + max(vs)) / 2))
        size = max(max(us) - min(us), max(vs) - min(vs), 1e-9)
        scale = min(0.02, extent / size)
        for l in loops:
            l[uv].uv = centre + (l[uv].uv - centre) * scale
    bm.to_mesh(me)
    bm.free()
    return len(buried)


def shade_smooth_by_angle(obj: bpy.types.Object, degrees: float = 35.0) -> None:
    """Smooth round surfaces while keeping hard edges crisp."""
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(degrees))


def _find_socket(nt, mat):
    """The painted color output of a kit material (the last mix node feeding Base Color)."""
    bsdf = nt.nodes["Principled BSDF"]
    return bsdf.inputs["Base Color"].links[0].from_socket


def finish_piece(parts: list[bpy.types.Object], name: str, spec: dict, previews: Path | None,
                 emissive_parts: list[bpy.types.Object] | None = None, center: bool = True,
                 preset: str = "dusk_grim", drop_to_floor: bool = True) -> list[bpy.types.Object]:
    """Join, put the origin at the feet, bake, export and render the contact sheet (lit by the
    lighting preset `preset`, the one the kit's arena uses). With center False and drop_to_floor
    False the geometry keeps the origin it was built around (a piece hung from a pivot)."""
    obj = common.join_objects(parts, name)
    if center:
        common.origin_to_feet(obj)
    elif drop_to_floor:
        zs = [v.co.z for v in obj.data.vertices]
        for v in obj.data.vertices:
            v.co.z -= min(zs)
    shade_smooth_by_angle(obj)
    # the textures are embedded in the .glb; keep the PNGs with the previews for review
    tex_dir = common.REPO / "previews" / "kit_textures"
    bake_piece(obj, tex_dir, name, size=int(spec.get("texture_size", 1024)))
    objs = [obj]
    if emissive_parts:
        glow = common.join_objects(emissive_parts, f"{name}_glow")
        glow.location = (0, 0, 0)
        objs.append(glow)
    tris = common.triangle_count(objs)
    common.export_glb(Path(spec["out"]), objs)
    print(f"  {name}: {tris} triangles -> {spec['out']}")
    if previews:
        common.render_contact_sheet(objs, previews / f"{name}_sheet.png", title=name, cell=384, preset=preset)
    return objs


def build_spec(spec: dict, previews: Path | None, pieces: dict, back_on_y0: set, materials,
               preset: str = "dusk_grim", keep_xy: set | None = None,
               keep_origin: set | None = None) -> None:
    """Build one kit piece from its asset spec: `pieces[params.piece](params, mats, rng)` returns
    the parts (or (parts, emissive parts)); `materials(palette)` makes the kit's materials. Pieces
    in `back_on_y0` keep y as built (mounting face on y = 0) and are centred on x; all others are
    centred on x and y. Either way the lowest point goes to z = 0.
    Optional (both empty by default): pieces in `keep_xy` keep the x and y they were built around
    (a round collider's axis, so asymmetric details cannot shift it) and only drop to z = 0;
    pieces in `keep_origin` are not moved at all (a piece hung from a pivot reaches below it)."""
    keep_xy = keep_xy or set()
    keep_origin = keep_origin or set()
    common.reset_scene()
    rng = common.seeded_random(spec["seed"])
    params = spec.get("params", {})
    piece = params["piece"]
    m = materials(spec.get("palette", {}))
    result = pieces[piece](params, m, rng)
    parts, glow = result if isinstance(result, tuple) else (result, [])
    apply_transforms(parts + glow)
    allv = [o.matrix_world @ v.co for o in parts for v in o.data.vertices]
    off = Vector(((min(v.x for v in allv) + max(v.x for v in allv)) / 2,
                  0.0 if piece in back_on_y0 else (min(v.y for v in allv) + max(v.y for v in allv)) / 2,
                  min(v.z for v in allv)))
    if piece in keep_xy:
        off.x = off.y = 0.0
    if piece in keep_origin:
        off = Vector((0.0, 0.0, 0.0))
    for o in parts + glow:
        for v in o.data.vertices:
            v.co -= off
    finish_piece(parts, spec["id"], spec, previews, glow, center=False, preset=preset,
                 drop_to_floor=piece not in keep_origin)
