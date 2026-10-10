"""Build one weapon (backlog G-09: weapons at the new fidelity).

    python3 tools/blender/build_weapon.py --spec data/assets/weapon_greatsword.json [--previews previews/g_09] [--draft]

The design (params.design, a function in weapon_kit.py) is a list of parts, each a distance field
in weapon space (the grip at the origin, the blade or head up +Z). Each part is extracted densely
(the normal map's source) and reduced to its share of params.tris, the same way armor is built
(build_piece.build_armor). Outputs: the .gltf with its baked textures beside it (albedo, orm,
normal, and an emission texture when a part glows) and a preview sheet.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402  (must come before bmesh)
import numpy as np  # noqa: E402

import armor_kit  # noqa: E402
import bake  # noqa: E402
import build_piece  # noqa: E402
import common  # noqa: E402
import kit  # noqa: E402
import sdf  # noqa: E402
import weapon_kit  # noqa: E402

# material -> (neutral colour, kit_material settings, surface detail for the normal map)
MATERIALS = {
    "steel": ("#a3a8ae", dict(roughness=0.28, metallic=0.35, edge=0.7, cavity=0.55, top_light=0.12, mottle=0.06), "brushed"),
    "dark": ("#3a3d43", dict(roughness=0.45, metallic=0.3, edge=0.45, cavity=0.6, top_light=0.1, mottle=0.08), "hammered"),
    "iron": ("#4a4c52", dict(roughness=0.5, metallic=0.3, edge=0.6, cavity=0.65, top_light=0.1, mottle=0.1), "hammered"),
    "gold": ("#c49a45", dict(roughness=0.32, metallic=0.35, edge=0.65, cavity=0.6), None),
    "leather": ("#4a3325", dict(roughness=0.8, edge=0.25, cavity=0.6), "leather"),
    "cloth": ("#e8e0cc", dict(roughness=0.9, edge=0.1, cavity=0.55, top_light=0.12), "cloth"),
    "wood": ("#6a4d34", dict(roughness=0.75, edge=0.3, cavity=0.6, mottle=0.18, mottle_scale=4.0), "grain"),
    "bone": ("#d8ceb2", dict(roughness=0.6, edge=0.45, cavity=0.75, top_light=0.1), "leather"),
    "frost": ("#9fe6ff", dict(roughness=0.15, edge=0.55, cavity=0.2, emission=1.6), None),
    "holy": ("#ffe2a0", dict(roughness=0.25, edge=0.4, cavity=0.2, emission=1.8), None),
}


def detail_material(name: str, kind: str | None) -> bpy.types.Material:
    """Surface detail for the dense mesh (baked into the normal map): the armor kinds, plus long
    polishing marks along a blade and grain along a wooden haft."""
    if kind not in ("brushed", "grain"):
        return build_piece.detail_material(name, kind)
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (1.0, 1.0, 0.04) if kind == "brushed" else (1.0, 1.0, 0.08)
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    tex = nt.nodes.new("ShaderNodeTexNoise")
    tex.inputs["Scale"].default_value = 260.0 if kind == "brushed" else 90.0
    tex.inputs["Detail"].default_value = 3.0
    nt.links.new(mp.outputs["Vector"], tex.inputs["Vector"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.06 if kind == "brushed" else 0.35
    bump.inputs["Distance"].default_value = 0.0006 if kind == "brushed" else 0.0012
    nt.links.new(tex.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def tight_bounds(part: armor_kit.Part, shape: sdf.Shape, coarse: float = 0.004) -> tuple[np.ndarray, np.ndarray] | None:
    """The part's box shrunk to where its surface actually is: the field sampled at 4 mm, every
    sample within two coarse cells of the surface kept, plus a margin. A design can then give
    all its parts the weapon's whole box without the fine grid spanning it (a greatsword's box
    at 1 mm is 90 million samples; its blade's own box is 12 million)."""
    probe = armor_kit.Part(part.name, part.material, part.fn, part.lo, part.hi, part.tris, voxel=coarse)
    f, glo = armor_kit.eval_part(probe, shape)
    if np.isnan(f).any():
        raise ValueError(f"{part.name}: the field has NaN samples (a fractional power of a negative number?)")
    idx = np.argwhere(f < 2.0 * coarse)
    if len(idx) == 0:
        return None
    lo = glo + idx.min(axis=0) * coarse - 3 * coarse
    hi = glo + idx.max(axis=0) * coarse + 3 * coarse
    return np.maximum(lo, part.lo), np.minimum(hi, part.hi)


def weapon_sheet(obj: bpy.types.Object, out_png: Path, title: str) -> Path:
    """A preview made for long, thin weapons (the standard four-view sheet shows a greatsword a
    few pixels wide): the weapon laid horizontally, flat face and edge on, in orthographic views
    framed to its length; below, close three-quarter views of the grip end and of the head end."""
    import math

    from mathutils import Matrix, Vector
    from PIL import Image, ImageDraw
    out_png = out_png if out_png.is_absolute() else common.REPO / out_png
    out_png.parent.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    common.setup_lighting("dusk_grim")
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 24
    scene.cycles.use_denoising = True
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "AgX"
    co = np.array([v.co[:] for v in obj.data.vertices])
    lo, hi = co.min(axis=0), co.max(axis=0)
    length = float(hi[2] - lo[2])
    cam_data = bpy.data.cameras.new("_wcam")
    cam = bpy.data.objects.new("_wcam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    W = 2048

    def shot(name, w, h):
        scene.render.resolution_x, scene.render.resolution_y = w, h
        tmp = out_png.with_name(f"_{out_png.stem}_{name}.png")
        scene.render.filepath = str(tmp)
        bpy.ops.render.render(write_still=True)
        img = Image.open(tmp).convert("RGB")
        tmp.unlink()
        return img

    c = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2))
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = length * 1.06
    tiles = []
    # flat face: image right = +Z, looking along +Y
    cam.matrix_world = Matrix.Translation(c - Vector((0, 3.0, 0))) @ Matrix(
        ((0, -1, 0, 0), (0, 0, -1, 0), (1, 0, 0, 0), (0, 0, 0, 1)))
    hx = max(float(hi[0] - lo[0]), 0.1)
    tiles.append(("flat", shot("flat", W, int(W * min(0.5, hx * 1.25 / (length * 1.06)) + 40))))
    # edge on: image right = +Z, looking along +X
    cam.matrix_world = Matrix.Translation(c - Vector((3.0, 0, 0))) @ Matrix(
        ((0, 0, -1, 0), (0, 1, 0, 0), (1, 0, 0, 0), (0, 0, 0, 1)))
    hy = max(float(hi[1] - lo[1]), 0.1)
    tiles.append(("edge", shot("edge", W, int(W * min(0.5, hy * 1.25 / (length * 1.06)) + 40))))
    cam_data.type = "PERSP"
    cam_data.lens = 50
    close = []
    for name, zc in (("grip end", 0.0), ("head end", float(hi[2]) - 0.22)):
        size = 0.48
        a = math.radians(35)
        d = Vector((math.sin(a), -math.cos(a), 0.3)).normalized()
        target = Vector((c.x, c.y, zc))
        cam.location = target + d * size * 1.7
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
        close.append((name, shot(name.replace(" ", "_"), W // 2, W // 2)))
    bpy.data.objects.remove(cam)
    rows = [img for _, img in tiles]
    height = sum(i.height + 24 for i in rows) + W // 2 + 24 + 28
    sheet = Image.new("RGB", (W, height), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    draw.text((8, 8), title, fill=(200, 200, 200))
    y = 28
    for label, img in tiles:
        draw.text((8, y + 4), label, fill=(170, 170, 170))
        sheet.paste(img, (0, y + 24))
        y += img.height + 24
    for k, (label, img) in enumerate(close):
        draw.text((k * W // 2 + 8, y + 4), label, fill=(170, 170, 170))
        sheet.paste(img, (k * W // 2, y + 24))
    sheet.save(out_png)
    return out_png


def build(spec: dict, previews: Path | None, draft: bool = False) -> None:
    params = spec["params"]
    parts = weapon_kit.DESIGNS[params["design"]](params)
    target = int(params.get("tris", 0))
    if target > 0:      # the parts' triangles are shares of the weapon's budget
        total = sum(p.tris for p in parts)
        for p in parts:
            p.tris = max(60, int(round(p.tris * target / total)))
    pal = spec.get("palette", {})
    shape = sdf.Shape([])
    lows, highs = [], []
    mats: dict[str, bpy.types.Material] = {}
    dmats: dict[str, bpy.types.Material] = {}
    for part in parts:
        box = tight_bounds(part, shape)
        if box is None:
            print(f"  WARNING {part.name}: empty", flush=True)
            continue
        part.lo, part.hi = box
        cells = np.prod(np.ceil((part.hi - part.lo) / part.voxel) + 1)
        f, glo = armor_kit.eval_part(part, shape)
        f[0], f[-1], f[:, 0], f[:, -1], f[:, :, 0], f[:, :, -1] = 1.0, 1.0, 1.0, 1.0, 1.0, 1.0
        verts, faces = sdf.surface(f, part.voxel)
        del f
        if len(faces) == 0:
            print(f"  WARNING {part.name}: empty", flush=True)
            continue
        verts = verts + glo
        hi_o = build_piece.mesh_obj(f"{part.name}_high", verts, faces)
        lo_o = build_piece.mesh_obj(part.name, verts, faces)
        build_piece.reduce_to(lo_o, part.tris)
        if part.facet_deg > 0:
            kit.shade_smooth_by_angle(lo_o, part.facet_deg)
        neutral, kw, detail = MATERIALS[part.material]
        if part.material not in mats:
            mats[part.material] = kit.kit_material(f"{spec['id']}_{part.material}", pal.get(part.material, neutral), **kw)
            dmats[part.material] = detail_material(f"{spec['id']}_{part.material}_detail", detail)
        lo_o.data.materials.append(mats[part.material])
        hi_o.data.materials.append(dmats[part.material])
        kit.set_tint(lo_o, (1.0, 1.0, 1.0))
        lows.append(lo_o)
        highs.append(hi_o)
        print(f"  {part.name}: {cells / 1e6:.1f}M samples, {len(faces)} dense -> {len(lo_o.data.polygons)} tris "
              f"({part.material})", flush=True)
    low = build_piece._join(lows, spec["id"])
    common.close_mesh(low)
    tris = common.triangle_count([low])
    if draft:
        for h in highs:
            bpy.data.objects.remove(h)
        out = (previews or common.REPO / "previews" / "draft") / f"{spec['id']}_draft.png"
        weapon_sheet(low, out, f"{spec['id']} draft {tris} tris")
        print(f"DRAFT {spec['id']} tris={tris}", flush=True)
        return
    high = build_piece._join(highs, f"{spec['id']}_high")
    size = int(spec.get("texture_size", 2048))
    out_dir = (common.REPO / spec["out"]).parent
    bake.bake_asset(low, high, out_dir, spec["id"], size=size, samples=16)
    bpy.data.objects.remove(high)
    tris = common.triangle_count([low])
    if previews:
        weapon_sheet(low, previews / f"{spec['id']}_sheet.png", f"{spec['id']} {tris} tris")
    out = common.export_glb(Path(spec["out"]), [low])
    print(f"BUILT {spec['id']} tris={tris} -> {out}", flush=True)


def main() -> None:
    def extra(p):
        p.add_argument("--draft", action="store_true", help="render the reduced shapes only: no bakes or export")
    args = common.parse_args("Build a weapon", extra)
    spec = common.load_spec(args.spec)
    common.reset_scene()
    build(spec, args.previews, draft=args.draft)


if __name__ == "__main__":
    main()
