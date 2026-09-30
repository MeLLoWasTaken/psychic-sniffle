"""Gallows Courtyard dressing pieces (backlog F-05): ramparts and wall walk, gatehouse, corner
turret, skyline silhouettes beyond the walls, props (crates, barrels, rubble, chains, weapon
rack, drain) and a worn floor tile. Built through build_kit_gallows.py, which registers these
functions in its PIECES table; one asset spec per piece (data/assets/gallows_<piece>.json).

Pivots follow build_kit_gallows.py: "face" pieces (rampart, wall_chains) have their mounting
face on y = 0 and the front toward -Y; everything else is centred with its lowest point at z = 0.
The front of every piece faces -Y (the glTF exporter turns it into Godot's +Z).
"""
from __future__ import annotations

import math

import bmesh
import bpy

import common
import kit
from kit import block, cylinder, random_tint

GAP = 0.04  # joint between stones


# ----------------------------------------------------------------------------- materials

def extra_mats(pal: dict) -> dict:
    return {
        "slate": kit.kit_material("slate", pal.get("slate", "#4a4f58"), roughness=0.8, edge=0.3, cavity=0.55,
                                  top_light=0.14, mottle=0.1),
        "dirt": kit.kit_material("dirt", pal.get("dirt", "#4b4339"), roughness=0.97, edge=0.05, cavity=0.45,
                                 mottle=0.18, mottle_scale=1.2),
        "void": kit.kit_material("void", pal.get("void", "#17140f"), roughness=0.95, edge=0.0, cavity=0.0,
                                 top_light=0.0, mottle=0.0),
        "far_stone": kit.kit_material("far_stone", pal.get("far_stone", "#5b5852"), roughness=0.92, edge=0.22,
                                      cavity=0.5, mottle=0.12, mottle_scale=0.15),
        "far_roof": kit.kit_material("far_roof", pal.get("far_roof", "#3f434b"), roughness=0.85, edge=0.2,
                                     cavity=0.45, top_light=0.1, mottle=0.1, mottle_scale=0.2),
        "walk": kit.kit_material("walk", pal.get("walk", "#6b6861"), roughness=0.92, edge=0.4, cavity=0.6,
                                 top_light=0.06, mottle=0.14, mottle_scale=0.35),
        "plaster": kit.kit_material("plaster", pal.get("plaster", "#6f6a60"), roughness=0.95, edge=0.1,
                                    cavity=0.45, mottle=0.14, mottle_scale=0.3),
    }


def glow(name: str, hex_color: str, strength: float) -> bpy.types.Material:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    c = common.hex_to_linear(hex_color)
    b.inputs["Base Color"].default_value = c
    b.inputs["Emission Color"].default_value = c
    b.inputs["Emission Strength"].default_value = strength
    b.inputs["Roughness"].default_value = 0.9
    return m


# ----------------------------------------------------------------------------- shapes

def apply_xf(objs) -> None:
    """Bake location, rotation and scale into the vertices. Object matrices are only refreshed
    when the view layer updates, so update it first (setting .location alone would be lost)."""
    bpy.context.view_layer.update()
    kit.apply_transforms(objs)


def _finish(o: bpy.types.Object, name: str, mat, tint, bevel: float = 0.0, segments: int = 1,
            angle: float = 40.0) -> bpy.types.Object:
    o.name = name
    if bevel:
        mod = o.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = segments
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(angle)
        common.apply_all_modifiers(o)
    if mat:
        o.data.materials.append(mat)
    kit.set_tint(o, tint)
    return o


def _from_bmesh(bm: bmesh.types.BMesh, name: str) -> bpy.types.Object:
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    return o


def prism(name: str, length: float, width: float, height: float, loc, rot=(0, 0, 0), mat=None,
          tint=(1.0, 1.0, 1.0), bevel: float = 0.0, ridge_shift: float = 0.0) -> bpy.types.Object:
    """A gabled roof: a triangular prism with its ridge along x, base on z = 0 (before `loc`)."""
    bm = bmesh.new()
    hl, hw = length / 2, width / 2
    v = [bm.verts.new(p) for p in ((-hl, -hw, 0), (-hl, hw, 0), (-hl, ridge_shift, height),
                                   (hl, -hw, 0), (hl, hw, 0), (hl, ridge_shift, height))]
    for f in ((0, 1, 2), (5, 4, 3), (0, 3, 4, 1), (1, 4, 5, 2), (2, 5, 3, 0)):
        bm.faces.new([v[i] for i in f])
    o = _from_bmesh(bm, name)
    o.rotation_euler = rot
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, tint, bevel)


def lathe(name: str, profile, loc=(0, 0, 0), sides: int = 16, mat=None, tint=(1.0, 1.0, 1.0),
          rot=(0, 0, 0), bevel: float = 0.0) -> bpy.types.Object:
    """A closed solid of revolution around z from a (radius, z) profile, bottom to top. A radius
    of 0 at either end closes it with a point, otherwise with a flat cap."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r <= 1e-6:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(i * math.tau / sides), r * math.sin(i * math.tau / sides), z))
                          for i in range(sides)])
    for a, b in zip(rings, rings[1:]):
        for i in range(sides):
            j = (i + 1) % sides
            if len(a) == 1:
                bm.faces.new((a[0], b[i], b[j])) if len(b) > 1 else None
            elif len(b) == 1:
                bm.faces.new((a[i], a[j], b[0]))
            else:
                bm.faces.new((a[i], a[j], b[j], b[i]))
    if len(rings[0]) > 1:
        bm.faces.new(list(reversed(rings[0])))
    if len(rings[-1]) > 1:
        bm.faces.new(rings[-1])
    o = _from_bmesh(bm, name)
    o.rotation_euler = rot
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, tint, bevel, angle=50)


def torus(name: str, major: float, minor: float, loc, rot=(0, 0, 0), mat=None, seg=(12, 6),
          scale=(1, 1, 1)) -> bpy.types.Object:
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=seg[0],
                                     minor_segments=seg[1], location=(0, 0, 0))
    o = bpy.context.active_object
    kit.clear_uvs(o)
    o.scale = scale
    o.rotation_euler = rot
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, (1, 1, 1))


def ashlar(parts: list, m, rng, axis: str, plane: float, outward: int, u0: float, u1: float, z0: float,
           z1: float, depth: float = 0.35, course=(0.55, 0.75), width=(0.9, 1.6), segments: int = 1,
           mat_key: str = "stone", jitter: float = 0.012, tint: float = 0.12, skip=None) -> None:
    """A face of coursed stone blocks. axis: the face runs along "x" (it faces -y or +y) or "y" (faces
    -x or +x); plane: coordinate of the stone fronts; outward: -1 or 1 along the facing axis.
    `skip(u, z)` returns True where a stone must be left out (an opening)."""
    z = z0
    row = 0
    while z < z1 - 0.05:
        ch = min(rng.uniform(*course), z1 - z)
        if z1 - (z + ch) < 0.3:
            ch = z1 - z
        u = u0 - (rng.uniform(0.2, 0.6) if row % 2 else 0.0)
        while u < u1 - 0.01:
            w = rng.uniform(*width)
            a, b = max(u, u0), min(u + w, u1)
            if u1 - b < 0.3:
                b = u1
                w = b - u
            uc, zc = (a + b) / 2, z + ch / 2
            if b - a > 0.15 and not (skip and skip(uc, zc)):
                front = plane + outward * rng.uniform(0.0, 0.02)
                c_n = front - outward * depth / 2
                if axis == "x":
                    size, loc = (b - a - GAP, depth, ch - GAP), (uc, c_n, zc)
                else:
                    size, loc = (depth, b - a - GAP, ch - GAP), (c_n, uc, zc)
                s = block("ashlar", size, loc, bevel=0.035, segments=segments, mat=m[mat_key],
                          tint=random_tint(rng, tint, 0.04))
                if jitter:
                    kit.jitter_vertices(s, rng, jitter)
                parts.append(s)
            u += w
        z += ch
        row += 1


def slit(parts: list, m, axis: str, plane: float, outward: int, u: float, z: float, h: float = 1.1,
         w: float = 0.18) -> None:
    """An arrow slit: a dark void with a stone sill and head, standing proud of a face."""
    def at(du, dz, size_u, size_n, size_z, key, n_off=0.0):
        c_n = plane + outward * (n_off - size_n / 2)
        if axis == "x":
            return block("slit", (size_u, size_n, size_z), (u + du, c_n, z + dz), bevel=0.02, mat=m[key])
        return block("slit", (size_n, size_u, size_z), (c_n, u + du, z + dz), bevel=0.02, mat=m[key])
    parts.append(at(0, 0, w, 0.3, h, "void", 0.04))
    parts.append(at(0, h / 2 + 0.1, w + 0.5, 0.36, 0.2, "stone", 0.07))
    parts.append(at(0, -h / 2 - 0.1, w + 0.5, 0.36, 0.2, "stone", 0.07))
    for s in (-1, 1):
        parts.append(at(s * (w / 2 + 0.13), 0, 0.24, 0.34, h, "stone", 0.06))


def merlon_row(parts: list, m, rng, x0: float, x1: float, y_front: float, depth: float, z: float,
               base_h: float, mer_h: float, step: float, axis: str = "x", damaged: float = 0.0,
               segments: int = 2) -> None:
    """A parapet along x (or y): a base course and merlons with sloped capstones. The front is at
    y_front on the -Y side (for axis "y", x_front on the -X side); the parapet extends `depth` back."""
    def put(name, u, n, zc, su, sn, sz, taper=0.0, seg=segments, key="stone", t=0.1, rot=0.0):
        if axis == "x":
            o = block(name, (su, sn, sz), (u, n, zc), rot=(0, 0, rot), bevel=0.03, segments=seg, mat=m[key],
                      tint=random_tint(rng, t, 0.04), taper=taper)
        else:
            o = block(name, (sn, su, sz), (n, u, zc), rot=(0, 0, rot), bevel=0.03, segments=seg, mat=m[key],
                      tint=random_tint(rng, t, 0.04), taper=taper)
        kit.jitter_vertices(o, rng, 0.01)
        parts.append(o)
    n_c = y_front + depth / 2
    u = x0
    while u < x1 - 0.01:
        w = min(rng.uniform(1.0, 1.7), x1 - u)
        if x1 - (u + w) < 0.4:
            w = x1 - u
        put("course", u + w / 2, n_c, z + base_h / 2, w - GAP, depth, base_h - GAP)
        u += w
    n = max(1, round((x1 - x0) / step))
    st = (x1 - x0) / n
    mw = st * 0.6
    for i in range(n):
        cx = x0 + st * (i + 0.5) + rng.uniform(-0.03, 0.03)
        broken = rng.random() < damaged
        h = mer_h * (rng.uniform(0.35, 0.6) if broken else 1.0)
        h1 = h * 0.55 if not broken else h
        put("merlon", cx, n_c + 0.02, z + base_h + h1 / 2, mw - GAP, depth - 0.06, h1 - GAP,
            rot=rng.uniform(-0.04, 0.04) if broken else 0.0)
        if not broken:
            h2 = h - h1 - 0.16
            put("merlon", cx + rng.uniform(-0.02, 0.02), n_c + 0.02, z + base_h + h1 + h2 / 2, mw - GAP - 0.03,
                depth - 0.08, h2 - GAP)
            put("cap", cx, n_c, z + base_h + h - 0.08, mw + 0.08, depth + 0.04, 0.18, taper=0.14)


# ----------------------------------------------------------------------------- architecture

def rampart(p: dict, m: dict, rng) -> list:
    """4 m of crenellated parapet crowning a wall facade: a base course and merlons with sloped
    capstones. The front lies flush with the wall face (y = 0, overhanging a little like the
    coping); it sits on the coping (z = 0) and reaches back into the wall walk."""
    width = p.get("width_m", 4.0)
    parts: list = []
    merlon_row(parts, m, rng, -width / 2, width / 2, -0.08, p.get("depth_m", 0.62), 0.0,
               p.get("base_m", 0.5), p.get("merlon_m", 1.0), p.get("step_m", 4.0 / 3.0),
               damaged=p.get("damaged", 0.0))
    return parts


def wall_walk(p: dict, m: dict, rng) -> list:
    """4 x 4 m of wall-walk paving: long, weathered slabs laid across the walk in courses."""
    size = p.get("size_m", 4.0)
    thick = 0.16
    parts = [block("bed", (size, size, 0.1), (0, 0, 0.05), bevel=0, mat=m["mortar"])]
    y = -size / 2
    while y < size / 2 - 0.01:
        h = min(rng.uniform(0.8, 1.15), size / 2 - y)
        if size / 2 - (y + h) < 0.5:
            h = size / 2 - y
        x = -size / 2 - rng.uniform(0.0, 0.8)
        while x < size / 2 - 0.01:
            w = rng.uniform(1.5, 2.4)
            a, b = max(x, -size / 2), min(x + w, size / 2)
            if size / 2 - b < 0.5:
                b = size / 2
                w = b - x
            if b - a > 0.2:
                top = 0.1 + thick + rng.uniform(-0.015, 0.01)
                s = block("slab", (b - a - 0.05, h - 0.05, thick), ((a + b) / 2, y + h / 2, top - thick / 2),
                          bevel=0.04, segments=2, mat=m["walk"], tint=random_tint(rng, 0.14, 0.04),
                          rot=(rng.uniform(-0.01, 0.01), rng.uniform(-0.01, 0.01), 0))
                kit.jitter_vertices(s, rng, 0.008)
                parts.append(s)
            x += w
        y += h
    return parts


def gatehouse(p: dict, m: dict, rng) -> list:
    """A gatehouse over a gate: a stone block standing on the wall top across the gate, arrow slits
    front and back, a row of corbels carrying an overhanging crenellated parapet, and a slate roof.
    The lowest band (z 0..1) sits behind the gate's lintel; the front faces the courtyard (-Y).
    Tall enough to hide the raised portcullis (it rises 4.6 m above a 5 m gate)."""
    W, D = p.get("width_m", 12.0), p.get("depth_m", 3.4)
    body_h = p.get("body_m", 5.0)
    lintel_d = p.get("lintel_depth_m", 1.0)  # the lower band starts behind the lintel
    hw, hd = W / 2, D / 2
    parts = [block("core", (W - 0.6, D - 0.6, body_h - 1.0), (0, 0, 1.0 + (body_h - 1.0) / 2), bevel=0,
                   mat=m["mortar"]),
             block("core_low", (W - 0.6, D - lintel_d - 0.3, 1.2), (0, (lintel_d - 0.3) / 2 + 0.15, 0.6), bevel=0,
                   mat=m["mortar"])]
    slits_front = [-3.4, 3.4]
    slits_back = [-2.6, 2.6]

    big = dict(course=(0.72, 0.92), width=(1.4, 2.3))
    ashlar(parts, m, rng, "x", -hd, -1, -hw, hw, 1.0, body_h, **big)
    ashlar(parts, m, rng, "x", hd, 1, -hw, hw, 0.0, body_h, **big)
    for s in (-1, 1):
        ashlar(parts, m, rng, "y", s * hw, s, -hd + 0.3, hd - 0.3, 1.0, body_h, **big)
        ashlar(parts, m, rng, "y", s * hw, s, -hd + lintel_d, hd - 0.3, 0.0, 1.0, course=(1.0, 1.0),
               width=(0.9, 1.5))
    # the lower band's front, behind the lintel
    ashlar(parts, m, rng, "x", -hd + lintel_d, -1, -hw + 0.3, hw - 0.3, 0.0, 1.0, course=(1.0, 1.0),
           width=(1.2, 2.0), depth=0.3)
    # quoins on the four vertical corners
    for sx in (-1, 1):
        for sy in (-1, 1):
            z = 0.0 if sy > 0 else 1.0
            i = 0
            while z < body_h - 0.05:
                ch = min(rng.uniform(0.5, 0.65), body_h - z)
                w = 0.75 if i % 2 == 0 else 0.62
                q = block("quoin", (w, w, ch - GAP), (sx * (hw - w / 2 + 0.05), sy * (hd - w / 2 + 0.05), z + ch / 2),
                          bevel=0.04, segments=1, mat=m["stone"], tint=random_tint(rng, 0.08))
                kit.jitter_vertices(q, rng, 0.012)
                parts.append(q)
                z += ch
                i += 1
    for u in slits_front:
        slit(parts, m, "x", -hd, -1, u, 2.9, h=1.3)
    for u in slits_back:
        slit(parts, m, "x", hd, 1, u, 2.7, h=1.2)
    # string course, corbels and the overhanging parapet (front and back)
    over = 0.4
    for sy in (-1, 1):
        parts.append(block("string", (W + 0.1, 0.3, 0.22), (0, sy * (hd + 0.05), body_h - 0.55), bevel=0.03,
                           segments=1, mat=m["stone"], tint=random_tint(rng, 0.06)))
        n = 9
        for i in range(n):
            x = -hw + 0.5 + i * (W - 1.0) / (n - 1)
            for k, (dz, dy) in enumerate(((0.0, 0.18), (0.28, 0.32))):  # a joint between the steps
                parts.append(block("corbel", (0.34, 0.3 + dy, 0.26), (x, sy * (hd + dy / 2 - 0.1), body_h - 0.3 + dz),
                                   bevel=0.03, segments=1, mat=m["stone"], tint=random_tint(rng, 0.08), taper=0.0))
        parts.append(block("ledge", (W + 2 * over - 0.2, 0.62, 0.22), (0, sy * (hd + over - 0.31), body_h + 0.3),
                           bevel=0.03, segments=1, mat=m["stone"], tint=random_tint(rng, 0.06)))
        y_front = -(hd + over) if sy < 0 else hd + over - 0.55
        merlon_row(parts, m, rng, -hw - over + 0.1, hw + over - 0.1, y_front, 0.55, body_h + 0.41, 0.45, 0.95,
                   1.75, segments=1)
    for sx in (-1, 1):  # parapet on the short sides
        merlon_row(parts, m, rng, -hd + 0.2, hd - 0.2, sx * (hw + 0.1) - (0.55 if sx > 0 else 0.0), 0.55,
                   body_h + 0.0, 0.85, 0.95, 1.75, axis="y", segments=1)
    # a steep slate roof rising well above the parapet, with an iron ridge and finials
    roof_h = p.get("roof_m", 3.4)
    parts.append(prism("roof", W - 0.9, D - 0.5, roof_h, (0, 0, body_h + 0.3), mat=m["slate"],
                       tint=random_tint(rng, 0.05), bevel=0.03))
    parts.append(block("ridge", (W - 0.8, 0.16, 0.14), (0, 0, body_h + 0.3 + roof_h), bevel=0.02, mat=m["iron"]))
    for sx in (-1, 1):
        parts.append(cylinder("finial", 0.07, 1.0, (sx * (W / 2 - 0.55), 0, body_h + 0.8 + roof_h), sides=6,
                              radius_top=0.0, mat=m["iron"]))
    return parts


def turret(p: dict, m: dict, rng) -> list:
    """A corner turret corbelled out from the wall top: a stepped corbel cone, a drum of stone
    courses with arrow slits, a crenel ring and a conical slate roof with an iron finial.
    The corbelling (z 0 .. corbel_m) hangs below the wall top."""
    r = p.get("radius_m", 1.7)
    corbel_h = p.get("corbel_m", 1.3)
    drum_h = p.get("drum_m", 3.0)
    roof_h = p.get("roof_m", 3.6)
    parts = []
    steps = 4
    for i in range(steps):  # stepped corbel rings, widening upward
        rr = r * (0.35 + 0.65 * (i + 1) / steps)
        z = i * corbel_h / steps
        parts.append(cylinder("corbel", rr * 0.92, corbel_h / steps - 0.03, (0, 0, z + corbel_h / steps / 2), sides=16,
                              radius_top=rr, bevel=0.03, mat=m["stone"], tint=random_tint(rng, 0.08),
                              rot=(0, 0, rng.uniform(0, 1))))
    z = corbel_h
    while z < corbel_h + drum_h - 0.05:
        ch = min(rng.uniform(0.5, 0.65), corbel_h + drum_h - z)
        d = cylinder("drum", r * rng.uniform(0.97, 1.0), ch - GAP, (0, 0, z + ch / 2), sides=16, bevel=0.03,
                     mat=m["stone"], tint=random_tint(rng, 0.1), rot=(0, 0, rng.uniform(0, math.pi)))
        kit.jitter_vertices(d, rng, 0.015)
        parts.append(d)
        z += ch
    top = corbel_h + drum_h
    for a in (math.radians(-90), math.radians(-90) + 1.2, math.radians(-90) - 1.2):  # slits toward -Y
        c = (math.cos(a) * (r - 0.1), math.sin(a) * (r - 0.1))
        parts.append(block("slit", (0.18, 0.3, 1.0), (c[0], c[1], corbel_h + drum_h * 0.55),
                           rot=(0, 0, a + math.pi / 2), bevel=0.02, mat=m["void"]))
        for s in (-1, 1):
            parts.append(block("jamb", (0.2, 0.3, 1.1), (c[0] + s * 0.19 * math.cos(a + math.pi / 2),
                                                        c[1] + s * 0.19 * math.sin(a + math.pi / 2),
                                                        corbel_h + drum_h * 0.55),
                               rot=(0, 0, a + math.pi / 2), bevel=0.02, mat=m["stone"], tint=random_tint(rng, 0.06)))
    parts.append(cylinder("band", r + 0.14, 0.24, (0, 0, top + 0.12), sides=16, bevel=0.03, mat=m["stone"],
                          tint=random_tint(rng, 0.05)))
    parts.append(lathe("roof", [(r + 0.35, 0.0), (r + 0.2, 0.25), (r * 0.55, roof_h * 0.55), (0.0, roof_h)],
                       loc=(0, 0, top + 0.24), sides=16, mat=m["slate"], tint=random_tint(rng, 0.05)))
    parts.append(cylinder("finial", 0.06, 0.9, (0, 0, top + 0.24 + roof_h + 0.3), sides=6, mat=m["iron"]))
    parts.append(lathe("knob", [(0.0, -0.1), (0.13, 0.0), (0.0, 0.14)], loc=(0, 0, top + 0.24 + roof_h + 0.3),
                       sides=8, mat=m["iron"]))
    return parts


# ----------------------------------------------------------------------------- skyline

def _windows(parts, m, rng, axis, plane, outward, us, zs, lit: float, lit_mat, w=0.7, h=1.2):
    """Dark window insets with a sill; a fraction `lit` glow warm (emissive, kept unbaked)."""
    glow_parts = []
    for u in us:
        for z in zs:
            is_lit = rng.random() < lit
            c_n = plane + outward * 0.02
            size = (w, 0.12, h) if axis == "x" else (0.12, w, h)
            loc = (u, c_n, z) if axis == "x" else (c_n, u, z)
            if is_lit:
                o = block("window", size, loc, bevel=0, mat=lit_mat)
                glow_parts.append(o)
            else:
                parts.append(block("window", size, loc, bevel=0.01, mat=m["void"]))
            sill = (w + 0.3, 0.25, 0.14) if axis == "x" else (0.25, w + 0.3, 0.14)
            sl = (u, plane + outward * 0.08, z - h / 2 - 0.08) if axis == "x" else (plane + outward * 0.08, u, z - h / 2 - 0.08)
            parts.append(block("sill", sill, sl, bevel=0.02, mat=m["far_stone"]))
    return glow_parts


def skyline_keep(p: dict, m: dict, rng):
    """A distant keep: a massive square tower with string courses, corner turrets with conical
    roofs, a crenellated crown and a few lit windows. Low detail, seen as a silhouette."""
    s = p.get("size_m", 14.0)
    h = p.get("height_m", 24.0)
    hs = s / 2
    parts = [block("body", (s, s, h), (0, 0, h / 2), bevel=0.15, segments=1, mat=m["far_stone"])]
    parts.append(block("plinth", (s + 0.8, s + 0.8, 3.0), (0, 0, 1.5), bevel=0.15, taper=0.03, mat=m["far_stone"],
                       tint=(0.9, 0.9, 0.9)))
    for z in (h * 0.36, h * 0.68):
        parts.append(block("string", (s + 0.4, s + 0.4, 0.45), (0, 0, z), bevel=0.08, mat=m["far_stone"],
                           tint=(1.08, 1.08, 1.08)))
    lit_mat = glow("window_lit", p.get("window_color", "#ffae5c"), p.get("window_glow", 3.0))
    glow_parts = []
    for axis, sgn in (("x", -1), ("x", 1), ("y", -1), ("y", 1)):
        glow_parts += _windows(parts, m, rng, axis, sgn * hs, sgn, [-3.2, 0.0, 3.2], [h * 0.52, h * 0.82], 0.25,
                               lit_mat, w=0.8, h=1.6)
    # corbelled crown and merlons
    parts.append(block("crown", (s + 1.2, s + 1.2, 0.6), (0, 0, h + 0.3), bevel=0.1, mat=m["far_stone"]))
    for axis in ("x", "y"):
        for sgn in (-1, 1):
            for i in range(6):
                u = -hs + 0.9 + i * (s - 1.8) / 5
                pos = (u, sgn * (hs + 0.3), h + 1.2) if axis == "x" else (sgn * (hs + 0.3), u, h + 1.2)
                size = (1.1, 0.7, 1.3) if axis == "x" else (0.7, 1.1, 1.3)
                parts.append(block("merlon", size, pos, bevel=0.06, mat=m["far_stone"], tint=random_tint(rng, 0.06)))
    # corner turrets
    tr = p.get("turret_radius_m", 2.0)
    th = h + p.get("turret_extra_m", 4.0)
    for sx in (-1, 1):
        for sy in (-1, 1):
            c = (sx * (hs - 0.4), sy * (hs - 0.4))
            parts.append(cylinder("turret", tr, th - h * 0.6, (c[0], c[1], h * 0.6 + (th - h * 0.6) / 2), sides=12,
                                  bevel=0.06, mat=m["far_stone"], tint=random_tint(rng, 0.05)))
            parts.append(cylinder("corbel", tr * 0.5, 1.6, (c[0], c[1], h * 0.6 - 0.8), sides=12, radius_top=tr,
                                  mat=m["far_stone"]))
            parts.append(lathe("cone", [(tr + 0.35, 0.0), (tr * 0.5, 2.8), (0.0, 5.2)], loc=(c[0], c[1], th),
                               sides=12, mat=m["far_roof"], tint=random_tint(rng, 0.05)))
    # a tall central roof behind the crown
    parts.append(cylinder("roof", (s - 2.0) * 0.72, 5.5, (0, 0, h + 0.6 + 2.75), sides=4, radius_top=0.3,
                          rot=(0, 0, math.pi / 4), mat=m["far_roof"]))
    return parts, glow_parts


def skyline_tower(p: dict, m: dict, rng):
    """A distant round tower with a machicolated ring and a tall conical roof."""
    r, h = p.get("radius_m", 3.4), p.get("height_m", 18.0)
    parts = [lathe("body", [(r * 1.12, 0.0), (r * 1.05, 2.0), (r, 3.0), (r * 0.97, h)], sides=14,
                   mat=m["far_stone"], tint=random_tint(rng, 0.05))]
    for z in (h * 0.4,):
        parts.append(cylinder("string", r * 1.02, 0.4, (0, 0, z), sides=14, mat=m["far_stone"], tint=(1.08, 1.08, 1.08)))
    parts.append(cylinder("mach", r * 0.97, 1.4, (0, 0, h + 0.2), sides=14, radius_top=r + 0.6, mat=m["far_stone"]))
    parts.append(cylinder("ring", r + 0.6, 1.4, (0, 0, h + 1.6), sides=14, bevel=0.05, mat=m["far_stone"],
                          tint=random_tint(rng, 0.05)))
    lit_mat = glow("window_lit", p.get("window_color", "#ffae5c"), p.get("window_glow", 3.0))
    glow_parts = []
    for i in range(5):
        a = -math.pi / 2 + (i - 2) * 0.7
        z = h * (0.55 if i % 2 else 0.75)
        pos = (math.cos(a) * (r - 0.02), math.sin(a) * (r - 0.02), z)
        o = block("window", (0.7, 0.2, 1.3), pos, rot=(0, 0, a + math.pi / 2), bevel=0,
                  mat=lit_mat if i == 1 else m["void"])
        (glow_parts if i == 1 else parts).append(o)
    parts.append(lathe("roof", [(r + 0.9, 0.0), (r * 0.6, h * 0.25), (0.0, h * 0.55)], loc=(0, 0, h + 2.3),
                       sides=14, mat=m["far_roof"], tint=random_tint(rng, 0.05)))
    parts.append(cylinder("spike", 0.12, 2.0, (0, 0, h + 2.3 + h * 0.55 + 0.8), sides=6, radius_top=0.0, mat=m["iron"]))
    return parts, glow_parts


def skyline_houses(p: dict, m: dict, rng):
    """A row of tall town houses beyond the walls: plaster upper floors on stone ground floors, steep
    slate roofs and chimneys, a lit window or two. About `width_m` wide; the front faces -Y."""
    total = p.get("width_m", 16.0)
    depth = p.get("depth_m", 7.0)
    parts = []
    lit_mat = glow("window_lit", p.get("window_color", "#ffae5c"), p.get("window_glow", 3.0))
    glow_parts = []
    x = -total / 2
    while x < total / 2 - 0.5:
        w = min(rng.uniform(3.6, 5.2), total / 2 - x)
        if total / 2 - (x + w) < 2.5:
            w = total / 2 - x
        cx = x + w / 2
        h = rng.uniform(7.5, 11.5)
        dy = rng.uniform(-0.6, 0.6)
        stone_h = rng.uniform(2.6, 3.4)
        parts.append(block("ground", (w - 0.1, depth, stone_h), (cx, dy, stone_h / 2), bevel=0.08,
                           mat=m["far_stone"], tint=random_tint(rng, 0.08)))
        jetty = 0.35
        parts.append(block("upper", (w - 0.1, depth + jetty * 2, h - stone_h), (cx, dy, stone_h + (h - stone_h) / 2),
                           bevel=0.06, mat=m["plaster"], tint=random_tint(rng, 0.1, 0.05)))
        # timber frame: corner posts and floor beams on the front
        yf = dy - depth / 2 - jetty - 0.03
        for bx in (cx - w / 2 + 0.2, cx + w / 2 - 0.2):
            parts.append(block("post", (0.25, 0.14, h - stone_h), (bx, yf, stone_h + (h - stone_h) / 2), bevel=0.02,
                               mat=m["dark_wood"]))
        for bz in (stone_h + 0.12, stone_h + (h - stone_h) * 0.5):
            parts.append(block("beam", (w - 0.1, 0.16, 0.24), (cx, yf, bz), bevel=0.02, mat=m["dark_wood"]))
        glow_parts += _windows(parts, m, rng, "x", yf, -1, [cx - w * 0.22, cx + w * 0.22],
                               [stone_h + (h - stone_h) * 0.3, stone_h + (h - stone_h) * 0.76], 0.18, lit_mat,
                               w=0.6, h=1.0)
        roof_h = rng.uniform(3.8, 5.5)
        gable_front = rng.random() < 0.45
        if gable_front:  # ridge runs front to back
            parts.append(prism("roof", depth + jetty * 2 + 0.6, w + 0.5, roof_h, (cx, dy, h), rot=(0, 0, math.pi / 2),
                               mat=m["far_roof"], tint=random_tint(rng, 0.08)))
        else:
            parts.append(prism("roof", w + 0.3, depth + jetty * 2 + 0.8, roof_h, (cx, dy, h), mat=m["far_roof"],
                               tint=random_tint(rng, 0.08)))
        if rng.random() < 0.8:
            chx = cx + rng.uniform(-w * 0.3, w * 0.3)
            parts.append(block("chimney", (0.7, 0.7, roof_h + 1.4), (chx, dy + depth * 0.2, h + (roof_h + 1.4) / 2),
                               bevel=0.04, mat=m["far_stone"], tint=random_tint(rng, 0.08)))
            parts.append(block("pot", (0.9, 0.9, 0.2), (chx, dy + depth * 0.2, h + roof_h + 1.5), bevel=0.03,
                               mat=m["far_stone"]))
        x += w
    return parts, glow_parts


def skyline_spire(p: dict, m: dict, rng):
    """A distant bell tower: a square stone tower with belfry openings and a tall octagonal spire."""
    s, h = p.get("size_m", 5.5), p.get("height_m", 20.0)
    hs = s / 2
    parts = [block("body", (s, s, h), (0, 0, h / 2), bevel=0.1, mat=m["far_stone"], tint=random_tint(rng, 0.05))]
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(block("buttress", (1.0, 1.0, h * 0.7), (sx * hs, sy * hs, h * 0.35), bevel=0.08, taper=0.25,
                               mat=m["far_stone"], tint=random_tint(rng, 0.05)))
    for axis, sgn in (("x", -1), ("x", 1), ("y", -1), ("y", 1)):
        for u in (-0.9, 0.9):
            pos = (u, sgn * hs, h - 2.6) if axis == "x" else (sgn * hs, u, h - 2.6)
            size = (0.9, 0.2, 2.6) if axis == "x" else (0.2, 0.9, 2.6)
            parts.append(block("belfry", size, pos, bevel=0, mat=m["void"]))
    parts.append(block("cornice", (s + 0.6, s + 0.6, 0.5), (0, 0, h + 0.25), bevel=0.06, mat=m["far_stone"]))
    parts.append(cylinder("spire", hs * 1.02, p.get("spire_m", 14.0), (0, 0, h + 0.5 + p.get("spire_m", 14.0) / 2),
                          sides=8, radius_top=0.08, rot=(0, 0, math.pi / 8), mat=m["far_roof"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(cylinder("pinnacle", 0.4, 2.4, (sx * hs, sy * hs, h + 1.7), sides=4, radius_top=0.0,
                                  rot=(0, 0, math.pi / 4), mat=m["far_stone"]))
    return parts


# ----------------------------------------------------------------------------- props

def _crate(parts, m, rng, size, loc, yaw=0.0):
    """A plank crate: a frame of edge battens around plank panels, iron corner plates."""
    sx, sy, sz = size
    obs = []
    # core panel box of planks (slightly inset), planks run horizontally on the sides
    obs.append(block("core", (sx - 0.1, sy - 0.1, sz - 0.1), (0, 0, sz / 2), bevel=0.0, mat=m["wood"],
                     tint=random_tint(rng, 0.1, 0.05)))
    n = 3
    for face in range(4):
        along = sx if face % 2 == 0 else sy
        off = (sy if face % 2 == 0 else sx) / 2 - 0.05
        for i in range(n):
            z = 0.08 + (sz - 0.16) * (i + 0.5) / n
            ph = (sz - 0.16) / n - 0.025
            if face % 2 == 0:
                o = block("plank", (along - 0.14, 0.05, ph), (0, (off) * (1 if face == 0 else -1), z), bevel=0.01,
                          mat=m["wood"], tint=random_tint(rng, 0.14, 0.06))
            else:
                o = block("plank", (0.05, along - 0.14, ph), ((off) * (1 if face == 1 else -1), 0, z), bevel=0.01,
                          mat=m["wood"], tint=random_tint(rng, 0.14, 0.06))
            obs.append(o)
    # edge battens (12 edges)
    bt = 0.09
    for ex in (-1, 1):
        for ey in (-1, 1):
            obs.append(block("batten", (bt, bt, sz), (ex * (sx / 2 - bt / 2), ey * (sy / 2 - bt / 2), sz / 2), bevel=0.012,
                             mat=m["dark_wood"], tint=random_tint(rng, 0.1)))
    for ez in (bt / 2, sz - bt / 2):
        for ey in (-1, 1):
            obs.append(block("batten", (sx - 2 * bt + 0.01, bt, bt), (0, ey * (sy / 2 - bt / 2), ez), bevel=0.012,
                             mat=m["dark_wood"], tint=random_tint(rng, 0.1)))
        for ex in (-1, 1):
            obs.append(block("batten", (bt, sy - 2 * bt + 0.01, bt), (ex * (sx / 2 - bt / 2), 0, ez), bevel=0.012,
                             mat=m["dark_wood"], tint=random_tint(rng, 0.1)))
    # a diagonal brace on two faces
    diag = math.atan2(sz - 2 * bt, sx - 2 * bt)
    obs.append(block("brace", (math.hypot(sx - 2 * bt, sz - 2 * bt) - 0.05, 0.05, 0.1), (0, -sy / 2 + 0.02, sz / 2),
                     rot=(0, -diag, 0), bevel=0.01, mat=m["dark_wood"], tint=random_tint(rng, 0.1)))
    # iron corner caps on the top corners
    for ex in (-1, 1):
        for ey in (-1, 1):
            obs.append(block("cap", (0.16, 0.16, 0.12), (ex * (sx / 2 - 0.06), ey * (sy / 2 - 0.06), sz - 0.055),
                             bevel=0.012, mat=m["iron"]))
    apply_xf(obs)
    for o in obs:
        o.rotation_euler = (0, 0, yaw)
        o.location = loc
    apply_xf(obs)
    parts += obs


def crate(p: dict, m: dict, rng) -> list:
    """A single plank crate with battens, a brace and iron corner caps."""
    parts: list = []
    _crate(parts, m, rng, p.get("size", (1.0, 1.0, 0.9)), (0, 0, 0))
    return parts


def crate_stack(p: dict, m: dict, rng) -> list:
    """Two crates side by side and a smaller one on top, turned a little; a sack leaning against them."""
    parts: list = []
    _crate(parts, m, rng, (1.0, 0.95, 0.9), (-0.55, 0.0, 0.0), rng.uniform(-0.08, 0.08))
    _crate(parts, m, rng, (0.95, 0.95, 0.85), (0.52, 0.05, 0.0), rng.uniform(-0.12, 0.12))
    _crate(parts, m, rng, (0.8, 0.75, 0.7), (-0.2, 0.05, 0.9), 0.35)
    sack = lathe("sack", [(0.3, 0.0), (0.38, 0.15), (0.34, 0.45), (0.16, 0.62), (0.1, 0.72), (0.0, 0.78)],
                 loc=(0.9, -0.55, 0.0), sides=10, mat=m["cloth"], tint=random_tint(rng, 0.05), rot=(0.15, 0.1, 0))
    kit.jitter_vertices(sack, rng, 0.02)
    parts.append(sack)
    return parts


def _barrel(parts, m, rng, loc, rot=(0, 0, 0), r=0.34, h=0.95):
    prof = [(r * 0.84, 0.0), (r * 0.93, h * 0.12), (r, h * 0.5), (r * 0.93, h * 0.88), (r * 0.84, h)]
    body = lathe("barrel", prof, sides=16, mat=m["wood"], tint=random_tint(rng, 0.1, 0.05))
    obs = [body]
    # staves: shallow vertical grooves suggested by thin dark battens
    for i in range(8):
        a = i * math.tau / 8 + rng.uniform(-0.05, 0.05)
        obs.append(block("stave", (0.035, 0.03, h * 0.72), (math.cos(a) * (r - 0.005), math.sin(a) * (r - 0.005), h / 2),
                         rot=(0, 0, a + math.pi / 2), bevel=0, mat=m["dark_wood"]))
    for z, rr in ((h * 0.1, r * 0.92), (h * 0.3, r * 0.99), (h * 0.7, r * 0.99), (h * 0.9, r * 0.92)):
        obs.append(lathe("hoop", [(rr + 0.012, z - 0.035), (rr + 0.022, z), (rr + 0.012, z + 0.035)], sides=16,
                         mat=m["iron"]))
        # (the hoop's open ends are capped, so it stays a closed ring over the body)
    obs.append(cylinder("lid", r * 0.8, 0.03, (0, 0, h - 0.01), sides=16, mat=m["dark_wood"]))
    apply_xf(obs)
    for o in obs:
        o.rotation_euler = rot
        o.location = loc
    apply_xf(obs)
    parts += obs


def barrel(p: dict, m: dict, rng) -> list:
    """A single iron-hooped barrel."""
    parts: list = []
    _barrel(parts, m, rng, (0, 0, 0))
    return parts


def barrel_group(p: dict, m: dict, rng) -> list:
    """Two standing barrels and one on its side, chocked with a plank."""
    parts: list = []
    _barrel(parts, m, rng, (-0.42, 0.1, 0))
    _barrel(parts, m, rng, (0.3, 0.2, 0), r=0.31, h=0.85)
    _barrel(parts, m, rng, (0.05, -0.58, 0.31 + 0.0), rot=(0, math.pi / 2, 0.15), r=0.3, h=0.85)
    parts.append(block("chock", (0.12, 0.5, 0.1), (0.52, -0.62, 0.05), rot=(0, 0, 0.15), bevel=0.01, mat=m["dark_wood"]))
    return parts


def rubble(p: dict, m: dict, rng) -> list:
    """Broken masonry fallen from the wall: a low heap of chipped blocks and chips on a dirt spill."""
    parts = []
    spread = p.get("spread_m", 1.6)
    heap = lathe("spill", [(spread * 0.5, 0.0), (spread * 0.38, 0.07), (spread * 0.18, 0.15), (0.0, 0.19)],
                 sides=12, mat=m["dirt"], tint=random_tint(rng, 0.06))
    heap.scale = (1.0, 0.75, 1.0)
    apply_xf([heap])
    kit.jitter_vertices(heap, rng, 0.05)
    parts.append(heap)
    for i in range(p.get("blocks", 12)):
        big = i < 4
        s = (rng.uniform(0.35, 0.6), rng.uniform(0.28, 0.45), rng.uniform(0.2, 0.32)) if big else \
            (rng.uniform(0.12, 0.25), rng.uniform(0.1, 0.2), rng.uniform(0.08, 0.14))
        a = rng.uniform(0, math.tau)
        d = rng.uniform(0, spread * (0.35 if big else 0.6))
        o = block("rubble", s, (math.cos(a) * d, math.sin(a) * d * 0.75, s[2] * 0.4 + (0.1 if big else 0.05)),
                  rot=(rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), rng.uniform(0, math.pi)), bevel=0.02,
                  segments=1, mat=m["stone"], tint=random_tint(rng, 0.12))
        kit.jitter_vertices(o, rng, 0.02)
        parts.append(o)
    # one large coping slab, cracked in two, leaning on the heap
    for k in (-1, 1):
        o = block("slab", (0.55, 0.6, 0.3), (k * 0.33 + 0.2, spread * 0.2, 0.22), rot=(0.1 * k, 0.28 * k, 0.1 * k),
                  bevel=0.03, segments=1, mat=m["stone"], tint=random_tint(rng, 0.06))
        kit.jitter_vertices(o, rng, 0.015)
        parts.append(o)
    return parts


def _chain(parts, m, p0, p1, sag: float, link: float = 0.11, thick: float = 0.018):
    """Links along a hanging curve from p0 to p1 (a parabola sagging by `sag`)."""
    from mathutils import Vector
    a, b = Vector(p0), Vector(p1)
    length = (b - a).length + sag * 1.5
    n = max(2, int(length / (link * 0.78)))
    pts = []
    for i in range(n + 1):
        t = i / n
        q = a.lerp(b, t)
        q.z -= sag * 4 * t * (1 - t)
        pts.append(q)
    for i in range(n):
        c = (pts[i] + pts[i + 1]) / 2
        d = (pts[i + 1] - pts[i]).normalized()
        rot = Vector((0, 0, 1)).rotation_difference(d).to_euler()
        o = torus("link", link / 2 - thick, thick, (0, 0, 0), seg=(8, 4), mat=m["iron"], scale=(0.62, 1, 1))
        # the torus lies in xy; stand it on its long axis (y -> z), alternate links turn 90 degrees
        o.rotation_euler = (math.pi / 2, 0, (math.pi / 2) * (i % 2))
        apply_xf([o])
        o.rotation_euler = rot
        o.location = c
        apply_xf([o])
        parts.append(o)


def wall_chains(p: dict, m: dict, rng) -> list:
    """Two iron wall plates with rings, a sagging chain between them and a shackle hanging from
    each. Mounted on a wall: back on y = 0, hanging toward -Y."""
    top = p.get("top_m", 2.4)
    span = p.get("span_m", 1.8)
    parts = []
    for sx in (-1, 1):
        x = sx * span / 2
        parts.append(block("plate", (0.26, 0.05, 0.3), (x, -0.025, top), bevel=0.012, mat=m["iron"]))
        for dz in (-0.1, 0.1):
            parts.append(cylinder("bolt", 0.03, 0.03, (x, -0.06, top + dz), rot=(math.pi / 2, 0, 0), sides=6,
                                  mat=m["iron"]))
        parts.append(torus("ring", 0.09, 0.022, (x, -0.1, top - 0.12), rot=(math.pi / 2, 0, math.pi / 2),
                           mat=m["iron"], seg=(10, 5)))
        drop = rng.uniform(0.7, 1.0)
        _chain(parts, m, (x, -0.1, top - 0.2), (x + sx * 0.02, -0.1, top - 0.2 - drop), 0.0)
        cuff_z = top - 0.3 - drop
        parts.append(torus("cuff", 0.08, 0.025, (x, -0.1, cuff_z), rot=(0, 0, 0), mat=m["iron"], seg=(10, 5)))
    _chain(parts, m, (-span / 2 + 0.06, -0.1, top - 0.2), (span / 2 - 0.06, -0.1, top - 0.2), 0.45)
    return parts


def weapon_rack(p: dict, m: dict, rng) -> list:
    """A wooden weapon rack: two posts on feet, a notched top rail and a foot rail, holding polearms
    (a spear, a broad glaive, a hooked bill) and a round shield leaning against it. The front faces -Y."""
    w = p.get("width_m", 2.0)
    parts = []
    for sx in (-1, 1):
        x = sx * (w / 2 - 0.08)
        parts.append(block("post", (0.12, 0.12, 1.55), (x, 0, 0.8), bevel=0.015, mat=m["dark_wood"], tint=random_tint(rng, 0.1)))
        parts.append(block("foot", (0.14, 0.7, 0.12), (x, 0, 0.06), bevel=0.015, mat=m["dark_wood"]))
    parts.append(block("rail", (w, 0.14, 0.12), (0, 0, 1.45), bevel=0.015, mat=m["wood"], tint=random_tint(rng, 0.1)))
    parts.append(block("rail", (w - 0.2, 0.3, 0.08), (0, 0.02, 0.25), bevel=0.015, mat=m["wood"], tint=random_tint(rng, 0.1)))
    lean = -0.16  # tilt back so the heads rest on the top rail
    kinds = ["spear", "glaive", "bill", "spear", "glaive"]
    n = p.get("weapons", 4)
    for i in range(n):
        x = -w / 2 + 0.35 + i * (w - 0.7) / max(1, n - 1)
        kind = kinds[i % len(kinds)]
        L = rng.uniform(2.1, 2.4)
        shaft = cylinder("shaft", 0.028, L, (0, 0, L / 2), sides=6, mat=m["wood"], tint=random_tint(rng, 0.12, 0.05))
        head = []
        if kind == "spear":
            head.append(cylinder("head", 0.05, 0.36, (0, 0, L + 0.16), sides=4, radius_top=0.0, mat=m["iron"]))
            head.append(cylinder("socket", 0.036, 0.12, (0, 0, L - 0.04), sides=6, mat=m["iron"]))
        elif kind == "glaive":
            head.append(block("blade", (0.13, 0.025, 0.55), (0.03, 0, L + 0.2), bevel=0.006, taper=0.3, mat=m["iron"]))
            head.append(block("spur", (0.12, 0.02, 0.05), (-0.07, 0, L + 0.02), rot=(0, 0.6, 0), bevel=0.004, mat=m["iron"]))
        else:
            head.append(block("blade", (0.2, 0.025, 0.3), (0.06, 0, L + 0.05), bevel=0.006, mat=m["iron"]))
            head.append(block("hook", (0.05, 0.02, 0.22), (-0.06, 0, L + 0.16), rot=(0, -0.5, 0), bevel=0.004, mat=m["iron"]))
            head.append(cylinder("spike", 0.03, 0.3, (0, 0, L + 0.33), sides=4, radius_top=0.0, mat=m["iron"]))
        group = [shaft] + head
        apply_xf(group)
        for o in group:
            o.rotation_euler = (lean, rng.uniform(-0.04, 0.04), 0)
            o.location = (x, 0.0, 0.2)
        apply_xf(group)
        parts += group
    # round shield leaning on the front of the rack: boards, rim, boss
    sh = [cylinder("shield", 0.41, 0.07, (0, 0, 0), sides=16, mat=m["wood"], tint=random_tint(rng, 0.1)),
          cylinder("rim", 0.45, 0.05, (0, 0, 0), sides=16, mat=m["iron"]),
          lathe("boss", [(0.12, 0.0), (0.11, 0.05), (0.05, 0.1), (0.0, 0.11)], loc=(0, 0, 0.02), sides=10,
                mat=m["iron"])]
    apply_xf(sh)
    for o in sh:
        o.rotation_euler = (math.pi / 2 - 0.3, 0, 0.15)
        o.location = (w * 0.22, -0.38, 0.44)
    apply_xf(sh)
    parts += sh
    return parts


def drain(p: dict, m: dict, rng) -> list:
    """A square iron drain grate in a stone frame, for the courtyard floor (top about flush)."""
    s = p.get("size_m", 1.0)
    parts = [block("pit", (s - 0.3, s - 0.3, 0.06), (0, 0, 0.03), bevel=0, mat=m["void"])]
    fw = 0.17
    for sy in (-1, 1):
        parts.append(block("frame", (s, fw, 0.12), (0, sy * (s / 2 - fw / 2), 0.06), bevel=0.02, mat=m["stone"],
                           tint=random_tint(rng, 0.08)))
        parts.append(block("frame", (fw, s - 2 * fw - 0.02, 0.12), (sy * (s / 2 - fw / 2), 0, 0.06), bevel=0.02,
                           mat=m["stone"], tint=random_tint(rng, 0.08)))
    inner = s - 2 * fw
    n = 6
    for i in range(n):
        x = -inner / 2 + inner * (i + 0.5) / n
        parts.append(block("bar", (0.035, inner + 0.04, 0.05), (x, 0, 0.085), bevel=0.006, mat=m["iron"]))
    for y in (-inner * 0.3, inner * 0.3):
        parts.append(block("bar", (inner + 0.04, 0.035, 0.04), (0, y, 0.075), bevel=0.006, mat=m["iron"]))
    return parts


def floor_tile_worn(p: dict, m: dict, rng) -> list:
    """4 x 4 m of flagstones like floor_tile, but worn: cracked flags split in two, a few sunken
    or tilted, stained ones, and a missing flag filled with dirt and chips."""
    size = p.get("size_m", 4.0)
    gap = 0.045
    thick = 0.14
    parts = [block("bed", (size, size, 0.1), (0, 0, 0.05), bevel=0, mat=m["mortar"])]
    y = -size / 2
    flags = []
    while y < size / 2 - 0.01:
        h = min(rng.uniform(0.75, 1.3), size / 2 - y)
        if size / 2 - (y + h) < 0.5:
            h = size / 2 - y
        x = -size / 2
        while x < size / 2 - 0.01:
            w = min(rng.uniform(0.7, 1.45), size / 2 - x)
            if size / 2 - (x + w) < 0.45:
                w = size / 2 - x
            flags.append((x, y, w, h))
            x += w
        y += h
    missing = set(rng.sample(range(len(flags)), p.get("missing", 1)))
    for i, (x, y, w, h) in enumerate(flags):
        if i in missing:
            dirt = block("dirt", (w - gap, h - gap, 0.1), (x + w / 2, y + h / 2, 0.15), bevel=0.03, mat=m["dirt"],
                         tint=random_tint(rng, 0.06))
            kit.jitter_vertices(dirt, rng, 0.02)
            parts.append(dirt)
            for k in range(4):
                c = block("chip", (rng.uniform(0.1, 0.22), rng.uniform(0.08, 0.18), 0.06),
                          (x + w / 2 + rng.uniform(-w / 3, w / 3), y + h / 2 + rng.uniform(-h / 3, h / 3), 0.2),
                          rot=(rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), rng.uniform(0, 3)), bevel=0.015,
                          mat=m["flag"], tint=random_tint(rng, 0.12))
                parts.append(c)
            continue
        r = rng.random()
        sunk = rng.uniform(0.015, 0.03) if r < 0.2 else 0.0
        tilt = 0.03 if r < 0.2 else 0.012
        stain = rng.uniform(0.6, 0.78) if rng.random() < 0.25 else 1.0
        top = 0.1 + thick + rng.uniform(-0.012, 0.012) - sunk
        cracked = w > 0.9 and rng.random() < 0.45
        pieces = []
        if cracked:  # split across its long side at a slight angle
            f = rng.uniform(0.35, 0.65)
            crack = 0.028
            if w >= h:
                pieces = [(x, y, w * f, h), (x + w * f + crack, y, w * (1 - f) - crack, h)]
            else:
                pieces = [(x, y, w, h * f), (x, y + h * f + crack, w, h * (1 - f) - crack)]
        else:
            pieces = [(x, y, w, h)]
        for (px, py, pw, ph) in pieces:
            t = random_tint(rng, 0.13)
            s = block("flag", (pw - gap, ph - gap, thick), (px + pw / 2, py + ph / 2, top - thick / 2), bevel=0.035,
                      segments=2, mat=m["flag"], tint=(t[0] * stain, t[1] * stain, t[2] * stain),
                      rot=(rng.uniform(-tilt, tilt), rng.uniform(-tilt, tilt), rng.uniform(-0.02, 0.02) if cracked else 0))
            kit.jitter_vertices(s, rng, 0.008)
            parts.append(s)
    return parts


PIECES = {
    "rampart": rampart, "wall_walk": wall_walk, "gatehouse": gatehouse, "turret": turret,
    "skyline_keep": skyline_keep, "skyline_tower": skyline_tower, "skyline_houses": skyline_houses,
    "skyline_spire": skyline_spire, "crate": crate, "crate_stack": crate_stack, "barrel": barrel,
    "barrel_group": barrel_group, "rubble": rubble, "wall_chains": wall_chains, "weapon_rack": weapon_rack,
    "drain": drain, "floor_tile_worn": floor_tile_worn,
}
BACK_ON_Y0 = {"rampart", "wall_chains"}
