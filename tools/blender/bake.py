"""High-to-low texture bakes for the overhaul assets (backlog G-01, G-03).

A game mesh (low) gets a tangent-space normal map carrying the detail of a dense version of the
same surface (high): muscle definition on bodies; engraving, rivets, mail and stitching on armor.
Base color and roughness come from the low mesh's own painted materials, baked as kit.bake_piece
does, so the results load the same way in Godot (albedo, orm, normal PNGs beside the .glb).
"""
from __future__ import annotations

import math
from pathlib import Path

import bpy

import kit


def scale_islands(obj: bpy.types.Object, factor_of) -> int:
    """Scale UV islands about their centres by `factor_of(island centre in object space)` before
    packing, so the face (say) gets more texels than its area alone would give it."""
    import numpy as np
    me = obj.data
    uv = me.uv_layers.active.data
    n_loops = len(me.loops)
    co = np.empty(n_loops * 2, dtype=np.float32)
    uv.foreach_get("uv", co)
    co = co.reshape(-1, 2)
    # islands: faces joined where they share an edge whose two loops carry the same UVs
    parent = list(range(len(me.polygons)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    edge_faces: dict = {}
    for poly in me.polygons:
        ls = list(poly.loop_indices)
        for i, li in enumerate(ls):
            lj = ls[(i + 1) % len(ls)]
            va, vb = me.loops[li].vertex_index, me.loops[lj].vertex_index
            key = (min(va, vb), max(va, vb))
            uvs = {va: tuple(np.round(co[li], 6)), vb: tuple(np.round(co[lj], 6))}
            if key in edge_faces:
                other, ouv = edge_faces[key]
                if ouv == uvs:
                    ra, rb = find(poly.index), find(other)
                    if ra != rb:
                        parent[ra] = rb
            else:
                edge_faces[key] = (poly.index, uvs)
    islands: dict = {}
    for poly in me.polygons:
        islands.setdefault(find(poly.index), []).append(poly)
    scaled = 0
    for polys in islands.values():
        centre = sum((p.center for p in polys), polys[0].center * 0) / len(polys)
        f = float(factor_of(centre))
        if abs(f - 1.0) < 1e-3:
            continue
        loops = [li for p in polys for li in p.loop_indices]
        c = co[loops].mean(axis=0)
        co[loops] = c + (co[loops] - c) * f
        scaled += 1
    uv.foreach_set("uv", co.ravel())
    return scaled


def unwrap(obj: bpy.types.Object, angle_deg: float = 66.0, margin: float = 0.004, detail=None) -> None:
    """Smart UV project and pack, islands scaled by their surface area (times `detail(centre)`
    when given: a texel-density factor per island)."""
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    me = obj.data
    while me.uv_layers:
        me.uv_layers.remove(me.uv_layers[0])
    me.uv_layers.new(name="UVMap")
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle_deg), island_margin=margin)
    if detail is not None:
        bpy.ops.object.mode_set(mode="OBJECT")
        scale_islands(obj, detail)
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, scale=True, margin=margin)
    bpy.ops.object.mode_set(mode="OBJECT")


def bake_normal(low: bpy.types.Object, high: bpy.types.Object, image: bpy.types.Image,
                extrusion: float = 0.012, max_ray: float = 0.03, samples: int = 4) -> None:
    """Bake `high`'s shading normals into `image` on `low`'s UVs (selected to active)."""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    prev_samples = scene.cycles.samples
    scene.cycles.samples = samples
    bake = scene.render.bake
    bake.use_selected_to_active = True
    bake.cage_extrusion = extrusion
    bake.max_ray_distance = max_ray
    bake.normal_space = "TANGENT"
    bake.margin = 8
    bake.use_clear = True
    added = []
    for mat in [m for m in low.data.materials if m]:
        nt = mat.node_tree
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = image
        nt.nodes.active = node
        added.append((mat, node))
    if not high.data.materials:
        high.data.materials.append(low.data.materials[0])
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type="NORMAL")
    bake.use_selected_to_active = False
    scene.cycles.samples = prev_samples
    tame_normals(image)
    for mat, node in added:
        mat.node_tree.nodes.remove(node)


def tame_normals(image: bpy.types.Image, min_z: float = 0.45) -> int:
    """Flatten texels whose baked normal leans further than `min_z` allows from the surface:
    rays that hit the far side of a deep cavity (nostrils, a mouth line, gaps between plates)
    leave near-sideways normals that render as black smudges on the game mesh."""
    import numpy as np
    w, h = image.size
    px = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(px)
    px = px.reshape(-1, 4)
    n = px[:, :3] * 2.0 - 1.0
    bad = n[:, 2] < min_z
    if bad.any():
        t = np.clip((min_z - n[bad, 2]) / min_z, 0.0, 1.0)[:, None]
        flat = np.array([0.0, 0.0, 1.0])
        m = n[bad] * (1 - t) + flat * t
        m /= np.linalg.norm(m, axis=1, keepdims=True)
        px[bad, :3] = m * 0.5 + 0.5
        image.pixels.foreach_set(px.ravel())
        image.update()
    return int(bad.sum())


def _emit_bake(target: bpy.types.Object, image: bpy.types.Image, surface_of, source: bpy.types.Object | None = None,
               extrusion: float = 0.012, max_ray: float = 0.03) -> None:
    """Bake an emission into `image` on `target`'s UVs: each material of the emitting object (the
    target itself, or `source` baked selected-to-active) temporarily emits `surface_of(mat, nt)`,
    a colour socket."""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prev = scene.cycles.samples
    scene.cycles.samples = 1
    bake = scene.render.bake
    bake.use_selected_to_active = source is not None
    bake.cage_extrusion = extrusion
    bake.max_ray_distance = max_ray
    bake.margin = 4
    bake.use_clear = True
    emitter = source or target
    saved, added = [], []
    for mat in {m for m in emitter.data.materials if m}:
        nt = mat.node_tree
        out = next(nd for nd in nt.nodes if nd.type == "OUTPUT_MATERIAL")
        prev_link = out.inputs["Surface"].links[0].from_socket if out.inputs["Surface"].links else None
        emit = nt.nodes.new("ShaderNodeEmission")
        nt.links.new(surface_of(mat, nt), emit.inputs["Color"])
        nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
        saved.append((mat, out, prev_link, emit))
    for mat in [m for m in target.data.materials if m]:
        node = mat.node_tree.nodes.new("ShaderNodeTexImage")
        node.image = image
        mat.node_tree.nodes.active = node
        added.append((mat, node))
    bpy.ops.object.select_all(action="DESELECT")
    if source is not None:
        source.select_set(True)
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.bake(type="EMIT")
    bake.use_selected_to_active = False
    scene.cycles.samples = prev
    for mat, out, prev_link, emit in saved:
        if prev_link is not None:
            mat.node_tree.links.new(prev_link, out.inputs["Surface"])
        mat.node_tree.nodes.remove(emit)
    for mat, node in added:
        mat.node_tree.nodes.remove(node)


def _pixels(image: bpy.types.Image):
    import numpy as np
    w, h = image.size
    px = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(px)
    return px.reshape(h, w, 4)[::-1]          # rows top-down, like the saved files


def curvature_map(low: bpy.types.Object, high: bpy.types.Object, size: int):
    """Mean curvature (1/m; positive on ridges) of the dense surface, in `low`'s UV layout, from its
    world-space shading normals (with the mail's rings) and positions. Unlike the
    tangent-space normal map, these carry no lines along the game mesh's edges or seams."""
    import numpy as np
    from scipy.ndimage import gaussian_filter

    def normal_socket(mat, nt):
        # bump detail counts only for mail: its rings are the form to paint, while leather grain,
        # cloth unevenness and hammer marks would come out as fine noise (DESIGN.md)
        bump = next((nd for nd in nt.nodes if nd.type == "BUMP"), None) if "_mail" in mat.name else None
        if bump is not None:
            src = bump.outputs["Normal"]
        else:
            src = nt.nodes.new("ShaderNodeNewGeometry").outputs["Normal"]
        m = nt.nodes.new("ShaderNodeVectorMath")
        m.operation = "MULTIPLY_ADD"
        m.inputs[1].default_value = (0.5, 0.5, 0.5)
        m.inputs[2].default_value = (0.5, 0.5, 0.5)
        nt.links.new(src, m.inputs[0])
        return m.outputs["Vector"]

    def position_socket(mat, nt):
        m = nt.nodes.new("ShaderNodeVectorMath")
        m.operation = "ADD"
        m.inputs[1].default_value = (10.0, 10.0, 10.0)     # positive everywhere: 0 means no texel
        nt.links.new(nt.nodes.new("ShaderNodeNewGeometry").outputs["Position"], m.inputs[0])
        return m.outputs["Vector"]

    if not high.data.materials:
        high.data.materials.append(bpy.data.materials.new("_plain"))
        high.data.materials[0].use_nodes = True
    cs = min(size, 2048)      # half size for 4096 px sets: the paint's forms do not need more, memory does
    out = {}
    for label, sock in (("n", normal_socket), ("p", position_socket)):
        img = bpy.data.images.new(f"_curv_{label}", cs, cs, alpha=True, float_buffer=True)
        img.colorspace_settings.name = "Non-Color"
        _emit_bake(low, img, sock, source=high)
        out[label] = np.ascontiguousarray(_pixels(img))
        bpy.data.images.remove(img)
    covered = out["p"][..., 0] > 1.0
    N = out.pop("n")[..., :3] * 2.0 - 1.0
    P = out.pop("p")[..., :3] - 10.0
    k = np.zeros(covered.shape, dtype=np.float32)
    ok = covered.copy()
    for axis in (1, 0):
        dot = np.zeros(covered.shape, dtype=np.float32)
        l2 = np.zeros(covered.shape, dtype=np.float32)
        for ch in range(3):          # channel by channel: whole (h, w, 3) gradients double the memory
            dp = np.gradient(P[..., ch], axis=axis)
            dot += np.gradient(N[..., ch], axis=axis) * dp
            l2 += dp * dp
        k += np.where(l2 > 1e-12, dot / np.maximum(l2, 1e-12), 0.0)
        t = np.median(np.sqrt(l2[covered])) if covered.any() else 1e-3
        ok &= np.sqrt(l2) < 4 * t     # neighbours on another island or the background: not the same surface
        ok &= np.roll(covered, 1, axis=axis) & np.roll(covered, -1, axis=axis)
    del N, P
    k = np.where(ok, k, 0.0)
    return gaussian_filter(k, 0.8), covered


def material_mask(low: bpy.types.Object, size: int, pick) -> "np.ndarray":
    """1 on texels of `low` whose material satisfies `pick(mat)` (cloth, for the cavity paint)."""
    def sock(mat, nt):
        rgb = nt.nodes.new("ShaderNodeRGB")
        v = 1.0 if pick(mat) else 0.0
        rgb.outputs[0].default_value = (v, v, v, 1.0)
        return rgb.outputs[0]
    size = min(size, 2048)
    img = bpy.data.images.new("_matmask", size, size, alpha=False, float_buffer=False)
    _emit_bake(low, img, sock)
    m = _pixels(img)[..., 0]
    bpy.data.images.remove(img)
    return m


CAVITY_LIFT, CAVITY_DARK, CAVITY_K, CAVITY_CLOTH = 0.22, 0.45, 110.0, 0.2


def paint_cavity(albedo: Path, curv, cloth=None) -> None:
    """Hollows darker and ridges lighter in the base colour (DESIGN.md: painted look), from the dense
    surface's curvature; cloth texels get CAVITY_CLOTH of the strength (their unevenness would read
    as grain)."""
    import numpy as np
    from PIL import Image
    a = np.asarray(Image.open(albedo).convert("RGB"), dtype=np.float32)
    c = curv if curv.shape[0] == a.shape[0] else np.asarray(
        Image.fromarray(curv.astype(np.float32)).resize((a.shape[1], a.shape[0]), Image.BILINEAR))
    base = CAVITY_LIFT * np.clip(c / CAVITY_K, 0, 1) - CAVITY_DARK * np.clip(-c / CAVITY_K, 0, 1)
    if cloth is not None and cloth.shape[0] != a.shape[0]:
        cloth = np.asarray(Image.fromarray(cloth.astype(np.float32)).resize((a.shape[1], a.shape[0]), Image.BILINEAR))
    strength = 1.0 if cloth is None else 1.0 - (1.0 - CAVITY_CLOTH) * cloth
    a = np.clip(a * (1.0 + strength * base)[..., None], 0, 255).astype(np.uint8)
    img = Image.fromarray(a, "RGB")
    if albedo.suffix.lower() in (".jpg", ".jpeg"):
        img.save(albedo, quality=92, subsampling=0)
    else:
        img.save(albedo)


def bake_asset(low: bpy.types.Object, high: bpy.types.Object | None, out_dir: Path, name: str,
               size: int = 2048, samples: int = 24, detail=None, cavity: float = 1.0) -> bpy.types.Material:
    """Unwrap `low`, bake albedo and roughness from its painted materials (kit.bake_piece) and,
    when `high` is given, a normal map from it; the low mesh ends with one plain material."""
    out_dir.mkdir(parents=True, exist_ok=True)
    unwrap(low, detail=detail)
    normal = None
    if high is not None:
        normal = bpy.data.images.new(f"{name}_normal", size, size, alpha=False)
        normal.colorspace_settings.name = "Non-Color"
        bake_normal(low, high, normal)
        curv, _cov = curvature_map(low, high, size)
        cloth = material_mask(low, size, lambda m: m.get("dye_channel") == "primary")
        normal.filepath_raw = str(out_dir / f"{normal.name}.png")
        normal.file_format = "PNG"
        normal.save()
        high.hide_render = True  # it overlaps the low surface: left visible it shadows the albedo's occlusion
    kit.bake_piece(low, out_dir, name, size=size, samples=samples, bevel_normal=0.0, keep_uvs=True)
    for suffix in ("albedo", "orm"):   # colour and roughness as JPEG: a quarter of the PNG's size
        img = bpy.data.images.get(f"{name}_{suffix}")
        png = out_dir / f"{name}_{suffix}.png"
        if img is None or not png.exists():
            continue
        from PIL import Image
        jpg = png.with_suffix(".jpg")
        Image.open(png).convert("RGB").save(jpg, quality=92, subsampling=0)
        png.unlink()
        if suffix == "albedo" and normal is not None:
            paint_cavity(jpg, curv * cavity, cloth if cloth.any() else None)
        img.filepath = str(jpg)
        img.source = "FILE"
        img.reload()
    mat = low.data.materials[0]
    if normal is not None:
        nt = mat.node_tree
        bsdf = nt.nodes["Principled BSDF"]
        t_nrm = nt.nodes.new("ShaderNodeTexImage")
        t_nrm.image = normal
        nmap = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(t_nrm.outputs["Color"], nmap.inputs["Color"])
        nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    return mat
