"""The Deathsworn's default plate set, "Rimebound" (backlog G-07): grave-cold dark iron with bone
trim and frost. Read at a distance by a crown of five glowing ice crystals on a narrow
skull-faced helm and a long cape torn into strips that flares out behind the legs.

Built like the Templar and Warblade sets (tools/blender/armor_kit.py, armor_warblade.py). "ice"
parts glow in game (build_piece.GLOW). Coordinates: metres, +Z up, facing -Y, left is +X.
"""
from __future__ import annotations

import numpy as np

import armor_kit as K
import armor_warblade as W
from armor_kit import Body, Part, band, ellipsoid, on_surface, shell, smin, studs, superellipse


def crystal(X, Y, Z, a, t, r, sides=6):
    """A faceted crystal from base `a` to tip `t`: a `sides`-sided prism of radius r, narrower at
    its foot and drawn to a point over its upper 40%."""
    a, t = np.asarray(a, float), np.asarray(t, float)
    L = float(np.linalg.norm(t - a))
    ax = (t - a) / L
    e1 = np.cross(ax, [0.0, 1.0, 0.0] if abs(ax[1]) < 0.9 else [1.0, 0.0, 0.0])
    e1 /= np.linalg.norm(e1)
    e2 = np.cross(ax, e1)
    qx, qy, qz = X - a[0], Y - a[1], Z - a[2]
    h = qx * ax[0] + qy * ax[1] + qz * ax[2]
    p1 = qx * e1[0] + qy * e1[1] + qz * e1[2]
    p2 = qx * e2[0] + qy * e2[1] + qz * e2[2]
    poly = None
    for k in range(sides):
        th = 2 * np.pi * k / sides
        v = p1 * np.cos(th) + p2 * np.sin(th)
        poly = v if poly is None else np.maximum(poly, v)
    rh = r * np.clip((L - h) / (0.4 * L), 0, 1) * (0.8 + 0.2 * np.clip(h / (0.15 * L), 0, 1))
    return np.maximum(poly - rh, np.maximum(-h, h - L))


def crystals(d, G, items):
    """Union of crystals (base, tip, radius) into `d`, each in a small window of the grid."""
    d = np.array(d, dtype=np.float32, copy=True)
    shape = d.shape
    for a, t, r in items:
        a, t = np.asarray(a, float), np.asarray(t, float)
        i0 = np.maximum(np.floor((np.minimum(a, t) - r * 2 - G.lo) / G.voxel).astype(int), 0)
        i1 = np.minimum(np.ceil((np.maximum(a, t) + r * 2 - G.lo) / G.voxel).astype(int) + 1, np.array(shape))
        if np.any(i1 <= i0):
            continue
        s = crystal(G.X[i0[0]:i1[0]], G.Y[:, i0[1]:i1[1]], G.Z[:, :, i0[2]:i1[2]], a, t, r)
        win = d[i0[0]:i1[0], i0[1]:i1[1], i0[2]:i1[2]]
        np.minimum(win, np.broadcast_to(s, win.shape).astype(np.float32), out=win)
    return d


def deathsworn_skull_helm(b: Body) -> list[Part]:
    """A narrow helm narrowing to a skull's jaw: a face plate with a heavy brow, angular slanted
    eye holes over glowing eyes, raised cheekbones, a triangular nose hole and a jaw guard with
    teeth; a bone circlet round the brow carries a crown of five ice crystals, the middle one
    tallest. A mail coif hangs below it (the Templar's aventail)."""
    s, hz = b.hs, b.hz
    cy = 0.006 * s
    rx, ry = 0.104 * s, 0.136 * s
    z0 = hz - 0.045 * s
    eye_z = hz + 0.12 * s
    cz = hz + 0.185 * s                       # the circlet
    lo = np.array([-0.15, cy - 0.2, z0 - 0.03])
    hi = np.array([0.15, cy + 0.19, hz + 0.29 * s])
    fy = cy - ry                              # the front of the face plate

    def narrow(Z):
        return 1.0 - 0.26 * np.clip((hz + 0.075 * s - Z) / (0.11 * s), 0, 1)

    def outer_field(G):
        skull = ellipsoid(G.X, G.Y, G.Z, (0.0, cy, hz + 0.13 * s), (rx, ry * 0.985, 0.14 * s))
        low = np.maximum(superellipse(G.X, G.Y, 0.0, cy, rx * narrow(G.Z), ry, 2.5), band(G.Z, z0 - 0.02, hz + 0.13 * s))
        d = smin(skull, low, 0.02)
        front = K._sig((cy - 0.07 - G.Y) / 0.004)
        ang = np.abs(np.arctan2(G.X, -(G.Y - cy)))
        brow = 0.007 * K._sig((G.Z - (eye_z + 0.016 * s)) / 0.001) * K._sig((eye_z + 0.036 * s - G.Z) / 0.001) \
            * K._sig((1.0 - ang) / 0.02)
        cheek = 0.0
        for sx in (1.0, -1.0):
            dist = np.sqrt(((G.X - sx * 0.052 * s) / 1.4) ** 2 + (G.Z - (hz + 0.084 * s)) ** 2)
            cheek = cheek + 0.008 * np.clip(1.0 - dist / (0.03 * s), 0, 1) * front
        teeth = 0.0025 * np.cos(G.X * 2 * np.pi / (0.0135 * s)) ** 6 * (np.abs(G.X) < 0.036 * s) \
            * (band(G.Z, hz + 0.014 * s, hz + 0.054 * s) < 0) * front
        return d - brow - cheek - teeth

    def holes(G):
        out = None
        for sx in (1.0, -1.0):
            xo = np.abs(G.X) - 0.036 * s
            eye = np.abs(G.X - sx * 0.036 * s) / (0.025 * s) + np.abs(G.Z - eye_z + 0.3 * xo) / (0.0135 * s) - 1.0
            eye = eye * 0.01 * s
            out = eye if out is None else np.minimum(out, eye)
        nose = np.maximum(np.abs(G.X) * 1.7 - (G.Z - (hz + 0.07 * s)) * 0.6, G.Z - (hz + 0.1 * s))
        nose = np.maximum(nose, hz + 0.07 * s - G.Z)
        mouth = np.maximum(np.abs(G.Z - (hz + 0.056 * s)) - 0.0018 * s, np.abs(G.X) - 0.034 * s)
        return np.maximum(np.minimum(np.minimum(out, nose), mouth), G.Y - (cy - 0.06))

    def helm(G):
        outer = outer_field(G)
        d = np.maximum(shell(outer, -0.0048, 0.0), band(G.Z, z0, hz + 0.3 * s))
        d = np.minimum(d, np.maximum(np.abs(outer + 0.0032) - 0.006, np.abs(G.Z - z0 - 0.006) - 0.006))
        d = np.maximum(d, -holes(G))
        riv = K.ring_points(rx, ry, z0 + 0.022, 18, cy=cy, keep=lambda x, y: abs(x) > 0.035 * s)
        riv = on_surface(outer_field, riv, (0.0, cy), sink=0.0012)
        return studs(d, G, riv, 0.0032)

    def liner(G):
        return np.maximum(shell(outer_field(G), -0.0165, -0.0125), band(G.Z, z0 + 0.012, hz + 0.25 * s))

    def eyes(G):
        d = None
        for sx in (1.0, -1.0):
            e = ellipsoid(G.X, G.Y, G.Z, (sx * 0.036 * s, fy + 0.013, eye_z), (0.02 * s, 0.004, 0.011 * s))
            d = e if d is None else np.minimum(d, e)
        return d

    def circlet_ring(G):
        outer = outer_field(G)
        return np.maximum(shell(outer, 0.0005, 0.0065), np.abs(G.Z - cz) - 0.011 * s)

    def crown_points():
        out = []
        for ang, ln, r in ((0.0, 0.17, 0.014), (0.42, 0.13, 0.012), (-0.42, 0.13, 0.012),
                           (0.86, 0.095, 0.0105), (-0.86, 0.095, 0.0105)):
            p = np.array([np.sin(ang) * rx * 1.02, cy - np.cos(ang) * ry * 1.0, cz + 0.008 * s])
            p = on_surface(outer_field, [p], (0.0, cy), sink=-0.003)[0]
            radial = np.array([np.sin(ang), -np.cos(ang), 0.0])
            dirn = radial * 0.22 + np.array([0.0, 0.28, 1.0])
            dirn /= np.linalg.norm(dirn)
            out.append((p - dirn * 0.01, p + dirn * ln * s, r * s))
        return out

    def circlet(G):
        d = circlet_ring(G)
        # a bone socket round the foot of each crystal
        socks = [(a, a + (t - a) / np.linalg.norm(t - a) * 0.02, r * 1.35, r * 1.1) for a, t, r in crown_points()]
        return W.spikes(d, G, socks)

    def crown(G):
        return crystals(np.full(np.broadcast_shapes(G.X.shape, G.Y.shape, G.Z.shape), 1.0, np.float32), G,
                        crown_points())
    clo = np.array([-0.15, cy - 0.21, cz - 0.03])
    chi = np.array([0.15, cy + 0.05, hz + 0.43 * s])
    return [Part("helm", "plate", helm, lo, hi, 4400, skin="head", voxel=0.0015, facet_deg=40),
            Part("helm_liner", "leather", liner, lo, hi, 300, skin="head", voxel=0.003),
            Part("helm_eyes", "ice", eyes, lo, hi, 200, skin="head", voxel=0.0015),
            Part("circlet", "bone", circlet, lo, hi, 1300, skin="head", voxel=0.0015, facet_deg=40),
            Part("crown", "ice", crown, clo, chi, 1500, skin="head", voxel=0.0013, facet_deg=30)] \
        + K.templar_aventail(b)


def deathsworn_pauldrons(b: Body) -> list[Part]:
    """Angular pauldrons sloping away from the neck with a ridge across them, one lame below, a
    bone band along the edges, and three ice shards breaking out of the top, leaning back."""
    parts = []
    S = b.S
    for side, sx in (("l", 1.0), ("r", -1.0)):
        sh = b.j[f"shoulder_{side}"]
        el = b.j[f"elbow_{side}"]
        ax = (el - sh) / np.linalg.norm(el - sh)
        c = sh + np.array([sx * 0.015, 0.0, 0.04]) * S
        R = np.array([0.112, 0.12, 0.095]) * S
        lo = c - np.array([0.21, 0.21, 0.19])
        hi = c + np.array([0.21, 0.24, 0.26])

        def along_of(G, c=c, ax=ax):
            return (G.X - c[0]) * ax[0] + (G.Y - c[1]) * ax[1] + (G.Z - c[2]) * ax[2]

        def boxy(G, cc, RR, n=3.4):
            q = [np.abs(G.X - cc[0]) / RR[0], np.abs(G.Y - cc[1]) / RR[1], np.abs(G.Z - cc[2]) / RR[2]]
            return ((q[0] ** n + q[1] ** n + q[2] ** n) ** (1.0 / n) - 1.0) * min(RR)

        def dome_of(G, c=c, R=R, boxy=boxy, sx=sx):
            slope = 0.25 * np.clip((G.X - c[0]) * sx, 0, None)           # lower toward the arm
            ridge = 0.01 * S * np.clip(1.0 - np.abs(G.Y - c[1]) / 0.025, 0, 1) ** 2
            return boxy(G, c, R) + slope - ridge

        def inner_cut(G, c=c, sx=sx):
            return (c[0] - sx * 0.07) * sx - G.X * sx

        def cap(G, c=c, ax=ax, sx=sx, R=R, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut, boxy=boxy):
            dome = dome_of(G)
            along = along_of(G)
            d = np.maximum(np.maximum(shell(dome, -0.0055, 0.0), along - 0.04), inner_cut(G))
            lame = boxy(G, c + ax * 0.062, R - 0.004)
            ld = np.maximum(np.maximum(shell(lame, -0.0048, 0.0), np.abs(along - 0.062) - 0.02),
                            (c[0] - sx * 0.04) * sx - G.X * sx)
            return np.minimum(d, ld)

        def trim(G, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut):
            d = np.maximum(shell(dome_of(G), -0.001, 0.0035), np.abs(along_of(G) - 0.03) - 0.008)
            return np.maximum(d, inner_cut(G) - 0.004)

        def shard_points(c=c, R=R, sx=sx, dome_of=dome_of):
            out = []
            for dx, dy, ln, r in ((-0.02, 0.03, 0.12, 0.013), (0.025, 0.045, 0.09, 0.011), (-0.055, 0.02, 0.075, 0.009)):
                p = np.array([c[0] + sx * dx * S, c[1] + dy * S, c[2] + R[2]])
                p = K.on_surface_dir(lambda P: dome_of(P), [p], (0, 0, 1.0), sink=0.012)[0]
                dirn = np.array([sx * 0.3, 0.45, 1.0])
                dirn /= np.linalg.norm(dirn)
                out.append((p, p + dirn * ln * S, r * S))
            return out

        def shards(G, shard_points=shard_points):
            return crystals(np.full(np.broadcast_shapes(G.X.shape, G.Y.shape, G.Z.shape), 1.0, np.float32), G,
                            shard_points())
        bone = f"upperarm_{side}"
        parts.append(Part(f"pauldron_{side}", "plate", cap, lo, hi, 3200, skin=bone, voxel=0.0015, facet_deg=40))
        parts.append(Part(f"pauldron_trim_{side}", "bone", trim, lo, hi, 800, skin=bone, voxel=0.0015, facet_deg=40))
        parts.append(Part(f"pauldron_ice_{side}", "ice", shards, lo, hi, 1000, skin=bone, voxel=0.0013, facet_deg=30))
        parts.append(W.rerebrace(b, side))
    return parts


def deathsworn_ribplate(b: Body) -> list[Part]:
    """Chest slot: a mail shirt with long sleeves under a dark breastplate shaped like a rib cage
    (ribs arching down from a raised sternum), a back plate, a bone band round the neck, a glowing
    rune over the heart and a long under-robe split into panels with torn hems."""
    z = b.z
    neck_z = z("chest_top") + 0.02
    belt = z("pelvis") + 0.06
    waist = z("spine") - 0.01
    top = neck_z - 0.014
    hem = z("knee_l") - 0.1
    lo = np.array([-0.75, -0.33, hem - 0.08])
    hi = np.array([0.75, 0.31, neck_z + 0.06])
    sh_l = b.j["shoulder_l"]
    torso = K._torso_names()
    rune_z = z("chest") - 0.035
    rib_lo, rib_hi = waist + 0.03, z("chest") + 0.07

    def rune_shape(X, Z):
        """A diamond outline crossed by a bar, with a stroke down through it (flat, in X and Z)."""
        dia = np.abs(X) / 0.024 + np.abs(Z - rune_z) / 0.038
        outline = np.abs(dia - 0.8) * 0.02 - 0.0028
        bar = np.maximum(np.abs(Z - rune_z - 0.006) - 0.0028, np.abs(X) - 0.026)
        stroke = np.maximum(np.abs(X) - 0.0028, np.abs(Z - rune_z) - 0.05)
        return np.minimum(np.minimum(outline, bar), stroke)

    def ribs(G):
        inside = (G.Y < 0) * (G.Z > rib_lo) * (G.Z < rib_hi) * (np.abs(G.X) < 0.145)
        rz = G.Z + 0.06 * (np.abs(G.X) / 0.14) ** 1.5
        rib = 0.0052 * np.clip(np.cos(2 * np.pi * (rz - rib_lo) / 0.034), 0, 1) ** 2 * (np.abs(G.X) > 0.02)
        sternum = 0.0065 * np.clip(1.0 - np.abs(G.X) / 0.013, 0, 1)
        clear = rune_shape(G.X, G.Z) > 0.01                            # flat round the rune
        return (rib + sternum) * inside * clear

    def holes(G):
        return [np.sqrt((G.X - sx * sh_l[0] * 0.9) ** 2 + (G.Y - sh_l[1]) ** 2 + ((G.Z - sh_l[2] + 0.05) * 0.85) ** 2)
                - 0.115 for sx in (1.0, -1.0)]

    def plate_body(G, inner, outer):
        f = G.subset(torso)
        front = np.maximum(shell(f - ribs(G), inner, outer), band(G.Z, waist - 0.05, top))
        back = np.maximum(shell(f, inner, outer), np.maximum(band(G.Z, belt - 0.01, top), -G.Y))
        d = np.minimum(np.where(G.Y < 0.0, front, 1.0), back)
        for h in holes(G):
            d = np.maximum(d, -h)
        neck = np.sqrt(G.X ** 2 + (G.Y * 0.95) ** 2) - 0.105
        return np.maximum(d, -np.where(G.Z > top - 0.08, neck, 1.0)), f

    def plate(G):
        return plate_body(G, 0.017, 0.0255)[0]

    def bone_trim(G):
        d, f = plate_body(G, 0.0245, 0.0295)
        return np.maximum(d, np.abs(G.Z - top) - 0.017)

    def rune(G):
        f = G.subset(torso)
        return np.maximum(np.maximum(shell(f, 0.0235, 0.0295), rune_shape(G.X, G.Z)), G.Y)

    def robe(G):
        t = np.clip((belt - G.Z) / (belt - hem), 0, 1)
        rx = (0.17 + 0.08 * t + 0.01 * b.fem) * b.S
        ry = (0.13 + 0.06 * t) * b.S
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        folds = (0.012 * np.sin(ang * 9.0) + 0.005 * np.sin(ang * 19.0 + 2.0 * t)) * t ** 0.8
        d = np.abs(superellipse(G.X, G.Y, 0.0, 0.01, rx, ry, 2.2) + folds) - 0.0045
        d = np.maximum(d, band(G.Z, K._hem_line(ang, hem, amp=0.018), belt + 0.03))
        # four panels: split front, back and at both sides, the splits widening toward the hem
        w = 0.01 + 0.03 * t
        split = np.minimum(np.abs(G.X) - w, np.abs(G.Y - 0.01) - w)
        return np.maximum(d, -np.where(G.Z < belt - 0.08, split, 1.0))

    return [Part("mail_shirt", "mail", W.mail_shirt(b, z("knee_l") + 0.3, neck_z), lo, hi, 5600, voxel=0.0025),
            Part("ribplate", "plate", plate, lo, hi, 8800, voxel=0.0018, facet_deg=40),
            Part("ribplate_bone", "bone", bone_trim, lo, hi, 1600, voxel=0.0018, facet_deg=40),
            Part("ribplate_rune", "ice", rune, np.array([-0.08, -0.3, rune_z - 0.07]), np.array([0.08, 0.0, rune_z + 0.07]),
                 500, voxel=0.0012),
            Part("robe", "cloth", robe, lo, hi, 7500, voxel=0.0025)]


def deathsworn_claws(b: Body) -> list[Part]:
    """Clawed gauntlets: pointed plates over the fingertips, knuckle bosses, flared cuffs."""
    parts = []
    for side in ("l", "r"):
        fn, lo, hi = W.plate_gauntlet(b, side, cuff_len=0.13, knuckle_spikes=False, claws=True)
        parts.append(Part(f"gauntlet_{side}", "plate", fn, lo, hi, 3300, skin=f"hand_{side}", voxel=0.0013,
                          facet_deg=45))
        parts.append(W.couter(b, side, spike=False))
    return parts


def deathsworn_loincloth(b: Body) -> list[Part]:
    """A leather belt with a bone plaque at the front carrying a glowing rune, and narrow cloth
    panels hanging front and back to the knees, torn at the bottom."""
    zb = b.z("pelvis") + 0.06
    S = b.S
    hem = b.z("knee_l") + 0.02
    fy = -0.155 * S
    lo = np.array([-0.3, -0.33, hem - 0.08])
    hi = np.array([0.3, 0.33, zb + 0.06])

    def strap(G):
        f = G.subset(K._torso_names())
        return np.maximum(shell(f, 0.021, 0.032), np.abs(G.Z - zb) - 0.024)

    def plaque(G):
        u, w = G.X, G.Z - zb
        shape = np.maximum(np.abs(u) * 0.8 + np.abs(w) * 0.55, np.abs(w)) - 0.036
        return np.maximum(shape, np.abs(G.Y - (fy - 0.038)) - 0.006)

    def rune(G):
        u, w = G.X, G.Z - zb
        dia = np.abs(u) / 0.016 + np.abs(w) / 0.024
        mark = np.minimum(np.abs(dia - 0.8) * 0.014 - 0.0022, np.maximum(np.abs(u) - 0.0022, np.abs(w) - 0.026))
        return np.maximum(mark, np.abs(G.Y - (fy - 0.0455)) - 0.0028)

    def panels(G):
        t = np.clip((zb - 0.03 - G.Z) / (zb - 0.03 - hem), 0, 1)
        half_w = 0.075 * S * (1.0 + 0.2 * t)
        fold = 0.006 * np.sin(G.X * 70.0) * t
        hl = K._hem_line(G.X * 9.0, hem, amp=0.015)
        front = np.maximum(np.abs(G.Y - (fy - 0.032 - 0.03 * t + fold)) - 0.0045, np.abs(G.X) - half_w)
        back = np.maximum(np.abs(G.Y - (0.15 * S + 0.03 + 0.035 * t + fold)) - 0.0045, np.abs(G.X) - half_w * 1.1)
        return np.maximum(np.minimum(front, back), band(G.Z, hl, zb - 0.01))
    return [Part("belt", "leather", strap, lo, hi, 900, voxel=0.0018, skin="pelvis"),
            Part("belt_plaque", "bone", plaque, lo, hi, 500, voxel=0.0015, skin="pelvis", facet_deg=40),
            Part("belt_rune", "ice", rune, lo, hi, 200, voxel=0.0012, skin="pelvis"),
            Part("loincloth", "cloth", panels, lo, hi, 1400, voxel=0.0022)]


def deathsworn_legplates(b: Body) -> list[Part]:
    return W.warblade_legplates(b, with_tassets=False)


def deathsworn_sabatons(b: Body) -> list[Part]:
    parts = []
    for side in ("l", "r"):
        fn, lo, hi = W.plate_sabaton(b, side, pointed=0.045)
        parts.append(Part(f"sabaton_{side}", "plate", fn, lo, hi, 3000, skin="transfer", voxel=0.0015, facet_deg=40))
    return parts


def deathsworn_grave_cape(b: Body) -> list[Part]:
    """A long cape from the shoulders to the ankles, flaring well out behind the legs, torn into
    long strips over its lower half."""
    z = b.z
    top = z("chest_top") + 0.01
    bottom = z("ankle_l") + 0.06
    lo = np.array([-0.5, -0.2, bottom - 0.08])
    hi = np.array([0.5, 0.62, top + 0.06])

    def fn(G):
        f = G.subset(K._torso_names() | {"deltoid"})
        drape = np.maximum(shell(f, 0.022, 0.03), np.abs(G.X) - 0.2 * b.S)
        t = np.clip((top - G.Z) / (top - bottom), 0, 1)
        y_sheet = (0.15 + 0.3 * t * t) * b.S + (0.024 * np.sin(G.X * 24.0 + 0.7 * np.sin(G.Z * 7.0)) +
                                                 0.009 * np.sin(G.X * 59.0 + 1.3)) * (0.2 + t)
        half_w = (0.22 + 0.17 * t) * b.S
        hem = K._hem_line(G.X * 5.0, bottom, amp=0.03)
        sheet = np.maximum(np.abs(G.Y - y_sheet) - 0.006, np.abs(G.X) - half_w)
        upper = np.where(G.Y > 0.05, drape, 1.0)
        d = smin(np.where(G.Z > z("chest") + 0.05, upper, 1.0), np.where(G.Z < z("chest") + 0.12, sheet, 1.0), 0.06)
        d = np.maximum(d, band(G.Z, hem, top))
        u = G.X / 0.07 + 0.4 * np.sin(G.X * 11.0)
        slit = np.abs(K.sawtooth(u, 1.0) - 0.5) * 0.07 - 0.005
        length = bottom + (top - bottom) * (0.35 + 0.15 * np.sin(np.floor(u) * 2.3))
        d = np.maximum(d, -np.maximum(slit, G.Z - length))
        return np.maximum(d, -G.Y - 0.02)
    return [Part("cape", "cloth", fn, lo, hi, 8000, voxel=0.0025)]


DESIGNS = {
    "deathsworn_skull_helm": deathsworn_skull_helm,
    "deathsworn_pauldrons": deathsworn_pauldrons,
    "deathsworn_ribplate": deathsworn_ribplate,
    "deathsworn_claws": deathsworn_claws,
    "deathsworn_loincloth": deathsworn_loincloth,
    "deathsworn_legplates": deathsworn_legplates,
    "deathsworn_sabatons": deathsworn_sabatons,
    "deathsworn_grave_cape": deathsworn_grave_cape,
}
