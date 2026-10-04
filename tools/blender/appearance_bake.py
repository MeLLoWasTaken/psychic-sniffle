"""Creator masks for the overhaul bodies (backlog G-02).

The character shader (G-05) recolours a body from masks in the body's UV layout:
- `<id>_mask.png`: R = iris, G = skin (0 on the whites of the eyes and the iris), B = lips.
- `<id>_marks_a.png`, `<id>_marks_b.png`: one scar or war-paint layer per channel, in the order of
  data/appearance/markings.json (after "none").

Masks are computed per texel from a baked position map: every texel's point on the body in
head-local coordinates (anatomy.head_frame), so a marking is a small distance function on the
face rather than paint on a UV layout that changes whenever the mesh does.
"""
from __future__ import annotations

from pathlib import Path

import bpy
import numpy as np

import anatomy

EYE = np.array([0.031, -0.082, 0.12])       # eyeball centre, head-local (anatomy.add_head)
EYE_R = 0.0122
IRIS_R = 0.0063


def bake_positions(obj: bpy.types.Object, size: int) -> tuple[np.ndarray, np.ndarray]:
    """World position of every texel of `obj`'s UV layout: (size x size x 3, covered mask)."""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    img = bpy.data.images.new(f"{obj.name}_pos", size, size, alpha=True, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    mat = bpy.data.materials.new(f"{obj.name}_posbake")
    mat.use_nodes = True
    nt = mat.node_tree
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    add = nt.nodes.new("ShaderNodeVectorMath")
    add.operation = "ADD"
    add.inputs[1].default_value = (10.0, 10.0, 10.0)   # positive everywhere, so 0 means "no texel"
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(geo.outputs["Position"], add.inputs[0])
    nt.links.new(add.outputs["Vector"], emit.inputs["Color"])
    nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.nodes.active = tex
    saved = list(obj.data.materials)
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    samples = scene.cycles.samples
    scene.cycles.samples = 1
    scene.render.bake.use_selected_to_active = False
    scene.render.bake.margin = 4
    bpy.ops.object.bake(type="EMIT")
    scene.cycles.samples = samples
    obj.data.materials.clear()
    for m in saved:
        obj.data.materials.append(m)
    px = np.empty(size * size * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    px = px.reshape(size, size, 4)
    covered = px[..., 0] > 1.0
    pos = px[..., :3] - 10.0
    bpy.data.images.remove(img)
    bpy.data.materials.remove(mat)
    return pos, covered


def _smooth(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def _segment_dist2(L, a, b):
    """Distance in the face's front view (x, z) from points to a segment a-b given as (x, z)."""
    p = L[..., [0, 2]]
    a, b = np.asarray(a, float), np.asarray(b, float)
    ab = b - a
    t = np.clip(((p - a) @ ab) / (ab @ ab), 0.0, 1.0)
    return np.linalg.norm(p - (a + t[..., None] * ab), axis=-1)


def _stroke(L, a, b, width, soft=0.0012):
    """A painted or scarred stroke from a to b, drawn in the front view (x, z, head-local)."""
    return 1.0 - _smooth(width * 0.5 - soft, width * 0.5 + soft, _segment_dist2(L, a, b))


def front(L):
    """1 on the face (in front of the ears); paint and scars never wrap round to the back."""
    return _smooth(0.0, -0.035, L[..., 1])


def markings(L) -> dict[str, np.ndarray]:
    """Mask per marking id (data/appearance/markings.json), from head-local texel positions,
    drawn in the front view. Paint is mirrored to both sides; scars sit on one side."""
    Lm = np.stack([np.abs(L[..., 0]), L[..., 1], L[..., 2]], axis=-1)
    f = front(L)
    x = np.abs(L[..., 0])
    return {
        "brow_scar": _stroke(L, (0.05, 0.168), (0.024, 0.098), 0.0065) * f,
        "cheek_scar": _stroke(L, (-0.062, 0.112), (-0.026, 0.058), 0.006) * f,
        "lip_scar": _stroke(L, (0.012, 0.074), (0.007, 0.034), 0.0055) * f,
        "stripes": np.maximum.reduce([_stroke(Lm, (0.03, 0.102 - 0.013 * i), (0.072, 0.11 - 0.013 * i), 0.007)
                                      for i in range(3)]) * f,
        "eye_band": (1.0 - _smooth(0.015, 0.018, np.abs(L[..., 2] - 0.122))) * _smooth(0.08, 0.075, x) * f,
        "jaw_lines": np.maximum.reduce([_stroke(Lm, (0.012, 0.012 + 0.014 * i), (0.055, 0.04 + 0.014 * i), 0.006)
                                        for i in range(2)]) * f,
    }


def write_masks(obj: bpy.types.Object, j: dict, body_type: str, out_dir: Path, name: str, size: int = 2048,
                mask_size: int = 1024, albedo: bpy.types.Image | None = None) -> list[Path]:
    """Compute the masks at `size` (the albedo's size), save them at `mask_size`, and paint the
    eyes (whites, a neutral iris the shader tints, pupils) into `albedo`."""
    from PIL import Image
    pos, covered = bake_positions(obj, size)
    hz, s = anatomy.head_frame(j, body_type)
    L = np.stack([pos[..., 0] / s, pos[..., 1] / s, (pos[..., 2] - hz) / s], axis=-1)
    on_head = covered & (L[..., 2] > -0.02)
    eye_l = np.stack([np.abs(L[..., 0]), L[..., 1], L[..., 2]], axis=-1)
    d_eye = np.linalg.norm(eye_l - EYE, axis=-1)
    on_eye = on_head & (d_eye < EYE_R + 0.0015)
    axis_d = np.linalg.norm((eye_l - EYE)[..., [0, 2]], axis=-1)
    iris = on_eye & (eye_l[..., 1] < EYE[1] - EYE_R * 0.6)
    iris_m = iris * (1.0 - _smooth(IRIS_R - 0.0006, IRIS_R + 0.0006, axis_d))
    skin = np.where(on_eye, 0.0, 1.0) * covered
    lips = on_head * (1.0 - _smooth(0.0, 0.004, np.linalg.norm((L - np.array([0.0, -0.096, 0.052])) / np.array([1.0, 0.6, 0.62]),
                                                                axis=-1) - 0.022))
    paths = []
    rgb = np.stack([iris_m, skin, lips], axis=-1)
    marks = markings(L)
    ids = list(marks)
    layers = [rgb, np.stack([marks[i] * on_head for i in ids[0:3]], axis=-1),
              np.stack([marks[i] * on_head for i in ids[3:6]], axis=-1)]
    out_dir.mkdir(parents=True, exist_ok=True)
    for suffix, arr in zip(("mask", "marks_a", "marks_b"), layers):
        img = Image.fromarray((np.clip(arr, 0, 1)[::-1] * 255).astype(np.uint8), "RGB")   # Blender rows run bottom-up
        if mask_size != size:
            img = img.resize((mask_size, mask_size), Image.LANCZOS)
        p = out_dir / f"{name}_{suffix}.png"
        img.save(p)
        paths.append(p)
    if albedo is not None:
        px = np.empty(size * size * 4, dtype=np.float32)
        albedo.pixels.foreach_get(px)
        px = px.reshape(size, size, 4)
        white = np.array([0.72, 0.68, 0.63])     # linear-ish values as Blender stores them
        iris_col = np.array([0.22, 0.22, 0.22])
        rim = _smooth(IRIS_R - 0.0014, IRIS_R, axis_d)                   # darker ring at the iris edge
        pupil = 1.0 - _smooth(0.0019, 0.0024, axis_d)
        eye_col = white[None, None, :] * (1 - iris_m[..., None]) + (iris_col * (1 - 0.5 * rim[..., None])) * iris_m[..., None]
        eye_col = eye_col * (1 - (pupil * iris)[..., None]) + 0.01 * (pupil * iris)[..., None]
        sel = on_eye
        px[sel, :3] = eye_col[sel]
        albedo.pixels.foreach_set(px.ravel())
        albedo.update()
        albedo.save()
    print(f"  masks {name}: iris texels {int(iris.sum())}, eye texels {int(on_eye.sum())}", flush=True)
    return paths
