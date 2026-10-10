"""The cloth classes' default sets (backlog G-08): the Arcanist's "Hoarfrost Regalia" and the
Oracle's "Dawnveil Vestments".

Robes are split across slots so pieces mix: the chest piece is the robe's body, sleeves and a skirt
to the knee; the legs piece is an ankle-length underskirt over trousers. Cloth hangs heavy, the
Arcanist's with torn hems, the Oracle's neat.

- Arcanist: a deep pointed hood with a dark lining over a mantle; a two-tier capelet with a collar
  of glowing ice crystals; a wrap-front robe with drooping bell sleeves; a knotted sash with a
  crystal pendant; wrapped gloves; soft boots with turned-down cuffs; a cape rimed with icicles.
- Oracle: a close veil hanging down the back, a dark blindfold, a gold circlet with a sunburst and
  a glowing gem; padded rounded shoulder caps with gold suns; a robe with a high collar, wide
  sleeves and a sun tabard; a twisted gold cord belt with tassels; gloves with gold cuffs;
  slippers with anklets; a glowing halo behind the shoulders.

Materials: "cloth" (primary dye), "trim" (secondary dye), "plate" (metal dye: the gold fittings
take a gold metal dye), "leather", glowing "ice" and "holy" (build_piece.GLOW). Coordinates:
metres, +Z up, the character faces -Y, its left is +X.
"""
from __future__ import annotations

import numpy as np

import armor_deathsworn as D
import armor_kit as K
import armor_warblade as W
from armor_kit import Body, Part, band, below, capsule, ellipsoid, sawtooth, shell, smin, studs, superellipse

UPPER_ARM = {"deltoid", "upperarm", "bicep", "tricep", "elbow"}
LEGS = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor", "patella", "shin", "tibia", "calf",
        "achilles", "malleolus_out", "malleolus_in", "glute", "pelvis"}
NECK_SHOULDERS = {"neck", "trap", "scm", "clavicle", "upper_back", "ribcage", "pec", "deltoid", "scapula", "breast"}


def _empty(G):
    return np.full(np.broadcast_shapes(G.X.shape, G.Y.shape, G.Z.shape), 1.0, np.float32)


def _perp_basis(ax):
    a = np.cross(ax, [0.0, 1.0, 0.0] if abs(ax[1]) < 0.9 else [1.0, 0.0, 0.0])
    a /= np.linalg.norm(a)
    return a, np.cross(ax, a)


# ----------------------------------------------------------------------------- shared shapes

def skirt_field(b: Body, top, hem, rx0, ry0, frx, fry, fold=0.014, torn=True, sides=False, thick=0.0045,
                hem_amp=0.012):
    """A skirt hanging from `top` to an uneven `hem`, flaring with deep folds; split front and back
    (and at both sides with `sides`) below the hips, the splits widening toward the hem."""
    def fn(G):
        t = np.clip((top - G.Z) / (top - hem), 0, 1)
        rx = (rx0 + frx * t + 0.01 * b.fem) * b.S
        ry = (ry0 + fry * t) * b.S
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        folds = (fold * np.sin(ang * 9.0) + 0.4 * fold * np.sin(ang * 17.0 + 0.8 + 3.0 * t)) * t ** 0.8
        d = np.abs(superellipse(G.X, G.Y, 0.0, 0.01, rx, ry, 2.2) + folds) - thick
        d = np.maximum(d, band(G.Z, K._hem_line(ang, hem, amp=hem_amp, tears=torn), top + 0.03))
        w = 0.012 + 0.03 * t
        split = np.abs(G.X) - w
        if sides:
            split = np.minimum(split, np.abs(G.Y - 0.01) - w)
        return np.maximum(d, -np.where(G.Z < top - 0.08, split, 1.0))
    return fn


def robe_body(b: Body, neck_z, belt, inner=0.007, outer=0.0135, top=None):
    """The robe from the neck to the belt over the upper arms, bloused over the belt; the sleeves
    stop at the elbow (the forearm is the sleeve's own part). `top` raises the robe round the neck
    hole up the slope of the shoulders (where nothing else covers them)."""
    names = K._torso_names() | UPPER_ARM

    def fn(G):
        f = G.subset(names)
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        u = np.clip(1.0 - (G.Z - belt) / 0.11, 0, 1) * (G.Z > belt - 0.02)
        blouse = u * (0.006 + 0.004 * np.sin(ang * 16.0 + 0.5))
        loose = 0.006 * np.clip((np.abs(G.X) - 0.13) / 0.06, 0, 1)        # roomier over the upper arms
        d = np.maximum(shell(f - blouse, inner, outer + loose), below(G.Z, neck_z if top is None else top))
        neck = np.sqrt(G.X ** 2 + (G.Y - 0.01) ** 2) - 0.09
        d = np.maximum(d, -np.where(G.Z > neck_z - 0.06, neck, 1.0))
        for sx in (1.0, -1.0):
            el = b.j["elbow_l"] * np.array([sx, 1, 1])
            wr = b.j["wrist_l"] * np.array([sx, 1, 1])
            ax = (wr - el) / np.linalg.norm(wr - el)
            along = (G.X - el[0]) * ax[0] + (G.Y - el[1]) * ax[1] + (G.Z - el[2]) * ax[2]
            d = np.where(G.X * sx > 0.16, np.maximum(d, along - 0.015), d)
        return np.maximum(d, belt - 0.04 - G.Z)
    return fn


def bell_sleeve(b: Body, side: str, r0=0.052, r1=0.11, extra=0.05, torn=True, droop=0.035):
    """A sleeve from the elbow widening into a bell past the wrist, drooping as it widens, with an
    uneven (or `torn`) edge. Returns (field, lo, hi)."""
    sx = 1.0 if side == "l" else -1.0
    el, wr = b.j[f"elbow_{side}"], b.j[f"wrist_{side}"]
    L = float(np.linalg.norm(wr - el))
    ax = (wr - el) / L
    down = np.array([0.0, 0.0, -1.0]) - ax * (-ax[2])
    down /= np.linalg.norm(down)
    e1, e2 = _perp_basis(ax)
    lo = np.minimum(el, wr) - 0.2
    hi = np.maximum(el, wr) + 0.2

    def fn(G):
        qx, qy, qz = G.X - el[0], G.Y - el[1], G.Z - el[2]
        along = qx * ax[0] + qy * ax[1] + qz * ax[2]
        t = np.clip(along / L, 0, 1.4)
        sag = droop * t * t
        px = qx - ax[0] * along - down[0] * sag
        py = qy - ax[1] * along - down[1] * sag
        pz = qz - ax[2] * along - down[2] * sag
        radial = np.sqrt(px * px + py * py + pz * pz)
        ang = np.arctan2(px * e2[0] + py * e2[1] + pz * e2[2], px * e1[0] + py * e1[1] + pz * e1[2])
        r = (r0 + (r1 - r0) * np.clip(t, 0, 1.2) ** 1.6) * b.S + 0.004 * np.sin(ang * 7.0) * t
        end = L + extra + (0.018 * np.sin(ang * 5.0 + sx) + 0.008 * np.sin(ang * 13.0) if torn else 0.006 * np.sin(ang * 3.0))
        return np.maximum(np.abs(radial - r) - 0.0035, np.maximum(-along - 0.02, along - end)), along, end, radial, r
    return fn, lo, hi


def cloth_glove(b: Body, side: str, cuff_len=0.12, fingerless=True, wraps=True):
    """A soft glove up the forearm, fingerless or whole, with cloth wraps spiralling up the cuff.
    Returns (field, lo, hi)."""
    hand_names = {f"palm_{side}", f"thumb_{side}"} | {f"finger{i}_{side}" for i in range(4)} | \
        {"wrist", "forearm", "forearm_mass"}
    wr, end = b.j[f"wrist_{side}"], b.j[f"hand_end_{side}"]
    el = b.j[f"elbow_{side}"]
    ax = (end - wr) / np.linalg.norm(end - wr)
    fa = (wr - el) / np.linalg.norm(wr - el)
    e1, e2 = _perp_basis(fa)
    lo = np.minimum(wr - fa * (cuff_len + 0.02), end) - 0.1
    hi = np.maximum(wr - fa * (cuff_len + 0.02), end) + 0.1

    def fn(G):
        f = G.subset(hand_names)
        qx, qy, qz = G.X - wr[0], G.Y - wr[1], G.Z - wr[2]
        along = qx * fa[0] + qy * fa[1] + qz * fa[2]
        u = qx * ax[0] + qy * ax[1] + qz * ax[2]
        d = shell(f, 0.0008, 0.0034)
        if fingerless:
            d = np.maximum(d, u - 0.112 * b.S)
        if wraps:   # wraps spiralling up the forearm, each band overlapping the next
            ang = np.arctan2(qx * e2[0] + qy * e2[1] + qz * e2[2], qx * e1[0] + qy * e1[1] + qz * e1[2])
            spiral = sawtooth(-along + ang / (2 * np.pi) * 0.016, 0.016)
            d = np.where(along < 0.0, shell(f - 0.0015 * spiral, 0.002, 0.0055), d)
        return np.maximum(d, -along - cuff_len)
    return fn, lo, hi


def soft_boot(b: Body, side: str, height=0.22, pointed=0.012):
    """A soft boot to mid-calf with a slightly pointed toe and a thicker sole; returns the boot,
    a turned-down cuff field and bounds."""
    names = {"heel", "foot", "instep", "toes", "malleolus_out", "malleolus_in", "achilles", "shin", "calf", "tibia"}
    a, t = b.j[f"ankle_{side}"], b.j[f"toe_{side}"]
    lo = np.minimum(a, t) - np.array([0.1, 0.16, 0.02])
    hi = np.maximum(a, t) + np.array([0.1, 0.16, height + 0.06])
    top = a[2] + height
    tc = t + np.array([0.0, -0.006, 0.008])

    def foot_field(G):
        f = G.subset(names)
        if pointed > 0:
            f = smin(f, ellipsoid(G.X, G.Y, G.Z, tc + np.array([0, -pointed * 0.4, 0]),
                                  (0.036, 0.04 + pointed * 0.4, 0.022)), 0.02)
        return f

    def boot(G):
        f = foot_field(G)
        d = np.maximum(shell(f, 0.0015, 0.0062 + 0.004 * (G.Z < 0.014)), below(G.Z, top))
        return np.maximum(d, -G.Z)

    def cuff(G):
        f = foot_field(G)
        ang = np.arctan2(G.X - a[0], G.Y - a[1])
        hem = top - 0.05 + 0.006 * np.sin(ang * 6.0)
        return np.maximum(shell(f, 0.006, 0.011), band(G.Z, hem, top + 0.004))
    return boot, cuff, lo, hi


def capelet(b: Body, inner, outer, hem_drop, reach, torn=True, amp=0.012):
    """A short cape over the shoulders (a mantle tier): a layer over the neck and shoulders down to
    a hem `hem_drop` below the top of the chest, reaching `reach` from the body's axis."""
    zb = b.z("chest_top") - hem_drop
    zt = b.z("neck") + 0.06

    def hem_z(G):
        return K._hem_line(np.arctan2(G.X, G.Y), zb, amp=amp, tears=torn)

    def base(G):
        f = G.subset(NECK_SHOULDERS)
        folds = 0.003 * np.sin(np.arctan2(G.X, G.Y) * 18.0) * np.clip((zt - G.Z) / (zt - zb), 0, 1)
        d = np.maximum(shell(f - folds, inner, outer), band(G.Z, hem_z(G), zt))
        return np.maximum(d, edge(G)), f

    def edge(G):
        # a rounded outer edge that curves down over the shoulder (a vertical cut looked boxy)
        side = G.X ** 2 / (G.X ** 2 + G.Y ** 2 + 1e-6)          # only at the sides: front and back keep the hem
        return np.sqrt(G.X ** 2 + (G.Y * 1.15) ** 2 + side * ((G.Z - (b.z("chest_top") + 0.06)) * 1.4) ** 2) - reach

    def layer(G):
        return base(G)[0]

    def trim(G):
        d, f = base(G)
        return np.maximum(np.maximum(shell(f, inner - 0.001, outer + 0.0015), np.abs(G.Z - hem_z(G) - 0.012) - 0.011),
                          edge(G) - 0.002)
    return layer, trim


# ----------------------------------------------------------------------------- Arcanist

def arcanist_hood(b: Body) -> list[Part]:
    """A deep hood with a peak falling back from the crown, soft folds running back from the face, a
    thick rolled edge round the face opening and a dark lining that shadows the face; below it a
    mantle over the neck and shoulders with a torn hem."""
    s, hz = b.hs, b.hz
    cy = 0.012 * s
    zc = hz + 0.098 * s
    lo = np.array([-0.16, cy - 0.17, hz - 0.08])
    hi = np.array([0.16, cy + 0.24, hz + 0.3 * s])

    def outer_field(G):
        d = ellipsoid(G.X, G.Y, G.Z, (0.0, cy + 0.008 * s, hz + 0.148 * s), (0.112 * s, 0.128 * s, 0.122 * s))
        peak = W.cone(G.X, G.Y, G.Z, (0.0, cy + 0.06 * s, hz + 0.2 * s), (0.0, cy + 0.185 * s, hz + 0.128 * s),
                      0.055 * s, 0.007 * s)
        d = smin(d, peak, 0.03)
        # down round the neck into the mantle, so no ring opens between them
        tube = np.maximum(superellipse(G.X, G.Y, 0.0, cy + 0.012 * s, 0.09 * s, 0.098 * s, 2.2),
                          band(G.Z, hz - 0.075 * s, hz + 0.1 * s))
        d = smin(d, tube, 0.03)
        ang = np.arctan2(G.X, G.Z - hz - 0.1 * s)
        folds = 0.004 * np.sin(ang * 7.0) * np.clip((G.Y - cy + 0.06) / 0.12, 0, 1)
        return d - folds

    def opening(G):
        e = np.sqrt((G.X / (0.075 * s)) ** 2 + ((G.Z - zc) / (0.118 * s)) ** 2) - 1.0
        return np.maximum(e * 0.075 * s, G.Y - (cy - 0.03))

    def hood(G):
        outer = outer_field(G)
        op = opening(G)
        d = np.maximum(np.maximum(shell(outer, -0.006, 0.0), -op), hz - 0.075 * s - G.Z)
        rim = np.maximum(np.maximum(np.abs(outer + 0.003) - 0.0078, np.abs(op) - 0.0095), G.Y - (cy - 0.02))
        return np.minimum(d, np.maximum(rim, hz - 0.075 * s - G.Z))

    def lining(G):
        outer = outer_field(G)
        d = np.maximum(shell(outer, -0.019, -0.014), -(opening(G) + 0.004))
        return np.maximum(d, hz - 0.03 * s - G.Z)

    mantle, mantle_trim = capelet(b, 0.017, 0.023, 0.13, 0.25, torn=True, amp=0.014)
    mlo = np.array([-0.3, -0.26, b.z("chest_top") - 0.2])
    mhi = np.array([0.3, 0.26, b.z("neck") + 0.1])
    return [Part("hood", "cloth", hood, lo, hi, 4800, skin="head", voxel=0.0018),
            Part("hood_lining", "leather", lining, lo, hi, 700, skin="head", voxel=0.0025),
            Part("hood_mantle", "cloth", mantle, mlo, mhi, 3600, voxel=0.0022),
            Part("hood_mantle_trim", "trim", mantle_trim, mlo, mhi, 1400, voxel=0.0022)]


def arcanist_capelet(b: Body) -> list[Part]:
    """Two short capelets over the shoulders, the upper one shorter, each with a trimmed torn hem,
    and a collar of ice crystals rising from the shoulders, leaning out and back."""
    lo = np.array([-0.34, -0.28, b.z("chest_top") - 0.25])
    hi = np.array([0.34, 0.3, b.z("neck") + 0.25])
    low_layer, low_trim = capelet(b, 0.027, 0.033, 0.19, 0.315, torn=True, amp=0.016)
    up_layer, up_trim = capelet(b, 0.037, 0.043, 0.1, 0.295, torn=True, amp=0.012)
    parts = [Part("capelet_lower", "cloth", low_layer, lo, hi, 2600, voxel=0.0022),
             Part("capelet_lower_trim", "trim", low_trim, lo, hi, 1000, voxel=0.0022),
             Part("capelet_upper", "cloth", up_layer, lo, hi, 2200, voxel=0.0022),
             Part("capelet_upper_trim", "trim", up_trim, lo, hi, 900, voxel=0.0022)]
    for side, sx in (("l", 1.0), ("r", -1.0)):
        items = []
        for dx, dy, ln, r in ((0.075, 0.035, 0.155, 0.016), (0.115, 0.02, 0.12, 0.013), (0.05, 0.06, 0.105, 0.012)):
            base = np.array([sx * dx * b.S, dy * b.S, b.z("chest_top") + 0.035])
            base = K.on_surface_dir(lambda P: P.subset(NECK_SHOULDERS) - 0.04, [base], (0, 0, 1.0), sink=0.01,
                                    shape=b.shape)[0]
            dirn = np.array([sx * 0.45, 0.35, 1.0])
            dirn /= np.linalg.norm(dirn)
            items.append((base, base + dirn * ln * b.S, r * b.S))

        def ice(G, items=items):
            return D.crystals(_empty(G), G, items)
        parts.append(Part(f"collar_ice_{side}", "ice", ice, lo, hi, 650, skin=f"clavicle_{side}", voxel=0.0013,
                          facet_deg=30))
    return parts


def arcanist_robe(b: Body) -> list[Part]:
    """Chest slot: a robe wrapped right over left (a raised edge running from the left collarbone to
    the right hip, trimmed), bloused over the belt, with bell sleeves that droop and end torn past
    the wrists, and a skirt to the knee with deep folds and a torn hem, split front and back."""
    z = b.z
    neck_z = z("chest_top") + 0.02
    belt = z("pelvis") + 0.06
    hem = z("knee_l") - 0.05
    lo = np.array([-0.75, -0.34, hem - 0.08])
    hi = np.array([0.75, 0.32, neck_z + 0.06])
    body = robe_body(b, neck_z, belt)
    skirt = skirt_field(b, belt, hem, 0.18, 0.14, 0.1, 0.08, fold=0.016, torn=True)
    x_top, x_bot = 0.075, -0.1

    def wrap_x(G):
        u = np.clip((neck_z - G.Z) / (neck_z - belt), 0, 1)
        return x_top + (x_bot - x_top) * u

    def robe(G):
        d = smin(np.where(G.Z > belt - 0.02, body(G), 1.0), skirt(G), 0.025)
        # the overlapping panel stands proud of the one beneath, in front, above the belt
        over = (G.Y < -0.02) * (G.Z > belt - 0.02) * K._sig((wrap_x(G) - G.X) / 0.002)
        return d - 0.0035 * over

    def trim(G):
        d = smin(np.where(G.Z > belt - 0.02, body(G), 1.0), skirt(G), 0.025)
        raised = np.maximum(d - 0.0045, -d - 0.001)
        edge = np.where((G.Y < -0.02) & (G.Z > belt - 0.03), np.abs(G.X - wrap_x(G) + 0.011) - 0.011, 1.0)
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        hz_ = K._hem_line(ang, hem, amp=0.012, tears=False)
        hem_band = np.where(G.Z < belt - 0.1, np.abs(G.Z - (hz_ + 0.03)) - 0.02, 1.0)
        return np.maximum(raised, np.minimum(edge, hem_band))

    parts = [Part("robe", "cloth", robe, lo, hi, 9000, voxel=0.0025),
             Part("robe_trim", "trim", trim, lo, hi, 2600, voxel=0.002)]
    for side in ("l", "r"):
        fn, slo, shi = bell_sleeve(b, side, r0=0.052, r1=0.115, extra=0.06, torn=True)

        def sleeve(G, fn=fn):
            return fn(G)[0]

        def cuff(G, fn=fn):
            d, along, end, radial, r = fn(G)
            return np.maximum(np.abs(radial - r) - 0.005, np.abs(along - (end - 0.028)) - 0.014)
        parts.append(Part(f"sleeve_{side}", "cloth", sleeve, slo, shi, 2800, voxel=0.0022))
        parts.append(Part(f"sleeve_cuff_{side}", "trim", cuff, slo, shi, 900, voxel=0.0022))
    return parts


def arcanist_wraps(b: Body) -> list[Part]:
    parts = []
    for side in ("l", "r"):
        fn, lo, hi = cloth_glove(b, side, cuff_len=0.12, fingerless=True, wraps=True)
        parts.append(Part(f"glove_{side}", "leather", fn, lo, hi, 4000, skin="transfer", voxel=0.0013))
    return parts


def arcanist_sash(b: Body) -> list[Part]:
    """A sash wound round the waist, knotted at the front left, two tails hanging to mid-thigh with
    torn ends, and an ice crystal pendant on a cord from the knot."""
    zb = b.z("pelvis") + 0.07
    S = b.S
    fy = -0.15 * S
    kx = 0.06 * S
    lo = np.array([-0.3, -0.3, zb - 0.36])
    hi = np.array([0.3, 0.3, zb + 0.07])

    def sash(G):
        f = G.subset(K._torso_names())
        ang = np.arctan2(G.X, -G.Y)
        folds = 0.002 * np.sin((G.Z - zb) * 260.0 + ang * 3.0)
        d = np.maximum(shell(f - folds, 0.017, 0.028), np.abs(G.Z - zb) - 0.028)
        knot = ellipsoid(G.X, G.Y, G.Z, (kx, fy - 0.03, zb), (0.028, 0.02, 0.03))
        return smin(d, knot, 0.01)

    def tails(G):
        out = None
        for dx, ln, tilt in ((0.0, 0.3, 0.01), (0.03, 0.24, 0.025)):
            t = np.clip((zb - 0.02 - G.Z) / ln, 0, 1)
            x0 = kx + dx + tilt * t
            y0 = fy - 0.04 - 0.035 * t + 0.004 * np.sin(G.Z * 60.0)
            end = zb - 0.02 - ln + 0.025 * (0.5 + 0.5 * np.sin((G.X - x0) * 500.0))
            d = np.maximum(np.abs(G.Y - y0) - 0.003, np.abs(G.X - x0) - (0.022 + 0.012 * t))
            d = np.maximum(d, band(G.Z, end, zb - 0.01))
            out = d if out is None else np.minimum(out, d)
        return out

    def pendant(G):
        top = np.array([kx - 0.012, fy - 0.045, zb - 0.02])
        bot = np.array([kx - 0.014, fy - 0.05, zb - 0.07])
        cord = capsule(G.X, G.Y, G.Z, top, bot, 0.0015)
        return np.minimum(cord, D.crystals(_empty(G), G, [(bot, bot + np.array([0, -0.004, -0.055]), 0.009)]))
    return [Part("sash", "trim", sash, lo, hi, 1500, voxel=0.0018, skin="pelvis"),
            Part("sash_tails", "trim", tails, lo, hi, 900, voxel=0.0018),
            Part("sash_pendant", "ice", pendant, lo, hi, 400, voxel=0.0012, skin="pelvis")]


def arcanist_underskirt(b: Body) -> list[Part]:
    """Legs: cloth trousers to the ankle and an underskirt from the hips to the ankles, split front
    and back, torn at the hem, with a trimmed hem band."""
    z = b.z
    top = z("pelvis") + 0.03
    hem = z("ankle_l") + 0.08
    lo = np.array([-0.4, -0.36, z("ankle_l") - 0.04])
    hi = np.array([0.4, 0.34, top + 0.06])
    sk = skirt_field(b, top, hem, 0.165, 0.13, 0.12, 0.09, fold=0.017, torn=True, hem_amp=0.016)

    def trousers(G):
        f = G.subset(LEGS)
        return np.maximum(shell(f, 0.0015, 0.008), band(G.Z, z("ankle_l") - 0.01, z("pelvis") - 0.05))

    def trim(G):
        d = sk(G)
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        hz_ = K._hem_line(ang, hem, amp=0.016, tears=False)
        return np.maximum(d - 0.0015, np.abs(G.Z - (hz_ + 0.04)) - 0.022)   # the skirt, thicker, over a band
    return [Part("trousers", "cloth", trousers, lo, hi, 2800, voxel=0.0025),
            Part("underskirt", "cloth", sk, lo, hi, 7000, voxel=0.0025),
            Part("underskirt_trim", "trim", trim, lo, hi, 2200, voxel=0.0022)]


def arcanist_boots(b: Body) -> list[Part]:
    parts = []
    for side in ("l", "r"):
        boot, cuff, lo, hi = soft_boot(b, side, height=0.24, pointed=0.014)
        parts.append(Part(f"boot_{side}", "leather", boot, lo, hi, 2200, skin="transfer", voxel=0.0015))
        parts.append(Part(f"boot_cuff_{side}", "trim", cuff, lo, hi, 800, skin="transfer", voxel=0.0015))
    return parts


def arcanist_frost_cape(b: Body) -> list[Part]:
    """A long cape hanging clear of the back in deep folds, torn at the hem, with icicles hanging
    from its lower edge."""
    z = b.z
    top = z("chest_top") + 0.01
    bottom = z("ankle_l") + 0.16
    lo = np.array([-0.5, -0.2, bottom - 0.14])
    hi = np.array([0.5, 0.55, top + 0.06])

    def sheet(G):
        t = np.clip((top - G.Z) / (top - bottom), 0, 1)
        y = (0.15 + 0.29 * t * t) * b.S + (0.022 * np.sin(G.X * 28.0 + 0.6 * np.sin(G.Z * 9.0)) +
                                           0.008 * np.sin(G.X * 67.0 + 1.1)) * (0.2 + t)
        return y, t

    def hem_of(G):
        return K._hem_line(G.X * 6.0, bottom, amp=0.02)

    def cape(G):
        f = G.subset(K._torso_names() | {"deltoid"})
        drape = np.maximum(shell(f, 0.026, 0.034), np.abs(G.X) - 0.2 * b.S)
        y, t = sheet(G)
        half_w = (0.22 + 0.13 * t) * b.S
        s_ = np.maximum(np.abs(G.Y - y) - 0.0055, np.abs(G.X) - half_w)
        upper = np.where(G.Y > 0.05, drape, 1.0)
        d = smin(np.where(G.Z > z("chest") + 0.05, upper, 1.0), np.where(G.Z < z("chest") + 0.12, s_, 1.0), 0.06)
        d = np.maximum(d, band(G.Z, hem_of(G), top))
        return np.maximum(d, -G.Y - 0.02)

    def frost(G):
        # icicles every few centimetres along the hem, of uneven length, hanging straight down
        items = []
        for k, x in enumerate(np.linspace(-0.3 * b.S, 0.3 * b.S, 15)):
            zz = float(K._hem_line(np.array(x * 6.0), bottom, amp=0.02)) + 0.006
            P = K._Pts(np.array([[x, 0.0, zz]]))
            yy = float(sheet(P)[0][0])
            ln = 0.03 + 0.03 * (0.5 + 0.5 * np.sin(k * 2.3))
            items.append((np.array([x, yy, zz + 0.004]), np.array([x, yy + 0.004, zz - ln]), 0.0055))
        return D.crystals(_empty(G), G, items)
    return [Part("cape", "cloth", cape, lo, hi, 6500, voxel=0.0025),
            Part("cape_frost", "ice", frost, np.array([-0.4, 0.1, bottom - 0.12]), np.array([0.4, 0.55, bottom + 0.06]),
                 1500, voxel=0.0013, facet_deg=30)]


# ----------------------------------------------------------------------------- Oracle

def oracle_veil(b: Body) -> list[Part]:
    """A close veil over the head, open round the face and hanging down the back to the shoulder
    blades; a dark blindfold over the eyes; a gold circlet round the brow carrying a sunburst with a
    glowing gem."""
    s, hz = b.hs, b.hz
    cy = 0.008 * s
    zc = hz + 0.1 * s
    eye_z = hz + 0.12 * s
    cz = hz + 0.172 * s
    lo = np.array([-0.15, cy - 0.16, b.z("chest_top") - 0.16])
    hi = np.array([0.15, cy + 0.24, hz + 0.33 * s])

    def cap_field(G):
        return ellipsoid(G.X, G.Y, G.Z, (0.0, cy + 0.004 * s, hz + 0.152 * s), (0.095 * s, 0.11 * s, 0.106 * s))

    def outer_field(G):
        # the cap, and below it the veil falling past the ears to the jaw, widening a little
        t = np.clip((hz + 0.12 * s - G.Z) / (0.14 * s), 0, 1)
        fall = np.maximum(superellipse(G.X, G.Y, 0.0, cy + 0.01 * s, (0.095 + 0.012 * t) * s, (0.108 + 0.01 * t) * s, 2.3),
                          band(G.Z, hz + 0.02 * s, hz + 0.15 * s))
        d = smin(cap_field(G), fall, 0.02)
        ang = np.arctan2(G.X, G.Y - cy)
        return d - 0.0028 * np.sin(ang * 11.0) * t

    def opening(G):
        e = np.sqrt((G.X / (0.069 * s)) ** 2 + ((G.Z - zc) / (0.102 * s)) ** 2) - 1.0
        return np.maximum(e * 0.069 * s, G.Y - (cy - 0.03))

    def veil(G):
        outer = outer_field(G)
        rim = hz + 0.02 * s + 0.06 * s * np.clip((G.Y - cy) / (0.1 * s), 0, 1)   # rising toward the back, clear of the nape
        return np.maximum(np.maximum(shell(outer, -0.004, 0.0), -opening(G)), rim - G.Z)

    def veil_back(G):
        # the hanging part behind: a sheet falling from the back of the head to the shoulder blades
        top = hz + 0.1 * s
        bot = b.z("chest_top") - 0.12
        t = np.clip((top - G.Z) / (top - bot), 0, 1)
        y = cy + (0.125 + 0.05 * t) * s + 0.004 * np.sin(G.X * 70.0) * t    # behind the cap, clear of the neck
        hw = (0.085 + 0.07 * t) * s
        hem = bot + 0.01 * np.sin(G.X * 40.0)
        return np.maximum(np.maximum(np.abs(G.Y - y) - 0.0035, np.abs(G.X) - hw), band(G.Z, hem, top + 0.02))

    def blindfold(G):
        # a band round the head just in front of the eyes and over the nose's bridge, flat across
        # the front, passing under the veil at the sides
        ring = superellipse(G.X, G.Y, 0.0, cy - 0.003 * s, 0.086 * s, 0.107 * s, 2.6)
        d = np.maximum(np.abs(ring - 0.002) - 0.002, np.abs(G.Z - eye_z - 0.002 * s) - 0.0115 * s)
        return np.maximum(d, G.Y - 0.02)

    def circlet(G):
        outer = cap_field(G)
        d = np.maximum(shell(outer, -0.001, 0.0042), np.abs(G.Z - cz) - 0.0055 * s)
        front = outer_front()
        disc = np.maximum(np.sqrt(G.X ** 2 + (G.Z - cz - 0.01 * s) ** 2) - 0.017 * s, np.abs(G.Y - front) - 0.004)
        d = np.minimum(d, disc)
        rays = []
        for k in range(9):
            a = np.radians(-80 + 20 * k)
            dirn = np.array([np.sin(a), -0.15, np.cos(a)])
            dirn /= np.linalg.norm(dirn)
            base = np.array([0.0, front, cz + 0.01 * s]) + dirn * 0.012 * s
            ln = (0.042 if k % 2 == 0 else 0.03) * s * (1.25 if k == 4 else 1.0)
            rays.append((base, base + dirn * ln, 0.0045 * s, 0.0008))
        return W.spikes(d, G, rays)

    def outer_front():
        return float(cy + 0.004 * s - 0.11 * s * np.sqrt(max(0.0, 1.0 - ((cz - hz - 0.152 * s) / (0.106 * s)) ** 2))) - 0.004

    def gem(G):
        return ellipsoid(G.X, G.Y, G.Z, (0.0, outer_front() - 0.006, cz + 0.01 * s), (0.008 * s, 0.005, 0.009 * s))
    return [Part("veil", "trim", veil, lo, hi, 4200, skin="head", voxel=0.0018),
            Part("veil_back", "trim", veil_back, lo, hi, 1400, skin="chest", voxel=0.0018),   # moves with the upper back
            Part("blindfold", "leather", blindfold, lo, hi, 1600, skin="head", voxel=0.0015),
            Part("circlet", "plate", circlet, lo, hi, 2200, skin="head", voxel=0.0013, facet_deg=40),
            Part("circlet_gem", "holy", gem, lo, hi, 300, skin="head", voxel=0.0012)]


def oracle_shoulder_caps(b: Body) -> list[Part]:
    """Padded, quilted shoulder caps with a gold rolled rim and a gold sun on the outside of each."""
    parts = []
    for side, sx in (("l", 1.0), ("r", -1.0)):
        sh, el = b.j[f"shoulder_{side}"], b.j[f"elbow_{side}"]
        ax = (el - sh) / np.linalg.norm(el - sh)
        c = sh + np.array([sx * 0.014, 0.0, 0.036]) * b.S
        R = np.array([0.106, 0.116, 0.098]) * b.S
        lo, hi = c - 0.2, c + 0.2

        def along_of(G, c=c, ax=ax):
            return (G.X - c[0]) * ax[0] + (G.Y - c[1]) * ax[1] + (G.Z - c[2]) * ax[2]

        def dome_of(G, c=c, R=R):
            ang = np.arctan2(G.Y - c[1], G.Z - c[2])
            quilt = 0.0022 * (0.5 + 0.5 * np.cos(ang * 10.0)) ** 2
            return ellipsoid(G.X, G.Y, G.Z, c, R) + quilt

        def inner_cut(G, c=c, sx=sx):
            return (c[0] - sx * 0.05) * sx - G.X * sx

        def cap(G, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut):
            d = np.maximum(shell(dome_of(G), -0.008, 0.0), along_of(G) - 0.05)
            return np.maximum(d, inner_cut(G))

        def gold(G, c=c, sx=sx, R=R, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut):
            rim = np.maximum(K.tube(dome_of(G) + 0.003, along_of(G) - 0.05, 0.0055), inner_cut(G) - 0.004)
            sc = c + np.array([sx * (R[0] + 0.004), 0.0, -0.004])
            disc = K.sun(G.X, G.Y, G.Z, sc, 0, 0.032 * b.S, 10, 0.0035)
            return np.minimum(rim, disc)
        bone = f"upperarm_{side}"
        parts.append(Part(f"cap_{side}", "trim", cap, lo, hi, 3200, skin=bone, voxel=0.0016))
        parts.append(Part(f"cap_gold_{side}", "plate", gold, lo, hi, 1600, skin=bone, voxel=0.0014, facet_deg=40))
    return parts


def oracle_robe(b: Body) -> list[Part]:
    """Chest slot: a robe with wide, neat bell sleeves and a skirt to the knee, a high standing
    collar open at the throat, and a tabard over it front and back, ending in a point, with a
    gold sun on the chest and gold edging."""
    z = b.z
    neck_z = z("chest_top") + 0.02
    belt = z("pelvis") + 0.06
    hem = z("knee_l") - 0.05
    lo = np.array([-0.75, -0.34, hem - 0.08])
    hi = np.array([0.75, 0.32, z("neck") + 0.1])
    body = robe_body(b, neck_z, belt, top=z("neck") - 0.005)
    skirt = skirt_field(b, belt, hem, 0.18, 0.14, 0.09, 0.07, fold=0.012, torn=False, hem_amp=0.006)
    S = b.S

    def robe(G):
        return smin(np.where(G.Z > belt - 0.02, body(G), 1.0), skirt(G), 0.025)

    def collar(G):
        zb, zt = z("chest_top") - 0.015, z("neck") - 0.005     # over 4 cm under the jaw, so a bowed head stays clear
        t = np.clip((G.Z - zb) / (zt - zb), 0, 1)
        ring = superellipse(G.X, G.Y, 0.0, 0.008, (0.074 + 0.012 * t) * S, (0.07 + 0.01 * t) * S, 2.4)
        d = np.maximum(np.abs(ring) - 0.0042, band(G.Z, zb, zt))
        v = np.maximum(np.abs(G.X) - (0.012 + 0.35 * np.clip(G.Z - zb, 0, None)), G.Y)     # open at the throat
        return np.maximum(d, -v)

    def tabard_field(G, grow=0.0, thick=0.0):
        """The tabard: over the chest and back above the belt, then a panel front and back to a
        point; `grow` moves its outline, `thick` its faces."""
        f = G.subset(K._torso_names())
        upper = np.maximum(shell(f, 0.0145 - thick, 0.0195 + thick), band(G.Z, belt - 0.01 - grow, neck_z - 0.02 + grow))
        upper = np.maximum(upper, np.abs(G.X) - 0.09 * S - grow)
        top = belt - 0.01
        point = hem - 0.03
        t = np.clip((top - G.Z) / (top - point), 0, 1)
        out = []
        for sgn in (-1.0, 1.0):
            y = sgn * ((0.165 if sgn < 0 else 0.15) * S + 0.025 * t)
            hw = 0.09 * S * (1.0 - np.clip((t - 0.82) / 0.18, 0, 1) * 0.85) + grow
            panel = np.maximum(np.abs(G.Y - y) - 0.0035 - thick, np.abs(G.X) - hw)
            out.append(np.maximum(panel, band(G.Z, point - grow, top + 0.02)))
        return np.minimum(upper, np.minimum(out[0], out[1]))

    def tabard(G):
        return tabard_field(G)

    def gold(G):
        # a gold edge round the tabard's outline, a little proud of its faces, and the chest sun
        edge = np.maximum(tabard_field(G, 0.0, 0.0012), -tabard_field(G, -0.008, 0.004))
        f = G.subset(K._torso_names())
        c = (0.0, -0.19 * S, z("chest") - 0.01)
        emblem = np.maximum(shell(f, 0.0185, 0.0235), K.sun(G.X, G.Y, G.Z, c, 1, 0.06 * S, 12, 0.08))
        return np.minimum(edge, emblem)

    parts = [Part("robe", "cloth", robe, lo, hi, 8000, voxel=0.0025),
             Part("robe_collar", "trim", collar, lo, hi, 1400, voxel=0.0018),
             Part("tabard", "trim", tabard, lo, hi, 3200, voxel=0.0022),
             Part("tabard_gold", "plate", gold, lo, hi, 2200, voxel=0.0016, facet_deg=40)]
    for side in ("l", "r"):
        fn, slo, shi = bell_sleeve(b, side, r0=0.052, r1=0.1, extra=0.035, torn=False, droop=0.03)

        def sleeve(G, fn=fn):
            return fn(G)[0]

        def cuff(G, fn=fn):
            d, along, end, radial, r = fn(G)
            return np.maximum(np.abs(radial - r) - 0.0048, np.abs(along - (end - 0.02)) - 0.012)
        parts.append(Part(f"sleeve_{side}", "cloth", sleeve, slo, shi, 2800, voxel=0.0022))
        parts.append(Part(f"sleeve_cuff_{side}", "plate", cuff, slo, shi, 800, voxel=0.0018, facet_deg=40))
    return parts


def oracle_gloves(b: Body) -> list[Part]:
    parts = []
    for side in ("l", "r"):
        fn, lo, hi = cloth_glove(b, side, cuff_len=0.07, fingerless=False, wraps=False)
        wr, el = b.j[f"wrist_{side}"], b.j[f"elbow_{side}"]
        fa = (wr - el) / np.linalg.norm(wr - el)
        hand_names = {"wrist", "forearm", "forearm_mass"}

        def cuff(G, wr=wr, fa=fa, hand_names=hand_names):
            f = G.subset(hand_names)
            along = (G.X - wr[0]) * fa[0] + (G.Y - wr[1]) * fa[1] + (G.Z - wr[2]) * fa[2]
            return np.maximum(shell(f, 0.0035, 0.0085), np.abs(along + 0.045) - 0.012)
        parts.append(Part(f"glove_{side}", "trim", fn, lo, hi, 3000, skin="transfer", voxel=0.0013))
        parts.append(Part(f"glove_cuff_{side}", "plate", cuff, lo, hi, 900, skin="transfer", voxel=0.0013,
                          facet_deg=40))
    return parts


def oracle_cord(b: Body) -> list[Part]:
    """A twisted gold cord round the waist, knotted at the front left with two tasselled ends."""
    zb = b.z("pelvis") + 0.065
    S = b.S
    fy = -0.15 * S
    lo = np.array([-0.3, -0.3, zb - 0.22])
    hi = np.array([0.3, 0.3, zb + 0.05])

    def cord(G):
        f = G.subset(K._torso_names())
        ang = np.arctan2(G.X, -G.Y)
        twist = 0.0014 * np.sin(ang * 40.0 + (G.Z - zb) * 900.0)
        d = np.maximum(shell(f - twist, 0.017, 0.026), np.abs(G.Z - zb) - 0.0085)
        return smin(d, ellipsoid(G.X, G.Y, G.Z, (0.05 * S, fy - 0.026, zb), (0.016, 0.013, 0.015)), 0.006)

    def tassels(G):
        out = None
        for dx, ln in ((0.042, 0.14), (0.06, 0.11)):
            top = np.array([dx * S, fy - 0.034, zb - 0.01])
            knot = top + np.array([0.0, -0.004, -ln])
            d = capsule(G.X, G.Y, G.Z, top, knot, 0.0035)
            d = np.minimum(d, W.cone(G.X, G.Y, G.Z, knot, knot + np.array([0, 0, -0.055]), 0.006, 0.013))
            out = d if out is None else np.minimum(out, d)
        return out
    return [Part("cord", "plate", cord, lo, hi, 1900, voxel=0.0015, skin="pelvis"),
            Part("cord_tassels", "plate", tassels, lo, hi, 1100, voxel=0.0013, skin="pelvis")]


def oracle_underskirt(b: Body) -> list[Part]:
    """Legs: trousers and an ankle-length underskirt with a neat hem and a gold hem band."""
    z = b.z
    top = z("pelvis") + 0.03
    hem = z("ankle_l") + 0.06
    lo = np.array([-0.4, -0.36, z("ankle_l") - 0.04])
    hi = np.array([0.4, 0.34, top + 0.06])
    sk = skirt_field(b, top, hem, 0.165, 0.13, 0.11, 0.085, fold=0.012, torn=False, hem_amp=0.005)

    def trousers(G):
        f = G.subset(LEGS)
        return np.maximum(shell(f, 0.0015, 0.008), band(G.Z, z("ankle_l") - 0.01, z("pelvis") - 0.05))

    def gold(G):
        d = sk(G)
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        hz_ = K._hem_line(ang, hem, amp=0.005, tears=False)
        return np.maximum(d - 0.0015, np.abs(G.Z - (hz_ + 0.022)) - 0.012)
    return [Part("trousers", "cloth", trousers, lo, hi, 2800, voxel=0.0025),
            Part("underskirt", "cloth", sk, lo, hi, 7200, voxel=0.0025),
            Part("underskirt_gold", "plate", gold, lo, hi, 2000, voxel=0.0018, facet_deg=40)]


def oracle_slippers(b: Body) -> list[Part]:
    parts = []
    for side in ("l", "r"):
        boot, cuff, lo, hi = soft_boot(b, side, height=0.06, pointed=0.0)
        a = b.j[f"ankle_{side}"]

        def anklet(G, a=a, side=side):
            f = G.subset({"malleolus_out", "malleolus_in", "achilles", "shin", "calf", "tibia"})
            return np.maximum(shell(f, 0.004, 0.0095), np.abs(G.Z - (a[2] + 0.075)) - 0.006)
        parts.append(Part(f"slipper_{side}", "trim", boot, lo, hi, 2000, skin="transfer", voxel=0.0015))
        parts.append(Part(f"anklet_{side}", "plate", anklet, lo, hi, 700, skin="transfer", voxel=0.0013,
                          facet_deg=40))
    return parts


def oracle_halo(b: Body) -> list[Part]:
    """A gold halo behind the head and shoulders: a ring with alternating long and short rays, a
    glowing inner ring, held by a rod rising from a small plate between the shoulder blades."""
    s, hz = b.hs, b.hz
    y0 = 0.17 * b.S
    zc = hz + 0.12 * s
    R = 0.2 * b.S
    lo = np.array([-R - 0.09, 0.08, b.z("chest") - 0.02])
    hi = np.array([R + 0.09, y0 + 0.04, zc + R + 0.09])

    def ring_d(G, r, tube_r):
        rad = np.sqrt(G.X ** 2 + (G.Z - zc) ** 2)
        return np.sqrt((rad - r) ** 2 + (G.Y - y0) ** 2) - tube_r

    def ring(G):
        d = ring_d(G, R, 0.009)
        rays = []
        for k in range(24):
            a = 2 * np.pi * k / 24
            u = np.array([np.sin(a), 0.0, np.cos(a)])
            base = np.array([0.0, y0, zc]) + u * (R + 0.006)
            ln = (0.06 if k % 2 == 0 else 0.032) * b.S
            rays.append((base, base + u * ln, 0.0075, 0.001))
        d = W.spikes(d, G, rays)
        plate = np.maximum(shell(G.subset({"upper_back", "scapula", "trap"}), 0.02, 0.026),
                           ellipsoid(G.X, G.Y, G.Z, (0.0, 0.12, b.z("chest_top") - 0.06), (0.06, 0.1, 0.07)))
        rod = capsule(G.X, G.Y, G.Z, (0.0, 0.135 * b.S, b.z("chest_top") - 0.05), (0.0, y0, zc - R), 0.008)
        return np.minimum(np.minimum(d, plate), rod)

    def glow(G):
        return ring_d(G, R - 0.022 * b.S, 0.0055)
    return [Part("halo", "plate", ring, lo, hi, 6000, skin="chest", voxel=0.0015, facet_deg=40),
            Part("halo_glow", "holy", glow, lo, hi, 2000, skin="chest", voxel=0.0013)]


DESIGNS = {
    "arcanist_hood": arcanist_hood,
    "arcanist_capelet": arcanist_capelet,
    "arcanist_robe": arcanist_robe,
    "arcanist_wraps": arcanist_wraps,
    "arcanist_sash": arcanist_sash,
    "arcanist_underskirt": arcanist_underskirt,
    "arcanist_boots": arcanist_boots,
    "arcanist_frost_cape": arcanist_frost_cape,
    "oracle_veil": oracle_veil,
    "oracle_shoulder_caps": oracle_shoulder_caps,
    "oracle_robe": oracle_robe,
    "oracle_gloves": oracle_gloves,
    "oracle_cord": oracle_cord,
    "oracle_underskirt": oracle_underskirt,
    "oracle_slippers": oracle_slippers,
    "oracle_halo": oracle_halo,
}
