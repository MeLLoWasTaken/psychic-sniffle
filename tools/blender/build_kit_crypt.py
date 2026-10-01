"""Flooded Crypt environment kit (backlog M2-09): a sunken, roofless crypt at night. Damp grey-green
stone with moss and wet stains, burial niches (loculi) in the walls, grave-slab paving, clustered
columns with broken vault springers, great tombs, an iron grille gate, and dressing (columbarium
wall, worn paving, stone fire bowl, bone pile, broken grave slabs, a mausoleum gatehouse and ruined
skyline). Funerary motifs are original and secular: rings, discs, hourglasses, blank tablets.
One piece per asset spec (data/assets/crypt_<piece>.json, params.piece).

Usage:
  python3 tools/blender/build_kit_crypt.py --spec data/assets/crypt_pillar.json --previews previews/kit
  python3 tools/blender/build_kit_crypt.py --all --previews previews/kit      # every crypt_* spec

Sizes and pivots match the gallows kit (build_kit_gallows.py), so the map builder places both the
same way (Blender axes; the glTF exporter turns -Y into Godot's +Z):
  floor_tile (4 x 4 m), pillar (radius_m, 6 m), corner, gate (8 x 5 m), tomb (6.4 x 2.8 m footprint,
  3.2 m tall, long side along x), brazier, bone_pile, gatehouse, skyline_*: centred, lowest point
  at z = 0.
  wall (4 x 6 m), gate_lintel (9 m), grave_slabs: the front faces -Y and the mounting face lies on
  y = 0 (the piece reaches back into +Y); centred on x, lowest point at z = 0.
Contact sheets are lit with the arena's preset (data/lighting/moonlit_crypt.json).
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
from mathutils import Euler, Matrix  # noqa: E402

import common  # noqa: E402
import kit  # noqa: E402
from build_kit_gallows_dressing import apply_xf, ashlar, glow, lathe, prism, torus, _from_bmesh, _finish  # noqa: E402
from kit import block, cylinder, random_tint  # noqa: E402

PRESET = "moonlit_crypt"
GAP = 0.05  # joints are wider and darker than in the gallows courtyard: old, settled masonry


def cool_tint(rng, spread: float = 0.13) -> tuple[float, float, float]:
    """Per-stone variation leaning cool and green rather than warm."""
    v = 1.0 + rng.uniform(-spread, spread)
    g = rng.uniform(-0.03, 0.07)  # mostly green-grey, now and then a browner stone
    return (v * (1 - g), v * (1 + g * 0.6), v * (1 - g * 0.6))


def mats(pal: dict) -> dict:
    km = kit.kit_material
    moss = pal.get("moss", "#64782e")
    rust = pal.get("rust", "#5b3b26")
    return {
        # walls, columns and piers: rising damp (the flood line), moss on ledges and in joints, streaks
        "stone": km("stone", pal.get("stone", "#686a62"), roughness=0.92, edge=0.34, cavity=0.65, top_light=0.14,
                    mottle=0.14, mottle_scale=0.5, moss=0.6, moss_color=moss, damp=0.75, damp_m=1.7, streaks=0.55),
        # the same stone for pieces standing on the wall top (no rising damp there)
        "stone_dry": km("stone_dry", pal.get("stone", "#686a62"), roughness=0.92, edge=0.34, cavity=0.65,
                        top_light=0.14, mottle=0.14, mottle_scale=0.5, moss=0.28, moss_color=pal.get("moss_dark", "#2c3a22"),
                        streaks=0.55),
        "flag": km("flag", pal.get("flag", "#5f625b"), roughness=0.9, edge=0.3, cavity=0.6, top_light=0.05,
                   mottle=0.16, mottle_scale=0.6, moss=0.35, moss_color=moss, moss_scale=1.0),
        # pale limestone for ledger slabs and the tombs, so the focal pieces read against the walls
        "ledger": km("ledger", pal.get("ledger", "#7a7a71"), roughness=0.88, edge=0.36, cavity=0.65, top_light=0.08,
                     mottle=0.12, mottle_scale=0.7, moss=0.4, moss_color=moss, damp=0.55, damp_m=1.1, streaks=0.4),
        "mortar": km("mortar", pal.get("mortar", "#1c221d"), roughness=0.97, edge=0.0, cavity=0.3, moss=0.5,
                     moss_color=pal.get("moss_dark", "#2c3a22"), moss_scale=2.0),
        "iron": km("iron", pal.get("iron", "#373b3b"), roughness=0.62, metallic=0.3, edge=0.5, cavity=0.5,
                   top_light=0.1, moss=0.45, moss_color=rust, moss_scale=3.0),
        "bone": km("bone", pal.get("bone", "#b0a68c"), roughness=0.85, edge=0.22, cavity=0.6, top_light=0.12,
                   mottle=0.1, mottle_scale=3.0),
        "void": km("void", pal.get("void", "#0b0d0c"), roughness=0.95, edge=0.0, cavity=0.0, top_light=0.0,
                   mottle=0.0),
        "dirt": km("dirt", pal.get("dirt", "#38372d"), roughness=0.97, edge=0.05, cavity=0.45, mottle=0.18,
                   mottle_scale=1.2, moss=0.4, moss_color=moss),
        "wood": km("wood", pal.get("wood", "#5f4a33"), roughness=0.88, edge=0.25, cavity=0.55),
        "far_stone": km("far_stone", pal.get("far_stone", "#4b4f4a"), roughness=0.92, edge=0.22, cavity=0.5,
                        mottle=0.12, mottle_scale=0.15, moss=0.3, moss_color=pal.get("moss_dark", "#2c3a22"),
                        moss_scale=0.4),
    }


# ----------------------------------------------------------------------------- small shapes

def group_xf(objs, loc=(0, 0, 0), rot=(0, 0, 0)) -> list:
    """Bake each object's own placement, then move the group as one: rotate about the origin by
    `rot`, then translate by `loc`."""
    apply_xf(objs)
    mx = Matrix.Translation(loc) @ Euler(rot).to_matrix().to_4x4()
    for o in objs:
        o.data.transform(mx)
    return objs


def ico(name: str, r: float, loc, mat, subdiv: int = 1, scale=(1, 1, 1), tint=(1, 1, 1)):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdiv, radius=r, location=(0, 0, 0))
    o = bpy.context.active_object
    kit.clear_uvs(o)
    o.scale = scale
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, tint)


def skull(m, loc, yaw: float = 0.0, s: float = 1.0, tilt: float = 0.0) -> list:
    """A small skull facing -Y: cranium, jaw and two dark sockets (dressing, about 20 cm)."""
    parts = [ico("cranium", 0.1 * s, (0, 0, 0.09 * s), m["bone"], subdiv=2, scale=(0.82, 1.0, 0.88)),
             block("jaw", (0.1 * s, 0.08 * s, 0.05 * s), (0, -0.045 * s, 0.025 * s), bevel=0.01, mat=m["bone"])]
    for sx in (-1, 1):
        parts.append(ico("socket", 0.026 * s, (sx * 0.034 * s, -0.083 * s, 0.09 * s), m["void"], subdiv=1))
    parts.append(ico("nose", 0.014 * s, (0, -0.094 * s, 0.062 * s), m["void"], subdiv=1))
    return group_xf(parts, loc, (tilt, 0, yaw))


def long_bone(m, p0, p1, r: float = 0.022) -> list:
    """A long bone: a shaft with a knob at each end."""
    parts = [kit.strut("bone", p0, p1, r, sides=6, mat=m["bone"])]
    for p in (p0, p1):
        parts.append(ico("knob", r * 1.9, p, m["bone"], subdiv=1, scale=(1.0, 1.0, 0.8)))
    return parts


def hip(name: str, length: float, width: float, height: float, ridge: float, loc, mat=None, tint=(1, 1, 1),
        bevel: float = 0.0):
    """A hipped cover: a rectangle (length along x) rising to a ridge of length `ridge`."""
    bm = bmesh.new()
    hl, hw, hr = length / 2, width / 2, ridge / 2
    v = [bm.verts.new(p) for p in ((-hl, -hw, 0), (hl, -hw, 0), (hl, hw, 0), (-hl, hw, 0),
                                   (-hr, 0, height), (hr, 0, height))]
    for f in ((3, 2, 1, 0), (0, 1, 5, 4), (2, 3, 4, 5), (1, 2, 5), (3, 0, 4)):
        bm.faces.new([v[i] for i in f])
    o = _from_bmesh(bm, name)
    o.location = loc
    apply_xf([o])
    return _finish(o, name, mat, tint, bevel)


def disc_y(name: str, r: float, depth: float, loc, mat, sides: int = 16, sign: int = -1):
    """A disc facing -Y (sign -1) or +Y, its back at loc."""
    return cylinder(name, r, depth, (loc[0], loc[1] + sign * depth / 2, loc[2]), rot=(math.pi / 2, 0, 0),
                    sides=sides, bevel=0.01, mat=mat)


def ring_y(name: str, r: float, thick: float, loc, mat, sign: int = -1, seg=(16, 5)):
    """A carved ring (wreath) standing proud of a face that looks along sign * Y."""
    return torus(name, r, thick, (loc[0], loc[1] + sign * thick * 0.3, loc[2]), rot=(math.pi / 2, 0, 0),
                 mat=mat, seg=seg, scale=(1, 1, 0.55))


def hourglass_y(m, mat, loc, h: float = 0.6, sign: int = -1) -> list:
    """An hourglass in relief (two cones tip to tip between a top and bottom bar) on a face."""
    x, y, z = loc
    d = 0.07
    yy = y + sign * d / 2
    parts = []
    for s in (-1, 1):
        # a flattened cone, wide at the bar and narrow at the waist (the upper one turned over)
        c = cylinder("glass", h * 0.22, h * 0.42, (0, 0, 0), sides=8, radius_top=0.03, mat=mat)
        c.scale = (1, 0.35, 1)
        c.rotation_euler = (math.pi if s > 0 else 0.0, 0, 0)
        # the lower cone's narrow end pokes into the upper one: coincident waist caps would weld
        # into non-manifold edges
        c.location = (x, yy, z + s * h * 0.21 + (0.012 if s < 0 else 0.0))
        apply_xf([c])
        parts.append(c)
        parts.append(block("bar", (h * 0.6, d, h * 0.08), (x, yy, z + s * (h * 0.46)), bevel=0.01, mat=mat))
    return parts


# ----------------------------------------------------------------------------- floor

def floor_tile(p: dict, m: dict, rng) -> list:
    """4 x 4 m of grave-slab paving in four 1 m courses (running bond) over a mossy bed. The long
    slabs are ledger stones with an incised border, a few with a carved ring. With params.worn:
    cracked and sunken slabs and a broken corner showing the earth below."""
    size = p.get("size_m", 4.0)
    worn = bool(p.get("worn", False))
    thick = 0.14
    half = size / 2
    parts = [block("bed", (size, size, 0.1), (0, 0, 0.05), bevel=0, mat=m["mortar"])]
    rows = 4
    rh = size / rows
    ledgers = 0
    for r in range(rows):
        y0 = -half + r * rh
        x = -half - (0.5 if r % 2 else 0.0) - rng.uniform(0.0, 0.3)
        while x < half - 0.01:
            w = rng.choice((0.9, 1.0, 1.1, 1.3, 2.0, 2.0))
            a, b = max(x, -half), min(x + w, half)
            if half - b < 0.45:
                b = half
            if b - a > 0.3:
                top = 0.1 + thick + rng.uniform(-0.014, 0.01)
                rot = (rng.uniform(-0.012, 0.012), rng.uniform(-0.012, 0.012), rng.uniform(-0.01, 0.01))
                cx, cy, sx, sy = (a + b) / 2, y0 + rh / 2, b - a - GAP, rh - GAP
                kind = "plain"
                if b - a > 1.7 and ledgers < 3:
                    kind = "ledger"
                    ledgers += 1
                elif worn and rng.random() < 0.35:
                    kind = rng.choice(("cracked", "sunken", "broken"))
                parts += _paving_slab(m, rng, kind, cx, cy, sx, sy, top, thick, rot)
            x = x + w if b < half else half
    return parts


def _paving_slab(m, rng, kind: str, cx, cy, sx, sy, top, thick, rot) -> list:
    out = []
    if kind == "ledger":
        # a raised rim around a panel, with a groove between them (the incised border)
        rim = 0.11
        g = 0.03
        mat = m["ledger"]
        t = cool_tint(rng, 0.08)
        for side in (-1, 1):
            out.append(block("rim", (sx, rim, thick), (cx, cy + side * (sy - rim) / 2, top - thick / 2), bevel=0.025,
                             mat=mat, tint=t, rot=rot))
            out.append(block("rim", (rim, sy - 2 * rim - 2 * g, thick), (cx + side * (sx - rim) / 2, cy,
                             top - thick / 2), bevel=0.02, mat=mat, tint=t, rot=rot))
        panel = block("panel", (sx - 2 * rim - 2 * g, sy - 2 * rim - 2 * g, thick - 0.015),
                      (cx, cy, top - 0.015 - (thick - 0.015) / 2), bevel=0.02, mat=mat, tint=t, rot=rot)
        out.append(panel)
        if rng.random() < 0.7:
            out.append(torus("ring", min(sx, sy) * 0.2, 0.028, (cx, cy, top - 0.012), mat=mat, seg=(16, 5),
                             scale=(1, 1, 0.5)))
        for o in out:
            kit.jitter_vertices(o, rng, 0.004)
        return out
    if kind == "cracked":
        # split across, the halves tilted apart
        f = rng.uniform(0.35, 0.65)
        for lo, hi in ((0.0, f), (f, 1.0)):
            w = sx * (hi - lo) - 0.02
            o = block("flag", (w, sy, thick), (cx - sx / 2 + sx * (lo + hi) / 2, cy, top - thick / 2 - rng.uniform(0, 0.02)),
                      bevel=0.03, segments=1, mat=m["flag"], tint=cool_tint(rng, 0.12),
                      rot=(rng.uniform(-0.03, 0.03), rng.uniform(-0.03, 0.03), rng.uniform(-0.03, 0.03)))
            kit.jitter_vertices(o, rng, 0.008)
            out.append(o)
        return out
    if kind == "sunken":
        o = block("flag", (sx, sy, thick), (cx, cy, top - thick / 2 - 0.045), bevel=0.03, segments=1, mat=m["flag"],
                  tint=cool_tint(rng, 0.1), rot=(rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04), 0))
        kit.jitter_vertices(o, rng, 0.008)
        return [o]
    if kind == "broken":
        # one corner gone: an L of two pieces, earth and a chip in the hole
        fx, fy = rng.uniform(0.45, 0.65), rng.uniform(0.45, 0.65)
        sgx, sgy = rng.choice((-1, 1)), rng.choice((-1, 1))
        a = block("flag", (sx, sy * (1 - fy) - 0.02, thick),
                  (cx, cy - sgy * sy * fy / 2, top - thick / 2), bevel=0.03, segments=1, mat=m["flag"],
                  tint=cool_tint(rng, 0.1), rot=rot)
        b = block("flag", (sx * (1 - fx) - 0.02, sy * fy, thick),
                  (cx - sgx * sx * fx / 2, cy + sgy * sy * (1 - fy) / 2, top - thick / 2 - 0.01), bevel=0.03,
                  segments=1, mat=m["flag"], tint=cool_tint(rng, 0.1), rot=rot)
        hx, hy = cx + sgx * sx * (1 - fx) / 2, cy + sgy * sy * (1 - fy) / 2
        earth = block("earth", (sx * fx - 0.04, sy * fy - 0.04, 0.08), (hx, hy, 0.13), bevel=0.02, mat=m["dirt"])
        chip = block("chip", (0.22, 0.16, 0.07), (hx + rng.uniform(-0.1, 0.1), hy + rng.uniform(-0.1, 0.1), 0.19),
                     rot=(0.1, -0.15, rng.uniform(0, 3)), bevel=0.02, mat=m["flag"], tint=cool_tint(rng, 0.1))
        for o in (a, b, chip):
            kit.jitter_vertices(o, rng, 0.01)
        return [a, b, earth, chip]
    o = block("flag", (sx, sy, thick), (cx, cy, top - thick / 2), bevel=0.03, segments=2, mat=m["flag"],
              tint=cool_tint(rng, 0.13), rot=rot)
    kit.jitter_vertices(o, rng, 0.007)
    return [o]


# ----------------------------------------------------------------------------- walls

def _courses(rng, z0: float, z1: float, lo: float, hi: float) -> list[tuple[float, float]]:
    """Split z0..z1 into courses of lo..hi metres (the last one absorbs the rest)."""
    out = []
    z = z0
    while z < z1 - 0.01:
        ch = rng.uniform(lo, hi)
        if z1 - (z + ch) < lo * 0.7:
            ch = z1 - z
        out.append((z, z + ch))
        z += ch
    return out


def _niche(parts: list, m, rng, x: float, z0: float, z1: float, w: float, contents: str) -> None:
    """A loculus between z0 and z1 (the frame included), centred on x, in a facade facing -Y with
    its front on y = 0: a stone sill and lintel, jambs, a dark back, and its contents."""
    depth = 0.46
    sill_h, lintel_h, jamb_w = 0.16, 0.26, 0.17
    t = cool_tint(rng, 0.08)
    parts.append(block("sill", (w + 2 * jamb_w + 0.1, depth + 0.07, sill_h - 0.02), (x, (depth + 0.07) / 2 - 0.07,
                       z0 + sill_h / 2), bevel=0.03, mat=m["stone"], tint=t))
    parts.append(block("lintel", (w + 2 * jamb_w + 0.04, depth + 0.03, lintel_h - 0.02),
                       (x, (depth + 0.03) / 2 - 0.03, z1 - lintel_h / 2), bevel=0.03, mat=m["stone"], tint=t))
    oz0, oz1 = z0 + sill_h, z1 - lintel_h
    for s in (-1, 1):
        j = block("jamb", (jamb_w - 0.02, depth, oz1 - oz0 - 0.02), (x + s * (w / 2 + jamb_w / 2), depth / 2,
                  (oz0 + oz1) / 2), bevel=0.025, mat=m["stone"], tint=t)
        kit.jitter_vertices(j, rng, 0.01)
        parts.append(j)
    parts.append(block("back", (w + 0.04, 0.1, oz1 - oz0 + 0.04), (x, depth + 0.03, (oz0 + oz1) / 2), bevel=0,
                       mat=m["void"]))
    oh = oz1 - oz0
    if contents == "sealed":
        # a sealing slab set just inside the opening, cracked across
        f = rng.uniform(0.35, 0.65)
        for lo, hi, dy in ((0.0, f, 0.0), (f, 1.0, rng.uniform(0.01, 0.03))):
            o = block("seal", (w * (hi - lo) - 0.025, 0.07, oh - 0.04), (x - w / 2 + w * (lo + hi) / 2, 0.06 + dy,
                      (oz0 + oz1) / 2), rot=(0, rng.uniform(-0.02, 0.02), 0), bevel=0.02, mat=m["ledger"],
                      tint=cool_tint(rng, 0.06))
            kit.jitter_vertices(o, rng, 0.006)
            parts.append(o)
        parts.append(ring_y("seal_ring", oh * 0.2, 0.02, (x - w * 0.25, 0.02, (oz0 + oz1) / 2), m["ledger"]))
    elif contents == "broken":
        # the lower part of the seal remains, its broken top jagged; a skull peers over it
        h = oh * rng.uniform(0.35, 0.5)
        o = block("seal", (w - 0.03, 0.07, h), (x, 0.08, oz0 + h / 2), bevel=0.02, mat=m["ledger"],
                  tint=cool_tint(rng, 0.06))
        for v in o.data.vertices:
            if v.co.z > oz0 + h * 0.6:
                v.co.z += rng.uniform(-0.09, 0.06)
        parts.append(o)
        parts += skull(m, (x + rng.uniform(-0.2, 0.2), 0.3, oz0 + 0.01), yaw=rng.uniform(-0.4, 0.4), s=0.95)
    elif contents == "bones":
        parts += skull(m, (x + rng.uniform(-0.25, 0.25), 0.2, oz0 + 0.005), yaw=rng.uniform(-0.6, 0.6))
        for i in range(3):
            y = rng.uniform(0.18, 0.38)
            dx = rng.uniform(0.2, 0.45)
            cx = x + rng.uniform(-0.15, 0.15)
            parts += long_bone(m, (cx - dx, y + rng.uniform(-0.06, 0.06), oz0 + 0.03 + 0.04 * i),
                               (cx + dx, y + rng.uniform(-0.06, 0.06), oz0 + 0.03 + 0.04 * i))
        parts.append(block("dust", (w - 0.1, 0.3, 0.03), (x, 0.24, oz0 + 0.012), bevel=0.01, mat=m["dirt"]))


def wall(p: dict, m: dict, rng) -> list:
    """A 4 m wide, 6 m tall crypt facade: a projecting plinth, rough courses of damp stone, rows of
    loculi (params.niche_rows: [[z0, z1], ...] at params.niche_x, params.niche_w wide, contents from
    params.niche_contents or chosen at random), a chamfered string course and an uneven coping.
    The front lies on y = 0 and the piece reaches back to y = 0.65, like the gallows wall."""
    width, height = p.get("width_m", 4.0), p.get("height_m", 6.0)
    half = width / 2
    rows = [tuple(r) for r in p.get("niche_rows", [[1.25, 2.45]])]
    nx = p.get("niche_x", [-0.95, 0.95])
    nw = p.get("niche_w", 1.2)
    contents = list(p.get("niche_contents", []))
    string_z = p.get("string_m", 3.35)
    plinth_h = 0.8
    frame_half = nw / 2 + 0.17
    # backing behind the joints; it starts deeper than the gallows wall's so the loculi are 0.46 m deep
    parts = [block("backing", (width, 0.17, height), (0, 0.565, height / 2), bevel=0, mat=m["mortar"])]
    # plinth: big blocks standing proud, their tops chamfered back
    x = -half - rng.uniform(0.0, 0.6)
    while x < half - 0.01:
        w = rng.uniform(1.1, 1.8)
        a, b = max(x, -half), min(x + w, half)
        if b - a > 0.15:
            s = block("plinth", (b - a - GAP, 0.42, plinth_h - GAP), ((a + b) / 2, 0.21 - 0.09, plinth_h / 2),
                      bevel=0.04, segments=2, mat=m["stone"], tint=cool_tint(rng, 0.1), taper=0.04)
            kit.jitter_vertices(s, rng, 0.016)
            parts.append(s)
        x += w
    # course boundaries: every niche row and the string course are course joints
    keys = sorted({plinth_h, string_z, string_z + 0.24, height - 0.45} | {z for r in rows for z in r})
    bands = []
    for z0, z1 in zip(keys, keys[1:]):
        if abs(z0 - string_z) < 1e-6:
            continue  # the string course itself
        in_row = any(abs(z0 - r[0]) < 1e-6 and abs(z1 - r[1]) < 1e-6 for r in rows)
        for c in _courses(rng, z0, z1, 0.42, 0.62) if not in_row else _courses(rng, z0, z1, 0.4, 0.6):
            bands.append((c[0], c[1], in_row))
    # a relieving arch over the bay, springing from the string course (an elliptical ring of
    # voussoirs standing proud, the stones inside it set back)
    arch = bool(p.get("arch", True))
    zs = string_z + 0.24
    ax, az = half - 0.5, min(1.25, height - 0.95 - zs - 0.4)
    ring_w = 0.4

    def arch_zone(u: float, z: float) -> str:
        if not arch or z < zs:
            return ""
        if (u / (ax + ring_w)) ** 2 + ((z - zs) / (az + ring_w)) ** 2 > 1.0:
            return ""
        return "inner" if (u / ax) ** 2 + ((z - zs) / az) ** 2 < 1.0 else "ring"

    for i, (z0, z1, in_row) in enumerate(bands):
        x = -half - rng.uniform(0.0, 0.7)
        while x < half - 0.01:
            w = rng.uniform(0.65, 1.45)
            spans = [(max(x, -half), min(x + w, half))]
            if in_row:  # leave room for the niche frames
                for cxn in nx:
                    nxt = []
                    for a, b in spans:
                        lo, hi = cxn - frame_half - 0.02, cxn + frame_half + 0.02
                        if b <= lo or a >= hi:
                            nxt.append((a, b))
                        else:
                            if lo - a > 0.12:
                                nxt.append((a, lo))
                            if b - hi > 0.12:
                                nxt.append((hi, b))
                    spans = nxt
            for a, b in spans:
                zone = arch_zone((a + b) / 2, (z0 + z1) / 2)
                if b - a > 0.12 and zone != "ring":
                    front = 0.08 if zone == "inner" else -rng.uniform(0.0, 0.03)
                    s = block("stone", (b - a - GAP, 0.3, z1 - z0 - GAP), ((a + b) / 2, front + 0.15, (z0 + z1) / 2),
                              bevel=0.035, segments=1, mat=m["stone"], tint=cool_tint(rng, 0.13))
                    kit.jitter_vertices(s, rng, 0.018)
                    parts.append(s)
            x += w
    # string course: a chamfered band standing proud
    x = -half
    while x < half - 0.01:
        w = min(rng.uniform(1.2, 2.0), half - x)
        if half - (x + w) < 0.4:
            w = half - x
        s = block("string", (w - GAP, 0.42, 0.24 - 0.03), (x + w / 2, 0.21 - 0.11, string_z + 0.12), bevel=0.05,
                  segments=1, mat=m["stone"], tint=cool_tint(rng, 0.08), taper=0.12)
        kit.jitter_vertices(s, rng, 0.012)
        parts.append(s)
        x += w
    if arch:
        n = 9
        ma, mb = ax + ring_w / 2, az + ring_w / 2

        def at(t: float):
            return ma * math.cos(t), zs + mb * math.sin(t)

        for i in range(n):
            t0, t1 = math.pi * i / n, math.pi * (i + 1) / n
            (x0, z0), (x1, z1) = at(t0), at(t1)
            tm = (t0 + t1) / 2
            cx, cz = at(tm)
            tx, tz = -ma * math.sin(tm), mb * math.cos(tm)
            key = i == n // 2
            o = block("voussoir", (math.hypot(x1 - x0, z1 - z0) - GAP, 0.32, ring_w + (0.12 if key else 0.0)),
                      (0, 0, 0), bevel=0.035, segments=1, mat=m["stone"], tint=cool_tint(rng, 0.1))
            kit.jitter_vertices(o, rng, 0.012)
            group_xf([o], (cx, -0.06 - (0.03 if key else 0.0) + 0.16, cz + (0.05 if key else 0.0)),
                     (0, math.atan2(-tz, tx), 0))
            parts.append(o)
    # half pilasters at both edges: neighbouring segments pair them into one pilaster per bay joint
    pil_w = 0.27
    for sx in (-1, 1):
        cx = sx * (half - pil_w / 2)
        parts.append(block("pil_base", (pil_w - 0.02, 0.44, 0.3), (cx, 0.22 - 0.16, plinth_h + 0.15), bevel=0.04,
                           mat=m["stone"], tint=cool_tint(rng, 0.08)))
        z = plinth_h + 0.3
        while z < string_z - 0.05:
            ch = min(rng.uniform(0.6, 0.9), string_z - z)
            if string_z - (z + ch) < 0.3:
                ch = string_z - z
            o = block("pilaster", (pil_w - 0.03, 0.42, ch - GAP), (cx, 0.21 - 0.13, z + ch / 2), bevel=0.035,
                      segments=1, mat=m["stone"], tint=cool_tint(rng, 0.1))
            kit.jitter_vertices(o, rng, 0.01)
            parts.append(o)
            z += ch
    # loculi
    k = 0
    for r in rows:
        for cxn in nx:
            what = contents[k] if k < len(contents) else rng.choice(("sealed", "sealed", "broken", "bones", "empty"))
            _niche(parts, m, rng, cxn, r[0], r[1], nw, what)
            k += 1
    # coping: heavy slabs of uneven height and wear, overhanging a little
    x = -half
    while x < half - 0.01:
        w = min(rng.uniform(0.9, 1.6), half - x)
        if half - (x + w) < 0.4:
            w = half - x
        h = rng.uniform(0.36, 0.45)
        s = block("coping", (w - GAP, 0.62, h), (x + w / 2, 0.21, height - h / 2), bevel=0.05, segments=2,
                  mat=m["stone"], tint=cool_tint(rng, 0.1), rot=(0, rng.uniform(-0.015, 0.015), 0))
        kit.jitter_vertices(s, rng, 0.02)
        parts.append(s)
        x += w
    return parts


def corner(p: dict, m: dict, rng) -> list:
    """An octagonal pier where two facades meet: a moulded base, drums of slightly different girth
    and a plain capital. About 1 m across, like the gallows quoins."""
    height = p.get("height_m", 6.0)
    parts = [lathe("base", [(0.5, 0.0), (0.5, 0.42), (0.45, 0.5)], sides=8, mat=m["stone"],
                   tint=cool_tint(rng, 0.06), bevel=0.03)]
    cap_h = 0.42
    z = 0.52
    i = 0
    while z < height - cap_h - 0.01:
        ch = min(rng.uniform(0.55, 0.8), height - cap_h - z)
        if height - cap_h - (z + ch) < 0.3:
            ch = height - cap_h - z
        r = 0.42 if i % 2 == 0 else 0.4
        d = lathe("drum", [(r, 0.0), (r, ch - 0.04)], loc=(0, 0, z), sides=8, mat=m["stone"],
                  tint=cool_tint(rng, 0.1), rot=(0, 0, rng.uniform(-0.04, 0.04)), bevel=0.03)
        kit.jitter_vertices(d, rng, 0.015)
        parts.append(d)
        z += ch
        i += 1
    parts.append(lathe("capital", [(0.42, 0.0), (0.5, 0.18), (0.5, cap_h - 0.02)], loc=(0, 0, height - cap_h + 0.02),
                       sides=8, mat=m["stone"], tint=cool_tint(rng, 0.06), bevel=0.03))
    return parts


def pillar(p: dict, m: dict, rng) -> list:
    """A clustered column (collision radius radius_m, 6 m tall): an octagonal stepped plinth, an
    octagonal core ringed by eight engaged shafts with two annulets, a flared capital and the
    broken stubs of four vault ribs rising from it (the crypt lost its roof)."""
    r = p.get("radius_m", 1.0)
    height = p.get("height_m", 6.0)
    k = r / 1.0
    parts = [lathe("plinth", [(1.1 * k, 0.0), (1.1 * k, 0.3), (1.04 * k, 0.36), (1.04 * k, 0.58), (0.97 * k, 0.68)],
                   sides=8, mat=m["stone"], tint=cool_tint(rng, 0.06), bevel=0.03)]
    shaft_r = 0.21 * k
    ring = 0.8 * k
    cap0 = height - 1.95  # the capital sits low enough for the rib stubs to rise clear of it
    parts.append(lathe("core", [(0.8 * k, 0.6), (0.8 * k, cap0 + 0.05)], sides=8, mat=m["stone"],
                       tint=cool_tint(rng, 0.05)))
    bands = [0.66, 1.95, 3.0, cap0]
    for i in range(8):
        a = math.radians(22.5 + 45 * i)
        cx, cy = math.cos(a) * ring, math.sin(a) * ring
        for z0, z1 in zip(bands, bands[1:]):
            s = cylinder("shaft", shaft_r, z1 - z0 + 0.04, (cx, cy, (z0 + z1) / 2), sides=10, mat=m["stone"],
                         tint=cool_tint(rng, 0.1), rot=(0, 0, rng.uniform(0, 1)))
            kit.jitter_vertices(s, rng, 0.012)
            parts.append(s)
    for z in bands[1:3]:
        parts.append(cylinder("annulet", ring + shaft_r + 0.05 * k, 0.18, (0, 0, z), sides=16, bevel=0.03,
                              mat=m["stone"], tint=cool_tint(rng, 0.06)))
    parts.append(lathe("capital", [(ring + shaft_r, 0.0), (ring + shaft_r, 0.1), (1.18 * k, 0.5), (1.18 * k, 0.6)],
                       loc=(0, 0, cap0 - 0.02), sides=16, mat=m["stone"], tint=cool_tint(rng, 0.06), bevel=0.03))
    ab0 = cap0 + 0.56
    parts.append(lathe("abacus", [(1.24 * k, 0.0), (1.24 * k, 0.24)], loc=(0, 0, ab0), sides=8, mat=m["stone"],
                       tint=cool_tint(rng, 0.06), rot=(0, 0, math.radians(22.5)), bevel=0.03))
    # broken rib stubs on the diagonals, rising outward; each ends in a jagged break
    top = ab0 + 0.24
    for i in range(4):
        a = math.radians(45 + 90 * i + rng.uniform(-4, 4))
        length = rng.uniform(1.25, 1.6)
        pitch = math.radians(rng.uniform(46, 54))
        o = block("rib", (length, 0.42 * k, 0.44), (0, 0, 0), bevel=0.04, segments=1, mat=m["stone"],
                  tint=cool_tint(rng, 0.08))
        # break the outer end along a slanted plane (per-vertex noise would fold the faces)
        ky, kz, c0 = rng.uniform(-0.35, 0.35), rng.uniform(-0.5, 0.2), rng.uniform(-0.15, 0.0)
        for v in o.data.vertices:
            if v.co.x > 0:
                v.co.x += c0 + ky * v.co.y + kz * v.co.z
        reach = 0.7 * k + math.cos(pitch) * length / 2
        rise = top - 0.25 + math.sin(pitch) * length / 2
        # pitch the outer end up, then turn it to its diagonal (Euler XYZ: Y first, then Z)
        group_xf([o], (math.cos(a) * reach, math.sin(a) * reach, rise), (0, -pitch, a))
        parts.append(o)
    # clamp: nothing may rise above the column's height (the map scales the piece by height / 6 m)
    zmax = max((o.matrix_world @ v.co).z for o in parts for v in o.data.vertices)
    if zmax > height:
        for o in parts[-4:]:
            for v in o.data.vertices:
                v.co.z -= zmax - height
    return parts


# ----------------------------------------------------------------------------- tomb

def tomb(p: dict, m: dict, rng) -> list:
    """A great tomb, 6.4 x 2.8 m and 3.2 m tall (long side along x): a two-step plinth, a panelled
    chest with pilasters (rings and hourglasses in the panels, a disc on each end), a heavy cornice
    knocked a little askew, a hipped lid with corner blocks and a ridge, iron rings on the ends and
    a skull and bones fallen at its foot."""
    L, W, H = p.get("length_m", 6.4), p.get("width_m", 2.8), p.get("height_m", 3.2)
    hl, hw = L / 2, W / 2
    parts = []
    # two-step plinth, each step of a few long blocks
    for (z0, z1, inset) in ((0.0, 0.3, 0.0), (0.3, 0.55, 0.22)):
        x = -hl + inset
        while x < hl - inset - 0.01:
            w = min(rng.uniform(1.5, 2.4), hl - inset - x)
            if hl - inset - (x + w) < 0.6:
                w = hl - inset - x
            # joints between blocks only: the outer ends lie flush with the footprint
            a = x + (GAP / 2 if x > -hl + inset + 1e-6 else 0.0)
            b = x + w - (GAP / 2 if x + w < hl - inset - 1e-6 else 0.0)
            s = block("step", (b - a, W - 2 * inset, z1 - z0), ((a + b) / 2, 0, (z0 + z1) / 2), bevel=0.04,
                      segments=2, mat=m["ledger"], tint=cool_tint(rng, 0.08))
            kit.jitter_vertices(s, rng, 0.012)
            parts.append(s)
            x += w
    cl, cw = L - 1.0, W - 0.8  # the chest
    c0, c1 = 0.55, 2.3
    parts.append(block("chest", (cl, cw, c1 - c0 + 0.02), (0, 0, (c0 + c1) / 2), bevel=0.03, mat=m["ledger"],
                       tint=cool_tint(rng, 0.04)))
    parts.append(block("base_moulding", (cl + 0.24, cw + 0.24, 0.16), (0, 0, c0 + 0.08), bevel=0.04, mat=m["ledger"],
                       tint=cool_tint(rng, 0.05)))
    face_y = cw / 2
    pil_x = [-cl / 2 + 0.17, -cl / 6, cl / 6, cl / 2 - 0.17]
    for side in (-1, 1):
        y = side * face_y
        for i, px in enumerate(pil_x):
            parts.append(block("pilaster", (0.34, 0.16, c1 - c0 - 0.2), (px, y + side * 0.06, (c0 + c1) / 2 + 0.06),
                               bevel=0.03, mat=m["ledger"], tint=cool_tint(rng, 0.06)))
        for i in range(3):
            a, b = pil_x[i] + 0.17, pil_x[i + 1] - 0.17
            cx = (a + b) / 2
            pw, ph = b - a - 0.14, c1 - c0 - 0.55
            pz = (c0 + c1) / 2 + 0.06
            parts.append(block("panel", (pw, 0.06, ph), (cx, y + side * 0.02, pz), bevel=0.015, mat=m["ledger"],
                               tint=cool_tint(rng, 0.05)))
            for sz in (-1, 1):  # frame mouldings top and bottom
                parts.append(block("frame", (pw + 0.12, 0.09, 0.08), (cx, y + side * 0.035, pz + sz * (ph / 2 + 0.04)),
                                   bevel=0.02, mat=m["ledger"]))
            if i == 1:
                parts.append(ring_y("wreath", 0.34, 0.06, (cx, y + side * 0.05, pz), m["ledger"], sign=side))
                parts.append(disc_y("boss", 0.12, 0.05, (cx, y + side * 0.05, pz), m["ledger"], sign=side))
            else:
                parts += hourglass_y(m, m["ledger"], (cx, y + side * 0.05, pz), h=0.62, sign=side)
    for side in (-1, 1):  # the ends: a disc in a ring, an iron ring on a plate
        x = side * cl / 2
        d = cylinder("end_disc", 0.42, 0.06, (x + side * 0.03, 0, (c0 + c1) / 2 + 0.1), rot=(0, math.pi / 2, 0),
                     sides=16, bevel=0.01, mat=m["ledger"])
        parts.append(d)
        parts.append(torus("end_ring", 0.42, 0.05, (x + side * 0.05, 0, (c0 + c1) / 2 + 0.1), rot=(0, math.pi / 2, 0),
                           mat=m["ledger"], seg=(16, 5), scale=(1, 1, 0.6)))
        for py in (-cw / 2 + 0.3, cw / 2 - 0.3):
            parts.append(block("plate", (0.05, 0.16, 0.16), (x + side * 0.025, py, c0 + 0.75), bevel=0.01, mat=m["iron"]))
            parts.append(torus("pull", 0.11, 0.022, (x + side * 0.06, py, c0 + 0.63), rot=(0, math.pi / 2, 0),
                               mat=m["iron"], seg=(12, 5)))
    # cornice and lid, knocked askew together
    lid = []
    lid.append(block("cornice", (cl + 0.5, cw + 0.5, 0.26), (0, 0, c1 + 0.12), bevel=0.05, segments=2, mat=m["ledger"],
                     tint=cool_tint(rng, 0.05), taper=0.0))
    lid.append(block("cornice_top", (cl + 0.36, cw + 0.36, 0.12), (0, 0, c1 + 0.3), bevel=0.03, mat=m["ledger"],
                     tint=cool_tint(rng, 0.05)))
    roof_h = H - (c1 + 0.36) - 0.12
    lid.append(hip("lid", cl + 0.2, cw + 0.2, roof_h, cl - 1.4, (0, 0, c1 + 0.35), mat=m["ledger"],
                   tint=cool_tint(rng, 0.05), bevel=0.03))
    lid.append(block("ridge", (cl - 1.3, 0.2, 0.16), (0, 0, c1 + 0.35 + roof_h + 0.03), bevel=0.03, mat=m["ledger"]))
    for sx in (-1, 1):
        for sy in (-1, 1):
            lid.append(block("acroterion", (0.34, 0.34, 0.34), (sx * (cl / 2 + 0.05), sy * (cw / 2 + 0.05), c1 + 0.52),
                             bevel=0.04, mat=m["ledger"], taper=0.25, tint=cool_tint(rng, 0.06)))
    group_xf(lid, (rng.uniform(0.03, 0.06), rng.uniform(-0.03, 0.03), 0), (0, 0, math.radians(rng.uniform(1.0, 1.6))))
    for o in lid:
        kit.jitter_vertices(o, rng, 0.008)
    parts += lid
    # small dressing at its foot: a skull and two bones on the lower step
    parts += skull(m, (hl - 0.7, -hw + 0.1, 0.3), yaw=0.5, s=1.0)
    parts += long_bone(m, (hl - 1.3, -hw + 0.1, 0.32), (hl - 0.9, -hw + 0.22, 0.32))
    parts += long_bone(m, (-hl + 0.6, hw - 0.1, 0.32), (-hl + 1.05, hw - 0.18, 0.33))
    return parts


# ----------------------------------------------------------------------------- gate

def gate(p: dict, m: dict, rng) -> list:
    """An iron grille, 8 m wide and 5 m tall: square bars set diagonally, flat riveted straps, a
    lattice of crossed bars low down, a band of rings near the top and spiked feet. Faces -Y."""
    width, height = p.get("width_m", 8.0), p.get("height_m", 5.0)
    parts = []
    n = int(round(width / 0.5))
    step = width / n
    foot = 0.28
    for i in range(n + 1):
        x = -width / 2 + i * step
        parts.append(cylinder("bar", 0.065, height - foot, (x, 0, foot + (height - foot) / 2), sides=4,
                              rot=(0, 0, math.pi / 4), mat=m["iron"], tint=random_tint(rng, 0.08)))
        parts.append(cylinder("spike", 0.07, foot, (x, 0, foot / 2), sides=4, radius_top=0.0, rot=(math.pi, 0, math.pi / 4),
                              mat=m["iron"]))
    straps = [0.45, 1.75, 3.35, height - 0.12]
    for z in straps:
        parts.append(block("strap", (width + 0.12, 0.05, 0.13), (0, -0.075, z), bevel=0.012, mat=m["iron"],
                           tint=random_tint(rng, 0.06)))
        parts.append(block("strap", (width + 0.12, 0.05, 0.13), (0, 0.075, z), bevel=0.012, mat=m["iron"],
                           tint=random_tint(rng, 0.06)))
        for i in range(0, n + 1, 2):
            parts.append(cylinder("rivet", 0.035, 0.04, (-width / 2 + i * step, -0.11, z), rot=(math.pi / 2, 0, 0),
                                  sides=6, mat=m["iron"]))
    # crossed lattice between the two lowest straps, one X per metre
    z0, z1 = straps[0] + 0.07, straps[1] - 0.07
    bays = int(round(width))
    bw = width / bays
    ang = math.atan2(z1 - z0, bw)
    ln = math.hypot(z1 - z0, bw) - 0.04
    for b in range(bays):
        cx = -width / 2 + bw * (b + 0.5)
        for s in (-1, 1):
            parts.append(block("lattice", (ln, 0.04, 0.07), (cx, -0.04, (z0 + z1) / 2), rot=(0, s * ang, 0),
                               bevel=0.01, mat=m["iron"], tint=random_tint(rng, 0.06)))
    # a band of rings between the upper straps
    zr = (straps[2] + straps[3]) / 2 + 0.05
    rr = min(step * 0.5, (straps[3] - straps[2]) * 0.4)
    for i in range(n):
        x = -width / 2 + (i + 0.5) * step
        parts.append(torus("ring", rr - 0.03, 0.028, (x, 0, zr), rot=(math.pi / 2, 0, 0), mat=m["iron"], seg=(12, 4)))
    return parts


def gate_lintel(p: dict, m: dict, rng) -> list:
    """A massive lintel over a gate: a beam of three long stones carved with a frieze of discs, a
    blank tablet in the middle under a small gable, and corbel blocks at the ends. Back on y = 0."""
    width = p.get("width_m", 9.0)
    depth = 1.0
    hw = width / 2
    parts = []
    end_w = 1.0
    for sx in (-1, 1):  # corbel blocks, standing a little proud
        s = block("corbel", (end_w - GAP, depth + 0.06, 1.2), (sx * (hw - end_w / 2), -(depth + 0.06) / 2, 0.6),
                  bevel=0.05, segments=2, mat=m["stone"], tint=cool_tint(rng, 0.08))
        kit.jitter_vertices(s, rng, 0.012)
        parts.append(s)
        parts.append(block("corbel_cap", (end_w + 0.1, depth + 0.16, 0.18), (sx * (hw - end_w / 2), -(depth + 0.16) / 2 + 0.02,
                           1.29), bevel=0.04, mat=m["stone"], tint=cool_tint(rng, 0.06), taper=0.08))
    beam_l = width - 2 * end_w
    n = 3
    for i in range(n):
        x0 = -beam_l / 2 + beam_l * i / n
        s = block("beam", (beam_l / n - GAP, depth, 1.0), (x0 + beam_l / n / 2, -depth / 2, 0.5), bevel=0.04, segments=2,
                  mat=m["stone"], tint=cool_tint(rng, 0.1))
        kit.jitter_vertices(s, rng, 0.012)
        parts.append(s)
    # frieze of discs (rings with a boss), skipping the middle where the tablet is
    for i in range(8):
        x = -beam_l / 2 + beam_l * (i + 0.5) / 8
        if abs(x) < 1.0:
            continue
        parts.append(ring_y("disc_ring", 0.2, 0.04, (x, -depth, 0.5), m["stone"], seg=(12, 4)))
        parts.append(disc_y("disc", 0.09, 0.04, (x, -depth, 0.5), m["stone"], sides=10))
    parts.append(block("tablet", (1.7, 0.08, 0.62), (0, -depth - 0.03, 0.5), bevel=0.02, mat=m["ledger"],
                       tint=cool_tint(rng, 0.04)))
    for sz in (-1, 1):
        parts.append(block("tablet_frame", (1.86, 0.1, 0.08), (0, -depth - 0.04, 0.5 + sz * 0.35), bevel=0.015,
                           mat=m["ledger"]))
    gable = prism("gable", depth - 0.1, 2.1, 0.42, (0, -depth / 2 - 0.02, 1.0), rot=(0, 0, math.pi / 2), mat=m["stone"],
                  tint=cool_tint(rng, 0.05), bevel=0.03)
    parts.append(gable)
    return parts


# ----------------------------------------------------------------------------- dressing

def brazier(p: dict, m: dict, rng) -> tuple[list, list]:
    """A stone fire bowl on a short octagonal pedestal with glowing coals (the coals are a separate
    emissive part); the bowl's rim is at about 1.2 m, like the gallows brazier, so the brazier_fire
    effect sits on it."""
    parts = [block("base", (0.66, 0.66, 0.2), (0, 0, 0.1), bevel=0.03, segments=2, mat=m["stone"],
                   tint=cool_tint(rng, 0.06)),
             lathe("pedestal", [(0.24, 0.18), (0.18, 0.3), (0.16, 0.75), (0.22, 0.86)], sides=8, mat=m["stone"],
                   tint=cool_tint(rng, 0.06), bevel=0.02),
             lathe("bowl", [(0.2, 0.84), (0.42, 0.98), (0.52, 1.12), (0.54, 1.2), (0.47, 1.2), (0.44, 1.1)],
                   sides=12, mat=m["stone"], tint=cool_tint(rng, 0.06)),
             cylinder("ash", 0.45, 0.06, (0, 0, 1.12), sides=12, mat=m["void"])]
    parts.append(torus("band", 0.49, 0.03, (0, 0, 1.03), mat=m["iron"], seg=(16, 4)))  # an iron hoop
    coal_mat = glow("coals", p.get("coal_color", "#ff6a1e"), 6.0)
    coals = []
    for i in range(9):
        a = rng.uniform(0, math.tau)
        rr = rng.uniform(0, 0.28)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=rng.uniform(0.07, 0.11),
                                              location=(math.cos(a) * rr, math.sin(a) * rr, 1.17 + rng.uniform(-0.02, 0.03)))
        c = bpy.context.active_object
        kit.clear_uvs(c)
        kit.jitter_vertices(c, rng, 0.02)
        c.data.materials.append(coal_mat)
        coals.append(c)
    return parts, coals


def bone_pile(p: dict, m: dict, rng) -> list:
    """A low heap of old bones against a wall or in a niche corner: a spill of earth, three skulls and
    a tangle of long bones. Under half a metre tall."""
    r = p.get("radius_m", 0.7)
    parts = [lathe("earth", [(r, 0.0), (r * 0.8, 0.06), (r * 0.45, 0.14), (0.0, 0.17)], sides=12, mat=m["dirt"],
                   tint=cool_tint(rng, 0.05))]
    kit.jitter_vertices(parts[0], rng, 0.03)
    for i in range(int(p.get("bones", 9))):
        a = rng.uniform(0, math.tau)
        d = rng.uniform(0.0, r * 0.6)
        cx, cy = math.cos(a) * d, math.sin(a) * d
        z = 0.17 * (1 - d / r) + 0.03 + rng.uniform(0, 0.06)
        b = rng.uniform(0, math.pi)
        ln = rng.uniform(0.32, 0.46) / 2
        parts += long_bone(m, (cx - math.cos(b) * ln, cy - math.sin(b) * ln, z + rng.uniform(-0.03, 0.03)),
                           (cx + math.cos(b) * ln, cy + math.sin(b) * ln, z + rng.uniform(-0.03, 0.05)),
                           r=rng.uniform(0.018, 0.024))
    for i in range(int(p.get("skulls", 3))):
        a = rng.uniform(0, math.tau)
        d = rng.uniform(0.1, r * 0.55)
        cx, cy = math.cos(a) * d, math.sin(a) * d
        z = 0.17 * (1 - d / r) + 0.02
        parts += skull(m, (cx, cy, z), yaw=rng.uniform(-1.2, 1.2), s=rng.uniform(0.95, 1.08),
                       tilt=rng.uniform(-0.25, 0.25))
    return parts


def grave_slabs(p: dict, m: dict, rng) -> list:
    """Broken grave slabs stacked against a wall: two leaning slabs (one carved with a ring, one
    split) and fragments at their feet. Back on y = 0, front toward -Y."""
    parts = []
    specs = [(-0.55, 1.5, 0.85, 0.27), (0.45, 1.25, 0.75, 0.33)]
    for i, (x, h, w, lean) in enumerate(specs):
        th = 0.12
        o = block("slab", (w, th, h), (0, 0, 0), bevel=0.03, segments=2, mat=m["ledger"], tint=cool_tint(rng, 0.07))
        group = [o]
        if i == 0:
            group.append(ring_y("ring", w * 0.28, 0.035, (0, -th / 2, h * 0.12), m["ledger"]))
            group.append(block("tablet", (w * 0.6, 0.03, h * 0.18), (0, -th / 2 - 0.01, -h * 0.25), bevel=0.01,
                               mat=m["ledger"]))
        else:
            for v in o.data.vertices:  # a broken top
                if v.co.z > h * 0.3:
                    v.co.z += rng.uniform(-0.18, 0.04) + (v.co.x / w) * 0.25
        kit.jitter_vertices(o, rng, 0.008)
        # lean back against the wall (tilting about x moves the top toward +Y), the top's back edge
        # just in front of y = 0 and the foot on the floor
        sl, cl = math.sin(lean), math.cos(lean)
        group_xf(group, (x, -(h / 2 * sl + th / 2 * cl) - 0.02, h / 2 * cl + th / 2 * sl),
                 (-lean, 0, rng.uniform(-0.05, 0.05)))
        parts += group
    for i in range(3):
        o = block("fragment", (rng.uniform(0.25, 0.45), rng.uniform(0.2, 0.32), 0.1),
                  (rng.uniform(-0.9, 0.9), -rng.uniform(0.55, 0.85), 0.05), rot=(rng.uniform(-0.1, 0.1), rng.uniform(-0.1, 0.1),
                                                                                  rng.uniform(0, 3)),
                  bevel=0.02, mat=m["ledger"], tint=cool_tint(rng, 0.07))
        kit.jitter_vertices(o, rng, 0.015)
        parts.append(o)
    parts += skull(m, (0.95, -0.35, 0.0), yaw=-0.6, s=1.0)
    return parts


def gatehouse(p: dict, m: dict, rng) -> list:
    """A mausoleum front on the wall top over a gate, tall enough to hide the raised grille: an
    ashlar block with four pilasters and blind loculi between them, an entablature and a pediment
    with a carved ring at front and back, and a low stone-slab roof between. The lowest band
    (z 0..1) sits behind the gate's lintel; the front faces the arena (-Y). Same envelope as the
    gallows gatehouse (12 x 3.4 m, body 5 m)."""
    W, D = p.get("width_m", 12.0), p.get("depth_m", 3.4)
    body_h = p.get("body_m", 5.0)
    lintel_d = p.get("lintel_depth_m", 1.0)
    hw, hd = W / 2, D / 2
    st = "stone_dry"
    parts = [block("core", (W - 0.6, D - 0.6, body_h - 1.0), (0, 0, 1.0 + (body_h - 1.0) / 2), bevel=0, mat=m["mortar"]),
             block("core_low", (W - 0.6, D - lintel_d - 0.3, 1.2), (0, (lintel_d - 0.3) / 2 + 0.15, 0.6), bevel=0,
                   mat=m["mortar"])]
    pil_x = [-hw + 0.45, -hw / 3, hw / 3, hw - 0.45]
    niches = [(-hw * 2 / 3 + 0.15, 2.6), (0.0, 2.6), (hw * 2 / 3 - 0.15, 2.6)]
    big = dict(course=(0.62, 0.8), width=(1.2, 2.0), mat_key=st)

    def front_skip(u, z):
        if any(abs(u - px) < 0.5 for px in pil_x):
            return True
        return any(abs(u - nx) < 0.85 and abs(z - nz) < 1.05 for nx, nz in niches)

    ashlar(parts, m, rng, "x", -hd, -1, -hw, hw, 1.0, body_h - 0.6, skip=front_skip, **big)
    ashlar(parts, m, rng, "x", hd, 1, -hw, hw, 0.0, body_h - 0.6, **big)
    for s in (-1, 1):
        ashlar(parts, m, rng, "y", s * hw, s, -hd + 0.3, hd - 0.3, 1.0, body_h - 0.6, **big)
        ashlar(parts, m, rng, "y", s * hw, s, -hd + lintel_d, hd - 0.3, 0.0, 1.0, course=(1.0, 1.0),
               width=(0.9, 1.5), mat_key=st)
    ashlar(parts, m, rng, "x", -hd + lintel_d, -1, -hw + 0.3, hw - 0.3, 0.0, 1.0, course=(1.0, 1.0),
           width=(1.2, 2.0), depth=0.3, mat_key=st)
    # pilasters standing proud of the front, on a base, with plain capitals
    for px in pil_x:
        parts.append(block("pilaster", (0.9, 0.5, body_h - 1.5), (px, -hd - 0.05, 1.0 + (body_h - 1.5) / 2), bevel=0.04,
                           segments=1, mat=m[st], tint=cool_tint(rng, 0.06)))
        parts.append(block("pil_cap", (1.1, 0.62, 0.3), (px, -hd - 0.08, body_h - 0.5 + 0.15), bevel=0.04, mat=m[st],
                           tint=cool_tint(rng, 0.05), taper=0.06))
    # blind loculi: framed dark recesses, two rows in each bay
    for nx, nz in niches:
        for dz in (-0.5, 0.5):
            z0 = nz + dz - 0.4
            parts.append(block("void", (1.3, 0.2, 0.62), (nx, -hd + 0.15, z0 + 0.4), bevel=0, mat=m["void"]))
            parts.append(block("sill", (1.62, 0.5, 0.14), (nx, -hd - 0.02, z0 + 0.03), bevel=0.03, mat=m[st],
                               tint=cool_tint(rng, 0.06)))
            parts.append(block("head", (1.62, 0.5, 0.2), (nx, -hd - 0.02, z0 + 0.8), bevel=0.03, mat=m[st],
                               tint=cool_tint(rng, 0.06)))
            for s in (-1, 1):
                parts.append(block("jamb", (0.14, 0.45, 0.62), (nx + s * 0.72, -hd, z0 + 0.4), bevel=0.02, mat=m[st],
                                   tint=cool_tint(rng, 0.06)))
    # entablature front and back, then pediments and a slab roof
    top = body_h
    for sy in (-1, 1):
        parts.append(block("architrave", (W + 0.3, 0.5, 0.5), (0, sy * (hd + 0.0), top - 0.35), bevel=0.04, segments=1,
                           mat=m[st], tint=cool_tint(rng, 0.05)))
        parts.append(block("cornice", (W + 0.7, 0.8, 0.26), (0, sy * (hd + 0.1), top + 0.03), bevel=0.04, segments=1,
                           mat=m[st], tint=cool_tint(rng, 0.05), taper=0.04))
    for sx in (-1, 1):
        parts.append(block("architrave", (0.5, D, 0.5), (sx * hw, 0, top - 0.35), bevel=0.04, mat=m[st]))
    # a gabled stone roof whose triangular ends (the pediments) face front and back
    ped_h = p.get("pediment_m", 2.0)
    gable_y = D / 2 + 0.3
    parts.append(prism("roof", 2 * gable_y, W - 0.1, ped_h, (0, 0, top + 0.16), rot=(0, 0, math.pi / 2), mat=m[st],
                       tint=cool_tint(rng, 0.05), bevel=0.04))
    for sy in (-1, 1):
        y = sy * gable_y
        parts.append(ring_y("tympanum_ring", 0.55, 0.09, (0, y, top + 0.16 + ped_h * 0.36), m[st], sign=sy))
        parts.append(disc_y("tympanum_boss", 0.2, 0.08, (0, y, top + 0.16 + ped_h * 0.36), m[st], sign=sy))
    parts.append(block("ridge", (0.5, 2 * gable_y + 0.1, 0.24), (0, 0, top + 0.16 + ped_h + 0.06), bevel=0.04, mat=m[st]))
    for sx in (-1, 0, 1):
        for sy in (-1, 1):
            z = top + 0.16 + (ped_h if sx == 0 else 0.0)
            parts.append(block("acroterion", (0.5, 0.5, 0.55), (sx * (hw - 0.3), sy * (gable_y - 0.1), z + 0.28),
                               bevel=0.04, mat=m[st], taper=0.3, tint=cool_tint(rng, 0.06)))
    return parts


def skyline_arches(p: dict, m: dict, rng) -> list:
    """A ruined arcade beyond the walls: square piers carrying round arches of voussoirs, one arch
    fallen to its springers, the upper wall broken to a jagged line. A low-detail silhouette."""
    bays = int(p.get("bays", 3))
    span = p.get("span_m", 5.6)
    pier = 2.0
    pier_h = p.get("pier_m", 6.5)
    W = bays * span + (bays + 1) * pier
    parts = []
    fallen = rng.randrange(bays)
    x = -W / 2
    for i in range(bays + 1):
        z = 0.0
        while z < pier_h - 0.05:
            ch = min(rng.uniform(1.0, 1.5), pier_h - z)
            parts.append(block("pier", (pier - 0.06, pier - 0.06, ch - 0.06), (x + pier / 2, 0, z + ch / 2), bevel=0.06,
                               mat=m["far_stone"], tint=cool_tint(rng, 0.08)))
            z += ch
        x += pier
        if i == bays:
            break
        r = span / 2
        cx = x + r
        n = 9
        for k in range(n):
            if i == fallen and 2 <= k <= n - 3:
                continue
            a0 = math.pi * k / n
            a1 = math.pi * (k + 1) / n
            am = (a0 + a1) / 2
            rad = r + 0.5
            o = block("voussoir", (math.pi * rad / n - 0.06, pier - 0.2, 1.0), (0, 0, 0), bevel=0.05, mat=m["far_stone"],
                      tint=cool_tint(rng, 0.08))
            group_xf([o], (cx - math.cos(am) * rad, 0, pier_h + math.sin(am) * rad), (0, am - math.pi / 2, 0))
            parts.append(o)
        if i != fallen:  # the wall over a standing arch, its top broken to a ragged line
            hw = r + pier / 2 - 0.03
            base = pier_h + r + 1.0
            tops = [base + rng.uniform(0.0, 2.5) for _ in range(4)]
            parts.append(_spandrel(cx, r, pier_h, hw, tops, pier - 0.5, 0.12, m["far_stone"], cool_tint(rng, 0.08)))
        x += span
    for o in parts:
        kit.jitter_vertices(o, rng, 0.04)
    return parts


def _spandrel(cx: float, r: float, zs: float, hw: float, tops: list, depth: float, y: float, mat, tint):
    """A slab of wall over a round arch: the rectangle cx +- hw from the springing line zs up to a
    broken top (heights `tops` across it), less the arch opening of radius r, `depth` thick."""
    prof = [(cx - hw, zs)]
    for k, t in enumerate(tops):
        prof.append((cx - hw + 2 * hw * k / (len(tops) - 1), t))
    prof.append((cx + hw, zs))
    n = 10
    prof += [(cx + r * math.cos(math.pi * k / n), zs + r * math.sin(math.pi * k / n)) for k in range(n + 1)]
    bm = bmesh.new()
    front = [bm.verts.new((x, y - depth / 2, z)) for x, z in prof]
    back = [bm.verts.new((x, y + depth / 2, z)) for x, z in prof]
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    for i in range(len(prof)):
        j = (i + 1) % len(prof)
        bm.faces.new((front[i], front[j], back[j], back[i]))
    o = _from_bmesh(bm, "spandrel")
    return _finish(o, "spandrel", mat, tint)


def skyline_ruin(p: dict, m: dict, rng) -> list:
    """A broken mausoleum tower beyond the walls: a stepped base, a square shaft with string courses
    and rows of blind loculi, and a jagged top where its upper courses have fallen. A low-detail
    silhouette."""
    w = p.get("width_m", 6.0)
    h = p.get("height_m", 16.0)
    fs = m["far_stone"]
    parts = [block("base", (w + 1.6, w + 1.6, 1.0), (0, 0, 0.5), bevel=0.08, mat=fs, tint=cool_tint(rng, 0.05)),
             block("base2", (w + 0.8, w + 0.8, 0.8), (0, 0, 1.4), bevel=0.08, mat=fs, tint=cool_tint(rng, 0.05))]
    body = h * 0.62
    z = 1.8
    for zt in (body * 0.45, body):  # the shaft in two stages, each topped by a string course
        parts.append(block("shaft", (w, w, zt - z), (0, 0, (z + zt) / 2), bevel=0.06, mat=fs, tint=cool_tint(rng, 0.06)))
        parts.append(block("string", (w + 0.5, w + 0.5, 0.35), (0, 0, zt + 0.1), bevel=0.06, mat=fs,
                           tint=cool_tint(rng, 0.05)))
        z = zt + 0.27
    # the broken top: the upper stage's walls stand to a ragged line that falls away from one corner
    n = 4
    cell = w / n
    for i in range(n):
        for j in range(n):
            if 0 < i < n - 1 and 0 < j < n - 1:
                continue  # hollow inside
            fall = (i + j) / (2 * (n - 1))
            tall = (h - z) * max(0.12, (1.0 - 0.85 * fall) * rng.uniform(0.75, 1.0))
            if rng.random() < 0.12:
                tall *= 0.4
            parts.append(block("ruin", (cell - 0.02, cell - 0.02, tall), (-w / 2 + cell * (i + 0.5), -w / 2 + cell * (j + 0.5),
                               z + tall / 2), bevel=0.06, mat=fs, tint=cool_tint(rng, 0.07)))
    for zz in (3.3, 7.2):
        for u in (-w / 4, w / 4):
            for sy in (-1, 1):
                parts.append(block("loculus", (1.1, 0.12, 0.6), (u, sy * (w / 2 + 0.02), zz), bevel=0, mat=m["void"]))
                parts.append(block("loculus", (0.12, 1.1, 0.6), (sy * (w / 2 + 0.02), u, zz), bevel=0, mat=m["void"]))
    for o in parts:
        kit.jitter_vertices(o, rng, 0.04)
    return parts


PIECES = {"floor_tile": floor_tile, "wall": wall, "corner": corner, "pillar": pillar, "tomb": tomb, "gate": gate,
          "gate_lintel": gate_lintel, "brazier": brazier, "bone_pile": bone_pile, "grave_slabs": grave_slabs,
          "gatehouse": gatehouse, "skyline_arches": skyline_arches, "skyline_ruin": skyline_ruin}
BACK_ON_Y0 = {"wall", "gate_lintel", "grave_slabs"}


def build(spec: dict, previews: Path | None) -> None:
    kit.build_spec(spec, previews, PIECES, BACK_ON_Y0, mats, preset=PRESET)


def main() -> int:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spec", type=Path)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--only", nargs="*", help="with --all: only these piece names or asset ids")
    ap.add_argument("--previews", type=Path)
    args = ap.parse_args(argv)
    specs = sorted((common.REPO / "data" / "assets").glob("crypt_*.json")) if args.all else [args.spec]
    for path in specs:
        spec = json.loads(Path(path).read_text())
        if args.only and spec["params"]["piece"] not in args.only and spec["id"] not in args.only:
            continue
        build(spec, args.previews)
    return 0


if __name__ == "__main__":
    sys.exit(main())
