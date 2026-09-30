"""Character lineup and silhouette test (backlog M1-22, and every review pass).

    python3 tools/blender/render_lineup.py [--out previews/lineup] [--clips idle,run] [--frame-time 0.2]

For every built character (data/assets, kind "character") with its weapon, posed from the
animation set:
- blender_lineup_<clip>.png: color render in the arena lighting preset;
- silhouettes_<clip>.png: black shapes at the size a character appears 30 m from the game camera
  (about 45 px tall at 1080p), enlarged with square pixels so the shapes can be judged;
- grayscale_<clip>.png: the color render at the same small size, without color;
- silhouettes.json: pairwise overlap (intersection over union) of the full-size silhouettes,
  feet aligned. Lower is more distinct.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import animation  # noqa: E402
import build_animations as ba  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402

REPO = common.REPO
SPACING_M = 1.6
GAME_FOV_DEG = 75.0     # Godot's default vertical field of view, used by the game camera
DISTANCE_M = 30.0
SCREEN_H = 1080


def characters() -> list[dict]:
    out = []
    for p in sorted((REPO / "data" / "assets").glob("char_*.json")):
        s = json.loads(p.read_text())
        if s["kind"] == "character" and (REPO / s["out"]).exists():
            out.append(s)
    return out


def load_all(anim: dict):
    common.reset_scene()
    bpy.context.scene.render.fps = anim["fps"]
    cast = []
    specs = characters()
    for i, cs in enumerate(specs):
        rig = humanoid.build_armature(cs["body_build"], f"rig_{cs['id']}")
        body = ba.load_character(cs, rig)
        weapon, hold = None, None
        wid = cs.get("params", {}).get("weapon")
        if wid:
            ws = json.loads((REPO / "data" / "assets" / f"{wid}.json").read_text())
            if (REPO / ws["out"]).exists():
                weapon = ba.attach_weapon(ws, rig, anim["weapon_grip"], cs["body_build"])
                h = ws.get("params", {}).get("hold", "forward")
                hold = h if h in animation.hold_variants(anim) else None
        mw = body.matrix_world.copy()
        body.parent = rig
        body.matrix_world = mw
        rig.location.x = (i - (len(specs) - 1) / 2) * SPACING_M
        cast.append({"spec": cs, "rig": rig, "body": body, "weapon": weapon, "hold": hold})
    return cast


def pose_all(cast, anim: dict, clip: str, t: float) -> None:
    for c in cast:
        frames = animation.sample_clip(anim, clip, c["spec"]["body_build"])
        f = min(int(round(t * anim["fps"])), len(frames) - 1)
        bpy.context.view_layer.objects.active = c["rig"]
        animation.pose_rig(c["rig"], frames[f], animation.wrist_rule(anim, c["hold"], clip, c["spec"]["body_build"]))
    bpy.context.view_layer.update()


def camera(cast, px_per_m: float):
    """Orthographic front camera (the characters face -Y) framing everyone."""
    objs = [o for c in cast for o in (c["body"], c["weapon"]) if o]
    deps = bpy.context.evaluated_depsgraph_get()
    pts = [o.evaluated_get(deps).matrix_world @ Vector(b) for o in objs for b in o.evaluated_get(deps).bound_box]
    lo = Vector((min(p.x for p in pts), 0, min(0.0, min(p.z for p in pts))))
    hi = Vector((max(p.x for p in pts), 0, max(p.z for p in pts)))
    w, h = (hi.x - lo.x) + 0.6, (hi.z - lo.z) + 0.4
    scene = bpy.context.scene
    cam = bpy.data.objects.get("_lineup_cam") or bpy.data.objects.new("_lineup_cam", bpy.data.cameras.new("_lineup_cam"))
    if cam.name not in scene.collection.objects:
        scene.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = max(w, h)
    cam.location = Vector(((lo.x + hi.x) / 2, -20.0, (lo.z + hi.z) / 2))
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.camera = cam
    scene.render.resolution_x = int(round(w * px_per_m))
    scene.render.resolution_y = int(round(h * px_per_m))
    return lo, hi


def render(path: Path, samples: int = 32, silhouette: bool = False) -> np.ndarray:
    from PIL import Image

    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 1 if silhouette else samples
    scene.cycles.use_denoising = not silhouette
    scene.render.filepath = str(path)
    vl = bpy.context.view_layer
    if silhouette:
        black = bpy.data.materials.get("_silhouette") or bpy.data.materials.new("_silhouette")
        black.use_nodes = True
        nt = black.node_tree
        nt.nodes.clear()
        em = nt.nodes.new("ShaderNodeEmission")
        em.inputs["Color"].default_value = (0, 0, 0, 1)
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        nt.links.new(em.outputs[0], out.inputs[0])
        vl.material_override = black
        world = bpy.data.worlds.new("_white")
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
        world.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
        prev_world = scene.world
        scene.world = world
        prev_view = scene.view_settings.view_transform
        scene.view_settings.view_transform = "Standard"
        hidden = [o for o in scene.objects if o.type == "LIGHT" or o.name.startswith("_preview_ground")]
        for o in hidden:
            o.hide_render = True
    bpy.ops.render.render(write_still=True)
    if silhouette:
        vl.material_override = None
        scene.world = prev_world
        scene.view_settings.view_transform = prev_view
        for o in hidden:
            o.hide_render = False
    return np.asarray(Image.open(path).convert("L"), dtype=np.float32) / 255.0


def small(img: np.ndarray, factor: float, enlarge: int):
    """Shrink to the 30 m size (area filter), then enlarge with square pixels for viewing."""
    from PIL import Image

    im = Image.fromarray((img * 255).astype(np.uint8))
    w, h = im.size
    s = im.resize((max(1, int(w * factor)), max(1, int(h * factor))), Image.LANCZOS)
    return s.resize((s.size[0] * enlarge, s.size[1] * enlarge), Image.NEAREST)


def overlaps(mask: np.ndarray, cast, lo, px_per_m: float) -> dict:
    """Pairwise intersection over union of each character's silhouette, cut out around its own
    position and aligned at the feet centre."""
    h, w = mask.shape
    half = int(SPACING_M / 2 * px_per_m)
    crops = {}
    for c in cast:
        cx = int(round((c["rig"].location.x - lo.x + 0.3) * px_per_m))
        crops[c["spec"]["id"]] = mask[:, max(0, cx - half):min(w, cx + half)]
    out = {}
    ids = list(crops)
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            a, b = crops[ids[i]], crops[ids[j]]
            n = min(a.shape[1], b.shape[1])
            a, b = a[:, :n], b[:, :n]
            inter = np.logical_and(a, b).sum()
            union = np.logical_or(a, b).sum()
            out[f"{ids[i]}/{ids[j]}"] = round(float(inter / max(union, 1)), 3)
    return out


def main() -> None:
    from PIL import Image

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path("previews/lineup"))
    ap.add_argument("--clips", default="idle,run")
    ap.add_argument("--frame-time", type=float, default=0.2)
    ap.add_argument("--samples", type=int, default=32)
    args = ap.parse_args()
    out = args.out if args.out.is_absolute() else REPO / args.out
    out.mkdir(parents=True, exist_ok=True)
    anim = animation.load_set("humanoid")
    cast = load_all(anim)
    common.setup_lighting()
    bpy.ops.mesh.primitive_plane_add(size=60, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.name = "_preview_ground"
    ground.data.materials.append(common.painted_material("_ground", "#2a2723", roughness=0.95, edge_highlight=0))
    px_per_m = 160.0
    # a 1.9 m character at 30 m with the game camera is this many pixels tall at 1080p
    far_px_per_m = SCREEN_H / (2 * DISTANCE_M * math.tan(math.radians(GAME_FOV_DEG / 2)))
    report = {"distance_m": DISTANCE_M, "fov_deg": GAME_FOV_DEG, "px_per_m_at_distance": round(far_px_per_m, 2),
              "clips": {}}
    for clip in [c for c in args.clips.split(",") if c]:
        pose_all(cast, anim, clip, args.frame_time if anim["clips"][clip]["loop"] else 0.0)
        lo, _hi = camera(cast, px_per_m)
        color_path = out / f"blender_lineup_{clip}.png"
        render(color_path, args.samples)
        sil = render(out / f"_sil_{clip}.png", silhouette=True)
        mask = sil < 0.5
        factor = far_px_per_m / px_per_m
        small(sil, factor, 6).save(out / f"silhouettes_{clip}.png")
        gray = np.asarray(Image.open(color_path).convert("L"), dtype=np.float32) / 255.0
        small(gray, factor, 6).save(out / f"grayscale_{clip}.png")
        (out / f"_sil_{clip}.png").unlink()
        report["clips"][clip] = {"iou": overlaps(mask, cast, lo, px_per_m),
                                 "height_px_at_distance": round(float(mask.any(axis=1).sum()) * factor, 1)}
        print(f"LINEUP {clip}: {report['clips'][clip]}")
    (out / "silhouettes.json").write_text(json.dumps(report, indent=1) + "\n")


if __name__ == "__main__":
    main()
