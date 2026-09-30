"""Fit motion capture to the standard skeleton, in animation terms (backlog X-01).

    python3 tools/blender/build_capture.py                  # every capture named in the set
    python3 tools/blender/build_capture.py --clip run --report previews/capture

A clip in data/animations/humanoid.json may name a capture:

    "run": {"length_s": 0.7333, "loop": true, "capture": {"source": "run", "bones": [...],
            "gains": {"thigh.swing": 1.4}}, "keys": [...]}

and data/capture_sources/<source>.json says where the source is: a BVH file under
tools/blender/mocap_src (the CMU database, see CREDITS.md), the time window, and for loops
whether the window is found automatically as one clean cycle. This script measures that window
on the heavy build's skeleton, frame by frame, as term values:

- torso (pelvis, spine, chest, neck, head) and feet: the capture's rotation away from its
  T-pose, applied to our bone's rest orientation and read back as bend, twist and lean (or
  point);
- limbs (thighs, calves, clavicles, upper arms, forearms): our bone pointed along the captured
  segment (direction match; the capture's T-pose and our A-pose differ, so rotations would not
  transfer);
- root: hip height and sway, in leg lengths (the clip scales them by each build's leg).

Terms are found by least squares on our own forward kinematics (animation.bone_quaternion), so
they mean exactly what the scripted poses mean. Loops are detrended and seam-corrected so the
last sample joins the first, and start with the left thigh furthest forward (as the scripted clips do). Output: data/captures/<source>.json, samples over the
clip's phase (0 to 1), read by animation.sample_clip.

The set's capture_leg_m must equal each build's hip-to-ankle length (checked here).
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
from scipy.optimize import least_squares

sys.path.insert(0, str(Path(__file__).resolve().parent))
import animation  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402
import mocap  # noqa: E402

REPO = common.REPO
SRC_DIR = REPO / "tools" / "blender" / "mocap_src"
OUT_DIR = REPO / "data" / "captures"
SOURCES_DIR = REPO / "data" / "capture_sources"
SAMPLES_PER_S = 60

TORSO_MAP = {"pelvis": "Hips", "spine": "Spine", "chest": "Spine1", "neck": "Neck1", "head": "Head"}
LIMB_MAP = {  # our bone: (from joint, to joint) of the captured segment, character's left side
    "thigh": ("UpLeg", "Leg"), "calf": ("Leg", "Foot"),
    "clavicle": ("Shoulder", "Arm"), "upperarm": ("Arm", "ForeArm"), "forearm": ("ForeArm", "Hand"),
}
FOOT_JOINT = "Foot"
TERMS = {"pelvis": ["bend", "twist", "lean"], "spine": ["bend", "twist", "lean"], "chest": ["bend", "twist", "lean"],
         "neck": ["bend", "twist", "lean"], "head": ["bend", "twist", "lean"], "thigh": ["swing", "spread"],
         "calf": ["bend"], "foot": ["point"], "clavicle": ["raise", "swing"], "upperarm": ["swing", "raise"],
         "forearm": ["bend"]}
ORDER = ["pelvis", "spine", "chest", "neck", "head", "thigh_l", "calf_l", "foot_l", "thigh_r", "calf_r", "foot_r",
         "clavicle_l", "upperarm_l", "forearm_l", "clavicle_r", "upperarm_r", "forearm_r"]


def src_name(fam_joint: str, side: str) -> str:
    """CMU joint name for a family joint on a side ("UpLeg", "l" -> "LeftUpLeg")."""
    return ("Left" if side == "l" else "Right") + fam_joint


def leg_m(build: str) -> float:
    j = humanoid.joints(humanoid.BUILDS[build])
    return float((j["knee_l"] - j["hip_l"]).length + (j["ankle_l"] - j["knee_l"]).length)


class Rig:
    """Rest data of the standard skeleton as numpy, and forward kinematics for term poses."""

    def __init__(self, rig):
        self.rig = rig
        self.rest = {}
        self.parent = {}
        for b in rig.data.bones:
            m = np.array(b.matrix_local)
            self.rest[b.name] = m
            self.parent[b.name] = b.parent.name if b.parent else None
        self._q = {}

    def local(self, bone: str, terms: dict) -> np.ndarray:
        q = animation.bone_quaternion(self.rig, bone, terms)
        return np.array(q.to_matrix())

    def rel(self, bone: str) -> np.ndarray:
        """Parent rest to bone rest (4x4)."""
        p = self.parent[bone]
        return np.linalg.inv(self.rest[p]) @ self.rest[bone] if p else self.rest[bone]

    def pose_world(self, pose: dict) -> dict[str, np.ndarray]:
        """Armature-space 4x4 matrix of every bone for a term pose (as Blender computes it)."""
        out = {}
        for bname, *_ in humanoid.BONES:
            basis = np.eye(4)
            if bname == "root":
                loc, q = animation.root_transform(self.rig, pose.get("root", {}))
                basis[:3, :3] = np.array(q.to_matrix())
                basis[:3, 3] = np.array(loc)
            elif bname in pose:
                basis[:3, :3] = self.local(bname, pose[bname])
            p = self.parent[bname]
            out[bname] = (out[p] if p else np.eye(4)) @ self.rel(bname) @ basis
        return out


def _solve(rig: Rig, bone: str, parent_world: np.ndarray, target: np.ndarray, mode: str, x0: np.ndarray) -> np.ndarray:
    """Term values for one bone: 'rot' matches a world rotation (3x3), 'dir' points the bone
    along a world direction."""
    names = TERMS[animation.family(bone)]
    base = parent_world[:3, :3] @ rig.rel(bone)[:3, :3]

    def resid(x):
        m = base @ rig.local(bone, dict(zip(names, x)))
        if mode == "rot":
            return (m - target).ravel()
        return m[:, 1] - target  # a bone points along its local +Y

    # mathutils works in single precision, so the Jacobian uses a fixed central step well above
    # its resolution (0.05 degrees moves a unit axis by about 1e-3); scipy's automatic step
    # falls back to 6e-6 at exactly zero, where every difference rounds away
    def jac(x):
        cols = []
        for i in range(len(x)):
            d = np.zeros(len(x))
            d[i] = 0.05
            cols.append((resid(x + d) - resid(x - d)) / 0.1)
        return np.stack(cols, axis=1)

    r = least_squares(resid, x0, jac=jac, method="trf", xtol=1e-8, ftol=1e-10)
    return r.x


def cycle_window(rots, pos, m: mocap.Motion, cycle: tuple[float, float]) -> tuple[int, int]:
    """Start and length (source frames) of the cleanest cycle: the period of the leg motion found
    by autocorrelation within `cycle` seconds, and the start where the pose at the start best
    matches the pose one period later."""
    hips = pos[:, 0]
    feat = []
    for side in ("Left", "Right"):
        for j in ("Leg", "Foot", "ToeBase", "ForeArm", "Hand"):
            feat.append(pos[:, m.index(side + j)] - hips)
    f = np.concatenate(feat, axis=1)
    f = f - f.mean(axis=0)
    lo, hi = int(cycle[0] * m.fps), int(cycle[1] * m.fps)
    n = len(f)
    best_p, best_s = lo, -1e9
    for p in range(lo, min(hi, n - 2) + 1):
        a, b = f[:n - p], f[p:]
        s = np.sum(a * b) / math.sqrt(np.sum(a * a) * np.sum(b * b))
        if s > best_s:
            best_p, best_s = p, s
    errs = [(np.linalg.norm(f[s] - f[s + best_p]), s) for s in range(0, n - best_p)]
    return min(errs)[1], best_p


def fit(source: dict, rig: Rig, build: str) -> dict:
    m = mocap.parse_bvh(SRC_DIR / source["file"])
    rots, pos = mocap.forward_kinematics(m)
    rest_rots, rest_pos = rots[0], pos[0]  # the added T-pose
    rots, pos = rots[1:], pos[1:]
    src_leg = mocap.leg_length(m)
    start = int(round(source.get("start_s", 0.0) * m.fps))
    if source.get("loop"):
        if "cycle_s" in source and "start_s" in source:
            length = int(round(source["cycle_s"] * m.fps))
        else:
            start, length = cycle_window(rots, pos, m, tuple(source.get("cycle_search_s", [0.5, 0.95])))
    else:
        length = int(round(source["length_s"] * m.fps))
    idx = np.arange(start, start + length + 1)
    idx = np.clip(idx, 0, len(pos) - 1)
    hips = pos[idx, 0]
    # heading: travel direction for moving clips, else the hips' facing
    travel = hips[-1, :2] - hips[0, :2]
    if source.get("loop") and np.linalg.norm(travel) / src_leg > 0.5:
        fwd = np.array([travel[0], travel[1], 0.0])
    else:
        left = (pos[idx, m.index("LeftUpLeg")] - pos[idx, m.index("RightUpLeg")]).mean(axis=0)
        fwd = np.cross(left, [0.0, 0.0, 1.0])
    H = mocap.heading_rotation(fwd / np.linalg.norm(fwd))
    ours = leg_m(build)
    scale = ours / src_leg

    channels: dict[str, dict[str, list[float]]] = {}
    prev: dict[str, np.ndarray] = {}
    root_up, root_fwd, root_left = [], [], []
    for k, fi in enumerate(idx):
        R = np.einsum("ij,njk->nik", H, rots[fi])
        P = pos[fi] @ H.T
        h = P[0]
        root = {"up": (h[2] - rest_pos[0][2]) * scale, "forward": -h[1] * scale, "left": h[0] * scale}
        root_up.append(root["up"])
        root_fwd.append(root["forward"])
        root_left.append(root["left"])
        pose: dict[str, dict[str, float]] = {"root": {"up": root["up"]}}
        world = rig.pose_world(pose)
        for bone in ORDER:
            fam, s = animation.family(bone), animation.side(bone)
            parent = rig.parent[bone]
            if fam in TORSO_MAP:
                ji = m.index(TORSO_MAP[fam])
                delta = R[ji] @ rest_rots[ji].T
                target, mode = delta @ rig.rest[bone][:3, :3], "rot"
            elif fam == "foot":
                ji = m.index(src_name(FOOT_JOINT, s))
                delta = R[ji] @ rest_rots[ji].T
                target, mode = delta @ rig.rest[bone][:3, 1], "dir"
            else:
                a, b = LIMB_MAP[fam]
                d = P[m.index(src_name(b, s))] - P[m.index(src_name(a, s))]
                target, mode = d / np.linalg.norm(d), "dir"
            x0 = prev.get(bone, np.zeros(len(TERMS[fam])))
            x = _solve(rig, bone, world[parent], target, mode, x0)
            prev[bone] = x
            pose[bone] = dict(zip(TERMS[fam], (float(v) for v in x)))
            world = rig.pose_world(pose)
            for t, v in pose[bone].items():
                channels.setdefault(bone, {}).setdefault(t, []).append(v)
    channels["root"] = {"up": root_up, "forward": root_fwd, "left": root_left}
    n = len(idx)
    loop = bool(source.get("loop"))
    for bone, terms in channels.items():
        for t, v in terms.items():
            a = np.unwrap(np.radians(v)) if bone != "root" else np.array(v)
            a = np.degrees(a) if bone != "root" else a
            if loop:  # remove drift (travel) and the seam mismatch: last sample joins the first
                a = a - (a[-1] - a[0]) * np.linspace(0.0, 1.0, n)
            if bone == "root" and t in ("forward", "left"):
                a = a - a.mean()
            if bone == "root":
                a = a / ours  # stored in leg lengths
            terms[t] = a
    # resample over the phase
    count = max(8, int(round(length / m.fps * SAMPLES_PER_S)))
    phase_src = np.linspace(0.0, 1.0, n)
    phase = np.linspace(0.0, 1.0, count + 1)
    res = {b: {t: np.interp(phase, phase_src, v) for t, v in terms.items()} for b, terms in channels.items()}
    if loop:
        # phase convention shared with the scripted clips: the left thigh furthest forward at phase 0
        shift = int(np.argmax(res["thigh_l"]["swing"][:-1]))
        for terms in res.values():
            for t, v in terms.items():
                body = np.roll(v[:-1], -shift)
                terms[t] = np.append(body, body[0])
    out = {b: {t: [round(float(x), 3 if b != "root" else 5) for x in v] for t, v in terms.items()}
           for b, terms in res.items()}
    return {"source_frames": [int(idx[0]), int(idx[-1])], "source_fps": m.fps, "duration_s": round(length / m.fps, 4),
            "samples": count + 1, "channels": out, "leg_units": round(src_leg, 3)}


def main() -> None:
    import bpy  # noqa: F401

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", action="append", help="capture source id (default: all)")
    args = ap.parse_args()
    sources = {p.stem: json.loads(p.read_text()) for p in sorted(SOURCES_DIR.glob("*.json"))}
    anim = animation.load_set("humanoid")
    for build in humanoid.BUILDS:
        want = round(leg_m(build), 4)
        have = anim.get("capture_leg_m", {}).get(build)
        if have is None or abs(have - want) > 1e-3:
            sys.exit(f"humanoid.json capture_leg_m.{build} should be {want} (hip to ankle), found {have}")
    common.reset_scene()
    rig = Rig(humanoid.build_armature("heavy", "rig_capture"))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for sid, src in sources.items():
        if args.source and sid not in args.source:
            continue
        res = fit(src, rig, "heavy")
        doc = {"id": sid, "description": f"Generated by tools/blender/build_capture.py from capture_sources/{sid}.json; do not edit.",
               "file": src["file"], "loop": bool(src.get("loop")), **res}
        (OUT_DIR / f"{sid}.json").write_text(json.dumps(doc, separators=(",", ":")) + "\n")
        print(f"CAPTURE {sid}: frames {res['source_frames']} ({res['duration_s']} s), {res['samples']} samples")


if __name__ == "__main__":
    main()
