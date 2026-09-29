"""Weapons (backlog M1-18..M1-20): oversized, chunky, battle-worn.

  python3 tools/blender/build_weapon.py --spec data/assets/weapon_greatsword.json --previews previews/weapons

Pivot: the point the hand grips is the origin; the blade or head points up (+Z). In game the
weapon is attached to the hand bone at that point.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402  (must come before bmesh)
import bmesh  # noqa: E402

import common  # noqa: E402
import kit  # noqa: E402
from kit import block, cylinder, random_tint  # noqa: E402


def loft(name: str, stations: list[tuple[float, float, float]], mat, tint=(1, 1, 1)) -> bpy.types.Object:
    """A blade from diamond cross-sections: stations are (z, half width, half thickness); the
    last station closes to a point."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    rings = []
    for z, w, t in stations:
        if w <= 1e-4:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            rings.append([bm.verts.new(p) for p in ((w, 0, z), (0, -t, z), (-w, 0, z), (0, t, z))])
    for a, b in zip(rings, rings[1:]):
        if len(b) == 1:
            for i in range(4):
                bm.faces.new((a[i], a[(i + 1) % 4], b[0]))
        else:
            for i in range(4):
                bm.faces.new((a[i], a[(i + 1) % 4], b[(i + 1) % 4], b[i]))
    bm.faces.new(list(reversed(rings[0])))
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(mat)
    kit.set_tint(o, tint)
    return o


def greatsword(p: dict, m: dict, rng) -> list:
    """Two-handed sword, about 1.75 m: broad chipped blade, spiked crossguard, wrapped grip."""
    blade_len = p.get("blade_m", 1.22)
    grip = p.get("grip_m", 0.34)
    base_w = p.get("blade_width_m", 0.075)
    parts = []
    # blade: ricasso, a long gently tapering body with chips in both edges, then the point
    z0 = grip / 2 + 0.06
    stations = [(z0, base_w * 0.8, 0.018), (z0 + 0.08, base_w * 0.8, 0.018), (z0 + 0.1, base_w, 0.016)]
    n = 22
    for i in range(1, n):
        t = i / n
        z = z0 + 0.1 + t * (blade_len - 0.28)
        w = base_w * (1.0 - 0.28 * t)
        if rng.random() < 0.25:
            w *= rng.uniform(0.84, 0.93)  # a chip knocked out of the edge
        stations.append((z, w, 0.016 * (1 - 0.3 * t)))
    stations += [(z0 + blade_len - 0.1, base_w * 0.62, 0.011), (z0 + blade_len, 0.0, 0.0)]
    parts.append(loft("blade", stations, m["steel"], random_tint(rng, 0.04)))
    # fuller: a dark groove down the first two thirds, standing just proud of both faces
    for sy in (-1, 1):
        f = block("fuller", (0.022, 0.004, blade_len * 0.6), (0, sy * 0.012, z0 + 0.1 + blade_len * 0.3), bevel=0.001,
                  mat=m["dark"])
        parts.append(f)
    # crossguard: a heavy bar whose ends turn down into spikes
    cg_z = grip / 2 + 0.02
    parts.append(block("guard", (0.36, 0.06, 0.06), (0, 0, cg_z), bevel=0.012, segments=2, mat=m["iron"],
                       tint=random_tint(rng, 0.05)))
    for sx in (-1, 1):  # short, down-turned tips at the ends of the bar
        parts.append(kit.strut("guard_end", (sx * 0.17, 0, cg_z), (sx * 0.215, 0, cg_z - 0.05), 0.03, sides=6,
                               mat=m["iron"]))
        parts.append(cylinder("guard_tip", 0.03, 0.06, (sx * 0.228, 0, cg_z - 0.08), rot=(0, -sx * 0.4, 0),
                              sides=6, radius_top=0.004, mat=m["iron"]))
    parts.append(block("guard_boss", (0.1, 0.075, 0.09), (0, 0, cg_z), bevel=0.015, segments=2, mat=m["iron"]))
    # grip: leather wrap with raised bands
    parts.append(cylinder("grip", 0.022, grip, (0, 0, 0), sides=10, mat=m["leather"], tint=random_tint(rng, 0.06)))
    for i in range(7):
        z = -grip / 2 + grip * (i + 0.5) / 7
        bpy.ops.mesh.primitive_torus_add(major_radius=0.023, minor_radius=0.006, major_segments=10, minor_segments=4,
                                         location=(0, 0, z))
        band = bpy.context.active_object
        kit.clear_uvs(band)
        band.data.materials.append(m["leather"])
        kit.set_tint(band, (0.85, 0.85, 0.85))
        parts.append(band)
    # pommel: a heavy faceted weight with a short spike
    pz = -grip / 2 - 0.05
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.055, location=(0, 0, pz))
    pom = bpy.context.active_object
    kit.clear_uvs(pom)
    pom.scale = (1, 0.7, 1)
    pom.data.materials.append(m["iron"])
    kit.set_tint(pom, (1, 1, 1))
    parts.append(pom)
    parts.append(cylinder("pommel_spike", 0.022, 0.07, (0, 0, pz - 0.07), rot=(math.pi, 0, 0), sides=6,
                          radius_top=0.0, mat=m["iron"]))
    return parts


def staff(p: dict, m: dict, rng) -> list:
    """Frost staff, about 1.9 m: a slightly crooked wooden shaft with iron bands, three iron
    claws gripping a glowing ice crystal cluster. The grip (origin) is a third of the way down."""
    below, above = p.get("below_m", 0.95), p.get("above_m", 0.8)
    parts = []
    # shaft in segments with small kinks, thinning towards the top
    pts = [(rng.uniform(-0.01, 0.01), rng.uniform(-0.01, 0.01), z) for z in
           [-below + (below + above) * t for t in (0, 0.2, 0.42, 0.63, 0.82, 1.0)]]
    for i, (a, b) in enumerate(zip(pts, pts[1:])):
        r = 0.026 - 0.004 * i / len(pts)
        parts.append(kit.strut("shaft", a, b, r, sides=8, mat=m["wood"], tint=random_tint(rng, 0.08)))
        bpy.ops.mesh.primitive_uv_sphere_add(segments=8, ring_count=5, radius=r * 1.05, location=b)
        knot = bpy.context.active_object  # rounds each kink
        kit.clear_uvs(knot)
        knot.data.materials.append(m["wood"])
        kit.set_tint(knot, (1, 1, 1))
        parts.append(knot)
    for z in (-below + 0.03, -0.25, 0.25, above - 0.12):  # iron bands and ferrule
        parts.append(cylinder("band", 0.031, 0.05 if z > -below + 0.1 else 0.09, (0, 0, z), sides=8, mat=m["iron"]))
    parts.append(cylinder("ferrule_tip", 0.03, 0.08, (0, 0, -below - 0.03), rot=(math.pi, 0, 0), sides=8,
                          radius_top=0.006, mat=m["iron"]))
    # claws
    top = above
    for k in range(3):
        a = k * math.tau / 3
        base = (math.cos(a) * 0.02, math.sin(a) * 0.02, top - 0.1)
        mid = (math.cos(a) * 0.16, math.sin(a) * 0.16, top + 0.1)
        tip = (math.cos(a) * 0.08, math.sin(a) * 0.08, top + 0.36)
        parts.append(kit.strut("claw", base, mid, 0.018, sides=6, mat=m["iron"]))
        parts.append(kit.strut("claw_tip", mid, tip, 0.016, sides=6, mat=m["iron"]))
    # crystal cluster: a tall main shard and smaller ones, glowing
    for (dx, dy, h, r, tilt) in ((0.0, 0.0, 0.58, 0.095, 0.0), (0.08, 0.03, 0.32, 0.055, 0.35),
                                 (-0.065, 0.06, 0.29, 0.05, -0.3), (0.015, -0.08, 0.26, 0.045, 0.3)):
        c = (dx, dy, top + 0.12 + h * 0.2)
        bpy.ops.mesh.primitive_cone_add(vertices=6, radius1=r, radius2=0.0, depth=h * 0.6,
                                        location=(c[0], c[1], c[2] + h * 0.3), rotation=(tilt, tilt * 0.5, 0))
        upper = bpy.context.active_object
        bpy.ops.mesh.primitive_cone_add(vertices=6, radius1=r, radius2=0.0, depth=h * 0.35,
                                        location=(c[0], c[1], c[2] - h * 0.175 + 0.0), rotation=(math.pi + tilt, -tilt * 0.5, 0))
        lower = bpy.context.active_object
        for o in (upper, lower):
            kit.clear_uvs(o)
            o.data.materials.append(m["frost"])
            kit.set_tint(o, random_tint(rng, 0.05))
            parts.append(o)
    return parts


def mace(p: dict, m: dict, rng) -> list:
    """One-handed flanged mace, about 0.8 m: wrapped grip, iron shaft, a head of six flanges
    around a gold-banded core with a short top spike."""
    grip = p.get("grip_m", 0.2)
    shaft = p.get("shaft_m", 0.42)
    parts = [cylinder("grip", 0.021, grip, (0, 0, 0), sides=8, mat=m["leather"], tint=random_tint(rng, 0.05))]
    parts.append(cylinder("pommel", 0.035, 0.05, (0, 0, -grip / 2 - 0.02), sides=8, radius_top=0.024, mat=m["gold"]))
    parts.append(cylinder("shaft", 0.019, shaft, (0, 0, grip / 2 + shaft / 2), sides=8, mat=m["iron"]))
    hz = grip / 2 + shaft + 0.07
    parts.append(cylinder("core", 0.045, 0.2, (0, 0, hz), sides=8, mat=m["iron"]))
    for z in (hz - 0.1, hz + 0.1):
        parts.append(cylinder("ring", 0.052, 0.025, (0, 0, z), sides=8, mat=m["gold"]))
    for k in range(6):
        a = k * math.tau / 6
        f = block("flange", (0.095, 0.018, 0.22), (math.cos(a) * 0.085, math.sin(a) * 0.085, hz), rot=(0, 0, a),
                  bevel=0.006, mat=m["iron"], tint=random_tint(rng, 0.05))
        for v in f.data.vertices:  # the outer edge comes to a point at mid-height (a leaf shape)
            radial = v.co.x * math.cos(a) + v.co.y * math.sin(a)
            if radial > 0.09:
                rel = abs(v.co.z - hz) / 0.11
                pull = 0.075 * rel ** 1.5
                v.co.x -= math.cos(a) * pull
                v.co.y -= math.sin(a) * pull
        parts.append(f)
    parts.append(cylinder("spike", 0.03, 0.1, (0, 0, hz + 0.16), sides=8, radius_top=0.003, mat=m["gold"]))
    return parts


WEAPONS = {"greatsword": greatsword, "staff": staff, "mace": mace}


def main() -> None:
    args = common.parse_args("Build a weapon")
    spec = common.load_spec(args.spec)
    common.reset_scene()
    rng = common.seeded_random(spec["seed"])
    pal = spec.get("palette", {})
    m = {
        "steel": kit.kit_material("steel", pal.get("steel", "#8d9299"), roughness=0.35, metallic=0.3, edge=0.55,
                                  cavity=0.4, top_light=0.1, mottle=0.12, mottle_scale=3.0),
        "dark": kit.kit_material("dark", pal.get("dark", "#3a3c40"), roughness=0.5, metallic=0.3, edge=0.2),
        "iron": kit.kit_material("iron", pal.get("iron", "#45474d"), roughness=0.5, metallic=0.3, edge=0.6),
        "leather": kit.kit_material("leather", pal.get("leather", "#3f2a1d"), roughness=0.85, edge=0.25),
        "wood": kit.kit_material("wood", pal.get("wood", "#5a3f2a"), roughness=0.8, edge=0.3, mottle=0.2,
                                 mottle_scale=4.0),
        "frost": kit.kit_material("frost", pal.get("frost", "#9fe6ff"), roughness=0.15, edge=0.5, cavity=0.2,
                                  emission=1.5),
        "gold": kit.kit_material("gold", pal.get("gold", "#b08a3e"), roughness=0.4, metallic=0.3, edge=0.6),
    }
    parts = WEAPONS[spec["params"]["type"]](spec["params"], m, rng)
    kit.apply_transforms(parts)
    obj = common.join_objects(parts, spec["id"])
    fused = kit.fuse_touching_parts(obj)
    if fused:
        print(f"  fused touching parts: removed {fused} coincident faces")
    kit.shade_smooth_by_angle(obj, 30)
    kit.bake_piece(obj, common.REPO / "previews" / "kit_textures", spec["id"], size=int(spec.get("texture_size", 1024)),
                   samples=32, bevel_normal=0.004)
    tris = common.triangle_count([obj])
    if args.previews:
        common.render_contact_sheet([obj], args.previews / f"{spec['id']}_sheet.png", cell=512, title=f"{spec['id']} {tris} tris")
    common.export_glb(Path(spec["out"]), [obj])
    print(f"BUILT {spec['id']} tris={tris}")


if __name__ == "__main__":
    main()
