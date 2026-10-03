"""Parametric humanoid body as a signed distance field (backlog M1-16, attempt 3).

Built on the standard skeleton's joint positions (humanoid.joints), so the mesh and the rig
always line up. Limbs are tapered capsules joint to joint; muscles, hands, feet and the face are
blended on with smooth unions. Only the character's left side is described; `mirrored()` adds
the right.

Style targets (docs/DESIGN.md, docs/ART_BIBLE.md): heroic, about 7.5 heads tall, broad
shoulders, oversized hands and feet, harsh facial features (heavy brow, strong jaw).
"""
from __future__ import annotations

import numpy as np

import sdf

# Per-build scale factors on the heavy build's measurements (widths only; heights come from the
# skeleton). torso: torso and neck widths; limb: limb radii; muscle: muscle masses; hand/foot:
# extremity size; jaw: jaw and brow heaviness.
BUILD_SCALES = {
    "heavy": {"torso": 1.0, "limb": 1.0, "muscle": 1.0, "hand": 1.22, "foot": 1.08, "jaw": 1.0},
    "lean": {"torso": 0.8, "limb": 0.8, "muscle": 0.62, "hand": 1.08, "foot": 1.0, "jaw": 0.82},
    # overhaul bodies (anatomy.py, G-01): only the hand scale is read here (hands and weapon grips)
    "male": {"torso": 1.0, "limb": 1.0, "muscle": 1.0, "hand": 1.08, "foot": 1.05, "jaw": 1.0},
    "female": {"torso": 0.86, "limb": 0.84, "muscle": 0.55, "hand": 0.94, "foot": 0.95, "jaw": 1.0},
}


# Finger curl per hand pose: bends (degrees) at the three knuckles. A fist wraps the fingers
# around a handle instead (see _hand); relaxed hands hang with a soft curl.
HAND_POSES = {"relaxed": (18, 30, 20), "open": (5, 8, 5)}
GRIP_RADIUS_M = 0.02   # handle radius a fist closes around (the weapons' grips are 0.018-0.02 m)


def hand_frame(j: dict, side: str):
    """Axes of a hand in the rest pose: x along the hand, palm toward the body, fwd across the
    knuckles toward the thumb (the character's front)."""
    wrist, end = j[f"wrist_{side}"], j[f"hand_end_{side}"]
    x = (end - wrist) / np.linalg.norm(end - wrist)
    inward = np.array([-1.0 if side == "l" else 1.0, 0.0, 0.0])
    palm = inward - x * (x @ inward)
    palm /= np.linalg.norm(palm)
    fwd = np.cross(palm, x) if side == "l" else np.cross(x, palm)
    fwd /= np.linalg.norm(fwd)
    if fwd[1] > 0:  # thumb and index face the front (-Y)
        fwd = -fwd
    return x, palm, fwd


def fist_grip(j: dict, side: str, build: str) -> np.ndarray:
    """Centre of the hole a fist closes around (where a held weapon's grip axis passes)."""
    H = BUILD_SCALES[build]["hand"]
    x, palm, _fwd = hand_frame(j, side)
    radius = GRIP_RADIUS_M + 0.0155 * H
    knuckle = j[f"wrist_{side}"] + x * (0.096 * H)
    return knuckle + x * 0.008 + palm * radius


def _hand(sh: sdf.Shape, j: dict, side: str, build: str, pose: str) -> None:
    """Oversized hand: palm block, four fingers (index toward the front), thumb."""
    H = BUILD_SCALES[build]["hand"]
    x, palm, fwd = hand_frame(j, side)
    back = -palm
    rot = np.stack([x, back, fwd])      # box axes: along, thickness, width
    wrist = j[f"wrist_{side}"]
    palm_c = wrist + x * 0.05 * H
    sh.round_box(palm_c, (0.056 * H, 0.025 * H, 0.052 * H), 0.02 * H, k=0.03, rot=rot, name=f"palm_{side}")
    lengths = (0.08, 0.092, 0.088, 0.07)          # index, middle, ring, little
    offsets = (0.036, 0.012, -0.012, -0.035)      # across the knuckles, index toward the front
    r0, r1 = 0.0155 * H, 0.013 * H
    for i in range(4):
        L = lengths[i] * H
        base = palm_c + x * 0.046 * H + fwd * offsets[i] * H
        if pose == "fist":
            # wrap around the handle: an arc about an axis across the knuckles
            radius = GRIP_RADIUS_M + r0
            centre = base + x * 0.008 + palm * radius
            sweep = min(L / radius, np.radians(250))
            pts = [base]
            for k in range(1, 5):
                a = sweep * k / 4
                pts.append(centre - palm * radius * np.cos(a) + x * radius * np.sin(a))
        else:
            a1, a2, a3 = (np.radians(b) for b in HAND_POSES[pose])
            pts, p, th = [base], base, 0.0
            for frac, bend in ((0.45, a1), (0.32, a2), (0.23, a3)):
                th += bend
                p = p + (x * np.cos(th) + palm * np.sin(th)) * L * frac
                pts.append(p)
        for k in range(len(pts) - 1):
            t0, t1 = k / (len(pts) - 1), (k + 1) / (len(pts) - 1)
            sh.round_cone(pts[k], pts[k + 1], r0 + (r1 - r0) * t0, r0 + (r1 - r0) * t1, k=0.006,
                          name=f"finger{i}_{side}")
    thumb_base = wrist + x * 0.022 * H + fwd * 0.042 * H + palm * 0.012 * H
    if pose == "fist":  # folded over the index and middle fingers
        tip = thumb_base + (x * 0.55 + palm * 0.75 - fwd * 0.35) * 0.08 * H
    else:
        tip = thumb_base + (x * 0.6 + fwd * 0.45 + palm * 0.35) * 0.08 * H
    mid = (thumb_base + tip) / 2 + fwd * 0.01 * H
    sh.round_cone(thumb_base, mid, 0.019 * H, 0.016 * H, k=0.015, name=f"thumb_{side}")
    sh.round_cone(mid, tip, 0.016 * H, 0.014 * H, k=0.008, name=f"thumb_{side}")


def body_shape(j: dict, build: str, hands: tuple[str, str] = ("relaxed", "fist")) -> sdf.Shape:
    """`hands`: pose of the left and right hand ("relaxed", "open" or "fist"). The right hand
    closes around a weapon's grip by default."""
    s = BUILD_SCALES[build]
    T, L, M, H, F, J = (s[k] for k in ("torso", "limb", "muscle", "hand", "foot", "jaw"))
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    sh = sdf.Shape()

    pelvis, spine, chest, chest_top = j["pelvis"], j["spine"], j["chest"], j["chest_top"]
    neck, head = j["neck"], j["head"]
    z = lambda p: float(p[2])  # noqa: E731

    # ---- torso (midline parts): rounded boxes read as a blocky, heroic male torso -----------
    sh.round_box(v(0, 0.012, z(pelvis) - 0.01), (0.17 * T, 0.118 * T, 0.11), 0.09, k=0.0, name="pelvis")
    sh.round_box(v(0, 0.004, z(spine) - 0.01), (0.172 * T, 0.122 * T, 0.13), 0.1, k=0.1, name="abdomen")
    sh.round_box(v(0, 0.022, z(chest) + 0.025), (0.215 * T, 0.145 * T, 0.165), 0.11, k=0.08, name="ribcage")
    sh.round_box(v(0, 0.03, z(chest_top) - 0.045), (0.265 * T, 0.13 * T, 0.085), 0.075, k=0.08, name="girdle")
    sh.round_cone(v(0, 0.022, z(chest_top) - 0.02), v(0, 0.0, z(head) + 0.03), 0.088 * T, 0.068 * T, k=0.06,
                  name="neck")

    # ---- left side (mirrored) ------------------------------------------------------------------
    # chest: flat, square plates high on the rib cage
    sh.round_box(v(0.092 * T, -0.108 * T, z(chest) + 0.07), (0.098 * T, 0.03 * M + 0.012, 0.068), 0.03,
                 k=0.05, rot=sdf.frame((1, 0.25, -0.3)), name="pec")
    sh.ellipsoid(v(0.175 * T, 0.05, z(chest) + 0.0), (0.07 * M + 0.012, 0.085 * T, 0.14), k=0.06,
                 rot=sdf.frame((0.35, 0, 1), up=(0, 1, 0)), name="lat")
    sh.round_cone(v(0.03, 0.04, z(chest_top) + 0.035), v(0.25 * T, 0.03, z(chest_top) - 0.02),
                  0.08 * T, 0.068 * T, k=0.07, name="trap")
    sh.ellipsoid(v(0.075 * T, 0.075 * T, z(pelvis) - 0.05), (0.085 * T, 0.072 * T, 0.095), k=0.05, name="glute")

    # arm: thick, heroic
    shoulder, elbow, wrist, hand_end = j["shoulder_l"], j["elbow_l"], j["wrist_l"], j["hand_end_l"]
    arm = elbow - shoulder
    fore = wrist - elbow
    sh.ellipsoid(shoulder + v(0.0, 0.0, 0.02), (0.088 * L, 0.098 * L, 0.084 * L), k=0.11,
                 rot=sdf.frame(arm + v(0, 0, 0.25)), name="deltoid")
    sh.round_cone(shoulder, elbow, 0.09 * L, 0.072 * L, k=0.05, name="upperarm")
    sh.ellipsoid(shoulder + arm * 0.5 + v(0, -0.03 * L, 0), (0.11, 0.06 * M + 0.01, 0.06 * M + 0.01), k=0.04,
                 rot=sdf.frame(arm), name="bicep")
    sh.ellipsoid(shoulder + arm * 0.4 + v(0, 0.034 * L, 0), (0.12, 0.055 * M + 0.01, 0.06 * M + 0.01), k=0.04,
                 rot=sdf.frame(arm), name="tricep")
    sh.round_cone(elbow, wrist, 0.078 * L, 0.057 * L, k=0.04, name="forearm")
    sh.ellipsoid(elbow + fore * 0.28 + v(0, -0.01, 0), (0.11, 0.07 * M + 0.012, 0.062 * M + 0.012), k=0.04,
                 rot=sdf.frame(fore), name="forearm_mass")
    # leg: thick thighs, strong calves
    hip, knee, ankle, toe = j["hip_l"], j["knee_l"], j["ankle_l"], j["toe_l"]
    thigh = knee - hip
    shin = ankle - knee
    sh.round_cone(hip + v(-0.015, 0.0, 0.0), knee, 0.105 * L, 0.07 * L, k=0.08, name="thigh")
    sh.ellipsoid(hip + thigh * 0.48 + v(0.0, -0.035 * L, 0), (0.16, 0.085 * M + 0.015, 0.08 * M + 0.015), k=0.05,
                 rot=sdf.frame(thigh), name="quad")
    sh.ellipsoid(hip + thigh * 0.45 + v(-0.035 * L, 0.012, 0), (0.15, 0.06 * M + 0.01, 0.06 * M + 0.01), k=0.05,
                 rot=sdf.frame(thigh), name="adductor")
    sh.sphere(knee + v(0, -0.014, 0), 0.075 * L, k=0.04, name="knee")
    sh.round_cone(knee, ankle + v(0, 0, 0.02), 0.07 * L, 0.048 * L, k=0.04, name="shin")
    sh.ellipsoid(knee + shin * 0.3 + v(0, 0.038 * L, 0), (0.13, 0.068 * M + 0.014, 0.07 * M + 0.014), k=0.045,
                 rot=sdf.frame(shin), name="calf")
    # foot: oversized, a tapered block from heel to toes, sole flattened by the floor clip
    heel = ankle + v(0, 0.035, -0.045)
    sh.round_cone(heel, toe, 0.06 * F, 0.05 * F, k=0.03, name="foot")
    sh.ellipsoid(ankle + v(0, -0.075 * F, -0.035), (0.06 * F, 0.09 * F, 0.045 * F), k=0.035, name="instep")

    # ---- head ----------------------------------------------------------------------------------
    hz0 = z(head)
    sh.ellipsoid(v(0, 0.014, hz0 + 0.145), (0.1, 0.116, 0.12), k=0.03, name="cranium")
    sh.round_box(v(0, -0.034, hz0 + 0.048), (0.07 * J + 0.005, 0.066, 0.055), 0.036, k=0.035, name="jaw")
    sh.ellipsoid(v(0, -0.088, hz0 + 0.02), (0.038 * J, 0.03, 0.032), k=0.022, name="chin")
    sh.ellipsoid(v(0.055, -0.072, hz0 + 0.108), (0.032, 0.028, 0.024), k=0.022, name="cheekbone")
    sh.round_cone(v(0.068, -0.086, hz0 + 0.148), v(0.0, -0.097, hz0 + 0.146), 0.02 * J + 0.005, 0.021 * J + 0.005,
                  k=0.022, name="brow")
    sh.sphere(v(0.036, -0.116, hz0 + 0.12), 0.019, k=0.02, subtract=True, name="eye_socket")
    sh.ellipsoid(v(0.036, -0.093, hz0 + 0.12), (0.014, 0.01, 0.009), k=0.005, name="eye")
    sh.round_cone(v(0.0, -0.106, hz0 + 0.135), v(0.0, -0.121, hz0 + 0.09), 0.009, 0.015, k=0.012, name="nose")
    sh.ellipsoid(v(0.0, -0.104, hz0 + 0.06), (0.03, 0.013, 0.01), k=0.012, name="lip")
    sh.ellipsoid(v(0.097, 0.01, hz0 + 0.108), (0.011, 0.022, 0.032), k=0.012, name="ear")
    out = sh.mirrored()
    # hands last and per side, so the two can differ (a fist on the weapon hand)
    _hand(out, j, "l", build, hands[0])
    _hand(out, j, "r", build, hands[1])
    return out


def body_mesh(j: dict, build: str, voxel: float = 0.005, hands: tuple[str, str] = ("relaxed", "fist")):
    """Closed triangle mesh (vertices, faces) of a body."""
    return sdf.extract(body_shape(j, build, hands), voxel=voxel, floor_z=0.0)
