"""Signed-distance-field modelling for organic shapes (backlog M1-16, body attempt 3).

A shape is a list of primitives (tapered capsules, ellipsoids, rounded boxes, spheres), each
merged into the field with a smooth union of blend radius k (or smoothly subtracted). Smooth
unions of tapered limbs give continuous, sculpted-looking transitions; the earlier metaball
body read as separate blobs. `extract` turns the field into a closed triangle mesh with
marching cubes.

Pure numpy (no Blender), so shapes can be built and checked quickly. Coordinates follow the
character convention: metres, +Z up, the character faces -Y, its left is +X.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from skimage import measure

Vec = tuple[float, float, float]


def _v(a) -> np.ndarray:
    return np.asarray(a, dtype=np.float64)


def frame(axis, up=(0.0, 0.0, 1.0)) -> np.ndarray:
    """Rotation matrix whose local x axis is `axis` (rows are the local axes in world space)."""
    x = _v(axis)
    x = x / np.linalg.norm(x)
    u = _v(up)
    if abs(np.dot(x, u / np.linalg.norm(u))) > 0.95:
        u = np.array([0.0, 1.0, 0.0]) if abs(x[1]) < 0.9 else np.array([1.0, 0.0, 0.0])
    z = u - x * np.dot(u, x)
    z = z / np.linalg.norm(z)
    y = np.cross(z, x)
    return np.stack([x, y, z])


# ----------------------------------------------------------------------------- primitives
# Each takes points P (N x 3) and returns distances (N,). Negative is inside.

def sd_round_cone(P, a, b, r1, r2):
    """Capsule whose radius goes from r1 at a to r2 at b (exact; after Inigo Quilez)."""
    a, b = _v(a), _v(b)
    ba = b - a
    l2 = float(ba @ ba)
    rr = r1 - r2
    a2 = l2 - rr * rr
    il2 = 1.0 / l2
    pa = P - a
    y = pa @ ba
    z = y - l2
    xv = pa * l2 - np.outer(y, ba)
    x2 = np.einsum("ij,ij->i", xv, xv)
    y2 = y * y * l2
    z2 = z * z * l2
    k = np.sign(rr) * rr * rr * x2
    d_mid = (np.sqrt(np.maximum(x2 * a2 * il2, 0)) + y * rr) * il2 - r1
    d_b = np.sqrt(x2 + z2) * il2 - r2
    d_a = np.sqrt(x2 + y2) * il2 - r1
    return np.where(np.sign(z) * a2 * z2 > k, d_b, np.where(np.sign(y) * a2 * y2 < k, d_a, d_mid))


def sd_ellipsoid(P, c, radii, rot=None):
    """Ellipsoid (a close bound, after Inigo Quilez). `rot` rows are its local axes."""
    q = P - _v(c)
    if rot is not None:
        q = q @ np.asarray(rot).T
    r = _v(radii)
    k0 = np.linalg.norm(q / r, axis=1)
    k1 = np.linalg.norm(q / (r * r), axis=1)
    return np.where(k1 > 1e-9, k0 * (k0 - 1.0) / np.maximum(k1, 1e-9), -np.min(r))


def sd_round_box(P, c, half, rounding, rot=None):
    q = P - _v(c)
    if rot is not None:
        q = q @ np.asarray(rot).T
    q = np.abs(q) - (_v(half) - rounding)
    outside = np.linalg.norm(np.maximum(q, 0.0), axis=1)
    inside = np.minimum(np.max(q, axis=1), 0.0)
    return outside + inside - rounding


def sd_sphere(P, c, r):
    return np.linalg.norm(P - _v(c), axis=1) - r


# ----------------------------------------------------------------------------- combining

def smin(a, b, k):
    """Polynomial smooth minimum: a union whose seam is rounded over a width of about k."""
    if k <= 0:
        return np.minimum(a, b)
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b + (a - b) * h - k * h * (1.0 - h)


def smax(a, b, k):
    return -smin(-a, -b, k)


@dataclass
class Prim:
    fn: object                 # callable(P) -> distances
    lo: np.ndarray             # bounding box of the primitive (world)
    hi: np.ndarray
    k: float                   # blend radius with what came before
    subtract: bool = False
    name: str = ""


@dataclass
class Shape:
    prims: list[Prim] = field(default_factory=list)

    # the helpers compute a bounding box so each primitive is evaluated only near itself
    def round_cone(self, a, b, r1, r2, k=0.04, name=""):
        a, b = _v(a), _v(b)
        m = max(r1, r2)
        self.prims.append(Prim(lambda P, a=a, b=b: sd_round_cone(P, a, b, r1, r2),
                               np.minimum(a, b) - m, np.maximum(a, b) + m, k, name=name))

    def ellipsoid(self, c, radii, k=0.03, rot=None, subtract=False, name=""):
        c = _v(c)
        m = float(np.max(radii))
        self.prims.append(Prim(lambda P, c=c: sd_ellipsoid(P, c, radii, rot), c - m, c + m, k, subtract, name))

    def round_box(self, c, half, rounding, k=0.03, rot=None, subtract=False, name=""):
        c = _v(c)
        m = float(np.linalg.norm(half))
        self.prims.append(Prim(lambda P, c=c: sd_round_box(P, c, half, rounding, rot), c - m, c + m, k, subtract, name))

    def sphere(self, c, r, k=0.03, subtract=False, name=""):
        c = _v(c)
        self.prims.append(Prim(lambda P, c=c: sd_sphere(P, c, r), c - r, c + r, k, subtract, name))

    def mirrored(self) -> "Shape":
        """Add a mirror image (x -> -x) of every primitive whose centre is off the midline."""
        out = Shape(list(self.prims))
        for p in self.prims:
            if (p.lo[0] + p.hi[0]) / 2 > 0.01:
                fn = p.fn
                out.prims.append(Prim(lambda P, fn=fn: fn(P * np.array([-1.0, 1.0, 1.0])),
                                      np.array([-p.hi[0], p.lo[1], p.lo[2]]),
                                      np.array([-p.lo[0], p.hi[1], p.hi[2]]), p.k, p.subtract, p.name + "_m"))
        return out

    def bounds(self, margin=0.05):
        lo = np.min([p.lo for p in self.prims], axis=0) - margin
        hi = np.max([p.hi for p in self.prims], axis=0) + margin
        return lo, hi


def evaluate(shape: Shape, voxel: float, floor_z: float | None = 0.0):
    """Sample the field on a grid. Returns (field[x, y, z], origin)."""
    lo, hi = shape.bounds()
    if floor_z is not None:
        lo[2] = min(lo[2], floor_z - 2 * voxel)
    n = np.ceil((hi - lo) / voxel).astype(int) + 1
    f = np.full(tuple(n), 10.0, dtype=np.float32)
    for p in shape.prims:
        margin = 2.0 * p.k + 3 * voxel
        i0 = np.clip(np.floor((p.lo - margin - lo) / voxel).astype(int), 0, n - 1)
        i1 = np.clip(np.ceil((p.hi + margin - lo) / voxel).astype(int) + 1, 1, n)
        axes = [lo[d] + voxel * np.arange(i0[d], i1[d]) for d in range(3)]
        gx, gy, gz = np.meshgrid(*axes, indexing="ij")
        P = np.stack([gx.ravel(), gy.ravel(), gz.ravel()], axis=1)
        d = p.fn(P).reshape(gx.shape).astype(np.float32)
        block = f[i0[0]:i1[0], i0[1]:i1[1], i0[2]:i1[2]]
        if p.subtract:
            block[...] = smax(block, -d, p.k)
        else:
            block[...] = smin(block, d, p.k)
    if floor_z is not None:  # flat soles: nothing below the floor
        zs = lo[2] + voxel * np.arange(n[2])
        f = np.maximum(f, (floor_z - zs)[None, None, :].astype(np.float32))
    return f, lo


def extract(shape: Shape, voxel: float = 0.006, floor_z: float | None = 0.0):
    """Closed triangle mesh of the shape's surface: (vertices N x 3, faces M x 3)."""
    f, origin = evaluate(shape, voxel, floor_z)
    verts, faces, _normals, _vals = measure.marching_cubes(f, level=0.0, spacing=(voxel, voxel, voxel))
    return verts + origin, faces
