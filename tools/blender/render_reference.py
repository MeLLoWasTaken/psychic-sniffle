"""Reference sheets: one image per specialization's character (codex and art reviews).

    python3 tools/blender/render_reference.py [--out previews/reference] [--only char_templar_zealot,...]

For every built character (data/assets, kind "character") with its weapon: four orthographic views
in the idle pose (front, three-quarter, side, back) and a three-quarter view in the combat-ready stance, rendered
alone in the arena lighting preset, then laid out on one labelled sheet,
<out>/<spec id>.png, with the class and spec names, role and triangle count.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Euler, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import animation  # noqa: E402
import common  # noqa: E402
import render_lineup as rl  # noqa: E402

REPO = common.REPO
VIEWS = [("Front", 0.0, "idle"), ("Three-quarter", 40.0, "idle"), ("Side", 90.0, "idle"), ("Back", 180.0, "idle"),
         ("Ready", 35.0, "combat_idle")]
PANEL_W, PANEL_H = 600, 760
FONTS = REPO / "game" / "assets" / "fonts"


def measure(c: dict, angle_deg: float) -> tuple[float, float]:
    """Height of the character with its weapon, and its half width seen from `angle_deg`."""
    deps = bpy.context.evaluated_depsgraph_get()
    objs = [o for o in (c["body"], c["weapon"]) if o]
    pts = [o.evaluated_get(deps).matrix_world @ Vector(b) for o in objs for b in o.evaluated_get(deps).bound_box]
    a = math.radians(angle_deg)
    across = Vector((math.cos(a), math.sin(a), 0.0))             # the camera's horizontal axis
    return max(p.z for p in pts), max(abs((p - c["rig"].location).dot(across)) for p in pts)


def fit_scale(top: float, half_w: float) -> float:
    """Orthographic height that shows the whole figure; a weapon reaching past 1 m to the side
    may be cut at the panel edge rather than shrinking the figure."""
    return max(top * 1.12, (2 * min(half_w, 1.0) + 0.2) / (PANEL_W / PANEL_H))


def frame_camera(c: dict, angle_deg: float, scale: float, top: float):
    """Orthographic camera circling the character at `angle_deg` (0 = in front; it faces -Y)."""
    scene = bpy.context.scene
    cam = bpy.data.objects.get("_ref_cam") or bpy.data.objects.new("_ref_cam", bpy.data.cameras.new("_ref_cam"))
    if cam.name not in scene.collection.objects:
        scene.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.sensor_fit = "VERTICAL"
    cam.data.ortho_scale = scale
    a = math.radians(angle_deg)
    centre = c["rig"].location + Vector((0, 0, top * 0.5))
    cam.rotation_euler = Euler((math.radians(82), 0, a))       # tipped 8 degrees down, so the floor shows
    view = cam.rotation_euler.to_matrix() @ Vector((0, 0, -1))
    cam.location = centre - view * 20.0
    scene.camera = cam
    scene.render.resolution_x, scene.render.resolution_y = PANEL_W, PANEL_H


def sheet(spec: dict, cs: dict, panels: list, out: Path) -> None:
    from PIL import Image, ImageDraw, ImageFont

    cls = json.loads((REPO / "data" / "classes" / f"{spec['class']}.json").read_text())
    head = 92
    img = Image.new("RGB", (PANEL_W * len(panels), PANEL_H + head), (24, 22, 26))
    d = ImageDraw.Draw(img)
    title = ImageFont.truetype(str(FONTS / "cinzel" / "Cinzel-Variable.ttf"), 40)
    small = ImageFont.truetype(str(FONTS / "firasans" / "FiraSans-Medium.ttf"), 20)
    colour = cls.get("color", "#cccccc")
    d.rectangle([0, 0, 10, head], fill=colour)
    d.text((28, 12), f"{spec['name']} {cls['name']}", font=title, fill=(236, 228, 210))
    facts = f"{spec['role'].upper()} · {spec.get('range', '')} · {cls['armor']} · {spec['description']}"
    d.text((30, 60), facts, font=small, fill=(176, 168, 156))
    for i, (label, path) in enumerate(panels):
        p = Image.open(path).convert("RGB")
        img.paste(p, (i * PANEL_W, head))
        d.text((i * PANEL_W + 16, head + 10), label, font=small, fill=(236, 228, 210))
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "reference")
    ap.add_argument("--only", default="", help="comma-separated character asset ids")
    ap.add_argument("--samples", type=int, default=32)
    args = ap.parse_args()
    out = args.out if args.out.is_absolute() else REPO / args.out
    anim = animation.load_set("humanoid")
    cast = rl.load_all(anim)
    common.setup_lighting()
    bpy.ops.mesh.primitive_plane_add(size=400, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.name = "_preview_ground"
    ground.data.materials.append(common.painted_material("_ground", "#2a2723", roughness=0.95, edge_highlight=0))
    only = {s for s in args.only.split(",") if s}
    tmp = out / "_panels"
    tmp.mkdir(parents=True, exist_ok=True)
    for c in cast:
        cs = c["spec"]
        if only and cs["id"] not in only:
            continue
        for o in cast:  # render this character alone
            for obj in (o["body"], o["weapon"]):
                if obj:
                    obj.hide_render = o is not c
        panels = []
        rl.pose_all([c], anim, "idle", 0.2)
        sizes = [measure(c, ang) for _l, ang, clip in VIEWS if clip == "idle"]
        idle_top = max(t for t, _w in sizes)
        idle_scale = fit_scale(idle_top, max(w for _t, w in sizes))
        for label, angle, clip in VIEWS:
            rl.pose_all([c], anim, clip, 0.2)
            if clip == "idle":   # one scale for the four turnaround views, so they compare
                frame_camera(c, angle, idle_scale, idle_top)
            else:
                top, half_w = measure(c, angle)
                frame_camera(c, angle, fit_scale(top, half_w), top)
            path = tmp / f"{cs['id']}_{label.lower().replace('-', '_')}.png"
            rl.render(path, args.samples)
            panels.append((label, path))
        spec = json.loads((REPO / "data" / "specs" / f"{cs['spec']}.json").read_text())
        sheet(spec, cs, panels, out / f"{cs['spec']}.png")
        print(f"REFERENCE {cs['spec']} -> {out / (cs['spec'] + '.png')}", flush=True)


if __name__ == "__main__":
    main()
