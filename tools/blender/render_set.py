"""Reference sheets of assembled overhaul characters (backlog G-04 review; G-05 does this in game).

    python3 tools/blender/render_set.py --set templar_crusader --spec templar_vanguard --body male
        [--out previews/g_04] [--face stern] [--hair cropped] [--skin #d3a27d] [--weapon weapon_warhammer]

Imports the body and every piece of the armor set for that body type, recolours the pieces with
the set's dyes for the spec (dye mask: R primary, G secondary, B metal), hides hair and beard
under a helm that hides them, attaches the weapon, and renders the reference-sheet views
(front, three-quarter, side, back in idle, and a three-quarter combat-ready view) like
render_reference.py, plus a 30 m grayscale silhouette next to the old character for comparison.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import animation  # noqa: E402
import build_animations as ba  # noqa: E402
import common  # noqa: E402
import render_appearance as ra  # noqa: E402

REPO = common.REPO
NEUTRAL = {"primary": "#cfc8bc", "secondary": "#d2c4a0", "metal": "#a9adb3"}   # build_piece.MATERIALS
VIEWS = [("Front", 0.0, "idle"), ("Three-quarter", 40.0, "idle"), ("Side", 90.0, "idle"), ("Back", 180.0, "idle"),
         ("Ready", 35.0, "combat_idle")]


def dye(obj, mask_path: Path, dyes: dict) -> None:
    """Multiply each dye channel's region toward its colour, as the character shader will."""
    for mat in obj.data.materials:
        nt = mat.node_tree
        bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
        src = bsdf.inputs["Base Color"].links[0].from_socket
        mask = nt.nodes.new("ShaderNodeTexImage")
        mask.image = bpy.data.images.load(str(mask_path))
        mask.image.colorspace_settings.name = "Non-Color"
        uv = nt.nodes.new("ShaderNodeUVMap")
        nt.links.new(uv.outputs["UV"], mask.inputs["Vector"])
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(mask.outputs["Color"], sep.inputs["Color"])
        cur = src
        for chan, out in (("primary", "Red"), ("secondary", "Green"), ("metal", "Blue")):
            n = common.hex_to_linear(NEUTRAL[chan])
            c = common.hex_to_linear(dyes[chan])
            rgb = nt.nodes.new("ShaderNodeRGB")
            rgb.outputs[0].default_value = (c[0] / n[0], c[1] / n[1], c[2] / n[2], 1.0)
            mix = nt.nodes.new("ShaderNodeMix")
            mix.data_type = "RGBA"
            mix.blend_type = "MULTIPLY"
            nt.links.new(cur, mix.inputs[6])
            nt.links.new(rgb.outputs[0], mix.inputs[7])
            nt.links.new(sep.outputs[out], mix.inputs["Factor"])
            cur = mix.outputs[2]
        nt.links.new(cur, bsdf.inputs["Base Color"])


def assemble(body_type: str, set_id: str, spec_id: str, face: str, hair: str, skin: str, weapon_id: str | None,
             offhand: str | None = None):
    st = json.loads((REPO / "data" / "armor_sets" / f"{set_id}.json").read_text())
    dyes = st["dyes"].get(spec_id, st["dyes"]["default"])
    body = ra.Body(body_type)
    body.set_colors(skin, "#4a2c18")
    body.set_face(face)
    hides = set()
    for slot, piece in st["pieces"].items():
        hides |= set(piece.get("hides", []))
    if "hair" not in hides and hair != "none":
        body.wear("hair", f"hair_{hair}_{body_type}")
    for slot in st["pieces"]:
        pid = f"{set_id}_{slot}_{body_type}"
        body.wear(slot, pid)
        for o in body.pieces.get(slot, []):
            if not o.data.materials:
                print(f"  {o.name}: no material", flush=True)
                continue
            # undo the hair tint render_appearance adds, then dye
            mat = o.data.materials[0]
            nt = mat.node_tree
            bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
            mix = bsdf.inputs["Base Color"].links[0].from_node
            if mix.type == "MIX":
                nt.links.new(mix.inputs[6].links[0].from_socket, bsdf.inputs["Base Color"])
            dye(o, REPO / "game" / "assets" / "armor" / f"{pid}_dye.png", dyes)
    if offhand:
        pid = f"{offhand}_{body_type}"
        body.wear("offhand", pid)
        for o in body.pieces.get("offhand", []):
            if not o.data.materials:
                continue
            mat = o.data.materials[0]
            nt = mat.node_tree
            bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
            mix = bsdf.inputs["Base Color"].links[0].from_node
            if mix.type == "MIX":
                nt.links.new(mix.inputs[6].links[0].from_socket, bsdf.inputs["Base Color"])
            dye(o, REPO / "game" / "assets" / "armor" / f"{pid}_dye.png", dyes)
    weapon = None
    anim = animation.load_set("humanoid")
    if weapon_id:
        ws = json.loads((REPO / "data" / "assets" / f"{weapon_id}.json").read_text())
        if (REPO / ws["out"]).exists():
            weapon = ba.attach_weapon(ws, body.rig, anim["weapon_grip"], body_type)
    return body, weapon, anim, (ws.get("params", {}).get("hold") if weapon_id else None)


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", required=True)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--body", default="male")
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "g_04")
    ap.add_argument("--face", default="stern")
    ap.add_argument("--hair", default="cropped")
    ap.add_argument("--skin", default="#c99a78")
    ap.add_argument("--weapon", default="")
    ap.add_argument("--offhand", default="", help="an off-hand piece id without the body type, e.g. shield_templar_kite")
    ap.add_argument("--samples", type=int, default=24)
    args = ap.parse_args(argv)
    out = args.out if args.out.is_absolute() else REPO / args.out
    out.mkdir(parents=True, exist_ok=True)
    common.reset_scene()
    common.setup_lighting()
    bpy.ops.mesh.primitive_plane_add(size=400)
    bpy.context.active_object.data.materials.append(common.painted_material("_ground", "#2a2723", roughness=0.95,
                                                                             edge_highlight=0))
    body, weapon, anim, hold = assemble(args.body, args.set, args.spec, args.face, args.hair, args.skin, args.weapon or None,
                                         args.offhand or None)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = "AgX"
    W, H = 600, 760
    scene.render.resolution_x, scene.render.resolution_y = W, H
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.type = "ORTHO"
    cam.data.sensor_fit = "VERTICAL"
    cam.data.ortho_scale = 2.35
    tiles = []
    for label, yaw, clip in VIEWS:
        frames = animation.sample_clip(anim, clip, args.body)
        wrist = animation.wrist_rule(anim, hold, clip, args.body) if hold else None
        animation.pose_rig(body.rig, frames[min(6, len(frames) - 1)], wrist)
        bpy.context.view_layer.update()
        a = math.radians(yaw)
        centre = Vector((0, 0, 1.05))
        cam.rotation_euler = (math.radians(82), 0, a)
        view = cam.rotation_euler.to_matrix() @ Vector((0, 0, -1))
        cam.location = centre - view * 20.0
        p = out / f"_{args.spec}_{args.body}_{label}.png"
        scene.render.filepath = str(p)
        bpy.ops.render.render(write_still=True)
        tiles.append((label, p))
    from PIL import Image, ImageDraw, ImageFont
    head = 70
    img = Image.new("RGB", (W * len(tiles), H + head), (24, 22, 26))
    d = ImageDraw.Draw(img)
    fonts = REPO / "game" / "assets" / "fonts"
    title = ImageFont.truetype(str(fonts / "cinzel" / "Cinzel-Variable.ttf"), 34)
    small = ImageFont.truetype(str(fonts / "firasans" / "FiraSans-Medium.ttf"), 19)
    st = json.loads((REPO / "data" / "armor_sets" / f"{args.set}.json").read_text())
    tris = sum(common.triangle_count([o]) for o in [body.mesh] + [p for v in body.pieces.values() for p in v])
    d.text((24, 10), f"{st['name']} · {args.spec.replace('_', ' ').title()} · {args.body}", font=title, fill=(236, 228, 210))
    d.text((26, 46), f"{tris:,} triangles with the body (weapon not counted)", font=small, fill=(176, 168, 156))
    for i, (label, p) in enumerate(tiles):
        img.paste(Image.open(p).convert("RGB"), (i * W, head))
        d.text((i * W + 14, head + 8), label, font=small, fill=(236, 228, 210))
        p.unlink()
    path = out / f"{args.set}_{args.spec}_{args.body}.png"
    img.save(path)
    print("saved", path, "tris", tris, flush=True)


if __name__ == "__main__":
    main()
