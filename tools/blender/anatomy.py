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
               head: bool = True, face: str | dict | None = None) -> sdf.Shape:
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
        add_head(sh, j, body_type, face)
    out = sh.mirrored()
    body_sdf._hand(out, j, "l", body_type, hands[0])
    body_sdf._hand(out, j, "r", body_type, hands[1])
    return out


FACE_KEYS = ("brow", "jaw", "cheek", "nose", "bridge", "chin", "lips", "hollow", "eyes")


def face_params(face: str | dict | None) -> dict:
    """A face preset's feature factors (data/appearance/faces.json), or the factors themselves."""
    f = {k: 1.0 for k in FACE_KEYS}
    f["hollow"] = 0.0
    if isinstance(face, dict):
        f.update(face)
    elif face:
        import json
        from pathlib import Path
        data = json.loads((Path(__file__).resolve().parents[2] / "data" / "appearance" / "faces.json").read_text())
        opt = next((o for o in data["options"] if o["id"] == face), None)
        if opt is None:
            raise KeyError(f"unknown face preset {face}")
        f.update(opt.get("params", {}))
    return f


def add_head(sh: sdf.Shape, j: dict, body_type: str, face: str | dict | None = None) -> None:
    """The head (G-02): skull, brow, cheekbones, jaw and chin, eyes with lids, nose with nostrils,
    lips and ears, shaped by a face preset (`face_params`). Left side only (mirrored later).

    Landmarks for a 1.88 m male, from the chin up: mouth 0.05 m, nose base 0.076, eyes 0.12 (half
    the head), brow 0.138, crown 0.245. Front is -y; the face's front plane is about y = -0.095."""
    t = TYPES[body_type]
    fem = t["fem"]
    S = float(j["head_top"][2]) / REF_HEIGHT
    f = face_params(face)
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    s = S * (0.96 if fem else 1.0)
    hz = float(j["head"][2]) - 0.012 * S   # chin a little below the head joint: a shorter neck
    P = lambda x, y, zz: v(x * s, y * s, hz + zz * s)  # noqa: E731
    jaw = f["jaw"] * (0.8 if fem else 1.0)
    brow = f["brow"] * (0.45 if fem else 1.0)
    nose = f["nose"] * (0.8 if fem else 1.0)
    lips = f["lips"] * (1.18 if fem else 1.0)
    eyes = f["eyes"] * (1.1 if fem else 1.0)
    chin = f["chin"] * (0.82 if fem else 1.0)
    face_len = 0.94 if fem else 1.0   # the female face is shorter below the eyes
    # skull: the cranium and a fuller forehead
    sh.ellipsoid(P(0, 0.02, 0.149), (0.075 * s, 0.097 * s, 0.088 * s), k=0.0, name="cranium")
    sh.ellipsoid(P(0, -0.035 - 0.004 * fem, 0.16), (0.064 * s, (0.062 + 0.004 * fem) * s, 0.07 * s), k=0.03 * s, name="forehead")
    # mid face (upper jaw) and lower face
    sh.round_box(P(0, -0.048, 0.088), ((0.05 - 0.005 * fem) * s, 0.045 * s, 0.042 * s), 0.034 * s, k=0.04 * s, name="midface")
    fl = (1.0 - face_len) * 0.08   # lower-face landmarks move up on a shorter face (0 for the male)
    sh.round_box(P(0, -0.036, 0.04 + fl * 0.5), (0.044 * jaw * s, 0.046 * s, 0.03 * s * face_len), 0.027 * s, k=0.035 * s,
                 name="lowerface")
    # jaw: from below the ear down to its angle, then forward to the chin
    angle = P((0.057 - 0.006 * fem) * jaw, -0.006, 0.034 + fl * 0.6 + 0.008 * fem)   # a higher, softer angle on the female jaw
    sh.round_cone(P(0.06, 0.004, 0.088), angle, 0.015 * s, 0.017 * jaw * s, k=0.028 * s, name="ramus")
    sh.round_cone(angle, P(0.017 * chin, -0.079, 0.012 + fl), 0.017 * jaw * s, 0.015 * s, k=0.028 * s, name="jawline")
    sh.ellipsoid(P(0, -0.083, 0.016 + fl), (0.022 * chin * s, 0.016 * s, 0.018 * chin * s), k=0.016 * s, name="chin")
    # masseter and temple: fill the side of the face between the cheekbone and the ear
    sh.ellipsoid(P(0.054 * jaw, -0.022, 0.066), (0.014 * s, 0.03 * s, 0.032 * s), k=0.024 * s, name="masseter")
    sh.ellipsoid(P(0.062, -0.03, 0.14), (0.014 * s, 0.03 * s, 0.03 * s), k=0.03 * s, name="temple")
    # cheekbones and the arch back to the ear
    ck = f["cheek"]
    sh.ellipsoid(P(0.049, -0.062 - 0.004 * fem, 0.101 + 0.003 * fem), ((0.024 + 0.002 * fem) * s, (0.02 + 0.003 * fem) * ck * s, 0.015 * s), k=0.024 * s,
                 name="cheekbone")
    sh.round_cone(P(0.052, -0.05, 0.102), P(0.07, -0.002, 0.106), 0.011 * ck * s, 0.009 * s, k=0.02 * s,
                  name="zygomatic")
    # soft cheeks under the cheekbones (fuller on the female face; a gaunt preset takes them away)
    full = max(0.0, (0.6 + 0.4 * fem) - f["hollow"])
    if full > 0:
        sh.ellipsoid(P(0.045, -0.058, 0.074), (0.022 * s, 0.02 * full * s, 0.025 * s), k=0.03 * s, name="cheek_fill")
    if f["hollow"] > 0:  # hollows under the cheekbones
        hw = f["hollow"]
        sh.ellipsoid(P(0.05, -0.064, 0.07), (0.02 * s, 0.009 * hw * s, 0.02 * s), k=0.022 * s, subtract=True,
                     name="cheek_hollow")
    # cheek fat beside the mouth (the nasolabial fold's outer side)
    sh.ellipsoid(P(0.03, -0.078, 0.07), (0.017 * s, 0.012 * s, 0.02 * s), k=0.018 * s, name="cheek_pad")
    # brow ridge
    sh.round_cone(P(0.051, -0.087, 0.138), P(0.008, -0.096, 0.137), (0.005 + 0.0045 * brow) * s,
                  (0.005 + 0.005 * brow) * s, k=0.015 * s, name="brow")
    # eyes: socket, eyeball, lids
    e = eyes
    sh.ellipsoid(P(0.031, -0.104, 0.121), (0.019 * e * s, 0.017 * s, 0.013 * e * s), k=0.01 * s, subtract=True,
                 name="eye_socket")
    sh.sphere(P(0.031, -0.082, 0.12), 0.0122 * s, k=0.002 * s, name="eyeball")
    sh.ellipsoid(P(0.031, -0.0852, 0.1285), (0.0138 * e * s, 0.0102 * s, 0.0058 * e * s), k=0.003 * s,
                 name="eyelid_upper")
    sh.ellipsoid(P(0.031, -0.0868, 0.1125), (0.0125 * e * s, 0.008 * s, 0.0038 * e * s), k=0.003 * s,
                 name="eyelid_lower")
    # nose: bridge, tip, wings and nostrils
    b = f["bridge"]
    sh.round_cone(P(0, -0.097, 0.13), P(0, -0.097 - 0.019 * nose, 0.086), 0.0065 * b * s, 0.0098 * nose * s,
                  k=0.012 * s, name="nose_bridge")
    sh.sphere(P(0, -0.0975 - 0.0205 * nose, 0.081), 0.0112 * nose * s, k=0.008 * s, name="nose_tip")
    sh.sphere(P(0.0122 * nose, -0.105 - 0.004 * nose, 0.077), 0.0084 * nose * s, k=0.007 * s, name="nose_wing")
    sh.sphere(P(0.0068 * nose, -0.111 - 0.006 * nose, 0.0718), 0.0028 * nose * s, k=0.002 * s, subtract=True,
              name="nostril")
    # mouth: lips and the line between them
    sh.ellipsoid(P(0, -0.097, 0.058 + fl * 0.4), (0.024 * s, 0.011 * lips * s, 0.0085 * lips * s), k=0.01 * s, name="lip_upper")
    sh.ellipsoid(P(0, -0.0955, 0.0455 + fl * 0.45), (0.02 * s, 0.0105 * lips * s, 0.0072 * lips * s), k=0.008 * s,
                 name="lip_lower")
    sh.round_cone(P(-0.021, -0.104, 0.0515 + fl * 0.42), P(0.021, -0.104, 0.0515 + fl * 0.42), 0.0016 * s, 0.0016 * s, k=0.002 * s,
                  subtract=True, name="mouth_line")
    # ears: a flattened disc with a hollow, tipped back
    ear_rot = sdf.frame((0.0, 0.25, 1.0), up=(0, 1, 0))
    sh.ellipsoid(P(0.075, 0.012, 0.108), (0.03 * s, 0.008 * s, 0.019 * s), k=0.008 * s, rot=ear_rot, name="ear")
    sh.ellipsoid(P(0.081, 0.009, 0.11), (0.019 * s, 0.005 * s, 0.011 * s), k=0.004 * s, rot=ear_rot, subtract=True,
                 name="ear_hollow")


def body_mesh(j: dict, body_type: str, voxel: float = 0.004, hands: tuple[str, str] = ("relaxed", "fist")):
    return sdf.extract(body_shape(j, body_type, hands), voxel=voxel, floor_z=0.0)


def head_subset(shape: sdf.Shape, j: dict) -> sdf.Shape:
    """The primitives that can reach the head and neck (faster to evaluate than the whole body)."""
    cut = float(j["chest_top"][2]) - 0.05
    return sdf.Shape([p for p in shape.prims if p.hi[2] > cut and abs((p.lo[0] + p.hi[0]) / 2) < 0.22])


def project_points(shape: sdf.Shape, P: np.ndarray, iters: int = 6, eps: float = 5e-4) -> np.ndarray:
    """Move points onto a shape's surface along its gradient (vectorised Newton steps)."""
    P = np.array(P, float)
    for _ in range(iters):
        d = sdf.eval_points(shape, P)
        g = np.stack([(sdf.eval_points(shape, P + e) - sdf.eval_points(shape, P - e)) / (2 * eps)
                      for e in np.eye(3) * eps], axis=1)
        g /= np.maximum(np.linalg.norm(g, axis=1, keepdims=True), 1e-9)
        P = P - g * d[:, None]
    return P


def face_offsets(j: dict, body_type: str, face: str, P: np.ndarray, neck_z: float) -> np.ndarray:
    """Where the neutral head's surface points `P` move for face preset `face` (a shape key).
    Points below the jaw fade to no movement over 3 cm above `neck_z`, so the neck never moves."""
    neutral = head_subset(body_shape(j, body_type), j)
    preset = head_subset(body_shape(j, body_type, face=face), j)
    w = np.clip((P[:, 2] - neck_z) / 0.03, 0.0, 1.0)
    moved = P.copy()
    sel = w > 0
    if sel.any():
        # only points the preset changes: skip those where both fields agree
        near = np.abs(sdf.eval_points(preset, P[sel]) - sdf.eval_points(neutral, P[sel])) > 1e-5
        idx = np.flatnonzero(sel)[near]
        if len(idx):
            moved[idx] = project_points(preset, P[idx])
    return (moved - P) * w[:, None]


def head_frame(j: dict, body_type: str) -> tuple[float, float]:
    """(chin height, head scale) used by add_head: head landmarks are hz + z * s."""
    S = float(j["head_top"][2]) / REF_HEIGHT
    s = S * (0.96 if TYPES[body_type]["fem"] else 1.0)
    return float(j["head"][2]) - 0.012 * S, s
