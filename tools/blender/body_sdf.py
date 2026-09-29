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
}


def body_shape(j: dict, build: str) -> sdf.Shape:
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
    handd = hand_end - wrist
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
    # hand: oversized; palm towards the thigh; local x along the hand, z across the knuckles,
    # y through the palm
    hrot = sdf.frame(handd, up=(0, -1, 0))
    hx, hy, hz = hrot[0], hrot[1], hrot[2]
    palm_c = wrist + hx * 0.05 * H
    sh.round_box(palm_c, (0.056 * H, 0.025 * H, 0.052 * H), 0.02 * H, k=0.03, rot=hrot, name="palm")
    for i, off in enumerate((-0.036, -0.012, 0.012, 0.035)):
        length = (0.08, 0.092, 0.088, 0.07)[i] * H
        base = palm_c + hx * 0.046 * H + hz * off * H
        tip = base + (hx * 0.88 - hy * 0.4) * length  # fingers curl a little towards the palm
        sh.round_cone(base, tip, 0.0155 * H, 0.013 * H, k=0.008, name=f"finger{i}")
    thumb_base = wrist + hx * 0.022 * H - hz * 0.042 * H - hy * 0.012 * H
    sh.round_cone(thumb_base, thumb_base + (hx * 0.55 - hz * 0.5 - hy * 0.45) * 0.08 * H, 0.019 * H, 0.015 * H,
                  k=0.015, name="thumb")

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
    return sh.mirrored()


def body_mesh(j: dict, build: str, voxel: float = 0.005):
    """Closed triangle mesh (vertices, faces) of a body."""
    return sdf.extract(body_shape(j, build), voxel=voxel, floor_z=0.0)
