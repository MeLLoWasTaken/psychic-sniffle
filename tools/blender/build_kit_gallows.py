"""Gallows Courtyard environment kit (backlog M1-15): flagstone floor, stone wall facade and
corner, pillar, iron portcullis and stone lintel, wooden gallows platform, brazier and team
banners, plus the F-05 dressing pieces in build_kit_gallows_dressing.py (ramparts, gatehouse,
turret, skyline, props, worn floor). One piece per asset spec (params.piece).

Usage:
  python3 tools/blender/build_kit_gallows.py --spec data/assets/gallows_pillar.json --previews previews/kit
  python3 tools/blender/build_kit_gallows.py --all --previews previews/kit      # every gallows_* spec

Pivots (Blender axes; the glTF exporter turns -Y into Godot's +Z):
  floor_tile, pillar, gallows, brazier, corner, gate: centred, lowest point at z = 0.
  wall, gate_lintel, banner: the front faces -Y and the back (wall side) lies on y = 0, so a
  piece can be placed flush against a collider face; centred on x, lowest point at z = 0.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
import common  # noqa: E402
import kit  # noqa: E402
import build_kit_gallows_dressing as dressing  # noqa: E402  (F-05 pieces)
from build_kit_gallows_dressing import lathe  # noqa: E402
from kit import block, cylinder, random_tint  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

GAP = 0.04  # joint between stones


def mats(pal: dict) -> dict:
    return {
        "stone": kit.kit_material("stone", pal.get("stone", "#6d6961"), roughness=0.9, edge=0.35, cavity=0.6),
        "flag": kit.kit_material("flag", pal.get("flag", "#5b5852"), roughness=0.92, edge=0.28, cavity=0.55,
                                 top_light=0.05),
        "mortar": kit.kit_material("mortar", pal.get("mortar", "#2c2a27"), roughness=0.95, edge=0.0, cavity=0.3),
        "wood": kit.kit_material("wood", pal.get("wood", "#6b4a30"), roughness=0.85, edge=0.3, cavity=0.55,
                                 mottle=0.18, mottle_scale=0.9),
        "dark_wood": kit.kit_material("dark_wood", pal.get("dark_wood", "#46301f"), roughness=0.85, edge=0.3),
        "iron": kit.kit_material("iron", pal.get("iron", "#3c3f44"), roughness=0.55, metallic=0.3, edge=0.55,
                                 cavity=0.5, top_light=0.1),
        "rope": kit.kit_material("rope", pal.get("rope", "#8a7654"), roughness=0.95, edge=0.1, cavity=0.3),
        "cloth": kit.kit_material("cloth", pal.get("cloth", "#7a1414"), roughness=0.9, edge=0.08, cavity=0.35,
                                  top_light=0.12, mottle=0.08),
        "emblem": kit.kit_material("emblem", pal.get("emblem", "#d8ccb0"), roughness=0.9, edge=0.1, cavity=0.3),
        # F-19: weathered stone and timber for the focal pieces (pillar, gallows): rain streaks,
        # a little rising damp and dark growth in the joints, timber greyed and streaked
        "stone_worn": kit.kit_material("stone_worn", pal.get("stone", "#6d6961"), roughness=0.9, edge=0.4, cavity=0.68,
                                       top_light=0.12, mottle=0.16, mottle_scale=0.5, moss=0.22,
                                       moss_color=pal.get("grime", "#4c4a36"), moss_scale=1.6, damp=0.35, damp_m=0.9,
                                       streaks=0.45),
        "timber": kit.kit_material("timber", pal.get("dark_wood", "#46301f"), roughness=0.88, edge=0.38, cavity=0.6,
                                   mottle=0.2, mottle_scale=1.1, streaks=0.3),
        "boards": kit.kit_material("boards", pal.get("wood", "#6b4a30"), roughness=0.88, edge=0.3, cavity=0.6,
                                   mottle=0.22, mottle_scale=1.5, streaks=0.3, damp=0.3, damp_m=0.6),
    }


def glow_material(name: str, hex_color: str, strength: float) -> bpy.types.Material:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    c = common.hex_to_linear(hex_color)
    b.inputs["Base Color"].default_value = c
    b.inputs["Emission Color"].default_value = c
    b.inputs["Emission Strength"].default_value = strength
    b.inputs["Roughness"].default_value = 0.9
    return m


# ----------------------------------------------------------------------------- pieces

def floor_tile(p: dict, m: dict, rng) -> list:
    """4 x 4 m of irregular flagstones over a dark mortar bed."""
    size = p.get("size_m", 4.0)
    gap = 0.045
    thick = 0.14
    parts = [block("bed", (size, size, 0.1), (0, 0, 0.05), bevel=0, mat=m["mortar"])]
    y = -size / 2
    while y < size / 2 - 0.01:
        h = min(rng.uniform(0.75, 1.3), size / 2 - y)
        if size / 2 - (y + h) < 0.5:
            h = size / 2 - y
        x = -size / 2
        while x < size / 2 - 0.01:
            w = min(rng.uniform(0.7, 1.45), size / 2 - x)
            if size / 2 - (x + w) < 0.45:
                w = size / 2 - x
            top = 0.1 + thick + rng.uniform(-0.012, 0.012)
            s = block("flag", (w - gap, h - gap, thick), (x + w / 2, y + h / 2, top - thick / 2), bevel=0.03,
                      segments=2, mat=m["flag"], tint=random_tint(rng, 0.13),
                      rot=(rng.uniform(-0.008, 0.008), rng.uniform(-0.008, 0.008), 0))
            kit.jitter_vertices(s, rng, 0.006)
            parts.append(s)
            x += w
        y += h
    return parts


def wall(p: dict, m: dict, rng) -> list:
    """A 4 m wide, 6 m tall facade of coursed stone with a plinth course and coping. course_m and
    stone_m (min, max) set the stone sizes and bevel_segments their bevel; larger stones and one
    segment make a cheap facade for faces only seen from afar (the outside of the arena walls)."""
    width, height = p.get("width_m", 4.0), p.get("height_m", 6.0)
    course_lo, course_hi = p.get("course_m", (0.42, 0.6))
    stone_lo, stone_hi = p.get("stone_m", (0.6, 1.3))
    segs = p.get("bevel_segments", 2)
    half = width / 2
    gap = 0.04
    parts = [block("backing", (width, 0.4, height), (0, 0.45, height / 2), bevel=0, mat=m["mortar"])]
    z = 0.0
    course = 0
    while z < height - 0.55:
        plinth = course == 0
        ch = 0.75 if plinth else rng.uniform(course_lo, course_hi)
        if height - 0.5 - (z + ch) < 0.35:
            ch = height - 0.5 - z
        depth = 0.34 if plinth else 0.3
        x = -half - (rng.uniform(0, 0.5) if course % 2 else 0)
        while x < half - 0.01:
            w = rng.uniform(stone_lo, stone_hi)
            x0, x1 = max(x, -half), min(x + w, half)
            if x1 - x0 > 0.12:
                front = -rng.uniform(0.0, 0.025)  # slightly uneven face
                s = block("stone", (x1 - x0 - gap, depth, ch - gap),
                          ((x0 + x1) / 2, front + depth / 2, z + ch / 2), bevel=0.035, segments=segs,
                          mat=m["stone"], tint=random_tint(rng, 0.12, 0.04))
                kit.jitter_vertices(s, rng, 0.012)
                parts.append(s)
            x += w
        z += ch
        course += 1
    # coping: large slabs that overhang the face a little
    x = -half
    while x < half - 0.01:
        w = min(rng.uniform(1.0, 1.6), half - x)
        if half - (x + w) < 0.4:
            w = half - x
        s = block("coping", (w - gap, 0.62, 0.5), (x + w / 2, 0.21, height - 0.25), bevel=0.04, segments=segs,
                  mat=m["stone"], tint=random_tint(rng, 0.08))
        kit.jitter_vertices(s, rng, 0.01)
        parts.append(s)
        x += w
    return parts


def corner(p: dict, m: dict, rng) -> list:
    """Quoin column for outside corners where two facades meet."""
    height = p.get("height_m", 6.0)
    parts = []
    z = 0.0
    i = 0
    while z < height - 0.01:
        ch = min(rng.uniform(0.45, 0.6), height - z)
        w = 0.9 if i % 2 == 0 else 0.8
        s = block("quoin", (w, w, ch - 0.04), (0, 0, z + ch / 2), bevel=0.04, segments=2, mat=m["stone"],
                  tint=random_tint(rng, 0.1))
        kit.jitter_vertices(s, rng, 0.012)
        parts.append(s)
        z += ch
        i += 1
    return parts


def _group(objs: list, loc=(0, 0, 0), yaw: float = 0.0) -> list:
    """Bake each object's placement, then turn the group about z by `yaw` and move it by `loc`."""
    dressing.apply_xf(objs)
    mx = Matrix.Translation(loc) @ Matrix.Rotation(yaw, 4, "Z")
    for o in objs:
        o.data.transform(mx)
    return objs


def _beam(name: str, p0, p1, width: float, thick: float, normal, mat, tint=(1, 1, 1), bevel: float = 0.015):
    """A squared timber from p0 to p1: `thick` along `normal` (made square to the beam), `width`
    across both."""
    a, b = Vector(p0), Vector(p1)
    x = (b - a).normalized()
    n = Vector(normal)
    y = (n - x * n.dot(x)).normalized()
    z = x.cross(y)
    o = block(name, ((b - a).length, thick, width), (0, 0, 0), bevel=bevel, mat=mat, tint=tint)
    mx = Matrix((x, y, z)).transposed().to_4x4()
    mx.translation = (a + b) / 2
    o.data.transform(mx)
    return o


def _oct_stone(m, rng, a: float, ang: float, z0: float, h: float, w: float, du: float = 0.0,
               depth: float = 0.42, chip: float = 0.0, sink: float = 0.0):
    """One stone of an octagonal course: its face on the side at apothem `a` facing angle `ang`,
    `du` along the side from its middle. `chip` breaks one front corner back along a slanted
    plane (deepest at the top front); `sink` sets the face back (a spalled stone)."""
    o = block("stone", (w - GAP, depth, h - GAP), (0, 0, 0), bevel=0.03, mat=m["stone_worn"],
              tint=random_tint(rng, 0.12, 0.04))
    if chip:
        sx = rng.choice((-1, 1))
        for v in o.data.vertices:
            if v.co.x * sx > 0:
                front = 0.5 - v.co.y / depth  # 1 at the face (y = -depth / 2), 0 at the back
                up = 0.5 + v.co.z / h
                v.co.x -= sx * chip * front * (0.35 + 0.65 * up)
    kit.jitter_vertices(o, rng, 0.01)
    n = Vector((math.cos(ang), math.sin(ang), 0))
    t = Vector((-math.sin(ang), math.cos(ang), 0))
    c = n * (a - depth / 2 - sink) + t * du
    return _group([o], (c.x, c.y, z0 + h / 2), ang + math.pi / 2)[0]


def pillar(p: dict, m: dict, rng) -> list:
    """An octagonal ashlar pier (collision radius radius_m, height_m tall), built for the yard's
    punishments: a stepped plinth, coursed stones (some split, chipped or spalled) over a mortar
    core, a band course where the shaft steps in, three corbel courses under a cornice, a
    pyramid cap with a ball finial, iron shackles on short chains on one face and a notice board
    with two nailed sheets on the opposite face. A few chips lie at its foot."""
    r = p.get("radius_m", 1.2)
    height = p.get("height_m", 6.0)
    k = r / 1.2
    sm = m["stone_worn"]
    oct_rot = (0, 0, math.pi / 8)  # lathe vertices on the diagonals, so the flats face +-x and +-y

    def circ(ap: float) -> float:  # circumradius of an octagon with apothem ap
        return ap / math.cos(math.pi / 8)

    a1, a2 = 1.04 * k, 0.98 * k  # shaft apothems below and above the band course
    plinth_top, band0, band1, shaft_top = 0.82, 2.4, 2.64, 4.25
    parts = [lathe("plinth", [(circ(1.17 * k), 0.0), (circ(1.17 * k), 0.32), (circ(1.11 * k), 0.4),
                              (circ(1.11 * k), 0.7), (circ(a1), plinth_top)], sides=8, rot=oct_rot, mat=sm,
                   tint=random_tint(rng, 0.05), bevel=0.03)]
    kit.jitter_vertices(parts[0], rng, 0.01)
    parts.append(lathe("core", [(circ(a2 - 0.06), plinth_top - 0.02), (circ(a2 - 0.06), shaft_top + 0.02)], sides=8,
                       rot=oct_rot, mat=m["mortar"]))

    def courses(z0: float, z1: float, a: float) -> None:
        side_w = 2 * a * math.tan(math.pi / 8)
        z = z0
        while z < z1 - 0.05:
            ch = min(rng.uniform(0.42, 0.58), z1 - z)
            if z1 - (z + ch) < 0.3:
                ch = z1 - z
            for s in range(8):
                split = rng.random() < 0.2
                for du, w in ([(-side_w / 4, side_w / 2), (side_w / 4, side_w / 2)] if split else [(0.0, side_w)]):
                    chip = rng.uniform(0.08, 0.2) if rng.random() < 0.14 else 0.0
                    sink = rng.uniform(0.012, 0.035) if rng.random() < 0.15 else -rng.uniform(0.0, 0.012)
                    parts.append(_oct_stone(m, rng, a, s * math.pi / 4, z, ch, w, du, chip=chip, sink=sink))
            z += ch

    courses(plinth_top, band0, a1)
    parts.append(lathe("band", [(circ(a1 + 0.01), 0.0), (circ(a1 + 0.08), 0.06), (circ(a1 + 0.08), 0.16),
                                (circ(a2 + 0.01), band1 - band0)], loc=(0, 0, band0), sides=8, rot=oct_rot, mat=sm,
                       tint=random_tint(rng, 0.05), bevel=0.02))
    courses(band1, shaft_top, a2)
    # corbels stepping out to the cornice, then the cap and finial
    z = shaft_top
    for i, (out, ch) in enumerate(((0.06, 0.2), (0.13, 0.18), (0.21, 0.17))):
        o = lathe("corbel", [(circ(a2 + out), 0.0), (circ(a2 + out), ch)], loc=(0, 0, z), sides=8, rot=oct_rot,
                  mat=sm, tint=random_tint(rng, 0.07), bevel=0.025)
        kit.jitter_vertices(o, rng, 0.008)
        parts.append(o)
        z += ch
    cornice = lathe("cornice", [(circ(1.15 * k), 0.0), (circ(1.2 * k), 0.08), (circ(1.2 * k), 0.2)],
                    loc=(0, 0, z), sides=8, rot=oct_rot, mat=sm, tint=random_tint(rng, 0.05), bevel=0.03)
    kit.jitter_vertices(cornice, rng, 0.01)
    parts.append(cornice)
    z += 0.2
    finial_r = 0.15
    cap_h = height - z - 0.06 - 2 * finial_r
    parts.append(lathe("cap", [(circ(1.1 * k), 0.0), (circ(1.06 * k), 0.06), (0.22, cap_h - 0.02), (0.0, cap_h)],
                       loc=(0, 0, z), sides=8, rot=oct_rot, mat=sm, tint=random_tint(rng, 0.06), bevel=0.02))
    z += cap_h - 0.04
    parts.append(cylinder("neck", 0.07, 0.12, (0, 0, z + 0.06), sides=8, mat=sm))
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=finial_r, location=(0, 0, height - finial_r))
    ball = bpy.context.active_object
    kit.clear_uvs(ball)
    ball.data.materials.append(sm)
    kit.set_tint(ball, random_tint(rng, 0.05))
    parts.append(ball)

    # shackles on the +x face: two plates with rings, chains and open cuffs (face frame: front -y)
    shack = []
    top = 2.2
    for sx in (-1, 1):
        x = sx * 0.2
        shack.append(block("plate", (0.17, 0.05, 0.24), (x, -0.025, top), bevel=0.01, mat=m["iron"]))
        for dz in (-0.08, 0.08):
            shack.append(cylinder("bolt", 0.025, 0.03, (x, -0.06, top + dz), rot=(math.pi / 2, 0, 0), sides=6,
                                  mat=m["iron"]))
        shack.append(dressing.torus("ring", 0.07, 0.018, (x, -0.08, top - 0.1), rot=(math.pi / 2, 0, math.pi / 2),
                                    mat=m["iron"], seg=(10, 5)))
        drop = rng.uniform(0.38, 0.55)
        dressing._chain(shack, m, (x, -0.08, top - 0.16), (x + sx * 0.03, -0.09, top - 0.16 - drop), 0.0,
                        link=0.1, thick=0.016)
        shack.append(dressing.torus("cuff", 0.065, 0.02, (x + sx * 0.03, -0.1, top - 0.24 - drop),
                                    rot=(0.4, 0, 0), mat=m["iron"], seg=(10, 5)))
    parts += _group(shack, (a1, 0, 0), math.pi / 2)
    # a notice board on the -x face: a board, two sheets and their nails
    board = [block("board", (0.6, 0.05, 0.74), (0, -0.025, 1.72), bevel=0.012, mat=m["dark_wood"],
                   tint=random_tint(rng, 0.08))]
    for (x, z, w, h, tilt) in ((-0.12, 1.78, 0.26, 0.38, 0.04), (0.15, 1.62, 0.2, 0.26, -0.07)):
        board.append(block("sheet", (w, 0.012, h), (x, -0.056, z), rot=(0, tilt, 0), bevel=0.0, mat=m["emblem"],
                           tint=random_tint(rng, 0.06, 0.06)))
        board.append(cylinder("nail", 0.014, 0.03, (x, -0.07, z + h / 2 - 0.04), rot=(math.pi / 2, 0, 0), sides=6,
                              mat=m["iron"]))
    parts += _group(board, (-a1, 0, 0), -math.pi / 2)
    # chips knocked off the shaft, lying at its foot
    for _ in range(3):
        ang = rng.uniform(0, math.tau)
        d = rng.uniform(1.3, 1.42) * k
        s = (rng.uniform(0.14, 0.24), rng.uniform(0.1, 0.18), rng.uniform(0.07, 0.12))
        o = block("chip", s, (math.cos(ang) * d, math.sin(ang) * d, s[2] * 0.4), bevel=0.02, mat=sm,
                  rot=(rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), rng.uniform(0, math.pi)),
                  tint=random_tint(rng, 0.1))
        kit.jitter_vertices(o, rng, 0.015)
        parts.append(o)
    return parts


def gate(p: dict, m: dict, rng) -> list:
    """Iron portcullis, 8 m wide and 5 m tall, with spiked bottom bars. Faces -Y."""
    width, height = p.get("width_m", 8.0), p.get("height_m", 5.0)
    parts = []
    n = int(width / 0.55)
    step = width / n
    for i in range(n + 1):
        x = -width / 2 + i * step
        bar = cylinder("bar", 0.065, height - 0.3, (x, 0, 0.3 + (height - 0.3) / 2), sides=6, mat=m["iron"],
                       tint=random_tint(rng, 0.08))
        spike = cylinder("spike", 0.08, 0.3, (x, 0, 0.15), sides=6, radius_top=0.0,
                         rot=(math.pi, 0, 0), mat=m["iron"])
        parts += [bar, spike]
    zs = [0.6, 1.7, 2.8, 3.9, height - 0.15]
    for z in zs:
        parts.append(block("band", (width + 0.1, 0.12, 0.16), (0, 0, z), bevel=0.015, mat=m["iron"],
                           tint=random_tint(rng, 0.06)))
        for i in range(0, n + 1, 2):  # rivets where bars cross the bands
            x = -width / 2 + i * step
            parts.append(cylinder("rivet", 0.04, 0.05, (x, -0.08, z), rot=(math.pi / 2, 0, 0), sides=6,
                                  mat=m["iron"]))
    return parts


def gate_lintel(p: dict, m: dict, rng) -> list:
    """Stone lintel over a gate opening: voussoir-like blocks with a keystone. Back on y = 0."""
    width = p.get("width_m", 9.0)
    parts = []
    n = 7
    w = width / n
    for i in range(n):
        x = -width / 2 + w * (i + 0.5)
        key = i == n // 2
        h = 1.25 if key else 1.05
        s = block("voussoir", (w - 0.04, 1.0, h), (x, -0.5, 0.525 + (h - 1.05) / 2 + (0.1 if key else 0)),
                  bevel=0.04, segments=2, mat=m["stone"], tint=random_tint(rng, 0.1))
        kit.jitter_vertices(s, rng, 0.012)
        parts.append(s)
    return parts


def _stage_side(m, rng, h: float, z0: float, z1: float, missing: bool) -> list:
    """One side of the gallows' timber stage, facing -y with its post faces on y = -h: a sill on
    the stone, a plate under the deck, a middle post, boards set back between the posts, a cross
    brace in each bay with an iron strap where the braces cross, and joist ends under the deck.
    `missing` leaves one board out (a dark gap)."""
    parts = []
    sill_h, plate_h = 0.26, 0.3
    parts.append(block("sill", (2 * h - 0.4, 0.26, sill_h), (0, -h + 0.18, z0 + sill_h / 2), bevel=0.02,
                       mat=m["timber"], tint=random_tint(rng, 0.08)))
    parts.append(block("plate", (2 * h - 0.4, 0.28, plate_h), (0, -h + 0.24, z1 - plate_h / 2), bevel=0.02,
                       mat=m["timber"], tint=random_tint(rng, 0.08)))
    b0, b1 = z0 + sill_h, z1 - plate_h
    parts.append(block("post", (0.3, 0.3, b1 - b0), (0, -h + 0.17, (b0 + b1) / 2), bevel=0.02, mat=m["timber"],
                       tint=random_tint(rng, 0.08)))
    # boards, set back from the post faces
    x = -h + 0.36
    gap_at = rng.uniform(-h + 0.6, h - 0.6) if missing else None
    while x < h - 0.37:
        w = min(rng.uniform(0.24, 0.34), h - 0.36 - x)
        if not (gap_at is not None and x <= gap_at < x + w):
            bot = b0 + (rng.uniform(0.02, 0.1) if rng.random() < 0.25 else 0.0)  # a rotted foot now and then
            parts.append(block("board", (w - 0.025, 0.06, b1 - bot), (x + w / 2, -h + 0.27, (bot + b1) / 2),
                               bevel=0.01, mat=m["boards"], tint=random_tint(rng, 0.16, 0.05),
                               rot=(0, rng.uniform(-0.006, 0.006), 0)))
        x += w
    # a cross brace in each bay, with an iron strap and bolts at the crossing
    for sx in (-1, 1):
        u0, u1 = sx * 0.15, sx * (h - 0.38)
        lo, hi = b0 + 0.02, b1 - 0.02
        for (p0, p1) in (((u0, lo), (u1, hi)), ((u0, hi), (u1, lo))):
            parts.append(_beam("brace", (p0[0], -h + 0.14, p0[1]), (p1[0], -h + 0.14, p1[1]), 0.16, 0.1, (0, 1, 0),
                               m["timber"], random_tint(rng, 0.08)))
        cx, cz = (u0 + u1) / 2, (lo + hi) / 2
        parts.append(block("strap", (0.22, 0.03, 0.22), (cx, -h + 0.08, cz), rot=(0, math.pi / 4, 0), bevel=0.008,
                           mat=m["iron"]))
        parts.append(cylinder("bolt", 0.035, 0.04, (cx, -h + 0.06, cz), rot=(math.pi / 2, 0, 0), sides=6,
                              mat=m["iron"]))
    # joist ends showing between the plate and the deck
    for u in (-1.4, -0.47, 0.47, 1.4):
        parts.append(block("joist", (0.14, 0.2, 0.12), (u, -h + 0.12, z1 - 0.06), bevel=0.01, mat=m["timber"]))
    return parts


def _noose(m, rng, x: float, y: float, z_top: float, drop: float) -> list:
    """A rope from the beam to a wound coil and an open loop below it."""
    parts = [cylinder("rope", 0.026, drop, (x, y, z_top - drop / 2), sides=6, mat=m["rope"])]
    for i in range(4):
        parts.append(dressing.torus("coil", 0.04, 0.02, (x, y, z_top - drop - 0.02 - i * 0.034), mat=m["rope"],
                                    seg=(8, 4)))
    parts.append(dressing.torus("loop", 0.16, 0.026, (x, y, z_top - drop - 0.33), rot=(math.pi / 2, 0, math.pi / 2),
                                mat=m["rope"], seg=(12, 5), scale=(1, 1.25, 1)))
    return parts


def _cage(m, x: float, y: float, z0: float, r: float = 0.27, h: float = 1.15) -> list:
    """A hanging iron cage: a floor plate, top and bottom rings, eight bars, a domed lid and a
    hanging ring."""
    parts = [cylinder("cage_floor", r, 0.04, (x, y, z0 + 0.02), sides=12, mat=m["iron"])]
    for z in (z0 + 0.04, z0 + h * 0.5, z0 + h):
        parts.append(dressing.torus("cage_ring", r, 0.022, (x, y, z), mat=m["iron"], seg=(16, 4)))
    for i in range(8):
        a = i * math.tau / 8
        parts.append(cylinder("bar", 0.016, h, (x + math.cos(a) * r, y + math.sin(a) * r, z0 + h / 2), sides=5,
                              mat=m["iron"]))
    parts.append(lathe("lid", [(r + 0.02, 0.0), (r * 0.7, 0.12), (0.05, 0.2), (0.0, 0.21)], loc=(x, y, z0 + h),
                       sides=12, mat=m["iron"]))
    parts.append(dressing.torus("hang", 0.06, 0.016, (x, y, z0 + h + 0.27), rot=(math.pi / 2, 0, 0), mat=m["iron"],
                                seg=(10, 4)))
    return parts


def gallows(p: dict, m: dict, rng) -> tuple[list, list]:
    """The central block (size_m square, deck at deck_m): a stone plinth with quoins and a
    chamfered cap, a timber stage above it (posts, cross-braced bays, boards set back, one
    missing), a plank deck with a trapdoor and a rail, a ladder up the +y side, and a gallows
    frame along y (seen side-on from both gates): two uprights with raking struts and knee
    braces, a crossbeam strapped with iron, three nooses over the trapdoor, an iron cage hung
    from the -y end of the beam and a lantern from the +y end (its glass is the glow part)."""
    size, deck_z = p.get("size_m", 5.0), p.get("deck_m", 3.2)
    h = size / 2
    parts = [block("core", (size - 1.0, size - 1.0, deck_z - 0.1), (0, 0, (deck_z - 0.1) / 2), bevel=0,
                   mat=m["void"])]
    # stone plinth: coursed faces between corner quoins, then a chamfered cap course
    base_top = 1.15
    for axis, plane, out in (("x", -h, -1), ("x", h, 1), ("y", -h, -1), ("y", h, 1)):
        dressing.ashlar(parts, m, rng, axis, plane, out, -h + 0.9, h - 0.9, 0.0, base_top, depth=0.4,
                        course=(0.5, 0.65), width=(0.7, 1.25), mat_key="stone_worn")
    for sx in (-1, 1):
        for sy in (-1, 1):
            z = 0.0
            for i, ch in enumerate((0.6, base_top - 0.6)):
                wx, wy = (0.9, 0.78) if i % 2 == 0 else (0.78, 0.9)
                q = block("quoin", (wx - GAP, wy - GAP, ch - GAP), (sx * (h - wx / 2 + 0.015), sy * (h - wy / 2 + 0.015),
                          z + ch / 2), bevel=0.035, mat=m["stone_worn"], tint=random_tint(rng, 0.1))
                kit.jitter_vertices(q, rng, 0.012)
                parts.append(q)
                z += ch
    cap_h = 0.16
    for side in range(4):
        cap = []
        x = -h - 0.04
        while x < h + 0.03:
            w = min(rng.uniform(0.9, 1.5), h + 0.04 - x)
            if h + 0.04 - (x + w) < 0.4:
                w = h + 0.04 - x
            s = block("cap", (w - GAP, 0.5, cap_h), (x + w / 2, -h + 0.21, base_top + cap_h / 2), bevel=0.045,
                      mat=m["stone_worn"], tint=random_tint(rng, 0.08))
            kit.jitter_vertices(s, rng, 0.01)
            cap.append(s)
            x += w
        parts += _group(cap, yaw=side * math.pi / 2)
    z0 = base_top + cap_h
    # timber stage: four sides, corner posts that rise above the deck as rail newels
    missing_side = rng.randrange(4)
    for side in range(4):
        parts += _group(_stage_side(m, rng, h, z0, deck_z, side == missing_side), yaw=side * math.pi / 2)
    rail_top = deck_z + 1.05
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(block("corner_post", (0.36, 0.36, rail_top + 0.1 - z0), (sx * (h - 0.19), sy * (h - 0.19),
                               (z0 + rail_top + 0.1) / 2), bevel=0.025, mat=m["timber"], tint=random_tint(rng, 0.08)))
            parts.append(block("post_cap", (0.42, 0.42, 0.08), (sx * (h - 0.19), sy * (h - 0.19), rail_top + 0.14),
                               bevel=0.02, mat=m["timber"]))
            for z in (z0 + 0.45, deck_z - 0.5):  # iron corner straps
                parts.append(block("band", (0.4, 0.4, 0.07), (sx * (h - 0.19), sy * (h - 0.19), z), bevel=0.01,
                                   mat=m["iron"]))
    # deck planks along x; a trapdoor under the nooses
    xf = 0.35  # the frame's line
    y = -h + 0.02
    while y < h - 0.03:
        w = min(rng.uniform(0.24, 0.32), h - 0.02 - y)
        parts.append(block("plank", (size - 0.06, w - 0.02, 0.08), (rng.uniform(-0.02, 0.02), y + w / 2, deck_z + 0.04),
                           bevel=0.012, mat=m["boards"], tint=random_tint(rng, 0.14, 0.05)))
        y += w
    trap_x, trap_y = (xf - 0.55, xf + 0.55), (-1.45, 1.45)
    for sx in (-1, 1):  # a dark joint around the trap
        parts.append(block("trap_joint", (1.16, 0.04, 0.012), (xf, sx * 1.47, deck_z + 0.084), bevel=0, mat=m["void"]))
        parts.append(block("trap_joint", (0.04, 2.98, 0.012), (xf + sx * 0.57, 0, deck_z + 0.084), bevel=0,
                           mat=m["void"]))
    for i, (a, b) in enumerate(((trap_x[0], xf), (xf, trap_x[1]))):
        parts.append(block("trap_leaf", (b - a - 0.03, trap_y[1] - trap_y[0], 0.05), ((a + b) / 2, 0, deck_z + 0.105),
                           bevel=0.01, mat=m["timber"], tint=random_tint(rng, 0.06)))
        hinge_x = a + 0.12 if i == 0 else b - 0.12
        for yy in (-1.0, 0.0, 1.0):
            parts.append(block("hinge", (0.3, 0.07, 0.015), (hinge_x + (0.06 if i == 0 else -0.06), yy, deck_z + 0.137),
                               bevel=0.004, mat=m["iron"]))
    # rail on all four sides (a gap where the ladder arrives on +y)
    for side in range(4):
        rail = []
        lo = -h + 0.37
        hi = h - 0.37
        # side 2 faces +y after the turn (local u = -x there): a gap over the ladder at x -1.25..-0.45
        segs = [(lo, 0.45), (1.25, hi)] if side == 2 else [(lo, hi)]
        for a, b in segs:
            for z, hh in ((rail_top - 0.06, 0.12), (deck_z + 0.55, 0.09)):
                rail.append(block("rail", (b - a, 0.1, hh), ((a + b) / 2, -h + 0.19, z), bevel=0.012, mat=m["timber"],
                                  tint=random_tint(rng, 0.08)))
        for u in ((0.45, 1.25) if side == 2 else (0.0,)):
            rail.append(block("baluster", (0.16, 0.16, rail_top - deck_z), (u, -h + 0.19, (deck_z + rail_top) / 2),
                              bevel=0.015, mat=m["timber"]))
        parts += _group(rail, yaw=side * math.pi / 2)
    # ladder up the +y side, nearly upright against the stage
    for lx in (-1.2, -0.5):
        parts.append(_beam("ladder_rail", (lx, h + 0.16, 0.0), (lx, h + 0.04, rail_top - 0.1), 0.09, 0.07, (0, 1, 0),
                           m["timber"], random_tint(rng, 0.08)))
    z = 0.35
    while z < rail_top - 0.3:
        yy = h + 0.16 - 0.12 * z / (rail_top - 0.1)
        parts.append(cylinder("rung", 0.03, 0.72, (-0.85, yy, z), rot=(0, math.pi / 2, 0), sides=6, mat=m["timber"]))
        z += 0.32
    # the gallows frame, along y on the line x = xf
    top = deck_z + 3.4
    uy = 1.75
    for sy in (-1, 1):
        parts.append(block("upright", (0.32, 0.32, top - deck_z), (xf, sy * uy, (deck_z + top) / 2), bevel=0.02,
                           mat=m["timber"], tint=random_tint(rng, 0.08)))
        for sx in (-1, 1):  # raking struts to the deck
            parts.append(_beam("strut", (xf + sx * 0.95, sy * uy, deck_z + 0.1), (xf + sx * 0.12, sy * uy, deck_z + 1.2),
                               0.16, 0.14, (0, 1, 0), m["timber"], random_tint(rng, 0.08)))
        parts.append(_beam("knee", (xf, sy * (uy - 0.12), top - 0.85), (xf, sy * (uy - 0.75), top - 0.12), 0.16, 0.14,
                           (1, 0, 0), m["timber"], random_tint(rng, 0.08)))
        for z in (top - 0.3, deck_z + 0.35):  # iron straps on the joints
            parts.append(block("strap", (0.36, 0.36, 0.08), (xf, sy * uy, z), bevel=0.01, mat=m["iron"]))
    beam_z = top + 0.17
    parts.append(block("beam", (0.34, 4.85, 0.34), (xf, 0, beam_z), bevel=0.025, mat=m["timber"],
                       tint=random_tint(rng, 0.06)))
    for sy in (-1, 1):
        parts.append(block("beam_strap", (0.38, 0.08, 0.38), (xf, sy * (uy + 0.25), beam_z), bevel=0.01, mat=m["iron"]))
        parts.append(block("beam_end", (0.3, 0.06, 0.3), (xf, sy * 2.42, beam_z), bevel=0.02, mat=m["timber"],
                           taper=0.1))
    for yy in (-0.78, 0.0, 0.78):
        parts += _noose(m, rng, xf, yy, top, rng.uniform(0.95, 1.25))
    # the release lever beside the trap
    parts.append(block("lever_post", (0.18, 0.18, 1.0), (xf + 0.95, -1.9, deck_z + 0.5), bevel=0.015, mat=m["timber"]))
    parts.append(_beam("lever", (xf + 0.95, -1.9, deck_z + 0.85), (xf + 0.75, -1.55, deck_z + 1.45), 0.06, 0.06,
                       (1, 0, 0), m["iron"]))
    # cage from the -y end, lantern from the +y end
    cage_y = -2.22
    parts += _cage(m, xf, cage_y, deck_z + 1.3)
    hang_z = deck_z + 1.3 + 1.15 + 0.33
    dressing._chain(parts, m, (xf, cage_y, beam_z - 0.17), (xf, cage_y, hang_z), 0.0, link=0.1, thick=0.017)
    lx, ly, lz = xf, 2.22, top - 0.95
    dressing._chain(parts, m, (lx, ly, beam_z - 0.17), (lx, ly, lz + 0.42), 0.0, link=0.08, thick=0.012)
    parts.append(block("lantern_base", (0.24, 0.24, 0.05), (lx, ly, lz), bevel=0.008, mat=m["iron"]))
    parts.append(dressing.prism("lantern_roof", 0.28, 0.28, 0.14, (lx, ly, lz + 0.3), mat=m["iron"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(cylinder("lantern_rod", 0.012, 0.28, (lx + sx * 0.11, ly + sy * 0.11, lz + 0.16), sides=4,
                                  mat=m["iron"]))
    glass = [block("lantern_glass", (0.18, 0.18, 0.24), (lx, ly, lz + 0.16), bevel=0.0,
                   mat=dressing.glow("lantern_glow", p.get("lamp_color", "#ffb35c"), 5.0))]
    return parts, glass


def brazier(p: dict, m: dict, rng) -> tuple[list, list]:
    """Iron tripod brazier with glowing coals (the coals are a separate emissive part)."""
    parts = []
    for i in range(3):
        a = i * math.tau / 3
        parts.append(kit.strut("leg", (math.cos(a) * 0.42, math.sin(a) * 0.42, 0.04),
                               (math.cos(a) * 0.2, math.sin(a) * 0.2, 1.0), 0.04, sides=6, mat=m["iron"]))
        foot = block("foot", (0.16, 0.16, 0.05), (math.cos(a) * 0.42, math.sin(a) * 0.42, 0.025), bevel=0.01,
                     mat=m["iron"])
        parts.append(foot)
    parts.append(cylinder("bowl", 0.26, 0.34, (0, 0, 1.05), sides=12, radius_top=0.5, bevel=0.02, mat=m["iron"]))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.5, minor_radius=0.04, major_segments=16, minor_segments=6,
                                     location=(0, 0, 1.22))
    rim = bpy.context.active_object
    kit.clear_uvs(rim)
    rim.data.materials.append(m["iron"])
    kit.set_tint(rim, (1, 1, 1))
    parts.append(rim)
    coal_mat = glow_material("coals", p.get("coal_color", "#ff6a1e"), 6.0)
    coals = []
    for i in range(9):
        a = rng.uniform(0, math.tau)
        rr = rng.uniform(0, 0.3)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=rng.uniform(0.07, 0.12),
                                              location=(math.cos(a) * rr, math.sin(a) * rr, 1.2 + rng.uniform(-0.02, 0.04)))
        c = bpy.context.active_object
        kit.clear_uvs(c)
        kit.jitter_vertices(c, rng, 0.02)
        c.data.materials.append(coal_mat)
        coals.append(c)
    return parts, coals


def banner(p: dict, m: dict, rng) -> list:
    """A team banner on an iron bracket, hanging 0.2 m in front of the wall. Back on y = 0."""
    width, length = p.get("width_m", 1.3), p.get("length_m", 3.0)
    top = p.get("top_m", 5.3)
    parts = [block("wallplate", (0.3, 0.05, 0.3), (0, -0.025, top + 0.1), bevel=0.01, mat=m["iron"]),
             cylinder("arm", 0.035, 0.32, (0, -0.2, top + 0.1), rot=(math.pi / 2, 0, 0), sides=6, mat=m["iron"]),
             cylinder("pole", 0.04, width + 0.3, (0, -0.35, top), rot=(0, math.pi / 2, 0), sides=8, mat=m["dark_wood"])]
    for sx in (-1, 1):
        parts.append(cylinder("finial", 0.06, 0.12, (sx * (width / 2 + 0.2), -0.35, top), rot=(0, math.pi / 2, 0),
                              sides=8, radius_top=0.0 if sx > 0 else 0.06, mat=m["iron"]))
    # cloth: a subdivided sheet with a swallowtail and a gentle wave, given thickness
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=10, y_subdivisions=24, size=1)
    cloth = bpy.context.active_object
    kit.clear_uvs(cloth)
    for v in cloth.data.vertices:
        u, t = v.co.x + 0.5, v.co.y + 0.5  # u across, t down the banner (0 top .. 1 bottom)
        t = 1 - t
        x = (u - 0.5) * width
        z = top - 0.05 - t * length
        notch = 0.45 * (1 - abs(u - 0.5) * 2)  # swallowtail: the middle of the hem rises
        if t > 0.8:
            z += notch * (t - 0.8) / 0.2
        y = -0.35 + 0.05 * math.sin(t * 5.0 + u * 1.3) * t
        v.co = (x, y, z)
    sol = cloth.modifiers.new("thick", "SOLIDIFY")
    sol.thickness = 0.025
    common.apply_all_modifiers(cloth)
    cloth.data.materials.append(m["cloth"])
    kit.set_tint(cloth, (1, 1, 1))
    parts.append(cloth)
    # emblem (original): a ring above a downward chevron, in bone white, stitched on the front
    cz = top - 0.2 - length * 0.38
    bpy.ops.mesh.primitive_torus_add(major_radius=width * 0.2, minor_radius=width * 0.035, major_segments=20,
                                     minor_segments=4, location=(0, -0.39, cz + 0.35), rotation=(math.pi / 2, 0, 0))
    ring = bpy.context.active_object
    ring.scale = (1, 1, 0.35)
    bpy.ops.object.transform_apply(scale=True)
    kit.clear_uvs(ring)
    ring.data.materials.append(m["emblem"])
    kit.set_tint(ring, (1, 1, 1))
    parts.append(ring)
    for sx in (-1, 1):
        parts.append(block("chevron", (width * 0.42, 0.02, 0.1), (sx * width * 0.13, -0.39, cz - 0.25),
                           rot=(0, sx * math.radians(38), 0), bevel=0.005, mat=m["emblem"]))
    return parts


PIECES = {"floor_tile": floor_tile, "wall": wall, "corner": corner, "pillar": pillar, "gate": gate,
          "gate_lintel": gate_lintel, "gallows": gallows, "brazier": brazier, "banner": banner, **dressing.PIECES}
BACK_ON_Y0 = {"wall", "gate_lintel", "banner"} | dressing.BACK_ON_Y0


def all_mats(pal: dict) -> dict:
    return {**mats(pal), **dressing.extra_mats(pal)}


def build(spec: dict, previews: Path | None) -> None:
    # the pillar and gallows keep the axis they were built around (asymmetric shackles, ladder, cage)
    kit.build_spec(spec, previews, PIECES, BACK_ON_Y0, all_mats, keep_xy={"pillar", "gallows"})


def main() -> int:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spec", type=Path)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--only", nargs="*", help="with --all: only these piece names")
    ap.add_argument("--previews", type=Path)
    args = ap.parse_args(argv)
    specs = sorted((common.REPO / "data" / "assets").glob("gallows_*.json")) if args.all else [args.spec]
    for path in specs:
        spec = json.loads(Path(path).read_text())
        if args.only and spec["params"]["piece"] not in args.only and spec["id"] not in args.only:
            continue
        build(spec, args.previews)
    return 0


if __name__ == "__main__":
    sys.exit(main())
