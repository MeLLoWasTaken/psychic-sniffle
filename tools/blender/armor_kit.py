"""Modular armor for the overhaul characters (backlog G-03), and the designs of each set (G-04 on).

A piece (one armor slot of one set, for one body type) is a list of parts. Each part is a distance
field evaluated on its own grid around the body, a material channel, a skinning rule and a share
of the piece's triangle budget. Parts are extracted densely (the normal map's source) and reduced
for the game; build_piece.py does the meshing, baking and skinning.

Fields are written with broadcast axes (G.X, G.Y, G.Z) rather than point lists, so a grid of tens
of millions of samples never needs a coordinate array; G.body is the body's field on the grid.

Material channels (the character shader's dye mask, docs/DESIGN.md "Appearance and armor
customization"): "primary" cloth, "secondary" trim and emblems, "metal" plate and mail, and
undyed "leather". Coordinates: metres, +Z up, the character faces -Y, its left is +X.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

import anatomy
import humanoid
import sdf

CHANNELS = ("primary", "secondary", "metal", "leather")


@dataclass
class Part:
    name: str
    material: str                   # plate, mail, cloth, trim, gold, leather (see build_piece.MATERIALS)
    fn: object                      # fn(G) -> field on G's grid
    lo: np.ndarray
    hi: np.ndarray
    tris: int
    skin: str = "transfer"          # "transfer" (weights from the body) or a bone name (rigid)
    voxel: float = 0.0025
    facet_deg: float = 0.0          # > 0: flat-shade edges sharper than this (plate edges)
    rivets: list = field(default_factory=list)   # (centre, radius) of rivet heads (dense mesh only)


class Grid:
    """A sampling grid with broadcast axes and lazily evaluated body fields."""

    def __init__(self, lo, hi, voxel: float, shape: sdf.Shape):
        self.lo = np.asarray(lo, float)
        self.voxel = voxel
        self.n = np.ceil((np.asarray(hi, float) - self.lo) / voxel).astype(int) + 1
        ax = [(self.lo[d] + voxel * np.arange(self.n[d])).astype(np.float32) for d in range(3)]
        self.X = ax[0][:, None, None]
        self.Y = ax[1][None, :, None]
        self.Z = ax[2][None, None, :]
        self._shape = shape
        self._body = None
        self._subsets: dict = {}

    @property
    def body(self) -> np.ndarray:
        if self._body is None:
            self._body = sdf.eval_grid(self._shape, self.lo, self.n, self.voxel)
        return self._body

    def subset(self, names: set[str]) -> np.ndarray:
        key = tuple(sorted(names))
        if key not in self._subsets:
            self._subsets[key] = sdf.eval_grid(sdf.subset(self._shape, names), self.lo, self.n, self.voxel)
        return self._subsets[key]

    def prims(self, sh: sdf.Shape) -> np.ndarray:
        """Field of a small primitive shape on this grid."""
        return sdf.eval_grid(sh, self.lo, self.n, self.voxel)


# ----------------------------------------------------------------------------- field helpers

def shell(f, inner: float, outer: float):
    return np.maximum(f - outer, inner - f)


def above(Z, z0):           # negative above z0
    return z0 - Z


def below(Z, z0):           # negative below z0
    return Z - z0


def band(Z, z0, z1):        # negative between z0 and z1
    return np.maximum(z0 - Z, Z - z1)


def smin(a, b, k):
    return sdf.smin(a, b, k)


def smax(a, b, k):
    return sdf.smax(a, b, k)


def superellipse(X, Y, cx, cy, rx, ry, n=3.0):
    """Approximate distance to a rounded-rectangle cylinder (vertical axis)."""
    u = np.abs(X - cx) / rx
    w = np.abs(Y - cy) / ry
    r = (u ** n + w ** n) ** (1.0 / n)
    return (r - 1.0) * np.minimum(rx, ry)


def ellipsoid(X, Y, Z, c, r):
    k0 = np.sqrt(((X - c[0]) / r[0]) ** 2 + ((Y - c[1]) / r[1]) ** 2 + ((Z - c[2]) / r[2]) ** 2)
    return (k0 - 1.0) * min(r)


def capsule(X, Y, Z, a, b, r):
    a, b = np.asarray(a, float), np.asarray(b, float)
    ba = b - a
    h = np.clip(((X - a[0]) * ba[0] + (Y - a[1]) * ba[1] + (Z - a[2]) * ba[2]) / (ba @ ba), 0.0, 1.0)
    return np.sqrt((X - a[0] - ba[0] * h) ** 2 + (Y - a[1] - ba[1] * h) ** 2 + (Z - a[2] - ba[2] * h) ** 2) - r


def sun(X, Y, Z, c, axis: int, r: float, rays: int, thick: float):
    """A raised sun emblem: a disc and pointed rays in the plane normal to `axis` (0 x, 1 y)."""
    if axis == 1:
        u, w, d = X - c[0], Z - c[2], Y - c[1]
    else:
        u, w, d = Y - c[1], Z - c[2], X - c[0]
    rad = np.sqrt(u * u + w * w)
    ang = np.arctan2(w, u)
    ray = (0.5 + 0.5 * np.cos(ang * rays)) ** 3
    outline = r * (0.45 + 0.55 * ray)
    flat = rad - outline
    ring = np.abs(rad - r * 0.42) - r * 0.06
    disc = np.minimum(flat, ring)
    return np.maximum(disc, np.abs(d) - thick)


class Body:
    """Joints, landmarks and the field of one body type."""

    def __init__(self, body_type: str, hands=("relaxed", "fist")):
        self.type = body_type
        self.j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[body_type]).items()}
        self.shape = anatomy.body_shape(self.j, body_type, hands)
        self.S = float(self.j["head_top"][2]) / anatomy.REF_HEIGHT
        self.hz, self.hs = anatomy.head_frame(self.j, body_type)
        self.fem = anatomy.TYPES[body_type]["fem"]

    def z(self, name: str) -> float:
        return float(self.j[name][2])


# ----------------------------------------------------------------------------- Templar crusader set

def templar_great_helm(b: Body) -> list[Part]:
    """A flat-topped great helm: a slightly tapered barrel enclosing the head, a flat crown plate,
    a horizontal eye slit broken by a vertical cross band, breaths on the right cheek, gold edges
    and a small sun on the cross band below the slit."""
    s, hz = b.hs, b.hz
    cy = 0.006 * s
    rx, ry = 0.117 * s, 0.142 * s
    z0, z1 = hz - 0.045 * s, hz + 0.268 * s   # low enough that the chin stays inside when the head bends
    eye_z = hz + 0.122 * s
    lo = np.array([-0.17, cy - 0.2, z0 - 0.03])
    hi = np.array([0.17, cy + 0.2, z1 + 0.04])

    def taper(Z):
        t = np.clip((Z - z0) / (z1 - z0), 0.0, 1.0)
        return 1.0 - 0.06 * t + 0.03 * np.clip((z0 + 0.04 * s - Z) / (0.04 * s), 0, 1)   # a slight flare at the rim

    def barrel(G):
        k = taper(G.Z)
        outer = superellipse(G.X, G.Y, 0.0, cy, rx * k, ry * k, 2.6)
        d = shell(outer, -0.005, 0.0)
        d = np.maximum(d, band(G.Z, z0, z1))
        top = np.maximum(superellipse(G.X, G.Y, 0.0, cy, rx * 0.95, ry * 0.95, 2.6), np.abs(G.Z - (z1 - 0.004)) - 0.005)
        dome = np.maximum(ellipsoid(G.X, G.Y, G.Z, (0.0, cy, z1 - 0.01), (rx * 0.9, ry * 0.9, 0.035 * s)), above(G.Z, z1 - 0.005))
        d = np.minimum(d, np.minimum(top, dome))
        # the eye slit (both sides of the central band) and the breaths on the right cheek
        slit = np.maximum(np.abs(G.Z - eye_z) - 0.0065 * s, np.maximum(np.abs(G.X) - 0.088 * s, 0.011 * s - np.abs(G.X)))
        slit = np.maximum(slit, G.Y - (cy - 0.05))
        d = np.maximum(d, -slit)
        for i in range(3):
            for k2 in range(4):
                bx = -(0.03 + 0.017 * k2) * s
                bz = hz + (0.04 + 0.022 * i) * s
                hole = np.sqrt((G.X - bx) ** 2 + (G.Z - bz) ** 2) - 0.004 * s
                hole = np.maximum(hole, G.Y - (cy - 0.06))
                d = np.maximum(d, -hole)
        return d

    def cross(G):
        k = taper(G.Z)
        outer = superellipse(G.X, G.Y, 0.0, cy, rx * k, ry * k, 2.6)
        strip = np.maximum(shell(outer, -0.002, 0.004), np.abs(G.X) - 0.012 * s)
        strip = np.maximum(strip, G.Y - (cy - 0.06))
        strip = np.maximum(strip, band(G.Z, z0 + 0.01, z1 - 0.01))
        brow = np.maximum(shell(outer, -0.002, 0.004), np.abs(G.Z - (eye_z + 0.02 * s)) - 0.009 * s)
        brow = np.maximum(brow, np.maximum(G.Y - (cy - 0.03), np.abs(G.X) - 0.1 * s))
        rims = np.maximum(shell(outer, -0.002, 0.004), np.minimum(np.abs(G.Z - (z0 + 0.008)) - 0.008, np.abs(G.Z - (z1 - 0.009)) - 0.007))
        d = np.minimum(np.minimum(strip, brow), rims)
        front = float(cy - ry * taper(np.array(hz + 0.07 * s))) - 0.004
        emblem = sun(G.X, G.Y, G.Z, (0.0, front - 0.003, hz + 0.065 * s), 1, 0.024 * s, 8, 0.003)
        return np.minimum(d, emblem)

    rivets = []
    for i in range(14):
        a = np.pi * 2 * i / 14
        rivets.append((np.array([np.sin(a) * rx * 0.945, cy - np.cos(a) * ry * 0.945, z1 - 0.022]), 0.0045))
    return [Part("helm", "plate", barrel, lo, hi, 2600, skin="head", voxel=0.002, facet_deg=40, rivets=rivets),
            Part("helm_trim", "gold", cross, lo, hi, 1300, skin="head", voxel=0.002, facet_deg=40)]


def templar_aventail(b: Body) -> list[Part]:
    """The mail coif's skirt below the helm, over the neck and the tops of the shoulders."""
    zt = b.z("neck") + 0.09   # up inside the helm, so a bent or turned head never opens a gap
    zb = b.z("chest_top") - 0.08
    lo = np.array([-0.3, -0.25, zb - 0.03])
    hi = np.array([0.3, 0.25, zt + 0.03])

    def fn(G):
        f = G.subset({"neck", "trap", "scm", "clavicle", "upper_back", "ribcage", "pec", "deltoid", "scapula",
                      "breast"})
        d = shell(f, 0.003, 0.016)         # loose enough that the neck turns and bends under it
        d = np.maximum(d, band(G.Z, zb, zt))
        reach = np.sqrt(G.X ** 2 + (G.Y * 1.1) ** 2) - (0.2 + 0.4 * np.clip((zt - G.Z) / (zt - zb), 0, 1) * 0.3)
        d = np.maximum(d, reach)
        hem = (zb + 0.012 * np.sin(np.arctan2(G.X, G.Y) * 14)) - G.Z
        return np.maximum(d, hem)
    return [Part("aventail", "mail", fn, lo, hi, 1400, voxel=0.003)]


def _torso_names():
    return {"ribcage", "abdomen", "pelvis", "upper_back", "pec", "breast", "lat", "oblique", "scapula", "glute",
            "trap", "clavicle", "rectus", "abs", "neck", "scm"}


def templar_surcoat(b: Body) -> list[Part]:
    """Chest slot: a mail hauberk (torso, sleeves to the elbow, a skirt to mid-thigh) under a long
    sleeveless surcoat, split front and back below the belt so the legs swing behind its panels,
    with a gold-edged hem and a large sun on the chest."""
    z = b.z
    neck_z = z("chest_top") + 0.02
    belt = z("pelvis") + 0.06
    skirt = z("knee_l") + 0.24
    hem = z("knee_l") - 0.1
    lo = np.array([-0.75, -0.32, hem - 0.05])
    hi = np.array([0.75, 0.3, neck_z + 0.06])
    sh_l = b.j["shoulder_l"]
    el_l = b.j["elbow_l"]
    torso = _torso_names()
    arms = {"deltoid", "upperarm", "bicep", "tricep", "elbow", "forearm", "forearm_mass", "wrist"}
    legs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor", "glute"}

    def hauberk(G):
        f = G.subset(torso | arms | legs)
        d = shell(f, 0.002, 0.008)
        d = np.maximum(d, below(G.Z, neck_z))
        neck_hole = np.sqrt(G.X ** 2 + (G.Y - 0.01) ** 2) - 0.085
        d = np.maximum(d, -np.where(G.Z > neck_z - 0.06, neck_hole, 1.0))
        # long sleeves: they stop under the gauntlet cuffs, a little before the wrist
        for sx in (1.0, -1.0):
            el = el_l * np.array([sx, 1, 1])
            wr = b.j["wrist_l"] * np.array([sx, 1, 1])
            ax = (wr - el) / np.linalg.norm(wr - el)
            along = (G.X - el[0]) * ax[0] + (G.Y - el[1]) * ax[1] + (G.Z - el[2]) * ax[2]
            beyond = along - (np.linalg.norm(wr - el) - 0.04)
            d = np.where((G.X * sx > 0.16), np.maximum(d, beyond), d)
        # the skirt: split at the front and back so the legs move
        d = np.maximum(d, skirt - G.Z)
        split = np.maximum(np.abs(G.X) - 0.012, z("pelvis") - 0.08 - G.Z)
        return np.maximum(d, -split)

    def skirt_shape(G):
        """Below the belt: a flared skirt around the hips with folds, split at the front and back
        so each half swings with its leg."""
        t = np.clip((belt - G.Z) / (belt - hem), 0, 1)
        rx = (0.175 + 0.1 * t + 0.01 * b.fem) * b.S
        ry = (0.135 + 0.08 * t) * b.S
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        folds = 0.009 * t * np.sin(ang * 9.0)
        d = np.abs(superellipse(G.X, G.Y, 0.0, 0.01, rx, ry, 2.2) + folds) - 0.004
        d = np.maximum(d, band(G.Z, hem + 0.012 * np.cos(ang * 7.0), belt + 0.03))
        slit = np.abs(G.X) - (0.012 + 0.03 * t)                         # widens toward the hem
        return np.maximum(d, -np.where(G.Z < belt - 0.1, slit, 1.0))

    def surcoat_field(G):
        f = G.subset(torso)
        body_over = shell(f, 0.009, 0.02)
        top = np.where(G.Z > belt - 0.02, body_over, 1.0)
        d = smin(top, skirt_shape(G), 0.025)
        d = np.maximum(d, below(G.Z, neck_z - 0.01))
        # sleeveless: arm holes and a neck opening
        for sx in (1.0, -1.0):
            sh = sh_l * np.array([sx, 1, 1])
            hole = np.sqrt((G.X - sh[0] * 0.92) ** 2 + (G.Y - sh[1]) ** 2 + ((G.Z - sh[2] + 0.06) * 0.8) ** 2) - 0.12
            d = np.maximum(d, -hole)
        neck = np.sqrt(G.X ** 2 + ((G.Y - 0.0) * 0.9) ** 2) - 0.12
        d = np.maximum(d, -np.where(G.Z > neck_z - 0.09, neck, 1.0))
        return d

    def surcoat(G):
        return surcoat_field(G)

    def trim(G):
        d = surcoat_field(G)
        t = np.clip((belt - G.Z) / (belt - hem), 0, 1)
        ang = np.arctan2(G.X, -(G.Y - 0.01))
        hem_band = np.abs(G.Z - (hem + 0.012 * np.cos(ang * 7.0) + 0.03)) - 0.022
        slit_edge = np.abs(np.abs(G.X) - (0.012 + 0.03 * t) - 0.012) - 0.012
        edge = np.where(G.Z < belt - 0.1, np.minimum(hem_band, slit_edge), 1.0)
        raised = np.maximum(d - 0.003, -d)
        return np.maximum(raised, edge)

    def emblem(G):
        f = G.subset(torso)
        surface = shell(f, 0.018, 0.024)
        y0 = -0.17 * b.S if b.fem < 0.5 else -0.18 * b.S
        disc = sun(G.X, G.Y, G.Z, (0.0, y0, z("chest") + 0.02), 1, 0.085 * b.S, 12, 0.08)
        return np.maximum(surface, disc)

    return [Part("hauberk", "mail", hauberk, lo, hi, 4200, voxel=0.003),
            Part("surcoat", "cloth", surcoat, lo, hi, 4200, voxel=0.003),
            Part("surcoat_trim", "trim", trim, lo, hi, 1600, voxel=0.0025),
            Part("surcoat_sun", "trim", emblem, np.array([-0.15, -0.3, z("chest") - 0.12]),
                 np.array([0.15, 0.0, z("chest") + 0.16]), 900, voxel=0.0018)]


def templar_belt(b: Body) -> list[Part]:
    zb = b.z("pelvis") + 0.06
    lo = np.array([-0.3, -0.3, zb - 0.06])
    hi = np.array([0.3, 0.3, zb + 0.06])

    def fn(G):
        f = G.subset(_torso_names())
        d = np.maximum(shell(f, 0.02, 0.032), np.abs(G.Z - zb) - 0.022)
        buckle = np.maximum(superellipse(G.X, G.Z, 0.0, zb, 0.034, 0.03, 4) * 1.0, np.abs(G.Y + 0.15 * b.S) - 0.03)
        d = np.minimum(d, np.maximum(buckle, -(np.maximum(np.abs(G.X) - 0.018, np.abs(G.Z - zb) - 0.014))))
        return d
    return [Part("belt", "leather", fn, lo, hi, 900, voxel=0.002, skin="pelvis")]


def templar_spaulders(b: Body) -> list[Part]:
    """Rounded plate spaulders over the shoulders, two lames below each, gold rims."""
    parts = []
    for side, sx in (("l", 1.0), ("r", -1.0)):
        sh = b.j[f"shoulder_{side}"]
        el = b.j[f"elbow_{side}"]
        ax = (el - sh) / np.linalg.norm(el - sh)
        c = sh + np.array([sx * 0.012, 0.0, 0.035]) * b.S
        lo = c - 0.2
        hi = c + 0.2

        def cap(G, c=c, ax=ax, sx=sx):
            dome = ellipsoid(G.X, G.Y, G.Z, c, (0.105 * b.S, 0.115 * b.S, 0.1 * b.S))
            d = shell(dome, -0.006, 0.0)
            # open toward the body and below the dome's equator along the arm
            along = (G.X - c[0]) * ax[0] + (G.Y - c[1]) * ax[1] + (G.Z - c[2]) * ax[2]
            d = np.maximum(d, along - 0.035)
            d = np.maximum(d, (c[0] - sx * 0.07) * sx - G.X * sx)
            for k, off in enumerate((0.055, 0.095)):     # lames hanging down the arm
                lc = c + ax * off
                lame = ellipsoid(G.X, G.Y, G.Z, lc, (0.098 * b.S - 0.008 * k, 0.108 * b.S - 0.008 * k, 0.095 * b.S))
                lame = np.maximum(shell(lame, -0.005, 0.0), np.abs(along - off) - 0.018)
                lame = np.maximum(lame, (c[0] - sx * 0.04) * sx - G.X * sx)
                d = np.minimum(d, lame)
            return d

        def rim(G, c=c, ax=ax, sx=sx):
            dome = ellipsoid(G.X, G.Y, G.Z, c, (0.105 * b.S, 0.115 * b.S, 0.1 * b.S))
            along = (G.X - c[0]) * ax[0] + (G.Y - c[1]) * ax[1] + (G.Z - c[2]) * ax[2]
            d = np.maximum(shell(dome, -0.003, 0.004), np.abs(along - 0.028) - 0.008)
            return np.maximum(d, (c[0] - sx * 0.07) * sx - G.X * sx)
        bone = f"upperarm_{side}"
        rivets = [(c + ax * 0.0 + np.array([sx * 0.07, -0.06, 0.02]) * b.S, 0.005),
                  (c + np.array([sx * 0.07, 0.06, 0.02]) * b.S, 0.005)]
        parts.append(Part(f"spaulder_{side}", "plate", cap, lo, hi, 1100, skin=bone, voxel=0.002, facet_deg=40,
                          rivets=rivets))
        parts.append(Part(f"spaulder_rim_{side}", "gold", rim, lo, hi, 400, skin=bone, voxel=0.002, facet_deg=40))
    return parts


def templar_gauntlets(b: Body) -> list[Part]:
    """Plate gauntlets: a flared cuff, plates over the back of the hand and segmented fingers."""
    parts = []
    hand_names = {f"palm_{s}" for s in "lr"} | {f"finger{i}_{s}" for i in range(4) for s in "lr"} | \
        {f"thumb_{s}" for s in "lr"} | {"wrist", "forearm", "forearm_mass"}
    for side, sx in (("l", 1.0), ("r", -1.0)):
        wr, end = b.j[f"wrist_{side}"], b.j[f"hand_end_{side}"]
        el = b.j[f"elbow_{side}"]
        ax = (end - wr) / np.linalg.norm(end - wr)
        fa = (wr - el) / np.linalg.norm(wr - el)
        lo = np.minimum(wr - fa * 0.14, end) - 0.12
        hi = np.maximum(wr - fa * 0.14, end) + 0.12

        def glove(G, wr=wr, ax=ax, fa=fa, side=side):
            f = G.subset({n for n in hand_names if n.endswith(side) or n in ("wrist", "forearm", "forearm_mass")})
            d = shell(f, 0.0015, 0.0055)
            along = (G.X - wr[0]) * fa[0] + (G.Y - wr[1]) * fa[1] + (G.Z - wr[2]) * fa[2]
            d = np.maximum(d, -along - 0.03)                      # stops a little up the forearm
            # finger segment grooves across the fingers
            u = (G.X - wr[0]) * ax[0] + (G.Y - wr[1]) * ax[1] + (G.Z - wr[2]) * ax[2]
            grooves = 0.0012 * (0.5 + 0.5 * np.cos(u * 2 * np.pi / 0.022))
            d = d + np.where(u > 0.08, grooves, 0.0)
            # the cuff: a flared cone around the wrist
            r = 0.05 * b.S + np.clip(-along, 0, 0.12) * 0.25
            px = G.X - wr[0] - fa[0] * along
            py = G.Y - wr[1] - fa[1] * along
            pz = G.Z - wr[2] - fa[2] * along
            radial = np.sqrt(px * px + py * py + pz * pz)
            cuff = np.maximum(np.abs(radial - r) - 0.0035, np.maximum(along - 0.01, -along - 0.11))
            return np.minimum(d, cuff)
        parts.append(Part(f"gauntlet_{side}", "plate", glove, lo, hi, 1600, skin=f"hand_{side}", voxel=0.0018,
                          facet_deg=45))
    return parts


def templar_chausses(b: Body) -> list[Part]:
    """Legs: mail chausses from the hips to the ankles, with domed plate poleyns on the knees."""
    z = b.z
    legs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor", "patella", "shin", "tibia", "calf",
            "achilles", "malleolus_out", "malleolus_in", "glute", "pelvis"}
    lo = np.array([-0.3, -0.25, z("ankle_l") - 0.02])
    hi = np.array([0.3, 0.25, z("pelvis") + 0.02])

    def mail(G):
        f = G.subset(legs)
        d = shell(f, 0.0015, 0.013)
        return np.maximum(d, band(G.Z, z("ankle_l") - 0.015, z("pelvis") - 0.06))   # down into the sabatons
    parts = [Part("chausses", "mail", mail, lo, hi, 3200, voxel=0.003)]
    for side, sx in (("l", 1.0), ("r", -1.0)):
        k = b.j[f"knee_{side}"]
        c = k + np.array([0.0, -0.05, 0.01]) * b.S
        plo, phi = c - 0.12, c + 0.12

        def poleyn(G, c=c, sx=sx):
            dome = ellipsoid(G.X, G.Y, G.Z, c, (0.058 * b.S, 0.045 * b.S, 0.065 * b.S))
            d = np.maximum(shell(dome, -0.005, 0.0), G.Y - (c[1] + 0.012))
            wing = ellipsoid(G.X, G.Y, G.Z, c + np.array([sx * 0.045, 0.02, 0.0]) * b.S, (0.03 * b.S, 0.03 * b.S, 0.05 * b.S))
            wing = np.maximum(shell(wing, -0.004, 0.0), (c[0] + sx * 0.035) * sx - G.X * sx)
            return np.minimum(d, wing)
        parts.append(Part(f"poleyn_{side}", "plate", poleyn, plo, phi, 700, skin=f"calf_{side}", voxel=0.002,
                          facet_deg=40))
    return parts


def templar_sabatons(b: Body) -> list[Part]:
    parts = []
    foot = {"heel", "foot", "instep", "toes", "malleolus_out", "malleolus_in", "achilles", "shin"}
    for side, sx in (("l", 1.0), ("r", -1.0)):
        a, t = b.j[f"ankle_{side}"], b.j[f"toe_{side}"]
        lo = np.minimum(a, t) - np.array([0.1, 0.12, 0.02])
        hi = np.maximum(a, t) + np.array([0.1, 0.12, 0.12])

        def fn(G, a=a, t=t, sx=sx):
            f = G.subset(foot)
            d = shell(f, 0.002, 0.008)
            d = np.maximum(d, below(G.Z, a[2] + 0.07))
            d = np.maximum(d, -G.Z)                                  # nothing below the floor
            # lames across the top of the foot
            fwd = -(G.Y - a[1])
            lames = 0.0015 * (0.5 + 0.5 * np.cos(fwd * 2 * np.pi / 0.03))
            return d + np.where(fwd > 0.03, lames, 0.0)
        # weights copied from the foot (not rigid on it): the heel and ankle skin follow the calf
        # partly, and a rigid sabaton let them show through when the foot points
        parts.append(Part(f"sabaton_{side}", "plate", fn, lo, hi, 1100, skin="transfer", voxel=0.002,
                          facet_deg=40))
    return parts


def templar_cape(b: Body) -> list[Part]:
    """A long cape from the shoulders to the calves, hanging clear of the back, with a gold clasp."""
    z = b.z
    top = z("chest_top") + 0.01
    bottom = z("knee_l") - 0.16
    lo = np.array([-0.45, -0.2, bottom - 0.04])
    hi = np.array([0.45, 0.45, top + 0.06])

    def fn(G):
        f = G.subset(_torso_names() | {"deltoid"})
        drape = shell(f, 0.03, 0.04)
        t = np.clip((top - G.Z) / (top - bottom), 0, 1)
        # below the shoulder blades it hangs as a sheet that moves away from the back toward the hem
        y_sheet = (0.15 + 0.12 * t * t) * b.S + 0.016 * np.sin(G.X * 30.0 + 0.6 * np.sin(G.Z * 9.0)) * (0.2 + t)
        half_w = (0.22 + 0.12 * t) * b.S
        sheet = np.maximum(np.abs(G.Y - y_sheet) - 0.006, np.abs(G.X) - half_w)
        upper = np.where(G.Y > 0.0, drape, 1.0)
        d = smin(np.where(G.Z > z("chest") + 0.05, upper, 1.0), np.where(G.Z < z("chest") + 0.12, sheet, 1.0), 0.06)
        d = np.maximum(d, band(G.Z, bottom + 0.012 * np.sin(G.X * 25), top))
        return np.maximum(d, -G.Y - 0.02)                          # behind the body only
    return [Part("cape", "cloth", fn, lo, hi, 2800, voxel=0.003)]


def templar_kite_shield(b: Body) -> list[Part]:
    """The Vanguard's kite shield on the outside of the left forearm: a rounded top tapering to a
    point, bowed around its long axis, a painted face (primary dye), a steel rim and a gold sun."""
    el, wr = b.j["elbow_l"], b.j["wrist_l"]
    up = (el - wr) / np.linalg.norm(el - wr)
    face = np.array([0.75, -0.66, 0.0])
    nrm = face - up * (face @ up)
    nrm /= np.linalg.norm(nrm)
    across = np.cross(up, nrm)
    sc = (el + wr) / 2 + nrm * 0.1 + up * 0.05
    W, H = 0.25, 0.5
    box = np.abs(np.stack([across, up, nrm])).T @ np.array([W + 0.05, H + 0.05, 0.12])
    lo, hi = sc - box, sc + box

    def coords(G):
        qx, qy, qz = G.X - sc[0], G.Y - sc[1], G.Z - sc[2]
        u = qx * across[0] + qy * across[1] + qz * across[2]
        w = qx * up[0] + qy * up[1] + qz * up[2]
        n = qx * nrm[0] + qy * nrm[1] + qz * nrm[2]
        return u, w, n + 0.07 * (u / W) ** 2          # bowed

    def outline(u, w):
        top = np.sqrt(u ** 2 + np.maximum(w - H * 0.55, 0) ** 2 * 1.6) - W            # rounded top
        t = np.clip((H * 0.55 - w) / (H * 1.55), 0, 1)
        half = W * (1.0 - t ** 1.4)
        lower = np.maximum(np.abs(u) - half, -w - H)
        return np.where(w > H * 0.55, top, lower)

    def face_fn(G):
        u, w, n = coords(G)
        return np.maximum(outline(u, w) + 0.012, np.abs(n) - 0.012)

    def rim_fn(G):
        u, w, n = coords(G)
        o = outline(u, w)
        return np.maximum(np.abs(o + 0.008) - 0.009, np.abs(n - 0.003) - 0.017)

    def sun_fn(G):
        u, w, n = coords(G)
        rad = np.sqrt(u ** 2 + (w - 0.06) ** 2)
        ang = np.arctan2(w - 0.06, u)
        ray = (0.5 + 0.5 * np.cos(ang * 8)) ** 3
        flat = rad - 0.11 * (0.45 + 0.55 * ray)
        ring = np.abs(rad - 0.046) - 0.007
        return np.maximum(np.minimum(flat, ring), np.abs(n - 0.016) - 0.006)
    return [Part("shield_face", "cloth", face_fn, lo, hi, 900, skin="forearm_l", voxel=0.003, facet_deg=40),
            Part("shield_rim", "plate", rim_fn, lo, hi, 700, skin="forearm_l", voxel=0.0025, facet_deg=40),
            Part("shield_sun", "gold", sun_fn, lo, hi, 600, skin="forearm_l", voxel=0.002, facet_deg=40)]


DESIGNS = {
    "templar_kite_shield": templar_kite_shield,
    "templar_great_helm": lambda b: templar_great_helm(b) + templar_aventail(b),
    "templar_surcoat": templar_surcoat,
    "templar_belt": templar_belt,
    "templar_spaulders": templar_spaulders,
    "templar_gauntlets": templar_gauntlets,
    "templar_chausses": templar_chausses,
    "templar_sabatons": templar_sabatons,
    "templar_cape": templar_cape,
}
