"""Compare locomotion clips: foot slide, ground contact and pose sheets (backlog X-01).

    python3 tools/blender/compare_capture.py --clips run,run_capture --variants scratch/variants.json \
        --character char_warblade_carnage --speed 7.0 --out previews/capture

--variants: a JSON file of extra or replacement clips ({"clips": {name: clip}}) merged into the
set for this comparison only, so candidates can be judged before they go into data.

Metrics per clip, measured on the character's skeleton in place (the game moves the root):
- slide: during support (the lower foot, within 5 cm of its lowest point), how far the foot's
  backward speed differs from the running speed, as a share of the speed (0 = planted);
- floor: the lowest foot point over the clip (negative = through the floor);
- bounce: the pelvis height range.
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import animation  # noqa: E402
import build_animations as ba  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402

REPO = common.REPO


def foot_points(rig, build: str) -> dict[str, list]:
    """Heel and toe contact points of each foot in its bone's rest space."""
    from mathutils import Vector

    j = humanoid.joints(humanoid.BUILDS[build])
    out = {}
    for s in ("l", "r"):
        bone = rig.data.bones[f"foot_{s}"]
        inv = bone.matrix_local.inverted()
        heel = Vector((j[f"ankle_{s}"].x, j[f"ankle_{s}"].y + 0.04, 0.0))
        toe = Vector((j[f"toe_{s}"].x, j[f"toe_{s}"].y, 0.0))
        out[s] = [inv @ heel, inv @ toe]
    return out


def measure(rig, anim: dict, clip: str, build: str, speed: float, hold: str | None) -> dict:
    import bpy

    frames = animation.sample_clip(anim, clip, build)
    fps = anim["fps"]
    pts = foot_points(rig, build)
    loop = anim["clips"][clip]["loop"]
    n = len(frames) - (1 if loop else 0)
    low = {s: [] for s in pts}
    pelvis = []
    wrist = animation.wrist_rule(anim, hold, clip, build)
    for f in range(n):
        animation.pose_rig(rig, frames[f], wrist)
        bpy.context.view_layer.update()
        for s, (heel, toe) in pts.items():
            m = rig.pose.bones[f"foot_{s}"].matrix
            hp, tp = m @ heel, m @ toe
            low[s].append(min((hp, tp), key=lambda v: v.z))
        pelvis.append(rig.pose.bones["pelvis"].head.z)
    slides, floor = [], 1e9
    zs = {s: np.array([p.z for p in seq]) for s, seq in low.items()}
    for s, seq in low.items():
        z = zs[s]
        other = zs["r" if s == "l" else "l"]
        y = np.array([p.y for p in seq])
        floor = min(floor, float(z.min()))
        stance = (z <= other) & (z < z.min() + 0.05)  # the supporting foot: the lower one, near the floor
        vy = (np.roll(y, -1) - np.roll(y, 1)) * fps / 2 if loop else np.gradient(y) * fps
        # the character moves toward -Y at `speed`; a planted foot moves toward +Y at the same speed
        err = np.abs(vy[stance] - speed) / speed if speed > 0 else np.abs(vy[stance])
        slides.append(float(np.mean(err)) if len(err) else float("nan"))
        slides.append(float(np.mean(stance)))
    return {"slide_l": round(slides[0], 3), "slide_r": round(slides[2], 3), "stance_share": round((slides[1] + slides[3]) / 2, 2),
            "floor_m": round(floor, 3), "bounce_m": round(float(max(pelvis) - min(pelvis)), 3)}


def main() -> None:
    import bpy  # noqa: F401

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clips", default="run")
    ap.add_argument("--variants", type=Path)
    ap.add_argument("--character", default="char_warblade_carnage")
    ap.add_argument("--speed", type=float, default=7.0)
    ap.add_argument("--out", type=Path, default=Path("previews/capture"))
    ap.add_argument("--no-sheets", action="store_true")
    ap.add_argument("--frames", type=int, default=8)
    args = ap.parse_args()
    anim = copy.deepcopy(animation.load_set("humanoid"))
    if args.variants:
        anim["clips"].update(json.loads(args.variants.read_text())["clips"])
    clips = [c for c in args.clips.split(",") if c]
    out = args.out if args.out.is_absolute() else REPO / args.out
    cs = json.loads((REPO / "data" / "assets" / f"{args.character}.json").read_text())
    build = cs["body_build"]
    common.reset_scene()
    bpy.context.scene.render.fps = anim["fps"]
    rig = humanoid.build_armature(build, "rig_cmp")
    body = ba.load_character(cs, rig)
    weapon, hold = None, None
    wid = cs.get("params", {}).get("weapon")
    if wid:
        ws = json.loads((REPO / "data" / "assets" / f"{wid}.json").read_text())
        weapon = ba.attach_weapon(ws, rig, anim["weapon_grip"], build)
        h = ws.get("params", {}).get("hold", "forward")
        hold = h if h in animation.hold_variants(anim) else None
    report = {}
    for clip in clips:
        report[clip] = measure(rig, anim, clip, build, args.speed if "idle" not in clip else 0.0, hold)
        print(f"METRICS {cs['id']} {clip}: {report[clip]}")
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{cs['id']}_metrics.json").write_text(json.dumps(report, indent=1) + "\n")
    if not args.no_sheets:
        ba.setup_render(240)
        for name, yaw in (("side", 90.0), ("threequarter", -62.0)):
            ba.render_sheet(body, weapon, rig, anim, clips, out / f"{cs['id']}_{name}.png",
                            f"{cs['id']} {name}", cell=240, hold=hold, build=build, yaw=yaw, count=args.frames)


if __name__ == "__main__":
    main()
