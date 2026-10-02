"""Burning Foundry environment kit (backlog M2-10): a sooty foundry yard under a smoke-choked dusk.
Soot-blackened brick bound with riveted iron, a round blast furnace with glowing mouths at the
hub, two forged-iron crucibles of molten iron on wheeled bogies riding a rail ring, an overhead
crane arm turning with them, stacked casting flasks, coke braziers, a heavy iron grate gate, and
dressing (ingots, coal, a rack of foundry tools, a brick-and-iron gatehouse and a skyline of
smokestacks and works sheds). Hand-forged, riveted, industrial-medieval: no modern machinery.
The only saturated colour is the orange of molten metal and fire (separate emissive parts).
One piece per asset spec (data/assets/foundry_<piece>.json, params.piece).

Usage:
  python3 tools/blender/build_kit_foundry.py --spec data/assets/foundry_furnace.json --previews previews/m2_10
  python3 tools/blender/build_kit_foundry.py --all --previews previews/m2_10     # every foundry_* spec
  python3 tools/blender/build_kit_foundry.py --assembled previews/m2_10/foundry_assembled.png
      # imports the exported pieces: furnace, rail ring, crucibles at (0, +-9 m), crane arm on
      # top, walls and floor around them, to judge the scale relationships

Sizes and pivots match the crypt and gallows kits (Blender axes; the glTF exporter turns -Y into
Godot's +Z):
  floor_tile (4 x 4 m), corner, gate (8 x 5 m), gatehouse, brazier, ingot_stack, coal_heap,
  mold (length_m along x, width_m, height_m), skyline_*: centred, lowest point at z = 0.
  wall (4 x 6 m), gate_lintel (9 m), tool_rack: the front faces -Y and the mounting face lies
  on y = 0 (wall and tool_rack reach back into +Y; the lintel, like the crypt's, reaches 1 m
  forward into -Y from its back on y = 0); centred on x, lowest point at z = 0.
  furnace (radius_m, height_m), crucible (radius_m, height_m), rail_ring: built around the
  collider's axis (x = y = 0, kept as built so asymmetric details cannot shift it), lowest point
  at z = 0. The furnace's brick body ends at height_m (the collider's top); a narrower flue stack
  rises about 2 m above it (visual only, well inside the radius). The crucible's wheels roll
  along x (tangent to the ring when it stands at (0, +-9 m)); its pouring lip faces -Y.
  crane_arm: the origin is the pivot on the furnace's axis at the collar (the map places it
  collar_m = 6.3 m above the floor). Girders reach along +-Y; the chains drop from radius 9 m to
  z = -drop_m (the crucible tops), so the piece extends below its origin (asset pivot "grip").
Contact sheets are lit with the arena's preset (data/lighting/forge_glow.json).
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402  (first: it makes bmesh and mathutils importable)
import bmesh  # noqa: E402
from mathutils import Euler, Matrix, Vector  # noqa: E402

import common  # noqa: E402
import kit  # noqa: E402
from build_kit_gallows_dressing import _finish, _from_bmesh, apply_xf, lathe, prism, torus  # noqa: E402
from kit import block, cylinder  # noqa: E402

PRESET = "forge_glow"
GAP = 0.04  # brick joints: tight, dark with soot


def brick_tint(rng, spread: float = 0.14) -> tuple[float, float, float]:
    """Per-brick variation: mostly soot-brown, now and then a redder or a greyer, burnt brick."""
    v = 1.0 + rng.uniform(-spread, spread)
    r = rng.uniform(-0.05, 0.09)
    return (v * (1 + r), v, v * (1 - r * 0.8))


def iron_tint(rng, spread: float = 0.08) -> tuple[float, float, float]:
    v = 1.0 + rng.uniform(-spread, spread)
    w = rng.uniform(-0.02, 0.04)
    return (v * (1 + w), v, v * (1 - w))


def mats(pal: dict) -> dict:
    global _PAL
    _PAL = dict(pal)
    km = kit.kit_material
    rust = pal.get("rust", "#6a3a22")
    brick = pal.get("brick", "#4a3a33")
    iron = pal.get("iron", "#2f3133")
    return {
        # brick blackens with smoke toward the top, under ledges and in long streaks
        "brick": km("brick", brick, roughness=0.93, edge=0.34, cavity=0.62, top_light=0.12, mottle=0.14,
                    mottle_scale=0.5, soot=0.5, soot_m=4.5),
        "brick_dark": km("brick_dark", pal.get("brick_dark", "#2e2522"), roughness=0.93, edge=0.3, cavity=0.6,
                         top_light=0.12, mottle=0.12, mottle_scale=0.5, soot=0.45, soot_m=4.5),
        # scorched, reddened brick around furnace mouths and flues
        "brick_hot": km("brick_hot", brick, roughness=0.93, edge=0.34, cavity=0.62, top_light=0.12, mottle=0.14,
                        mottle_scale=0.6, soot=0.4, soot_m=4.5, heat=0.7, heat_color=pal.get("scorch", "#6e3219"),
                        heat_scale=2.0),
        "paver": km("paver", pal.get("paver", "#54453c"), roughness=0.9, edge=0.32, cavity=0.6, top_light=0.05,
                    mottle=0.16, mottle_scale=0.6, soot=0.35, soot_m=9.0),
        "mortar": km("mortar", pal.get("mortar", "#1a1614"), roughness=0.97, edge=0.0, cavity=0.3),
        # dark iron with bright worn edges and rust in broad patches
        "iron": km("iron", iron, roughness=0.6, metallic=0.3, edge=0.55, cavity=0.5, top_light=0.1, moss=0.4,
                   moss_color=rust, moss_scale=3.0, soot=0.25, soot_m=6.0),
        # heat-tempered iron: the crucible's pot, darkest and tinted toward its rim
        "iron_hot": km("iron_hot", iron, roughness=0.6, metallic=0.3, edge=0.5, cavity=0.5, top_light=0.1,
                       moss=0.3, moss_color=rust, moss_scale=3.0, heat=0.85, heat_color=pal.get("heat", "#3d2b36"),
                       heat_m=2.4, heat_scale=1.6),
        "slag": km("slag", pal.get("slag", "#3a3530"), roughness=0.9, edge=0.36, cavity=0.6, top_light=0.12,
                   mottle=0.25, mottle_scale=2.5),
        "coal": km("coal", pal.get("coal", "#141210"), roughness=0.7, edge=0.45, cavity=0.5, top_light=0.1,
                   mottle=0.1),
        "ash": km("ash", pal.get("ash", "#77706a"), roughness=0.97, edge=0.1, cavity=0.5, mottle=0.2,
                  mottle_scale=1.5),
        "sand": km("sand", pal.get("sand", "#3f352d"), roughness=0.97, edge=0.12, cavity=0.55, mottle=0.18,
                   mottle_scale=1.8),
        "pig": km("pig", pal.get("pig_iron", "#4a4744"), roughness=0.75, metallic=0.25, edge=0.45, cavity=0.5,
                  top_light=0.12, moss=0.35, moss_color=rust, moss_scale=4.0),
        "wood": km("wood", pal.get("wood", "#66503a"), roughness=0.88, edge=0.28, cavity=0.55, soot=0.3, soot_m=3.0),
        "void": km("void", pal.get("void", "#0c0a09"), roughness=0.95, edge=0.0, cavity=0.0, top_light=0.0,
                   mottle=0.0),
        "far_brick": km("far_brick", pal.get("far_brick", "#3b302b"), roughness=0.92, edge=0.22, cavity=0.5,
                        mottle=0.12, mottle_scale=0.15, soot=0.45, soot_m=14.0),
        "far_roof": km("far_roof", pal.get("far_roof", "#2c2f33"), roughness=0.85, edge=0.2, cavity=0.45,
                       top_light=0.1, mottle=0.1, mottle_scale=0.2),
    }


_PAL: dict = {}  # the current spec's palette (set by mats), for the emissive colours


def glow(name: str, hex_color: str, strength: float, base_hex: str = "#1c0a04") -> bpy.types.Material:
    """An emissive material for hot metal and embers (kept unbaked). Its base colour is a dark
    char, so lights and the sky do not wash the orange out toward pink; the glow carries it."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    b = mat.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = common.hex_to_linear(base_hex)
    b.inputs["Emission Color"].default_value = common.hex_to_linear(hex_color)
    b.inputs["Emission Strength"].default_value = strength
    b.inputs["Roughness"].default_value = 0.95
    return mat


def molten(p: dict, strength: float | None = None):
    """Emissive molten metal (kept unbaked, a separate part): params override the palette."""
    return glow("molten", p.get("molten", _PAL.get("molten", "#ff7a1a")),
                strength or p.get("molten_glow", 1.4))


def ember(p: dict, strength: float | None = None):
    """Emissive embers, dimmer and redder than molten metal."""
    return glow("ember", p.get("ember", _PAL.get("ember", "#c2410c")), strength or p.get("ember_glow", 1.8))


# ----------------------------------------------------------------------------- shapes

def group_xf(objs, loc=(0, 0, 0), rot=(0, 0, 0)) -> list:
    """Bake each object's own placement, then rotate the group about the origin by `rot` and
    translate it by `loc`."""
    apply_xf(objs)
    mx = Matrix.Translation(loc) @ Euler(rot).to_matrix().to_4x4()
    for o in objs:
        o.data.transform(mx)
    return objs


def beam(name: str, p0, p1, w: float, h: float, mat, tint=(1, 1, 1), bevel: float = 0.0, up=(0, 0, 1)):
    """A box beam from p0 to p1, w wide and h deep; its depth stays as close to `up` as it can."""
    a, b = Vector(p0), Vector(p1)
    x = (b - a).normalized()
    u = Vector(up)
    z = u - x * u.dot(x)
    if z.length < 1e-6:
        z = Vector((1, 0, 0)) - x * x.x
    z.normalize()
    y = z.cross(x)
    c = (a + b) / 2
    o = block(name, ((b - a).length, w, h), (0, 0, 0), bevel=bevel, mat=mat, tint=tint)
    o.data.transform(Matrix(((x.x, y.x, z.x, c.x), (x.y, y.y, z.y, c.y), (x.z, y.z, z.z, c.z), (0, 0, 0, 1))))
    return o


def rivet(m, loc, normal, r: float = 0.03, h: float = 0.024, key: str = "iron"):
    """A domed rivet head standing on a face whose outward normal is `normal`."""
    n = Vector(normal).normalized()
    rot = Vector((0, 0, 1)).rotation_difference(n).to_euler()
    c = Vector(loc) + n * (h / 2)
    return cylinder("rivet", r, h, tuple(c), rot=tuple(rot), sides=5, radius_top=r * 0.55, mat=m[key])


def rivet_row(m, p0, p1, n: int, normal, r: float = 0.03) -> list:
    a, b = Vector(p0), Vector(p1)
    return [rivet(m, a.lerp(b, (i + 0.5) / n), normal, r) for i in range(n)]


def arc_block(name: str, r0: float, r1: float, a0: float, a1: float, z0: float, z1: float, mat, tint=(1, 1, 1),
              bevel: float = 0.0, max_seg: float = 0.55):
    """A curved block: the ring sector r0..r1, angles a0..a1 (radians), z0..z1."""
    n = max(1, math.ceil((a1 - a0) * r1 / max_seg))
    bm = bmesh.new()
    secs = []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        c, s = math.cos(a), math.sin(a)
        secs.append([bm.verts.new((r * c, r * s, z)) for r, z in ((r0, z0), (r1, z0), (r1, z1), (r0, z1))])
    for i in range(n):
        A, B = secs[i], secs[i + 1]
        for k in range(4):
            k2 = (k + 1) % 4
            bm.faces.new((A[k], B[k], B[k2], A[k2]))
    bm.faces.new(list(reversed(secs[0])))
    bm.faces.new(secs[-1])
    o = _from_bmesh(bm, name)
    return _finish(o, name, mat, tint, bevel)


def revolve(name: str, loop, sides: int, mat, tint=(1, 1, 1), loc=(0, 0, 0), rot=(0, 0, 0), a0: float = 0.0):
    """A closed ring (torus topology) from a closed (radius, z) loop turned about z: hoops,
    collars, rails."""
    bm = bmesh.new()
    rings = []
    for i in range(sides):
        a = a0 + i * math.tau / sides
        c, s = math.cos(a), math.sin(a)
        rings.append([bm.verts.new((r * c, r * s, z)) for r, z in loop])
    k_n = len(loop)
    for i in range(sides):
        j = (i + 1) % sides
        for k in range(k_n):
            k2 = (k + 1) % k_n
            bm.faces.new((rings[i][k], rings[j][k], rings[j][k2], rings[i][k2]))
    o = _from_bmesh(bm, name)
    o.rotation_euler = rot
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, tint)


def hoop(name: str, r_in: float, r_out: float, z0: float, z1: float, sides: int, mat, tint=(1, 1, 1), chamfer: float = 0.0):
    """A flat iron band (rectangular section, optionally chamfered outer corners)."""
    c = min(chamfer, (z1 - z0) / 3, (r_out - r_in) / 2)
    loop = [(r_in, z0), (r_out - c, z0), (r_out, z0 + c), (r_out, z1 - c), (r_out - c, z1), (r_in, z1)] if c > 0 \
        else [(r_in, z0), (r_out, z0), (r_out, z1), (r_in, z1)]
    return revolve(name, loop, sides, mat, tint)


def chain(parts: list, m, p0, p1, link: float = 0.24, thick: float = 0.04, seg=(6, 4)) -> None:
    """A straight hanging chain of oval links from p0 to p1, alternate links turned 90 degrees."""
    a, b = Vector(p0), Vector(p1)
    d = b - a
    n = max(1, int(round(d.length / (link * 0.72))))
    rot = Vector((0, 0, 1)).rotation_difference(d.normalized()).to_euler()
    for i in range(n):
        c = a.lerp(b, (i + 0.5) / n)
        o = torus("link", link / 2 - thick, thick, (0, 0, 0), seg=seg, mat=m["iron"], scale=(0.6, 1, 1))
        o.rotation_euler = (math.pi / 2, 0, (math.pi / 2) * (i % 2))  # stand the oval on its long axis
        apply_xf([o])
        o.rotation_euler = rot
        o.location = c
        apply_xf([o])
        parts.append(o)


def wedge_plate(name: str, w0: float, w1: float, length: float, t: float, mat, loc=(0, 0, 0), tint=(1, 1, 1)):
    """A flat trapezoid plate t thick: w0 wide at y = 0, narrowing to w1 at y = -length."""
    bm = bmesh.new()
    vs = [bm.verts.new(c) for c in ((-w0 / 2, 0, 0), (w0 / 2, 0, 0), (w1 / 2, -length, 0), (-w1 / 2, -length, 0),
                                    (-w0 / 2, 0, t), (w0 / 2, 0, t), (w1 / 2, -length, t), (-w1 / 2, -length, t))]
    for f in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
        bm.faces.new([vs[i] for i in f])
    o = _from_bmesh(bm, name)
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, tint, 0.012)


def lump(name: str, r: float, loc, mat, rng=None, scale=(1, 1, 1), rot=(0, 0, 0), subdiv: int = 1, jitter: float = 0.0):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdiv, radius=r, location=(0, 0, 0))
    o = bpy.context.active_object
    kit.clear_uvs(o)
    if rng is not None and jitter:
        kit.jitter_vertices(o, rng, jitter)
    o.scale = scale
    o.rotation_euler = rot
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, (1, 1, 1))


def brick_face(parts: list, m, rng, axis: str, plane: float, outward: int, u0: float, u1: float, z0: float,
               z1: float, depth: float = 0.3, course=(0.31, 0.37), width=(0.72, 1.02), bevel: float = 0.022,
               key: str = "brick", dark: float = 0.15, skip=None, hot=None, jitter: float = 0.01,
               proud=(0.0, 0.02)) -> None:
    """A face of coursed brick in running bond. axis "x": the face runs along x and looks along
    `outward` * Y; axis "y": runs along y and looks along `outward` * X. `plane` is the brick fronts'
    coordinate. `skip(u, z)` leaves a brick out (an opening); `hot(u, z)` makes it scorched."""
    z = z0
    row = 0
    while z < z1 - 0.04:
        ch = min(rng.uniform(*course), z1 - z)
        if z1 - (z + ch) < course[0] * 0.6:
            ch = z1 - z
        u = u0 - (rng.uniform(0.15, 0.45) if row % 2 else rng.uniform(0.0, 0.1))
        while u < u1 - 0.01:
            w = rng.uniform(*width)
            a, b = max(u, u0), min(u + w, u1)
            if u1 - b < width[0] * 0.45:
                b = u1
                w = b - u
            uc, zc = (a + b) / 2, z + ch / 2
            if b - a > 0.12 and not (skip and skip(uc, zc)):
                front = plane + outward * rng.uniform(*proud)
                cn = front - outward * depth / 2
                k = "brick_hot" if hot and hot(uc, zc) else ("brick_dark" if rng.random() < dark else key)
                if axis == "x":
                    size, loc = (b - a - GAP, depth, ch - GAP), (uc, cn, zc)
                else:
                    size, loc = (depth, b - a - GAP, ch - GAP), (cn, uc, zc)
                s = block("brick", size, loc, bevel=bevel, mat=m[k], tint=brick_tint(rng))
                if jitter:
                    kit.jitter_vertices(s, rng, jitter)
                parts.append(s)
            u += w
        z += ch
        row += 1


def ring_courses(parts: list, m, rng, r_in: float, r_out: float, z0: float, z1: float, course=(0.4, 0.48),
                 length=(0.85, 1.15), openings=(), hot_margin: float = 0.0, key: str = "brick",
                 dark: float = 0.15, jitter: float = 0.012, max_seg: float = 0.55) -> None:
    """Courses of curved blocks around a round shaft (running bond). openings: (angle, half
    angle, z0, z1) where blocks are left out; blocks within hot_margin metres of an opening are
    scorched."""
    z = z0
    row = 0
    circ = math.tau * r_out
    while z < z1 - 0.04:
        ch = min(rng.uniform(*course), z1 - z)
        if z1 - (z + ch) < course[0] * 0.6:
            ch = z1 - z
        n = max(3, round(circ / ((length[0] + length[1]) / 2)))
        ws = [rng.uniform(*length) for _ in range(n)]
        k = math.tau / sum(ws)
        a = rng.uniform(0, math.tau) if row == 0 else a_start + ws[0] * k * 0.5  # noqa: F821
        a_start = a
        for w in ws:
            spans = [(a, a + w * k)]
            for ac, ha, oz0, oz1 in openings:
                if z + ch <= oz0 + 0.01 or z >= oz1 - 0.01:
                    continue
                nxt = []
                for s0, s1 in spans:
                    # opening edges relative to this span, the angle wrapped near it
                    mid = (s0 + s1) / 2
                    c = ac + math.tau * round((mid - ac) / math.tau)
                    lo, hi = c - ha, c + ha
                    if s1 <= lo or s0 >= hi:
                        nxt.append((s0, s1))
                        continue
                    if lo - s0 > 0.1 / r_out:
                        nxt.append((s0, lo))
                    if s1 - hi > 0.1 / r_out:
                        nxt.append((hi, s1))
                spans = nxt
            for s0, s1 in spans:
                gap = GAP / r_out / 2
                hot = False
                for ac, ha, oz0, oz1 in openings:
                    mid = (s0 + s1) / 2
                    c = ac + math.tau * round((mid - ac) / math.tau)
                    if abs(mid - c) < ha + hot_margin / r_out + (s1 - s0) / 2 and z < oz1 + hot_margin and z + ch > oz0 - 0.2:
                        hot = True
                kk = "brick_hot" if hot and hot_margin > 0 else ("brick_dark" if rng.random() < dark else key)
                rr = r_out + rng.uniform(-0.02, 0.0)
                o = arc_block("course", r_in, rr, s0 + gap, s1 - gap, z + GAP / 2, z + ch - GAP / 2, m[kk],
                              tint=brick_tint(rng), max_seg=max_seg)
                if jitter:
                    kit.jitter_vertices(o, rng, jitter)
                parts.append(o)
            a += w * k
        z += ch
        row += 1


def iron_band(parts: list, m, rng, x0: float, x1: float, y_front: float, z: float, h: float = 0.24,
              depth: float = 0.14, rivets: float = 0.42) -> None:
    """A flat riveted iron band course along x, its front at y_front (facing -Y)."""
    parts.append(block("band", (x1 - x0, depth, h), ((x0 + x1) / 2, y_front + depth / 2, z), bevel=0.012,
                       mat=m["iron"], tint=iron_tint(rng)))
    n = max(1, int((x1 - x0) / rivets))
    for zz in (z - h * 0.27, z + h * 0.27):
        parts += rivet_row(m, (x0, y_front, zz), (x1, y_front, zz), n, (0, -1, 0), r=0.026)


def anchor_plate(parts: list, m, loc, s: float = 1.0) -> None:
    """The end of a tie rod through a brick wall: a cross-shaped iron plate with a square nut,
    standing on a face that looks toward -Y."""
    x, y, z = loc
    for rot in (0.0, math.pi / 2):
        parts.append(block("anchor", (0.62 * s, 0.04, 0.13 * s), (x, y - 0.02, z), rot=(0, rot, 0), bevel=0.01,
                           mat=m["iron"], taper=0.0))
    parts.append(block("nut", (0.12 * s, 0.07, 0.12 * s), (x, y - 0.06, z), rot=(0, math.radians(12), 0), bevel=0.01,
                       mat=m["iron"]))
    parts.append(cylinder("rod_end", 0.035 * s, 0.1, (x, y - 0.1, z), rot=(math.pi / 2, 0, 0), sides=6, mat=m["iron"]))


# ----------------------------------------------------------------------------- floor

def floor_tile(p: dict, m: dict, rng) -> list:
    """4 x 4 m of soot-darkened brick pavers in basket weave (1 m cells of three pavers) mixed
    with riveted iron floor plates, slag spatter and scorch marks (darkened pavers around a few
    centres). With params.worn: cracked and missing pavers filled with cinders, a sunken plate
    and more slag. The top stays within about 0.05 m of flat."""
    size = p.get("size_m", 4.0)
    worn = bool(p.get("worn", False))
    half = size / 2
    thick = 0.12
    top0 = 0.1 + thick
    parts = [block("bed", (size, size, 0.1), (0, 0, 0.05), bevel=0, mat=m["mortar"])]
    cells = int(round(size))
    used = set()
    plates = []
    # one 2 x 2 m plate (two riveted halves) or two 1 x 2 m plates
    if rng.random() < 0.6:
        i, j = rng.randrange(cells - 1), rng.randrange(cells - 1)
        plates.append((i, j, 2, 2))
    else:
        for _ in range(2):
            for _try in range(20):
                along = rng.random() < 0.5
                w, h = (2, 1) if along else (1, 2)
                i, j = rng.randrange(cells - w + 1), rng.randrange(cells - h + 1)
                cs = {(i + a, j + b) for a in range(w) for b in range(h)}
                if not cs & used:
                    plates.append((i, j, w, h))
                    used |= cs
                    break
    for (i, j, w, h) in plates:
        used |= {(i + a, j + b) for a in range(w) for b in range(h)}
    scorch = [(rng.uniform(-half, half), rng.uniform(-half, half), rng.uniform(0.6, 1.1)) for _ in range(2 if worn else 1)]

    def scorch_f(x, y):
        f = 1.0
        for sx, sy, sr in scorch:
            f *= 1.0 - 0.6 * math.exp(-((x - sx) ** 2 + (y - sy) ** 2) / (sr * sr))
        return f

    # pavers
    for i in range(cells):
        for j in range(cells):
            if (i, j) in used:
                continue
            x0, y0 = -half + i, -half + j
            along_x = (i + j) % 2 == 0
            fg = 0.03  # floor joints are tighter than the walls': a calmer surface to fight on
            for k in range(3):
                if along_x:
                    cx, cy, sx, sy = x0 + 0.5, y0 + (k + 0.5) / 3, 1.0 - fg, 1 / 3 - fg
                else:
                    cx, cy, sx, sy = x0 + (k + 0.5) / 3, y0 + 0.5, 1 / 3 - fg, 1.0 - fg
                t = brick_tint(rng, 0.07)
                f = scorch_f(cx, cy)
                t = (t[0] * f, t[1] * f, t[2] * f)
                key = "brick_dark" if rng.random() < 0.06 else "paver"
                top = top0 + rng.uniform(-0.012, 0.008)
                r = rng.random()
                if worn and r < 0.08:  # missing: cinders and a chip in the hole
                    parts.append(block("cinders", (sx - 0.02, sy - 0.02, 0.07), (cx, cy, 0.135), bevel=0.015, mat=m["ash"],
                                       tint=(f, f, f)))
                    parts.append(lump("chip", 0.07, (cx + rng.uniform(-0.1, 0.1), cy + rng.uniform(-0.1, 0.1), 0.17),
                                      m["slag"], scale=(1.2, 0.9, 0.5)))
                    continue
                if (worn and r < 0.3) or r < 0.05:  # cracked across, the halves tilted apart
                    fr = rng.uniform(0.35, 0.65)
                    long_x = sx > sy
                    L = sx if long_x else sy
                    for lo, hi in ((0.0, fr), (fr, 1.0)):
                        c = -L / 2 + L * (lo + hi) / 2
                        ln = L * (hi - lo) - 0.025
                        pc = (cx + c, cy) if long_x else (cx, cy + c)
                        ps = (ln, sy, thick) if long_x else (sx, ln, thick)
                        o = block("paver", ps, (pc[0], pc[1], top - thick / 2 - rng.uniform(0, 0.012)), bevel=0.022,
                                  mat=m[key], tint=t, rot=(rng.uniform(-0.02, 0.02), rng.uniform(-0.02, 0.02), rng.uniform(-0.03, 0.03)))
                        kit.jitter_vertices(o, rng, 0.006)
                        parts.append(o)
                    continue
                o = block("paver", (sx, sy, thick), (cx, cy, top - thick / 2), bevel=0.018, mat=m[key], tint=t,
                          rot=(rng.uniform(-0.01, 0.01), rng.uniform(-0.01, 0.01), rng.uniform(-0.012, 0.012)))
                kit.jitter_vertices(o, rng, 0.006)
                parts.append(o)
    # iron plates: riveted along their edges, a flush lifting ring on the bigger ones
    for n_plate, (i, j, w, h) in enumerate(plates):
        cx, cy = -half + i + w / 2, -half + j + h / 2
        sunk = 0.03 if worn and n_plate == 0 else 0.0
        tilt = (rng.uniform(-0.015, 0.015), rng.uniform(-0.015, 0.015), 0) if sunk else (0, 0, 0)
        halves = [(cx, cy, w, h)]
        if w == 2 and h == 2:
            halves = [(cx - 0.5, cy, 1, 2), (cx + 0.5, cy, 1, 2)]
        group = []
        ptop = top0 - 0.004 - sunk
        for (hx, hy, hw, hh) in halves:
            f = scorch_f(hx, hy)
            t = iron_tint(rng)
            group.append(block("plate", (hw - GAP, hh - GAP, 0.07), (hx, hy, ptop - 0.035), bevel=0.014, mat=m["iron"],
                               tint=(t[0] * f, t[1] * f, t[2] * f)))
            ex, ey = (hw - GAP) / 2 - 0.07, (hh - GAP) / 2 - 0.07
            nx, ny = max(2, int(hw / 0.36)), max(2, int(hh / 0.36))
            for sy in (-1, 1):
                group += rivet_row(m, (hx - ex, hy + sy * ey, ptop), (hx + ex, hy + sy * ey, ptop), nx, (0, 0, 1), r=0.028)
            for sx in (-1, 1):
                group += rivet_row(m, (hx + sx * ex, hy - ey + 0.12, ptop), (hx + sx * ex, hy + ey - 0.12, ptop), ny - 1,
                                   (0, 0, 1), r=0.028)
        if w * h >= 2:
            group.append(torus("lift_ring", 0.085, 0.017, (cx + (0.5 if w == 2 and h == 2 else 0) * 0, cy, ptop + 0.004),
                               mat=m["iron"], seg=(10, 4), scale=(1, 1, 0.6)))
            group.append(block("ring_plate", (0.12, 0.05, 0.016), (cx, cy - 0.085, ptop + 0.006), bevel=0.004, mat=m["iron"]))
        if sunk:
            group_xf(group, (0, 0, 0), (0, 0, 0))
            c = Vector((cx, cy, ptop))
            mx = Matrix.Translation(c) @ Euler(tilt).to_matrix().to_4x4() @ Matrix.Translation(-c)
            for o in group:
                o.data.transform(mx)
        parts += group
    # slag spatter: flattened dark splashes, a few with a trail of droplets
    for _ in range(9 if worn else 5):
        x, y = rng.uniform(-half + 0.2, half - 0.2), rng.uniform(-half + 0.2, half - 0.2)
        r = rng.uniform(0.07, 0.17)
        parts.append(lump("slag", r, (x, y, top0 + 0.004), m["slag"], rng=rng, jitter=r * 0.15,
                          scale=(1.0, rng.uniform(0.6, 1.0), 0.13), rot=(0, 0, rng.uniform(0, 3))))
        if rng.random() < 0.5:
            a = rng.uniform(0, math.tau)
            for k in range(3):
                d = r + 0.08 + 0.07 * k
                parts.append(lump("drop", r * (0.35 - 0.07 * k), (x + math.cos(a) * d, y + math.sin(a) * d, top0 + 0.003),
                                  m["slag"], scale=(1, 1, 0.3)))
    return parts


# ----------------------------------------------------------------------------- walls

def wall(p: dict, m: dict, rng) -> list:
    """A 4 m wide, 6 m tall foundry yard wall: a dark plinth, soot-blackened brick in three
    stages divided by riveted iron band courses, riveted iron half-pilasters at both edges (two
    segments pair them), a recessed panel with a tie-rod anchor plate in the middle stage, and a
    corbelled brick top under heavy coping. params.vents: two flue openings with iron grilles
    in the lower stage, a faint ember glow deep inside and scorched brick around them. The front
    lies on y = 0 and the piece reaches back to y = 0.65."""
    width, height = p.get("width_m", 4.0), p.get("height_m", 6.0)
    half = width / 2
    vents = bool(p.get("vents", False))
    plinth_h = 0.75
    bands = p.get("bands_m", [2.6, 4.75])
    band_h = 0.24
    corbel_z = height - 0.72
    pil_w = 0.3
    parts = [block("backing", (width, 0.2, height), (0, 0.55, height / 2), bevel=0, mat=m["mortar"])]
    glow_parts = []
    # plinth: big dark blocks standing proud, their tops chamfered back
    x = -half - rng.uniform(0.0, 0.6)
    while x < half - 0.01:
        w = rng.uniform(1.0, 1.6)
        a, b = max(x, -half), min(x + w, half)
        if b - a > 0.15:
            s = block("plinth", (b - a - GAP, 0.44, plinth_h - GAP), ((a + b) / 2, 0.22 - 0.1, plinth_h / 2), bevel=0.04,
                      segments=2, mat=m["brick_dark"], tint=brick_tint(rng, 0.08), taper=0.04)
            kit.jitter_vertices(s, rng, 0.012)
            parts.append(s)
        x += w
    vent_x = p.get("vent_x", [-0.85, 0.85])
    vent_w, vz0, vz1 = p.get("vent_w", 0.86), p.get("vent_z0", 1.2), p.get("vent_z1", 2.15)
    frame = 0.12

    def skip(u, z):
        if abs(u) > half - pil_w + 0.02:
            return True
        if vents:
            for vx in vent_x:
                if abs(u - vx) < vent_w / 2 + frame + 0.03 and vz0 - frame - 0.02 < z < vz1 + frame + 0.04:
                    return True
        return False

    def hot(u, z):
        return vents and any(abs(u - vx) < vent_w / 2 + 0.55 for vx in vent_x) and vz0 - 0.3 < z < bands[0]

    inner = half - pil_w
    stages = [(plinth_h, bands[0] - band_h / 2), (bands[0] + band_h / 2, bands[1] - band_h / 2),
              (bands[1] + band_h / 2, corbel_z)]
    panel_x = inner - 0.32  # the recessed panel of the middle stage
    for si, (z0, z1) in enumerate(stages):
        if si == 1 and not vents:
            brick_face(parts, m, rng, "x", 0.0, -1, -inner, inner, z0, z1, skip=lambda u, z: abs(u) < panel_x or skip(u, z))
            brick_face(parts, m, rng, "x", 0.07, -1, -panel_x, panel_x, z0, z1 - 0.3, proud=(0.0, 0.01))
            # a header course of bricks set on end over the panel, stepping out
            brick_face(parts, m, rng, "x", 0.0, -1, -panel_x, panel_x, z1 - 0.3, z1, course=(0.3, 0.3),
                       width=(0.26, 0.3), proud=(0.0, 0.015))
        else:
            brick_face(parts, m, rng, "x", 0.0, -1, -inner, inner, z0, z1, skip=skip, hot=hot)
    for z in bands:
        iron_band(parts, m, rng, -half, half, -0.12, z, h=band_h)
    if not vents:
        anchor_plate(parts, m, (rng.uniform(-0.25, 0.25), 0.07, (stages[1][0] + stages[1][1]) / 2 - 0.1))
    else:
        anchor_plate(parts, m, (0.0, 0.0, (stages[1][0] + stages[1][1]) / 2))
    # iron half-pilasters: a riveted plate with edge flanges, on a plinth block
    for sx in (-1, 1):
        cx = sx * (half - pil_w / 2)
        z0, z1 = plinth_h, corbel_z
        parts.append(block("pilaster", (pil_w, 0.16, z1 - z0), (cx, -0.08 + 0.02, (z0 + z1) / 2), bevel=0.014,
                           mat=m["iron"], tint=iron_tint(rng)))
        parts.append(block("flange", (0.05, 0.1, z1 - z0), (sx * (half - pil_w + 0.025), -0.11, (z0 + z1) / 2),
                           bevel=0.01, mat=m["iron"]))
        parts.append(block("pil_foot", (pil_w, 0.26, 0.2), (cx, -0.08, z0 + 0.1), bevel=0.02, mat=m["iron"],
                           taper=0.12))
        n = int((z1 - z0) / 0.36)
        parts += rivet_row(m, (sx * (half - 0.08), -0.14, z0 + 0.2), (sx * (half - 0.08), -0.14, z1 - 0.1), n, (0, -1, 0),
                           r=0.026)
    # corbelled top: two stepped brick courses, then heavy dark coping with an iron cap strip
    brick_face(parts, m, rng, "x", -0.06, -1, -half, half, corbel_z, corbel_z + 0.16, course=(0.16, 0.16),
               width=(0.26, 0.32), depth=0.36, bevel=0.015)
    brick_face(parts, m, rng, "x", -0.12, -1, -half, half, corbel_z + 0.16, corbel_z + 0.32, course=(0.16, 0.16),
               width=(0.55, 0.8), depth=0.42, bevel=0.015)
    x = -half
    cz = corbel_z + 0.32
    while x < half - 0.01:
        w = min(rng.uniform(0.9, 1.5), half - x)
        if half - (x + w) < 0.4:
            w = half - x
        h = height - cz - rng.uniform(0.0, 0.03)
        s = block("coping", (w - GAP, 0.74, h), (x + w / 2, 0.21, cz + h / 2), bevel=0.04, segments=2, mat=m["brick_dark"],
                  tint=brick_tint(rng, 0.08), rot=(0, rng.uniform(-0.01, 0.01), 0))
        kit.jitter_vertices(s, rng, 0.012)
        parts.append(s)
        x += w
    parts.append(block("cap_strip", (width, 0.05, 0.1), (0, -0.19, cz + 0.06), bevel=0.01, mat=m["iron"]))
    if vents:
        em = ember(p, p.get("vent_glow", 1.3))
        for vx in vent_x:
            _vent(parts, glow_parts, m, rng, em, vx, vz0, vz1, vent_w, frame)
    return parts, glow_parts


def _vent(parts, glow_parts, m, rng, em, x: float, z0: float, z1: float, w: float, frame: float) -> None:
    """A flue opening in a wall facing -Y: a dark throat with embers glowing at its back, an
    iron frame with rivets, a heavy lintel plate and a grille of round bars."""
    h = z1 - z0
    depth = 0.42
    parts.append(block("throat", (w + 0.04, 0.06, h + 0.04), (x, depth + 0.03, (z0 + z1) / 2), bevel=0, mat=m["void"]))
    for s in (-1, 1):  # dark brick reveals (the sides run past the head's corners)
        parts.append(block("reveal", (0.06, depth, h + 0.07), (x + s * (w / 2 + 0.03), depth / 2, (z0 + z1) / 2 + 0.03), bevel=0,
                           mat=m["brick_dark"]))
    parts.append(block("reveal", (w, depth, 0.06), (x, depth / 2, z1 + 0.03), bevel=0, mat=m["brick_dark"]))
    parts.append(block("hearth", (w, depth, 0.08), (x, depth / 2, z0 + 0.0), bevel=0.01, mat=m["ash"]))
    glow_parts.append(block("embers", (w * 0.85, 0.04, h * 0.45), (x, depth - 0.01, z0 + h * 0.24), bevel=0, mat=em))
    for k in range(5):  # a few coals on the hearth
        glow_parts.append(lump("coal", rng.uniform(0.04, 0.07), (x + rng.uniform(-w * 0.35, w * 0.35),
                               rng.uniform(depth * 0.45, depth * 0.85), z0 + 0.05), em, scale=(1.2, 1, 0.7)))
    # frame: four riveted flats proud of the brick
    fy = -0.05
    for s in (-1, 1):
        parts.append(block("frame", (frame, 0.08, h + 2 * frame), (x + s * (w / 2 + frame / 2), fy + 0.02, (z0 + z1) / 2),
                           bevel=0.01, mat=m["iron"], tint=iron_tint(rng)))
        parts += rivet_row(m, (x + s * (w / 2 + frame / 2), fy - 0.02, z0 - frame * 0.5),
                           (x + s * (w / 2 + frame / 2), fy - 0.02, z1 + frame * 0.5), 4, (0, -1, 0), r=0.022)
    parts.append(block("lintel", (w + 2 * frame + 0.24, 0.12, 0.2), (x, fy, z1 + frame / 2 + 0.06), bevel=0.012,
                       mat=m["iron"], tint=iron_tint(rng)))
    parts += rivet_row(m, (x - w / 2 - 0.1, fy - 0.06, z1 + 0.12), (x + w / 2 + 0.1, fy - 0.06, z1 + 0.12), 5, (0, -1, 0),
                       r=0.024)
    parts.append(block("sill", (w + 2 * frame + 0.1, 0.14, 0.1), (x, fy + 0.02, z0 - frame / 2), bevel=0.012,
                       mat=m["iron"]))
    n = 6
    for i in range(n):
        bx = x - w / 2 + w * (i + 0.5) / n
        parts.append(cylinder("bar", 0.026, h + 0.1, (bx, 0.06, (z0 + z1) / 2), sides=6, mat=m["iron"],
                              tint=iron_tint(rng)))
    parts.append(block("bar_rail", (w, 0.05, 0.05), (x, 0.06, z0 + h * 0.55), bevel=0.006, mat=m["iron"]))


def corner(p: dict, m: dict, rng) -> list:
    """A square brick pier where two walls meet, about 1.1 m across: a dark plinth, bonded
    courses (alternate courses run front to back), iron corner guards (riveted angle irons) on
    the four edges, the walls' iron band courses carried round it, and a stepped brick cap
    under a dark coping slab."""
    height = p.get("height_m", 6.0)
    s = p.get("size_m", 1.1)
    hs = s / 2
    parts = [block("plinth", (s + 0.12, s + 0.12, 0.75), (0, 0, 0.375), bevel=0.04, segments=2, mat=m["brick_dark"],
                   tint=brick_tint(rng, 0.06), taper=0.03)]
    parts.append(block("core", (s - 0.3, s - 0.3, height - 0.8), (0, 0, 0.75 + (height - 0.8) / 2), bevel=0, mat=m["mortar"]))
    bands = p.get("bands_m", [2.6, 4.75])
    z = 0.75
    row = 0
    cap0 = height - 0.72
    while z < cap0 - 0.05:
        ch = min(rng.uniform(0.4, 0.48), cap0 - z)
        if cap0 - (z + ch) < 0.25:
            ch = cap0 - z
        if any(abs(z + ch / 2 - b) < 0.16 for b in bands):
            z += ch
            row += 1
            continue
        # two long bricks per face, the bond turning each course
        for side in range(4):
            ang = side * math.pi / 2
            n = 1 if (side + row) % 2 == 0 else 2
            for k in range(n):
                L = s / n
                u = -hs + L * (k + 0.5)
                key = "brick_dark" if rng.random() < 0.15 else "brick"
                o = block("brick", (L - GAP, 0.28, ch - GAP), (u, -hs + 0.14 - rng.uniform(0, 0.015), z + ch / 2),
                          bevel=0.02 if n == 1 else 0.0, mat=m[key], tint=brick_tint(rng))
                kit.jitter_vertices(o, rng, 0.008)
                group_xf([o], (0, 0, 0), (0, 0, ang))
                parts.append(o)
        z += ch
        row += 1
    for b in bands:  # band courses carried round the pier
        parts.append(block("band", (s + 0.26, s + 0.26, 0.24), (0, 0, b), bevel=0.012, mat=m["iron"], tint=iron_tint(rng)))
        for side in range(4):
            ang = side * math.pi / 2
            rs = rivet_row(m, (-hs + 0.05, -hs - 0.13, b), (hs - 0.05, -hs - 0.13, b), 2, (0, -1, 0), r=0.028)
            group_xf(rs, (0, 0, 0), (0, 0, ang))
            parts += rs
    for sx in (-1, 1):  # angle-iron guards on the edges, riveted through both flanges
        for sy in (-1, 1):
            cx, cy = sx * (hs + 0.01), sy * (hs + 0.01)
            z0, z1 = 0.75, cap0
            parts.append(block("angle", (0.22, 0.04, z1 - z0), (cx - sx * 0.09, cy, (z0 + z1) / 2), bevel=0.008, mat=m["iron"],
                               tint=iron_tint(rng)))
            parts.append(block("angle", (0.046, 0.22, z1 - z0 - 0.01), (cx, cy - sy * 0.09, (z0 + z1) / 2), bevel=0.008,
                               mat=m["iron"], tint=iron_tint(rng)))
            for zz in (1.7, 3.7, 5.0):
                if zz < z1 - 0.1:
                    parts.append(rivet(m, (cx - sx * 0.12, cy + sy * 0.02, zz), (0, sy, 0), r=0.024))
                    parts.append(rivet(m, (cx + sx * 0.02, cy - sy * 0.12, zz), (sx, 0, 0), r=0.024))
    parts.append(block("cap1", (s + 0.14, s + 0.14, 0.18), (0, 0, cap0 + 0.09), bevel=0.02, mat=m["brick"],
                       tint=brick_tint(rng, 0.06)))
    parts.append(block("cap2", (s + 0.3, s + 0.3, 0.18), (0, 0, cap0 + 0.27), bevel=0.02, mat=m["brick"],
                       tint=brick_tint(rng, 0.06)))
    parts.append(block("coping", (s + 0.42, s + 0.42, height - cap0 - 0.36), (0, 0, (cap0 + 0.36 + height) / 2), bevel=0.04,
                       segments=2, mat=m["brick_dark"], tint=brick_tint(rng, 0.06), taper=0.06))
    return parts


# ----------------------------------------------------------------------------- gate

def gate(p: dict, m: dict, rng) -> list:
    """A heavy riveted iron grate, 8 m wide and 5 m tall: deep flat bars on edge, double
    riveted straps (front and back), a solid riveted kick plate low down, a heavy top rail and
    pointed feet. Faces -Y."""
    width, height = p.get("width_m", 8.0), p.get("height_m", 5.0)
    parts = []
    n = int(round(width / 0.45))
    step = width / n
    foot = 0.3
    for i in range(n + 1):
        x = -width / 2 + i * step
        parts.append(block("bar", (0.07, 0.16, height - foot - 0.1), (x, 0, foot + (height - foot - 0.1) / 2), bevel=0.012,
                           mat=m["iron"], tint=iron_tint(rng)))
        parts.append(cylinder("spike", 0.075, foot, (x, 0, foot / 2), sides=4, radius_top=0.0, rot=(math.pi, 0, math.pi / 4),
                              mat=m["iron"]))
    straps = p.get("straps_m", [0.5, 1.15, 2.4, 3.6])
    for z in straps:
        for sy in (-1, 1):
            parts.append(block("strap", (width + 0.14, 0.05, 0.16), (0, sy * 0.105, z), bevel=0.012, mat=m["iron"],
                               tint=iron_tint(rng)))
        for i in range(n + 1):
            parts.append(rivet(m, (-width / 2 + i * step, -0.13, z), (0, -1, 0), r=0.032))
    # kick plate between the two lowest straps, riveted along a middle line
    parts.append(block("kick", (width + 0.1, 0.04, straps[1] - straps[0]), (0, -0.1, (straps[0] + straps[1]) / 2),
                       bevel=0.01, mat=m["iron"], tint=iron_tint(rng)))
    # diagonal braces in the middle field, flat bars across the front
    z0, z1 = straps[1] + 0.08, straps[2] - 0.08
    bays = 4
    bw = width / bays
    ang = math.atan2(z1 - z0, bw)
    ln = math.hypot(z1 - z0, bw) - 0.05
    for b in range(bays):
        cx = -width / 2 + bw * (b + 0.5)
        s = 1 if b % 2 == 0 else -1
        parts.append(block("brace", (ln, 0.04, 0.12), (cx, -0.1, (z0 + z1) / 2), rot=(0, s * ang, 0), bevel=0.01,
                           mat=m["iron"], tint=iron_tint(rng)))
    # heavy top rail: a channel with a riveted cover plate
    parts.append(block("top_rail", (width + 0.12, 0.3, 0.3), (0, 0, height - 0.15), bevel=0.02, mat=m["iron"],
                       tint=iron_tint(rng)))
    for i in range(int(width / 0.5)):
        parts.append(rivet(m, (-width / 2 + 0.25 + i * 0.5, -0.15, height - 0.15), (0, -1, 0), r=0.034))
    for sx in (-1, 1):  # lifting eyes on the face of the top rail (nothing rises above the gate's height)
        parts.append(torus("eye", 0.09, 0.03, (sx * width * 0.3, -0.17, height - 0.15), rot=(math.pi / 2, 0, 0),
                           mat=m["iron"], seg=(10, 4)))
    return parts


def gate_lintel(p: dict, m: dict, rng) -> list:
    """An iron box girder over a gate, resting on brick corbels at both ends: riveted flanges,
    stiffeners on its face, a blank cast plate in the middle and two portcullis sheaves hanging
    under it. Back on y = 0, reaching 1 m forward (-Y), like the crypt's lintel."""
    width = p.get("width_m", 9.0)
    depth = 1.0
    hw = width / 2
    end_w = 0.95
    parts = []
    for sx in (-1, 1):  # brick corbels standing a little proud, with an iron bearing plate
        cx = sx * (hw - end_w / 2)
        brick_face(parts, m, rng, "x", -depth - 0.04, -1, cx - end_w / 2, cx + end_w / 2, 0.0, 1.05,
                   course=(0.25, 0.28), width=(0.4, 0.5), depth=depth + 0.04)
        parts.append(block("bearing", (end_w + 0.08, depth + 0.1, 0.1), (cx, -(depth + 0.1) / 2, 1.1), bevel=0.012,
                           mat=m["iron"]))
        parts.append(block("cap", (end_w + 0.1, depth + 0.14, 0.24), (cx, -(depth + 0.14) / 2, 1.27), bevel=0.03,
                           mat=m["brick_dark"], tint=brick_tint(rng, 0.06), taper=0.06))
    L = width - 2 * end_w + 0.3
    gz0, gz1 = 0.12, 1.05
    # box girder: flanges top and bottom, front web, rivet lines along the flanges
    parts.append(block("web", (L, depth - 0.12, gz1 - gz0 - 0.1), (0, -depth / 2, (gz0 + gz1) / 2), bevel=0, mat=m["iron"],
                       tint=iron_tint(rng)))
    for z in (gz0 + 0.04, gz1 - 0.04):
        parts.append(block("flange", (L + 0.02, depth, 0.1), (0, -depth / 2, z), bevel=0.014, mat=m["iron"],
                           tint=iron_tint(rng)))
        parts += rivet_row(m, (-L / 2, -depth, z + (0.12 if z < 0.5 else -0.12)),
                           (L / 2, -depth + 0.0, z + (0.12 if z < 0.5 else -0.12)), int(L / 0.32), (0, -1, 0), r=0.03)
    parts.append(block("face", (L - 0.02, 0.04, gz1 - gz0 - 0.12), (0, -depth + 0.04, (gz0 + gz1) / 2), bevel=0.008,
                       mat=m["iron"], tint=iron_tint(rng)))
    for i in range(9):  # stiffeners
        x = -L / 2 + 0.3 + i * (L - 0.6) / 8
        if abs(x) < 1.1:
            continue
        parts.append(block("stiffener", (0.1, 0.09, gz1 - gz0 - 0.2), (x, -depth - 0.0, (gz0 + gz1) / 2), bevel=0.01,
                           mat=m["iron"], tint=iron_tint(rng)))
    # a blank cast plate in the middle, framed by a raised rim
    parts.append(block("plaque", (1.8, 0.06, 0.52), (0, -depth - 0.02, (gz0 + gz1) / 2), bevel=0.02, mat=m["iron"],
                       tint=(0.85, 0.85, 0.85)))
    for sz in (-1, 1):
        parts.append(block("plaque_rim", (1.96, 0.08, 0.07), (0, -depth - 0.03, (gz0 + gz1) / 2 + sz * 0.29), bevel=0.01,
                           mat=m["iron"]))
    for sx in (-1, 1):
        parts.append(block("plaque_rim", (0.07, 0.08, 0.65), (sx * 0.95, -depth - 0.03, (gz0 + gz1) / 2), bevel=0.01,
                           mat=m["iron"]))
        parts.append(rivet(m, (sx * 0.8, -depth - 0.05, (gz0 + gz1) / 2), (0, -1, 0), r=0.045))
    # portcullis sheaves on brackets on the girder's face
    for sx in (-1, 1):
        x = sx * width * 0.3
        for s in (-1, 1):
            parts.append(block("cheek", (0.04, 0.3, 0.42), (x + s * 0.09, -depth - 0.15, (gz0 + gz1) / 2), bevel=0.0,
                               mat=m["iron"]))
        parts.append(cylinder("sheave", 0.17, 0.1, (x, -depth - 0.17, (gz0 + gz1) / 2 + 0.02), rot=(0, math.pi / 2, 0), sides=12,
                              mat=m["iron"]))
    return parts


def gatehouse(p: dict, m: dict, rng) -> list:
    """A brick winding house on the wall top over a gate, tall enough to hide the raised grate:
    brick walls with riveted iron I-beam pilasters, tall round-headed windows with iron glazing
    bars (one glowing faintly), an iron girder cornice, an iron-plated gabled roof with a
    ventilating lantern along its ridge and a squat chimney. The lowest band (z 0..1) sits behind
    the gate's lintel; the front faces the arena (-Y). Same envelope as the crypt and gallows
    gatehouses (12 x 3.4 m, body 5 m)."""
    W, D = p.get("width_m", 12.0), p.get("depth_m", 3.4)
    body_h = p.get("body_m", 5.0)
    lintel_d = p.get("lintel_depth_m", 1.0)
    hw, hd = W / 2, D / 2
    parts = [block("core", (W - 0.5, D - 0.5, body_h - 1.0), (0, 0, 1.0 + (body_h - 1.0) / 2), bevel=0, mat=m["mortar"]),
             block("core_low", (W - 0.5, D - lintel_d - 0.25, 1.2), (0, (lintel_d - 0.25) / 2 + 0.125, 0.6), bevel=0,
                   mat=m["mortar"])]
    glow_parts = []
    em = ember(p, 1.6)
    pil_x = [-hw + 0.35, -hw / 3, hw / 3, hw - 0.35]
    win_x = [-hw * 2 / 3, 0.0, hw * 2 / 3]
    wz0, wz1, ww = 1.6, 3.7, 1.0
    big = dict(course=(0.42, 0.5), width=(0.9, 1.35), bevel=0.03, depth=0.32)

    def front_skip(u, z):
        if any(abs(u - px) < 0.32 for px in pil_x):
            return True
        for wx in win_x:
            if abs(u - wx) < ww / 2 + 0.2 and wz0 - 0.2 < z < wz1:
                return True
            if z >= wz1 and (u - wx) ** 2 + (z - wz1) ** 2 < (ww / 2 + 0.3) ** 2:
                return True
        return False

    brick_face(parts, m, rng, "x", -hd, -1, -hw, hw, 1.0, body_h - 0.55, skip=front_skip, **big)
    plain = dict(big, bevel=0.0)  # the back and the ends are seen from far off only
    brick_face(parts, m, rng, "x", hd, 1, -hw, hw, 0.0, body_h - 0.55, **plain)
    for s in (-1, 1):
        brick_face(parts, m, rng, "y", s * hw, s, -hd + 0.3, hd - 0.3, 1.0, body_h - 0.55, **plain)
        brick_face(parts, m, rng, "y", s * hw, s, -hd + lintel_d, hd - 0.3, 0.0, 1.0, course=(0.5, 0.5),
                   width=(0.9, 1.3), bevel=0.03, depth=0.32)
    brick_face(parts, m, rng, "x", -hd + lintel_d, -1, -hw + 0.3, hw - 0.3, 0.0, 1.0, course=(0.5, 0.5),
               width=(1.0, 1.5), bevel=0.03, depth=0.3)
    # I-beam pilasters: web and two flanges, riveted, on the front
    for px in pil_x:
        z0, z1 = 1.0, body_h - 0.5
        parts.append(block("pil_web", (0.14, 0.34, z1 - z0), (px, -hd - 0.12, (z0 + z1) / 2), bevel=0.01, mat=m["iron"],
                           tint=iron_tint(rng)))
        parts.append(block("pil_flange", (0.5, 0.07, z1 - z0), (px, -hd - 0.3, (z0 + z1) / 2), bevel=0.012, mat=m["iron"],
                           tint=iron_tint(rng)))
        parts += rivet_row(m, (px, -hd - 0.335, z0 + 0.2), (px, -hd - 0.335, z1 - 0.2), 9, (0, -1, 0), r=0.03)
    # tall round-headed windows: a dark opening, brick arch, iron sill and glazing bars
    lit = rng.randrange(3)
    for i, wx in enumerate(win_x):
        mat = em if i == lit else m["void"]
        pane = block("window", (ww, 0.1, wz1 - wz0), (wx, -hd + 0.12, (wz0 + wz1) / 2), bevel=0, mat=mat)
        head = cylinder("window_head", ww / 2 - 0.004, 0.096, (wx, -hd + 0.12, wz1), rot=(math.pi / 2, 0, 0), sides=12, mat=mat)
        (glow_parts if i == lit else parts).extend([pane, head])
        n = 9
        for k in range(n):  # brick voussoirs round the head
            a0, a1 = math.pi * k / n, math.pi * (k + 1) / n
            am = (a0 + a1) / 2
            rr = ww / 2 + 0.15
            o = block("voussoir", (math.pi * rr / n - GAP, 0.3, 0.28), (0, 0, 0), bevel=0.0, mat=m["brick"],
                      tint=brick_tint(rng))
            group_xf([o], (wx + math.cos(am) * rr, -hd + 0.13, wz1 + math.sin(am) * rr), (0, -(am - math.pi / 2), 0))
            parts.append(o)
        for s in (-1, 1):  # jambs of bricks set on end
            e = wx + s * (ww / 2 + 0.1)
            brick_face(parts, m, rng, "x", -hd, -1, e - 0.1, e + 0.1, wz0 - 0.2, wz1, course=(0.3, 0.34), width=(0.2, 0.2),
                       depth=0.32, dark=0.3)
        parts.append(block("sill", (ww + 0.4, 0.36, 0.12), (wx, -hd - 0.06, wz0 - 0.1), bevel=0.015, mat=m["iron"]))
        for k in (-1, 0, 1):
            parts.append(block("glazing", (0.035, 0.04, wz1 - wz0 + ww * 0.4), (wx + k * ww / 4, -hd + 0.05, (wz0 + wz1) / 2 + 0.1),
                               bevel=0, mat=m["iron"]))
        for zz in (wz0 + 0.55, wz0 + 1.1, wz0 + 1.65):
            parts.append(block("glazing", (ww, 0.04, 0.035), (wx, -hd + 0.05, zz), bevel=0, mat=m["iron"]))
    # iron girder cornice front and back, ends
    top = body_h
    for sy in (-1, 1):
        parts.append(block("cornice_web", (W + 0.3, 0.3, 0.5), (0, sy * (hd + 0.05), top - 0.3), bevel=0.012, mat=m["iron"],
                           tint=iron_tint(rng)))
        parts.append(block("cornice_flange", (W + 0.5, 0.55, 0.1), (0, sy * (hd + 0.12), top), bevel=0.014, mat=m["iron"],
                           tint=iron_tint(rng)))
        parts += rivet_row(m, (-hw, sy * (hd + 0.2), top - 0.3), (hw, sy * (hd + 0.2), top - 0.3), 24, (0, sy, 0), r=0.032)
    for sx in (-1, 1):
        parts.append(block("cornice_end", (0.3, D + 0.3, 0.5), (sx * (hw + 0.05), 0, top - 0.3), bevel=0.012, mat=m["iron"]))
    # gabled roof of iron plates (ridge along x), seam straps, a ventilating lantern on the ridge
    ped_h = p.get("roof_m", 1.6)
    roof_w = D + 0.6
    parts.append(prism("roof", W + 0.3, roof_w, ped_h, (0, 0, top + 0.05), mat=m["iron"], tint=(0.9, 0.9, 0.9), bevel=0.03))
    slope = math.atan2(ped_h, roof_w / 2)
    for i in range(9):
        x = -W / 2 + 0.6 + i * (W - 1.2) / 8
        for sy in (-1, 1):
            parts.append(block("seam", (0.06, roof_w / 2 / math.cos(slope) + 0.02, 0.05),
                               (x, sy * roof_w / 4, top + 0.05 + ped_h / 2 + 0.03), rot=(-sy * slope, 0, 0), bevel=0.0,
                               mat=m["iron"]))
    lw = W * 0.5
    lz = top + 0.05 + ped_h - 0.2
    parts.append(block("lantern", (lw, 0.8, 0.6), (0, 0, lz + 0.3), bevel=0.02, mat=m["void"]))
    for k in range(10):
        x = -lw / 2 + 0.1 + k * (lw - 0.2) / 9
        for sy in (-1, 1):
            parts.append(block("louvre_post", (0.08, 0.06, 0.62), (x, sy * 0.42, lz + 0.31), bevel=0, mat=m["iron"]))
    for sy in (-1, 1):
        for zz in (lz + 0.15, lz + 0.35):
            parts.append(block("louvre", (lw, 0.04, 0.08), (0, sy * 0.44, zz), rot=(sy * 0.6, 0, 0), bevel=0, mat=m["iron"]))
    parts.append(prism("lantern_roof", lw + 0.4, 1.3, 0.45, (0, 0, lz + 0.6), mat=m["iron"], tint=(0.85, 0.85, 0.85),
                       bevel=0.02))
    # a squat square chimney at one end with an iron cap
    cxm = hw - 1.6
    ch_top = top + ped_h + 1.6
    brick_face(parts, m, rng, "x", -0.45, -1, cxm - 0.45, cxm + 0.45, top + 0.4, ch_top, course=(0.3, 0.34),
               width=(0.42, 0.5), depth=0.9, bevel=0.02)
    parts.append(block("chimney_cap", (1.15, 1.15, 0.16), (cxm, 0, ch_top + 0.08), bevel=0.02, mat=m["iron"]))
    parts.append(cylinder("flue", 0.24, 0.5, (cxm, 0, ch_top + 0.4), sides=10, mat=m["iron"]))
    return parts, glow_parts


# ----------------------------------------------------------------------------- the hub: furnace

def furnace(p: dict, m: dict, rng) -> tuple[list, list]:
    """The great round blast furnace at the hub (collision radius radius_m, height_m): a dark
    stone footing, a battered brick shaft in courses of curved blocks bound by riveted iron
    hoops, three or four furnace mouths set back in the brickwork (an iron frame, a heavy door
    swung open flat against the shaft, glowing metal deep inside and embers on the sill,
    scorched brick round them), an iron collar ring with gussets at collar_m where the crane arm
    pivots, a corbelled brick top and a narrower iron-banded flue stack above height_m."""
    R = p.get("radius_m", 2.6)
    H = p.get("height_m", 7.0)
    collar = p.get("collar_m", 6.3)
    k = R / 2.6
    hot_m = molten(p)
    em = ember(p, 3.2)
    parts, glow_parts = [], []
    r_shaft0, r_shaft1 = 2.42 * k, 2.02 * k  # batter: the shaft narrows as it rises, like a cone
    r_core = 1.9 * k
    plinth_h = 0.55
    hoops = [z for z in p.get("hoops_m", [2.25, 3.6, 4.85]) if z < collar - 0.8]
    collar0 = collar - 0.4
    n_mouths = int(p.get("mouths", 4))
    mouth_w, mz0, mz1 = p.get("mouth_w", 1.25), plinth_h, hoops[0] - 0.12
    a_off = math.radians(p.get("mouth_angle_deg", 45.0))
    mouths = [a_off + i * math.tau / n_mouths for i in range(n_mouths)]
    parts.append(lathe("core", [(r_core, 0.3), (r_core, collar + 0.2)], sides=24, mat=m["mortar"]))
    # footing: big dark curved blocks, chamfered
    n = 12
    for i in range(n):
        a0, a1 = i * math.tau / n, (i + 1) * math.tau / n
        o = arc_block("footing", r_core, 2.56 * k, a0 + 0.006, a1 - 0.006, 0.0, plinth_h - 0.02, m["brick_dark"],
                      tint=brick_tint(rng, 0.08), max_seg=0.7)
        for v in o.data.vertices:  # chamfer the top outer edge back
            rr = math.hypot(v.co.x, v.co.y)
            if v.co.z > plinth_h * 0.6 and rr > 2.4 * k:
                f = (2.42 * k) / rr
                v.co.x *= f
                v.co.y *= f
        kit.jitter_vertices(o, rng, 0.01)
        parts.append(o)

    # shaft stages between the hoops; the shaft radius follows the batter
    def r_at(z):
        return r_shaft0 + (r_shaft1 - r_shaft0) * (z - plinth_h) / (collar0 - plinth_h)

    hoop_h = 0.24
    stage_z = [plinth_h] + [z for h in hoops for z in (h - hoop_h / 2, h + hoop_h / 2)] + [collar0]
    openings = [(a, (mouth_w / 2 + 0.02) / r_shaft0, mz0, mz1 + 0.01) for a in mouths]
    for z0, z1 in zip(stage_z[0::2], stage_z[1::2]):
        ring_courses(parts, m, rng, r_core - 0.02, r_at((z0 + z1) / 2), z0, z1, course=(0.42, 0.5), length=(1.05, 1.4),
                     openings=openings, hot_margin=0.6, max_seg=0.75)
    # buckstays: vertical iron straps binding the brickwork between the mouths, over the hoops
    for i in range(int(p.get("buckstays", 8))):
        a = mouths[0] + math.pi / n_mouths + i * math.tau / int(p.get("buckstays", 8))
        if any(abs(math.remainder(a - mo, math.tau)) < (mouth_w / 2 + 0.35) / r_shaft0 for mo in mouths):
            continue
        ca, sa = math.cos(a), math.sin(a)
        z0, z1 = plinth_h - 0.1, collar0
        r0, r1 = r_at(z0) + 0.12, r_at(z1) + 0.12
        parts.append(beam("buckstay", (r0 * ca, r0 * sa, z0), (r1 * ca, r1 * sa, z1), 0.18, 0.07, m["iron"], iron_tint(rng),
                          up=(ca, sa, 0)))
        for h in hoops:
            rh = r_at(h) + 0.16
            parts.append(rivet(m, (rh * ca, rh * sa, h + 0.0), (ca, sa, 0), r=0.035))
    for h in hoops:
        r = r_at(h) + 0.02
        parts.append(hoop("hoop", r - 0.06, r + 0.1, h - hoop_h / 2, h + hoop_h / 2, 28, m["iron"], iron_tint(rng)))
        a0 = rng.uniform(0, math.tau)
        for i in range(6):  # rivets, and a strap joint where the band was closed
            a = a0 + i * math.tau / 6
            parts.append(rivet(m, ((r + 0.1) * math.cos(a), (r + 0.1) * math.sin(a), h), (math.cos(a), math.sin(a), 0), r=0.03))
        j = a0 + math.pi / 10
        o = block("joint", (0.08, 0.32, hoop_h + 0.1), (r + 0.13, 0, h), bevel=0.012, mat=m["iron"])
        group_xf([o], (0, 0, 0), (0, 0, j))
        parts.append(o)
    # furnace mouths
    for a in mouths:
        _furnace_mouth(parts, glow_parts, m, rng, hot_m, em, a, r_core, r_shaft0, mouth_w, mz0, mz1)
    # collar ring with gussets under it, where the crane arm pivots
    rc = 2.5 * k
    parts.append(hoop("collar", r_core, rc, collar0, collar, 28, m["iron"], iron_tint(rng)))
    parts.append(hoop("collar_lip", rc - 0.06, rc + 0.06, collar - 0.12, collar - 0.02, 28, m["iron"], iron_tint(rng)))
    for i in range(8):
        a = i * math.tau / 8 + math.pi / 8
        o = block("gusset", (0.34, 0.06, 0.4), (r_shaft1 + 0.14, 0, collar0 - 0.18), bevel=0.0, mat=m["iron"], taper=0.0)
        for v in o.data.vertices:  # a triangular knee: the outer bottom corner cut away
            if v.co.z < collar0 - 0.2 and v.co.x > r_shaft1 + 0.14:
                v.co.x -= 0.22
        group_xf([o], (0, 0, 0), (0, 0, a))
        parts.append(o)
        for da in (math.pi / 8,):
            ca, sa = math.cos(a + da), math.sin(a + da)
            parts.append(rivet(m, ((rc - 0.15) * ca, (rc - 0.15) * sa, collar), (0, 0, 1), r=0.035))
    # corbelled brick top, then the flue stack
    top_r = 1.92 * k  # inside the crane's hub ring
    ring_courses(parts, m, rng, r_core - 0.02, top_r, collar, H - 0.24, course=(0.3, 0.36), length=(1.0, 1.3), max_seg=0.75)
    parts.append(lathe("top_rim", [(top_r + 0.08, H - 0.24), (top_r + 0.14, H - 0.12), (top_r + 0.14, H), (1.25 * k, H)],
                       sides=24, mat=m["brick_dark"], tint=brick_tint(rng, 0.05), bevel=0.02))
    flue_r = p.get("flue_radius_m", 1.05) * k
    flue_h = p.get("flue_m", 2.2)
    parts.append(lathe("throat", [(1.3 * k, H - 0.02), (flue_r + 0.15, H + 0.25), (flue_r + 0.15, H + 0.3)], sides=20,
                       mat=m["brick_dark"]))
    ring_courses(parts, m, rng, flue_r - 0.3, flue_r, H + 0.28, H + flue_h - 0.25, course=(0.42, 0.5),
                 length=(0.9, 1.15), dark=0.3, max_seg=1.2)
    for z in (H + 0.6, H + flue_h - 0.55):
        parts.append(hoop("flue_hoop", flue_r - 0.05, flue_r + 0.07, z - 0.09, z + 0.09, 16, m["iron"], iron_tint(rng)))
    parts.append(lathe("flue_cap", [(flue_r + 0.12, H + flue_h - 0.26), (flue_r + 0.2, H + flue_h - 0.1),
                                    (flue_r + 0.2, H + flue_h), (flue_r - 0.18, H + flue_h), (flue_r - 0.18, H + flue_h - 0.2)],
                       sides=20, mat=m["iron"], tint=iron_tint(rng)))
    # a faint glow deep in the flue mouth (the cap's recessed floor), seen from above
    glow_parts.append(cylinder("flue_glow", flue_r - 0.19, 0.03, (0, 0, H + flue_h - 0.19), sides=16, mat=em))
    return parts, glow_parts


def _furnace_mouth(parts, glow_parts, m, rng, hot_m, em, a: float, r_core: float, r_shaft: float, w: float,
                   z0: float, z1: float) -> None:
    """One furnace mouth at angle a, built facing -Y at the origin and turned into place."""
    h = z1 - z0
    depth = r_shaft - r_core
    loc_parts, loc_glow = [], []
    # local frame: the shaft surface on y = -r_shaft... built about y = 0 (surface) then pushed out
    # glowing metal deep inside (a bright core over a wider ember back), embers on the sill
    loc_glow.append(block("mouth_back", (w + 0.02, 0.05, h - 0.04), (0, depth + 0.0, h / 2), bevel=0, mat=em))
    loc_glow.append(block("mouth_core", (w * 0.7, 0.05, h * 0.55), (0, depth - 0.04, h * 0.34), bevel=0, mat=hot_m))
    # an arched head of brick voussoirs inside the opening, the corners above it filled
    ar = w / 2
    spring = h - ar - 0.04
    n = 7
    for k in range(n):
        a0, a1 = math.pi * k / n, math.pi * (k + 1) / n
        am = (a0 + a1) / 2
        rr = ar - 0.1
        o = block("voussoir", (math.pi * (ar - 0.1) / n - 0.025, 0.3, 0.2), (0, 0, 0), bevel=0.0, mat=m["brick_hot"],
                  tint=brick_tint(rng))
        group_xf([o], (math.cos(am) * rr, 0.12, spring + math.sin(am) * rr), (0, -(am - math.pi / 2), 0))
        loc_parts.append(o)
    for s in (-1, 1):
        loc_parts.append(block("spandrel", (ar * 0.62, 0.28, ar * 0.62), (s * ar * 0.72, 0.14, h - ar * 0.3), bevel=0.0,
                               mat=m["brick_hot"], tint=brick_tint(rng)))
    for k in range(5):
        loc_glow.append(lump("ember", rng.uniform(0.06, 0.1), (rng.uniform(-w * 0.4, w * 0.4), rng.uniform(0.12, depth - 0.08),
                             0.05), hot_m if k % 3 == 0 else em, scale=(1.2, 1.0, 0.6)))
    loc_parts.append(block("hearth", (w, depth + 0.02, 0.06), (0, depth / 2, 0.02), bevel=0.0, mat=m["slag"]))
    for k in range(2):
        loc_parts.append(lump("slag", rng.uniform(0.06, 0.09), (rng.uniform(-w * 0.45, w * 0.45), rng.uniform(0.05, depth - 0.1),
                              0.06), m["slag"], rng=rng, jitter=0.01, scale=(1.3, 1.0, 0.6)))
    # iron frame with rivets, a heavy lintel plate, a sill plate
    fr = 0.13
    for s in (-1, 1):
        loc_parts.append(block("jamb", (fr, 0.1, h + 0.06), (s * (w / 2 + fr / 2 - 0.02), -0.03, h / 2), bevel=0.0,
                               mat=m["iron"], tint=iron_tint(rng)))
        loc_parts += rivet_row(m, (s * (w / 2 + fr / 2 - 0.02), -0.08, 0.1), (s * (w / 2 + fr / 2 - 0.02), -0.08, h - 0.05),
                               2, (0, -1, 0), r=0.028)
    loc_parts.append(block("lintel", (w + 2 * fr + 0.2, 0.1, 0.16), (0, -0.03, h + 0.04), bevel=0.0, mat=m["iron"],
                           tint=iron_tint(rng)))
    loc_parts.append(block("sill", (w + 2 * fr, 0.14, 0.08), (0, -0.02, 0.04), bevel=0.0, mat=m["iron"]))
    # the door, swung right round and lying flat against the shaft beside the opening
    side = rng.choice((-1, 1))
    dx = side * (w / 2 + fr + 0.3)
    loc_parts.append(block("door", (0.52, 0.06, h - 0.1), (dx, -0.05, h / 2), bevel=0.012, mat=m["iron"], tint=iron_tint(rng)))
    for zz in (0.25, h - 0.3):
        loc_parts.append(block("strap", (0.6, 0.03, 0.08), (dx, -0.09, zz), bevel=0.0, mat=m["iron"]))
    loc_parts.append(block("peep", (0.12, 0.03, 0.08), (dx, -0.09, h * 0.55), bevel=0.0, mat=m["void"]))
    # bend everything onto the curved shaft: push out to the surface and turn to the angle
    objs = loc_parts + loc_glow
    apply_xf(objs)
    for o in objs:
        for v in o.data.vertices:
            # wrap x round the shaft (keeps the frame hugging the curve), y outward from the surface
            ang = v.co.x / r_shaft
            rr = r_shaft - v.co.y
            v.co.x, v.co.y = rr * math.sin(ang), -rr * math.cos(ang)
            v.co.z += z0
    group_xf(objs, (0, 0, 0), (0, 0, a + math.pi / 2))
    parts += loc_parts
    glow_parts += loc_glow


# ----------------------------------------------------------------------------- crucible

def crucible(p: dict, m: dict, rng) -> tuple[list, list]:
    """A huge forged-iron crucible (ladle pot) of molten iron on a squat wheeled bogie, inside
    radius_m and height_m: a riveted pot with banded sides, a rolled rim darkened by heat, a
    pouring lip facing -Y and a tipping lug opposite, trunnions along x resting in A-frame
    bearings on the bogie, two lifting lugs on the rim at x = +-lug_x (where the crane's chains
    hook on), molten metal glowing at the top with a dark crust at its edge and slag spilled down
    the lip. The four flanged wheels roll along x on rails 0.8 m apart (the rail ring's radial
    gauge), so the bogie runs tangent to the ring at (0, +-9 m)."""
    R = p.get("radius_m", 1.5)
    H = p.get("height_m", 2.6)
    gauge = p.get("gauge_m", 0.8)
    lug_x = p.get("lug_x", 1.05)
    hot_m = molten(p)
    em = ember(p)
    parts, glow_parts = [], []
    # bogie: two riveted side frames along x, cross beams, a deck plate
    wr, fl = 0.27, 0.06  # wheel tread radius, flange depth
    axle_z = fl + wr
    fy = gauge / 2 + 0.2
    for sy in (-1, 1):
        parts.append(block("frame", (2.5, 0.09, 0.34), (0, sy * fy, axle_z + 0.08), bevel=0.014, mat=m["iron"], tint=iron_tint(rng)))
        parts.append(block("frame_top", (2.56, 0.2, 0.06), (0, sy * fy, axle_z + 0.27), bevel=0.01, mat=m["iron"]))
        parts += rivet_row(m, (-1.15, sy * (fy + 0.045), axle_z + 0.16), (1.15, sy * (fy + 0.045), axle_z + 0.16), 8,
                           (0, sy, 0), r=0.025)
        for sx in (-1, 1):  # axle boxes
            parts.append(block("axle_box", (0.26, 0.14, 0.26), (sx * 0.78, sy * (fy + 0.08), axle_z), bevel=0.02, mat=m["iron"]))
            parts.append(rivet(m, (sx * 0.78, sy * (fy + 0.15), axle_z), (0, sy, 0), r=0.04))
        parts.append(block("buffer", (0.1, 0.24, 0.2), (0, 0, 0), bevel=0.02, mat=m["iron"]))
        group_xf([parts[-1]], (sy * 1.28, 0, axle_z + 0.1))
    for sx in (-1, 1):
        parts.append(block("cross", (0.24, 2 * fy, 0.22), (sx * 0.5, 0, axle_z + 0.2), bevel=0.014, mat=m["iron"]))
        # wheels: flange inward, an axle through both
        for sy in (-1, 1):
            wl = lathe("wheel", [(0.0, -0.05), (wr, -0.05), (wr, 0.025), (wr + fl, 0.03), (wr + fl, 0.05), (0.0, 0.05)],
                       sides=16, mat=m["iron"], tint=iron_tint(rng))
            hub = lathe("hub", [(0.0, -0.08), (0.11, -0.08), (0.11, 0.08), (0.0, 0.08)], sides=10, mat=m["iron"])
            web = lathe("web", [(0.0, -0.065), (wr - 0.05, -0.065), (wr - 0.05, -0.04), (0.0, -0.04)], sides=12, mat=m["void"],
                        tint=(1, 1, 1))
            # turn the wheel's axis from z to y (flange side, +z before the turn, toward the middle)
            group_xf([wl, hub, web], (sx * 0.78, sy * gauge / 2, axle_z), (sy * math.pi / 2, 0, 0))
            parts += [wl, hub, web]
        parts.append(cylinder("axle", 0.05, 2 * fy + 0.1, (sx * 0.78, 0, axle_z), rot=(math.pi / 2, 0, 0), sides=8, mat=m["iron"]))
    deck_z = axle_z + 0.34
    parts.append(block("deck", (2.2, 2 * fy + 0.1, 0.08), (0, 0, deck_z), bevel=0.012, mat=m["iron"], tint=iron_tint(rng)))
    # A-frame bearings carrying the trunnions
    tz = p.get("trunnion_m", 1.75)
    tx = 1.3
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(beam("aframe", (sx * tx, sy * 0.48, deck_z + 0.02), (sx * tx, sy * 0.05, tz - 0.12), 0.1, 0.14,
                              m["iron"], iron_tint(rng), bevel=0.01, up=(1, 0, 0)))
        parts.append(block("bearing", (0.2, 0.36, 0.22), (sx * tx, 0, tz - 0.12), bevel=0.02, mat=m["iron"]))
        parts.append(block("bearing_cap", (0.22, 0.3, 0.1), (sx * tx, 0, tz + 0.06), bevel=0.02, mat=m["iron"], taper=0.2))
        parts.append(block("aframe_foot", (0.24, 0.98, 0.08), (sx * tx, 0, deck_z + 0.07), bevel=0.01, mat=m["iron"]))
    # the pot: a riveted, banded ladle with a rolled rim; molten metal stands at metal_m
    base = deck_z + 0.04
    rim_top = H - 0.14
    metal = rim_top - 0.12
    prof = [(0.0, base), (0.74, base), (0.86, base + 0.1), (1.0, base + 0.55), (1.1, base + 1.1), (1.15, rim_top - 0.22),
            (1.19, rim_top - 0.1), (1.24, rim_top - 0.06), (1.24, rim_top), (1.12, rim_top), (1.07, metal + 0.04),
            (1.05, metal), (0.0, metal)]
    pot = lathe("pot", prof, sides=24, mat=m["iron_hot"], tint=iron_tint(rng, 0.05))
    parts.append(pot)

    def pot_r(z):
        for (r0, z0), (r1, z1) in zip(prof[1:7], prof[2:8]):
            if z0 <= z <= z1:
                return r0 + (r1 - r0) * (z - z0) / max(z1 - z0, 1e-6)
        return prof[6][0]

    for bz in (base + 0.42, base + 0.92, rim_top - 0.32):
        r = pot_r(bz)
        parts.append(hoop("band", r - 0.04, r + 0.05, bz - 0.08, bz + 0.08, 24, m["iron_hot"], iron_tint(rng), 0.02))
        for i in range(10):
            aa = i * math.tau / 10 + 0.13
            parts.append(rivet(m, ((r + 0.05) * math.cos(aa), (r + 0.05) * math.sin(aa), bz), (math.cos(aa), math.sin(aa), 0),
                               r=0.028, key="iron_hot"))
    # riveted vertical seams where the pot's plates were joined, on the diagonals
    za, zb = base + 0.5, rim_top - 0.42
    for i in range(4):
        aa = math.pi / 4 + i * math.pi / 2
        ca, sa = math.cos(aa), math.sin(aa)
        ra, rb = pot_r(za) + 0.012, pot_r(zb) + 0.012
        parts.append(beam("seam", (ra * ca, ra * sa, za), (rb * ca, rb * sa, zb), 0.13, 0.03, m["iron_hot"], up=(ca, sa, 0)))
        for t in (0.2, 0.5, 0.8):
            z = za + (zb - za) * t
            r = pot_r(z) + 0.03
            parts.append(rivet(m, (r * ca, r * sa, z), (ca, sa, 0), r=0.028, key="iron_hot"))
    # trunnions along x into the bearings, with collars
    for sx in (-1, 1):
        r0 = pot_r(tz) - 0.05
        parts.append(cylinder("trunnion", 0.12, tx + 0.1 - r0, (sx * (r0 + tx + 0.1) / 2, 0, tz), rot=(0, math.pi / 2, 0),
                              sides=12, mat=m["iron"]))
        parts.append(cylinder("trunnion_boss", 0.24, 0.12, (sx * (r0 + 0.04), 0, tz), rot=(0, math.pi / 2, 0), sides=12,
                              mat=m["iron_hot"]))
        parts.append(cylinder("trunnion_collar", 0.17, 0.06, (sx * (tx + 0.14), 0, tz), rot=(0, math.pi / 2, 0), sides=12,
                              mat=m["iron"]))
    # pouring lip facing -Y: a beak-shaped trough of thick plate standing out of the rim, its
    # floor tilting down to the tip, with a gusset under it
    lip = []
    L0, L1, w0, w1 = 0.15, 0.45, 0.78, 0.26  # from inside the rim (y = -L0 behind it) to the tip
    lip.append(wedge_plate("lip_floor", w0, w1, L0 + L1, 0.07, m["iron_hot"], (0, L0, 0)))
    for s in (-1, 1):
        lip.append(beam("lip_side", (s * w0 / 2, L0, 0.09), (s * w1 / 2, -L1, 0.06), 0.07, 0.15, m["iron_hot"], bevel=0.012))
    gs = block("lip_gusset", (0.07, 0.42, 0.42), (0, -0.05, -0.24), bevel=0.01, mat=m["iron_hot"])
    for v in gs.data.vertices:  # a triangle: the lower outer corner cut away
        if v.co.z < -0.2 and v.co.y < 0.0:
            v.co.y += 0.32
    lip.append(gs)
    group_xf(lip, (0, -1.0, rim_top - 0.16), (math.radians(6), 0, 0))
    lz = max((v.co.z for o in lip for v in o.data.vertices))
    if lz > H:  # keep the lip under the collider's height
        for o in lip:
            o.data.transform(Matrix.Translation((0, 0, H - lz)))
    parts += lip
    # molten metal running into the lip
    ml = wedge_plate("lip_metal", w0 - 0.2, w1 - 0.12, L0 + L1 - 0.12, 0.03, hot_m, (0, L0 - 0.05, 0.072))
    group_xf([ml], (0, -1.0, rim_top - 0.16 + min(0.0, H - lz)), (math.radians(6), 0, 0))
    glow_parts.append(ml)
    # tipping lug opposite the lip (it also balances the footprint)
    tl = [block("tip_lug", (0.36, 0.34, 0.26), (0, 1.0 + 0.17, base + 0.7), bevel=0.02, mat=m["iron_hot"], taper=0.0),
          torus("tip_eye", 0.1, 0.04, (0, 1.3, base + 0.7), rot=(0, math.pi / 2, 0), mat=m["iron"], seg=(10, 5))]
    parts += tl
    # lifting lugs on the rim, their eyes facing -Y; the crane's chains drop onto them
    for sx in (-1, 1):
        parts.append(block("lug", (0.3, 0.1, 0.42), (sx * lug_x, 0, H - 0.21), bevel=0.02, mat=m["iron"], taper=0.25))
        parts.append(torus("lug_eye", 0.075, 0.03, (sx * lug_x, -0.065, H - 0.14), rot=(math.pi / 2, 0, 0), mat=m["iron"],
                           seg=(10, 4)))
        for dz in (0.1, 0.24):
            parts.append(rivet(m, (sx * lug_x, -0.05, H - 0.42 + dz), (0, -1, 0), r=0.025))
    # molten metal: a bright pool with a dark crust drifting at its edge
    glow_parts.append(cylinder("molten", 1.05, 0.04, (0, 0, metal + 0.02), sides=24, mat=hot_m))
    for i in range(int(p.get("crust", 7))):
        aa = rng.uniform(0, math.tau)
        d = rng.uniform(0.62, 0.92)
        rr = rng.uniform(0.1, 0.2)
        parts.append(lump("crust", rr, (math.cos(aa) * d, math.sin(aa) * d, metal + 0.04), m["slag"], rng=rng, jitter=rr * 0.2,
                          scale=(1.4, 1.0, 0.25), rot=(0, 0, aa)))
    # slag run down the side under the lip, a congealed drip at its foot; spill on the deck
    for k in range(3):
        zz = rim_top - 0.42 - k * 0.3
        parts.append(lump("spill", 0.085 - 0.015 * k, (0.12 - 0.04 * k, -pot_r(zz) - 0.015, zz), m["slag"], rng=rng,
                          jitter=0.008, scale=(0.9, 0.45, 2.2), subdiv=2))
    glow_parts.append(lump("drip", 0.045, (0.0, -pot_r(rim_top - 1.2) - 0.03, rim_top - 1.2), em, scale=(0.8, 0.6, 1.5), subdiv=2))
    parts.append(lump("deck_slag", 0.2, (0.2, -0.75, deck_z + 0.04), m["slag"], rng=rng, jitter=0.02, scale=(1.4, 1.0, 0.2)))
    return parts, glow_parts


# ----------------------------------------------------------------------------- crane arm

def crane_arm(p: dict, m: dict, rng) -> list:
    """The overhead crane arm turning with the crucibles (visual only). Its origin is the pivot on
    the furnace axis at the collar: a hub ring sitting on the furnace's collar, twin riveted lattice
    girders (top and bottom chords, Warren diagonals, cross ties, gusset plates) out along +Y and
    -Y to reach_m, a sheave housing at radius_m on each end, and from it a heavy chain to a hook
    block and a lifting beam whose two short chains drop onto the crucible's rim lugs at z =
    -drop_m. The piece extends below its origin by drop_m."""
    reach = p.get("reach_m", 9.4)
    rad = p.get("radius_m", 9.0)
    drop = p.get("drop_m", 3.7)
    lug_x = p.get("lug_x", 1.05)
    hub_in, hub_out = p.get("hub_inner_m", 2.05), p.get("hub_outer_m", 2.55)
    gx = p.get("girder_gap_m", 0.42)
    parts = []
    parts.append(hoop("hub", hub_in, hub_out, 0.0, 0.36, 32, m["iron"], iron_tint(rng), 0.03))
    parts.append(hoop("hub_lip", hub_out - 0.05, hub_out + 0.05, 0.26, 0.36, 32, m["iron"], iron_tint(rng)))
    for i in range(16):
        a = i * math.tau / 16
        parts.append(rivet(m, ((hub_in + hub_out) / 2 * math.cos(a), (hub_in + hub_out) / 2 * math.sin(a), 0.36), (0, 0, 1),
                           r=0.035))
    for s in (-1, 1):
        y0 = s * (hub_in + 0.15)
        # root bracket on the hub, riveted
        parts.append(block("root", (2 * gx + 0.3, 0.7, 1.45), (0, s * (hub_out - 0.05), 0.72), bevel=0.02, mat=m["iron"],
                           tint=iron_tint(rng)))
        parts += rivet_row(m, (-gx - 0.1, s * (hub_out + 0.31), 0.25), (-gx - 0.1, s * (hub_out + 0.31), 1.25), 4, (0, s, 0))
        parts += rivet_row(m, (gx + 0.1, s * (hub_out + 0.31), 0.25), (gx + 0.1, s * (hub_out + 0.31), 1.25), 4, (0, s, 0))
        y_root = s * (hub_out + 0.3)
        y_end = s * reach
        n_pan = int(p.get("panels", 7))
        top0, top1 = 1.4, 0.62
        bot = 0.06
        for x in (-gx, gx):
            parts.append(beam("top_chord", (x, y_root, top0), (x, y_end, top1), 0.16, 0.16, m["iron"], iron_tint(rng), bevel=0.012))
            parts.append(beam("bottom_chord", (x, y_root, bot), (x, y_end, bot), 0.16, 0.14, m["iron"], iron_tint(rng), bevel=0.012))
            for k in range(n_pan + 1):
                t = k / n_pan
                y = y_root + (y_end - y_root) * t
                zt = top0 + (top1 - top0) * t
                parts.append(beam("post", (x, y, bot + 0.06), (x, y, zt - 0.06), 0.08, 0.05, m["iron"], bevel=0.0, up=(0, 1, 0)))
                if k < n_pan:
                    t2 = (k + 1) / n_pan
                    y2 = y_root + (y_end - y_root) * t2
                    zt2 = top0 + (top1 - top0) * t2
                    if k % 2 == 0:
                        a, b = (x, y, bot + 0.06), (x, y2, zt2 - 0.06)
                    else:
                        a, b = (x, y, zt - 0.06), (x, y2, bot + 0.06)
                    parts.append(beam("diagonal", a, b, 0.08, 0.05, m["iron"], bevel=0.0, up=(1, 0, 0)))
                # gusset plates at the bottom nodes (the end plate closes the last one)
                if k < n_pan:
                    parts.append(block("gusset", (0.03, 0.3, 0.22), (x + (0.1 if x > 0 else -0.1), y, bot + 0.13), bevel=0.0,
                                       mat=m["iron"]))
        # cross ties between the twin girders, top and bottom, every other node
        for k in range(0, n_pan + 1, 2):
            t = k / n_pan
            y = y_root + (y_end - y_root) * t
            zt = top0 + (top1 - top0) * t
            parts.append(beam("tie", (-gx, y, zt), (gx, y, zt), 0.1, 0.08, m["iron"], bevel=0.0))
            parts.append(beam("tie", (-gx, y, bot), (gx, y, bot), 0.1, 0.08, m["iron"], bevel=0.0))
        # end plate
        parts.append(block("end_plate", (2 * gx + 0.36, 0.1, top1 + 0.2), (0, y_end - s * 0.05, (top1 + bot) / 2 + 0.02),
                           bevel=0.014, mat=m["iron"]))
        # sheave housing at radius rad, hanging under the girders
        yc = s * rad
        for x in (-0.2, 0.2):
            parts.append(block("cheek", (0.05, 0.62, 0.66), (x, yc, -0.18), bevel=0.01, mat=m["iron"], tint=iron_tint(rng)))
            parts += rivet_row(m, (x + (0.03 if x > 0 else -0.03), yc - 0.22, -0.4), (x + (0.03 if x > 0 else -0.03), yc + 0.22, -0.4),
                               3, (1 if x > 0 else -1, 0, 0), r=0.025)
        parts.append(cylinder("sheave", 0.24, 0.12, (0, yc, -0.18), rot=(0, math.pi / 2, 0), sides=14, mat=m["iron"]))
        parts.append(cylinder("pin", 0.06, 0.56, (0, yc, -0.18), rot=(0, math.pi / 2, 0), sides=8, mat=m["iron"]))
        # the heavy chain, a hook block and the lifting beam
        hook_top = -drop + 0.72
        chain(parts, m, (0, yc, -0.4), (0, yc, hook_top + 0.04), link=0.27, thick=0.045)
        parts.append(block("hook_block", (0.34, 0.24, 0.32), (0, yc, hook_top - 0.16), bevel=0.03, mat=m["iron"], taper=0.15))
        parts.append(torus("hook", 0.11, 0.04, (0, yc, hook_top - 0.42), rot=(0, math.pi / 2, 0), mat=m["iron"], seg=(10, 5)))
        bz = -drop + 0.3
        parts.append(block("lift_beam", (2 * lug_x + 0.3, 0.16, 0.2), (0, yc, bz), bevel=0.014, mat=m["iron"], tint=iron_tint(rng)))
        parts.append(block("lift_beam_web", (0.4, 0.06, 0.22), (0, yc, bz + 0.18), bevel=0.01, mat=m["iron"]))
        for sx in (-1, 1):
            parts.append(torus("shackle", 0.07, 0.025, (sx * lug_x, yc, bz - 0.12), rot=(math.pi / 2, 0, 0), mat=m["iron"],
                               seg=(8, 4)))
            chain(parts, m, (sx * lug_x, yc, bz - 0.17), (sx * lug_x, yc, -drop + 0.035), link=0.16, thick=0.03)
    # clamp the lowest point to -drop exactly (link tori may overshoot by a centimetre or two)
    zmin = min((o.matrix_world @ v.co).z for o in parts for v in o.data.vertices)
    if zmin < -drop:
        f = drop / -zmin
        for o in parts:
            apply_xf([o])
            for v in o.data.vertices:
                if v.co.z < 0:
                    v.co.z *= f
    return parts


# ----------------------------------------------------------------------------- rail ring

def rail_ring(p: dict, m: dict, rng) -> list:
    """The casting wheel's track: two iron rails (rail_radii_m) on timber sleepers, a flat ring
    centred on the origin, no more than max_height_m tall."""
    radii = p.get("rail_radii_m", [8.6, 9.4])
    sides = int(p.get("sides", 96))
    top = p.get("max_height_m", 0.08)
    sl_h = 0.035
    parts = []
    for r in radii:
        loop = [(r - 0.07, sl_h - 0.004), (r + 0.07, sl_h - 0.004), (r + 0.07, sl_h + 0.012), (r + 0.032, sl_h + 0.02),
                (r + 0.036, top), (r - 0.036, top), (r - 0.032, sl_h + 0.02), (r - 0.07, sl_h + 0.012)]
        parts.append(revolve("rail", loop, sides, m["iron"], iron_tint(rng, 0.04), a0=math.pi / sides))
    n = int(p.get("sleepers", 64))
    r0, r1 = min(radii) - 0.3, max(radii) + 0.3
    for i in range(n):
        a = i * math.tau / n + rng.uniform(-0.01, 0.01)
        L = r1 - r0 + rng.uniform(-0.06, 0.06)
        o = block("sleeper", (L, 0.26, sl_h), ((r0 + r1) / 2, 0, sl_h / 2), bevel=0.008, mat=m["wood"],
                  tint=brick_tint(rng, 0.14), rot=(0, 0, rng.uniform(-0.03, 0.03)))
        kit.jitter_vertices(o, rng, 0.004)
        for v in o.data.vertices:
            v.co.z = min(max(v.co.z, 0.0), sl_h)
        group_xf([o], (0, 0, 0), (0, 0, a))
        parts.append(o)
    return parts


# ----------------------------------------------------------------------------- moulds

def _flask(parts, m, rng, sx: float, sy: float, h: float, loc, yaw: float = 0.0, top: str = "sand") -> None:
    """A riveted iron casting flask: four walls with outer flanges top and bottom, ribs, a
    lifting pin on each end, rammed sand (with pouring holes) or a cope lid on top."""
    obs = []
    t = 0.08
    for s in (-1, 1):
        obs.append(block("wall", (sx, t, h - 0.1), (0, s * (sy / 2 - t / 2), h / 2), bevel=0.012, mat=m["iron"], tint=iron_tint(rng)))
        obs.append(block("wall", (t, sy - 2 * t + 0.002, h - 0.1), (s * (sx / 2 - t / 2), 0, h / 2), bevel=0.012, mat=m["iron"],
                         tint=iron_tint(rng)))
    for z in (0.04, h - 0.04):
        obs.append(block("flange", (sx + 0.06, sy + 0.06, 0.08), (0, 0, z), bevel=0.012, mat=m["iron"], tint=iron_tint(rng)))
    nr = max(2, int(sx / 0.5))
    for s in (-1, 1):
        for i in range(nr):
            x = -sx / 2 + sx * (i + 0.5) / nr
            obs.append(block("rib", (0.05, 0.05, h - 0.12), (x, s * (sy / 2 + 0.02), h / 2), bevel=0.0, mat=m["iron"]))
        obs.append(cylinder("pin", 0.065, 0.12, (s * (sx / 2 + 0.06), 0, h * 0.55), rot=(0, math.pi / 2, 0), sides=8, mat=m["iron"]))
        obs.append(cylinder("pin_end", 0.1, 0.04, (s * (sx / 2 + 0.12), 0, h * 0.55), rot=(0, math.pi / 2, 0), sides=8, mat=m["iron"]))
    if top == "sand":
        obs.append(block("sand", (sx - 2 * t, sy - 2 * t, h - 0.14), (0, 0, (h - 0.14) / 2 + 0.04), bevel=0.01, mat=m["sand"],
                         tint=brick_tint(rng, 0.06)))
        # a pouring cup over the sprue and a vent hole
        cx, cy = rng.uniform(-sx * 0.25, sx * 0.25), rng.uniform(-sy * 0.2, sy * 0.2)
        obs.append(lathe("cup", [(0.2, h - 0.12), (0.26, h + 0.06), (0.16, h + 0.06), (0.06, h - 0.05)], loc=(cx, cy, 0), sides=10,
                         mat=m["sand"]))
        obs.append(cylinder("vent", 0.05, 0.03, (-cx * 0.8, -cy, h - 0.1), sides=6, mat=m["void"]))
    else:
        obs.append(block("lid", (sx - 0.02, sy - 0.02, 0.06), (0, 0, h - 0.06), bevel=0.01, mat=m["iron"], tint=iron_tint(rng)))
        for k in range(3):
            obs.append(block("lid_rib", (sx - 0.2, 0.06, 0.06), (0, -sy / 3 + k * sy / 3, h - 0.0), bevel=0.006, mat=m["iron"]))
    group_xf(obs, loc, (0, 0, yaw))
    parts += obs


def _clamp(parts, m, x: float, y: float, z0: float, z1: float, yaw: float = 0.0) -> None:
    """A C-clamp holding a flask stack together: a riveted bar down the side, jaws top and bottom
    and a wedge."""
    obs = [block("clamp", (0.1, 0.06, z1 - z0 + 0.16), (0, -0.05, (z0 + z1) / 2), bevel=0.01, mat=m["iron"]),
           block("jaw", (0.1, 0.2, 0.07), (0, 0.04, z1 + 0.05), bevel=0.008, mat=m["iron"]),
           block("jaw", (0.1, 0.2, 0.07), (0, 0.04, z0 - 0.05), bevel=0.008, mat=m["iron"]),
           block("wedge", (0.08, 0.16, 0.12), (0, 0.06, z1 + 0.12), bevel=0.006, mat=m["iron"], taper=0.3)]
    group_xf(obs, (x, y, 0), (0, 0, yaw))
    parts += obs


def _ingot(m, rng, loc, yaw: float = 0.0, L: float = 0.62, key: str = "pig"):
    o = block("ingot", (L, 0.15, 0.1), (0, 0, 0.05), bevel=0.014, mat=m[key], tint=iron_tint(rng, 0.1), taper=0.2)
    kit.jitter_vertices(o, rng, 0.004)
    group_xf([o], loc, (0, 0, yaw))
    return o


def mold(p: dict, m: dict, rng) -> list:
    """Stacked iron casting flasks and ingot moulds on timber skids, inside length_m (x) x
    width_m x height_m: two drag flasks side by side, a cope and a smaller pair stacked on them
    with C-clamps, and an ingot-mould comb on top with pig ingots, a few cast and cooling."""
    L, W, H = p.get("length_m", 4.0), p.get("width_m", 2.0), p.get("height_m", 2.4)
    parts = []
    for sy in (-1, 1):
        parts.append(block("skid", (L - 0.06, 0.26, 0.18), (0, sy * (W / 2 - 0.3), 0.09), bevel=0.02, mat=m["wood"],
                           tint=brick_tint(rng, 0.1)))
    z = 0.18
    f1 = p.get("drag_m", 1.05)
    fw = W - 0.26
    fl = L / 2 - 0.3
    _flask(parts, m, rng, fl, fw, f1, (-L / 4 + 0.02, 0, z), 0.0, "sand")
    _flask(parts, m, rng, fl, fw, f1, (L / 4 - 0.02, 0, z), 0.0, "cope")
    z2 = z + f1
    f2 = p.get("cope_m", 0.85)
    _flask(parts, m, rng, fl - 0.1, fw - 0.06, f2, (-L / 4 + 0.05, 0.0, z2), math.radians(rng.uniform(-2, 2)), "cope")
    _flask(parts, m, rng, 1.2, 1.2, 0.6, (L / 4 - 0.15, 0.08, z2), math.radians(rng.uniform(4, 10)), "sand")
    for sx in (-1, 1):
        _clamp(parts, m, -L / 4 + 0.05 + sx * 0.45, -fw / 2 - 0.02, z + 0.04, z2 + f2 - 0.04)
    _clamp(parts, m, -L / 4 + 0.05, fw / 2 + 0.02, z + 0.04, z2 + f2 - 0.04, math.pi)
    # ingot-mould comb on the top left: a base plate with dividers and ingots in some slots
    z3 = z2 + f2
    cl, cw = fl - 0.2, fw - 0.3
    parts.append(block("comb_base", (cl, cw, 0.1), (-L / 4 + 0.05, 0, z3 + 0.05), bevel=0.014, mat=m["iron"], tint=iron_tint(rng)))
    n = 6
    for i in range(n + 1):
        x = -L / 4 + 0.05 - cl / 2 + cl * i / n
        parts.append(block("divider", (0.06, cw, 0.14), (x, 0, z3 + 0.17), bevel=0.01, mat=m["iron"]))
    for i in range(n):
        if rng.random() < 0.7:
            x = -L / 4 + 0.05 - cl / 2 + cl * (i + 0.5) / n
            parts.append(_ingot(m, rng, (x, rng.uniform(-0.05, 0.05), z3 + 0.1), math.pi / 2, L=min(0.62, cw - 0.1)))
    # loose pig on the smaller flask, one still faintly hot (scorched)
    zt = z2 + 0.6
    for i in range(3):
        parts.append(_ingot(m, rng, (L / 4 - 0.15 + rng.uniform(-0.2, 0.2), 0.08 + (i - 1) * 0.2, zt), rng.uniform(-0.2, 0.2)))
    for i in range(2):
        parts.append(_ingot(m, rng, (L / 4 - 0.15 + (i - 0.5) * 0.25, 0.08, zt + 0.1), math.pi / 2 + rng.uniform(-0.1, 0.1)))
    return parts


# ----------------------------------------------------------------------------- dressing

def brazier(p: dict, m: dict, rng) -> tuple[list, list]:
    """A coke fire basket on three splayed legs, about 1.3 m tall: a grate, a basket of bent
    bars with two hoops, coke heaped to about 1.2 m with glowing lumps (emissive, separate), ash
    spilled underneath. The brazier_fire effect sits on its top, as on the crypt's fire bowl."""
    parts, coals = [], []
    em = molten(p, p.get("coal_glow", 5.0))
    em2 = ember(p)
    for i in range(3):
        a = i * math.tau / 3 + 0.3
        parts.append(kit.strut("leg", (math.cos(a) * 0.46, math.sin(a) * 0.46, 0.0), (math.cos(a) * 0.24, math.sin(a) * 0.24, 0.8),
                               0.03, sides=6, mat=m["iron"]))
        parts.append(block("foot", (0.14, 0.14, 0.04), (math.cos(a) * 0.47, math.sin(a) * 0.47, 0.02), bevel=0.01, mat=m["iron"]))
    parts.append(torus("leg_ring", 0.34, 0.022, (0, 0, 0.42), mat=m["iron"], seg=(14, 4)))
    parts.append(cylinder("grate", 0.3, 0.05, (0, 0, 0.8), sides=12, mat=m["iron"]))
    nb = 12
    for i in range(nb):
        a = i * math.tau / nb
        parts.append(kit.strut("bar", (math.cos(a) * 0.29, math.sin(a) * 0.29, 0.78), (math.cos(a) * 0.42, math.sin(a) * 0.42, 1.31),
                               0.018, sides=4, mat=m["iron"]))
    parts.append(torus("hoop", 0.355, 0.026, (0, 0, 1.02), mat=m["iron"], seg=(16, 4)))
    parts.append(torus("rim", 0.42, 0.03, (0, 0, 1.3), mat=m["iron"], seg=(16, 4)))
    parts.append(lathe("coke_bed", [(0.29, 0.82), (0.37, 1.08), (0.25, 1.16), (0.0, 1.18)], sides=12, mat=m["coal"]))
    for i in range(16):
        a = rng.uniform(0, math.tau)
        rr = rng.uniform(0.0, 0.3)
        o = lump("coke", rng.uniform(0.055, 0.085), (math.cos(a) * rr, math.sin(a) * rr, 1.12 + rng.uniform(0, 0.08) - rr * 0.15),
                 m["coal"], rng=rng, jitter=0.015)
        parts.append(o)
    for i in range(8):
        a = rng.uniform(0, math.tau)
        rr = rng.uniform(0.0, 0.26)
        coals.append(lump("glow", rng.uniform(0.05, 0.08), (math.cos(a) * rr, math.sin(a) * rr, 1.16 + rng.uniform(0, 0.05)),
                          em if i % 2 == 0 else em2, rng=rng, jitter=0.012))
    parts.append(lathe("ash", [(0.55, 0.0), (0.4, 0.03), (0.18, 0.05), (0.0, 0.055)], sides=12, mat=m["ash"]))
    kit.jitter_vertices(parts[-1], rng, 0.015)
    return parts, coals


def ingot_stack(p: dict, m: dict, rng) -> list:
    """Pig iron stacked in crossed layers on two timber bearers, about 0.8 m tall, with a few
    loose pigs at its foot."""
    parts = []
    for sy in (-1, 1):
        parts.append(block("bearer", (1.0, 0.14, 0.12), (0, sy * 0.3, 0.06), bevel=0.015, mat=m["wood"], tint=brick_tint(rng, 0.1)))
    layers = int(p.get("layers", 6))
    z = 0.12
    for l in range(layers):
        n = 5 if l % 2 == 0 else 4
        for i in range(n):
            if l == layers - 1 and rng.random() < 0.35:
                continue
            u = -0.36 + 0.72 * (i + 0.5) / n
            if l % 2 == 0:
                parts.append(_ingot(m, rng, (rng.uniform(-0.02, 0.02), u, z), rng.uniform(-0.03, 0.03), L=0.86))
            else:
                parts.append(_ingot(m, rng, (u, rng.uniform(-0.02, 0.02), z), math.pi / 2 + rng.uniform(-0.03, 0.03), L=0.86))
        z += 0.1
    for i in range(3):
        a = rng.uniform(0, math.tau)
        parts.append(_ingot(m, rng, (math.cos(a) * 0.75, math.sin(a) * 0.75, 0.0), a + math.pi / 2 + rng.uniform(-0.5, 0.5), L=0.8))
    return parts


def coal_heap(p: dict, m: dict, rng) -> list:
    """A low heap of coke against a wall or in a corner: a rough mound, lumps on its flanks,
    a shovel stuck in it and a few spilled lumps. About 0.6 m tall."""
    r = p.get("radius_m", 1.0)
    h = p.get("height_m", 0.55)
    parts = [lathe("mound", [(r, 0.0), (r * 0.8, h * 0.25), (r * 0.5, h * 0.7), (r * 0.18, h * 0.95), (0.0, h)], sides=14,
                   mat=m["coal"])]
    kit.jitter_vertices(parts[0], rng, 0.06)
    for v in parts[0].data.vertices:
        v.co.z = max(v.co.z, 0.0)
    parts[0].scale = (1.0, 0.8, 1.0)
    apply_xf([parts[0]])
    def mound_z(d):  # the mound's surface height at distance d (its profile, piecewise linear)
        prof = [(0.0, h), (0.18, h * 0.95), (0.5, h * 0.7), (0.8, h * 0.25), (1.0, 0.0)]
        t = min(d / r, 1.0)
        for (t0, z0), (t1, z1) in zip(prof, prof[1:]):
            if t <= t1:
                return z0 + (z1 - z0) * (t - t0) / (t1 - t0)
        return 0.0

    for i in range(int(p.get("lumps", 40))):
        a = rng.uniform(0, math.tau)
        d = rng.uniform(0.0, 1.08) * r
        rr = rng.uniform(0.06, 0.13)
        zz = max(mound_z(d) + rr * 0.3, rr * 1.0)
        parts.append(lump("coke", rr, (math.cos(a) * d, math.sin(a) * d * 0.8, zz), m["coal"], rng=rng, jitter=rr * 0.25,
                          rot=(rng.uniform(0, 3), rng.uniform(0, 3), 0)))
    # a shovel driven into the heap
    sh = [cylinder("handle", 0.025, 1.0, (0, 0, 0.5), sides=6, mat=m["wood"]),
          block("blade", (0.26, 0.03, 0.3), (0, 0, -0.12), bevel=0.008, mat=m["iron"], taper=0.15),
          block("grip", (0.16, 0.035, 0.035), (0, 0, 1.0), bevel=0.006, mat=m["wood"])]
    group_xf(sh, (r * 0.35, 0.0, h * 0.75), (0.35, -0.25, 0.4))
    parts += sh
    return parts


def tool_rack(p: dict, m: dict, rng) -> list:
    """A wall-mounted rack of foundry tools: a timber backboard on two iron brackets with a
    hook rail, holding long tongs, a hand ladle, a skimmer and a poker. Back on y = 0, front
    toward -Y; the tools hang from about 1.9 m to 0.35 m above the floor."""
    w = p.get("width_m", 1.9)
    rail_z = p.get("rail_m", 1.85)
    parts = [block("board", (w, 0.06, 0.34), (0, -0.03, rail_z), bevel=0.012, mat=m["wood"], tint=brick_tint(rng, 0.1))]
    # an iron quench trough on the floor under the tools, half full of black water
    tw, td, th = w - 0.2, 0.42, 0.32
    for sy in (-1, 1):
        parts.append(block("trough", (tw, 0.05, th), (0, -0.03 - td / 2 + sy * (td / 2 - 0.025), th / 2), bevel=0.01, mat=m["iron"],
                           tint=iron_tint(rng)))
    for sx in (-1, 1):
        parts.append(block("trough_end", (0.05, td - 0.09, th - 0.01), (sx * (tw / 2 - 0.025), -0.03 - td / 2, th / 2), bevel=0.01,
                           mat=m["iron"]))
    parts.append(block("trough_floor", (tw - 0.1, td - 0.1, 0.04), (0, -0.03 - td / 2, 0.02), bevel=0.0, mat=m["iron"]))
    parts.append(block("water", (tw - 0.1, td - 0.1, 0.04), (0, -0.03 - td / 2, th * 0.6), bevel=0.0, mat=m["void"]))
    parts.append(block("trough_rim", (tw + 0.04, 0.08, 0.05), (0, -0.03 - td + 0.03, th), bevel=0.008, mat=m["iron"]))
    for sx in (-1, 1):
        parts.append(block("bracket", (0.06, 0.05, 0.6), (sx * (w / 2 - 0.15), -0.085, rail_z - 0.12), bevel=0.008, mat=m["iron"]))
        for dz in (-0.3, 0.05):
            parts.append(rivet(m, (sx * (w / 2 - 0.15), -0.11, rail_z + dz), (0, -1, 0), r=0.022))
    parts.append(block("rail", (w - 0.1, 0.05, 0.06), (0, -0.09, rail_z + 0.05), bevel=0.008, mat=m["iron"]))
    hooks = [(-w / 2 + 0.28 + i * (w - 0.56) / 4) for i in range(5)]
    for x in hooks:
        parts.append(block("hook", (0.03, 0.14, 0.03), (x, -0.16, rail_z + 0.04), bevel=0, mat=m["iron"]))
        parts.append(block("hook_tip", (0.03, 0.03, 0.08), (x, -0.22, rail_z + 0.08), bevel=0, mat=m["iron"]))
    hang = rail_z + 0.0
    y = -0.25
    # long tongs: two crossed bars with a pivot and jaws
    x = hooks[0]
    for s in (-1, 1):
        parts.append(kit.strut("tong", (x + s * 0.03, y, hang), (x - s * 0.07, y, 0.55), 0.016, sides=5, mat=m["iron"]))
        # (each part starts a few millimetres off the last one's end: coincident caps would weld
        # into non-manifold edges)
        parts.append(kit.strut("jaw", (x - s * 0.07, y + 0.004, 0.556), (x + s * 0.03, y, 0.38), 0.02, sides=5, mat=m["iron"]))
    parts.append(torus("tong_ring", 0.05, 0.014, (x, y, hang - 0.02), rot=(math.pi / 2, 0, 0), mat=m["iron"], seg=(8, 4)))
    parts.append(cylinder("tong_pivot", 0.025, 0.08, (x - 0.042, y, 0.62), rot=(math.pi / 2, 0, 0), sides=6, mat=m["iron"]))
    # a hand ladle: long handle, a bowl at the bottom, crusted with slag
    x = hooks[1]
    parts.append(kit.strut("ladle_handle", (x, y, hang), (x, y, 0.62), 0.018, sides=6, mat=m["iron"]))
    parts.append(lathe("ladle_bowl", [(0.0, 0.36), (0.13, 0.4), (0.17, 0.52), (0.15, 0.55), (0.13, 0.5), (0.0, 0.47)], sides=12,
                       mat=m["iron"], loc=(x, y - 0.04, 0.0)))
    parts.append(lump("crust", 0.06, (x + 0.08, y - 0.12, 0.47), m["slag"], scale=(1.2, 0.8, 0.6)))
    parts.append(torus("ladle_eye", 0.04, 0.012, (x, y, hang - 0.02), rot=(math.pi / 2, 0, 0), mat=m["iron"], seg=(8, 4)))
    # a skimmer: a rod with a flat perforated plate
    x = hooks[2]
    parts.append(kit.strut("skimmer_rod", (x, y, hang), (x, y, 0.5), 0.015, sides=6, mat=m["iron"]))
    parts.append(cylinder("skimmer", 0.16, 0.03, (x, y - 0.02, 0.38), rot=(math.pi / 2 - 0.15, 0, 0), sides=12, mat=m["iron"]))
    # pokers: a hooked rod and a straight one with a wooden grip
    for k, x in enumerate(hooks[3:]):
        bottom = 0.4 + 0.12 * k
        parts.append(kit.strut("poker", (x, y, hang), (x, y, bottom), 0.017, sides=6, mat=m["iron"]))
        parts.append(cylinder("grip", 0.03, 0.32, (x, y, hang - 0.25), sides=6, mat=m["wood"]))
        if k == 0:
            parts.append(kit.strut("poker_hook", (x, y + 0.004, bottom + 0.006), (x + 0.12, y - 0.05, bottom + 0.08), 0.017, sides=6,
                                   mat=m["iron"]))
        else:
            parts.append(block("rake", (0.22, 0.03, 0.09), (x, y - 0.02, bottom - 0.03), bevel=0.006, mat=m["iron"]))
    return parts


# ----------------------------------------------------------------------------- skyline

def _windows(parts, glow_parts, m, rng, plane_y: float, us, zs, lit: float, lit_mat, w=1.0, h=2.2, arched=True):
    """Tall works windows on a face looking toward -Y: dark or (a fraction `lit`) glowing."""
    for u in us:
        for z in zs:
            is_lit = rng.random() < lit
            mat = lit_mat if is_lit else m["void"]
            o = block("window", (w, 0.14, h), (u, plane_y - 0.04, z), bevel=0, mat=mat)
            objs = [o]
            if arched:
                objs.append(cylinder("window_head", w / 2 - 0.004, 0.136, (u, plane_y - 0.04, z + h / 2), rot=(math.pi / 2, 0, 0),
                                     sides=8, mat=mat))
            (glow_parts if is_lit else parts).extend(objs)
            parts.append(block("sill", (w + 0.3, 0.3, 0.16), (u, plane_y - 0.1, z - h / 2 - 0.08), bevel=0.02, mat=m["far_brick"]))


def skyline_stacks(p: dict, m: dict, rng) -> tuple[list, list]:
    """Tall brick smokestacks beyond the walls: square plinths, round tapering shafts with iron
    bands and corbelled caps, a low boiler house between them; one stack's mouth glows faintly.
    A low-detail silhouette."""
    stacks = p.get("stacks", [[-6.0, 0.0, 30.0, 1.7], [1.5, 2.5, 24.0, 1.4], [7.0, -1.0, 34.0, 1.9]])
    fb = m["far_brick"]
    em = ember(p, 2.0)
    parts, glow_parts = [], []
    glowing = int(p.get("glowing", 2))
    for i, (x, y, h, r) in enumerate(stacks):
        ps = r * 2 + 1.2
        parts.append(block("plinth", (ps, ps, 4.0), (x, y, 2.0), bevel=0.08, mat=fb, tint=brick_tint(rng, 0.06), taper=0.04))
        parts.append(block("plinth_cap", (ps + 0.4, ps + 0.4, 0.4), (x, y, 4.1), bevel=0.06, mat=fb))
        parts.append(lathe("shaft", [(r, 4.0), (r * 0.66, h)], loc=(x, y, 0), sides=12, mat=fb, tint=brick_tint(rng, 0.06)))
        for t in (0.35, 0.6, 0.82):
            z = 4.0 + (h - 4.0) * t
            rr = r + (r * 0.66 - r) * t
            parts.append(cylinder("band", rr + 0.08, 0.3, (x, y, z), sides=12, mat=m["iron"]))
        rt = r * 0.66
        parts.append(lathe("cap", [(rt, h - 0.1), (rt + 0.45, h + 0.6), (rt + 0.45, h + 1.2), (rt - 0.25, h + 1.2),
                                   (rt - 0.25, h + 0.8)], loc=(x, y, 0), sides=12, mat=fb, tint=brick_tint(rng, 0.05)))
        if i == glowing:
            glow_parts.append(cylinder("mouth", rt - 0.28, 0.05, (x, y, h + 1.0), sides=12, mat=em))
        else:
            parts.append(cylinder("mouth", rt - 0.28, 0.05, (x, y, h + 1.0), sides=12, mat=m["void"]))
    # a low boiler house tying the stacks together
    parts.append(block("boiler_house", (14.0, 6.0, 5.5), (0.5, 4.5, 2.75), bevel=0.08, mat=fb, tint=brick_tint(rng, 0.06)))
    parts.append(prism("boiler_roof", 14.6, 6.8, 2.2, (0.5, 4.5, 5.5), mat=m["far_roof"]))
    _windows(parts, glow_parts, m, rng, 1.5, [-4.5, -1.5, 1.5, 4.5], [2.6], 0.25, em, w=1.0, h=2.0)
    return parts, glow_parts


def skyline_works(p: dict, m: dict, rng) -> tuple[list, list]:
    """Works buildings beyond the walls: a long brick casting hall with a gabled roof and a
    raised ventilating lantern along its ridge, tall round-headed windows (a quarter or fewer
    glowing), a lower lean-to shed, a squat square chimney and a timber gantry. About width_m
    wide, the front facing -Y. A low-detail silhouette."""
    W = p.get("width_m", 18.0)
    D = p.get("depth_m", 9.0)
    h = p.get("height_m", 9.0)
    fb = m["far_brick"]
    em = ember(p, 2.2)
    parts, glow_parts = [], []
    parts.append(block("hall", (W, D, h), (0, 0, h / 2), bevel=0.1, mat=fb, tint=brick_tint(rng, 0.05)))
    for x in [-W / 2 + 0.4 + i * (W - 0.8) / 5 for i in range(6)]:  # buttress piers
        parts.append(block("pier", (0.8, 0.6, h - 0.4), (x, -D / 2 - 0.25, (h - 0.4) / 2), bevel=0.06, mat=fb, taper=0.05))
    roof_h = p.get("roof_m", 4.5)
    parts.append(prism("roof", W + 0.6, D + 1.0, roof_h, (0, 0, h), mat=m["far_roof"], tint=brick_tint(rng, 0.05)))
    parts.append(block("lantern", (W * 0.7, 2.2, 1.4), (0, 0, h + roof_h - 0.6 + 0.7), bevel=0.04, mat=m["void"]))
    parts.append(prism("lantern_roof", W * 0.7 + 0.4, 3.2, 1.0, (0, 0, h + roof_h + 0.5), mat=m["far_roof"]))
    xs = [-W / 2 + 0.4 + (i + 0.5) * (W - 0.8) / 5 for i in range(5)]
    _windows(parts, glow_parts, m, rng, -D / 2, xs, [h * 0.45], 0.25, em, w=1.4, h=3.6)
    # lean-to shed on the left
    sw = 6.0
    parts.append(block("shed", (sw, D * 0.8, h * 0.5), (-W / 2 - sw / 2, 0.4, h * 0.25), bevel=0.08, mat=fb,
                       tint=brick_tint(rng, 0.06)))
    shed_roof = prism("shed_roof", sw + 0.4, D * 0.8 + 0.6, 1.8, (-W / 2 - sw / 2, 0.4, h * 0.5), mat=m["far_roof"],
                      ridge_shift=D * 0.4)
    parts.append(shed_roof)
    _windows(parts, glow_parts, m, rng, -D * 0.4 + 0.4, [-W / 2 - sw / 2], [h * 0.22], 0.0, em, w=1.6, h=1.8, arched=False)
    # squat square chimney on the right
    cx = W / 2 - 2.5
    parts.append(block("chimney", (2.0, 2.0, h + roof_h + 5.0), (cx, D * 0.15, (h + roof_h + 5.0) / 2), bevel=0.06, mat=fb,
                       tint=brick_tint(rng, 0.06)))
    parts.append(block("chimney_cap", (2.5, 2.5, 0.5), (cx, D * 0.15, h + roof_h + 5.2), bevel=0.05, mat=fb))
    # a timber gantry on the right end: two trestles and a beam
    gx = W / 2 + 2.5
    for gy in (-2.0, 2.0):
        for sx in (-1, 1):
            parts.append(kit.strut("trestle", (gx + sx * 1.2, gy, 0.0), (gx + sx * 0.3, gy, 7.0), 0.18, sides=4, mat=m["wood"]))
    parts.append(block("gantry_beam", (1.0, 5.4, 0.6), (gx, 0, 7.2), bevel=0.04, mat=m["wood"]))
    return parts, glow_parts


PIECES = {"floor_tile": floor_tile, "wall": wall, "corner": corner, "gate": gate, "gate_lintel": gate_lintel,
          "gatehouse": gatehouse, "furnace": furnace, "crucible": crucible, "crane_arm": crane_arm,
          "rail_ring": rail_ring, "mold": mold, "brazier": brazier, "ingot_stack": ingot_stack, "coal_heap": coal_heap,
          "tool_rack": tool_rack, "skyline_stacks": skyline_stacks, "skyline_works": skyline_works}
BACK_ON_Y0 = {"wall", "gate_lintel", "tool_rack"}
KEEP_XY = {"furnace", "crucible", "rail_ring"}  # built round the collider's axis
KEEP_ORIGIN = {"crane_arm"}  # hung from its pivot


def build(spec: dict, previews: Path | None) -> None:
    kit.build_spec(spec, previews, PIECES, BACK_ON_Y0, mats, preset=PRESET, keep_xy=KEEP_XY, keep_origin=KEEP_ORIGIN)


# ----------------------------------------------------------------------------- assembled preview

def render_assembled(out_png: Path, cell: int = 768, samples: int = 32) -> Path:
    """Import the exported pieces and stand them as in the arena: the furnace at the hub, the rail
    ring, crucibles at (0, +-9 m), the crane arm at collar_m, a floor of tiles and a run of walls
    with a corner beyond the far crucible. Renders an overview and a player-height view."""
    from PIL import Image, ImageDraw

    common.reset_scene()
    kit_dir = common.REPO / "game" / "assets" / "kits" / "foundry"
    spec = {s.stem: json.loads(s.read_text()) for s in (common.REPO / "data" / "assets").glob("foundry_*.json")}
    collar = spec["foundry_crane_arm"]["params"].get("collar_m", 6.3)

    def place(piece: str, loc=(0, 0, 0), yaw: float = 0.0):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=str(kit_dir / f"foundry_{piece}.glb"))
        new = [o for o in bpy.data.objects if o not in before]
        root = bpy.data.objects.new(f"place_{piece}", None)
        bpy.context.scene.collection.objects.link(root)
        for o in new:
            if o.parent is None:
                o.parent = root
        root.location = loc
        root.rotation_euler = (0, 0, yaw)
        return root

    tile_top = 0.22
    for ix in range(-3, 3):
        for iy in range(-3, 6):
            piece = "floor_tile_worn" if (ix * 7 + iy * 3) % 5 == 0 else "floor_tile"
            place(piece, (ix * 4 + 2, iy * 4 + 2, -tile_top), ((ix + iy) % 4) * math.pi / 2)
    place("furnace")
    place("rail_ring")
    place("crucible", (0, 9, 0))
    place("crucible", (0, -9, 0))  # both unturned, as the map builder places them
    place("crane_arm", (0, 0, collar))
    for i, x in enumerate((-10, -6, -2, 2, 6, 10)):
        place("wall_vents" if i in (1, 4) else "wall", (x, 18, 0))
    place("corner", (12.55, 18.55, 0))
    place("mold", (-11, 12, 0), math.pi / 2)
    place("brazier", (8, 16.5, 0))
    place("tool_rack", (-4, 17.95, 0))
    place("coal_heap", (4.5, 16.8, 0))
    place("ingot_stack", (-7.5, 16.6, 0))
    scene = bpy.context.scene
    common.setup_lighting(PRESET)
    cam = bpy.data.objects.new("_cam", bpy.data.cameras.new("_cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x = cell
    scene.render.resolution_y = int(cell * 9 / 16)
    scene.view_settings.view_transform = "AgX"
    shots = [("overview", (17.0, -19.0, 15.0), (0, 3.0, 2.0), 28),
             ("player", (5.5, -17.0, 3.2), (0, 2.0, 2.8), 24),
             ("under the arm", (3.5, -3.0, 1.7), (0, -9.0, 4.5), 20)]
    tiles = []
    for label, loc, target, lens in shots:
        cam.data.lens = lens
        cam.location = loc
        cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        tmp = out_png.with_name(f"_{out_png.stem}_{label.replace(' ', '_')}.png")
        scene.render.filepath = str(tmp)
        bpy.ops.render.render(write_still=True)
        tiles.append((label, tmp))
    w, h = scene.render.resolution_x, scene.render.resolution_y
    sheet = Image.new("RGB", (w, (h + 24) * len(tiles)), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    for i, (label, tmp) in enumerate(tiles):
        sheet.paste(Image.open(tmp).convert("RGB"), (0, i * (h + 24) + 24))
        draw.text((8, i * (h + 24) + 6), label, fill=(220, 220, 220))
        tmp.unlink()
    out_png.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_png)
    return out_png


def main() -> int:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spec", type=Path)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--only", nargs="*", help="with --all: only these piece names or asset ids")
    ap.add_argument("--previews", type=Path)
    ap.add_argument("--assembled", type=Path, help="render the assembled preview to this PNG (needs the exported pieces)")
    ap.add_argument("--samples", type=int, default=32)
    args = ap.parse_args(argv)
    if args.assembled:
        out = args.assembled if args.assembled.is_absolute() else common.REPO / args.assembled
        render_assembled(out, samples=args.samples)
        return 0
    specs = sorted((common.REPO / "data" / "assets").glob("foundry_*.json")) if args.all else [args.spec]
    for path in specs:
        spec = json.loads(Path(path).read_text())
        if args.only and spec["params"]["piece"] not in args.only and spec["id"] not in args.only:
            continue
        build(spec, args.previews)
    return 0


if __name__ == "__main__":
    sys.exit(main())
