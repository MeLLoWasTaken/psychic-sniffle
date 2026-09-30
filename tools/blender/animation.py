"""Scripted animation from pose data (backlog M1-21).

Clips live in data/animations/<set>.json as a few key poses each. A pose names joints in plain
terms ("thigh_l": {"swing": 40}) instead of raw bone axes; this module turns those terms into
bone rotations for the standard skeleton, fills the frames between keys with eased curves, and
adds follow-through (extremities trail their parents by a few frames).

Two layers:
- pure evaluation (`sample_clip`): term values per frame, no Blender needed;
- Blender application (`pose_rig`, `bake_clip`): turns term values into pose-bone rotations and
  root translation on an armature built by humanoid.build_armature.

Axis conventions (measured on the standard skeleton, checked by `check_axes`):
character faces -Y, up is +Z, its left is +X. Each term is a rotation about an axis given for
the left side, either in world space (the rest pose) or in the bone's local space. The right
side mirrors the left: an axis (x, y, z) becomes (x, -y, -z), which holds for world axes and for
the skeleton's local bone axes (bone rolls are mirror images).
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]

# ----------------------------------------------------------------------------- term table
# family -> term -> (space, axis for the left side). Positive angles as documented in the
# animation set's description.
TORSO = {
    "bend": ("world", (1, 0, 0)),     # + forward
    "twist": ("world", (0, 0, 1)),    # + turns toward the character's left
    "lean": ("world", (0, -1, 0)),    # + toward the character's right
    "tilt": ("world", (0, -1, 0)),    # head: + toward the character's right (same as lean)
}
FAMILIES = {
    "pelvis": TORSO, "spine": TORSO, "chest": TORSO, "neck": TORSO, "head": TORSO,
    "clavicle": {"raise": ("local", (1, 0, 0)), "swing": ("local", (0, 0, -1))},
    "upperarm": {"swing": ("local", (-1, 0, 0)), "raise": ("local", (0, 0, -1))},
    "forearm": {"bend": ("local", (-1, 0, 0))},
    "hand": {"curl": ("world", (0, 1, 0)), "cock": ("world", (-1, 0, 0))},
    "thigh": {"swing": ("world", (-1, 0, 0)), "spread": ("world", (0, -1, 0))},
    "calf": {"bend": ("local", (1, 0, 0))},
    "foot": {"point": ("local", (1, 0, 0))},
}
# Terms are applied in this order (first listed is applied last, i.e. outermost).
TERM_ORDER = ["bend", "swing", "cock", "curl", "point", "raise", "spread", "lean", "tilt", "twist"]
ROOT_TERMS = ("up", "forward", "left", "pitch")

# Clip names every humanoid set must have (docs/DESIGN.md, asset pipeline; docs/ART_BIBLE.md,
# animation clip names). cast_release is the default; schools with their own release add
# cast_release_<school>.
REQUIRED_CLIPS = [
    "idle", "combat_idle", "run", "strafe_left", "strafe_right", "backpedal", "jump",
    "cast_start", "cast_loop", "cast_release", "channel", "attack_1", "attack_2", "attack_3",
    "ranged_shot", "hit", "stunned", "feared_run", "death", "victory",
]


def family(bone: str) -> str:
    return bone[:-2] if bone.endswith(("_l", "_r")) else bone


def side(bone: str) -> str:
    return bone[-1] if bone.endswith(("_l", "_r")) else ""


def term_axis(bone: str, term: str) -> tuple[str, tuple[float, float, float]]:
    fam = FAMILIES.get(family(bone))
    if fam is None or term not in fam:
        raise KeyError(f"unknown term {term!r} for bone {bone!r}")
    space, (x, y, z) = fam[term]
    if side(bone) == "r":
        y, z = -y, -z
    return space, (float(x), float(y), float(z))


# ----------------------------------------------------------------------------- data

def load_set(set_id: str = "humanoid") -> dict:
    return json.loads((REPO / "data" / "animations" / f"{set_id}.json").read_text())


def validate_set(anim: dict) -> list[str]:
    """Problems with an animation set that the JSON schema cannot see (unknown terms, key
    order, keys past the clip end)."""
    errors = []
    for name, clip in anim["clips"].items():
        times = [k["t"] for k in clip["keys"]]
        if times != sorted(times) or len(set(times)) != len(times):
            errors.append(f"{name}: key times must strictly increase")
        if times and (times[0] != 0.0 or times[-1] > clip["length_s"] + 1e-9):
            errors.append(f"{name}: keys must start at 0 and end by length_s")
        frames = clip["length_s"] * anim["fps"]
        if abs(frames - round(frames)) > 0.01:
            errors.append(f"{name}: length_s {clip['length_s']} is not a whole number of frames at {anim['fps']} fps")
        for k in clip["keys"]:
            for bone, terms in k["pose"].items():
                for term in terms:
                    if bone == "root":
                        if term not in ROOT_TERMS:
                            errors.append(f"{name}: unknown root term {term!r}")
                        continue
                    try:
                        term_axis(bone, term)
                    except KeyError as e:
                        errors.append(f"{name}: {e.args[0]}")
    for hold, h in anim.get("weapon_grip", {}).get("holds", {}).items():
        for name in h.get("second_hand", {}).get("clips", []):
            if name not in anim["clips"]:
                errors.append(f"weapon_grip.holds.{hold}.second_hand: unknown clip {name!r}")
    for build, clips in anim.get("build_offsets", {}).items():
        for name, pose in clips.items():
            if name not in anim["clips"]:
                errors.append(f"build_offsets.{build}: unknown clip {name!r}")
            for bone, terms in pose.items():
                for term in terms:
                    try:
                        term_axis(bone, term)
                    except KeyError as e:
                        errors.append(f"build_offsets.{build}.{name}: {e.args[0]}")
    return errors


# ----------------------------------------------------------------------------- curves

def _monotone_slopes(t: np.ndarray, v: np.ndarray, periodic: bool) -> np.ndarray:
    """Fritsch-Carlson slopes: a smooth curve through every key that never overshoots, so a
    pose held at an extreme eases in and out instead of wobbling past it."""
    n = len(t)
    if n < 2:
        return np.zeros(n)
    d = np.diff(v) / np.diff(t)
    m = np.zeros(n)
    for i in range(n):
        if i == 0 or i == n - 1:
            if periodic:
                a, b = d[-1], d[0]
            else:
                m[i] = 0.0  # clips that do not loop start and end at rest velocity
                continue
        else:
            a, b = d[i - 1], d[i]
        m[i] = 0.0 if a * b <= 0 else 2.0 / (1.0 / a + 1.0 / b)
    return m


_EASE = {
    "linear": lambda u: u,
    "in": lambda u: u * u * u,              # accelerate into the key (strike contact)
    "out": lambda u: 1 - (1 - u) ** 3,      # snap out of the previous key, settle into this one
}


def channel_curve(times: list[float], values: list[float], eases: list[str], length: float, loop: bool):
    """Returns f(t) for one channel. `eases[i]` shapes the segment that ends at key i."""
    t = list(times)
    v = list(values)
    e = list(eases)
    if loop:  # close the loop: the first key repeats at the clip end
        t.append(length)
        v.append(v[0])
        e.append(e[0])
    elif t[-1] < length:
        t.append(length)
        v.append(v[-1])
        e.append("smooth")
    ta, va = np.array(t, float), np.array(v, float)
    m = _monotone_slopes(ta, va, loop)

    def f(x: float) -> float:
        if loop:
            x = x % length
        x = min(max(x, ta[0]), ta[-1])
        i = int(np.searchsorted(ta, x, side="right") - 1)
        i = min(i, len(ta) - 2)
        h = ta[i + 1] - ta[i]
        u = (x - ta[i]) / h
        ease = e[i + 1]
        if ease in _EASE:
            return float(va[i] + (va[i + 1] - va[i]) * _EASE[ease](u))
        # cubic Hermite
        h00 = 2 * u**3 - 3 * u**2 + 1
        h10 = u**3 - 2 * u**2 + u
        h01 = -2 * u**3 + 3 * u**2
        h11 = u**3 - u**2
        return float(h00 * va[i] + h10 * h * m[i] + h01 * va[i + 1] + h11 * h * m[i + 1])

    return f


def clip_channels(clip: dict) -> dict[tuple[str, str], object]:
    """(bone, term) -> curve for every channel the clip animates."""
    keys = clip["keys"]
    names = sorted({(b, term) for k in keys for b, terms in k["pose"].items() for term in terms})
    times = [k["t"] for k in keys]
    eases = [k.get("ease", "smooth") for k in keys]
    out = {}
    for bone, term in names:
        values = [float(k["pose"].get(bone, {}).get(term, 0.0)) for k in keys]
        out[(bone, term)] = channel_curve(times, values, eases, clip["length_s"], clip["loop"])
    return out


def frame_count(clip: dict, fps: int) -> int:
    """Frames in the clip, counting both ends (a loop's last frame equals its first)."""
    return int(round(clip["length_s"] * fps)) + 1


def hold_variants(anim: dict) -> list[str]:
    """Weapon holds with a rule (a wrist aim or a second hand) that need their own baked copy of
    every clip."""
    return [h for h, d in anim.get("weapon_grip", {}).get("holds", {}).items()
            if d.get("wrist") or d.get("second_hand")]


def wrist_rule(anim: dict, hold: str | None, clip: str | None = None, build: str | None = None) -> dict | None:
    """The hand rules of a hold for one clip: "aim" (wrist aim, see _aim_wrist) and "second"
    (the other hand on the handle, for the clips the hold lists; see _second_hand)."""
    if not hold:
        return None
    grip = anim["weapon_grip"]
    h = grip["holds"][hold]
    rules: dict = {}
    if h.get("wrist"):
        rules.update(h["wrist"], bone=grip["bone"], blade=h["blade"])
    second = h.get("second_hand")
    if second and clip in second.get("clips", []) and build:
        rules["second"] = dict(second, grip=grip, hold=hold, build=build)
    return rules or None


def fist_point(rig, grip: dict, bone_name: str, build: str):
    """Rest-pose centre of a fist (where a handle passes) and the hand's along and palm axes."""
    from mathutils import Vector

    bone = rig.data.bones[bone_name]
    head = bone.head_local
    along = (bone.tail_local - head).normalized()
    inward = Vector((1.0, 0.0, 0.0)) if bone_name.endswith("_r") else Vector((-1.0, 0.0, 0.0))
    palm = (inward - along * along.dot(inward)).normalized()
    return head + along * grip["along_m"][build] + palm * grip["palm_m"][build], along, palm


def grip_rest(rig, grip: dict, hold: str, build: str):
    """Rest-pose world matrix of a held weapon: the blade (+Z) and flat (+Y) along the hold's
    directions; the weapon's origin (its grip centre) at the fist, slid slide_m down the handle
    for two-handed holds so the first hand sits near the guard."""
    from mathutils import Matrix, Vector

    point, _along, _palm = fist_point(rig, grip, grip["bone"], build)
    h = grip["holds"][hold]
    z = Vector(h["blade"]).normalized()
    y = Vector(h["flat"])
    y = (y - z * z.dot(y)).normalized()
    x = y.cross(z)
    m = Matrix((x, y, z)).transposed().to_4x4()
    m.translation = point - z * h.get("slide_m", 0.0)
    return m


def variant_name(clip: str, hold: str | None) -> str:
    return f"{clip}_{hold}" if hold else clip


def sample_clip(anim: dict, clip_name: str, build: str | None = None) -> list[dict[str, dict[str, float]]]:
    """Pose (bone -> term -> degrees or metres) for every frame, with follow-through applied.
    `build` adds that body build's offsets for this clip (build_offsets in the set), e.g. arms
    hanging closer on the slim build than plate allows on the heavy one."""
    clip = anim["clips"][clip_name]
    fps = anim["fps"]
    lag = anim.get("overlap_s", {})
    curves = clip_channels(clip)
    frames = []
    for fi in range(frame_count(clip, fps)):
        t = fi / fps
        pose: dict[str, dict[str, float]] = {}
        for (bone, term), f in curves.items():
            delay = 0.0 if bone == "root" else lag.get(family(bone), 0.0)
            pose.setdefault(bone, {})[term] = f(t - delay if clip["loop"] else max(0.0, t - delay))
        for bone, terms in anim.get("build_offsets", {}).get(build or "", {}).get(clip_name, {}).items():
            for term, value in terms.items():
                pose.setdefault(bone, {})[term] = pose.get(bone, {}).get(term, 0.0) + value
        _auto_shrug(pose, anim.get("auto_shrug", 0.0))
        frames.append(pose)
    return frames


def _auto_shrug(pose: dict, gain: float) -> None:
    """Raise the clavicles as an arm lifts high, so overhead swings do not pinch the shoulder."""
    if gain <= 0:
        return
    for s in ("l", "r"):
        arm = pose.get(f"upperarm_{s}", {})
        lift = max(0.0, arm.get("swing", 0.0) - 50.0) + max(0.0, arm.get("raise", 0.0) - 25.0)
        if lift > 0:
            c = pose.setdefault(f"clavicle_{s}", {})
            c["raise"] = c.get("raise", 0.0) + gain * lift


def key_frames(anim: dict, clip_name: str) -> list[int]:
    fps = anim["fps"]
    return [int(round(k["t"] * fps)) for k in anim["clips"][clip_name]["keys"]]


# ----------------------------------------------------------------------------- Blender side

def bone_quaternion(rig, bone: str, terms: dict[str, float]):
    """Pose rotation (bone-local quaternion) for a bone's term values in degrees."""
    from mathutils import Quaternion, Vector

    rest = rig.data.bones[bone].matrix_local.to_3x3()
    rest_inv = rest.transposed()
    q = Quaternion()
    for term in TERM_ORDER:  # outermost first
        if term not in terms:
            continue
        space, axis = term_axis(bone, term)
        a = Vector(axis)
        if space == "world":
            a = rest_inv @ a
        q = q @ Quaternion(a.normalized(), math.radians(terms[term]))
    return q


def root_transform(rig, terms: dict[str, float]):
    """Root bone (location in its rest frame, rotation). Pitch pivots about the pelvis."""
    from mathutils import Matrix, Quaternion, Vector

    rest = rig.data.bones["root"].matrix_local.to_3x3()
    pitch = math.radians(terms.get("pitch", 0.0))
    rot_world = Matrix.Rotation(-pitch, 3, "X")  # + tips backward
    pelvis = rig.data.bones["pelvis"].head_local
    w = Vector((terms.get("left", 0.0), -terms.get("forward", 0.0), terms.get("up", 0.0)))
    w += pelvis - rot_world @ pelvis
    loc = rest.transposed() @ w
    q_local = (rest.transposed() @ rot_world @ rest).to_quaternion()
    return loc, q_local


def pose_rig(rig, pose: dict[str, dict[str, float]], wrist: dict | None = None) -> None:
    """Set a pose (unlisted bones go back to rest). `wrist` (see wrist_rule) then turns the grip
    hand so the held weapon points along `aim` in the character's frame."""
    from mathutils import Quaternion, Vector

    for pb in rig.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.location = Vector()
        pb.rotation_quaternion = Quaternion()
    for bone, terms in pose.items():
        if bone == "root":
            loc, q = root_transform(rig, terms)
            rig.pose.bones["root"].location = loc
            rig.pose.bones["root"].rotation_quaternion = q
        else:
            rig.pose.bones[bone].rotation_quaternion = bone_quaternion(rig, bone, terms)
    if wrist:
        if "aim" in wrist:
            _aim_wrist(rig, wrist)
        if "second" in wrist:
            _second_hand(rig, wrist["second"])


def _basis(a, b):
    """Orthonormal rotation matrix whose columns are a, b (made perpendicular to a) and a x b."""
    from mathutils import Matrix

    a = a.normalized()
    b = (b - a * a.dot(b)).normalized()
    return Matrix((a, b, a.cross(b))).transposed()


def _turn_bone(pb, pivot, from_dir, to_dir) -> None:
    import bpy
    from mathutils import Matrix

    q = from_dir.rotation_difference(to_dir)
    pb.matrix = Matrix.Translation(pivot) @ q.to_matrix().to_4x4() @ Matrix.Translation(-pivot) @ pb.matrix
    bpy.context.view_layer.update()


SECOND_HAND_SHORTFALL: dict = {}   # clip bake diagnostics: worst distance the hand fell short (m)


def _reach(rig, hand_name: str, wrist_target, hand_turn) -> float:
    """Two-bone reach: turn the upper arm and forearm so the wrist lands on wrist_target (or as
    close as the arm allows), keeping the animated elbow's side; then set the hand's world
    rotation to hand_turn (applied to its rest orientation). Returns how far it fell short (m)."""
    import bpy
    from mathutils import Vector

    hand = rig.pose.bones[hand_name]
    upper, fore = hand.parent.parent, hand.parent
    a, b = upper.bone.length, fore.bone.length
    shoulder = upper.head.copy()
    to = wrist_target - shoulder
    d = to.length
    reach = min(max(d, abs(a - b) + 1e-3), a + b - 1e-4)
    u = to.normalized()
    side = upper.tail - shoulder
    side = side - u * side.dot(u)
    if side.length < 1e-4:
        side = Vector((0, 0, -1)) - u * u.z
    side.normalize()
    cos_a = (a * a + reach * reach - b * b) / (2 * a * reach)
    elbow = shoulder + u * a * cos_a + side * a * math.sqrt(max(0.0, 1 - cos_a * cos_a))
    wrist = shoulder + u * reach
    _turn_bone(upper, shoulder, (upper.tail - upper.head).normalized(), (elbow - shoulder).normalized())
    _turn_bone(fore, fore.head.copy(), (fore.tail - fore.head).normalized(), (wrist - fore.head).normalized())
    m = (hand_turn @ hand.bone.matrix_local.to_3x3()).to_4x4()
    m.translation = hand.head.copy()
    hand.matrix = m
    bpy.context.view_layer.update()
    return max(0.0, d - reach)


def _second_hand(rig, s: dict) -> None:
    """Both hands on a two-handed weapon. The blade keeps its animated direction; the handle
    moves toward the body's midline (and toward the chest while a fist is out of reach), the
    first hand is re-reached onto it with its animated rotation, and the second fist closes
    below_m further down the handle, palm facing the first hand's palm, thumb toward the blade."""
    import bpy
    from mathutils import Vector

    bpy.context.view_layer.update()
    grip, hold, build = s["grip"], s["hold"], s["build"]
    h = grip["holds"][hold]
    first = rig.pose.bones[grip["bone"]]
    second = rig.pose.bones[s["bone"]]
    turn_first = first.matrix.to_3x3() @ first.bone.matrix_local.to_3x3().inverted()
    weapon = first.matrix @ first.bone.matrix_local.inverted() @ grip_rest(rig, grip, hold, build)
    blade = (weapon.to_3x3() @ Vector((0, 0, 1))).normalized()
    fist1, _a1, palm1 = fist_point(rig, grip, grip["bone"], build)
    fist2, along2, palm2 = fist_point(rig, grip, s["bone"], build)
    fist_first = weapon.translation + blade * h.get("slide_m", 0.0)
    fist_second = fist_first - blade * s["below_m"]
    palm_first = turn_first @ palm1
    fwd2 = palm2.cross(along2) if s["bone"].endswith("_l") else along2.cross(palm2)
    if fwd2.y > 0:
        fwd2 = -fwd2
    turn_second = _basis(blade, -palm_first) @ _basis(fwd2.normalized(), palm2).inverted()
    off1 = turn_first @ (fist1 - first.bone.head_local)       # wrist to fist centre, posed
    off2 = turn_second @ (fist2 - second.bone.head_local)
    # move the handle: toward the midline and at least min_forward_m in front of the body (plate
    # is deep); while a wrist is out of reach, raise it toward shoulder height rather than
    # pulling it back into the chest
    root = rig.pose.bones["root"]
    root_rot = root.matrix.to_3x3() @ root.bone.matrix_local.to_3x3().inverted()
    left_axis = root_rot @ Vector((1, 0, 0))
    fwd_axis = root_rot @ Vector((0, -1, 0))
    up_axis = root_rot @ Vector((0, 0, 1))
    mid = (fist_first + fist_second) / 2
    rel = mid - root.head
    lateral = rel.dot(left_axis) * (1.0 - s.get("centre", 0.8))
    s1, s2 = first.parent.parent, second.parent.parent
    shoulder_h = ((s1.head + s2.head) / 2 - root.head).dot(up_axis)
    height = rel.dot(up_axis)
    # the forward clearance applies in front of the torso, fading out as the handle rises past
    # the shoulders (overhead windups pass behind the head)
    low = min(max((shoulder_h + 0.05 - height) / 0.25, 0.0), 1.0)
    min_fwd = s.get("min_forward_m", 0.4) * low
    forward = max(rel.dot(fwd_axis), min_fwd)
    limit = 0.97 * (s1.bone.length + first.parent.bone.length)
    for _ in range(20):
        new_mid = root.head + left_axis * lateral + fwd_axis * forward + up_axis * height
        shift = new_mid - mid
        w1 = fist_first + shift - off1
        w2 = fist_second + shift - off2
        if (w1 - s1.head).length <= limit and (w2 - s2.head).length <= limit:
            break
        height += (shoulder_h - 0.2 - height) * 0.2
        forward = max(min_fwd, forward - 0.02)
        lateral *= 0.9
    short = _reach(rig, grip["bone"], fist_first + shift - off1, turn_first)
    short = max(short, _reach(rig, s["bone"], fist_second + shift - off2, turn_second))
    key = s.get("clip", "")
    SECOND_HAND_SHORTFALL[key] = max(SECOND_HAND_SHORTFALL.get(key, 0.0), short)


def _aim_wrist(rig, wrist: dict) -> None:
    """Rotate the grip hand (about its head) so the weapon's blade turns toward `aim`, measured in
    the root bone's posed frame (so a character falling over takes its staff with it), by
    `weight` of the way and at most `limit` degrees."""
    import bpy
    from mathutils import Matrix, Vector

    bpy.context.view_layer.update()
    pb = rig.pose.bones[wrist["bone"]]
    rest = pb.bone.matrix_local.to_3x3()
    current = (pb.matrix.to_3x3() @ rest.inverted()) @ Vector(wrist["blade"]).normalized()
    root = rig.pose.bones["root"]
    root_rot = root.matrix.to_3x3() @ root.bone.matrix_local.to_3x3().inverted()
    target = root_rot @ Vector(wrist["aim"]).normalized()
    q = current.rotation_difference(target)
    axis, angle = q.to_axis_angle()
    angle = min(angle * wrist.get("weight", 1.0), math.radians(wrist.get("limit", 180.0)))
    head = pb.matrix.translation.copy()
    turn = Matrix.Translation(head) @ Matrix.Rotation(angle, 4, axis) @ Matrix.Translation(-head)
    pb.matrix = turn @ pb.matrix


def bake_clip(rig, anim: dict, clip_name: str, start_frame: int = 0, hold: str | None = None,
              build: str | None = None):
    """Key every frame of a clip into a new action on the rig; returns the action."""
    import bpy

    frames = sample_clip(anim, clip_name, build)
    wrist = wrist_rule(anim, hold, clip_name, build)
    if wrist and "second" in wrist:
        wrist["second"]["clip"] = variant_name(clip_name, hold)
    act = bpy.data.actions.new(variant_name(clip_name, hold))
    rig.animation_data_create()
    rig.animation_data.action = act
    for i, pose in enumerate(frames):
        pose_rig(rig, pose, wrist)
        for pb in rig.pose.bones:
            pb.keyframe_insert("rotation_quaternion", frame=start_frame + i)
            if pb.name == "root":
                pb.keyframe_insert("location", frame=start_frame + i)
    return act


def check_axes(rig) -> list[str]:
    """Verify every term moves the skeleton the documented way (catches an axis or sign slip
    after any skeleton change). Returns failures."""
    import bpy

    def pts():
        bpy.context.view_layer.update()
        return {pb.name: (pb.head.copy(), pb.tail.copy()) for pb in rig.pose.bones}

    # (bone, term, watched bone, head/tail, world direction the point should move)
    probes = [
        ("spine", "bend", "head", 1, (0, -1, 0)),
        ("spine", "twist", "clavicle_r", 1, (0, -1, 0)),
        ("spine", "lean", "head", 1, (-1, 0, 0)),
        ("head", "tilt", "head", 1, (-1, 0, 0)),
        ("clavicle_l", "raise", "clavicle_l", 1, (0, 0, 1)),
        ("clavicle_r", "raise", "clavicle_r", 1, (0, 0, 1)),
        ("clavicle_l", "swing", "clavicle_l", 1, (0, -1, 0)),
        ("clavicle_r", "swing", "clavicle_r", 1, (0, -1, 0)),
        ("upperarm_l", "swing", "upperarm_l", 1, (0, -1, 0)),
        ("upperarm_r", "swing", "upperarm_r", 1, (0, -1, 0)),
        ("upperarm_l", "raise", "upperarm_l", 1, (1, 0, 1)),
        ("upperarm_r", "raise", "upperarm_r", 1, (-1, 0, 1)),
        ("forearm_l", "bend", "forearm_l", 1, (0, -1, 1)),
        ("forearm_r", "bend", "forearm_r", 1, (0, -1, 1)),
        ("hand_l", "curl", "hand_l", 1, (-1, 0, 0)),
        ("hand_r", "curl", "hand_r", 1, (1, 0, 0)),
        ("hand_l", "cock", "hand_l", 1, (0, -1, 0)),
        ("hand_r", "cock", "hand_r", 1, (0, -1, 0)),
        ("thigh_l", "swing", "thigh_l", 1, (0, -1, 0)),
        ("thigh_r", "swing", "thigh_r", 1, (0, -1, 0)),
        ("thigh_l", "spread", "thigh_l", 1, (1, 0, 0)),
        ("thigh_r", "spread", "thigh_r", 1, (-1, 0, 0)),
        ("calf_l", "bend", "calf_l", 1, (0, 1, 0)),
        ("calf_r", "bend", "calf_r", 1, (0, 1, 0)),
        ("foot_l", "point", "foot_l", 1, (0, 0, -1)),
        ("foot_r", "point", "foot_r", 1, (0, 0, -1)),
        ("root", "up", "pelvis", 0, (0, 0, 1)),
        ("root", "forward", "pelvis", 0, (0, -1, 0)),
        ("root", "left", "pelvis", 0, (1, 0, 0)),
        ("root", "pitch", "head", 1, (0, 1, 0)),
    ]
    from mathutils import Vector

    failures = []
    pose_rig(rig, {})
    base = pts()
    for bone, term, watch, end, direction in probes:
        amount = 0.1 if bone == "root" and term != "pitch" else 25.0
        pose_rig(rig, {bone: {term: amount}})
        moved = pts()[watch][end] - base[watch][end]
        if moved.dot(Vector(direction).normalized()) <= 0.01:
            failures.append(f"{bone}.{term}: {watch} moved {tuple(round(c, 3) for c in moved)}, expected toward {direction}")
    # root pitch pivots at the pelvis: the pelvis stays put
    pose_rig(rig, {"root": {"pitch": 60}})
    drift = (pts()["pelvis"][0] - base["pelvis"][0]).length
    if drift > 1e-3:
        failures.append(f"root.pitch moved the pelvis by {drift:.3f} m")
    pose_rig(rig, {})
    return failures
