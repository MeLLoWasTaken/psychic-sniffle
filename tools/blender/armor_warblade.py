"""The Warblade's default plate set, "Ironreaver" (backlog G-07): massive, angular, blackened plate
with brass trim, read at a distance by wide ribbed horns on a close helm and spiked pauldrons.

Built like the Templar set (tools/blender/armor_kit.py): each design returns parts, each a distance
field on its own grid. Coordinates: metres, +Z up, the character faces -Y, its left is +X.
"""
from __future__ import annotations

import numpy as np

import armor_kit as K
from armor_kit import (Body, Part, band, below, capsule, ellipsoid, on_surface, on_surface_dir, ring_points,
                       sawtooth, shell, smin, studs, superellipse, tube)


# ----------------------------------------------------------------------------- shared helpers

def cone(X, Y, Z, a, b, r1, r2):
    """A capsule whose radius changes from r1 at a to r2 at b (spikes, horn segments)."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    ba = b - a
    h = np.clip(((X - a[0]) * ba[0] + (Y - a[1]) * ba[1] + (Z - a[2]) * ba[2]) / (ba @ ba), 0.0, 1.0)
    return np.sqrt((X - a[0] - ba[0] * h) ** 2 + (Y - a[1] - ba[1] * h) ** 2 + (Z - a[2] - ba[2] * h) ** 2) \
        - (r1 + (r2 - r1) * h)


def spikes(d, G, items):
    """Union of tapered spikes (base, tip, base radius, tip radius) into `d`, each evaluated in a
    small window of the grid (like armor_kit.studs)."""
    d = np.array(d, dtype=np.float32, copy=True)
    shape = d.shape
    for a, t, r1, r2 in items:
        a, t = np.asarray(a, float), np.asarray(t, float)
        lo3 = np.minimum(a, t) - r1 * 2
        hi3 = np.maximum(a, t) + r1 * 2
        i0 = np.maximum(np.floor((lo3 - G.lo) / G.voxel).astype(int), 0)
        i1 = np.minimum(np.ceil((hi3 - G.lo) / G.voxel).astype(int) + 1, np.array(shape))
        if np.any(i1 <= i0):
            continue
        X = G.X[i0[0]:i1[0]]
        Y = G.Y[:, i0[1]:i1[1]]
        Z = G.Z[:, :, i0[2]:i1[2]]
        s = cone(X, Y, Z, a, t, r1, r2)
        win = d[i0[0]:i1[0], i0[1]:i1[1], i0[2]:i1[2]]
        np.minimum(win, np.broadcast_to(s, win.shape).astype(np.float32), out=win)
    return d


def curve(points, n=20):
    """Points along a smooth curve through `points` (Catmull-Rom), n per span."""
    P = [np.asarray(p, float) for p in points]
    P = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for t in np.linspace(0, 1, n, endpoint=False):
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3))
    out.append(P[-2])
    return np.array(out)


def swept(G, pts, radii, rib=0.0, period=0.014):
    """A tube swept along a polyline with a radius per point; `rib` > 0 cuts rings across it
    every `period` metres (a horn's growth rings)."""
    d = np.full(np.broadcast_shapes(G.X.shape, G.Y.shape, G.Z.shape), 10.0, dtype=np.float32)
    s0 = 0.0
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        L = float(np.linalg.norm(b - a))
        ba = b - a
        h = np.clip(((G.X - a[0]) * ba[0] + (G.Y - a[1]) * ba[1] + (G.Z - a[2]) * ba[2]) / (L * L), 0.0, 1.0)
        r = radii[i] + (radii[i + 1] - radii[i]) * h
        if rib > 0:
            s = s0 + h * L
            r = r * (1.0 - rib * (0.5 + 0.5 * np.cos(2 * np.pi * s / period)) ** 6)
        seg = np.sqrt((G.X - a[0] - ba[0] * h) ** 2 + (G.Y - a[1] - ba[1] * h) ** 2 + (G.Z - a[2] - ba[2] * h) ** 2) - r
        d = np.minimum(d, seg)
        s0 += L
    return d


def mail_shirt(b: Body, skirt_z: float, neck_z: float):
    """A mail shirt with long sleeves (stopping under the gauntlet cuffs), padded at the elbows so
    they bend inside it, and a skirt split front and back down to `skirt_z`."""
    torso = K._torso_names()
    arms = {"deltoid", "upperarm", "bicep", "tricep", "elbow", "forearm", "forearm_mass", "wrist"}
    legs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor", "glute"}
    el_l = b.j["elbow_l"]
    z = b.z

    def fn(G):
        f = G.subset(torso | arms | legs)
        loose = 0.008 * np.clip((np.abs(G.X) - 0.21) / 0.05, 0, 1)
        for sx in (1.0, -1.0):
            e = el_l * np.array([sx, 1, 1])
            loose = loose + 0.01 * np.exp(-((G.X - e[0]) ** 2 + (G.Y - e[1]) ** 2 + (G.Z - e[2]) ** 2) / 0.07 ** 2)
        d = shell(f, 0.002, 0.008 + loose)
        d = np.maximum(d, below(G.Z, neck_z))
        neck_hole = np.sqrt(G.X ** 2 + (G.Y - 0.01) ** 2) - 0.085
        d = np.maximum(d, -np.where(G.Z > neck_z - 0.06, neck_hole, 1.0))
        for sx in (1.0, -1.0):
            el = el_l * np.array([sx, 1, 1])
            wr = b.j["wrist_l"] * np.array([sx, 1, 1])
            ax = (wr - el) / np.linalg.norm(wr - el)
            along = (G.X - el[0]) * ax[0] + (G.Y - el[1]) * ax[1] + (G.Z - el[2]) * ax[2]
            d = np.where((G.X * sx > 0.16), np.maximum(d, along - (np.linalg.norm(wr - el) - 0.04)), d)
        d = np.maximum(d, skirt_z - G.Z)
        split = np.maximum(np.abs(G.X) - 0.012, G.Z - (z("pelvis") - 0.08))   # below the hips only
        return np.maximum(d, -split)
    return fn


def plate_gauntlet(b: Body, side: str, cuff_len=0.16, knuckle_spikes=True, claws=False, trim=None):
    """A plate gauntlet: finger scales, wrist lames, a plate over the back of the hand, a long
    flared cuff with a ridge along its top and a hard edge; spiked knuckles or bosses; `claws`
    gives the fingertips pointed plates. Returns (field function, bounds) for one hand."""
    sx = 1.0 if side == "l" else -1.0
    hand_names = {f"palm_{side}", f"thumb_{side}"} | {f"finger{i}_{side}" for i in range(4)} | \
        {"wrist", "forearm", "forearm_mass"}
    wr, end = b.j[f"wrist_{side}"], b.j[f"hand_end_{side}"]
    el = b.j[f"elbow_{side}"]
    ax = (end - wr) / np.linalg.norm(end - wr)
    fa = (wr - el) / np.linalg.norm(wr - el)
    dorsal = np.array([abs(ax[2]) * sx, 0.0, abs(ax[0])])
    dorsal /= np.linalg.norm(dorsal)
    lo = np.minimum(wr - fa * (cuff_len + 0.02), end) - 0.12
    hi = np.maximum(wr - fa * (cuff_len + 0.02), end) + 0.12
    r0 = 0.05 * b.S

    def coords(G):
        along = (G.X - wr[0]) * fa[0] + (G.Y - wr[1]) * fa[1] + (G.Z - wr[2]) * fa[2]
        u = (G.X - wr[0]) * ax[0] + (G.Y - wr[1]) * ax[1] + (G.Z - wr[2]) * ax[2]
        back = (G.X - wr[0]) * dorsal[0] + (G.Y - wr[1]) * dorsal[1] + (G.Z - wr[2]) * dorsal[2]
        return along, u, back

    def cuff_radial(G, along):
        px = G.X - wr[0] - fa[0] * along
        py = G.Y - wr[1] - fa[1] * along
        pz = G.Z - wr[2] - fa[2] * along
        radial = np.sqrt(px * px + py * py + pz * pz)
        top = (px * dorsal[0] + py * dorsal[1] + pz * dorsal[2]) / np.maximum(radial, 1e-6)
        return radial, top

    def fn(G):
        f = G.subset(hand_names)
        along, u, back = coords(G)
        scales = 0.0018 * sawtooth(u, 0.018)
        d = shell(f - np.where(u > 0.085, scales, 0.0), 0.0015, 0.0058)
        d = np.maximum(d, -along - 0.03)
        lam = 0.0016 * sawtooth(-along + 0.02, 0.02) * (along > -0.03) * (u < 0.03)
        d = d - lam
        plate = np.maximum(shell(f, 0.004, 0.0095), np.maximum(-back + 0.005, band(u, 0.02, 0.083)))
        d = np.minimum(d, plate)
        if claws:   # a pointed plate over each fingertip, reaching a little past it
            tip = np.maximum(shell(f, 0.003, 0.0075), np.maximum(-back + 0.002, u - 0.205 * b.S))
            d = np.minimum(d, np.maximum(tip, 0.16 * b.S - u))
        # the cuff: a flared cone with a ridge along its top and a hard, thick edge
        radial, top = cuff_radial(G, along)
        r = r0 + np.clip(-along, 0, cuff_len) * 0.21
        ridge = 0.007 * np.clip((top - 0.85) / 0.15, 0, 1)
        cuff = np.maximum(np.abs(radial - r - ridge) - 0.0038, np.maximum(along - 0.012, -along - cuff_len))
        cuff = np.minimum(cuff, np.maximum(np.abs(radial - (r0 + cuff_len * 0.21) - ridge) - 0.0065,
                                           np.abs(along + cuff_len - 0.006) - 0.006))   # the thick edge
        return np.minimum(d, cuff)

    def full(G):
        d = fn(G)
        perp1 = np.cross(fa, [0.0, 1.0, 0.0])
        perp1 /= np.linalg.norm(perp1)
        perp2 = np.cross(fa, perp1)
        rr = r0 + (cuff_len - 0.018) * 0.21 + 0.006
        riv = [wr - fa * (cuff_len - 0.018) + (perp1 * np.cos(a) + perp2 * np.sin(a)) * rr
               for a in np.linspace(0, 2 * np.pi, 10, endpoint=False)]
        d = studs(d, G, riv, 0.0034)
        across = np.cross(ax, dorsal)
        across /= np.linalg.norm(across)
        kn = [wr + ax * 0.088 + across * w for w in (-0.027, -0.009, 0.009, 0.027)]
        kn = on_surface_dir(lambda P: P.subset(hand_names) - 0.0095, kn, dorsal, sink=0.002, shape=G._shape)
        if knuckle_spikes:
            items = [(k, k + (dorsal * 0.8 + ax * 0.6) / np.linalg.norm(dorsal * 0.8 + ax * 0.6) * 0.024,
                      0.0065, 0.0012) for k in kn]
            return spikes(d, G, items)
        return studs(d, G, kn, 0.0062)
    return full, lo, hi


def plate_sabaton(b: Body, side: str, pointed=0.03):
    """Angular plate sabatons: lames over the foot, a ridge down the instep to a toe cap drawn out
    `pointed` metres past the toes, and a thick edge round the ankle."""
    foot = {"heel", "foot", "instep", "toes", "malleolus_out", "malleolus_in", "achilles", "shin"}
    a, t = b.j[f"ankle_{side}"], b.j[f"toe_{side}"]
    lo = np.minimum(a, t) - np.array([0.1, 0.16 + pointed, 0.02])
    hi = np.maximum(a, t) + np.array([0.1, 0.16, 0.12])
    top = a[2] + 0.075
    tc = t + np.array([0.0, -0.005, 0.01])

    def fn(G):
        f = G.subset(foot)
        toe = ellipsoid(G.X, G.Y, G.Z, tc + np.array([0, -pointed * 0.4, 0]), (0.04, 0.045 + pointed * 0.4, 0.026))
        f = smin(f, toe, 0.02)
        fwd = -(G.Y - a[1])
        lames = 0.002 * sawtooth(fwd - 0.02, 0.024) * (fwd > 0.02)
        ridge = 0.004 * np.clip(1.0 - np.abs(G.X - t[0]) / 0.012, 0, 1) * (fwd > 0.0)
        d = shell(f - lames - ridge, 0.002, 0.009)
        d = np.maximum(d, below(G.Z, top))
        d = np.minimum(d, np.maximum(np.abs(f - 0.0065) - 0.0055, np.abs(G.Z - top + 0.005) - 0.005))
        return np.maximum(d, -G.Z)
    return fn, lo, hi


# ----------------------------------------------------------------------------- Warblade designs

def warblade_horned_helm(b: Body) -> list[Part]:
    """A close helm with a domed skull and a low crest, cheek plates flaring at the bottom, a keel
    down the face, a heavy overhanging brow and a T-shaped opening (eye slits that rise at their
    outer ends, a slot down to the mouth), riveted at the brow and the rim; two wide ribbed horns
    sweep out from the temples and up and forward, set in brass collars."""
    s, hz = b.hs, b.hz
    cy = 0.004 * s
    z0 = hz - 0.04 * s
    zt = hz + 0.135 * s
    eye_z = hz + 0.122 * s
    lo = np.array([-0.16, cy - 0.2, z0 - 0.03])
    hi = np.array([0.16, cy + 0.19, hz + 0.3 * s])

    def outer_field(G):
        skull = ellipsoid(G.X, G.Y, G.Z, (0.0, cy, zt), (0.113 * s, 0.137 * s, 0.135 * s))
        flare = 1.0 + 0.09 * np.clip((hz + 0.07 * s - G.Z) / (0.11 * s), 0, 1)
        cyl = np.maximum(superellipse(G.X, G.Y, 0.0, cy, 0.113 * s * flare, 0.137 * s * (0.5 + 0.5 * flare), 2.4),
                         band(G.Z, z0 - 0.02, zt))
        d = smin(skull, cyl, 0.02)
        front = (G.Y < cy) * 1.0
        keel = 0.016 * s * np.clip(1.0 - np.abs(G.X) / (0.06 * s), 0, 1) ** 1.5 * front * (G.Z < eye_z + 0.05 * s)
        crest = 0.0065 * np.clip(1.0 - np.abs(G.X) / 0.009, 0, 1) * (G.Z > hz + 0.17 * s)
        ang = np.abs(np.arctan2(G.X, -(G.Y - cy)))
        brow = 0.0065 * K._sig((G.Z - (eye_z + 0.009 * s)) / 0.001) * K._sig((eye_z + 0.034 * s - G.Z) / 0.001) \
            * K._sig((1.15 - ang) / 0.02)
        return d - keel - crest - brow

    def slit_field(G):
        ez = eye_z + 0.009 * s * np.clip(np.abs(G.X) / (0.072 * s), 0, 1)       # rising at the outer ends
        eyes = np.maximum(np.abs(G.Z - ez) - 0.0068 * s, np.maximum(np.abs(G.X) - 0.072 * s, 0.006 * s - np.abs(G.X)))
        mouth = np.maximum(np.abs(G.X) - 0.0095 * s, band(G.Z, hz + 0.03 * s, eye_z - 0.004 * s))
        return np.maximum(np.minimum(eyes, mouth), G.Y - (cy - 0.05))

    def helm(G):
        outer = outer_field(G)
        sl = slit_field(G)
        d = shell(outer, -0.005, 0.0)
        d = np.maximum(d, below(G.Z, hz + 0.32 * s))
        d = np.maximum(d, z0 - G.Z)
        d = np.minimum(d, np.maximum(np.abs(outer + 0.0035) - 0.0062, np.abs(G.Z - z0 - 0.006) - 0.006))  # thick rim
        d = np.maximum(d, -sl)
        riv = ring_points(0.113 * s, 0.137 * s, eye_z + 0.04 * s, 22, cy=cy, keep=lambda x, y: abs(x) > 0.025 * s)
        riv += ring_points(0.122 * s, 0.14 * s, z0 + 0.022, 20, cy=cy, keep=lambda x, y: abs(x) > 0.03 * s)
        riv = on_surface(outer_field, riv, (0.0, cy), sink=0.0012)
        return studs(d, G, riv, 0.0036)

    def liner(G):
        outer = outer_field(G)
        return np.maximum(shell(outer, -0.0155, -0.0115), band(G.Z, z0 + 0.012, hz + 0.25 * s))

    parts = [Part("helm", "plate", helm, lo, hi, 4600, skin="head", voxel=0.0015, facet_deg=40),
             Part("helm_liner", "leather", liner, lo, hi, 300, skin="head", voxel=0.003)]
    for side, sx in (("l", 1.0), ("r", -1.0)):
        ctrl = [(0.096, 0.008, 0.162), (0.17, -0.002, 0.192), (0.245, -0.024, 0.255), (0.288, -0.064, 0.345),
                (0.296, -0.112, 0.43)]
        pts = curve([np.array([sx * x * s, cy + y * s, hz + zz * s]) for x, y, zz in ctrl], n=8)
        t = np.linspace(0, 1, len(pts))
        radii = (0.035 * (1 - t) ** 0.85 + 0.003) * s
        hlo = pts.min(0) - 0.04
        hhi = pts.max(0) + 0.04

        def horn(G, pts=pts, radii=radii):
            return swept(G, pts, radii, rib=0.07, period=0.013)

        def collar(G, pts=pts, radii=radii):
            k = max(2, len(pts) // 10)
            return swept(G, pts[1:k + 1], radii[1:k + 1] + 0.0055 * s)
        parts.append(Part(f"horn_{side}", "horn", horn, hlo, hhi, 1700, skin="head", voxel=0.0015))
        parts.append(Part(f"horn_collar_{side}", "gold", collar, hlo, hhi, 350, skin="head", voxel=0.0015,
                          facet_deg=40))
    return parts + warblade_gorget(b)


def warblade_gorget(b: Body) -> list[Part]:
    """A plate gorget under the helm: three lames over the neck and the top of the chest, each
    stepping out over the one below, with a thick lower edge."""
    zt = b.z("neck") + 0.075
    zb = b.z("chest_top") - 0.055
    lo = np.array([-0.3, -0.25, zb - 0.03])
    hi = np.array([0.3, 0.25, zt + 0.03])
    names = {"neck", "trap", "scm", "clavicle", "upper_back", "ribcage", "pec", "deltoid", "scapula", "breast"}

    def fn(G):
        f = G.subset(names)
        lames = 0.0024 * sawtooth(zt - G.Z, 0.034)
        d = np.maximum(shell(f - lames, 0.006, 0.0125), band(G.Z, zb, zt))
        d = np.minimum(d, np.maximum(np.abs(f - 0.011) - 0.004, np.abs(G.Z - zb - 0.004) - 0.004))
        reach = np.sqrt(G.X ** 2 + (G.Y * 1.1) ** 2) - 0.2
        return np.maximum(d, reach)
    return [Part("gorget", "plate", fn, lo, hi, 2100, voxel=0.002, facet_deg=40)]


def warblade_pauldrons(b: Body) -> list[Part]:
    """Massive angular pauldrons: a boxy cop with a sharp ridge across it and three spikes rising
    from the ridge, two lames below stepping out over each other, a brass band along each edge and
    rivets at the lames' ends."""
    parts = []
    S = b.S
    for side, sx in (("l", 1.0), ("r", -1.0)):
        sh = b.j[f"shoulder_{side}"]
        el = b.j[f"elbow_{side}"]
        ax = (el - sh) / np.linalg.norm(el - sh)
        c = sh + np.array([sx * 0.02, 0.0, 0.045]) * S
        R = np.array([0.12, 0.13, 0.106]) * S
        lames = [(0.058, 0.0), (0.092, 0.008)]
        lo = c - np.array([0.22, 0.22, 0.2])
        hi = c + np.array([0.22, 0.22, 0.24])

        def along_of(G, c=c, ax=ax):
            return (G.X - c[0]) * ax[0] + (G.Y - c[1]) * ax[1] + (G.Z - c[2]) * ax[2]

        def boxy(G, cc, RR, n=2.8):
            q = [np.abs(G.X - cc[0]) / RR[0], np.abs(G.Y - cc[1]) / RR[1], np.abs(G.Z - cc[2]) / RR[2]]
            return ((q[0] ** n + q[1] ** n + q[2] ** n) ** (1.0 / n) - 1.0) * min(RR)

        def dome_of(G, c=c, R=R, boxy=boxy):
            ridge = 0.012 * S * np.clip(1.0 - np.abs(G.Y - c[1]) / 0.028, 0, 1) ** 2
            return boxy(G, c, R) - ridge

        def inner_cut(G, c=c, sx=sx):
            return (c[0] - sx * 0.075) * sx - G.X * sx

        def cap(G, c=c, ax=ax, sx=sx, R=R, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut, boxy=boxy):
            dome = dome_of(G)
            along = along_of(G)
            d = np.maximum(shell(dome, -0.006, 0.0), along - 0.04)
            d = np.maximum(d, inner_cut(G))
            for off, loss in lames:
                lc = c + ax * off
                lame = boxy(G, lc, R - 0.003 - loss * S)
                ld = np.maximum(shell(lame, -0.005, 0.0), np.abs(along - off) - 0.019)
                ld = np.maximum(ld, (c[0] - sx * 0.04) * sx - G.X * sx)
                d = np.minimum(d, ld)
            riv = []
            for off, loss in lames:
                for fy in (-1.0, 1.0):
                    u = np.array([0.35 * sx, fy, -0.1])
                    u = u - ax * (u @ ax)
                    u /= np.linalg.norm(u)
                    riv.append(K.ellipsoid_point(c + ax * off, R - 0.003 - loss * S, u) - u * 0.0015)
            d = studs(d, G, riv, 0.0038)
            # three spikes along the ridge, leaning out from the neck
            items = []
            for dx, ln in ((-0.04, 0.075), (0.008, 0.1), (0.056, 0.072)):
                base = np.array([c[0] + sx * dx * S, c[1], c[2] + R[2] * 0.82])
                base = on_surface_dir(lambda P, dome_of=dome_of: dome_of(P), [base], (0, 0, 1.0), sink=0.004)[0]
                dirn = np.array([sx * (0.25 + 2.0 * dx), 0.04, 1.0])
                dirn /= np.linalg.norm(dirn)
                items.append((base, base + dirn * ln * S, 0.017 * S, 0.0014))
            return spikes(d, G, items)

        def trim(G, c=c, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut):
            dome = dome_of(G)
            along = along_of(G)
            d = np.maximum(shell(dome, -0.001, 0.0032), np.abs(along - 0.031) - 0.0075)
            return np.maximum(d, inner_cut(G) - 0.004)
        bone = f"upperarm_{side}"
        parts.append(Part(f"pauldron_{side}", "plate", cap, lo, hi, 3900, skin=bone, voxel=0.0015, facet_deg=40))
        parts.append(Part(f"pauldron_trim_{side}", "gold", trim, lo, hi, 800, skin=bone, voxel=0.0015, facet_deg=40))
        parts.append(rerebrace(b, side))
    return parts


def rerebrace(b: Body, side: str) -> Part:
    """A plate tube round the upper arm between the pauldron and the elbow, in two lames, with a
    thick lower edge."""
    sh, el = b.j[f"shoulder_{side}"], b.j[f"elbow_{side}"]
    ax = (el - sh) / np.linalg.norm(el - sh)
    L = float(np.linalg.norm(el - sh))
    arm = {"upperarm", "bicep", "tricep", "deltoid"}
    a0, a1 = 0.4 * L, L - 0.045
    lo = np.minimum(sh, el) - 0.1
    hi = np.maximum(sh, el) + 0.1

    def fn(G):
        f = G.subset(arm)
        along = (G.X - sh[0]) * ax[0] + (G.Y - sh[1]) * ax[1] + (G.Z - sh[2]) * ax[2]
        lames = 0.002 * sawtooth(along - a0, (a1 - a0) / 2)
        d = np.maximum(shell(f - lames, 0.0125, 0.018), band(along, a0, a1))
        rim = np.maximum(np.abs(f - 0.0165) - 0.0045, np.abs(along - a1 + 0.004) - 0.004)
        side_cut = -(G.X * (1 if side == "l" else -1)) + 0.12        # never reaching the chest
        return np.maximum(np.minimum(d, rim), side_cut)
    return Part(f"rerebrace_{side}", "plate", fn, lo, hi, 1300, skin=f"upperarm_{side}", voxel=0.0018, facet_deg=40)


def couter(b: Body, side: str, spike=True) -> Part:
    """An elbow cop: a dome over the point of the elbow with a fan-shaped wing on the outside and
    a spike pointing back."""
    sx = 1.0 if side == "l" else -1.0
    el = b.j[f"elbow_{side}"]
    c = el + np.array([0.0, 0.018, 0.0]) * b.S
    R = np.array([0.048, 0.042, 0.05]) * b.S
    lo, hi = c - 0.12, c + 0.12

    def fn(G):
        dome = ellipsoid(G.X, G.Y, G.Z, c, R)
        d = np.maximum(shell(dome, -0.005, 0.0), c[1] - 0.012 - G.Y)              # the back of the elbow
        wc = c + np.array([sx * 0.035, -0.01, 0.0]) * b.S
        wing = ellipsoid(G.X, G.Y, G.Z, wc, (0.014 * b.S, 0.04 * b.S, 0.05 * b.S))
        wa = np.arctan2(G.Z - wc[2], G.Y - wc[1])
        wing = np.maximum(shell(wing - 0.0016 * (0.5 + 0.5 * np.cos(wa * 8.0)), -0.0035, 0.0),
                          (c[0] + sx * 0.03) * sx - G.X * sx)
        d = np.minimum(d, wing)
        if spike:
            tip = c + np.array([0.0, R[1] + 0.045 * b.S, -0.012])
            d = spikes(d, G, [(c + np.array([0.0, R[1] - 0.006, 0.0]), tip, 0.013 * b.S, 0.0014)])
        return d
    return Part(f"couter_{side}", "plate", fn, lo, hi, 900, skin="transfer", voxel=0.0015, facet_deg=40)


def warblade_cuirass(b: Body) -> list[Part]:
    """Chest slot: a mail shirt with long sleeves and a short split skirt, under a breastplate
    with a keel down the chest, a back plate, a plackart of three lames over the belly, a brass
    band round the neck and the arm holes, and rivets along it."""
    z = b.z
    neck_z = z("chest_top") + 0.02
    belt = z("pelvis") + 0.06
    waist = z("spine") + 0.01
    top = neck_z - 0.012
    skirt = z("knee_l") + 0.3
    lo = np.array([-0.75, -0.33, skirt - 0.06])
    hi = np.array([0.75, 0.31, neck_z + 0.06])
    sh_l = b.j["shoulder_l"]
    torso = K._torso_names()

    def keel(G):
        return 0.015 * np.clip(1.0 - np.abs(G.X) / 0.1, 0, 1) ** 1.2 * (G.Y < 0) \
            * np.clip((G.Z - waist) / 0.12, 0, 1)

    def holes(G):
        out = []
        for sx in (1.0, -1.0):
            s = sh_l * np.array([sx, 1, 1])
            out.append(np.sqrt((G.X - s[0] * 0.9) ** 2 + (G.Y - s[1]) ** 2 + ((G.Z - s[2] + 0.05) * 0.85) ** 2) - 0.115)
        return out

    def plate_body(G, inner, outer):
        f = G.subset(torso)
        P = f - keel(G)
        front = np.maximum(shell(P, inner, outer), band(G.Z, waist, top))
        back = np.maximum(shell(f, inner, outer), np.maximum(band(G.Z, belt - 0.01, top), -G.Y))
        d = np.minimum(np.where(G.Y < 0.0, front, 1.0), back)
        for h in holes(G):
            d = np.maximum(d, -h)
        neck = np.sqrt(G.X ** 2 + (G.Y * 0.95) ** 2) - 0.105
        return np.maximum(d, -np.where(G.Z > top - 0.08, neck, 1.0)), f, P

    def cuirass(G):
        d, f, P = plate_body(G, 0.017, 0.0255)
        return d

    def plackart(G):
        f = G.subset(torso)
        lames = 0.0032 * sawtooth(waist + 0.03 - G.Z, 0.045)
        d = np.maximum(shell(f - lames, 0.019, 0.027), band(G.Z, belt - 0.015, waist + 0.03))
        d = np.maximum(d, G.Y - 0.02)
        return d

    def trim(G):
        d, f, P = plate_body(G, 0.0245, 0.0295)
        edges = [np.abs(G.Z - top) - 0.016] + [np.abs(h) - 0.012 for h in holes(G)]
        edge = edges[0]
        for e in edges[1:]:
            edge = np.minimum(edge, e)
        return np.maximum(d, edge)

    def trim_riveted(G):
        d = trim(G)
        pts = [np.array([np.sin(a) * 0.15, -np.cos(a) * 0.15, top - 0.008]) for a in np.linspace(-1.2, 1.2, 9)]
        pts = on_surface(lambda P: P.subset(torso) - 0.03, pts, (0.0, 0.0), sink=0.0015, reach=0.12, shape=G._shape)
        return studs(d, G, pts, 0.0042)

    return [Part("mail_shirt", "mail", mail_shirt(b, skirt, neck_z), lo, hi, 6200, voxel=0.0025),
            Part("cuirass", "plate", cuirass, lo, hi, 9200, voxel=0.002, facet_deg=40),
            Part("plackart", "plate", plackart, np.array([-0.3, -0.3, belt - 0.05]), np.array([0.3, 0.1, waist + 0.06]),
                 3600, voxel=0.0018, facet_deg=40),
            Part("cuirass_trim", "gold", trim_riveted, lo, hi, 3000, voxel=0.0018, facet_deg=40)]


def warblade_gauntlets(b: Body) -> list[Part]:
    """Heavy gauntlets: long flared cuffs with a ridge and a thick edge, spiked knuckles."""
    parts = []
    for side in ("l", "r"):
        fn, lo, hi = plate_gauntlet(b, side, cuff_len=0.16, knuckle_spikes=True)
        parts.append(Part(f"gauntlet_{side}", "plate", fn, lo, hi, 3300, skin=f"hand_{side}", voxel=0.0013,
                          facet_deg=45))
        parts.append(couter(b, side))
    return parts


def warblade_girdle(b: Body) -> list[Part]:
    """A broad studded leather girdle with an angular steel boss over the buckle: a six-sided
    plate with a ridge across it and a rivet at each corner."""
    zb = b.z("pelvis") + 0.06
    S = b.S
    lo = np.array([-0.3, -0.3, zb - 0.07])
    hi = np.array([0.3, 0.3, zb + 0.07])
    fy = -0.155 * S

    def strap(G):
        f = G.subset(K._torso_names())
        d = np.maximum(shell(f, 0.021, 0.034), np.abs(G.Z - zb) - 0.032)
        pts = [np.array([np.sin(a) * 0.19, -np.cos(a) * 0.19, zb + dz]) for a in np.linspace(-2.6, 2.6, 22)
               if abs(a) > 0.45 for dz in (-0.017, 0.017)]
        pts = on_surface(lambda P: P.subset(K._torso_names()) - 0.034, pts, (0.0, 0.0), sink=0.0015, reach=0.1,
                         shape=G._shape)
        return studs(d, G, pts, 0.0045)

    def boss(G):
        u, w = G.X, G.Z - zb
        hexa = np.maximum(np.abs(u) * 0.866 + np.abs(w) * 0.5, np.abs(w)) - 0.04
        ridge = 0.004 * np.clip(1.0 - np.abs(w) / 0.01, 0, 1)
        d = np.maximum(hexa, np.abs(G.Y - (fy - 0.04) + ridge * 0.5) - 0.006 - ridge * 0.5)
        corners = [np.array([0.035 * np.cos(a), fy - 0.047, zb + 0.035 * np.sin(a)]) for a in
                   np.linspace(0, 2 * np.pi, 6, endpoint=False) + np.pi / 6]
        return studs(d, G, corners, 0.0045)
    return [Part("girdle", "leather", strap, lo, hi, 2200, voxel=0.0018, skin="pelvis"),
            Part("girdle_boss", "plate", boss, lo, hi, 800, voxel=0.0015, skin="pelvis", facet_deg=40)]


def warblade_legplates(b: Body, with_tassets: bool = True) -> list[Part]:
    """Legs: mail breeches; tassets of three lames hanging from the waist over the hips, plate
    cuisses with a ridge down the front of the thigh, angular knee cops with a short spike, and
    greaves with a keel down the shin."""
    z = b.z
    legs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor", "patella", "shin", "tibia", "calf",
            "achilles", "malleolus_out", "malleolus_in", "glute", "pelvis"}
    thighs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor"}
    lower = {"shin", "tibia", "calf", "achilles", "malleolus_out", "malleolus_in"}
    lo = np.array([-0.3, -0.25, z("ankle_l") - 0.02])
    hi = np.array([0.3, 0.25, z("pelvis") + 0.08])
    kz = z("knee_l")

    def mail(G):
        f = G.subset(legs)
        return np.maximum(shell(f, 0.0015, 0.012), band(G.Z, z("ankle_l") - 0.015, z("pelvis") - 0.06))
    parts = [Part("breeches", "mail", mail, lo, hi, 3200, voxel=0.0025)]

    def knee_x(G):
        return np.where(G.X > 0, b.j["knee_l"][0], -b.j["knee_l"][0])

    def cuisses(G):
        f = G.subset(thighs)
        ridge = 0.006 * np.clip(1.0 - np.abs(G.X - knee_x(G)) / 0.02, 0, 1) * (G.Y < b.j["knee_l"][1])
        d = np.maximum(shell(f - ridge, 0.0145, 0.021), band(G.Z, kz + 0.075, z("pelvis") - 0.14))
        d = np.maximum(d, G.Y - (b.j["knee_l"][1] + 0.035))          # the front and sides of the thigh
        return np.maximum(d, 0.012 - np.abs(G.X))

    def tassets(G):
        f = G.subset(thighs | {"glute", "pelvis"})
        t0, t1 = z("pelvis") - 0.17, z("pelvis") + 0.035
        lames = 0.0035 * sawtooth(t1 - G.Z, 0.068)
        d = np.maximum(shell(f - lames, 0.03, 0.037), band(G.Z, t0, t1))
        d = np.maximum(d, G.Y - 0.0)
        d = np.maximum(d, 0.03 - np.abs(G.X))                        # a gap down the middle
        return d
    parts.append(Part("cuisses", "plate", cuisses, np.array([-0.3, -0.25, kz + 0.05]),
                      np.array([0.3, 0.2, z("pelvis") - 0.1]), 2400, voxel=0.002, facet_deg=40))
    if with_tassets:
        parts.append(Part("tassets", "plate", tassets, np.array([-0.32, -0.3, z("pelvis") - 0.2]),
                          np.array([0.32, 0.1, z("pelvis") + 0.07]), 1700, voxel=0.002, facet_deg=40))

    def greaves(G):
        f = G.subset(lower)
        keel = 0.006 * np.clip(1.0 - np.abs(G.X - knee_x(G)) / 0.018, 0, 1) * (G.Y < 0.0)
        d = np.maximum(shell(f - keel, 0.012, 0.018), band(G.Z, z("ankle_l") + 0.05, kz - 0.06))
        top = np.maximum(np.abs(f - 0.016) - 0.004, np.abs(G.Z - (kz - 0.064)) - 0.005)
        return np.minimum(d, top)
    parts.append(Part("greaves", "plate", greaves, np.array([-0.3, -0.25, z("ankle_l") + 0.02]),
                      np.array([0.3, 0.25, kz - 0.03]), 2000, voxel=0.0018, facet_deg=40))
    for side, sx in (("l", 1.0), ("r", -1.0)):
        k = b.j[f"knee_{side}"]
        c = k + np.array([0.0, -0.05, 0.01]) * b.S
        R = np.array([0.06, 0.047, 0.066]) * b.S
        plo, phi = c - np.array([0.13, 0.16, 0.13]), c + 0.13

        def cop(G, c=c, sx=sx, R=R):
            q = [np.abs(G.X - c[0]) / R[0], np.abs(G.Y - c[1]) / R[1], np.abs(G.Z - c[2]) / R[2]]
            dome = ((q[0] ** 2.6 + q[1] ** 2.6 + q[2] ** 2.6) ** (1 / 2.6) - 1.0) * min(R)
            back = G.Y - (c[1] + 0.014)
            d = np.maximum(np.maximum(shell(dome, -0.005, 0.0), back), band(G.Z, c[2] - R[2] * 0.85, c[2] + R[2] * 0.85))
            front = c + np.array([0.0, -R[1] + 0.004, 0.0])
            return spikes(d, G, [(front, front + np.array([0.0, -0.045, -0.006]) * b.S, 0.014 * b.S, 0.0015)])
        parts.append(Part(f"knee_{side}", "plate", cop, plo, phi, 1300, skin=f"calf_{side}", voxel=0.0015,
                          facet_deg=40))
    return parts


def warblade_sabatons(b: Body) -> list[Part]:
    parts = []
    for side in ("l", "r"):
        fn, lo, hi = plate_sabaton(b, side, pointed=0.03)
        parts.append(Part(f"sabaton_{side}", "plate", fn, lo, hi, 3000, skin="transfer", voxel=0.0015, facet_deg=40))
    return parts


def warblade_war_cloak(b: Body) -> list[Part]:
    """A heavy war cloak from the shoulders to the knees, torn into strips at the bottom, under a
    thick fur ruff across the shoulders."""
    z = b.z
    top = z("chest_top") + 0.01
    bottom = z("knee_l") + 0.02
    lo = np.array([-0.46, -0.2, bottom - 0.08])
    hi = np.array([0.46, 0.45, top + 0.1])

    def cloak(G):
        f = G.subset(K._torso_names() | {"deltoid"})
        drape = np.maximum(shell(f, 0.024, 0.032), np.abs(G.X) - 0.2 * b.S)
        t = np.clip((top - G.Z) / (top - bottom), 0, 1)
        y_sheet = (0.15 + 0.1 * t * t) * b.S + (0.02 * np.sin(G.X * 26.0 + 0.6 * np.sin(G.Z * 8.0)) +
                                                 0.008 * np.sin(G.X * 63.0 + 1.1)) * (0.2 + t)
        half_w = (0.23 + 0.1 * t) * b.S
        hem = K._hem_line(G.X * 5.0, bottom, amp=0.02)
        sheet = np.maximum(np.abs(G.Y - y_sheet) - 0.0065, np.abs(G.X) - half_w)
        upper = np.where(G.Y > 0.05, drape, 1.0)
        d = smin(np.where(G.Z > z("chest") + 0.05, upper, 1.0), np.where(G.Z < z("chest") + 0.12, sheet, 1.0), 0.06)
        d = np.maximum(d, band(G.Z, hem, top))
        # torn into strips over the lowest quarter: slits of uneven length
        u = G.X / 0.055 + 0.3 * np.sin(G.X * 13.0)
        slit = np.abs(sawtooth(u, 1.0) - 0.5) * 0.055 - 0.004
        length = bottom + (top - bottom) * (0.2 + 0.08 * np.sin(np.floor(u) * 2.7))
        d = np.maximum(d, -np.maximum(slit, G.Z - length))
        return np.maximum(d, -G.Y - 0.02)

    def ruff(G):
        f = G.subset(K._torso_names() | {"deltoid"})
        ang = np.arctan2(G.X, G.Y)
        tuft = 0.009 * (0.5 + 0.5 * np.sin(ang * 34.0 + np.sin(G.Z * 90.0))) * (0.5 + 0.5 * np.sin(G.Z * 140.0 + ang * 9))
        d = np.maximum(shell(f - tuft, 0.02, 0.05), band(G.Z, top - 0.055, top + 0.06))
        d = np.maximum(d, -G.Y - 0.03)                                # round the back and over the shoulders
        return np.maximum(d, np.abs(G.X) - 0.26 * b.S)
    return [Part("cloak", "cloth", cloak, lo, hi, 6000, voxel=0.0025),
            Part("cloak_ruff", "fur", ruff, lo, hi, 2000, voxel=0.0025)]


DESIGNS = {
    "warblade_horned_helm": warblade_horned_helm,
    "warblade_pauldrons": warblade_pauldrons,
    "warblade_cuirass": warblade_cuirass,
    "warblade_gauntlets": warblade_gauntlets,
    "warblade_girdle": warblade_girdle,
    "warblade_legplates": warblade_legplates,
    "warblade_sabatons": warblade_sabatons,
    "warblade_war_cloak": warblade_war_cloak,
}
