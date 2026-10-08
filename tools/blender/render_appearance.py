"""Sheets of the character creator's options on the built bodies (backlog G-02 review).

    python3 tools/blender/render_appearance.py --out previews/g_02 [--sheets faces,hair,beards,colors]

Imports the built body (data/assets body_<type>) and pieces (hair_<style>_<type>, beard_<style>_male),
recolours them the way the game's character shader will (skin tone over the skin mask, iris colour
over the iris mask, hair colour over the hair texture), and renders labelled grids:
- faces: every face preset on both body types;
- hair: every hair style on both body types;
- beards: every beard on the male body;
- colors: skin tones, hair colours and eye colours.
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

import common  # noqa: E402

REPO = common.REPO
OPTS = {k: json.loads((REPO / "data" / "appearance" / f"{k}.json").read_text())["options"]
        for k in ("faces", "hair", "beards", "skin_tones", "hair_colors", "eye_colors", "markings")}


def hex_rgb(h: str):
    return common.hex_to_linear(h)


def asset_path(asset_id: str) -> Path:
    """Where an asset's built model is (its spec's "out")."""
    spec = json.loads((REPO / "data" / "assets" / f"{asset_id}.json").read_text())
    return REPO / spec["out"]


def import_glb(path: Path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    return [o for o in bpy.data.objects if o not in before]


class Body:
    def __init__(self, body_type: str):
        self.type = body_type
        objs = import_glb(asset_path(f"body_{body_type}"))
        self.mesh = next(o for o in objs if o.type == "MESH")
        self.rig = next(o for o in objs if o.type == "ARMATURE")
        self.pieces: dict[str, list] = {}
        self._skin_material()

    def _skin_material(self):
        mat = self.mesh.data.materials[0]
        nt = mat.node_tree
        bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
        albedo = bsdf.inputs["Base Color"].links[0].from_socket
        mask = nt.nodes.new("ShaderNodeTexImage")
        mask.image = bpy.data.images.load(str(REPO / "game" / "assets" / "characters" / f"body_{self.type}_mask.png"))
        mask.image.colorspace_settings.name = "Non-Color"
        uv = nt.nodes.new("ShaderNodeUVMap")
        nt.links.new(uv.outputs["UV"], mask.inputs["Vector"])
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(mask.outputs["Color"], sep.inputs["Color"])
        # skin: albedo / neutral * tone, over the skin mask
        self.tone = nt.nodes.new("ShaderNodeRGB")
        skin = nt.nodes.new("ShaderNodeMix")
        skin.data_type = "RGBA"
        skin.blend_type = "MULTIPLY"
        nt.links.new(albedo, skin.inputs[6])
        nt.links.new(self.tone.outputs[0], skin.inputs[7])
        nt.links.new(sep.outputs["Green"], skin.inputs["Factor"])
        # lips (mask B) and eyebrows (face R), as the skin shader paints them
        lip = nt.nodes.new("ShaderNodeMix")
        lip.data_type = "RGBA"
        lip.blend_type = "MULTIPLY"
        lip.inputs[7].default_value = (0.86, 0.6, 0.6, 1.0)
        lipf = nt.nodes.new("ShaderNodeMath")
        lipf.operation = "MULTIPLY"
        lipf.inputs[1].default_value = 0.7
        nt.links.new(sep.outputs["Blue"], lipf.inputs[0])
        nt.links.new(skin.outputs[2], lip.inputs[6])
        nt.links.new(lipf.outputs[0], lip.inputs["Factor"])
        face = nt.nodes.new("ShaderNodeTexImage")
        face_path = REPO / "game" / "assets" / "characters" / f"body_{self.type}_face.png"
        if face_path.exists():
            face.image = bpy.data.images.load(str(face_path))
            face.image.colorspace_settings.name = "Non-Color"
        nt.links.new(uv.outputs["UV"], face.inputs["Vector"])
        fsep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(face.outputs["Color"], fsep.inputs["Color"])
        browf = nt.nodes.new("ShaderNodeMath")
        browf.operation = "MULTIPLY"
        browf.use_clamp = True
        browf.inputs[1].default_value = 1.15
        nt.links.new(fsep.outputs["Red"], browf.inputs[0])
        self.brow = nt.nodes.new("ShaderNodeRGB")
        brow = nt.nodes.new("ShaderNodeMix")
        brow.data_type = "RGBA"
        nt.links.new(lip.outputs[2], brow.inputs[6])
        nt.links.new(self.brow.outputs[0], brow.inputs[7])
        nt.links.new(browf.outputs[0], brow.inputs["Factor"])
        self.brow.outputs[0].default_value = (0.16, 0.1, 0.06, 1.0)
        # iris
        self.iris = nt.nodes.new("ShaderNodeRGB")
        iris = nt.nodes.new("ShaderNodeMix")
        iris.data_type = "RGBA"
        iris.blend_type = "MULTIPLY"
        nt.links.new(brow.outputs[2], iris.inputs[6])
        nt.links.new(self.iris.outputs[0], iris.inputs[7])
        nt.links.new(sep.outputs["Red"], iris.inputs["Factor"])
        # markings: one channel of marks_a or marks_b, picked by two weight vectors, in a paint colour
        dots = []
        self.mark_w = []
        for suffix in ("marks_a", "marks_b"):
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = bpy.data.images.load(str(REPO / "game" / "assets" / "characters" / f"body_{self.type}_{suffix}.png"))
            tex.image.colorspace_settings.name = "Non-Color"
            nt.links.new(uv.outputs["UV"], tex.inputs["Vector"])
            dot = nt.nodes.new("ShaderNodeVectorMath")
            dot.operation = "DOT_PRODUCT"
            nt.links.new(tex.outputs["Color"], dot.inputs[0])
            dot.inputs[1].default_value = (0.0, 0.0, 0.0)
            self.mark_w.append(dot.inputs[1])
            dots.append(dot)
        add = nt.nodes.new("ShaderNodeMath")
        nt.links.new(dots[0].outputs["Value"], add.inputs[0])
        nt.links.new(dots[1].outputs["Value"], add.inputs[1])
        self.paint = nt.nodes.new("ShaderNodeRGB")
        mark = nt.nodes.new("ShaderNodeMix")
        mark.data_type = "RGBA"
        nt.links.new(iris.outputs[2], mark.inputs[6])
        nt.links.new(self.paint.outputs[0], mark.inputs[7])
        nt.links.new(add.outputs[0], mark.inputs["Factor"])
        nt.links.new(mark.outputs[2], bsdf.inputs["Base Color"])
        self.set_colors("#e3b897", "#4a2c18")
        self.set_marking("none")

    MARKS = ["brow_scar", "cheek_scar", "lip_scar", "stripes", "eye_band", "jaw_lines"]

    def set_marking(self, mark: str, paint_hex: str = "#2b3a52"):
        """Scars take a pale, raised-skin colour; paint takes `paint_hex`."""
        for w in self.mark_w:
            w.default_value = (0.0, 0.0, 0.0)
        if mark in self.MARKS:
            i = self.MARKS.index(mark)
            vec = [0.0, 0.0, 0.0]
            vec[i % 3] = 0.85 if "scar" in mark else 0.95
            self.mark_w[i // 3].default_value = vec
            opt = next((o for o in OPTS["markings"] if o["id"] == mark), {})
            c = hex_rgb(opt.get("color", paint_hex))
            self.paint.outputs[0].default_value = (c[0], c[1], c[2], 1.0)

    def set_colors(self, skin_hex: str, iris_hex: str):
        # the baked albedo is a neutral skin (#b08a70); the tone node scales it toward the chosen tone
        neutral = hex_rgb("#b08a70")
        t = hex_rgb(skin_hex)
        self.tone.outputs[0].default_value = (t[0] / neutral[0], t[1] / neutral[1], t[2] / neutral[2], 1.0)
        i = hex_rgb(iris_hex)
        self.iris.outputs[0].default_value = (i[0] * 4.5, i[1] * 4.5, i[2] * 4.5, 1.0)   # the baked iris is a dark grey

    def set_face(self, face: str):
        keys = self.mesh.data.shape_keys
        for kb in (keys.key_blocks if keys else []):
            kb.value = 1.0 if kb.name == f"face_{face}" else 0.0
        for objs in self.pieces.values():
            for o in objs:
                k = o.data.shape_keys
                for kb in (k.key_blocks if k else []):
                    kb.value = 1.0 if kb.name == f"face_{face}" else 0.0

    def wear(self, slot: str, piece_id: str | None, color_hex: str = "#5e3d26"):
        if slot == "hair":   # eyebrows: a darker shade of the hair colour (character_assembler)
            c = hex_rgb(color_hex)
            self.brow.outputs[0].default_value = (c[0] * 0.27, c[1] * 0.27, c[2] * 0.27, 1.0)   # 0.55 in sRGB
        for o in self.pieces.pop(slot, []):
            bpy.data.objects.remove(o, do_unlink=True)
        if not piece_id:
            return
        path = asset_path(piece_id)
        if not path.exists():
            print(f"  missing {path.name}")
            return
        objs = import_glb(path)
        keep = []
        for o in objs:
            if o.type == "ARMATURE":
                bpy.data.objects.remove(o, do_unlink=True)
                continue
            for m in o.modifiers:
                if m.type == "ARMATURE":
                    m.object = self.rig
            mw = o.matrix_world.copy()
            o.parent = self.rig
            o.matrix_world = mw
            self._tint(o, color_hex)
            keep.append(o)
        self.pieces[slot] = keep

    @staticmethod
    def _tint(o, color_hex: str):
        for mat in o.data.materials:
            nt = mat.node_tree
            bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
            src = bsdf.inputs["Base Color"].links[0].from_socket
            neutral = hex_rgb("#b4aa9e")
            c = hex_rgb(color_hex)
            rgb = nt.nodes.new("ShaderNodeRGB")
            rgb.outputs[0].default_value = (c[0] / neutral[0], c[1] / neutral[1], c[2] / neutral[2], 1.0)
            mul = nt.nodes.new("ShaderNodeMix")
            mul.data_type = "RGBA"
            mul.blend_type = "MULTIPLY"
            mul.inputs["Factor"].default_value = 1.0
            nt.links.new(src, mul.inputs[6])
            nt.links.new(rgb.outputs[0], mul.inputs[7])
            nt.links.new(mul.outputs[2], bsdf.inputs["Base Color"])

    def show(self, on: bool):
        for o in [self.mesh] + [p for v in self.pieces.values() for p in v]:
            o.hide_render = not on


def setup(cell: int, samples: int):
    common.reset_scene()
    scene = bpy.context.scene
    common.setup_lighting("dusk_grim")
    fill = bpy.data.objects.new("fill", bpy.data.lights.new("fill", type="SUN"))
    fill.data.energy = 2.0
    fill.rotation_euler = (math.radians(68), 0, math.radians(22))
    scene.collection.objects.link(fill)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.lens = 85
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = "AgX"
    scene.render.resolution_x = scene.render.resolution_y = cell
    return scene, cam


def shoot(scene, cam, body: Body, yaw: float, out: Path, dist: float = 1.35) -> Path:
    top = max((body.mesh.matrix_world @ v.co).z for v in body.mesh.data.vertices)
    centre = Vector((0, 0.0, top - 0.13))
    a = math.radians(yaw)
    d = Vector((math.sin(a), -math.cos(a), 0.06)).normalized()
    if dist < 1.0:   # close-ups look at the eyes
        centre = centre + Vector((0, 0, 0.0))
    cam.location = centre + d * dist
    cam.rotation_euler = (centre - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = str(out)
    bpy.ops.render.render(write_still=True)
    return out


def grid(rows: list[tuple[str, list[tuple[str, Path]]]], cell: int, out: Path, title: str):
    from PIL import Image, ImageDraw
    cols = max(len(r[1]) for r in rows)
    lw = 110
    img = Image.new("RGB", (lw + cols * cell, 30 + len(rows) * (cell + 18)), (18, 18, 20))
    d = ImageDraw.Draw(img)
    d.text((8, 8), title, fill=(230, 230, 230))
    for r, (label, tiles) in enumerate(rows):
        y = 30 + r * (cell + 18)
        d.text((8, y + cell // 2), label, fill=(220, 220, 220))
        for c, (cap, p) in enumerate(tiles):
            img.paste(Image.open(p).convert("RGB"), (lw + c * cell, y + 18))
            d.text((lw + c * cell + 4, y + 3), cap, fill=(200, 200, 140))
            p.unlink()
    img.save(out)
    print("saved", out, flush=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--sheets", default="faces,hair,beards,colors")
    ap.add_argument("--cell", type=int, default=280)
    ap.add_argument("--samples", type=int, default=12)
    args = ap.parse_args(argv)
    out = args.out if args.out.is_absolute() else REPO / args.out
    out.mkdir(parents=True, exist_ok=True)
    scene, cam = setup(args.cell, args.samples)
    bodies = {t: Body(t) for t in ("male", "female")}
    tmp = out / "_tiles"
    tmp.mkdir(exist_ok=True)

    def only(b):
        for x in bodies.values():
            x.show(x is b)
    sheets = args.sheets.split(",")
    if "faces" in sheets:
        rows = []
        for t, b in bodies.items():
            only(b)
            b.wear("hair", f"hair_cropped_{t}")
            tiles = []
            for f in OPTS["faces"]:
                b.set_face(f["id"])
                tiles.append((f["name"], shoot(scene, cam, b, 20, tmp / f"f_{t}_{f['id']}.png")))
            b.set_face("neutral")
            rows.append((t, tiles))
        grid(rows, args.cell, out / "creator_faces.png", "Face presets (cropped hair)")
    if "closeup" in sheets:   # faces large enough to judge the painted detail (G-16)
        rows = []
        for t, b in bodies.items():
            only(b)
            b.wear("hair", f"hair_cropped_{t}")
            for face in ("neutral", "stern" if t == "male" else "sharp"):
                b.set_face(face)
                tiles = [(f"{face} {yaw}", shoot(scene, cam, b, yaw, tmp / f"c_{t}_{face}_{yaw}.png", dist=0.55))
                         for yaw in (0, 30, 75)]
                rows.append((f"{t} {face}", tiles))
            b.set_face("neutral")
        grid(rows, args.cell, out / "creator_closeup.png", "Face close-ups (baked textures)")
    if "hair" in sheets:
        rows = []
        for t, b in bodies.items():
            only(b)
            for yaw in (25, 150):
                tiles = []
                for h in OPTS["hair"]:
                    b.wear("hair", None if h["id"] == "none" else f"hair_{h['id']}_{t}")
                    tiles.append((h["name"], shoot(scene, cam, b, yaw, tmp / f"h_{t}_{h['id']}_{yaw}.png")))
                rows.append((f"{t} {'front' if yaw < 90 else 'back'}", tiles))
        grid(rows, args.cell, out / "creator_hair.png", "Hair styles")
    if "beards" in sheets:
        b = bodies["male"]
        only(b)
        b.wear("hair", "hair_swept_male")
        rows = []
        for face in ("neutral", "broad", "gaunt"):
            b.set_face(face)
            tiles = []
            for bd in OPTS["beards"]:
                b.wear("beard", None if bd["id"] == "none" else f"beard_{bd['id']}_male")
                b.set_face(face)
                tiles.append((bd["name"], shoot(scene, cam, b, 25, tmp / f"b_{face}_{bd['id']}.png")))
            rows.append((face, tiles))
        b.wear("beard", None)
        grid(rows, args.cell, out / "creator_beards.png", "Beards (rows: face presets they follow)")
    if "colors" in sheets:
        rows = []
        b = bodies["female"]
        only(b)
        b.wear("hair", "hair_long_female")
        tiles = []
        for st in OPTS["skin_tones"]:
            b.set_colors(st["color"], "#4a2c18")
            tiles.append((st["name"], shoot(scene, cam, b, 20, tmp / f"c_s_{st['id']}.png")))
        rows.append(("skin", tiles))
        b.set_colors("#e3b897", "#4a2c18")
        tiles = []
        for hc in OPTS["hair_colors"]:
            b.wear("hair", "hair_long_female", hc["color"])
            tiles.append((hc["name"], shoot(scene, cam, b, 20, tmp / f"c_h_{hc['id']}.png")))
        rows.append(("hair", tiles))
        tiles = []
        for ec in OPTS["eye_colors"]:
            b.set_colors("#e3b897", ec["color"])
            tiles.append((ec["name"], shoot(scene, cam, b, 5, tmp / f"c_e_{ec['id']}.png", dist=0.5)))
        rows.append(("eyes", tiles))
        tiles = []
        for m in ["none"] + Body.MARKS:
            b.set_colors("#d3a27d", "#4a2c18")
            b.set_marking(m)
            tiles.append((m.replace("_", " "), shoot(scene, cam, b, 15, tmp / f"c_m_{m}.png", dist=0.75)))
        b.set_marking("none")
        rows.append(("marks", tiles))
        grid(rows, args.cell, out / "creator_colors.png", "Skin tones, hair colours, eye colours, scars and paint")


if __name__ == "__main__":
    main()
