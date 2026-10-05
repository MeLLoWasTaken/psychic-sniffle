"""Armor fit check (backlog G-03): does the body show through an armor set in motion?

    python3 tools/blender/check_armor_fit.py --set templar_crusader [--body male,female]
        [--clips idle,run,cast_loop,attack_1] [--out previews/g_03/fit_templar_crusader.json]

For each body type, imports the body and every piece of the set on one skeleton. At rest, a body
vertex counts as covered when an armor surface lies over it within 4 cm along its normal. In
sampled frames of each clip, a covered vertex pokes through when no armor surface lies over it any
more along its normal and armor does not surround it (a vertex folded into a bent joint can have
its normal along the limb, out of a sleeve's open end); the depth is its distance to the piece it
was under. The report lists
pokes per clip and piece; any poke deeper than FAIL_M in a gated clip fails the check.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

import animation  # noqa: E402
import common  # noqa: E402
import render_appearance as ra  # noqa: E402

REPO = common.REPO
COVER_M = 0.04
POKE_M = 0.004
FAIL_M = 0.012
GATED = ["idle", "combat_idle", "run", "cast_loop", "cast_release", "attack_1", "attack_2", "attack_3"]


def evaluated_world(o):
    deps = bpy.context.evaluated_depsgraph_get()
    ev = o.evaluated_get(deps)
    me = ev.to_mesh()
    mw = o.matrix_world
    verts = [mw @ v.co for v in me.vertices]
    normals = [(mw.to_3x3() @ v.normal).normalized() for v in me.vertices]
    polys = [tuple(p.vertices) for p in me.polygons]
    ev.to_mesh_clear()
    return verts, normals, polys


AXES = [Vector(a) for a in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))]


def enclosed(trees: dict, pos) -> bool:
    """Whether armor surrounds a point (rays along five of the six axes meet armor within 30 cm).
    A body vertex folded into a bent elbow or knee can have its normal along the limb, so its
    normal ray runs out of the open end of a sleeve; enclosed, it can not be seen from outside."""
    hits = 0
    for a in AXES:
        for tree in trees.values():
            if tree.ray_cast(pos + a * 0.0005, a, 0.3)[0] is not None:
                hits += 1
                break
    return hits >= 5


def check(body_type: str, set_id: str, clips: list[str], frames_per_clip: int = 8) -> dict:
    common.reset_scene()
    st = json.loads((REPO / "data" / "armor_sets" / f"{set_id}.json").read_text())
    body = ra.Body(body_type)
    for slot in st["pieces"]:
        body.wear(slot, f"{set_id}_{slot}_{body_type}")
    pieces = {slot: [o for o in objs if o.data.materials] for slot, objs in body.pieces.items()}
    anim = animation.load_set("humanoid")
    animation.pose_rig(body.rig, {})
    bpy.context.view_layer.update()
    # rest: a body vertex is covered by the piece whose inner surface its outward ray meets first
    def trees_now():
        out = {}
        for slot, objs in pieces.items():
            vs, ps = [], []
            for o in objs:
                v, _n, p = evaluated_world(o)
                base = len(vs)
                vs += v
                ps += [tuple(i + base for i in poly) for poly in p]
            out[slot] = BVHTree.FromPolygons(vs, ps)
        return out
    bv, bn, _ = evaluated_world(body.mesh)
    trees = trees_now()
    covered: dict[int, str] = {}
    for i, (pos, nrm) in enumerate(zip(bv, bn)):
        best = None
        for slot, tree in trees.items():
            loc, n, _f, dist = tree.ray_cast(pos + nrm * 0.0005, nrm, COVER_M)
            if loc is not None and n.dot(nrm) < 0 and (best is None or dist < best[1]):
                best = (slot, dist)
        if best:
            covered[i] = best[0]
    print(f"  {body_type}: {len(covered)} of {len(bv)} body vertices covered", flush=True)
    report = {"covered": len(covered), "clips": {}}
    for clip in clips:
        frames = animation.sample_clip(anim, clip, body_type)
        picks = sorted({round(k * (len(frames) - 1) / max(frames_per_clip - 1, 1)) for k in range(frames_per_clip)})
        worst: dict[str, dict] = {}
        for f in picks:
            animation.pose_rig(body.rig, frames[f])
            bpy.context.view_layer.update()
            bv, bn, _ = evaluated_world(body.mesh)
            trees = trees_now()
            for i, slot in covered.items():
                # showing through means no piece at all is over it any more (a body point under the
                # hauberk where a spaulder lifted away is still covered)
                hidden = False
                for tree in trees.values():
                    loc, n, _f, dist = tree.ray_cast(bv[i] + bn[i] * 0.0005, bn[i], 0.08)
                    if loc is not None:            # under an armor surface, or inside a plate
                        hidden = True
                        break
                if hidden or enclosed(trees, bv[i]):
                    continue
                tree = trees[slot]
                near = tree.find_nearest(bv[i], 0.1)
                depth = near[3] if near[0] is not None else 0.1
                if depth > POKE_M:
                    w = worst.setdefault(slot, {"count": 0, "depth_m": 0.0, "frame": f})
                    w["count"] += 1
                    if depth > w["depth_m"]:
                        w["depth_m"], w["frame"] = round(depth, 4), f
                        w["at"] = [round(c, 3) for c in bv[i]]   # where (world, posed) the worst one is
        report["clips"][clip] = worst
        print(f"    {clip}: {worst}", flush=True)
    report["failures"] = {c: {s: w for s, w in hits.items() if w["depth_m"] > FAIL_M and w["count"] > 3}
                          for c, hits in report["clips"].items() if c in GATED}
    report["failures"] = {c: v for c, v in report["failures"].items() if v}
    return report


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", required=True)
    ap.add_argument("--body", default="male,female")
    ap.add_argument("--clips", default="idle,combat_idle,run,cast_loop,cast_release,attack_1,attack_2,attack_3")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args(argv)
    out = args.out or REPO / "previews" / "g_03" / f"fit_{args.set}.json"
    out = out if out.is_absolute() else REPO / out
    full = {}
    for t in args.body.split(","):
        full[t] = check(t, args.set, args.clips.split(","))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(full, indent=1) + "\n")
    bad = {t: r["failures"] for t, r in full.items() if r["failures"]}
    print(f"FIT {args.set}: {'clean' if not bad else bad}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
