"""Build one wearable piece for the overhaul characters (backlog G-02 hair and beards; G-03 armor).

    python3 tools/blender/build_piece.py --spec data/assets/hair_long_female.json [--previews previews/g_02]

A piece is skinned to the standard skeleton of its body build and sits where it is worn, so the
game hangs it on the character's own skeleton (G-05). Spec params: `slot` (hair, beard, or an
armor slot), `style`, `target_tris`. Output: the .glb, its baked textures beside it (albedo, orm,
normal), and preview sheets.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
import numpy as np  # noqa: E402

import anatomy  # noqa: E402
import armor_kit  # noqa: E402
import bake  # noqa: E402
import kit  # noqa: E402
import sdf  # noqa: E402
import common  # noqa: E402
import hair  # noqa: E402
import humanoid  # noqa: E402


def hair_material(name: str, hex_color: str) -> bpy.types.Material:
    """Neutral hair (the game tints it with the chosen colour): light and dark streaks along the
    strands, darker in the crevices."""
    mat = common.painted_material(name, hex_color, roughness=0.55, edge_highlight=0.12, cavity_darken=0.55)
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    src = bsdf.inputs["Base Color"].links[0].from_socket
    tc = nt.nodes.new("ShaderNodeTexCoord")
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "X"
    wave.inputs["Scale"].default_value = 60.0
    wave.inputs["Distortion"].default_value = 6.0
    wave.inputs["Detail"].default_value = 3.0
    nt.links.new(tc.outputs["Object"], wave.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeMapRange")
    ramp.inputs["To Min"].default_value = 0.78
    ramp.inputs["To Max"].default_value = 1.12
    nt.links.new(wave.outputs["Fac"], ramp.inputs["Value"])
    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    nt.links.new(src, mul.inputs[6])
    comb = nt.nodes.new("ShaderNodeCombineColor")
    for k in ("Red", "Green", "Blue"):
        nt.links.new(ramp.outputs["Result"], comb.inputs[k])
    nt.links.new(comb.outputs["Color"], mul.inputs[7])
    nt.links.new(mul.outputs[2], bsdf.inputs["Base Color"])
    return mat


def mesh_obj(name: str, verts, faces) -> bpy.types.Object:
    me = common.mesh_from_arrays(name, verts, faces)
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    return o


def reduce_to(o: bpy.types.Object, tris: int) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    d = o.modifiers.new("d", "DECIMATE")
    d.ratio = min(1.0, tris / max(len(o.data.polygons), 1))
    bpy.ops.object.modifier_apply(modifier="d")
    close_mesh(o)
    bpy.ops.object.shade_smooth()


def close_mesh(o: bpy.types.Object) -> int:
    return common.close_mesh(o)


def skin_to_head(o: bpy.types.Object, j: dict, body_type: str, hang: bool) -> None:
    """Weights: the head, fading to the chest for hair hanging below the chin (it then follows
    the back and shoulders instead of swinging through them)."""
    hz, s = anatomy.head_frame(j, body_type)
    head = o.vertex_groups.new(name="head")
    chest = o.vertex_groups.new(name="chest") if hang else None
    for v in o.data.vertices:
        zl = (v.co.z - hz) / s
        w = float(np.clip((zl + 0.06) / 0.08, 0.0, 1.0)) if hang else 1.0
        if w > 0:
            head.add([v.index], w, "REPLACE")
        if chest is not None and w < 1:
            chest.add([v.index], 1.0 - w, "REPLACE")


def follow_face_keys(o: bpy.types.Object, j: dict, body_type: str) -> None:
    """Shape keys matching the body's face presets: each vertex moves as the nearest point of the
    face does, so a beard stays on a broad or gaunt jaw."""
    faces = json.loads((common.REPO / "data" / "appearance" / "faces.json").read_text())["options"]
    co = np.array([v.co[:] for v in o.data.vertices])
    head = anatomy.head_subset(anatomy.body_shape(j, body_type), j)
    on_skin = anatomy.project_points(head, co, iters=4)
    neck_z = float(j["neck"][2])
    o.shape_key_add(name="Basis", from_mix=False)
    for opt in faces:
        if not opt.get("params"):
            continue
        off = anatomy.face_offsets(j, body_type, opt["id"], on_skin, neck_z)
        key = o.shape_key_add(name=f"face_{opt['id']}", from_mix=False)
        key.data.foreach_set("co", (co + off).astype(np.float32).ravel())


# material -> (dye channel, neutral colour, kit_material settings, surface detail for the normal map)
MATERIALS = {
    "plate": ("metal", "#a9adb3", dict(roughness=0.35, metallic=0.3, edge=0.65, cavity=0.6, top_light=0.12, mottle=0.08), "hammered"),
    "mail": ("metal", "#8e9298", dict(roughness=0.45, metallic=0.3, edge=0.3, cavity=0.7, top_light=0.1), "mail"),
    "gold": ("secondary", "#d2c4a0", dict(roughness=0.35, metallic=0.3, edge=0.6, cavity=0.55), None),
    "trim": ("secondary", "#d2c4a0", dict(roughness=0.85, edge=0.15, cavity=0.5), "cloth"),
    "cloth": ("primary", "#cfc8bc", dict(roughness=0.9, edge=0.1, cavity=0.55, top_light=0.15), "cloth"),
    "leather": ("leather", "#4a3424", dict(roughness=0.75, edge=0.3, cavity=0.5), "leather"),
    # undyed (G-07): horn and bone keep their colour, fur its brown; ice glows (GLOW below)
    "horn": ("leather", "#c4b292", dict(roughness=0.55, edge=0.5, cavity=0.7, top_light=0.1), "leather"),
    "bone": ("leather", "#d8ceb2", dict(roughness=0.6, edge=0.45, cavity=0.75, top_light=0.1), "leather"),
    "fur": ("leather", "#6a533d", dict(roughness=0.95, edge=0.05, cavity=0.8, top_light=0.15), "cloth"),
    "ice": ("leather", "#a8ecff", dict(roughness=0.2, edge=0.6, cavity=0.25), None),
    "holy": ("leather", "#ffe2a0", dict(roughness=0.3, edge=0.4, cavity=0.2), None),     # G-08: the Oracle's halo
}
# materials that glow: their texels are white in the piece's glow mask (<id>_glow.png), which the
# piece shader turns into emission
GLOW = {"ice", "holy"}
# long cloth that hangs from the belt or the shoulders: weighted to the pelvis and thighs
# (skirt_weights), not copied from the body; the cape-like ones hang behind the legs
SKIRTS = {"surcoat", "surcoat_trim", "cape", "cloak", "robe", "robe_trim", "loincloth", "cape_frost", "underskirt",
          "underskirt_trim", "underskirt_gold", "tabard", "tabard_gold", "sash_tails"}
BEHIND = ("cape", "cloak")
CHANNEL_RGB = {"primary": (1, 0, 0), "secondary": (0, 1, 0), "metal": (0, 0, 1), "leather": (0, 0, 0)}


def detail_material(name: str, kind: str | None) -> bpy.types.Material:
    """A material for the dense mesh whose only job is surface detail baked into the normal map:
    mail rings, cloth weave, leather grain, faint hammer marks on plate."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    if kind is None:
        return mat
    tc = nt.nodes.new("ShaderNodeTexCoord")
    bump = nt.nodes.new("ShaderNodeBump")
    if kind == "mail":
        tex = nt.nodes.new("ShaderNodeTexVoronoi")
        tex.inputs["Scale"].default_value = 115.0
        nt.links.new(tc.outputs["Object"], tex.inputs["Vector"])
        ring = nt.nodes.new("ShaderNodeMath")
        ring.operation = "PINGPONG"   # a ring around each cell centre
        ring.inputs[1].default_value = 0.3
        nt.links.new(tex.outputs["Distance"], ring.inputs[0])
        nt.links.new(ring.outputs[0], bump.inputs["Height"])
        bump.inputs["Strength"].default_value = 0.8
        bump.inputs["Distance"].default_value = 0.0015
    elif kind == "cloth":
        # soft unevenness of heavy wool, not a weave: a fine weave becomes grain-like noise once
        # the cavity paint picks it up (DESIGN.md: no fine noise)
        tex = nt.nodes.new("ShaderNodeTexNoise")
        tex.inputs["Scale"].default_value = 25.0
        tex.inputs["Detail"].default_value = 2.0
        nt.links.new(tc.outputs["Object"], tex.inputs["Vector"])
        nt.links.new(tex.outputs["Fac"], bump.inputs["Height"])
        bump.inputs["Strength"].default_value = 0.12
        bump.inputs["Distance"].default_value = 0.002
    elif kind == "leather":
        tex = nt.nodes.new("ShaderNodeTexNoise")
        tex.inputs["Scale"].default_value = 180.0
        tex.inputs["Detail"].default_value = 4.0
        nt.links.new(tc.outputs["Object"], tex.inputs["Vector"])
        nt.links.new(tex.outputs["Fac"], bump.inputs["Height"])
        bump.inputs["Strength"].default_value = 0.3
        bump.inputs["Distance"].default_value = 0.0008
    elif kind == "hammered":
        tex = nt.nodes.new("ShaderNodeTexVoronoi")
        tex.inputs["Scale"].default_value = 35.0
        nt.links.new(tc.outputs["Object"], tex.inputs["Vector"])
        nt.links.new(tex.outputs["Distance"], bump.inputs["Height"])
        bump.inputs["Strength"].default_value = 0.08
        bump.inputs["Distance"].default_value = 0.001
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def reference_body(body_type: str) -> tuple[bpy.types.Object, bpy.types.Object]:
    """A quick, coarse skinned body to copy weights from (cloth and mail follow it)."""
    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[body_type]).items()}
    verts, faces = anatomy.body_mesh(j, body_type, voxel=0.008)
    o = mesh_obj("_weights_body", verts, faces)
    reduce_to(o, 9000)
    rig = humanoid.build_armature(body_type, "_weights_rig")
    humanoid.bind(o, rig)
    return o, rig


def transfer_weights(o: bpy.types.Object, src: bpy.types.Object) -> None:
    for g in src.vertex_groups:
        if g.name not in o.vertex_groups:
            o.vertex_groups.new(name=g.name)
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    m = o.modifiers.new("dt", "DATA_TRANSFER")
    m.object = src
    m.use_vert_data = True
    m.data_types_verts = {"VGROUP_WEIGHTS"}
    m.vert_mapping = "POLYINTERP_NEAREST"
    m.layers_vgroup_select_src = "ALL"
    m.layers_vgroup_select_dst = "NAME"
    bpy.ops.object.modifier_apply(modifier="dt")


def skirt_weights(o: bpy.types.Object, j: dict, names: set[str], z_top: float, behind: bool = False) -> None:
    """Panels hanging below the waist (surcoat, cape) follow the pelvis, with a little of each
    thigh, instead of tearing between the legs."""
    groups = {g.name: g for g in o.vertex_groups}
    for n in ("pelvis", "thigh_l", "thigh_r", "spine"):
        if n not in groups:
            groups[n] = o.vertex_groups.new(name=n)
    for v in o.data.vertices:
        if v.co.z >= z_top or v.index not in names:
            continue
        t = min(1.0, (z_top - v.co.z) / 0.25)
        for g in o.vertex_groups:
            try:
                w = g.weight(v.index)
            except RuntimeError:
                continue
            g.add([v.index], w * (1 - t), "REPLACE")
        side = 0.5 + 0.5 * np.clip(v.co.x / 0.02, -1, 1)        # a split skirt: each half with its own leg
        leg = 0.0 if behind else 0.65 * t
        groups["pelvis"].add([v.index], t * (1 - leg), "ADD")
        groups["thigh_l"].add([v.index], t * leg * side, "ADD")
        groups["thigh_r"].add([v.index], t * leg * (1 - side), "ADD")


def build_armor(spec: dict, previews: Path | None, draft: bool = False, only: str = "") -> None:
    body_type = spec["body_build"]
    params = spec["params"]
    b = armor_kit.Body(body_type)
    parts = armor_kit.DESIGNS[params["design"]](b)
    # the design's part triangles are shares; the set's per-slot budget (params.tris) is the total
    target = int(params.get("tris", 0))
    if target > 0:
        total = sum(p.tris for p in parts)
        for p in parts:
            p.tris = max(60, int(round(p.tris * target / total)))
    if only:
        parts = [p for p in parts if p.name in only.split(",")]
    lows, highs, part_verts = [], [], {}
    mats: dict[str, bpy.types.Material] = {}
    dmats: dict[str, bpy.types.Material] = {}
    for part in parts:
        f, glo = armor_kit.eval_part(part, b.shape)
        zs = (glo[2] + part.voxel * np.arange(f.shape[2])).astype(np.float32)
        np.maximum(f, -zs[None, None, :], out=f)                     # nothing below the floor
        f[0], f[-1], f[:, 0], f[:, -1], f[:, :, 0], f[:, :, -1] = 1.0, 1.0, 1.0, 1.0, 1.0, 1.0
        verts, faces = sdf.surface(f, part.voxel)
        del f
        if len(faces) == 0:
            print(f"  WARNING {part.name}: empty", flush=True)
            continue
        verts = verts + glo
        hi_o = mesh_obj(f"{part.name}_high", verts, faces)
        lo_o = mesh_obj(part.name, verts, faces)
        reduce_to(lo_o, part.tris)
        if part.facet_deg > 0:
            kit.shade_smooth_by_angle(lo_o, part.facet_deg)
        chan, neutral, kw, detail = MATERIALS[part.material]
        if part.material not in mats:
            mats[part.material] = kit.kit_material(f"{spec['id']}_{part.material}", neutral, **kw)
            mats[part.material]["dye_channel"] = chan
            dmats[part.material] = detail_material(f"{spec['id']}_{part.material}_detail", detail)
        lo_o.data.materials.append(mats[part.material])
        hi_o.data.materials.append(dmats[part.material])
        kit.set_tint(lo_o, (1.0, 1.0, 1.0))
        for centre, r in part.rivets:   # rivet heads: detail for the normal map only
            bpy.ops.mesh.primitive_uv_sphere_add(radius=r, location=tuple(centre), segments=12, ring_count=6)
            rv = bpy.context.active_object
            rv.data.materials.append(dmats[part.material])
            highs.append(rv)
        rgb = CHANNEL_RGB[chan]
        a = lo_o.data.attributes.new("dye_rgb", "FLOAT_COLOR", "CORNER")
        a.data.foreach_set("color", [c for _ in range(len(lo_o.data.loops)) for c in (*rgb, 1.0)])
        g = 1.0 if part.material in GLOW else 0.0
        a = lo_o.data.attributes.new("glow_rgb", "FLOAT_COLOR", "CORNER")
        a.data.foreach_set("color", [g, g, g, 1.0] * len(lo_o.data.loops))
        lo_o["skin"] = part.skin
        lo_o["skirt"] = part.name in SKIRTS
        lows.append(lo_o)
        highs.append(hi_o)
        print(f"  {part.name}: {len(faces)} dense -> {len(lo_o.data.polygons)} tris ({part.material}, {part.skin})",
              flush=True)
    if draft:   # a quick look at the shapes: flat material colours, no weights, bakes or export
        for h in highs:
            bpy.data.objects.remove(h)
        low = _join(lows, spec["id"])
        tris = common.triangle_count([low])
        print(f"DRAFT {spec['id']} tris={tris}", flush=True)
        out = (previews or common.REPO / "previews" / "draft") / f"{spec['id']}_draft.png"
        common.render_contact_sheet([low], out, cell=720 if only else 480, title=f"{spec['id']} draft {tris} tris")
        return
    # weights per part before joining (rigid parts on one bone, the rest copied from a body)
    ref, ref_rig = reference_body(body_type)
    belt_z = b.z("pelvis") + 0.06
    for o in lows:
        skin = o["skin"]
        if skin == "transfer":
            transfer_weights(o, ref)
            if o["skirt"]:
                skirt_weights(o, b.j, set(range(len(o.data.vertices))), belt_z, behind=o.name.startswith(BEHIND))
        else:
            g = o.vertex_groups.new(name=skin)
            g.add(list(range(len(o.data.vertices))), 1.0, "REPLACE")
    bpy.data.objects.remove(ref)
    bpy.data.objects.remove(ref_rig)
    low = _join(lows, spec["id"])
    high = _join(highs, f"{spec['id']}_high")
    size = int(spec.get("texture_size", 2048))
    out_dir = (common.REPO / spec["out"]).parent
    bake.bake_asset(low, high, out_dir, spec["id"], size=size, samples=16 if size <= 2048 else 8)
    bpy.data.objects.remove(high)
    bake_dye_mask(low, [m for m in mats.values()], out_dir / f"{spec['id']}_dye.png", size // 2)
    glow_path = out_dir / f"{spec['id']}_glow.png"
    if any(p.material in GLOW for p in parts):
        bake_attr_mask(low, "glow_rgb", glow_path, size // 4, gray=True)
    elif glow_path.exists():
        glow_path.unlink()
    if low.data.attributes.get("glow_rgb"):
        low.data.attributes.remove(low.data.attributes["glow_rgb"])
    rig = humanoid.build_armature(body_type, f"{spec['id']}_rig")
    low.parent = rig
    mod = low.modifiers.new("armature", "ARMATURE")
    mod.object = rig
    tris = common.triangle_count([low])
    print(f"PIECE {spec['id']} slot={params['slot']} design={params['design']} tris={tris}", flush=True)
    if previews:
        common.render_contact_sheet([low], previews / f"{spec['id']}_sheet.png", cell=360, title=f"{spec['id']} {tris} tris")
    out = common.export_glb(Path(spec["out"]), [low, rig])
    print(f"BUILT {spec['id']} -> {out}")


def _join(objs: list, name: str) -> bpy.types.Object:
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    o.name = name
    return o


def bake_dye_mask(low: bpy.types.Object, kit_mats: list, path: Path, size: int) -> None:
    """The dye mask: R primary, G secondary, B metal, black for undyed (from each part's material,
    carried in the per-corner 'dye_rgb' attribute)."""
    bake_attr_mask(low, "dye_rgb", path, size)
    if low.data.attributes.get("dye_rgb"):
        low.data.attributes.remove(low.data.attributes["dye_rgb"])
    print(f"  dye mask {path.name}", flush=True)


def bake_attr_mask(low: bpy.types.Object, attr_name: str, path: Path, size: int, gray: bool = False) -> None:
    """Bake a per-corner colour attribute into the low mesh's UV layout as a PNG (RGB, or one
    grey channel)."""
    import numpy as np
    from PIL import Image
    img = bpy.data.images.new(path.stem, size, size, alpha=False)
    mat = bpy.data.materials.new("_dye_bake")
    mat.use_nodes = True
    nt = mat.node_tree
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    col = nt.nodes.new("ShaderNodeAttribute")
    col.attribute_type = "GEOMETRY"
    col.attribute_name = attr_name
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(col.outputs["Color"], emit.inputs["Color"])
    nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.nodes.active = tex
    saved = list(low.data.materials)
    low.data.materials.clear()
    low.data.materials.append(mat)
    for p in low.data.polygons:
        p.material_index = 0
    scene = bpy.context.scene
    samples = scene.cycles.samples
    scene.cycles.samples = 1
    bpy.ops.object.select_all(action="DESELECT")
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type="EMIT")
    scene.cycles.samples = samples
    low.data.materials.clear()
    for m in saved:
        low.data.materials.append(m)
    px = np.empty(size * size * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    rgb = (np.clip(px.reshape(size, size, 4)[::-1, :, :3], 0, 1) * 255).astype(np.uint8)
    path.parent.mkdir(parents=True, exist_ok=True)
    if gray:
        Image.fromarray(rgb[:, :, 0], "L").save(path)
    else:
        Image.fromarray(rgb, "RGB").save(path)
    if gray:
        print(f"  mask {path.name}", flush=True)


def main() -> None:
    def extra(p):
        p.add_argument("--draft", action="store_true", help="armor only: render the reduced shapes, no bakes or export")
        p.add_argument("--parts", default="", help="with --draft: only these parts (comma-separated names)")
    args = common.parse_args("Build a wearable piece", extra)
    spec = common.load_spec(args.spec)
    common.reset_scene()
    body_type = spec["body_build"]
    params = spec["params"]
    slot, style = params["slot"], params.get("style", "")
    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[body_type]).items()}
    if slot not in ("hair", "beard"):
        build_armor(spec, args.previews, draft=args.draft, only=args.parts)
        return
    verts, faces = hair.build_mesh(j, body_type, style, beard=slot == "beard", voxel=float(params.get("voxel", 0.002)))
    high = mesh_obj(f"{spec['id']}_high", verts, faces)
    low = mesh_obj(spec["id"], verts, faces)
    reduce_to(low, int(params.get("target_tris", 3000)))
    low.data.materials.append(hair_material(f"{spec['id']}_hair", spec["palette"]["hair"]))
    size = int(spec.get("texture_size", 1024))
    bake.bake_asset(low, high, (common.REPO / spec["out"]).parent, spec["id"], size=size, samples=12)
    bpy.data.objects.remove(high)
    hang = (slot == "hair" and style in ("long", "braided")) or (slot == "beard" and style == "long")
    rig = humanoid.build_armature(body_type, f"{spec['id']}_rig")
    skin_to_head(low, j, body_type, hang)
    low.parent = rig
    mod = low.modifiers.new("armature", "ARMATURE")
    mod.object = rig
    if slot == "beard":
        follow_face_keys(low, j, body_type)
    tris = common.triangle_count([low])
    print(f"PIECE {spec['id']} slot={slot} style={style} tris={tris}", flush=True)
    if args.previews:
        common.render_contact_sheet([low], args.previews / f"{spec['id']}_sheet.png", cell=320,
                                    title=f"{spec['id']} {tris} tris")
    out = common.export_glb(Path(spec["out"]), [low, rig])
    print(f"BUILT {spec['id']} -> {out}")


if __name__ == "__main__":
    main()
