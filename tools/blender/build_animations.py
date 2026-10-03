"""Build one body build's animation library and review it on the finished characters (M1-21).

    python3 tools/blender/build_animations.py --spec data/assets/anims_heavy.json \
        [--previews previews/animations] [--no-export] [--clips run,idle]

Export: a fresh standard skeleton for the build (identical to every character of that build),
every clip of the animation set baked frame by frame, and a tiny proxy mesh skinned to every
bone so the glTF carries a real skin (Godot then imports a Skeleton3D with the clips on an
AnimationPlayer). Characters of the build share the library.

Review (--previews): each character asset of the build is imported and re-bound to the fresh
skeleton, its weapon attached with the set's weapon_grip, then
- pose sheets: sampled frames of every clip, grouped into locomotion, casting and combat sheets;
- clipping check: triangles of one limb passing through another body part (or the weapon
  through the body) in sampled frames; the gated clips must be clean. Results go to a JSON
  report next to the sheets.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import animation  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402

REPO = common.REPO

SHEETS = {
    "locomotion": ["idle", "combat_idle", "run", "strafe_left", "strafe_right", "backpedal", "jump", "feared_run"],
    "casting": ["cast_start", "cast_loop", "cast_release", "cast_release_frost", "cast_release_holy", "channel",
                "ranged_shot"],
    "combat": ["attack_1", "attack_2", "attack_3", "hit", "stunned", "death", "victory"],
}
# Clips that must be free of clipping (backlog M1-21: idle, run and cast poses).
GATED_CLIPS = ["idle", "combat_idle", "run", "cast_start", "cast_loop", "cast_release", "cast_release_frost",
               "cast_release_holy", "channel"]

CHAINS = {
    "arm_l": {"upperarm_l", "forearm_l", "hand_l"},
    "arm_r": {"upperarm_r", "forearm_r", "hand_r"},
    "leg_l": {"thigh_l", "calf_l", "foot_l"},
    "leg_r": {"thigh_r", "calf_r", "foot_r"},
}
# Pairs of body regions that must not pass through each other, with the joints whose
# neighbourhood is exempt (skin there is meant to fold into itself).
PAIRS = [
    ("arm_l", "torso", ("upperarm_l",)),
    ("arm_r", "torso", ("upperarm_r",)),
    ("arm_l", "leg_l", ()),
    ("arm_r", "leg_r", ()),
    ("arm_l", "leg_r", ()),
    ("arm_r", "leg_l", ()),
    ("arm_l", "arm_r", ()),
    ("leg_l", "leg_r", ("thigh_l", "thigh_r")),
    ("weapon", "torso", ()),
    ("weapon", "leg_l", ()),
    ("weapon", "leg_r", ()),
    ("weapon", "arm_l", ()),
]
# shoulders: pauldrons (rigid on the clavicle) are built to overlap the upper-arm plate out to
# about 0.24 m from the joint; contact under the rim is hidden (DECISIONS.md, M1-21)
JOINT_ZONE_M = {"upperarm_l": 0.24, "upperarm_r": 0.24, "thigh_l": 0.2, "thigh_r": 0.2}


# ----------------------------------------------------------------------------- library

def proxy_mesh(rig) -> bpy.types.Object:
    """One tiny triangle per bone, fully weighted to it, so the exported skin lists every bone."""
    verts, faces = [], []
    for i, b in enumerate(rig.data.bones):
        h = b.head_local
        verts += [h, h + Vector((0.004, 0, 0)), h + Vector((0, 0, 0.004))]
        faces.append((3 * i, 3 * i + 1, 3 * i + 2))
    me = bpy.data.meshes.new("anim_proxy")
    me.from_pydata([tuple(v) for v in verts], [], faces)
    obj = bpy.data.objects.new("anim_proxy", me)
    bpy.context.scene.collection.objects.link(obj)
    for i, b in enumerate(rig.data.bones):
        vg = obj.vertex_groups.new(name=b.name)
        vg.add([3 * i, 3 * i + 1, 3 * i + 2], 1.0, "REPLACE")
    obj.parent = rig
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = rig
    return obj


def build_library(spec: dict, anim: dict, clips: list[str], export: bool):
    common.reset_scene()
    # keys are placed on frame numbers at the set's rate; the exporter converts frames to
    # seconds with the scene rate, so the two must agree
    bpy.context.scene.render.fps = anim["fps"]
    bpy.context.scene.render.fps_base = 1.0
    build = spec["body_build"]
    rig = humanoid.build_armature(build, "rig")
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="POSE")
    failures = animation.check_axes(rig)
    if failures:
        raise SystemExit("axis check failed:\n  " + "\n  ".join(failures))
    print(f"axis check OK ({build})")
    import body_sdf
    jt = {k: np.array(tuple(v)) for k, v in humanoid.joints(humanoid.BUILDS[build]).items()}
    fist = body_sdf.fist_grip(jt, anim["weapon_grip"]["bone"][-1], build)
    got = grip_matrix(rig, anim["weapon_grip"], "forward", build).translation
    if (Vector(tuple(fist)) - got).length > 0.005:
        raise SystemExit(f"weapon_grip for {build} is {(Vector(tuple(fist)) - got).length * 1000:.1f} mm from the "
                         f"fist's centre {tuple(round(c, 4) for c in fist)}; update data/animations")
    for hold in [None] + animation.hold_variants(anim):
        for clip in clips:
            name = animation.variant_name(clip, hold)
            act = animation.bake_clip(rig, anim, clip, hold=hold, build=build)
            track = rig.animation_data.nla_tracks.new()
            track.name = name
            strip = track.strips.new(name, 0, act)
            strip.name = name
            rig.animation_data.action = None
        print(f"  baked {len(clips)} clips{' for hold ' + hold if hold else ''}")
    short = {k: round(v, 3) for k, v in animation.SECOND_HAND_SHORTFALL.items() if v > 0.005}
    if short:
        print(f"  second hand fell short of the handle (m): {short}")
    animation.pose_rig(rig, {})
    bpy.ops.object.mode_set(mode="OBJECT")
    proxy = proxy_mesh(rig)
    if export:
        out = common.export_glb(Path(spec["out"]), [rig, proxy])
        print(f"BUILT {spec['id']} -> {out}")
    bpy.data.objects.remove(proxy, do_unlink=True)
    # previews pose the rig directly; left in place, the baked tracks would override those poses
    # whenever the renderer re-evaluates animation
    rig.animation_data_clear()
    return rig


# ----------------------------------------------------------------------------- characters

def import_glb(path: Path) -> list[bpy.types.Object]:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    new = [o for o in bpy.data.objects if o not in before]
    helpers = [o for o in new if any(c.name.startswith("glTF_not_exported") for c in o.users_collection)]
    for o in helpers:  # the importer's bone-display shape
        bpy.data.objects.remove(o, do_unlink=True)
    return [o for o in new if o not in helpers]


def load_character(char_spec: dict, rig) -> bpy.types.Object:
    """Import a character and re-bind its mesh to `rig` (same build, so the same rest pose)."""
    new = import_glb(REPO / char_spec["out"])
    meshes = [o for o in new if o.type == "MESH"]
    arms = [o for o in new if o.type == "ARMATURE"]
    # the imported skeleton must match the fresh one, or the re-bind would distort the mesh
    worst = 0.0
    for a in arms:
        for b in a.data.bones:
            if b.name in rig.data.bones:
                worst = max(worst, ((a.matrix_world @ b.head_local) - rig.data.bones[b.name].head_local).length)
    if worst > 1e-3:
        raise SystemExit(f"{char_spec['id']}: imported skeleton differs from the {char_spec['body_build']} "
                         f"skeleton by {worst:.4f} m")
    if len(meshes) != 1:
        raise SystemExit(f"{char_spec['id']}: expected one mesh, found {len(meshes)}")
    body = meshes[0]
    mw = body.matrix_world.copy()
    body.parent = None
    body.matrix_world = mw
    for mod in body.modifiers:
        if mod.type == "ARMATURE":
            mod.object = rig
    for o in new:
        if o is not body:
            bpy.data.objects.remove(o, do_unlink=True)
    body.name = char_spec["id"]
    return body


def grip_matrix(rig, grip: dict, hold: str, build: str) -> Matrix:
    """Rest-pose world matrix of a held weapon (see animation.grip_rest)."""
    return animation.grip_rest(rig, grip, hold, build)


def attach_weapon(weapon_spec: dict, rig, grip: dict, build: str) -> bpy.types.Object:
    new = import_glb(REPO / weapon_spec["out"])
    meshes = [o for o in new if o.type == "MESH"]
    for o in meshes:
        mw = o.matrix_world.copy()
        o.parent = None
        o.matrix_world = mw
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    weapon = bpy.context.view_layer.objects.active
    for o in new:
        if o is not weapon and o.name in bpy.data.objects:
            bpy.data.objects.remove(o, do_unlink=True)
    weapon.name = weapon_spec["id"]
    animation.pose_rig(rig, {})
    bpy.context.view_layer.update()
    world = grip_matrix(rig, grip, weapon_spec.get("params", {}).get("hold", "forward"), build)
    weapon.parent = rig
    weapon.parent_type = "BONE"
    weapon.parent_bone = grip["bone"]
    weapon.matrix_parent_inverse = Matrix()
    bpy.context.view_layer.update()
    weapon.matrix_world = world
    return weapon


# ----------------------------------------------------------------------------- clipping

def triangle_regions(body: bpy.types.Object) -> np.ndarray:
    """Region name per vertex from its strongest bone weight."""
    names = {vg.index: vg.name for vg in body.vertex_groups}
    chain_of = {b: c for c, bones in CHAINS.items() for b in bones}
    region = []
    for v in body.data.vertices:
        best = max(v.groups, key=lambda g: g.weight, default=None)
        bone = names.get(best.group, "") if best else ""
        region.append(chain_of.get(bone, "torso"))
    return np.array(region)


def world_triangles(obj: bpy.types.Object):
    deps = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(deps)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    mw = ev.matrix_world
    verts = [mw @ v.co for v in me.vertices]
    tris = [tuple(t.vertices) for t in me.loop_triangles]
    ev.to_mesh_clear()
    return verts, tris


SEARCH_M = 0.15      # deepest penetration looked for
GRAZE_M = 0.015      # penetration up to this depth reads as surfaces touching, not clipping
MIN_PIECE_TRIS = 40  # rivets and other specks are ignored as clipping targets
RAY_DIRS = [Vector(d).normalized() for d in ((0.31, 0.52, 0.8), (-0.83, 0.21, -0.51), (0.13, -0.94, 0.3))]
PAIR_SET = {frozenset((a, b)): exempt for a, b, exempt in PAIRS}


class Pieces:
    """The character mesh split back into its closed pieces (body, each armor part), plus the
    weapon's pieces. glTF splits vertices along UV seams, so vertices are welded by position
    first; the welding is fixed per character, only positions change per frame."""

    def __init__(self, body, weapon, vregion: np.ndarray):
        from scipy.sparse import coo_matrix
        from scipy.sparse.csgraph import connected_components

        self.objs = [(body, vregion)] + ([(weapon, None)] if weapon is not None else [])
        self.parts = []  # per object: (welded rep index, welded tris, piece label, region per welded vertex, per-tri region)
        for obj, reg in self.objs:
            verts, tris = world_triangles(obj)
            co = np.array([tuple(v) for v in verts])
            _u, rep_idx, inv = np.unique(np.round(co / 1e-5).astype(np.int64), axis=0, return_index=True,
                                         return_inverse=True)
            inv = inv.ravel()
            t = inv[np.array(tris)]
            n = len(rep_idx)
            g = coo_matrix((np.ones(3 * len(t)), (np.concatenate([t[:, 0], t[:, 1], t[:, 2]]),
                                                  np.concatenate([t[:, 1], t[:, 2], t[:, 0]]))), shape=(n, n))
            _k, label = connected_components(g, directed=False)
            wreg = np.array(["weapon"] * n) if reg is None else reg[rep_idx]
            treg = np.array(["weapon"] * len(t)) if reg is None else np.array(
                [max(set(r), key=list(r).count) for r in wreg[t]])
            self.parts.append((rep_idx, t, label, wreg, treg))

    def frame(self, rig) -> dict[str, dict]:
        pieces = []  # (tree, lo, hi, tri regions, owner id)
        points = []  # (positions, regions, owner ids)
        joints = {b: np.array(tuple(rig.matrix_world @ rig.pose.bones[b].head)) for b in JOINT_ZONE_M}
        for oi, ((obj, _r), (rep_idx, t, label, wreg, treg)) in enumerate(zip(self.objs, self.parts)):
            verts, _tris = world_triangles(obj)
            co = np.array([tuple(v) for v in verts])[rep_idx]
            vlist = [Vector(c) for c in co]
            tlabel = label[t[:, 0]]
            for lab in np.unique(tlabel):
                sel = np.nonzero(tlabel == lab)[0]
                if len(sel) < MIN_PIECE_TRIS:
                    continue
                pts = co[np.unique(t[sel])]
                pieces.append((BVHTree.FromPolygons(vlist, [tuple(x) for x in t[sel]]), pts.min(axis=0),
                               pts.max(axis=0), treg[sel], (oi, lab)))
            points.append((co, wreg, [(oi, lab) for lab in label]))
        out: dict[str, dict] = {}
        for co, wreg, owner in points:
            for pi, (tree, lo, hi, treg, pid) in enumerate(pieces):
                cand = np.nonzero(np.all((co > lo) & (co < hi), axis=1))[0]
                for vi in cand:
                    if owner[vi] == pid:
                        continue
                    p = Vector(co[vi])
                    near = tree.find_nearest(p, SEARCH_M)
                    if near[0] is None:
                        continue
                    a, b = wreg[vi], treg[near[2]]
                    key = frozenset((a, b))
                    if a == b or key not in PAIR_SET:
                        continue
                    if any(np.linalg.norm(co[vi] - joints[e]) < JOINT_ZONE_M[e] for e in PAIR_SET[key]):
                        continue
                    if near[3] <= GRAZE_M or not _inside(tree, p):
                        continue
                    name = "/".join(x for x in next(pr for pr in PAIRS if frozenset(pr[:2]) == key)[:2])
                    hit = out.setdefault(name, {"depth_m": 0.0, "verts": 0})
                    if near[3] > hit["depth_m"]:
                        hit["depth_m"] = round(near[3], 3)
                        hit["at"] = [_nearest_bone(rig, co[vi]), _nearest_bone(rig, np.array(tuple(near[0])))]
                    hit["verts"] += 1
        return out


def _nearest_bone(rig, p: np.ndarray) -> str:
    """The bone whose posed segment passes closest to a point (to say where clipping happens)."""
    best, name = 1e9, ""
    for pb in rig.pose.bones:
        a, b = np.array(tuple(pb.head)), np.array(tuple(pb.tail))
        t = np.clip(np.dot(p - a, b - a) / max(np.dot(b - a, b - a), 1e-9), 0, 1)
        d = np.linalg.norm(p - (a + t * (b - a)))
        if d < best:
            best, name = d, pb.name
    return name


def _inside(tree, p: Vector) -> bool:
    """Ray parity in three skewed directions, majority vote (robust to grazing a mesh edge)."""
    votes = 0
    for d in RAY_DIRS:
        o, hits = p, 0
        while hits < 64:
            loc, _n, _i, _d = tree.ray_cast(o, d)
            if loc is None:
                break
            hits += 1
            o = loc + d * 1e-5
        votes += hits % 2
    return votes >= 2


# ----------------------------------------------------------------------------- previews

def setup_render(cell: int) -> None:
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 8
    scene.cycles.use_denoising = True
    scene.render.resolution_x = cell
    scene.render.resolution_y = cell
    scene.view_settings.view_transform = "AgX"
    common.setup_lighting()


def sample_frames(anim: dict, clip: str, count: int = 6) -> list[int]:
    c = anim["clips"][clip]
    n = animation.frame_count(c, anim["fps"])
    last = n - 2 if c["loop"] else n - 1  # a loop's last frame repeats its first
    return sorted({int(round(i * last / (count - 1))) for i in range(count)})


def framing(objs, yaw_deg: float):
    """Camera direction and ortho box for the current pose."""
    a = math.radians(yaw_deg)
    fwd = Vector((math.sin(a), -math.cos(a), 0.18)).normalized()  # from the model toward the camera
    right = Vector((0, 0, 1)).cross(fwd).normalized()
    up = fwd.cross(right)
    deps = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in objs:
        ev = o.evaluated_get(deps)
        pts += [ev.matrix_world @ Vector(c) for c in ev.bound_box]
    return fwd, right, up, pts


def render_sheet(body, weapon, rig, anim: dict, clips: list[str], out_png: Path, title: str, cell: int = 220,
                 hold: str | None = None, build: str | None = None, yaw: float = -62.0, count: int = 6):
    from PIL import Image, ImageDraw

    scene = bpy.context.scene
    cam = bpy.data.objects.new("_anim_cam", bpy.data.cameras.new("_anim_cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.type = "ORTHO"
    objs = [body] + ([weapon] if weapon else [])
    # default yaw: front three-quarter from the character's right (weapon side); 90 is a side view
    rows = []
    for clip in clips:
        frames = animation.sample_clip(anim, clip, build)
        wrist = animation.wrist_rule(anim, hold, clip, build)
        picks = sample_frames(anim, clip, count)
        # one camera for the whole row, fitted to every sampled pose, so motion reads as motion
        pts = []
        for f in picks:
            animation.pose_rig(rig, frames[f], wrist)
            bpy.context.view_layer.update()
            fwd, right, up, p = framing(objs, yaw)
            pts += p
        xs = [p.dot(right) for p in pts]
        ys = [p.dot(up) for p in pts]
        ys.append(0.0)
        cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
        cam.data.ortho_scale = max(max(xs) - min(xs), max(ys) - min(ys)) * 1.08
        centre = right * cx + up * cy
        cam.location = centre + fwd * 10
        cam.rotation_euler = (-fwd).to_track_quat("-Z", "Y").to_euler()
        tiles = []
        for f in picks:
            animation.pose_rig(rig, frames[f], wrist)
            tmp = out_png.with_name(f"_{out_png.stem}_{clip}_{f}.png")
            scene.render.filepath = str(tmp)
            bpy.ops.render.render(write_still=True)
            tiles.append((f, tmp))
        rows.append((clip, tiles))
    cols = max(len(t) for _c, t in rows)
    label_w = 120
    sheet = Image.new("RGB", (label_w + cols * cell, 30 + len(rows) * cell), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    draw.text((8, 8), title, fill=(220, 220, 220))
    for r, (clip, tiles) in enumerate(rows):
        y = 30 + r * cell
        draw.text((8, y + cell // 2 - 6), clip, fill=(220, 220, 220))
        for c, (f, tmp) in enumerate(tiles):
            sheet.paste(Image.open(tmp).convert("RGB"), (label_w + c * cell, y))
            draw.text((label_w + c * cell + 4, y + 4), f"f{f}", fill=(200, 200, 120))
            tmp.unlink()
    out_png.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_png)
    bpy.data.objects.remove(cam, do_unlink=True)
    animation.pose_rig(rig, {})
    print(f"sheet {out_png}")


def review(spec: dict, anim: dict, rig, clips: list[str], previews: Path, sheets: bool) -> dict:
    report = {}
    for path in sorted((REPO / "data" / "assets").glob("*.json")):
        cs = json.loads(path.read_text())
        bare_body = cs["id"] == f"body_{spec['body_build']}"  # the overhaul's bare bodies (G-01) are reviewed too
        if (cs["kind"] != "character" and not bare_body) or cs.get("body_build") != spec["body_build"]:
            continue
        if not (REPO / cs["out"]).exists():
            print(f"  skip {cs['id']}: not built")
            continue
        body = load_character(cs, rig)
        weapon, hold = None, None
        wid = cs.get("params", {}).get("weapon")
        if wid:
            ws = json.loads((REPO / "data" / "assets" / f"{wid}.json").read_text())
            if (REPO / ws["out"]).exists():
                weapon = attach_weapon(ws, rig, anim["weapon_grip"], cs["body_build"])
                h = ws.get("params", {}).get("hold", "forward")
                hold = h if h in animation.hold_variants(anim) else None
        vregion = triangle_regions(body)
        animation.pose_rig(rig, {})
        bpy.context.view_layer.update()
        pieces = Pieces(body, weapon, vregion)
        rest_hits = pieces.frame(rig)
        per_clip = {}
        for clip in clips:
            frames = animation.sample_clip(anim, clip, cs["body_build"])
            wrist = animation.wrist_rule(anim, hold, clip, cs["body_build"])
            worst: dict[str, dict] = {}
            for f in range(0, len(frames), 2):
                animation.pose_rig(rig, frames[f], wrist)
                bpy.context.view_layer.update()
                for k, hit in pieces.frame(rig).items():
                    if hit["depth_m"] > worst.get(k, {"depth_m": 0})["depth_m"]:
                        worst[k] = dict(hit, frame=f)
            per_clip[clip] = dict(sorted(worst.items()))
        gated_fail = {c: per_clip[c] for c in GATED_CLIPS if c in per_clip and per_clip[c]}
        report[cs["id"]] = {"rest": rest_hits, "clips": per_clip, "gated_failures": gated_fail}
        print(f"CLIPPING {cs['id']}: rest={rest_hits} gated failures={len(gated_fail)}")
        for c, hits in per_clip.items():
            if hits:
                print(f"    {c}{' (gated)' if c in GATED_CLIPS else ''}: {hits}")
        if sheets:
            setup_render(220)
            for sheet, names in SHEETS.items():
                names = [n for n in names if n in clips]
                if names:
                    render_sheet(body, weapon, rig, anim, names, previews / f"{cs['id']}_{sheet}.png",
                                 f"{cs['id']} - {sheet}{' (hold ' + hold + ')' if hold else ''}", hold=hold,
                                 build=cs["body_build"])
        for o in (body, weapon):
            if o is not None:
                bpy.data.objects.remove(o, do_unlink=True)
    return report


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", type=Path, required=True)
    ap.add_argument("--previews", type=Path)
    ap.add_argument("--clips", default="", help="comma-separated subset")
    ap.add_argument("--no-export", action="store_true")
    ap.add_argument("--no-sheets", action="store_true", help="with --previews: clipping check only")
    args = ap.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:])
    spec = common.load_spec(args.spec)
    anim = animation.load_set(spec["params"]["set"])
    problems = animation.validate_set(anim)
    if problems:
        raise SystemExit("animation set problems:\n  " + "\n  ".join(problems))
    clips = [c for c in args.clips.split(",") if c] or list(anim["clips"])
    rig = build_library(spec, anim, clips, not args.no_export)
    if args.previews:
        previews = args.previews if args.previews.is_absolute() else REPO / args.previews
        report = review(spec, anim, rig, clips, previews, not args.no_sheets)
        out = previews / f"{spec['id']}_clipping.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=1) + "\n")
        print(f"report {out}")


if __name__ == "__main__":
    main()
