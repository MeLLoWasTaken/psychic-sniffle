"""Weapons at the new fidelity (backlog G-09): each design is a list of parts (armor_kit.Part), each
a distance field, extracted densely (the normal map's source) and reduced to the weapon's budget by
build_weapon.py, then baked like the armor.

Weapon space: the point the hand grips is the origin and the blade or head points up (+Z); a
blade's flat faces face +-Y, its edges +-X. Sizes follow the old weapons so grips and animations
still fit (data/assets/weapon_*.json params). Materials: steel, dark (blackened steel), iron,
leather, wood, gold, bone, and glowing frost and holy (build_weapon.MATERIALS).
"""
from __future__ import annotations

import numpy as np

import armor_deathsworn as D
import armor_kit as K
import armor_warblade as W
from armor_kit import Part, capsule, ellipsoid, sawtooth, studs

TAU = 2 * np.pi


# ----------------------------------------------------------------------------- shared fields

class _Scaled:
    """A grid seen with its axes scaled (to squash a round field into a flat one)."""

    def __init__(self, G, sx=1.0, sy=1.0, sz=1.0):
        self.X, self.Y, self.Z = G.X * sx, G.Y * sy, G.Z * sz
        self.lo, self.voxel = G.lo, G.voxel


def radial(G):
    return np.sqrt(G.X ** 2 + G.Y ** 2)


def angle(G):
    return np.arctan2(G.Y, G.X)


def ring(G, z, r, half_h, tube=0.0):
    """A band round the Z axis: radius r, half height half_h, rounded by `tube`."""
    return np.sqrt(np.maximum(radial(G) - r, 0) ** 2 + np.maximum(np.abs(G.Z - z) - half_h, 0) ** 2) - tube \
        + np.minimum(np.maximum(radial(G) - r, np.abs(G.Z - z) - half_h), 0)


def rod(G, z0, z1, r):
    return np.maximum(radial(G) - r, np.maximum(z0 - G.Z, G.Z - z1))


def wrapped(G, z0, z1, r, pitch=0.022, depth=0.0018):
    """A leather wrap from z0 to z1: overlapping bands spiralling round the grip."""
    s = sawtooth((G.Z - z0) + angle(G) / TAU * pitch, pitch)
    return np.maximum(radial(G) - (r - depth * s), np.maximum(z0 - G.Z, G.Z - z1))


def seg2(U, V, a, b):
    """Distance in a plane (coordinates U, V) to the segment a-b."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    ab = b - a
    t = np.clip(((U - a[0]) * ab[0] + (V - a[1]) * ab[1]) / (ab @ ab), 0, 1)
    return np.sqrt((U - a[0] - ab[0] * t) ** 2 + (V - a[1] - ab[1] * t) ** 2)


def facet_ball(G, c, r, sides=8, rz=None):
    """A faceted knob: a `sides`-sided prism round Z, bevelled to points top and bottom."""
    q = [G.X - c[0], G.Y - c[1], G.Z - c[2]]
    poly = None
    for k in range(sides):
        th = TAU * k / sides
        v = q[0] * np.cos(th) + q[1] * np.sin(th)
        poly = v if poly is None else np.maximum(poly, v)
    rz = rz or r
    return np.maximum(poly - r * (1.0 - 0.6 * np.clip((np.abs(q[2]) - rz * 0.35) / (rz * 0.65), 0, 1)), np.abs(q[2]) - rz)


def blade(G, z0, L, hw, ht, point=0.16, nicks=(), fuller=None, bevel=0.6):
    """A straight blade from z0 for L metres: half width hw(t) and half thickness ht(t) (t from 0
    at the base to 1 at the tip). Its section is a flat-ish centre that breaks at `bevel` (a
    fraction of the half width) into a ground edge bevel, so the edge reads as a bright line. The
    point is drawn over the last `point` of its length; nicks are (t, depth, side) chips out of
    one edge (side +1 or -1) or both (0); fuller is (t0, t1, half width, depth)."""
    t = np.clip((G.Z - z0) / L, 0, 1)
    w = hw(t)
    tip = np.clip((1.0 - t) / point, 0, 1)
    w = w * np.sqrt(tip) * (1.0 - 0.15 * (1.0 - tip))
    for nick in nicks:
        tn, depth = nick[0], nick[1]
        side = nick[2] if len(nick) > 2 else 0
        on = 1.0 if side == 0 else (np.sign(G.X) == side)
        w = w * (1.0 - depth * on * np.exp(-np.abs((t - tn) * L) / 0.0045))
    h = ht(t) * (0.55 + 0.45 * tip)
    u = np.clip(np.abs(G.X) / np.maximum(w, 1e-4), 0, 1)
    thick = h * np.minimum(1.0 - 0.12 * u, 0.12 + 0.88 * (1.0 - u) / (1.0 - bevel))
    if fuller is not None:
        f0, f1, fw, fd = fuller
        inside = np.clip((t - f0) / 0.03, 0, 1) * np.clip((f1 - t) / 0.05, 0, 1)
        thick = thick - fd * inside * np.clip(1.0 - np.abs(G.X) / fw, 0, 1) ** 0.6
    return np.maximum(np.maximum(np.abs(G.X) - w, np.abs(G.Y) - thick), np.maximum(z0 - G.Z, G.Z - z0 - L))


def glyphs(X, Z, z0, count, cell, width, seed=3):
    """Angular runes in a column down a blade's centre: each a few strokes in a cell, as a 2D
    distance (in X and Z)."""
    rng = np.random.default_rng(seed)
    d = np.full(np.broadcast_shapes(X.shape, Z.shape), 1.0)
    for k in range(count):
        zc = z0 + (k + 0.5) * cell
        h, w = cell * 0.36, width
        strokes = [((0, -h), (0, h))]
        for _ in range(2):
            y0 = rng.uniform(-h, h * 0.6)
            side = rng.choice([-1, 1])
            strokes.append(((0, y0), (side * w, y0 + rng.uniform(0.2, 0.5) * h)))
        if rng.random() < 0.5:
            strokes.append(((-w * 0.7, -h * 0.7), (w * 0.7, -h * 0.7)))
        for a, b in strokes:
            d = np.minimum(d, seg2(X, Z, (a[0], zc + a[1]), (b[0], zc + b[1])))
    return d


# ----------------------------------------------------------------------------- designs

def warblade_greatsword(p: dict) -> list[Part]:
    """The Warblade's two-handed sword: a broad blade with a long fuller, nicks in both edges and
    parrying lugs above the ricasso; a heavy crossguard whose arms sweep down, round a riveted boss
    with a brass ring; a spiral leather grip between iron ferrules; a faceted pommel with a spike."""
    g, L, w = p.get("grip_m", 0.34), p.get("blade_m", 1.22), p.get("blade_width_m", 0.085)
    zg = g / 2 + 0.035                       # the guard
    z0 = zg + 0.035                          # the blade's base
    lo, hi = np.array([-0.26, -0.06, -g / 2 - 0.16]), np.array([0.26, 0.06, z0 + L + 0.02])

    def hw(t):
        ric = np.clip(t / 0.08, 0, 1)
        return w * (0.62 + 0.38 * ric) * (1.0 - 0.24 * t)

    def blade_fn(G):
        d = blade(G, z0, L, hw, lambda t: 0.012 * (1 - 0.35 * t), point=0.14,
                  nicks=((0.33, 0.1, 1), (0.56, 0.13, -1), (0.71, 0.07, 1)),
                  fuller=(0.09, 0.66, 0.013, 0.0045))
        # parrying lugs: two short points either side, a hand's width above the guard
        for sx in (1.0, -1.0):
            a = np.array([sx * w * 0.6, 0.0, z0 + 0.1])
            lug = W.cone(G.X, G.Y * 1.8, G.Z, a, a + np.array([sx * 0.05, 0.0, -0.018]), 0.017, 0.002)
            d = np.minimum(d, lug)
        return d

    def guard(G):
        S = _Scaled(G, 1.0, 1.7, 1.0)
        d = None
        for sx in (1.0, -1.0):
            pts = np.array([[0.0, 0.0, zg], [sx * 0.08, 0.0, zg + 0.004], [sx * 0.13, 0.0, zg - 0.008],
                            [sx * 0.158, 0.0, zg - 0.042], [sx * 0.163, 0.0, zg - 0.07]])
            arm = W.swept(S, W.curve(pts, n=6), np.linspace(0.024, 0.009, 4 * 6 + 1), rib=0.0)
            d = arm if d is None else np.minimum(d, arm)
            d = np.minimum(d, facet_ball(G, (sx * 0.163, 0.0, zg - 0.078), 0.015, sides=8, rz=0.017))
        boss = K.superellipse(G.X, G.Y, 0.0, 0.0, 0.042, 0.031, 3.0)
        boss = np.maximum(boss, np.abs(G.Z - zg) - 0.034)
        d = np.minimum(d, boss - 0.004)
        # a pointed langet rising from the boss onto both faces of the blade
        rise = np.clip((G.Z - zg) / 0.12, 0, 1)
        langet = np.maximum(np.maximum(np.abs(G.X) - 0.034 * (1.0 - rise), np.abs(G.Y) - 0.0165),
                            np.maximum(zg - G.Z, G.Z - zg - 0.12))
        d = np.minimum(d, langet)
        riv = [np.array([sx * 0.026, sy * 0.034, zg + dz]) for sx in (1, -1) for sy in (1, -1) for dz in (0.017, -0.017)]
        return studs(d, G, riv, 0.0042)

    def brass(G):
        band = np.maximum(np.abs(K.superellipse(G.X, G.Y, 0.0, 0.0, 0.045, 0.034, 3.0) - 0.002) - 0.0025,
                          np.abs(G.Z - zg) - 0.007)
        pom = ring(G, -g / 2 - 0.068, 0.04, 0.005, 0.002)
        return np.minimum(band, pom)

    def grip(G):
        d = wrapped(G, -g / 2 + 0.012, g / 2 - 0.006, 0.0225, pitch=0.024)
        return d

    def iron(G):
        d = np.minimum(ring(G, g / 2 + 0.002, 0.026, 0.008, 0.002), ring(G, -g / 2 + 0.004, 0.027, 0.01, 0.002))
        pz = -g / 2 - 0.068
        knob = facet_ball(G, (0.0, 0.0, pz), 0.046, sides=8, rz=0.052)
        spike = W.cone(G.X, G.Y, G.Z, (0, 0, pz - 0.04), (0, 0, pz - 0.105), 0.022, 0.002)
        neck = rod(G, pz + 0.03, -g / 2, 0.02)
        return np.minimum(np.minimum(d, knob), np.minimum(spike, neck))
    return [Part("blade", "steel", blade_fn, lo, hi, 6500, skin="", voxel=0.0011, facet_deg=35),
            Part("guard", "dark", guard, lo, np.array([0.26, 0.06, z0 + 0.12]), 3200, voxel=0.001, facet_deg=40),
            Part("brass", "gold", brass, lo, np.array([0.26, 0.06, z0 + 0.06]), 900, voxel=0.0009, facet_deg=40),
            Part("grip", "leather", grip, lo, np.array([0.26, 0.06, z0]), 1800, voxel=0.0009),
            Part("pommel", "dark", iron, lo, np.array([0.26, 0.06, z0]), 2000, voxel=0.0009, facet_deg=40)]


def deathsworn_runeblade(p: dict) -> list[Part]:
    """The Deathsworn's runeblade: a dark two-handed blade with saw teeth along both edges near the
    guard and a column of glowing runes down its fuller; a crescent guard of blackened iron round a
    bone centre with an ice crystal rising at each end; a dark leather grip with bone rings; an iron
    cage pommel holding an ice crystal."""
    g, L, w = p.get("grip_m", 0.36), p.get("blade_m", 1.2), p.get("blade_width_m", 0.06)
    zg = g / 2 + 0.04
    z0 = zg + 0.03
    lo, hi = np.array([-0.28, -0.06, -g / 2 - 0.16]), np.array([0.28, 0.06, z0 + L + 0.02])
    fuller_floor = 0.0115 * 0.55

    def hw(t):
        return w * (1.12 - 0.3 * t)

    def blade_fn(G):
        d = blade(G, z0, L, hw, lambda t: 0.0115 * (1 - 0.3 * t), point=0.15,
                  nicks=((0.69, 0.09, 1),), fuller=(0.06, 0.78, 0.016, 0.005))
        # hooked teeth along the back edge (-X), pointing back toward the guard, flattened like the blade
        for k in range(7):
            tt = 0.06 + k * 0.075
            zt = z0 + tt * L
            wb = w * (1.12 - 0.3 * tt)
            size = 1.0 - 0.05 * k
            base = np.array([-wb * 0.75, 0.0, zt])
            tip = np.array([-wb - 0.042 * size, 0.0, zt - 0.03 * size])
            d = np.minimum(d, W.cone(G.X, G.Y * 2.6, G.Z, base, tip, 0.024 * size, 0.0015))
        return d

    def runes(G):
        d2 = glyphs(G.X, G.Z, z0 + 0.09, 9, 0.075, 0.009, seed=7) - 0.0018
        face = np.abs(np.abs(G.Y) - (fuller_floor + 0.0006)) - 0.0009
        return np.maximum(d2, face)

    def guard(G):
        S = _Scaled(G, 1.0, 1.6, 1.0)
        d = None
        for sx in (1.0, -1.0):
            pts = np.array([[0.0, 0.0, zg - 0.01], [sx * 0.11, 0.0, zg], [sx * 0.18, 0.0, zg + 0.035],
                            [sx * 0.215, 0.0, zg + 0.09]])
            arm = W.swept(S, W.curve(pts, n=6), np.linspace(0.026, 0.008, 3 * 6 + 1))
            d = arm if d is None else np.minimum(d, arm)
        return d

    def bone(G):
        centre = facet_ball(_Scaled(G, 1.0, 1.35, 1.0), (0.0, 0.0, zg), 0.046, sides=6, rz=0.044)
        rings = None
        for z in (-g / 2 + 0.06, 0.0, g / 2 - 0.05):
            r = ring(G, z, 0.026, 0.006, 0.002)
            rings = r if rings is None else np.minimum(rings, r)
        return np.minimum(centre, rings)

    def ice(G):
        items = [(np.array([sx * 0.21, 0.0, zg + 0.085]), np.array([sx * 0.24, 0.0, zg + 0.19]), 0.016) for sx in (1, -1)]
        pz = -g / 2 - 0.07
        items.append((np.array([0, 0, pz - 0.035]), np.array([0, 0, pz + 0.04]), 0.02))
        return D.crystals(np.full(np.broadcast_shapes(G.X.shape, G.Y.shape, G.Z.shape), 1.0, np.float32), G, items)

    def grip(G):
        return wrapped(G, -g / 2 + 0.01, g / 2 - 0.005, 0.021, pitch=0.02)

    def pommel(G):
        pz = -g / 2 - 0.07
        cage = None
        for k in range(4):
            a = TAU * k / 4 + 0.4
            pts = np.array([[0.0, 0.0, -g / 2], [np.cos(a) * 0.034, np.sin(a) * 0.034, pz + 0.01],
                            [np.cos(a) * 0.02, np.sin(a) * 0.02, pz - 0.055]])
            bar = W.swept(G, W.curve(pts, n=5), np.linspace(0.0075, 0.004, 2 * 5 + 1))
            cage = bar if cage is None else np.minimum(cage, bar)
        return np.minimum(cage, ring(G, -g / 2 + 0.002, 0.025, 0.008, 0.002))
    gh = np.array([0.28, 0.06, z0 + 0.22])
    return [Part("blade", "dark", blade_fn, lo, hi, 6200, voxel=0.0011, facet_deg=35),
            Part("runes", "frost", runes, np.array([-0.02, -0.02, z0]), np.array([0.02, 0.02, z0 + L * 0.82]), 1200,
                 voxel=0.0007),
            Part("guard", "iron", guard, lo, gh, 2400, voxel=0.001, facet_deg=40),
            Part("bone", "bone", bone, lo, gh, 1600, voxel=0.0009),
            Part("ice", "frost", ice, lo, gh, 900, voxel=0.0009, facet_deg=30),
            Part("grip", "leather", grip, lo, gh, 1600, voxel=0.0009),
            Part("pommel", "iron", pommel, lo, gh, 1300, voxel=0.0009, facet_deg=40)]


def arcanist_frost_staff(p: dict) -> list[Part]:
    """The Arcanist's staff: a gnarled pale shaft with its grain and knots, iron bands, a leather
    grip and a spiked ferrule; at the top four iron prongs curl round a cluster of glowing ice
    crystals."""
    below, above = p.get("below_m", 0.7), p.get("above_m", 1.05)
    top = above
    lo, hi = np.array([-0.24, -0.24, -below - 0.1]), np.array([0.24, 0.24, top + 0.62])
    ctrl = np.array([[0.0, 0.0, -below], [0.008, -0.004, -below * 0.4], [-0.006, 0.006, 0.2],
                     [0.01, 0.002, above * 0.6], [0.0, 0.0, top]])
    pts = W.curve(ctrl, n=10)
    radii = np.linspace(0.025, 0.019, len(pts))

    def shaft(G):
        d = W.swept(G, pts, radii)
        ang = angle(G)
        grain = 0.0016 * np.sin(ang * 13.0 + np.sin(G.Z * 9.0) * 2.0 + np.sin(G.Z * 31.0) * 0.6)
        d = d + grain
        for zk, ak in ((-0.42, 0.5), (0.36, 2.4), (0.71, 4.1)):
            c = np.array([np.cos(ak) * 0.02, np.sin(ak) * 0.02, zk])
            d = K.smin(d, ellipsoid(G.X, G.Y, G.Z, c, (0.014, 0.014, 0.022)), 0.012)
        return d

    def iron(G):
        d = None
        for z, h in ((-below + 0.04, 0.035), (-0.17, 0.012), (0.17, 0.012), (top - 0.1, 0.03)):
            b = ring(G, z, 0.0285, h, 0.002)
            d = b if d is None else np.minimum(d, b)
        d = np.minimum(d, W.cone(G.X, G.Y, G.Z, (0, 0, -below + 0.01), (0, 0, -below - 0.08), 0.022, 0.003))
        for k in range(4):
            a = TAU * k / 4 + 0.3
            u = np.array([np.cos(a), np.sin(a), 0.0])
            prong = W.curve(np.array([u * 0.022 + [0, 0, top - 0.08], u * 0.135 + [0, 0, top + 0.07],
                                      u * 0.16 + [0, 0, top + 0.26], u * 0.065 + [0, 0, top + 0.43]]), n=12)
            pr = W.swept(G, prong, np.linspace(0.016, 0.006, len(prong)))
            d = np.minimum(d, pr)
        return d

    def grip(G):
        return wrapped(G, -0.15, 0.15, 0.0275, pitch=0.026)

    def crystal(G):
        items = [(np.array([0.0, 0.0, top + 0.03]), np.array([0.0, 0.0, top + 0.56]), 0.068)]
        for a, ln, r, tilt in ((0.4, 0.28, 0.038, 0.45), (2.2, 0.24, 0.034, 0.5), (4.0, 0.31, 0.04, 0.4), (5.3, 0.2, 0.028, 0.6)):
            base = np.array([np.cos(a) * 0.035, np.sin(a) * 0.035, top + 0.07])
            dirn = np.array([np.cos(a) * tilt, np.sin(a) * tilt, 1.0])
            items.append((base, base + dirn / np.linalg.norm(dirn) * ln, r))
        return D.crystals(np.full(np.broadcast_shapes(G.X.shape, G.Y.shape, G.Z.shape), 1.0, np.float32), G, items)
    return [Part("shaft", "wood", shaft, lo, hi, 4500, voxel=0.0011),
            Part("iron", "iron", iron, lo, hi, 4000, voxel=0.0011, facet_deg=40),
            Part("grip", "leather", grip, np.array([-0.05, -0.05, -0.2]), np.array([0.05, 0.05, 0.2]), 1400, voxel=0.0009),
            Part("crystal", "frost", crystal, np.array([-0.24, -0.24, top - 0.02]), hi, 2400, voxel=0.001, facet_deg=30)]


def oracle_mace(p: dict) -> list[Part]:
    """The Oracle's mace: a steel haft with gold rings and a cloth-wrapped grip; a head of eight
    pointed flanges round a core like the rays of a sun, each edged in gold, crowned with short
    rays and a glowing gem; a gold pommel. The head sits where the old mace's did (grip/2 + shaft +
    7 cm) and is a little larger than it (flanges reach 13.5 cm), as G-09's oversize asks."""
    g, shaft = p.get("grip_m", 0.2), p.get("shaft_m", 0.42)
    hz = g / 2 + shaft + 0.07                # the head's centre
    k = 1.55                                 # head scale against the first draft's proportions
    hh = 0.085 * k                           # half the head's height
    lo, hi = np.array([-0.17, -0.17, -g / 2 - 0.1]), np.array([0.17, 0.17, hz + 0.24])

    def haft(G):
        return rod(G, -g / 2, hz, 0.019)

    def flange_field(G, grow=0.0, rim=None):
        """The eight flanges; with `rim`, only the band within `rim` of their outer edge."""
        ang = angle(G)
        kk = np.round(ang / (TAU / 8))
        local = ang - kk * TAU / 8
        r = radial(G)
        across = r * np.sin(local)
        t = np.clip((G.Z - (hz - hh)) / (2 * hh), 0, 1)
        reach = k * (0.03 + 0.057 * np.clip(np.sin(np.pi * t), 0, 1) ** 0.7) + grow
        outer = r * np.cos(local) - reach
        plate = np.maximum(np.abs(across) - 0.007 - grow * 0.4, outer)
        plate = np.maximum(plate, np.abs(G.Z - hz) - hh - grow)
        if rim is not None:
            plate = np.maximum(plate, -(outer + rim))
        return plate

    def head(G):
        core = ellipsoid(G.X, G.Y, G.Z, (0, 0, hz), (0.038 * k, 0.038 * k, 0.074 * k))
        collar = ring(G, hz - hh + 0.01, 0.03, 0.016, 0.003)
        return np.minimum(np.minimum(core, flange_field(G)), collar)

    def head_gold(G):
        edge = flange_field(G, 0.002, rim=0.012)
        crown = ring(G, hz + hh - 0.012, 0.032, 0.008, 0.003)
        rays = None
        for kk in range(8):
            a = TAU * (kk + 0.5) / 8
            u = np.array([np.cos(a), np.sin(a), 0.0])
            ray = W.cone(G.X, G.Y, G.Z, u * 0.026 + [0, 0, hz + hh - 0.012], u * 0.075 + [0, 0, hz + hh + 0.025],
                         0.011, 0.002)
            rays = ray if rays is None else np.minimum(rays, ray)
        band = ring(G, hz - hh - 0.012, 0.028, 0.011, 0.002)
        return np.minimum(np.minimum(edge, crown), np.minimum(rays, band))

    def fittings(G):
        rings = np.minimum(ring(G, g / 2 + 0.012, 0.023, 0.01, 0.002), ring(G, -g / 2 - 0.005, 0.023, 0.01, 0.002))
        rings = np.minimum(rings, ring(G, g / 2 + shaft * 0.5, 0.022, 0.008, 0.002))
        pom = facet_ball(G, (0, 0, -g / 2 - 0.05), 0.036, sides=10, rz=0.042)
        return np.minimum(rings, pom)

    def grip(G):
        return wrapped(G, -g / 2 + 0.006, g / 2, 0.021, pitch=0.02, depth=0.0016)

    def gem(G):
        return facet_ball(G, (0, 0, hz + hh + 0.045), 0.028, sides=8, rz=0.045)
    hlo, hhi = np.array([-0.17, -0.17, hz - hh - 0.05]), hi
    return [Part("haft", "steel", haft, lo, hi, 1200, voxel=0.001),
            Part("head", "steel", head, hlo, hhi, 5000, voxel=0.0011, facet_deg=35),
            Part("head_gold", "gold", head_gold, hlo, hhi, 3400, voxel=0.001, facet_deg=40),
            Part("fittings", "gold", fittings, lo, hi, 1000, voxel=0.0009, facet_deg=40),
            Part("grip", "cloth", grip, lo, hi, 1400, voxel=0.0009),
            Part("gem", "holy", gem, hlo, hhi, 700, voxel=0.0009, facet_deg=30)]


def templar_warhammer(p: dict) -> list[Part]:
    """The Templar's warhammer: an ash haft with iron langets down from the head, a leather grip and
    an iron pommel; a head with a flared square face cut in a grid of teeth, a curved back spike, a
    top spike and a gold sun inset on each cheek, riveted. The head sits where the old hammer's did
    (grip/2 + shaft + 6 cm) at about its size (45 cm from face to spike tip)."""
    g, shaft = p.get("grip_m", 0.22), p.get("shaft_m", 0.45)
    hz = g / 2 + shaft + 0.06
    lo, hi = np.array([-0.32, -0.11, -g / 2 - 0.09]), np.array([0.24, 0.11, hz + 0.21])

    def haft(G):
        d = rod(G, -g / 2 - 0.02, hz + 0.02, 0.02)
        # faint, uneven grain (an even groove pattern reads as a fluted column)
        return d + 0.00025 * np.sin(angle(G) * 9.0 + np.sin(G.Z * 17.0) * 1.5 + G.Z * 23.0)

    def head_field(G):
        block = K.superellipse(G.X, G.Y, 0.0, 0.0, 0.1, 0.058, 4.0)
        block = np.maximum(block, np.abs(G.Z - hz) - 0.068)
        flare = 1.0 + 0.2 * np.clip((G.X - 0.1) / 0.08, 0, 1)        # the striking face widens outward
        face = np.maximum(np.maximum(np.abs(G.Y) - 0.06 * flare, np.abs(G.Z - hz) - 0.066 * flare),
                          np.abs(G.X - 0.145) - 0.05)
        teeth = 0.005 * (np.abs(np.sin(G.Y * np.pi / 0.02)) * np.abs(np.sin((G.Z - hz) * np.pi / 0.02))) ** 0.5
        face = np.maximum(face, G.X - (0.195 - teeth))
        beak = W.curve(np.array([[-0.08, 0, hz], [-0.19, 0, hz - 0.008], [-0.29, 0, hz - 0.06]]), n=24)
        spike = W.swept(G, beak, np.linspace(0.046, 0.003, len(beak)))
        top = W.cone(G.X, G.Y, G.Z, (0, 0, hz + 0.06), (0, 0, hz + 0.19), 0.034, 0.003)
        return np.minimum(np.minimum(block, face), np.minimum(spike, top))

    def head(G):
        d = head_field(G)
        riv = [np.array([sx, sy * 0.06, hz + dz]) for sx in (0.068, -0.068) for sy in (1, -1) for dz in (0.048, -0.048)]
        return studs(d, G, riv, 0.0055)

    def langets(G):
        d = None
        for sy in (1.0, -1.0):
            strip = np.maximum(np.maximum(np.abs(G.X) - 0.011, np.abs(G.Y - sy * 0.0205) - 0.003),
                               np.maximum(hz - 0.3 - G.Z, G.Z - hz))
            d = strip if d is None else np.minimum(d, strip)
        riv = [np.array([0.0, sy * 0.0238, z]) for sy in (1, -1) for z in (hz - 0.1, hz - 0.17, hz - 0.24)]
        pz = -g / 2 - 0.045
        pom = facet_ball(G, (0, 0, pz), 0.032, sides=8, rz=0.038)
        return studs(np.minimum(d, pom), G, riv, 0.0036)

    def gold(G):
        out = None
        for sy in (1.0, -1.0):
            s_ = K.sun(G.X, G.Y, G.Z, (0.0, sy * 0.0605, hz), 1, 0.046, 8, 0.0026)
            out = s_ if out is None else np.minimum(out, s_)
        bands = np.minimum(ring(G, hz - 0.085, 0.026, 0.012, 0.002), ring(G, g / 2 + 0.01, 0.024, 0.009, 0.002))
        return np.minimum(out, bands)

    def grip(G):
        return wrapped(G, -g / 2, g / 2, 0.022, pitch=0.022)
    return [Part("haft", "wood", haft, lo, hi, 1600, voxel=0.001),
            Part("head", "steel", head, lo, hi, 5600, voxel=0.0011, facet_deg=40),
            Part("langets", "iron", langets, lo, hi, 2000, voxel=0.0009, facet_deg=40),
            Part("gold", "gold", gold, lo, hi, 1600, voxel=0.0008, facet_deg=40),
            Part("grip", "leather", grip, lo, hi, 1400, voxel=0.0009)]


def zealot_sun_glaive(p: dict) -> list[Part]:
    """The Zealot's glaive: a long haft with gold rings, leather wraps and a spiked butt; a broad
    curved blade with a fuller, rising from a gold sun disc with a glowing centre."""
    below, above, bl = p.get("below_m", 0.75), p.get("above_m", 0.95), p.get("blade_m", 0.7)
    z0 = above - bl + 0.1                    # the blade's base (the sun disc)
    lo, hi = np.array([-0.18, -0.07, -below - 0.12]), np.array([0.2, 0.07, above + 0.14])

    def haft(G):
        return rod(G, -below, z0, 0.019) + 0.00025 * np.sin(angle(G) * 9.0 + np.sin(G.Z * 13.0) * 1.5 + G.Z * 21.0)

    def blade_fn(G):
        # a curved blade: its centreline bends toward +X as it rises; the edge faces +X
        t = np.clip((G.Z - z0) / bl, 0, 1)
        bend = 0.07 * t * t
        Gx = _Scaled(G)
        Gx.X = G.X - bend
        w = lambda tt: 0.05 + 0.025 * np.sin(np.pi * np.clip(tt, 0, 1) * 0.8)   # noqa: E731
        return blade(Gx, z0, bl, w, lambda tt: 0.011 * (1 - 0.3 * tt), point=0.22, nicks=((0.4, 0.07, 1),),
                     fuller=(0.12, 0.6, 0.012, 0.004))

    def gold(G):
        disc = np.maximum(np.sqrt(G.X ** 2 + (G.Z - z0) ** 2) - 0.06, np.abs(G.Y) - 0.012)
        rays = K.sun(G.X, G.Y, G.Z, (0.0, 0.0, z0), 1, 0.1, 12, 0.008)
        rings = None
        for z in (z0 - 0.05, 0.25, -0.25, -below + 0.06):
            b = ring(G, z, 0.023, 0.01, 0.002)
            rings = b if rings is None else np.minimum(rings, b)
        spike = W.cone(G.X, G.Y, G.Z, (0, 0, -below + 0.02), (0, 0, -below - 0.1), 0.02, 0.002)
        return np.minimum(np.minimum(disc, rays), np.minimum(rings, spike))

    def glow(G):
        return np.maximum(np.sqrt(G.X ** 2 + (G.Z - z0) ** 2) - 0.03, np.abs(G.Y) - 0.0145)

    def wraps(G):
        return np.minimum(wrapped(G, -0.18, 0.18, 0.0225, pitch=0.022), wrapped(G, -below + 0.1, -below + 0.25, 0.0225))
    return [Part("haft", "wood", haft, lo, hi, 2000, voxel=0.0011),
            Part("blade", "steel", blade_fn, np.array([-0.12, -0.03, z0 - 0.02]), hi, 5000, voxel=0.001, facet_deg=35),
            Part("gold", "gold", gold, lo, hi, 4200, voxel=0.0009, facet_deg=40),
            Part("glow", "holy", glow, np.array([-0.05, -0.03, z0 - 0.05]), np.array([0.05, 0.03, z0 + 0.05]), 500,
                 voxel=0.0008),
            Part("wraps", "leather", wraps, lo, hi, 1800, voxel=0.0009)]


def zealot_sunbrand(p: dict) -> list[Part]:
    """The Zealot's two-handed sword: a long flame-waved blade with a fuller; a guard of gold sun
    rays round a disc with a glowing centre; a crimson-dyed leather grip; a gold sun pommel."""
    g, L, w = p.get("grip_m", 0.36), p.get("blade_m", 1.15), p.get("blade_width_m", 0.07)
    zg = g / 2 + 0.04
    z0 = zg + 0.04
    lo, hi = np.array([-0.24, -0.06, -g / 2 - 0.13]), np.array([0.24, 0.06, z0 + L + 0.02])

    def hw(t):
        wave = 0.13 * np.sin(t * L / 0.085 * TAU) * np.clip((t - 0.12) / 0.06, 0, 1) * np.clip((0.86 - t) / 0.06, 0, 1)
        return w * (1.0 - 0.22 * t) * (1.0 + wave)

    def blade_fn(G):
        return blade(G, z0, L, hw, lambda t: 0.0115 * (1 - 0.35 * t), point=0.13, fuller=(0.04, 0.55, 0.012, 0.0045))

    def gold(G):
        disc = np.maximum(np.sqrt(G.X ** 2 + (G.Z - zg) ** 2) - 0.05, np.abs(G.Y) - 0.02)
        rays = K.sun(G.X, G.Y, G.Z, (0.0, 0.0, zg), 1, 0.2, 10, 0.012)
        rays = np.maximum(rays, -(G.Z - zg + 0.02 - 0.6 * np.abs(G.X)))     # the rays fan sideways and up
        pz = -g / 2 - 0.06
        pom = np.maximum(np.sqrt(G.X ** 2 + (G.Z - pz) ** 2) - 0.04, np.abs(G.Y) - 0.017)
        pom_rays = K.sun(G.X, G.Y, G.Z, (0.0, 0.0, pz), 1, 0.06, 8, 0.01)
        ferrules = np.minimum(ring(G, g / 2 + 0.004, 0.025, 0.008, 0.002), ring(G, -g / 2 + 0.004, 0.025, 0.008, 0.002))
        return np.minimum(np.minimum(disc, rays), np.minimum(np.minimum(pom, pom_rays), ferrules))

    def glow(G):
        a = np.maximum(np.sqrt(G.X ** 2 + (G.Z - zg) ** 2) - 0.026, np.abs(G.Y) - 0.023)
        b = np.maximum(np.sqrt(G.X ** 2 + (G.Z + g / 2 + 0.06) ** 2) - 0.018, np.abs(G.Y) - 0.02)
        return np.minimum(a, b)

    def grip(G):
        return wrapped(G, -g / 2 + 0.01, g / 2, 0.021, pitch=0.022)
    gh = np.array([0.24, 0.06, z0 + 0.1])
    return [Part("blade", "steel", blade_fn, lo, hi, 6800, voxel=0.0011, facet_deg=35),
            Part("gold", "gold", gold, lo, gh, 4600, voxel=0.0009, facet_deg=40),
            Part("glow", "holy", glow, lo, gh, 700, voxel=0.0008),
            Part("grip", "leather", grip, lo, gh, 1700, voxel=0.0009)]


DESIGNS = {
    "warblade_greatsword": warblade_greatsword,
    "deathsworn_runeblade": deathsworn_runeblade,
    "arcanist_frost_staff": arcanist_frost_staff,
    "oracle_mace": oracle_mace,
    "templar_warhammer": templar_warhammer,
    "zealot_sun_glaive": zealot_sun_glaive,
    "zealot_sunbrand": zealot_sunbrand,
}
