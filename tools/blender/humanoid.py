"""Standard humanoid skeleton and parametric body (backlog M1-16).

One skeleton definition drives both the body mesh (Blender's Skin modifier gives each joint a
radius) and the armature, so every humanoid shares bone names and proportions scale cleanly.

Character convention: faces -Y, up is +Z, character's left is +X. Rest pose is an A-pose
(arms 50 degrees below horizontal) so shoulders deform well both raised and lowered.
"""
from __future__ import annotations

import math

import bpy
from mathutils import Vector

import common

# Standard bone names. The asset validator requires these on every character.
BONES = [
    # name, head joint, tail joint, parent
    ("root", "ground", "pelvis", None),
    ("pelvis", "pelvis", "spine", "root"),
    ("spine", "spine", "chest", "pelvis"),
    ("chest", "chest", "neck", "spine"),
    ("neck", "neck", "head", "chest"),
    ("head", "head", "head_top", "neck"),
    ("clavicle_l", "chest_top", "shoulder_l", "chest"),
    ("upperarm_l", "shoulder_l", "elbow_l", "clavicle_l"),
    ("forearm_l", "elbow_l", "wrist_l", "upperarm_l"),
    ("hand_l", "wrist_l", "hand_end_l", "forearm_l"),
    ("clavicle_r", "chest_top", "shoulder_r", "chest"),
    ("upperarm_r", "shoulder_r", "elbow_r", "clavicle_r"),
    ("forearm_r", "elbow_r", "wrist_r", "upperarm_r"),
    ("hand_r", "wrist_r", "hand_end_r", "forearm_r"),
    ("thigh_l", "hip_l", "knee_l", "pelvis"),
    ("calf_l", "knee_l", "ankle_l", "thigh_l"),
    ("foot_l", "ankle_l", "toe_l", "calf_l"),
    ("thigh_r", "hip_r", "knee_r", "pelvis"),
    ("calf_r", "knee_r", "ankle_r", "thigh_r"),
    ("foot_r", "ankle_r", "toe_r", "calf_r"),
]
BONE_NAMES = [b[0] for b in BONES]

# Edges of the skin mesh (joint pairs). ground/head_top are bone ends, not all are skinned.
SKIN_EDGES = [
    ("pelvis", "spine"), ("spine", "chest"), ("chest", "chest_top"), ("chest_top", "neck"),
    ("neck", "head"), ("head", "head_top"),
    ("chest_top", "shoulder_l"), ("shoulder_l", "elbow_l"), ("elbow_l", "wrist_l"), ("wrist_l", "hand_end_l"),
    ("chest_top", "shoulder_r"), ("shoulder_r", "elbow_r"), ("elbow_r", "wrist_r"), ("wrist_r", "hand_end_r"),
    ("pelvis", "hip_l"), ("hip_l", "knee_l"), ("knee_l", "ankle_l"), ("ankle_l", "toe_l"),
    ("pelvis", "hip_r"), ("hip_r", "knee_r"), ("knee_r", "ankle_r"), ("ankle_r", "toe_r"),
]

# Body masses for the metaball body. Ellipsoids are (half-size x, y, z) in metres, where x runs
# along the limb for limb parts; balls and capsules are a radius. Multiplied by the build's bulk.
HEAVY_PARTS = {
    "pelvis": (0.19, 0.14, 0.12), "abdomen": (0.16, 0.12, 0.14), "ribcage": (0.25, 0.17, 0.20),
    "traps": (0.24, 0.11, 0.10), "pec": (0.11, 0.06, 0.08), "lat": (0.10, 0.11, 0.17), "glute": 0.11,
    "neck": 0.095, "skull": (0.105, 0.12, 0.13), "jaw": (0.09, 0.09, 0.065), "brow": (0.09, 0.03, 0.025),
    "deltoid": 0.12, "upperarm": 0.095, "bicep": (0.11, 0.08, 0.08), "elbow": 0.08,
    "forearm": 0.09, "forearm_mass": 0.11, "hand": (0.12, 0.075, 0.055),
    "thigh": 0.115, "quad": (0.15, 0.10, 0.10), "knee": 0.085, "shin": 0.085, "calf": 0.105,
    "foot": (0.14, 0.07, 0.06),
}

# Builds: heights in metres and radii (x = side-to-side, y = front-to-back) per joint.
# "heavy" is broad and top-heavy (plate wearers); "lean" is narrower (cloth and leather).
BUILDS = {
    "heavy": {
        "height": 1.95,
        "shoulder_width": 0.36,
        "arm_angle_deg": 50,
        "bulk": 1.0,
        "parts": HEAVY_PARTS,
        "radii": {
            "pelvis": (0.20, 0.15), "spine": (0.21, 0.15), "chest": (0.27, 0.18), "chest_top": (0.24, 0.15),
            "neck": (0.085, 0.085), "head": (0.12, 0.13), "head_top": (0.105, 0.115),
            "shoulder": (0.13, 0.13), "elbow": (0.085, 0.085), "wrist": (0.07, 0.06), "hand_end": (0.095, 0.05),
            "hip": (0.13, 0.13), "knee": (0.10, 0.10), "ankle": (0.08, 0.08), "toe": (0.085, 0.07),
        },
    },
    "lean": {
        "height": 1.85,
        "shoulder_width": 0.29,
        "arm_angle_deg": 50,
        "bulk": 0.74,
        "parts": HEAVY_PARTS,
        "radii": {
            "pelvis": (0.16, 0.12), "spine": (0.15, 0.11), "chest": (0.19, 0.13), "chest_top": (0.18, 0.12),
            "neck": (0.065, 0.065), "head": (0.105, 0.115), "head_top": (0.095, 0.105),
            "shoulder": (0.09, 0.09), "elbow": (0.06, 0.06), "wrist": (0.05, 0.045), "hand_end": (0.075, 0.04),
            "hip": (0.10, 0.10), "knee": (0.075, 0.075), "ankle": (0.06, 0.06), "toe": (0.065, 0.055),
        },
    },
    # Graphics overhaul (G-01): realistic-heroic proportions, about 7.5 heads, open to every class.
    # Bodies come from anatomy.py; "radii" and "parts" are unused (metaball and skin bodies only).
    "male": {
        "height": 1.88,
        "shoulder_width": 0.205,
        "shoulder_z": 0.802,
        "chest_top_z": 0.812,
        "hip_width": 0.052,
        "knee_width": 0.05,
        "ankle_width": 0.052,
        "arm_angle_deg": 50,
        "bulk": 1.0,
        "parts": HEAVY_PARTS,
        "radii": {},
    },
    "female": {
        "height": 1.76,
        "shoulder_width": 0.18,
        "shoulder_z": 0.802,
        "chest_top_z": 0.812,
        "hip_width": 0.058,
        "knee_width": 0.046,
        "ankle_width": 0.048,
        "arm_angle_deg": 50,
        "bulk": 0.8,
        "parts": HEAVY_PARTS,
        "radii": {},
    },
}


def joints(build: dict) -> dict[str, Vector]:
    """Joint positions for a build, from proportions of total height (about 7 heads tall)."""
    h = build["height"]
    sw = build["shoulder_width"]
    a = math.radians(build["arm_angle_deg"])
    j: dict[str, Vector] = {
        "ground": Vector((0, 0, 0)),
        "pelvis": Vector((0, 0, 0.53 * h)),
        "spine": Vector((0, 0.005, 0.62 * h)),
        "chest": Vector((0, 0.0, 0.72 * h)),
        "chest_top": Vector((0, 0.01, build.get("chest_top_z", 0.80) * h)),
        "neck": Vector((0, 0.0, 0.845 * h)),
        "head": Vector((0, -0.01, 0.875 * h)),
        "head_top": Vector((0, -0.015, h)),
    }
    upper, fore, hand = 0.17 * h, 0.155 * h, 0.10 * h
    for side, sx in (("l", 1), ("r", -1)):
        sh = Vector((sx * sw, 0.01, build.get("shoulder_z", 0.79) * h))
        down = Vector((sx * math.cos(a), 0, -math.sin(a)))
        el = sh + down * upper
        wr = el + down * fore
        j[f"shoulder_{side}"] = sh
        j[f"elbow_{side}"] = el + Vector((0, 0.02, 0))  # elbows slightly back
        j[f"wrist_{side}"] = wr
        j[f"hand_end_{side}"] = wr + down * hand
        j[f"hip_{side}"] = Vector((sx * build.get("hip_width", 0.065) * h, 0, 0.50 * h))
        j[f"knee_{side}"] = Vector((sx * build.get("knee_width", 0.07) * h, -0.015, 0.275 * h))
        j[f"ankle_{side}"] = Vector((sx * build.get("ankle_width", 0.075) * h, 0.01, 0.045 * h))
        j[f"toe_{side}"] = Vector((sx * (build.get("ankle_width", 0.075) + 0.005) * h, -0.11 * h, 0.02 * h))
    return j


def _radius(build: dict, joint: str) -> tuple[float, float]:
    key = joint.rsplit("_", 1)[0] if joint.endswith(("_l", "_r")) else joint
    return build["radii"][key]


def build_body(build_name: str, name: str = "body") -> bpy.types.Object:
    """Metaball body: individual masses (rib cage, pecs, deltoids, calves...) merged smoothly,
    converted to one closed mesh, remeshed, smoothed and decimated.

    Metaballs replaced the first Skin-modifier version, which only made thin tubes around the
    skeleton and could not produce the heavy, top-heavy silhouette the art direction needs.
    """
    build = BUILDS[build_name]
    j = joints(build)
    bulk = build.get("bulk", 1.0)
    mb = bpy.data.metaballs.new(name + "_mb")
    mb.resolution = 0.015
    mb.render_resolution = 0.015
    # With threshold 0.1 and stiffness 2, a metaball's surface sits at 0.795 of its radius
    # (measured). K scales radii so each mass comes out at its nominal size in metres.
    mb.threshold = 0.1
    K = 1 / 0.795
    mobj = bpy.data.objects.new(name + "_mb", mb)
    bpy.context.scene.collection.objects.link(mobj)

    def ball(center, r):
        e = mb.elements.new(type="BALL")
        e.co = center
        e.radius = r * bulk * K
        e.stiffness = 2.0
        return e

    def ell(center, sx, sy, sz, axis: Vector | None = None, r: float = 0.1):
        e = mb.elements.new(type="ELLIPSOID")
        e.co = center
        e.radius = r
        e.size_x, e.size_y, e.size_z = (sx * bulk * K / r, sy * bulk * K / r, sz * bulk * K / r)
        if axis is not None:
            e.rotation = Vector((1, 0, 0)).rotation_difference(axis.normalized())
        e.stiffness = 2.0
        return e

    def seg(a: Vector, b: Vector, r: float):
        e = mb.elements.new(type="CAPSULE")
        e.co = (a + b) / 2
        e.radius = r * bulk * K
        e.size_x = (b - a).length / 2
        e.rotation = Vector((1, 0, 0)).rotation_difference((b - a).normalized())
        e.stiffness = 2.0
        return e

    P = build["parts"]
    up = Vector((0, 0, 1))
    # torso
    ell(j["pelvis"] + Vector((0, 0.01, 0)), *P["pelvis"])
    ell(j["spine"], *P["abdomen"])
    ell(j["chest"] + Vector((0, 0, 0.03)), *P["ribcage"])
    ell(j["chest_top"] + Vector((0, 0.03, 0.0)), *P["traps"])
    for sx in (1, -1):
        ell(j["chest"] + Vector((sx * 0.10, -0.10, 0.05)), *P["pec"])
        ell(j["chest"] + Vector((sx * 0.16, 0.05, -0.02)), *P["lat"])
        ball(j["pelvis"] + Vector((sx * 0.08, 0.08, -0.04)), P["glute"])
    # neck and head
    seg(j["neck"] - up * 0.03, j["head"] + up * 0.03, P["neck"])
    ell(j["head"] + Vector((0, 0, 0.11)), *P["skull"])
    ell(j["head"] + Vector((0, -0.035, 0.035)), *P["jaw"])
    ell(j["head"] + Vector((0, -0.075, 0.12)), *P["brow"])
    # arms and legs
    for s in ("l", "r"):
        arm_dir = j[f"elbow_{s}"] - j[f"shoulder_{s}"]
        fore_dir = j[f"wrist_{s}"] - j[f"elbow_{s}"]
        ball(j[f"shoulder_{s}"], P["deltoid"])
        seg(j[f"shoulder_{s}"], j[f"elbow_{s}"], P["upperarm"])
        ell(j[f"shoulder_{s}"] + arm_dir * 0.55 + Vector((0, -0.03, 0)), *P["bicep"], axis=arm_dir)
        ball(j[f"elbow_{s}"], P["elbow"])
        seg(j[f"elbow_{s}"], j[f"wrist_{s}"], P["forearm"])
        ball(j[f"elbow_{s}"] + fore_dir * 0.28, P["forearm_mass"])
        hand_dir = j[f"hand_end_{s}"] - j[f"wrist_{s}"]
        ell(j[f"wrist_{s}"] + hand_dir * 0.45, *P["hand"], axis=hand_dir)
        leg_dir = j[f"knee_{s}"] - j[f"hip_{s}"]
        seg(j[f"hip_{s}"], j[f"knee_{s}"], P["thigh"])
        ell(j[f"hip_{s}"] + leg_dir * 0.45 + Vector((0, -0.03, 0)), *P["quad"], axis=leg_dir)
        ball(j[f"knee_{s}"], P["knee"])
        seg(j[f"knee_{s}"], j[f"ankle_{s}"], P["shin"])
        ball(j[f"knee_{s}"] + (j[f"ankle_{s}"] - j[f"knee_{s}"]) * 0.3 + Vector((0, 0.04, 0)), P["calf"])
        foot_dir = j[f"toe_{s}"] - j[f"ankle_{s}"]
        ell(j[f"ankle_{s}"] + foot_dir * 0.5 + Vector((0, 0, -0.005)), *P["foot"], axis=foot_dir)

    # metaball -> mesh
    bpy.context.view_layer.objects.active = mobj
    mobj.select_set(True)
    bpy.ops.object.convert(target="MESH")
    obj = bpy.context.active_object
    obj.name = name
    obj.data.name = name
    remesh = obj.modifiers.new("remesh", "REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = 0.012
    smooth = obj.modifiers.new("smooth", "CORRECTIVE_SMOOTH")
    smooth.iterations = 6
    smooth.use_only_smooth = True
    dec = obj.modifiers.new("decimate", "DECIMATE")
    dec.ratio = build.get("decimate", 0.12)
    for m in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.ops.object.shade_smooth()
    return obj


def build_body_sdf(build_name: str, name: str = "body", target_tris: int = 9000,
                   voxel: float = 0.005, hands: tuple[str, str] = ("relaxed", "fist")) -> bpy.types.Object:
    """Third version: a signed-distance-field body (tapered limbs and muscles blended with
    smooth unions, see body_sdf.py), extracted with marching cubes and reduced to the
    triangle target. Replaced the metaball body, which read as a segmented mannequin."""
    import numpy as np
    import body_sdf
    build = BUILDS[build_name]
    j = {k: np.array(v) for k, v in joints(build).items()}
    verts, faces = body_sdf.body_mesh(j, build_name, voxel, hands)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts.tolist(), [], faces.tolist())
    mesh.validate()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    dec = obj.modifiers.new("decimate", "DECIMATE")
    dec.ratio = min(1.0, target_tris / max(len(faces), 1))
    dec.use_symmetry = False  # the hands differ (a fist on the weapon hand)
    smooth = obj.modifiers.new("smooth", "CORRECTIVE_SMOOTH")
    smooth.iterations = 3
    smooth.use_only_smooth = True
    for m in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.ops.object.shade_smooth()
    return obj


def build_body_skin(build_name: str, name: str = "body") -> bpy.types.Object:
    """First version (kept for comparison): Skin-modifier body. Too thin; see build_body."""
    build = BUILDS[build_name]
    j = joints(build)
    names = sorted({n for e in SKIN_EDGES for n in e})
    index = {n: i for i, n in enumerate(names)}
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(j[n]) for n in names], [(index[a], index[b]) for a, b in SKIN_EDGES], [])
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    skin = obj.modifiers.new("skin", "SKIN")
    skin.use_smooth_shade = True
    skin.branch_smoothing = 0.6
    for n, v in zip(names, mesh.skin_vertices[0].data):
        v.radius = _radius(build, n)
        v.use_root = n == "pelvis"
    sub = obj.modifiers.new("subsurf", "SUBSURF")
    sub.levels = 2
    remesh = obj.modifiers.new("remesh", "REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = 0.018
    smooth = obj.modifiers.new("smooth", "CORRECTIVE_SMOOTH")
    smooth.iterations = 8
    smooth.use_only_smooth = True
    dec = obj.modifiers.new("decimate", "DECIMATE")
    dec.ratio = 0.35
    for m in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.ops.object.shade_smooth()
    return obj


def build_armature(build_name: str, name: str = "rig") -> bpy.types.Object:
    build = BUILDS[build_name]
    j = joints(build)
    arm = bpy.data.armatures.new(name)
    rig = bpy.data.objects.new(name, arm)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    edit = {}
    for bname, head, tail, parent in BONES:
        b = arm.edit_bones.new(bname)
        b.head, b.tail = j[head], j[tail]
        if parent:
            b.parent = edit[parent]
            b.use_connect = (edit[parent].tail - b.head).length < 1e-4
        edit[bname] = b
    bpy.ops.object.mode_set(mode="OBJECT")
    return rig


def bind(body: bpy.types.Object, rig: bpy.types.Object) -> None:
    """Parent the body to the rig with automatic (heat-map) weights."""
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")


def _reduce_weighted(o, target_tris: int, n_faces: int, factor: float) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    dec = o.modifiers.new("decimate", "DECIMATE")
    dec.ratio = min(1.0, target_tris / max(n_faces, 1))
    dec.vertex_group = "detail"
    dec.vertex_group_factor = factor
    dec.use_symmetry = False
    smooth = o.modifiers.new("smooth", "CORRECTIVE_SMOOTH")
    smooth.iterations = 2
    smooth.use_only_smooth = True
    for m in list(o.modifiers):
        bpy.ops.object.modifier_apply(modifier=m.name)


def build_body_anatomy(body_type: str, name: str = "body", target_tris: int = 14000, voxel: float = 0.003,
                       hands: tuple[str, str] = ("relaxed", "fist"),
                       head_share: float = 0.0) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Overhaul body (G-01): the anatomy.py field extracted densely (`high`, the normal-bake
    source) and a game mesh reduced from it to `target_tris` (`low`). The head and hands keep
    proportionally more triangles (a weighted reduction), since faces and fingers are seen close."""
    import numpy as np
    import anatomy
    build = BUILDS[body_type]
    jv = joints(build)
    j = {k: np.array(v) for k, v in jv.items()}
    verts, faces = anatomy.body_mesh(j, body_type, voxel, hands)
    high = bpy.data.objects.new(f"{name}_high", common.mesh_from_arrays(f"{name}_high", verts, faces))
    bpy.context.scene.collection.objects.link(high)
    neck_z = float(jv["neck"].z)
    hand_c = np.array([list((jv[f"wrist_{s}"] + jv[f"hand_end_{s}"]) / 2) for s in ("l", "r")])
    # the group's weight is how freely a vertex may be removed (Blender's reduction reads it that way)
    w = np.where(verts[:, 2] > neck_z, 0.5, 1.0)
    near_hand = np.min(np.linalg.norm(verts[:, None, :] - hand_c[None], axis=2), axis=1) < 0.11
    w = np.where(near_hand, 0.7, w)
    n_faces = len(faces)
    del verts, faces

    def weighted_copy():
        o = high.copy()
        o.data = high.data.copy()
        bpy.context.scene.collection.objects.link(o)
        g = o.vertex_groups.new(name="detail")
        for value in np.unique(w):
            g.add(np.nonzero(w == value)[0].tolist(), float(value), "REPLACE")
        return o
    # The weighted reduction is very sensitive to the group factor and the right factor depends on
    # the mesh density, so search it for the head's share of the triangles (log-scale bisection).
    lo_f, hi_f = 0.0003, 0.03
    best = None
    for _ in range(6 if head_share > 0 else 1):
        factor = (lo_f * hi_f) ** 0.5 if head_share > 0 else 0.003
        trial = weighted_copy()
        _reduce_weighted(trial, target_tris, n_faces, factor)
        n = len(trial.data.polygons)
        share = sum(1 for p in trial.data.polygons if p.center.z > neck_z) / max(n, 1)
        print(f"  reduction factor {factor:.5f}: head share {share:.3f}", flush=True)
        if best is None or abs(share - head_share) < abs(best[1] - head_share):
            if best is not None:
                bpy.data.objects.remove(best[0])
            best = (trial, share)
        else:
            bpy.data.objects.remove(trial)
        if head_share <= 0 or abs(share - head_share) < 0.01:
            break
        if share < head_share:
            lo_f = factor
        else:
            hi_f = factor
    low = best[0]
    low.name = name
    low.vertex_groups.remove(low.vertex_groups["detail"])
    head_tris = sum(1 for p in low.data.polygons if p.center.z > neck_z)
    print(f"BODY {name}: {len(low.data.polygons)} triangles, {head_tris} on the head", flush=True)
    for o in (low, high):
        bpy.context.view_layer.objects.active = o
        o.select_set(True)
        bpy.ops.object.shade_smooth()
        o.select_set(False)
    return low, high
