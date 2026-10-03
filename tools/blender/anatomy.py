"""Bodies for the graphics overhaul (backlog G-01): male and female, realistic-heroic.

A signed distance field on the standard skeleton's joints (humanoid.joints), like body_sdf.py,
but with the anatomy the new fidelity budget can show: clavicles, the neck's side muscles,
fan-shaped pectorals, abdominals and obliques, shoulder blades and the spine's groove, three-part
shoulders, biceps, triceps and forearm muscles, the thigh's teardrop and outer muscles, kneecaps,
two-headed calves, ankle bones and Achilles tendons. Proportions follow docs/DESIGN.md (changed
2026-10-03): about 7.5 heads, hands, feet and shoulders at most about 10% larger than realistic.

Only the character's left side (+X) is described; `sdf.Shape.mirrored` adds the right. Units are
metres; the character faces -Y. Every size is given for a 1.88 m male and scaled by the build's
height, then by the body type's factors in TYPES.
"""
from __future__ import annotations

import numpy as np

import body_sdf
import sdf

# Body type factors. muscle: muscle mass depth; torso: torso width; limb: limb radii;
# hand/foot: extremity size (the hand function's scale, also used for weapon grips); fem: 0 or 1
# for the female forms (breasts, wider pelvis, narrower waist, softer muscle definition).
TYPES = {
    "male": {"muscle": 1.0, "torso": 1.0, "limb": 1.0, "hand": 1.08, "foot": 1.05, "fem": 0.0, "neck": 1.0},
    "female": {"muscle": 0.55, "torso": 0.86, "limb": 0.84, "hand": 0.94, "foot": 0.95, "fem": 1.0, "neck": 0.82},
}
REF_HEIGHT = 1.88

# the hand and grip helpers in body_sdf look up their scale by build name
for _name, _t in TYPES.items():
    body_sdf.BUILD_SCALES.setdefault(_name, {"torso": _t["torso"], "limb": _t["limb"], "muscle": _t["muscle"],
                                             "hand": _t["hand"], "foot": _t["foot"], "jaw": 1.0})


def body_shape(j: dict, body_type: str, hands: tuple[str, str] = ("relaxed", "fist"),
               head: bool = True) -> sdf.Shape:
    t = TYPES[body_type]
    S = float(j["head_top"][2]) / REF_HEIGHT        # height scale
    M, T, L, F, fem = t["muscle"], t["torso"], t["limb"], t["foot"], t["fem"]
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    z = lambda p: float(p[2])  # noqa: E731
    sh = sdf.Shape()
    pelvis, spine, chest, chest_top = j["pelvis"], j["spine"], j["chest"], j["chest_top"]
    neck_j, head_j = j["neck"], j["head"]

    # ---- torso core (midline) ------------------------------------------------------------------
    # rib cage: an egg, widest just under the armpits, narrowing to the waist
    sh.ellipsoid(v(0, 0.012 * S, z(chest) + 0.02 * S), (0.158 * T * S, 0.118 * S, 0.19 * S), k=0.0, name="ribcage")
    # waist and belly: narrower for the female body
    waist = 0.128 - 0.016 * fem
    sh.ellipsoid(v(0, 0.004 * S, z(spine) - 0.005 * S), (waist * S, 0.098 * S, 0.15 * S), k=0.07 * S, name="abdomen")
    # pelvis: wider for the female body
    sh.round_box(v(0, 0.014 * S, z(pelvis) + 0.005 * S), ((0.148 + 0.012 * fem) * S, 0.102 * S, 0.085 * S),
                 0.075 * S, k=0.07 * S, name="pelvis")
    # upper back: the trapezius' diamond between the shoulder blades
    sh.ellipsoid(v(0, 0.07 * S, z(chest) + 0.08 * S), (0.1 * T * S, 0.045 * S, 0.14 * S), k=0.05 * S, name="upper_back")
    # neck
    nk = t["neck"]
    sh.round_cone(v(0, 0.012 * S, z(chest_top) - 0.01 * S), v(0, 0.004 * S, z(head_j) + 0.02 * S),
                  0.066 * nk * S, 0.056 * nk * S, k=0.045 * S, name="neck")
    # front of the torso: rectus abdominis as a long shallow plate; the male shows its segments
    sh.ellipsoid(v(0, -0.074 * S, z(spine) + 0.02 * S), (0.068 * S, 0.034 * S, 0.16 * S), k=0.03 * S, name="rectus")
    if fem < 0.5:
        for row, zz in enumerate((0.115, 0.04, -0.035)):
            sh.ellipsoid(v(0.033 * S, -0.098 * S + row * 0.002 * S, z(spine) + zz * S),
                         (0.03 * S, 0.009 * S * M, 0.031 * S), k=0.018 * S, name="abs")
    sh.sphere(v(0, -0.104 * S, z(pelvis) + 0.1 * S), 0.009 * S, k=0.008 * S, subtract=True, name="navel")
    # the spine's groove down the back
    sh.round_cone(v(0, 0.14 * S, z(chest_top) - 0.05 * S), v(0, 0.12 * S, z(pelvis) + 0.06 * S),
                  0.011 * S, 0.009 * S, k=0.025 * S, subtract=True, name="spine_groove")

    # ---- torso, left side ----------------------------------------------------------------------
    # clavicle: a shallow S from the notch to the shoulder
    sh.round_cone(v(0.022 * S, -0.058 * S, z(chest_top) + 0.002 * S), v(0.15 * T * S, -0.022 * S, z(chest_top) + 0.016 * S),
                  0.013 * S, 0.012 * S, k=0.018 * S, name="clavicle")
    # trapezius slope from the neck to the shoulder
    sh.round_cone(v(0.012 * S, 0.045 * S, z(head_j) + 0.0 * S), v(0.165 * T * S, 0.028 * S, z(chest_top) - 0.002 * S),
                  0.05 * S * (0.6 + 0.4 * M), 0.034 * S, k=0.05 * S, name="trap")
    # sternocleidomastoid: behind the ear to the collarbone notch
    sh.round_cone(v(0.052 * nk * S, 0.008 * S, z(head_j) + 0.03 * S), v(0.018 * S, -0.052 * S, z(chest_top) + 0.01 * S),
                  0.015 * S * nk, 0.012 * S * nk, k=0.03 * S, name="scm")
    # pectoral: a fan from the sternum to the armpit, its lower edge crisp
    pec_rot = sdf.frame((1.0, 0.22, 0.28))
    sh.ellipsoid(v(0.072 * T * S, -0.083 * S, z(chest) + 0.06 * S), (0.088 * T * S, (0.024 * M + 0.008) * S, 0.064 * S),
                 k=0.04 * S, rot=pec_rot, name="pec")
    if fem > 0.5:  # breasts: modest, stylized, sitting on the pectorals
        sh.ellipsoid(v(0.072 * S, -0.098 * S, z(chest) + 0.02 * S), (0.05 * S, 0.036 * S, 0.046 * S), k=0.05 * S,
                     rot=sdf.frame((1.0, 0.12, -0.15)), name="breast")
    # latissimus: the V from the armpit to the waist
    sh.ellipsoid(v(0.128 * T * S, 0.035 * S, z(chest) - 0.02 * S), (0.15 * S, (0.04 * M + 0.014) * S, 0.08 * S),
                 k=0.05 * S, rot=sdf.frame((0.28, 0.0, 1.0), up=(0, 1, 0)), name="lat")
    # serratus and obliques: a soft mass over the side of the waist and the hip bone
    sh.ellipsoid(v((0.108 - 0.02 * fem) * S, -0.01 * S, z(spine) - (0.035 + 0.02 * fem) * S),
                 ((0.045 - 0.015 * fem) * S, 0.08 * S, 0.11 * S), k=0.06 * S, name="oblique")
    # shoulder blade
    sh.ellipsoid(v(0.082 * T * S, 0.098 * S, z(chest) + 0.065 * S), (0.062 * S, 0.024 * S, 0.078 * S), k=0.035 * S,
                 rot=sdf.frame((1.0, 0.0, -0.25)), name="scapula")
    # glute: rounder and fuller for the female body
    sh.ellipsoid(v(0.072 * S, (0.072 + 0.006 * fem) * S, z(pelvis) - 0.045 * S),
                 ((0.082 + 0.012 * fem) * S, (0.066 + 0.01 * fem) * S, 0.098 * S), k=0.05 * S, name="glute")

    # ---- arm -----------------------------------------------------------------------------------
    shoulder, elbow, wrist = j["shoulder_l"], j["elbow_l"], j["wrist_l"]
    arm, fore = elbow - shoulder, wrist - elbow
    arm_rot, fore_rot = sdf.frame(arm), sdf.frame(fore)
    fwd = v(0, -1.0, 0)
    # deltoid: a cap over the shoulder, thicker at the front and side
    sh.ellipsoid(shoulder + v(0.012, -0.004, 0.008) * S + arm * 0.12, ((0.1 * L) * S, (0.062 * L + 0.008 * M) * S,
                 (0.06 * L + 0.008 * M) * S), k=0.045 * S, rot=sdf.frame(arm / np.linalg.norm(arm) + v(0, 0, 0.35)), name="deltoid")
    sh.round_cone(shoulder, elbow, 0.054 * L * S, 0.04 * L * S, k=0.04 * S, name="upperarm")
    sh.ellipsoid(shoulder + arm * 0.56 + fwd * 0.018 * S, (0.085 * S, (0.03 * M + 0.008) * L * S, (0.034 * M + 0.008) * L * S),
                 k=0.025 * S, rot=arm_rot, name="bicep")
    sh.ellipsoid(shoulder + arm * 0.42 - fwd * 0.022 * S, (0.1 * S, (0.026 * M + 0.008) * L * S, (0.032 * M + 0.008) * L * S),
                 k=0.025 * S, rot=arm_rot, name="tricep")
    sh.sphere(elbow - fwd * 0.012 * S, 0.03 * L * S, k=0.025 * S, name="elbow")
    sh.round_cone(elbow, wrist, 0.042 * L * S, 0.026 * L * S, k=0.03 * S, name="forearm")
    # brachioradialis and the flexors: the forearm's upper bulk, tapering to a slim wrist
    sh.ellipsoid(elbow + fore * 0.24 + fwd * 0.006 * S, (0.085 * S, (0.026 * M + 0.012) * L * S, (0.024 * M + 0.012) * L * S),
                 k=0.025 * S, rot=fore_rot, name="forearm_mass")
    # wrist: wider than deep
    sh.ellipsoid(wrist - fore / np.linalg.norm(fore) * 0.012 * S, (0.026 * S, 0.02 * L * S, 0.028 * L * S), k=0.02 * S,
                 rot=fore_rot, name="wrist")

    # ---- leg -----------------------------------------------------------------------------------
    hip, knee, ankle, toe = j["hip_l"], j["knee_l"], j["ankle_l"], j["toe_l"]
    thigh, shin = knee - hip, ankle - knee
    th_rot, sh_rot = sdf.frame(thigh), sdf.frame(shin)
    outward = v(1.0, 0, 0)
    sh.round_cone(hip + v(0.0, 0.0, 0.025) * S, knee, (0.082 + 0.008 * fem) * L * S, 0.048 * L * S, k=0.07 * S, name="thigh")
    sh.ellipsoid(hip + thigh * 0.45 + fwd * 0.028 * S, (0.16 * S, (0.034 * M + 0.02) * L * S, (0.036 * M + 0.02) * L * S),
                 k=0.04 * S, rot=th_rot, name="quad")
    sh.ellipsoid(hip + thigh * 0.5 + outward * 0.03 * S, (0.15 * S, (0.024 * M + 0.016) * L * S, (0.03 * M + 0.016) * L * S),
                 k=0.04 * S, rot=th_rot, name="vastus_lat")
    # the teardrop above the inner knee
    sh.ellipsoid(hip + thigh * 0.8 - outward * 0.026 * S + fwd * 0.016 * S,
                 (0.06 * S, (0.02 * M + 0.016) * L * S, (0.022 * M + 0.016) * L * S), k=0.025 * S, rot=th_rot, name="vastus_med")
    sh.ellipsoid(hip + thigh * 0.48 - fwd * 0.03 * S, (0.16 * S, (0.03 * M + 0.02) * L * S, (0.034 * M + 0.02) * L * S),
                 k=0.04 * S, rot=th_rot, name="hamstring")
    sh.ellipsoid(hip + thigh * 0.28 - outward * 0.04 * S, (0.13 * S, 0.035 * L * S, 0.04 * L * S),
                 k=0.04 * S, rot=th_rot, name="adductor")
    sh.sphere(knee + fwd * 0.03 * S + v(0, 0, 0.008) * S, 0.024 * L * S, k=0.018 * S, name="patella")
    sh.round_cone(knee, ankle + v(0, 0, 0.015) * S, 0.042 * L * S, 0.026 * L * S, k=0.03 * S, name="shin")
    # tibia: the hard front edge of the shin
    sh.round_cone(knee + fwd * 0.03 * S - v(0, 0, 0.04) * S, ankle + fwd * 0.018 * S + v(0, 0, 0.04) * S,
                  0.013 * S, 0.011 * S, k=0.02 * S, name="tibia")
    # calf: two heads high on the back of the shin, then the Achilles tendon to the heel
    for side_off, length in ((0.014, 0.1), (-0.013, 0.085)):
        sh.ellipsoid(knee + shin * 0.27 - fwd * 0.034 * S + outward * side_off * S,
                     (length * S, (0.024 * M + 0.014) * L * S, (0.022 * M + 0.012) * L * S), k=0.03 * S, rot=sh_rot, name="calf")
    heel = ankle + v(0, 0.038, -0.052) * S   # low enough that the floor flattens the sole
    sh.round_cone(knee + shin * 0.62 - fwd * 0.03 * S, heel + v(0, 0, 0.03) * S, 0.02 * S, 0.012 * S, k=0.02 * S,
                  name="achilles")
    sh.sphere(ankle + outward * 0.024 * S - v(0, 0, 0.004) * S, 0.017 * S, k=0.012 * S, name="malleolus_out")
    sh.sphere(ankle - outward * 0.022 * S + v(0, 0, 0.004) * S, 0.017 * S, k=0.012 * S, name="malleolus_in")
    # foot: heel, an arched block to the ball of the foot, then the toes
    ball = toe + v(0, 0.045, -0.002) * S
    sh.ellipsoid(heel, (0.034 * F * S, 0.042 * F * S, 0.036 * S), k=0.02 * S, name="heel")
    sh.round_cone(heel + v(0, -0.01, 0.01) * S, ball + v(0, 0, -0.01) * S, 0.034 * F * S, 0.03 * F * S, k=0.03 * S, name="foot")
    sh.ellipsoid(ankle + v(0, -0.06, -0.02) * S, (0.036 * F * S, 0.06 * F * S, 0.03 * S), k=0.03 * S, name="instep")
    sh.round_box(toe + v(-0.004, -0.008, -0.022) * S, (0.04 * F * S, 0.035 * F * S, 0.018 * S), 0.014 * S, k=0.02 * S,
                 name="toes")

    if head:
        add_head(sh, j, body_type)
    out = sh.mirrored()
    body_sdf._hand(out, j, "l", body_type, hands[0])
    body_sdf._hand(out, j, "r", body_type, hands[1])
    return out


def add_head(sh: sdf.Shape, j: dict, body_type: str, face: dict | None = None) -> None:
    """A neutral head (G-01); G-02 adds face presets on top of these proportions.

    `face` scales features: brow, jaw, cheek, nose, chin (1.0 = neutral)."""
    t = TYPES[body_type]
    fem = t["fem"]
    S = float(j["head_top"][2]) / REF_HEIGHT
    f = {"brow": 1.0, "jaw": 1.0, "cheek": 1.0, "nose": 1.0, "chin": 1.0, **(face or {})}
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    hz = float(j["head"][2]) - 0.012 * S   # the chin sits a little below the head joint: a shorter neck
    s = S * (0.97 if fem else 1.0)
    jaw = f["jaw"] * (0.86 if fem else 1.0)
    brow = f["brow"] * (0.6 if fem else 1.0)
    sh.ellipsoid(v(0, 0.016 * s, hz + 0.152 * s), (0.078 * s, 0.098 * s, 0.096 * s), k=0.0, name="cranium")
    sh.round_box(v(0, -0.036 * s, hz + 0.09 * s), (0.063 * s, 0.05 * s, 0.07 * s), 0.046 * s, k=0.06 * s, name="face")
    # jaw line from below the ear to the chin
    sh.round_cone(v(0.058 * jaw * s, -0.004 * s, hz + 0.08 * s), v(0.02 * s, -0.074 * s, hz + 0.018 * s),
                  0.02 * jaw * s, 0.016 * s, k=0.03 * s, name="jaw")
    sh.ellipsoid(v(0, -0.082 * s, hz + 0.018 * s), (0.022 * f["chin"] * jaw * s, 0.017 * s, 0.019 * f["chin"] * s), k=0.02 * s,
                 name="chin")
    sh.ellipsoid(v(0.05 * s, -0.066 * s, hz + 0.098 * s), (0.026 * s, 0.02 * f["cheek"] * s, 0.017 * s), k=0.022 * s,
                 name="cheekbone")
    sh.round_cone(v(0.052 * s, -0.082 * s, hz + 0.137 * s), v(0.006 * s, -0.09 * s, hz + 0.136 * s),
                  (0.006 + 0.007 * brow) * s, (0.006 + 0.007 * brow) * s, k=0.018 * s, name="brow")
    sh.ellipsoid(v(0.031 * s, -0.096 * s, hz + 0.119 * s), (0.016 * s, 0.012 * s, 0.01 * s), k=0.012 * s, subtract=True,
                 name="eye_socket")
    sh.sphere(v(0.031 * s, -0.076 * s, hz + 0.119 * s), 0.0125 * s, k=0.003 * s, name="eyeball")
    sh.ellipsoid(v(0.031 * s, -0.087 * s, hz + 0.124 * s), (0.016 * s, 0.007 * s, 0.006 * s), k=0.004 * s, name="eyelid")
    nose = f["nose"] * (0.85 if fem else 1.0)
    sh.round_cone(v(0, -0.092 * s, hz + 0.126 * s), v(0, (-0.092 - 0.02 * nose) * s, hz + 0.086 * s),
                  0.008 * s, 0.011 * nose * s, k=0.01 * s, name="nose_bridge")
    sh.sphere(v(0, (-0.093 - 0.021 * nose) * s, hz + 0.082 * s), 0.012 * nose * s, k=0.008 * s, name="nose_tip")
    sh.sphere(v(0.013 * s, -0.101 * s, hz + 0.078 * s), 0.0095 * nose * s, k=0.008 * s, name="nostril")
    lip = 1.15 if fem else 1.0
    sh.ellipsoid(v(0, -0.097 * s, hz + 0.058 * s), (0.021 * s, 0.009 * lip * s, 0.007 * lip * s), k=0.008 * s, name="lip_upper")
    sh.ellipsoid(v(0, -0.095 * s, hz + 0.046 * s), (0.018 * s, 0.009 * lip * s, 0.007 * lip * s), k=0.008 * s, name="lip_lower")
    ear_rot = sdf.frame((0.0, 0.25, 1.0), up=(0, 1, 0))
    sh.ellipsoid(v(0.076 * s, 0.01 * s, hz + 0.112 * s), (0.03 * s, 0.008 * s, 0.02 * s), k=0.01 * s, rot=ear_rot, name="ear")
    sh.ellipsoid(v(0.083 * s, 0.006 * s, hz + 0.114 * s), (0.018 * s, 0.005 * s, 0.011 * s), k=0.004 * s, rot=ear_rot,
                 subtract=True, name="ear_hollow")


def body_mesh(j: dict, body_type: str, voxel: float = 0.004, hands: tuple[str, str] = ("relaxed", "fist")):
    return sdf.extract(body_shape(j, body_type, hands), voxel=voxel, floor_z=0.0)
