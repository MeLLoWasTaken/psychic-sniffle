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
from kit import block, cylinder, random_tint  # noqa: E402


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


def pillar(p: dict, m: dict, rng) -> list:
    """Round stone pillar (collision radius 1.2 m, 6 m tall): plinth, drums, capital, shackle."""
    r = p.get("radius_m", 1.2)
    height = p.get("height_m", 6.0)
    parts = [cylinder("plinth", r * 1.07, 0.5, (0, 0, 0.25), sides=8, radius_top=r * 1.0, bevel=0.04,
                      mat=m["stone"], tint=random_tint(rng, 0.06))]
    z = 0.5
    cap_h = 0.55
    while z < height - cap_h - 0.01:
        dh = min(rng.uniform(0.9, 1.3), height - cap_h - z)
        rad = r * rng.uniform(0.9, 0.95)
        d = cylinder("drum", rad, dh - 0.05, (0, 0, z + dh / 2), sides=16, bevel=0.04, mat=m["stone"],
                     tint=random_tint(rng, 0.1), rot=(0, 0, rng.uniform(0, math.pi)))
        kit.jitter_vertices(d, rng, 0.02)
        parts.append(d)
        z += dh
    parts.append(cylinder("capital", r * 0.95, cap_h * 0.45, (0, 0, height - cap_h * 0.775), sides=16,
                          radius_top=r * 1.12, mat=m["stone"], tint=random_tint(rng, 0.06)))
    parts.append(block("abacus", (r * 2.08, r * 2.08, cap_h * 0.55), (0, 0, height - cap_h * 0.275), bevel=0.05,
                       segments=2, mat=m["stone"], tint=random_tint(rng, 0.06)))
    # an iron shackle ring bolted to one side, at chest height
    ang = rng.uniform(0, math.tau)
    dx, dy = math.cos(ang), math.sin(ang)
    rr = r * 0.93
    parts.append(block("plate", (0.18, 0.06, 0.18), (dx * rr, dy * rr, 2.0), rot=(0, 0, ang + math.pi / 2),
                       bevel=0.01, mat=m["iron"]))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.13, minor_radius=0.025, major_segments=12, minor_segments=6,
                                     location=(dx * (rr + 0.05), dy * (rr + 0.05), 1.85),
                                     rotation=(0, math.pi / 2, ang))
    ring = bpy.context.active_object
    kit.clear_uvs(ring)
    ring.data.materials.append(m["iron"])
    kit.set_tint(ring, (1, 1, 1))
    parts.append(ring)
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


def gallows(p: dict, m: dict, rng) -> list:
    """The central block: a 5 x 5 m platform 3.2 m high on a stone base, board skirting, a deck,
    a low rail, and a gallows frame with three nooses."""
    size, deck_z = p.get("size_m", 5.0), p.get("deck_m", 3.2)
    half = size / 2
    parts = [block("core", (size - 0.3, size - 0.3, deck_z), (0, 0, deck_z / 2), bevel=0, mat=m["dark_wood"])]
    # stone base course
    for side in range(4):
        x = -half
        while x < half - 0.01:
            w = min(rng.uniform(0.8, 1.3), half - x)
            if half - (x + w) < 0.35:
                w = half - x
            loc = [(x + w / 2, -half + 0.2), (half - 0.2, x + w / 2), (-(x + w / 2), half - 0.2), (-half + 0.2, -(x + w / 2))][side]
            size_b = (w - 0.04, 0.45, 0.6) if side % 2 == 0 else (0.45, w - 0.04, 0.6)
            s = block("base", size_b, (loc[0], loc[1], 0.3), bevel=0.035, segments=2, mat=m["stone"],
                      tint=random_tint(rng, 0.12))
            kit.jitter_vertices(s, rng, 0.01)
            parts.append(s)
            x += w
    # vertical boards on each side
    for side in range(4):
        x = -half + 0.25
        while x < half - 0.26:
            w = rng.uniform(0.26, 0.34)
            w = min(w, half - 0.25 - x)
            h = deck_z - 0.6 - rng.uniform(0.0, 0.05)
            c = x + w / 2
            loc = [(c, -half + 0.08), (half - 0.08, c), (-c, half - 0.08), (-half + 0.08, -c)][side]
            sz = (w - 0.02, 0.07, h) if side % 2 == 0 else (0.07, w - 0.02, h)
            parts.append(block("board", sz, (loc[0], loc[1], 0.6 + h / 2), bevel=0.012, mat=m["wood"],
                               tint=random_tint(rng, 0.16, 0.05), rot=(0, 0, rng.uniform(-0.01, 0.01))))
            x += w
    # corner posts and rails
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(block("post", (0.32, 0.32, deck_z + 0.5), (sx * (half - 0.16), sy * (half - 0.16),
                               (deck_z + 0.5) / 2), bevel=0.02, mat=m["dark_wood"], tint=random_tint(rng, 0.08)))
    for z in (0.95, deck_z - 0.2):
        for side in range(4):
            loc = [(0, -half + 0.02), (half - 0.02, 0), (0, half - 0.02), (-half + 0.02, 0)][side]
            sz = (size - 0.3, 0.1, 0.2) if side % 2 == 0 else (0.1, size - 0.3, 0.2)
            parts.append(block("girt", sz, (loc[0], loc[1], z), bevel=0.015, mat=m["dark_wood"],
                               tint=random_tint(rng, 0.08)))
    # deck planks
    y = -half + 0.05
    while y < half - 0.06:
        w = min(rng.uniform(0.26, 0.34), half - 0.05 - y)
        parts.append(block("plank", (size - 0.1, w - 0.02, 0.08), (0, y + w / 2, deck_z + 0.04), bevel=0.012,
                           mat=m["wood"], tint=random_tint(rng, 0.14, 0.05)))
        y += w
    # low rail on three sides (the gallows frame side stays open)
    for side in (0, 2, 3):
        loc = [(0, -half + 0.16), None, (0, half - 0.16), (-half + 0.16, 0)][side]
        sz = (size - 0.3, 0.1, 0.1) if side % 2 == 0 else (0.1, size - 0.3, 0.1)
        parts.append(block("rail", sz, (loc[0], loc[1], deck_z + 0.45), bevel=0.01, mat=m["dark_wood"]))
    # gallows frame: two uprights, a crossbeam, braces
    top = deck_z + 3.6
    for sx in (-1, 1):
        parts.append(block("upright", (0.3, 0.3, top - deck_z), (sx * 1.6, 0.6, (deck_z + top) / 2), bevel=0.02,
                           mat=m["dark_wood"], tint=random_tint(rng, 0.08)))
        br = block("brace", (0.14, 0.14, 1.2), (sx * 1.2, 0.6, top - 0.55), rot=(0, sx * math.radians(45), 0),
                   bevel=0.01, mat=m["dark_wood"])
        parts.append(br)
    parts.append(block("beam", (4.0, 0.32, 0.32), (0, 0.6, top + 0.1), bevel=0.02, mat=m["dark_wood"],
                       tint=random_tint(rng, 0.06)))
    for x in (-0.9, 0.0, 0.9):
        drop = rng.uniform(1.0, 1.35)
        parts.append(cylinder("rope", 0.028, drop, (x, 0.6, top - 0.06 - drop / 2), sides=6, mat=m["rope"]))
        bpy.ops.mesh.primitive_torus_add(major_radius=0.17, minor_radius=0.03, major_segments=12, minor_segments=6,
                                         location=(x, 0.6, top - 0.06 - drop - 0.15), rotation=(math.pi / 2, 0, 0))
        loop = bpy.context.active_object
        kit.clear_uvs(loop)
        loop.data.materials.append(m["rope"])
        kit.set_tint(loop, (1, 1, 1))
        parts.append(loop)
    return parts


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
    kit.build_spec(spec, previews, PIECES, BACK_ON_Y0, all_mats)


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
