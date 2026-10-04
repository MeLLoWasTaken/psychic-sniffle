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
import bake  # noqa: E402
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
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts.tolist(), [], faces.tolist())
    me.validate()
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
    bpy.ops.object.shade_smooth()


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


def main() -> None:
    args = common.parse_args("Build a wearable piece")
    spec = common.load_spec(args.spec)
    common.reset_scene()
    body_type = spec["body_build"]
    params = spec["params"]
    slot, style = params["slot"], params["style"]
    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[body_type]).items()}
    if slot not in ("hair", "beard"):
        raise SystemExit(f"{spec['id']}: slot {slot} has no builder yet")
    verts, faces = hair.build_mesh(j, body_type, style, beard=slot == "beard", voxel=float(params.get("voxel", 0.002)))
    high = mesh_obj(f"{spec['id']}_high", verts, faces)
    low = mesh_obj(spec["id"], verts, faces)
    reduce_to(low, int(params.get("target_tris", 3000)))
    low.data.materials.append(hair_material(f"{spec['id']}_hair", spec["palette"]["hair"]))
    size = int(spec.get("texture_size", 1024))
    bake.bake_asset(low, high, common.REPO / "previews" / "kit_textures", spec["id"], size=size)
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
