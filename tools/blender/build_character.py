"""Build a playable character: body, armor set, one texture atlas, rig (backlog M1-18..M1-20).

  python3 tools/blender/build_character.py --spec data/assets/char_warblade_carnage.json --previews previews/warblade

The body (body_sdf.py) is skinned with automatic weights; each armor piece (armor.py) is rigidly
bound to one bone. Everything is joined into one mesh and baked into one 2048 px texture set
(base color, roughness/metallic, normal), so a character is one draw call in game.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
import numpy as np  # noqa: E402
from mathutils import Vector  # noqa: E402

import armor  # noqa: E402
import build_body  # noqa: E402
import common  # noqa: E402
import humanoid  # noqa: E402
import kit  # noqa: E402
import sdf  # noqa: E402


GRAD = {"height_grad": 0.22}  # painted height gradient on every non-glowing character material


def materials(pal: dict) -> dict:
    g = GRAD
    return {
        "plate": kit.kit_material("plate", pal.get("plate", "#4b4e55"), roughness=0.45, metallic=0.3, edge=0.6,
                                  cavity=0.6, top_light=0.15, mottle=0.1, mottle_scale=2.0, **g),
        "trim": kit.kit_material("trim", pal.get("trim", "#8a6b3c"), roughness=0.5, metallic=0.3, edge=0.5, **g),
        "leather": kit.kit_material("leather", pal.get("leather", "#4a3325"), roughness=0.8, edge=0.3, cavity=0.5, **g),
        "cloth": kit.kit_material("cloth", pal.get("cloth", "#3a2a24"), roughness=0.9, edge=0.1, cavity=0.5, **g),
        "skin": kit.kit_material("skin", pal.get("skin", "#9a7a62"), roughness=0.7, edge=0.05, cavity=0.45,
                                 top_light=0.1, **g),
        "cloth_dark": kit.kit_material("cloth_dark", pal.get("cloth_dark", "#23272e"), roughness=0.9, edge=0.12,
                                       cavity=0.5, **g),
        "frost": kit.kit_material("frost", pal.get("frost", "#9fe6ff"), roughness=0.2, edge=0.4, cavity=0.2,
                                  top_light=0.1, emission=1.2),
        "gold": kit.kit_material("gold", pal.get("gold", "#b08a3e"), roughness=0.4, metallic=0.3, edge=0.6,
                                 cavity=0.5, **g),
        "trim_cloth": kit.kit_material("trim_cloth", pal.get("trim_cloth", "#e6ddc8"), roughness=0.9, edge=0.1,
                                       cavity=0.45, **g),
        "shadow": kit.kit_material("shadow", pal.get("shadow", "#0b0d12"), roughness=1.0, edge=0.0, cavity=0.2,
                                   top_light=0.0, **g),
        "eyes": kit.kit_material("eyes", pal.get("eyes", pal.get("frost", "#9fe6ff")), roughness=0.3, edge=0.0,
                                 cavity=0.0, top_light=0.0, emission=7.0),
        "holy": kit.kit_material("holy", pal.get("holy", "#ffd98a"), roughness=0.3, metallic=0.2, edge=0.5,
                                 cavity=0.3, emission=0.6),
    }


def mesh_object(name: str, verts, faces) -> bpy.types.Object:
    me = bpy.data.meshes.new(name)
    me.from_pydata(np.asarray(verts).tolist(), [], np.asarray(faces).tolist())
    me.validate()
    # marching cubes leaves a few duplicate vertices along internal seams; unwelded seams stop
    # the triangle reduction far short of its target
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    return o


MIN_ISLAND_TRIS = 24  # a separate part (a spike, a stud) never drops below this in the reduction


def _decimate(o: bpy.types.Object, tris: int) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    for _ in range(3):  # one collapse pass can stop short of the target on dense scans
        if len(o.data.polygons) <= tris * 1.08:
            break
        d = o.modifiers.new("dec", "DECIMATE")
        d.ratio = min(1.0, tris / max(len(o.data.polygons), 1))
        common.apply_all_modifiers(o)


def _split_small_islands(o: bpy.types.Object, ratio: float) -> list[bpy.types.Object]:
    """Move the separate parts that a uniform reduction would shrink below MIN_ISLAND_TRIS into
    objects of their own. The collapse would flatten such a part into two back-to-back
    triangles, which the glTF exporter then deletes as duplicates, leaving holes."""
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(o.data)
    bm.faces.index_update()
    seen, islands = set(), []
    for f in bm.faces:
        if f in seen:
            continue
        stack, island = [f], []
        seen.add(f)
        while stack:
            g = stack.pop()
            island.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h not in seen:
                        seen.add(h)
                        stack.append(h)
        islands.append(island)
    small = [i for i in islands if len(i) * ratio < MIN_ISLAND_TRIS]
    if not small or len(small) == len(islands):
        bm.free()
        return []
    parts = []
    for island in small:
        part_bm = bm.copy()  # same face order, so the indices match
        part_bm.faces.index_update()
        idx = {f.index for f in island}
        bmesh.ops.delete(part_bm, geom=[f for f in part_bm.faces if f.index not in idx], context="FACES")
        me = bpy.data.meshes.new(f"{o.name}_part")
        part_bm.to_mesh(me)
        part_bm.free()
        part = bpy.data.objects.new(me.name, me)
        bpy.context.scene.collection.objects.link(part)
        parts.append(part)
    bmesh.ops.delete(bm, geom=[f for i in small for f in i], context="FACES")
    bm.to_mesh(o.data)
    bm.free()
    return parts


def reduce(o: bpy.types.Object, tris: int, facet_deg: float) -> None:
    ratio = min(1.0, tris / max(len(o.data.polygons), 1))
    small = _split_small_islands(o, ratio)
    _decimate(o, tris - sum(max(MIN_ISLAND_TRIS, round(len(p.data.polygons) * ratio)) for p in small))
    for part in small:
        _decimate(part, max(MIN_ISLAND_TRIS, round(len(part.data.polygons) * ratio)))
    if small:
        bpy.ops.object.select_all(action="DESELECT")
        for part in small:
            part.select_set(True)
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.join()
    kit.shade_smooth_by_angle(o, facet_deg)


def rigid(o: bpy.types.Object, bone: str) -> None:
    g = o.vertex_groups.new(name=bone)
    g.add(list(range(len(o.data.vertices))), 1.0, "REPLACE")


def transfer_weights(o: bpy.types.Object, body: bpy.types.Object) -> None:
    """Cloth: copy skin weights from the nearest point of the body, so a robe bends with the
    legs and a sleeve with the arm instead of riding rigidly on one bone."""
    for g in body.vertex_groups:
        o.vertex_groups.new(name=g.name)
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    m = o.modifiers.new("weights", "DATA_TRANSFER")
    m.object = body
    m.use_vert_data = True
    m.data_types_verts = {"VGROUP_WEIGHTS"}
    m.vert_mapping = "POLYINTERP_NEAREST"
    m.layers_vgroup_select_src = "ALL"
    m.layers_vgroup_select_dst = "NAME"
    bpy.ops.object.modifier_apply(modifier=m.name)


def soften_skirt(o: bpy.types.Object, j: dict) -> None:
    """A skirt copying each thigh's weights splits at the front when a leg lifts. Below the
    waist, fold calf and foot weights into the thigh, hand part of the leg weight to the pelvis
    (most near the waist, less toward the hem, so the hem still swings), and let the middle of
    the skirt follow both thighs halfway, so the two halves move together."""
    waist = float(j["spine"][2]) - 0.08
    hem = float(j["ankle_l"][2]) + 0.1
    groups = {g.name: g for g in o.vertex_groups}
    idx = {g.index: g.name for g in o.vertex_groups}
    for v in o.data.vertices:
        if v.co.z >= waist:
            continue
        w = {idx[g.group]: g.weight for g in v.groups}
        t = min(max((waist - v.co.z) / (waist - hem), 0.0), 1.0)
        leg = {s: sum(w.pop(f"{b}_{s}", 0.0) for b in ("thigh", "calf", "foot")) for s in ("l", "r")}
        keep = 0.25 + 0.35 * t
        mix = 0.5 * min(max(1.0 - abs(v.co.x) / 0.12, 0.0), 1.0)
        left, right = leg["l"] * keep, leg["r"] * keep
        both = (left + right) / 2
        w["thigh_l"] = (1 - mix) * left + mix * both
        w["thigh_r"] = (1 - mix) * right + mix * both
        w["pelvis"] = w.get("pelvis", 0.0) + (leg["l"] + leg["r"]) * (1 - keep)
        total = sum(w.values()) or 1.0
        for name, g in groups.items():
            value = w.get(name, 0.0) / total
            if value > 1e-4:
                g.add([v.index], value, "REPLACE")
            else:
                g.remove([v.index])


def close_holes(o: bpy.types.Object) -> None:
    """Weld duplicate vertices and fill any small holes left after reduction and joining, so
    the character stays a set of closed meshes (asset validation).

    The pieces arrive closed (sdf.surface, reduce), so this is a safety net. It must not
    collapse short edges: a 2 mm threshold used here once pinched thin rims and spike tips
    into edges shared by four faces and tore holes the fill could not close."""
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(o.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    # zero-area slivers are dropped by the glTF exporter, which opens holes; dissolve them here
    bmesh.ops.dissolve_degenerate(bm, dist=1e-5, edges=bm.edges)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    # an edge shared by more than two faces: drop those faces and let the hole fill close it
    bad = {f for e in bm.edges if len(e.link_faces) > 2 for f in e.link_faces}
    if bad:
        print(f"  WARNING {len(bad)} faces on edges shared by more than two faces")
        bmesh.ops.delete(bm, geom=list(bad), context="FACES")
    boundary = [e for e in bm.edges if e.is_boundary]
    if boundary:
        filled = bmesh.ops.holes_fill(bm, edges=boundary, sides=64)
        bmesh.ops.triangulate(bm, faces=filled["faces"])
        print(f"  WARNING filled {len(filled['faces'])} small holes")
    bm.to_mesh(o.data)
    bm.free()
    # automatic weights can exceed 1 by a hair; the exporter then reports the mesh as invalid
    for v in o.data.vertices:
        for g in v.groups:
            if g.weight > 1.0:
                g.weight = 1.0


def rivet(pos, normal, mat, bone: str) -> bpy.types.Object:
    n = Vector(normal).normalized()
    rot = Vector((0, 0, 1)).rotation_difference(n).to_euler()
    bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.011, depth=0.018, location=tuple(Vector(pos) + n * 0.004),
                                        rotation=tuple(rot))
    o = bpy.context.active_object
    kit.clear_uvs(o)
    o.data.materials.append(mat)
    kit.set_tint(o, (1.0, 1.0, 1.0))
    rigid(o, bone)
    return o


def closeup_shots(j: dict) -> list:
    """Head, both hands and the chest, for judging detail."""
    head = j["head"] + np.array([0.0, 0.0, 0.12])
    hands = {s: (j[f"wrist_{s}"] + j[f"hand_end_{s}"]) / 2 for s in ("l", "r")}
    return [("head", head, 20, 0.75), ("head_side", head, 75, 0.75),
            ("hand_r", hands["r"], -60, 0.55), ("hand_l", hands["l"], 50, 0.55),
            ("front", (j["spine"] + j["pelvis"]) / 2, 0, 1.3)]


def build(spec: dict, previews: Path | None, pose_test: bool, bake: bool = True) -> None:
    common.reset_scene()
    rng = common.seeded_random(spec["seed"])
    build_name = spec["body_build"]
    mats = materials(spec.get("palette", {}))
    hand_poses = tuple(spec["params"].get("hands", ["relaxed", "fist"]))  # left, right
    body = humanoid.build_body_sdf(build_name, spec["id"], target_tris=int(spec["params"].get("body_tris", 7000)),
                                   hands=hand_poses)
    body.data.materials.append(mats["cloth"])
    # the head: skin, or "shadow" for a face lost in a deep hood (params.face)
    body.data.materials.append(mats["shadow" if spec["params"].get("face") == "shadow" else "skin"])
    # skin on the head and neck, and on the hands unless the armor set covers them; padded
    # cloth everywhere else under the armor
    jt = humanoid.joints(humanoid.BUILDS[build_name])
    head_z = jt["neck"].z
    bare_hands = bool(spec["params"].get("bare_hands", False))
    hands = [(jt[f"wrist_{s}"] + jt[f"hand_end_{s}"]) / 2 for s in ("l", "r")]
    for poly in body.data.polygons:
        on_hand = bare_hands and min((poly.center - h).length for h in hands) < 0.13
        poly.material_index = 1 if (poly.center.z > head_z or on_hand) else 0
    kit.set_tint(body, (1.0, 1.0, 1.0))
    rig = humanoid.build_armature(build_name, f"{spec['id']}_rig")
    humanoid.bind(body, rig)

    j = {k: np.array(v) for k, v in humanoid.joints(humanoid.BUILDS[build_name]).items()}
    parts = []
    for piece in armor.ARMOR_SETS[spec["params"]["armor"]](j, build_name, hand_poses):
        floor_clipped = lambda P, fn=piece.fn: np.maximum(fn(P), -P[:, 2])  # noqa: E731  nothing below the floor
        verts, faces = sdf.extract_field(floor_clipped, piece.lo, piece.hi, piece.voxel)
        if len(faces) == 0:
            print(f"  WARNING armor piece {piece.name} is empty")
            continue
        o = mesh_object(piece.name, verts, faces)
        reduce(o, piece.tris, piece.facet_deg)
        o.data.materials.append(mats[piece.material])
        kit.set_tint(o, kit.random_tint(rng, 0.08, 0.02))
        if piece.skin == "transfer":
            transfer_weights(o, body)
            if piece.skirt:
                soften_skirt(o, j)
        else:
            rigid(o, piece.bone)
        parts.append(o)
        for pos, normal in piece.rivets:
            parts.append(rivet(pos, normal, mats["trim"], piece.bone))
        print(f"  {piece.name}: {len(o.data.polygons)} tris on {piece.bone}")
    # join the armor into the skinned body (the body keeps its armature modifier)
    bpy.ops.object.select_all(action="DESELECT")
    for o in parts:
        o.select_set(True)
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()
    char = bpy.context.view_layer.objects.active
    close_holes(char)
    tris = common.triangle_count([char])
    print(f"CHARACTER {spec['id']} tris={tris}")
    if not bake:  # fast geometry review: procedural materials, close-ups, nothing exported
        if previews:
            common.render_contact_sheet([char], previews / f"{spec['id']}_nobake_sheet.png", cell=384,
                                        title=f"{spec['id']} {tris} tris (no bake)")
            common.render_closeups([char], previews / f"{spec['id']}_closeups.png", closeup_shots(j))
            if pose_test:
                build_body.pose_test(rig)
                common.render_contact_sheet([char], previews / f"{spec['id']}_nobake_pose.png", cell=384,
                                            title="pose test (no bake)")
        print(f"PREVIEWED {spec['id']} (no bake, not exported)")
        return
    kit.bake_piece(char, common.REPO / "previews" / "kit_textures", spec["id"], size=int(spec.get("texture_size", 2048)),
                   samples=32, bevel_normal=0.006)
    if previews:
        common.render_closeups([char], previews / f"{spec['id']}_closeups.png", closeup_shots(j))
        common.render_contact_sheet([char], previews / f"{spec['id']}_sheet.png", cell=512, title=f"{spec['id']} {tris} tris")
        if pose_test:
            build_body.pose_test(rig)
            common.render_contact_sheet([char], previews / f"{spec['id']}_pose.png", cell=512, title="pose test")
            bpy.context.view_layer.objects.active = rig
            bpy.ops.object.mode_set(mode="POSE")
            bpy.ops.pose.select_all(action="SELECT")
            bpy.ops.pose.transforms_clear()
            bpy.ops.object.mode_set(mode="OBJECT")
    out = common.export_glb(Path(spec["out"]), [char, rig])
    print(f"BUILT {spec['id']} -> {out}")


def main() -> None:
    def extra(p):
        p.add_argument("--pose-test", action="store_true")
        p.add_argument("--no-bake", action="store_true", help="geometry review only: no bake, no export")
    args = common.parse_args("Build a character", extra)
    build(common.load_spec(args.spec), args.previews, args.pose_test, bake=not args.no_bake)


if __name__ == "__main__":
    main()
