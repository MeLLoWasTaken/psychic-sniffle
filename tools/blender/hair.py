"""Hair and beards for the character creator (backlog G-02), as distance fields on the head.

Every style is a field sampled on one grid around the head: a cap (a shell over the scalp whose
thickness the style sets, cut at a hairline), plus clumps (tapered, grooved cones along curves)
for locks, braids, knots and beards. Clumps are trimmed where they would pass into the body, so
long hair lies on the shoulders and back instead of through them. Grooves along the cap's flow
and around each clump give the strand detail the normal map carries.

Styles are listed in data/appearance/hair.json and beards.json (ids, names, which body types);
their geometry is here, keyed by id. Head-local coordinates: x across, y front (-) to back (+),
z up from the chin, all in units of the head scale `s` (anatomy.head_frame).
"""
from __future__ import annotations

import numpy as np

import anatomy
import sdf

# hairline height (head-local z) by angle around the head (degrees from the front, |angle|)
HAIRLINE = [(0, 0.168), (35, 0.163), (60, 0.152), (85, 0.138), (100, 0.13), (120, 0.104), (150, 0.074), (180, 0.064)]
EAR = np.array([0.075, 0.012, 0.108])
SKULL_Y = 0.02


def _local(P, hz, s):
    return np.stack([P[..., 0] / s, P[..., 1] / s, (P[..., 2] - hz) / s], axis=-1)


def _angle(L):
    """Degrees around the head's vertical axis from the front (-y), 0..180 either side."""
    return np.degrees(np.abs(np.arctan2(L[..., 0], -(L[..., 1] - SKULL_Y))))


def grooved_cone(sh: sdf.Shape, a, b, r1, r2, grooves: int = 7, depth: float = 0.0012, k: float = 0.01, name=""):
    """A tapered lock of hair with grooves running along it."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    ax = (b - a) / np.linalg.norm(b - a)
    ref = np.array([0.0, 0.0, 1.0]) if abs(ax[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    u = np.cross(ax, ref)
    u /= np.linalg.norm(u)
    w = np.cross(ax, u)

    def fn(P, a=a, b=b):
        d = sdf.sd_round_cone(P, a, b, r1, r2)
        q = P - a
        phi = np.arctan2(q @ w, q @ u)
        return d + depth * (0.5 + 0.5 * np.sin(grooves * phi))
    m = max(r1, r2) + depth
    sh.prims.append(sdf.Prim(fn, np.minimum(a, b) - m, np.maximum(a, b) + m, k, False, name))


def lock(sh: sdf.Shape, pts, r0: float, r1: float, grooves: int = 6, k: float = 0.012, name: str = "lock"):
    """A lock along a polyline, radius r0 at the root to r1 at the tip."""
    pts = [np.asarray(p, float) for p in pts]
    n = len(pts) - 1
    for i in range(n):
        ra = r0 + (r1 - r0) * i / n
        rb = r0 + (r1 - r0) * (i + 1) / n
        grooved_cone(sh, pts[i], pts[i + 1], ra, rb, grooves=grooves, depth=0.0012 * (ra / max(r0, 1e-6)) + 0.0004,
                     k=k, name=name)


def around(theta_deg: float, z: float, r_scale: float = 1.0, out: float = 0.0):
    """A point on (or `out` beyond) an ellipse around the skull at head-local height z."""
    t = np.radians(theta_deg)
    # skull half-widths shrink toward the crown
    zc = 0.149
    k = np.sqrt(max(0.0, 1.0 - ((z - zc) / 0.1) ** 2)) if z > zc else 1.0
    rx, ry = 0.075 * k * r_scale + out, 0.097 * k * r_scale + out
    return np.array([np.sin(t) * rx, SKULL_Y - np.cos(t) * ry, z])


# ----------------------------------------------------------------------------- styles

def _thickness(style: str, L):
    """Cap thickness (head-local units) over the scalp, per style; 0 means no cap there."""
    z, ang = L[..., 2], _angle(L)
    top = np.clip((z - 0.12) / 0.12, 0.0, 1.0)
    if style == "cropped":
        return np.full(z.shape, 0.018)
    if style == "swept":  # volume on top, combed back and down over the crown
        back = np.clip((ang - 60) / 120, 0, 1)
        return 0.03 + 0.08 * top * (1 - 0.4 * back) + 0.05 * back * np.clip((z - 0.06) / 0.1, 0, 1)
    if style == "long":
        return 0.045 + 0.03 * top
    if style == "topknot":
        return np.where(ang < 200, 0.022 + 0.02 * top, 0.0)
    if style == "braided":
        return 0.04 + 0.02 * top
    if style == "ridge":  # only a strip along the middle
        return (0.03 + 0.035 * top) * np.clip((0.028 - np.abs(L[..., 0])) / 0.01, 0.0, 1.0)
    raise KeyError(style)


def _locks(style: str, sh: sdf.Shape):
    """Clumps per style, in head-local units (converted by the caller)."""
    if style == "long":
        for sgn in (-1, 1):  # the parting's two front locks frame the face
            lock(sh, [around(sgn * 8, 0.23), around(sgn * 40, 0.185, out=0.02), around(sgn * 62, 0.1, out=0.025),
                      around(sgn * 70, -0.02, out=0.03)], 0.026, 0.012, name="long_front")
    if style == "topknot":
        knot = np.array([0.0, 0.07, 0.25])
        sh.ellipsoid(knot, (0.045, 0.04, 0.038), k=0.02, name="knot")
        sh.round_cone(knot - np.array([0, 0.0, 0.035]), knot - np.array([0, 0.01, 0.06]), 0.028, 0.03, k=0.015, name="knot_band")
        for th in (-140, -100, -60, -25, 25, 60, 100, 140):
            lock(sh, [around(th, 0.15, out=0.0), around(th * 0.6, 0.215, out=0.012), knot + np.array([0, 0, -0.02])],
                 0.012, 0.016, grooves=5, name="knot_lock")
    if style == "braided":
        top = around(180, 0.1, out=0.02)
        prev = top
        for i in range(12):  # a three-strand braid read as alternating lobes down the back
            z = 0.06 - i * 0.042
            p = np.array([0.012 * (1 if i % 2 else -1), 0.13 + 0.01 * min(i, 4) - 0.004 * max(0, i - 6), z])
            r = 0.03 - 0.0012 * i
            sh.ellipsoid(p, (r * 1.1, r * 0.8, r * 1.1), k=0.012, rot=sdf.frame((0.6 if i % 2 else -0.6, 0.2, 1.0)), name="braid")
            prev = p
        sh.round_cone(prev, prev - np.array([0, 0, 0.06]), 0.016, 0.006, k=0.01, name="braid_tail")
        for th in (-145, 145):
            lock(sh, [around(th, 0.15, out=0.006), around(th * 1.1, 0.11, out=0.016), top], 0.024, 0.022, name="braid_gather")
    if style == "ridge":
        for i, (z, y) in enumerate(((0.235, -0.02), (0.25, 0.03), (0.235, 0.08))):
            base = np.array([0.0, y, z])
            tip = base + np.array([0.0, 0.04, 0.035])
            grooved_cone(sh, base, tip, 0.026, 0.008, grooves=5, k=0.02, name="ridge_spike")


BEARD_STYLES = ("full", "long", "goatee", "moustache")


def _beard(style: str, sh: sdf.Shape):
    if style in ("full", "long"):
        for th in (-75, -55, -35, -15, 15, 35, 55, 75):
            sgn = np.sign(th)
            a = np.radians(th)
            root = np.array([0.058 * np.sin(a), -0.02 - 0.06 * np.cos(a), 0.075])
            tip_z = -0.02 if style == "full" else -0.12
            tip = np.array([0.03 * np.sin(a), -0.075 - 0.02 * np.cos(a) * (style == "long"), tip_z])
            mid = (root + tip) / 2 + np.array([0.008 * sgn, -0.02, 0.0])
            lock(sh, [root, mid, tip], 0.02, 0.012 if style == "full" else 0.008, grooves=6, k=0.014, name="beard")
    if style == "goatee":
        lock(sh, [np.array([0.0, -0.092, 0.035]), np.array([0.0, -0.1, 0.0]), np.array([0.0, -0.09, -0.045])],
             0.02, 0.008, grooves=6, name="goatee")
    if style in ("full", "long", "goatee", "moustache"):
        for sgn in (-1, 1):  # moustache: from under the nose out past the mouth's corners
            lock(sh, [np.array([sgn * 0.004, -0.107, 0.066]), np.array([sgn * 0.02, -0.104, 0.06]),
                      np.array([sgn * 0.032, -0.094, 0.045])], 0.008, 0.005, grooves=4, k=0.006, name="moustache")


def _smooth01(x):
    t = np.clip(x, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def _mane(L, s):
    """Long hair below the cap: a mass hanging from the crown behind the face to the shoulders,
    with a ragged hem and grooves running down it (head-local units in, world distance out)."""
    x, y, z = L[..., 0], L[..., 1] - SKULL_Y, L[..., 2]
    ang = _angle(L)
    # how far out the hair hangs from the head's axis, widening a little toward the hem
    k = np.clip((0.15 - z) / 0.3, 0.0, 1.0)
    rx, ry = 0.086 + 0.03 * k, 0.106 + 0.025 * k
    r = np.sqrt((x / rx) ** 2 + (y / ry) ** 2)
    outer = (r - 1.0) * 0.09
    inner = (0.8 - r) * 0.09                      # a thick shell, hollow inside (the head and neck sit there)
    hem = (-0.16 + 0.025 * np.sin(np.radians(ang) * 9.0) - 0.04 * (ang > 120)
           - 0.03 * (np.abs((ang / 13.85) % 1.0 - 0.5) * 2.0) ** 3)   # each lock ends in a point
    bottom = hem - z
    top = z - 0.17
    face = (60.0 - ang) * 0.002                    # open in front: the mane starts beside the face
    a = np.radians(ang)
    # locks (deep enough to read as separate locks, not grooves in a curtain) and strands
    grooves = (0.011 * (0.5 + 0.5 * np.sin(a * 13.0 + np.sin(z * 18.0) * 1.5)) ** 2
               + 0.0015 * (0.5 + 0.5 * np.sin(a * 80.0 + np.sin(z * 30.0) * 2.0)))
    d = np.maximum.reduce([outer + grooves, inner, bottom, top, face])
    return d * s


# ----------------------------------------------------------------------------- the field

def build_field(j: dict, body_type: str, style: str, beard: bool = False, voxel: float = 0.002):
    """(field grid, grid origin) of a hair style or beard on a body type's neutral head."""
    hz, s = anatomy.head_frame(j, body_type)
    body = anatomy.body_shape(j, body_type)
    head = anatomy.head_subset(body, j)
    long_hang = (not beard and style in ("long", "braided")) or (beard and style == "long")
    lo = np.array([-0.15, -0.17, hz - (0.45 if long_hang else 0.08) * s])
    hi = np.array([0.15, 0.2, hz + 0.33 * s])
    n = np.ceil((hi - lo) / voxel).astype(int) + 1
    f_head = sdf.eval_grid(head, lo, n, voxel)
    P = sdf.grid_points(lo, n, voxel)
    L = _local(P, hz, s)
    locks = sdf.Shape()
    if beard:
        _beard(style, locks)
        # a thin shell over the jaw and chin carries the beard's base
        z, x, y = L[..., 2], np.abs(L[..., 0]), L[..., 1]
        cheek_line = 0.066 + 0.03 * np.clip(x / 0.06, 0.0, 1.0)        # low beside the mouth, up to the sideburns
        if style in ("full", "long"):
            # the jaw, cheeks and chin, and under the chin only toward the front (not down the throat)
            under = np.where(z < 0.02, -y - 0.045 + (z + 0.01) * 0.6, 1.0)
            inside = np.minimum.reduce([cheek_line - z, -y - 0.002, z + 0.03, under])
        elif style == "goatee":
            inside = np.minimum(np.minimum(0.05 - z, 0.024 - x), np.minimum(-y - 0.06, z + 0.01))
        else:
            inside = np.full(z.shape, -1.0)
        t = (0.005 + 0.01 * np.clip((0.07 - z) / 0.08, 0.0, 1.0)) * s        # thicker toward the chin
        cap = np.maximum(f_head - t * _smooth01(inside / 0.015), -f_head - 0.002)
        cap = np.where(inside > 0, cap, 1.0)
        # keep the lips and the eyes clear
        mouth = np.linalg.norm((L - np.array([0.0, -0.1, 0.052])) * np.array([1.0, 1.6, 2.4]), axis=-1) - 0.03
        cap = np.maximum(cap, -mouth * s)
    else:
        _locks(style, locks)
        t = _thickness(style, L) * s * 0.35
        ang = _angle(L)
        hairline = np.interp(ang, [a for a, _z in HAIRLINE], [z for _a, z in HAIRLINE])
        # a broken fringe: the hairline comes down in pointed locks over the forehead and temples
        # (a straight cut read as a bowl), and in finer points around the ears and nape
        warp = ang + 4.0 * np.sin(np.radians(ang) * 7.3)                    # uneven spacing
        tri = np.abs((warp / 14.0) % 1.0 - 0.5) * 2.0                       # 0 at a point, 1 between
        vary = 0.55 + 0.45 * np.sin(np.floor(warp / 14.0) * 2.4) ** 2       # each lock its own length
        tips = (0.016 if style == "cropped" else 0.011) * vary * (1.0 - tri) ** 1.5
        front = np.clip((85.0 - ang) / 30.0, 0.0, 1.0)
        hairline = hairline - tips * (0.35 + 0.65 * front) - 0.004 * np.sin(np.radians(ang) * 23.0) * front
        below = (hairline - L[..., 2]) * s          # positive below the hairline
        ear_d = np.minimum(np.linalg.norm(L - EAR, axis=-1), np.linalg.norm(L - EAR * np.array([-1, 1, 1]), axis=-1))
        ear_cut = (0.032 - ear_d) * s               # positive near the ears
        rad = np.radians(ang)
        flow = 0.0007 * (0.5 + 0.5 * np.sin(rad * 64.0 + 3.0 * np.sin(rad * 11.0 + L[..., 2] * 37.0)))  # grooves front to back
        t = t * _smooth01((L[..., 2] - hairline) / 0.04)                      # thin out toward the hairline
        cap = np.maximum(f_head - t + flow, -f_head - 0.003)
        cap = np.where(t > 0, cap, 1.0)
        cap = sdf.smax(sdf.smax(cap, below, 0.004), ear_cut, 0.004)
        if style == "long":
            cap = sdf.smin(cap, _mane(L, s), 0.01 * s)
    # locks in head-local units -> world
    world = sdf.Shape()
    for p in locks.prims:
        fn = p.fn
        world.prims.append(sdf.Prim(lambda Q, fn=fn: fn(_local(Q, hz, s)) * s,
                                    p.lo * s + np.array([0, 0, hz]), p.hi * s + np.array([0, 0, hz]), p.k * s, p.subtract, p.name))
    f_locks = sdf.eval_grid(world, lo, n, voxel)
    if long_hang:  # locks (and a mane below the chin) rest on the body instead of passing through it
        f_body = sdf.eval_grid(body, lo, n, voxel)
        f_locks = np.maximum(f_locks, -(f_body - 0.004))
        cap = np.where(L[..., 2] < 0.02, np.maximum(cap, -(f_body - 0.004)), cap)
    else:
        f_locks = np.maximum(f_locks, -(f_head - 0.002))
    return sdf.smin(cap.astype(np.float32), f_locks, 0.006 * s), lo


def build_mesh(j: dict, body_type: str, style: str, beard: bool = False, voxel: float = 0.002):
    f, lo = build_field(j, body_type, style, beard, voxel)
    f[0], f[-1], f[:, 0], f[:, -1], f[:, :, 0], f[:, :, -1] = 1.0, 1.0, 1.0, 1.0, 1.0, 1.0
    verts, faces = sdf.surface(f, voxel)
    return verts + lo, faces
