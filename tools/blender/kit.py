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
                 mottle_scale: float = 0.45, emission: float = 0.0) -> bpy.types.Material:
    """Painted-look material. Every channel is broad and soft (no fine noise):
    - base color times the per-part tint attribute
    - mottle: very low-frequency brightness variation (mottle_scale is in 1/m)
    - top_light: surfaces facing up are lighter (light from above, baked in)
    - edge: worn, lighter edges (Bevel-normal comparison)
    - cavity: darker crevices (ambient occlusion)
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
    light_col = n.new("ShaderNodeRGB")
    light_col.outputs[0].default_value = (1.0, 0.96, 0.88, 1.0)
    edged = _mix(nt, "SCREEN", lit, light_col.outputs[0], em.outputs["Result"])

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


# ----------------------------------------------------------------------------- baking

def bake_piece(obj: bpy.types.Object, out_dir: Path, name: str, size: int = 1024, samples: int = 48,
               keep_unbaked: list[bpy.types.Object] | None = None) -> None:
    """Bake the painted materials of `obj` into textures and replace them with one plain
    material: base color from `<name>_albedo.png`, roughness and metallic from `<name>_orm.png`
    (glTF layout: G = roughness, B = metallic). Emissive parts should be separate objects in
    `keep_unbaked`; they keep their own material."""
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
        bpy.ops.object.bake(type="EMIT")
        for mat, out, prev, emit, img_node in saved:
            mat.node_tree.links.new(prev, out.inputs["Surface"])
            mat.node_tree.nodes.remove(emit)
            mat.node_tree.nodes.remove(img_node)
        saved.clear()
        path = out_dir / f"{pass_img.name}.png"
        pass_img.filepath_raw = str(path)
        pass_img.file_format = "PNG"
        pass_img.save()

    emissive = any(float(m.get("kit_emission", 0)) > 0 for m in mats)
    final = bpy.data.materials.new(f"{name}_baked")
    final.use_nodes = True
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
    if emissive:
        nt.links.new(t_alb.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 1.0
    me.materials.clear()
    me.materials.append(final)
    # the tint attribute is baked in now; drop it so glTF does not export it as vertex color
    if me.color_attributes.get(TINT_ATTR):
        me.color_attributes.remove(me.color_attributes[TINT_ATTR])


def shrink_buried_uvs(obj: bpy.types.Object, probe: float = 0.06) -> int:
    """Faces that touch another part or the ground (a drum's top under the next drum, a
    stone's back against the wall) are never seen. Shrink their UVs to a point so the texture
    goes to visible surfaces. A face is buried when a short ray from its centre along its
    normal hits the same mesh, or when it faces down at ground level. Returns the count."""
    from mathutils.bvhtree import BVHTree
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    tree = BVHTree.FromBMesh(bm)
    uv = bm.loops.layers.uv.active
    min_z = min(v.co.z for v in bm.verts)
    count = 0
    for f in bm.faces:
        c = f.calc_center_median()
        n = f.normal
        hidden = n.z < -0.9 and c.z < min_z + 0.02
        if not hidden:
            # covered only if the centre and points near every corner are all covered
            samples = [c] + [c.lerp(v.co, 0.85) for v in f.verts]
            hidden = all(tree.ray_cast(pt + n * 0.002, n, probe)[0] is not None for pt in samples)
        if hidden:
            count += 1
            centre = sum((l[uv].uv for l in f.loops), start=Vector((0.0, 0.0))) / len(f.loops)
            for l in f.loops:
                l[uv].uv = centre + (l[uv].uv - centre) * 0.02
    bm.to_mesh(me)
    bm.free()
    return count


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
                 emissive_parts: list[bpy.types.Object] | None = None, center: bool = True) -> list[bpy.types.Object]:
    """Join, put the origin at the feet, bake, export and render the contact sheet."""
    obj = common.join_objects(parts, name)
    if center:
        common.origin_to_feet(obj)
    else:
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
        common.render_contact_sheet(objs, previews / f"{name}_sheet.png", title=name, cell=384)
    return objs
