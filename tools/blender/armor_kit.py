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

    def __init__(self, lo, hi, voxel: float, shape: sdf.Shape, n=None):
        self.lo = np.asarray(lo, float)
        self.voxel = voxel
        self.n = np.asarray(n, int) if n is not None else np.ceil((np.asarray(hi, float) - self.lo) / voxel).astype(int) + 1
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


def eval_part(part: "Part", shape: sdf.Shape, max_cells: int = 6_000_000) -> tuple[np.ndarray, np.ndarray]:
    """A part's field on its whole grid, evaluated in slabs along x so the field functions'
    temporaries stay small (a surcoat at 2 mm is over 100 million samples). Returns (field, lo)."""
    full = Grid(part.lo, part.hi, part.voxel, shape)
    nx, ny, nz = (int(v) for v in full.n)
    f = np.empty((nx, ny, nz), dtype=np.float32)
    step = max(4, max_cells // max(ny * nz, 1))
    for x0 in range(0, nx, step):
        x1 = min(x0 + step, nx)
        G = Grid(full.lo + np.array([x0 * part.voxel, 0.0, 0.0]), None, part.voxel, shape, n=(x1 - x0, ny, nz))
        f[x0:x1] = np.broadcast_to(part.fn(G), (x1 - x0, ny, nz))
    return f, full.lo


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


def _sig(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -40, 40)))


def tube(f1, f2, r):
    """A round tube along the curve where two fields are both zero: a rolled edge where a plate
    (f1) is cut by a plane or another field (f2)."""
    return np.sqrt(f1 * f1 + f2 * f2) - r


def sawtooth(u, period):
    """0 to 1 rising along u, dropping back each period: overlapping scales and lames."""
    return u / period - np.floor(u / period)


def studs(d, G, centres, r):
    """Union of rivet heads into the field `d`: spheres centred a little inside the surface they sit
    on, so a dome shows. Each is evaluated only in a small window of the grid. Modelled, so they
    survive into the game mesh at the 2026-10-04 budgets, not only into the normal map."""
    d = np.array(d, dtype=np.float32, copy=True)
    shape = d.shape
    for c in centres:
        c = np.asarray(c, float)
        i0 = np.maximum(np.floor((c - r * 2 - G.lo) / G.voxel).astype(int), 0)
        i1 = np.minimum(np.ceil((c + r * 2 - G.lo) / G.voxel).astype(int) + 1, np.array(shape))
        if np.any(i1 <= i0):
            continue
        X = G.X[i0[0]:i1[0]]
        Y = G.Y[:, i0[1]:i1[1]]
        Z = G.Z[:, :, i0[2]:i1[2]]
        s = np.sqrt((X - c[0]) ** 2 + (Y - c[1]) ** 2 + (Z - c[2]) ** 2) - r
        win = d[i0[0]:i1[0], i0[1]:i1[1], i0[2]:i1[2]]
        np.minimum(win, s.astype(np.float32), out=win)
    return d


class _Pts:
    """Point lists dressed as a grid (X, Y, Z arrays), so a part's field functions can be
    evaluated at a few points."""

    def __init__(self, P, shape: sdf.Shape | None = None):
        P = np.asarray(P, float)
        self.P = P
        self.X, self.Y, self.Z = P[:, 0], P[:, 1], P[:, 2]
        self._shape = shape

    def subset(self, names: set[str]) -> np.ndarray:
        return sdf.eval_points(sdf.subset(self._shape, names), self.P)


def on_surface(field, pts, axis_xy=(0.0, 0.0), sink=0.001, reach=0.04, shape=None):
    """Move points horizontally (away from a vertical axis) onto the zero surface of `field`
    (a function of a grid), then `sink` back inside: where rivet heads sit."""
    pts = np.asarray(pts, float)
    d = pts[:, :2] - np.asarray(axis_xy, float)
    d /= np.maximum(np.linalg.norm(d, axis=1, keepdims=True), 1e-9)
    dirs = np.concatenate([d, np.zeros((len(pts), 1))], axis=1)
    a = np.full(len(pts), -reach)
    b = np.full(len(pts), reach)
    for _ in range(30):     # bisection: inside (negative) at a, outside at b
        m = (a + b) / 2
        f = np.asarray(field(_Pts(pts + dirs * m[:, None], shape)), float)
        inside = f < 0
        a = np.where(inside, m, a)
        b = np.where(inside, b, m)
    return list(pts + dirs * ((a + b) / 2 - sink)[:, None])


def ring_points(rx, ry, z, n, cy=0.0, exp=2.6, inset=0.0, keep=None):
    """`n` points around a horizontal superellipse (the helm's cross-section) at height z,
    moved `inset` towards the axis; `keep(x, y)` filters them."""
    out = []
    for i in range(n):
        a = 2 * np.pi * (i + 0.5) / n
        sa, ca = np.sin(a), np.cos(a)
        x = (rx - inset) * np.sign(sa) * abs(sa) ** (2 / exp)
        y = cy - (ry - inset) * np.sign(ca) * abs(ca) ** (2 / exp)
        if keep is None or keep(x, y):
            out.append(np.array([x, y, z]))
    return out


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
    """A flat-topped great helm built like a riveted one: a barrel that comes to a keel down the
    face, an upper band lapped over the face plate at the brow with a row of rivets, a slightly
    domed crown plate riveted round its edge, flanged eye slits, cross-pattern breaths on the right
    cheek and a rolled lower rim; a gilt cross pattee over the face and a small sun below the slit."""
    s, hz = b.hs, b.hz
    cy = 0.006 * s
    rx, ry = 0.117 * s, 0.142 * s
    z0, z1 = hz - 0.045 * s, hz + 0.268 * s   # low enough that the chin stays inside when the head bends
    eye_z = hz + 0.122 * s
    brow_z = eye_z + 0.034 * s                # the upper band laps over the face plate here
    lo = np.array([-0.17, cy - 0.21, z0 - 0.03])
    hi = np.array([0.17, cy + 0.2, z1 + 0.05])

    SIDE_SEAM = 1.2    # radians from the front: where the face plate laps over the side plates

    def taper(Z):
        t = np.clip((Z - z0) / (z1 - z0), 0.0, 1.0)
        return 1.0 - 0.06 * t + 0.03 * np.clip((z0 + 0.04 * s - Z) / (0.04 * s), 0, 1)   # a slight flare at the rim

    def outer_field(G):
        k = taper(G.Z)
        d = superellipse(G.X, G.Y, 0.0, cy, rx * k, ry * k, 2.6)
        keel = 0.011 * s * np.clip(1.0 - np.abs(G.X) / (0.07 * s), 0, 1) ** 2 * (G.Y < cy)
        d = d - keel
        lap = 0.0026 * _sig((G.Z - brow_z) / 0.0009)          # the upper band sits proud
        ang = np.abs(np.arctan2(G.X, -(G.Y - cy)))
        face = 0.0018 * _sig((SIDE_SEAM - ang) / 0.012) * _sig((brow_z - G.Z) / 0.0009)  # face plate over the sides
        return d - lap - face

    def slit_field(G):
        sl = np.maximum(np.abs(G.Z - eye_z) - 0.0068 * s, np.maximum(np.abs(G.X) - 0.09 * s, 0.013 * s - np.abs(G.X)))
        return np.maximum(sl, G.Y - (cy - 0.05))

    def breaths():
        """Hole centres (x, z) in a cross on the right cheek."""
        cx, cz, step = -0.064 * s, hz + 0.05 * s, 0.0135 * s
        pts = [(cx + i * step, cz) for i in range(-2, 3)] + [(cx, cz + k * step) for k in (-2, -1, 1, 2)]
        return pts

    def barrel(G):
        outer = outer_field(G)
        sl = slit_field(G)
        flange = np.clip(1.0 - np.maximum(sl, 0.0) / (0.008 * s), 0, 1) * (G.Y < cy - 0.05)
        outer = outer - 0.004 * flange ** 1.5          # the slit's lips stand out like sights
        d = shell(outer, -0.0045, 0.0)
        d = np.maximum(d, band(G.Z, z0 + 0.004, z1))
        # the rolled lower rim: a bead along the rim's edge
        d = np.minimum(d, tube(outer + 0.0022, G.Z - (z0 + 0.005), 0.0046))
        # the crown: a shallow dome on a flat plate, with a rolled seam where it meets the barrel
        k1 = float(taper(np.array(z1)))
        top = np.maximum(superellipse(G.X, G.Y, 0.0, cy, rx * k1 * 0.985, ry * k1 * 0.985, 2.6),
                         np.abs(G.Z - (z1 - 0.003)) - 0.004)
        dome = np.maximum(ellipsoid(G.X, G.Y, G.Z, (0.0, cy, z1 - 0.006), (rx * k1 * 0.93, ry * k1 * 0.93, 0.03 * s)),
                          above(G.Z, z1 - 0.004))
        seam = tube(superellipse(G.X, G.Y, 0.0, cy, rx * k1, ry * k1, 2.6) + 0.002, G.Z - (z1 - 0.002), 0.004)
        d = np.minimum(d, np.minimum(np.minimum(top, dome), seam))
        d = np.maximum(d, -sl)
        for bx, bz in breaths():
            hole = np.sqrt((G.X - bx) ** 2 + (G.Z - bz) ** 2) - 0.0037 * s
            d = np.maximum(d, -np.maximum(hole, G.Y - (cy - 0.04)))
        # rivets, sitting on the surface: along the brow lap (not under the cross), round the crown,
        # above the lower rim, and down both side seams of the face plate
        r = 0.0034
        riv = ring_points(rx, ry, brow_z + 0.008, 26, cy=cy, keep=lambda x, y: abs(x) > 0.03 * s)
        riv += ring_points(rx, ry, z1 - 0.015, 24, cy=cy)
        riv += ring_points(rx, ry, z0 + 0.024, 18, cy=cy, keep=lambda x, y: abs(x) > 0.04 * s)
        for sx in (1.0, -1.0):
            a = SIDE_SEAM - 0.07
            for zz in np.linspace(z0 + 0.045, brow_z - 0.012, 6):
                riv.append(np.array([sx * np.sin(a) * rx, cy - np.cos(a) * ry, zz]))
        riv = on_surface(outer_field, riv, (0.0, cy), sink=0.0012)
        return studs(d, G, riv, r)

    def trim(G):
        outer = outer_field(G)
        skin = shell(outer, -0.0015, 0.0034)
        # a cross pattee: arms that widen toward their ends
        zc = eye_z + 0.004 * s
        half = (z1 - 0.012 - (z0 + 0.012)) / 2
        zm = (z1 - 0.012 + z0 + 0.012) / 2
        u = np.clip(np.abs(G.Z - zm) / half, 0, 1)
        upright = np.maximum(np.abs(G.X) - 0.010 * s * (1.0 + 1.3 * u ** 3), band(G.Z, z0 + 0.012, z1 - 0.012))
        v = np.clip(np.abs(G.X) / (0.1 * s), 0, 1)
        arm = np.maximum(np.abs(G.Z - (brow_z - 0.006 * s)) - 0.0085 * s * (1.0 + 0.9 * v ** 3),
                         np.abs(G.X) - 0.1 * s)
        cross = np.maximum(np.minimum(upright, arm), G.Y - (cy - 0.035))
        d = np.maximum(skin, cross)
        d = np.maximum(d, -slit_field(G))
        ez = hz + 0.064 * s
        front = cy - ry * float(taper(np.array(ez))) - 0.011 * s
        emblem = sun(G.X, G.Y, G.Z, (0.0, front - 0.0015, ez), 1, 0.024 * s, 8, 0.0035)
        return np.minimum(d, emblem)

    def liner(G):
        """The padded lining: a dark layer a centimetre inside the plate, so the slit and the
        breaths show shadow rather than the face behind them."""
        outer = outer_field(G)
        d = shell(outer, -0.0145, -0.0105)
        return np.maximum(d, band(G.Z, z0 + 0.012, z1 - 0.008))

    return [Part("helm", "plate", barrel, lo, hi, 3600, skin="head", voxel=0.0015, facet_deg=40),
            Part("helm_trim", "gold", trim, lo, hi, 1500, skin="head", voxel=0.0015, facet_deg=40),
            Part("helm_liner", "leather", liner, lo, hi, 300, skin="head", voxel=0.003)]


def templar_aventail(b: Body) -> list[Part]:
    """The mail coif's skirt below the helm, over the neck and the tops of the shoulders, with a
    leather-bound scalloped hem."""
    zt = b.z("neck") + 0.09   # up inside the helm, so a bent or turned head never opens a gap
    zb = b.z("chest_top") - 0.08
    lo = np.array([-0.3, -0.25, zb - 0.03])
    hi = np.array([0.3, 0.25, zt + 0.03])
    names = {"neck", "trap", "scm", "clavicle", "upper_back", "ribcage", "pec", "deltoid", "scapula", "breast"}

    def base(G):
        f = G.subset(names)
        d = np.maximum(shell(f, 0.003, 0.016), band(G.Z, zb - 0.02, zt))  # loose: the neck turns under it
        reach = np.sqrt(G.X ** 2 + (G.Y * 1.1) ** 2) - (0.2 + 0.4 * np.clip((zt - G.Z) / (zt - zb), 0, 1) * 0.3)
        return np.maximum(d, reach), f

    def hem_z(G):
        return zb + 0.012 * np.sin(np.arctan2(G.X, G.Y) * 14)

    def mail(G):
        d, _f = base(G)
        return np.maximum(d, hem_z(G) + 0.012 - G.Z)

    def binding(G):
        d, f = base(G)
        bound = np.maximum(shell(f, 0.002, 0.0185), band(G.Z, hem_z(G), hem_z(G) + 0.016))
        return np.maximum(bound, np.sqrt(G.X ** 2 + (G.Y * 1.1) ** 2) - 0.33)
    return [Part("aventail", "mail", mail, lo, hi, 2300, voxel=0.0025),
            Part("aventail_hem", "leather", binding, lo, hi, 600, voxel=0.0025)]


def _torso_names():
    return {"ribcage", "abdomen", "pelvis", "upper_back", "pec", "breast", "lat", "oblique", "scapula", "glute",
            "trap", "clavicle", "rectus", "abs", "neck", "scm"}


def ellipsoid_point(c, r, u):
    """The point of an ellipsoid (centre c, radii r) in direction u from its centre."""
    u = np.asarray(u, float) / np.linalg.norm(u)
    k = 1.0 / np.sqrt(np.sum((u / np.asarray(r, float)) ** 2))
    return np.asarray(c, float) + u * k


def _hem_line(ang, base, amp=0.012, tears=True):
    """An uneven cloth hem: a slow wave, a faster ripple and a few V-shaped tears."""
    z = base + amp * np.cos(ang * 7.0) + 0.4 * amp * np.sin(ang * 23.0 + 1.3)
    if tears:
        tear = np.clip((np.sin(ang * 11.0 + 0.7) - 0.9) / 0.1, 0, 1) * np.clip((np.cos(ang * 3.0 + 0.4) - 0.2) / 0.8, 0, 1)
        z = z + 0.045 * tear
    return z


def templar_surcoat(b: Body) -> list[Part]:
    """Chest slot: a mail hauberk (torso, long sleeves, a skirt to mid-thigh) under a long
    sleeveless surcoat, split front and back below the belt so each half follows its leg. The
    surcoat bloused above the belt, hangs in deep uneven folds, has a worn and torn hem, a gold
    hem band with a raised lozenge border, and a large embroidered sun on the chest."""
    z = b.z
    neck_z = z("chest_top") + 0.02
    belt = z("pelvis") + 0.06
    skirt = z("knee_l") + 0.24
    hem = z("knee_l") - 0.1
    lo = np.array([-0.75, -0.33, hem - 0.06])
    hi = np.array([0.75, 0.31, neck_z + 0.06])
    sh_l = b.j["shoulder_l"]
    el_l = b.j["elbow_l"]
    torso = _torso_names()
    arms = {"deltoid", "upperarm", "bicep", "tricep", "elbow", "forearm", "forearm_mass", "wrist"}
    legs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor", "glute"}

    def hauberk(G):
        f = G.subset(torso | arms | legs)
        # padded sleeves (a quilted gambeson under the mail gives the arms a soldier's bulk), roomier
        # still at the elbow so it bends inside them
        loose = 0.008 * np.clip((np.abs(G.X) - 0.21) / 0.05, 0, 1)
        for sx in (1.0, -1.0):
            e = el_l * np.array([sx, 1, 1])
            loose = loose + 0.01 * np.exp(-((G.X - e[0]) ** 2 + (G.Y - e[1]) ** 2 + (G.Z - e[2]) ** 2) / 0.07 ** 2)
        d = shell(f, 0.002, 0.008 + loose)
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

    def ang_of(G):
        return np.arctan2(G.X, -(G.Y - 0.01))

    def skirt_shape(G):
        """Below the belt: a flared skirt with deep uneven folds, split front and back."""
        t = np.clip((belt - G.Z) / (belt - hem), 0, 1)
        rx = (0.175 + 0.1 * t + 0.01 * b.fem) * b.S
        ry = (0.135 + 0.08 * t) * b.S
        ang = ang_of(G)
        folds = (0.015 * np.sin(ang * 9.0) + 0.006 * np.sin(ang * 17.0 + 0.8 + 3.0 * t)) * t ** 0.8
        d = np.abs(superellipse(G.X, G.Y, 0.0, 0.01, rx, ry, 2.2) + folds) - 0.0045
        d = np.maximum(d, band(G.Z, _hem_line(ang, hem), belt + 0.03))
        slit = np.abs(G.X) - (0.012 + 0.03 * t)                         # widens toward the hem
        return np.maximum(d, -np.where(G.Z < belt - 0.1, slit, 1.0))

    def surcoat_field(G):
        f = G.subset(torso)
        # bloused over the belt: soft vertical folds in the 10 cm above it
        ang = ang_of(G)
        u = np.clip(1.0 - (G.Z - belt) / 0.11, 0, 1) * (G.Z > belt - 0.02)
        blouse = u * (0.006 + 0.004 * np.sin(ang * 16.0 + 0.5))
        body_over = shell(f - blouse, 0.009, 0.02)
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
        ang = ang_of(G)
        hz = _hem_line(ang, hem, tears=False)
        hem_band = np.abs(G.Z - (hz + 0.034)) - 0.024
        slit_edge = np.abs(np.abs(G.X) - (0.012 + 0.03 * t) - 0.012) - 0.012
        edge = np.where(G.Z < belt - 0.1, np.minimum(hem_band, slit_edge), 1.0)
        # a raised border of lozenges along the middle of the hem band
        v = (G.Z - (hz + 0.034)) / 0.016
        lozenge = np.abs(sawtooth(ang * 40.0 / np.pi, 1.0) - 0.5) * 2.0 + np.abs(v)   # < 1 inside a lozenge
        relief = 0.0016 * np.clip(1.15 - lozenge, 0, 0.3) / 0.3
        raised = np.maximum(d - 0.003 - relief, -d)
        return np.maximum(raised, edge)

    def emblem(G):
        f = G.subset(torso)
        y0 = -0.17 * b.S if b.fem < 0.5 else -0.18 * b.S
        c = (0.0, y0, z("chest") + 0.02)
        r = 0.085 * b.S
        rad = np.sqrt(G.X ** 2 + (G.Z - c[2]) ** 2)
        # embroidery stands proud of the cloth, highest in the disc and along each ray's spine
        swell = 0.0035 * np.clip(1.0 - rad / r, 0, 1) + 0.0015
        surface = shell(f - swell, 0.018, 0.024)
        disc = sun(G.X, G.Y, G.Z, c, 1, r, 12, 0.08)
        return np.maximum(surface, disc)

    return [Part("hauberk", "mail", hauberk, lo, hi, 5200, voxel=0.0025),
            Part("surcoat", "cloth", surcoat, lo, hi, 8800, voxel=0.0025),
            Part("surcoat_trim", "trim", trim, lo, hi, 3600, voxel=0.002),
            Part("surcoat_sun", "trim", emblem, np.array([-0.15, -0.3, z("chest") - 0.12]),
                 np.array([0.15, 0.0, z("chest") + 0.16]), 1600, voxel=0.0015)]


def templar_belt(b: Body) -> list[Part]:
    """A sword belt: a studded leather strap, a gilt buckle frame with its prong, and the strap's
    end hanging down the left front with a gilt chape."""
    zb = b.z("pelvis") + 0.06
    S = b.S
    lo = np.array([-0.3, -0.3, zb - 0.22])
    hi = np.array([0.3, 0.3, zb + 0.06])
    fy = -0.15 * S                     # the front of the belt, near enough for the buckle

    def strap_field(G):
        f = G.subset(_torso_names())
        return np.maximum(shell(f, 0.02, 0.032), np.abs(G.Z - zb) - 0.022), f

    def belt(G):
        d, f = strap_field(G)
        # the hanging end: a slab falling from the buckle down the left front, flaring out a little
        t = np.clip((zb - 0.02 - G.Z) / 0.15, 0, 1)
        y_end = fy - 0.03 - 0.018 * t
        tongue = np.maximum(np.abs(G.Y - y_end) - 0.0028,
                            np.maximum(np.abs(G.X - 0.05) - 0.019, band(G.Z, zb - 0.17, zb - 0.01)))
        d = np.minimum(d, tongue)
        studs_at = []
        for i in range(-7, 8):
            if abs(i) < 2:
                continue                                    # under the buckle
            a = i * 0.21
            studs_at.append(np.array([np.sin(a) * 0.19, -np.cos(a) * 0.19, zb]))
        studs_at = on_surface(lambda P: P.subset(_torso_names()) - 0.032, studs_at, (0.0, 0.0), sink=0.0015,
                              reach=0.1, shape=G._shape)
        return studs(d, G, studs_at, 0.0052)

    def gilt(G):
        # the buckle: a rounded rectangular frame proud of the belt, its prong across the middle
        frame_o = superellipse(G.X, G.Z, 0.0, zb, 0.036, 0.031, 4)
        frame = np.maximum(np.maximum(frame_o, -(frame_o + 0.008)), np.abs(G.Y - (fy - 0.034)) - 0.004)
        prong = np.maximum(capsule(G.X, G.Y, G.Z, (-0.03, fy - 0.038, zb), (0.03, fy - 0.038, zb), 0.0028), 0.0)
        chape = np.maximum(superellipse(G.X, G.Z, 0.05, zb - 0.165, 0.021, 0.014, 4),
                           np.abs(G.Y - (fy - 0.048 - 0.018)) - 0.0045)
        return np.minimum(np.minimum(frame, prong), chape)
    return [Part("belt", "leather", belt, lo, hi, 2400, voxel=0.0018, skin="pelvis"),
            Part("belt_buckle", "gold", gilt, lo, hi, 600, voxel=0.0015, skin="pelvis", facet_deg=40)]


def templar_spaulders(b: Body) -> list[Part]:
    """Rounded plate spaulders: a domed cop with a raised ridge from the shoulder's crown down the
    arm and a gilt rolled edge, and three lames below, each with a rolled edge and a rivet at
    either end."""
    parts = []
    for side, sx in (("l", 1.0), ("r", -1.0)):
        sh = b.j[f"shoulder_{side}"]
        el = b.j[f"elbow_{side}"]
        ax = (el - sh) / np.linalg.norm(el - sh)
        c = sh + np.array([sx * 0.012, 0.0, 0.035]) * b.S
        R = np.array([0.108, 0.118, 0.102]) * b.S
        lo = c - 0.21
        hi = c + 0.21
        lames = [(0.052, 0.0), (0.081, 0.007), (0.11, 0.014)]   # (offset along the arm, radius loss)

        def along_of(G, c=c, ax=ax):
            return (G.X - c[0]) * ax[0] + (G.Y - c[1]) * ax[1] + (G.Z - c[2]) * ax[2]

        def dome_of(G, c=c, R=R):
            ridge = 0.007 * b.S * np.exp(-((G.Y - c[1]) / 0.014) ** 2)
            return ellipsoid(G.X, G.Y, G.Z, c, R) - ridge

        def inner_cut(G, c=c, sx=sx):
            return (c[0] - sx * 0.07) * sx - G.X * sx

        def cap(G, c=c, ax=ax, sx=sx, R=R, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut):
            dome = dome_of(G)
            along = along_of(G)
            d = shell(dome, -0.0055, 0.0)
            d = np.maximum(d, along - 0.035)
            d = np.maximum(d, inner_cut(G))
            for off, loss in lames:
                lc = c + ax * off
                lame = ellipsoid(G.X, G.Y, G.Z, lc, R - 0.004 - loss * b.S)
                ld = np.maximum(shell(lame, -0.0045, 0.0), np.abs(along - off) - 0.017)
                ld = np.minimum(ld, tube(lame + 0.0022, along - (off + 0.017), 0.0034))   # rolled lower edge
                ld = np.maximum(ld, (c[0] - sx * 0.035) * sx - G.X * sx)
                d = np.minimum(d, ld)
            riv = []
            for off, loss in lames:
                for fy in (-1.0, 1.0):
                    u = np.array([0.35 * sx, fy, -0.1])
                    u = u - ax * (u @ ax)          # in the lame's plane, across the arm
                    u /= np.linalg.norm(u)
                    riv.append(ellipsoid_point(c + ax * off, R - 0.004 - loss * b.S, u) - u * 0.0012)
            return studs(d, G, riv, 0.0034)

        def rim(G, c=c, ax=ax, sx=sx, dome_of=dome_of, along_of=along_of, inner_cut=inner_cut):
            dome = dome_of(G)
            along = along_of(G)
            d = tube(dome + 0.0027, along - 0.035, 0.0062)
            return np.maximum(d, inner_cut(G) - 0.004)
        bone = f"upperarm_{side}"
        parts.append(Part(f"spaulder_{side}", "plate", cap, lo, hi, 3500, skin=bone, voxel=0.0015, facet_deg=40))
        parts.append(Part(f"spaulder_rim_{side}", "gold", rim, lo, hi, 900, skin=bone, voxel=0.0015, facet_deg=40))
    return parts


def templar_gauntlets(b: Body) -> list[Part]:
    """Plate gauntlets: a flared cuff with a rolled edge and rivets, two wrist lames, a plate over
    the back of the hand ending in a row of knuckle bosses, and overlapping finger scales."""
    parts = []
    hand_names = {f"palm_{s}" for s in "lr"} | {f"finger{i}_{s}" for i in range(4) for s in "lr"} | \
        {f"thumb_{s}" for s in "lr"} | {"wrist", "forearm", "forearm_mass"}
    for side, sx in (("l", 1.0), ("r", -1.0)):
        wr, end = b.j[f"wrist_{side}"], b.j[f"hand_end_{side}"]
        el = b.j[f"elbow_{side}"]
        ax = (end - wr) / np.linalg.norm(end - wr)
        fa = (wr - el) / np.linalg.norm(wr - el)
        dorsal = np.array([abs(ax[2]) * sx, 0.0, abs(ax[0])])          # out and up: the back of the hand
        dorsal /= np.linalg.norm(dorsal)
        lo = np.minimum(wr - fa * 0.14, end) - 0.12
        hi = np.maximum(wr - fa * 0.14, end) + 0.12

        def coords(G, wr=wr, ax=ax, fa=fa, dorsal=dorsal):
            along = (G.X - wr[0]) * fa[0] + (G.Y - wr[1]) * fa[1] + (G.Z - wr[2]) * fa[2]
            u = (G.X - wr[0]) * ax[0] + (G.Y - wr[1]) * ax[1] + (G.Z - wr[2]) * ax[2]
            back = (G.X - wr[0]) * dorsal[0] + (G.Y - wr[1]) * dorsal[1] + (G.Z - wr[2]) * dorsal[2]
            return along, u, back

        def hand_field(G, side=side):
            return G.subset({n for n in hand_names if n.endswith(side) or n in ("wrist", "forearm", "forearm_mass")})

        def glove(G, wr=wr, fa=fa, coords=coords, hand_field=hand_field):
            f = hand_field(G)
            along, u, back = coords(G)
            # finger scales: each overlaps the next toward the fingertips
            scales = 0.0016 * sawtooth(u, 0.019)
            d = shell(f - np.where(u > 0.085, scales, 0.0), 0.0015, 0.0055)
            d = np.maximum(d, -along - 0.03)                      # stops a little up the forearm
            # wrist lames: two steps between the cuff and the hand plate
            lam = 0.0015 * sawtooth(-along + 0.02, 0.02) * (along > -0.03) * (u < 0.03)
            d = d - lam
            # the plate over the back of the hand, from the wrist to the knuckles, with a rolled end
            plate = np.maximum(shell(f, 0.004, 0.009), np.maximum(-back + 0.005, band(u, 0.02, 0.083)))
            plate = np.minimum(plate, np.maximum(tube(f - 0.0065, u - 0.083, 0.0035), -back + 0.008))
            d = np.minimum(d, plate)
            # the cuff: a flared cone around the wrist with a rolled outer edge
            r = 0.05 * b.S + np.clip(-along, 0, 0.12) * 0.19
            px = G.X - wr[0] - fa[0] * along
            py = G.Y - wr[1] - fa[1] * along
            pz = G.Z - wr[2] - fa[2] * along
            radial = np.sqrt(px * px + py * py + pz * pz)
            cuff = np.maximum(np.abs(radial - r) - 0.0035, np.maximum(along - 0.01, -along - 0.11))
            cuff = np.minimum(cuff, tube(radial - (0.05 * b.S + 0.11 * 0.19), along + 0.11, 0.0045))
            return np.minimum(d, cuff)

        def gauntlet(G, wr=wr, fa=fa, ax=ax, dorsal=dorsal, glove=glove, hand_field=hand_field):
            d = glove(G)
            # cuff rivets and knuckle bosses
            riv = []
            perp1 = np.cross(fa, [0.0, 1.0, 0.0])
            perp1 /= np.linalg.norm(perp1)
            perp2 = np.cross(fa, perp1)
            rr = 0.05 * b.S + 0.07 * 0.19 + 0.0005
            for k in range(8):
                a = 2 * np.pi * k / 8
                riv.append(wr - fa * 0.07 + (perp1 * np.cos(a) + perp2 * np.sin(a)) * rr)
            across = np.cross(ax, dorsal)
            across /= np.linalg.norm(across)
            knuckles = [wr + ax * 0.088 + across * w for w in (-0.027, -0.009, 0.009, 0.027)]
            knuckles = on_surface_dir(lambda P: hand_field(P) - 0.009, knuckles, dorsal, sink=0.002, shape=G._shape)
            d = studs(d, G, riv, 0.0032)
            return studs(d, G, knuckles, 0.0062)
        parts.append(Part(f"gauntlet_{side}", "plate", gauntlet, lo, hi, 4000, skin=f"hand_{side}", voxel=0.0013,
                          facet_deg=45))
    return parts


def on_surface_dir(field, pts, direction, sink=0.001, reach=0.05, shape=None):
    """Like on_surface, along one fixed direction (the back of a hand)."""
    pts = np.asarray(pts, float)
    u = np.asarray(direction, float) / np.linalg.norm(direction)
    a = np.full(len(pts), -reach)
    bb = np.full(len(pts), reach)
    for _ in range(30):
        m = (a + bb) / 2
        f = np.asarray(field(_Pts(pts + u[None, :] * m[:, None], shape)), float)
        inside = f < 0
        a = np.where(inside, m, a)
        bb = np.where(inside, bb, m)
    return list(pts + u[None, :] * ((a + bb) / 2 - sink)[:, None])


def templar_chausses(b: Body) -> list[Part]:
    """Legs: mail chausses from the hips to the ankles; quilted cuisses over the thighs (padded
    cloth with vertical channels, cut off above the knee); domed plate poleyns with a ridge,
    rolled edges, a fluted side wing and a lame above and below."""
    z = b.z
    legs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor", "patella", "shin", "tibia", "calf",
            "achilles", "malleolus_out", "malleolus_in", "glute", "pelvis"}
    thighs = {"thigh", "quad", "vastus_lat", "vastus_med", "hamstring", "adductor"}
    lo = np.array([-0.3, -0.25, z("ankle_l") - 0.02])
    hi = np.array([0.3, 0.25, z("pelvis") + 0.02])

    def mail(G):
        f = G.subset(legs)
        d = shell(f, 0.0015, 0.013)
        return np.maximum(d, band(G.Z, z("ankle_l") - 0.015, z("pelvis") - 0.06))   # down into the sabatons
    parts = [Part("chausses", "mail", mail, lo, hi, 4200, voxel=0.0025)]
    kz = z("knee_l")
    cz0, cz1 = kz + 0.07, z("pelvis") - 0.17

    def cuisses(G):
        f = G.subset(thighs)
        kx = np.where(G.X > 0, b.j["knee_l"][0], -b.j["knee_l"][0])
        ang = np.arctan2(G.Y - b.j["knee_l"][1], G.X - kx)
        quilt = 0.0035 * (0.5 + 0.5 * np.cos(ang * 11.0)) ** 2           # channels between padded ribs
        d = shell(f + quilt, 0.0135, 0.023)                                # wholly over the mail
        d = np.maximum(d, band(G.Z, cz0, cz1))
        d = np.maximum(d, 0.012 - np.abs(G.X))                             # never bridging the legs
        d = np.minimum(d, np.maximum(np.maximum(tube(f - 0.019, G.Z - cz0, 0.005), -f + 0.012),
                                      0.012 - np.abs(G.X)))                                      # a rolled lower edge
        return d
    parts.append(Part("cuisses", "cloth", cuisses, np.array([-0.3, -0.25, cz0 - 0.02]),
                      np.array([0.3, 0.25, cz1 + 0.02]), 2400, voxel=0.0025))
    for side, sx in (("l", 1.0), ("r", -1.0)):
        k = b.j[f"knee_{side}"]
        c = k + np.array([0.0, -0.05, 0.01]) * b.S
        R = np.array([0.058, 0.045, 0.065]) * b.S
        plo, phi = c - 0.13, c + 0.13

        def poleyn(G, c=c, sx=sx, R=R):
            ridge = 0.005 * b.S * np.exp(-((G.X - c[0]) / 0.01) ** 2)
            dome = ellipsoid(G.X, G.Y, G.Z, c, R) - ridge
            back = G.Y - (c[1] + 0.012)
            d = np.maximum(shell(dome, -0.0045, 0.0), back)
            d = np.maximum(d, band(G.Z, c[2] - R[2] * 0.82, c[2] + R[2] * 0.82))
            for zz in (c[2] - R[2] * 0.82, c[2] + R[2] * 0.82):
                d = np.minimum(d, np.maximum(tube(dome + 0.0022, G.Z - zz, 0.0035), back))
            # lames above and below
            for zz, sgn in ((c[2] + R[2] * 0.95, 1), (c[2] - R[2] * 0.95, -1)):
                lame = ellipsoid(G.X, G.Y, G.Z, c + np.array([0, 0.004, sgn * 0.012]), R * np.array([0.95, 0.95, 1.05]))
                ld = np.maximum(np.maximum(shell(lame, -0.004, 0.0), back), np.abs(G.Z - zz) - 0.012)
                d = np.minimum(d, ld)
            # the fluted wing on the outside of the knee
            wc = c + np.array([sx * 0.046, 0.022, 0.0]) * b.S
            wa = np.arctan2(G.Z - wc[2], (G.Y - wc[1]))
            flute = 0.0018 * (0.5 + 0.5 * np.cos(wa * 9.0))
            wing = ellipsoid(G.X, G.Y, G.Z, wc, (0.02 * b.S, 0.036 * b.S, 0.052 * b.S))
            wing = np.maximum(shell(wing - flute, -0.0035, 0.0), (c[0] + sx * 0.036) * sx - G.X * sx)
            d = np.minimum(d, wing)
            riv = [c + np.array([sx * 0.046, -0.004, zz]) * b.S for zz in (0.06, -0.06)]
            riv = on_surface_dir(lambda P: ellipsoid(P.X, P.Y, P.Z, c + np.array([0, 0.004, 0]), R * 0.98),
                                 riv, (0.0, -1.0, 0.0), sink=0.0012)
            return studs(d, G, riv, 0.003)
        parts.append(Part(f"poleyn_{side}", "plate", poleyn, plo, phi, 2700, skin=f"calf_{side}", voxel=0.0015,
                          facet_deg=40))
    return parts


def templar_sabatons(b: Body) -> list[Part]:
    """Plate sabatons with overlapping lames over the foot, a rolled edge round the ankle and a
    gilt prick spur strapped round the heel."""
    parts = []
    foot = {"heel", "foot", "instep", "toes", "malleolus_out", "malleolus_in", "achilles", "shin"}
    for side, sx in (("l", 1.0), ("r", -1.0)):
        a, t = b.j[f"ankle_{side}"], b.j[f"toe_{side}"]
        lo = np.minimum(a, t) - np.array([0.1, 0.16, 0.02])
        hi = np.maximum(a, t) + np.array([0.1, 0.16, 0.12])
        top = a[2] + 0.07

        def fn(G, a=a, t=t, sx=sx):
            f = G.subset(foot)
            fwd = -(G.Y - a[1])
            lames = 0.0018 * sawtooth(fwd - 0.02, 0.026) * (fwd > 0.02)
            d = shell(f - lames, 0.002, 0.0085)
            d = np.maximum(d, below(G.Z, top))
            d = np.minimum(d, np.maximum(tube(f - 0.0055, G.Z - top, 0.0038), -f))
            return np.maximum(d, -G.Z)                                  # nothing below the floor
        parts.append(Part(f"sabaton_{side}", "plate", fn, lo, hi, 2200, skin="transfer", voxel=0.0015,
                          facet_deg=40))

        def spur(G, a=a, sx=sx):
            f = G.subset(foot)
            zs = a[2] - 0.01
            ring = np.maximum(tube(f - 0.011, G.Z - zs, 0.004), -G.Z)
            heel_y = a[1] + 0.06
            neck = capsule(G.X, G.Y, G.Z, (a[0], heel_y - 0.004, zs), (a[0], heel_y + 0.035, zs + 0.008), 0.0045)
            prick = capsule(G.X, G.Y, G.Z, (a[0], heel_y + 0.035, zs + 0.008), (a[0], heel_y + 0.055, zs + 0.012), 0.0028)
            return np.minimum(ring, np.minimum(neck, prick))
        parts.append(Part(f"spur_{side}", "gold", spur, lo, hi, 800, skin="transfer", voxel=0.0013, facet_deg=40))
    return parts


def templar_cape(b: Body) -> list[Part]:
    """A long cape from the shoulders to the calves, hanging clear of the back in deep folds, with
    a doubled, heavier hem worn uneven at the bottom."""
    z = b.z
    top = z("chest_top") + 0.01
    bottom = z("knee_l") - 0.16
    lo = np.array([-0.46, -0.2, bottom - 0.06])
    hi = np.array([0.46, 0.47, top + 0.06])

    def sheet_y(G, t):
        return (0.15 + 0.12 * t * t) * b.S + (0.022 * np.sin(G.X * 30.0 + 0.6 * np.sin(G.Z * 9.0)) +
                                               0.009 * np.sin(G.X * 71.0 + 1.1)) * (0.2 + t)

    def fn(G):
        f = G.subset(_torso_names() | {"deltoid"})
        drape = np.maximum(shell(f, 0.022, 0.03), np.abs(G.X) - 0.2 * b.S)   # across the upper back only
        t = np.clip((top - G.Z) / (top - bottom), 0, 1)
        y_sheet = sheet_y(G, t)
        half_w = (0.22 + 0.12 * t) * b.S
        hem = _hem_line(G.X * 6.0, bottom, amp=0.01)
        thick = 0.006 + 0.003 * np.clip(1.0 - (G.Z - hem) / 0.05, 0, 1)    # the doubled hem
        sheet = np.maximum(np.abs(G.Y - y_sheet) - thick, np.abs(G.X) - half_w)
        upper = np.where(G.Y > 0.05, drape, 1.0)                    # behind the shoulders, no fin over them
        d = smin(np.where(G.Z > z("chest") + 0.05, upper, 1.0), np.where(G.Z < z("chest") + 0.12, sheet, 1.0), 0.06)
        d = np.maximum(d, band(G.Z, hem, top))
        return np.maximum(d, -G.Y - 0.02)                          # behind the body only
    return [Part("cape", "cloth", fn, lo, hi, 8000, voxel=0.0025)]


def templar_kite_shield(b: Body) -> list[Part]:
    """The Vanguard's kite shield on the outside of the left forearm: a rounded top tapering to a
    point, bowed around its long axis, a painted face (primary dye), a steel rim fixed with a row
    of rivets, and a gold sun in relief."""
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

    def rivet_points():
        pts = []
        for k in range(22):
            ang = -0.3 * np.pi + 1.6 * np.pi * k / 21     # down one side, over the top, down the other
            d = np.array([np.cos(ang), np.sin(ang)])
            lo_r, hi_r = 0.0, 1.0
            for _ in range(30):
                m = (lo_r + hi_r) / 2
                if outline(np.array(m * d[0]), np.array(0.08 + m * d[1])) < -0.021:
                    lo_r = m
                else:
                    hi_r = m
            u, w = lo_r * d[0], 0.08 + lo_r * d[1]
            n = 0.019 - 0.07 * (u / W) ** 2
            pts.append(sc + across * u + up * w + nrm * n)
        return pts

    def rim_fn(G):
        u, w, n = coords(G)
        o = outline(u, w)
        d = np.maximum(np.abs(o + 0.011) - 0.012, np.abs(n - 0.003) - 0.016)
        return studs(d, G, rivet_points(), 0.0045)

    def sun_fn(G):
        u, w, n = coords(G)
        rad = np.sqrt(u ** 2 + (w - 0.06) ** 2)
        ang = np.arctan2(w - 0.06, u)
        ray = (0.5 + 0.5 * np.cos(ang * 8)) ** 3
        flat = rad - 0.11 * (0.45 + 0.55 * ray)
        ring = np.abs(rad - 0.046) - 0.007
        relief = 0.004 * np.clip(1.0 - rad / 0.11, 0, 1)            # higher toward the centre
        return np.maximum(np.minimum(flat, ring), np.abs(n - 0.016 - relief / 2) - 0.006 - relief / 2)
    return [Part("shield_face", "cloth", face_fn, lo, hi, 2000, skin="forearm_l", voxel=0.0025, facet_deg=40),
            Part("shield_rim", "plate", rim_fn, lo, hi, 2400, skin="forearm_l", voxel=0.002, facet_deg=40),
            Part("shield_sun", "gold", sun_fn, lo, hi, 1600, skin="forearm_l", voxel=0.0015, facet_deg=40)]


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
