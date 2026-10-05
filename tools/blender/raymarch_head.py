"""Quick shaded views of the head's distance field, for iterating on the face (backlog G-16).

Sphere-traces the head primitives (anatomy.add_head plus the neck) with numpy and shades them
with a key light, a fill and ambient occlusion, so a face change can be checked in about a
minute instead of a full Blender render (tools/blender/preview_head.py, 7-12 minutes).

    python3 tools/blender/raymarch_head.py --out previews/g_16/rm.png --types male,female --faces neutral
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import anatomy  # noqa: E402
import humanoid  # noqa: E402
import sdf  # noqa: E402

EYE_C = np.array([0.031, -0.082, 0.12])
EYE_R = 0.0122
SKIN = np.array([0.69, 0.54, 0.44])


def head_field(body_type: str, face: str):
    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[body_type]).items()}
    shape = anatomy.body_shape(j, body_type, face=face)
    cut = float(j["chest_top"][2]) + 0.02
    keep = sdf.Shape([p for p in shape.prims if p.hi[2] > cut and abs((p.lo[0] + p.hi[0]) / 2) < 0.2])

    def fn(P):
        return np.maximum(sdf.eval_points(keep, P), cut - P[:, 2])
    hz, s = anatomy.head_frame(j, body_type)
    return fn, hz, s


def render(fn, target, yaw_deg: float, size: int, dist: float, fov_deg: float = 26.0, pitch_deg: float = 4.0):
    yaw, pitch = np.radians(yaw_deg), np.radians(pitch_deg)
    # the face looks along -y, so the camera looks along +y; yaw 0 is a front view, 90 the left
    # (+x) profile
    fwd = np.array([-np.sin(yaw) * np.cos(pitch), np.cos(yaw) * np.cos(pitch), -np.sin(pitch)])
    eye = target - fwd * dist
    right = np.cross(fwd, [0, 0, 1.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    t = np.tan(np.radians(fov_deg) / 2)
    u = (np.arange(size) + 0.5) / size * 2 - 1
    gx, gy = np.meshgrid(u * t, -u * t)
    D = fwd[None] + gx.ravel()[:, None] * right[None] + gy.ravel()[:, None] * up[None]
    D /= np.linalg.norm(D, axis=1, keepdims=True)
    n = len(D)
    T = np.full(n, dist - 0.25)
    hit = np.zeros(n, bool)
    alive = np.ones(n, bool)
    for _ in range(90):
        idx = np.nonzero(alive)[0]
        if len(idx) == 0:
            break
        P = eye[None] + D[idx] * T[idx, None]
        d = fn(P)
        done = d < 2e-4
        hit[idx[done]] = True
        T[idx] += np.where(done, 0.0, d * 0.8)
        far = T[idx] > dist + 0.3
        alive[idx[done | far]] = False
    img = np.tile(np.array([0.42, 0.46, 0.52]), (n, 1))
    idx = np.nonzero(hit)[0]
    P = eye[None] + D[idx] * T[idx, None]
    e = 4e-4
    N = np.stack([fn(P + v) - fn(P - v) for v in np.eye(3) * e], axis=1)
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    # ambient occlusion: how far the field falls short of the step along the normal
    ao = np.ones(len(P))
    for k, h in enumerate((0.003, 0.007, 0.013, 0.022)):
        ao -= np.clip(h - fn(P + N * h), 0, None) / h * (0.5 ** k) * 0.55
    ao = np.clip(ao, 0, 1)
    # lights follow the camera: a key from upper left, a fill from the right
    key = -fwd * 0.7 - right * 0.5 + up * 0.6
    key /= np.linalg.norm(key)
    fill = -fwd * 0.4 + right * 0.7 + up * 0.1
    fill /= np.linalg.norm(fill)
    V = -D[idx]
    lam = np.clip(N @ key, 0, None)
    H = key[None] + V
    H /= np.linalg.norm(H, axis=1, keepdims=True)
    spec = np.clip((N * H).sum(1), 0, None) ** 40 * 0.12
    shade = (0.85 * lam + 0.25 * np.clip(N @ fill, 0, None)) * (0.4 + 0.6 * ao) + 0.22 * ao
    col = SKIN[None] * shade[:, None] + spec[:, None]
    img[idx] = col
    return (np.clip(img, 0, 1) ** (1 / 1.6) * 255).astype(np.uint8).reshape(size, size, 3), P, idx


def paint_eyes(img, P, idx, hz, s, size):
    flat = img.reshape(-1, 3)
    for side in (1, -1):
        c = np.array([side * EYE_C[0] * s, EYE_C[1] * s, hz + EYE_C[2] * s])
        q = P - c
        on = np.abs(np.linalg.norm(q, axis=1) - EYE_R * s) < 0.0012
        ang = np.degrees(np.arccos(np.clip(-q[:, 1] / np.maximum(np.linalg.norm(q, axis=1), 1e-9), -1, 1)))
        flat[idx[on & (ang < 70)]] = (flat[idx[on & (ang < 70)]] * 0.2 + np.array([210, 205, 195]) * 0.8).astype(np.uint8)
        flat[idx[on & (ang < 26)]] = (70, 45, 30)
        flat[idx[on & (ang < 11)]] = (15, 10, 8)
    return flat.reshape(img.shape)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--types", default="male,female")
    ap.add_argument("--faces", default="neutral")
    ap.add_argument("--size", type=int, default=360)
    ap.add_argument("--yaws", default="0,35,90")
    ap.add_argument("--dist", type=float, default=0.75)
    args = ap.parse_args()
    yaws = [float(y) for y in args.yaws.split(",")]
    rows = []
    labels = []
    for bt in args.types.split(","):
        for face in args.faces.split(","):
            fn, hz, s = head_field(bt, face)
            target = np.array([0.0, -0.01 * s, hz + 0.1 * s])
            row = []
            for y in yaws:
                img, P, idx = render(fn, target, y, args.size, args.dist)
                row.append(paint_eyes(img, P, idx, hz, s, args.size))
            rows.append(np.concatenate(row, axis=1))
            labels.append(f"{bt} {face}")
            print(f"  {bt} {face}", flush=True)
    sheet = Image.fromarray(np.concatenate(rows, axis=0))
    d = ImageDraw.Draw(sheet)
    for i, lab in enumerate(labels):
        d.text((6, 4 + i * args.size), lab, fill=(255, 255, 255))
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print(f"saved {args.out}")


if __name__ == "__main__":
    main()
