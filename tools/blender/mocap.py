"""Motion capture into animation terms (backlog X-01).

Reads BVH motion capture (the CMU database in Bruce Hahne's conversion: 120 fps, a T-pose added
as frame 0, facing +Z with +Y up), and measures it in the terms our clips use
(tools/blender/animation.py), so a captured clip goes through the same pipeline as a scripted
one: build offsets, follow-through, weapon holds, the clipping gate and the bake.

Pure numpy here (parsing, forward kinematics, cycle detection); the fit to the standard skeleton
needs the rig and lives in build_capture.py.

Character frame used throughout: faces -Y, left is +X, up is +Z, metres.
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# BVH (x right-of-viewer, y up, facing +z) to the character frame: x stays (the subject's left
# when it faces +z), forward (+z) becomes -y, up (+y) becomes +z.
BVH_TO_CHAR = np.array([[1.0, 0.0, 0.0], [0.0, 0.0, -1.0], [0.0, 1.0, 0.0]])


@dataclass
class Joint:
    name: str
    parent: int
    offset: np.ndarray
    channels: list[str] = field(default_factory=list)
    end: np.ndarray | None = None  # end-site offset, if the joint has one


@dataclass
class Motion:
    joints: list[Joint]
    frames: np.ndarray       # (n_frames, n_channels) raw channel values
    frame_time: float

    @property
    def fps(self) -> float:
        return 1.0 / self.frame_time

    def index(self, name: str) -> int:
        for i, j in enumerate(self.joints):
            if j.name == name:
                return i
        raise KeyError(name)


def parse_bvh(path: Path) -> Motion:
    tokens = re.split(r"\s+", Path(path).read_text().strip())
    joints: list[Joint] = []
    stack: list[int] = []
    i = 0
    pending_end = False
    while tokens[i] != "MOTION":
        t = tokens[i]
        if t in ("ROOT", "JOINT"):
            joints.append(Joint(tokens[i + 1], stack[-1] if stack else -1, np.zeros(3)))
            i += 2
        elif t == "End":
            pending_end = True
            i += 2
        elif t == "{":
            stack.append(-2 if pending_end else len(joints) - 1)
            i += 1
        elif t == "}":
            stack.pop()
            pending_end = False if not stack or stack[-1] != -2 else pending_end
            i += 1
        elif t == "OFFSET":
            v = np.array([float(x) for x in tokens[i + 1:i + 4]])
            if stack and stack[-1] == -2:
                joints[stack[-2]].end = v
            else:
                joints[-1].offset = v
            i += 4
        elif t == "CHANNELS":
            n = int(tokens[i + 1])
            joints[-1].channels = tokens[i + 2:i + 2 + n]
            i += 2 + n
        else:
            i += 1
    n_frames = int(tokens[i + 2])
    frame_time = float(tokens[i + 5])
    values = np.array([float(x) for x in tokens[i + 6:]])
    n_ch = sum(len(j.channels) for j in joints)
    return Motion(joints, values.reshape(n_frames, n_ch), frame_time)


def _axis_rot(axis: str, deg: np.ndarray) -> np.ndarray:
    a = np.radians(deg)
    c, s = np.cos(a), np.sin(a)
    m = np.zeros(a.shape + (3, 3))
    k = "XYZ".index(axis)
    i, j = [(1, 2), (2, 0), (0, 1)][k]
    m[..., k, k] = 1.0
    m[..., i, i] = c
    m[..., j, j] = c
    m[..., i, j] = -s
    m[..., j, i] = s
    return m


def forward_kinematics(m: Motion) -> tuple[np.ndarray, np.ndarray]:
    """World rotations (n_frames, n_joints, 3, 3) and positions (n_frames, n_joints, 3), in the
    character frame, in the file's units."""
    n = len(m.frames)
    rots = np.zeros((n, len(m.joints), 3, 3))
    pos = np.zeros((n, len(m.joints), 3))
    col = 0
    for ji, j in enumerate(m.joints):
        local = np.broadcast_to(np.eye(3), (n, 3, 3)).copy()
        trans = np.broadcast_to(j.offset, (n, 3)).copy()
        for ch in j.channels:
            v = m.frames[:, col]
            col += 1
            if ch.endswith("position"):
                trans[:, "XYZ".index(ch[0])] = v + (0.0 if j.parent >= 0 else 0.0)
            else:
                local = local @ _axis_rot(ch[0], v)
        if j.parent < 0:
            rots[:, ji] = local
            pos[:, ji] = trans
        else:
            rots[:, ji] = rots[:, j.parent] @ local
            pos[:, ji] = pos[:, j.parent] + np.einsum("nij,nj->ni", rots[:, j.parent], trans)
    c = BVH_TO_CHAR
    return np.einsum("ij,nkjl,ml->nkim", c, rots, c), np.einsum("ij,nkj->nki", c, pos)


def end_positions(m: Motion, rots: np.ndarray, pos: np.ndarray, name: str) -> np.ndarray:
    """World position of a joint's end site (e.g. the head top or toe tip)."""
    ji = m.index(name)
    off = BVH_TO_CHAR @ m.joints[ji].end
    return pos[:, ji] + np.einsum("nij,j->ni", rots[:, ji], off)


def leg_length(m: Motion) -> float:
    """Hip to ankle length along the rest offsets (file units)."""
    return float(np.linalg.norm(m.joints[m.index("LeftLeg")].offset) + np.linalg.norm(m.joints[m.index("LeftFoot")].offset))


def heading_rotation(direction: np.ndarray) -> np.ndarray:
    """Rotation about +Z that turns a horizontal direction to face -Y."""
    ang = math.atan2(direction[0], -direction[1])
    c, s = math.cos(-ang), math.sin(-ang)
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


def contacts(height: np.ndarray, fps: float, min_gap_s: float = 0.25) -> list[int]:
    """Frames where a foot reaches a local minimum of height (a footfall)."""
    h = np.convolve(height, np.ones(5) / 5, mode="same")
    gap = int(min_gap_s * fps)
    out = []
    for i in range(2, len(h) - 2):
        if h[i] <= h[i - 1] and h[i] < h[i + 1] and h[i] <= np.min(h[max(0, i - gap):i + gap]):
            if not out or i - out[-1] >= gap:
                out.append(i)
    return out


def summary(path: Path) -> dict:
    """Speed, cadence and stride of a locomotion capture (for choosing clips)."""
    m = parse_bvh(path)
    rots, pos = forward_kinematics(m)
    rots, pos = rots[1:], pos[1:]  # frame 0 is the added T-pose
    leg = leg_length(m)
    hips = pos[:, 0]
    toe = end_positions(m, rots, pos, "LeftToeBase")[:]
    foot_l = pos[:, m.index("LeftFoot")]
    c = contacts(foot_l[:, 2], m.fps)
    steps = np.diff(c) / m.fps if len(c) > 1 else np.array([])
    speed = np.linalg.norm(np.diff(hips[:, :2], axis=0), axis=1) * m.fps
    mid = slice(len(speed) // 4, 3 * len(speed) // 4)
    v = float(np.median(speed[mid]))
    cycle = float(np.median(steps)) if len(steps) else float("nan")
    return {"file": Path(path).stem, "frames": len(hips), "fps": round(m.fps, 1), "leg_units": round(leg, 2),
            "speed_legs_per_s": round(v / leg, 2), "cycle_s": round(cycle, 3),
            "stride_legs": round(v * cycle / leg, 2), "contacts": len(c), "toe_min": round(float(toe[:, 2].min() / leg), 3)}
