"""Armor sets built as signed distance fields around a body (backlog M1-18..M1-20).

Body-hugging plates are shells: the layer between two outward offsets of the body's own
distance field, cut to a region with planes. They fit any build automatically. Designed parts
(helmet, pauldrons, horns, spikes) are built from primitives. Each piece rides on one bone
(rigid parenting, docs/DESIGN.md "Asset pipeline").

Pure numpy. Coordinates: metres, +Z up, the character faces -Y, its left is +X.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

import body_sdf
import sdf


@dataclass
class Piece:
    name: str
    bone: str
    material: str
    fn: object                      # distance function of points
    lo: np.ndarray
    hi: np.ndarray
    tris: int                       # triangle target after reduction
    facet_deg: float = 25.0         # flat-shade edges sharper than this (angular plate look)
    voxel: float = 0.006
    rivets: list = field(default_factory=list)  # (position, outward normal) pairs
    skin: str = "rigid"             # "rigid": all on `bone`; "transfer": weights copied from the body (cloth)
    skirt: bool = False             # below the waist: follow the pelvis more and both thighs together


def _grad(fn, p, eps=1e-3):
    """Outward normal of a field at a point (numerical gradient)."""
    P = np.array([p + d for d in np.eye(3) * eps] + [p - d for d in np.eye(3) * eps])
    v = fn(P)
    g = v[:3] - v[3:]
    return g / (np.linalg.norm(g) + 1e-12)


def _project(fn, p, iters=12):
    """Move a point onto the zero surface of fn along the gradient."""
    p = np.array(p, float)
    for _ in range(iters):
        d = fn(p[None])[0]
        p = p - _grad(fn, p) * d
    return p


def _rivet_ring(fn, centre, radius, axis_a, axis_b, count, arc=(0.0, 2 * np.pi)):
    """Rivets on a surface, found by projecting points of a circle onto it."""
    out = []
    for t in np.linspace(arc[0], arc[1], count, endpoint=arc[1] - arc[0] < 2 * np.pi - 1e-6):
        guess = centre + radius * (np.cos(t) * axis_a + np.sin(t) * axis_b)
        p = _project(fn, guess)
        out.append((p, _grad(fn, p)))
    return out


def warblade_plate(j: dict, build: str = "heavy", hands: tuple[str, str] = ("relaxed", "fist")) -> list[Piece]:
    """Angular blackened plate: great helm with horns, spiked layered pauldrons, keeled
    breastplate over a plackart, belt, tassets, cuisses, knee cops, greaves, sabatons,
    rerebraces, elbow cops, vambraces and gauntlets."""
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    body = body_sdf.body_shape(j, build, hands)
    ev = lambda names: (lambda P, s=sdf.subset(body, names): sdf.eval_points(s, P))  # noqa: E731
    torso = ev({"pelvis", "abdomen", "ribcage", "girdle", "pec", "lat", "trap", "glute"})
    z = lambda name: float(j[name][2])  # noqa: E731
    pieces: list[Piece] = []

    # ---- breastplate (chest) with a central keel, and plackart (spine) --------------------------
    top = z("chest_top") + 0.035
    breast_bottom = z("chest") - 0.12
    sh_l, sh_r = j["shoulder_l"], j["shoulder_r"]

    def breastplate(P):
        base = torso(P)
        # a vertical fin down the sternum: the plate rises to a ridge over it
        keel = sdf.sd_round_box(P, v(0, -0.12, z("chest") + 0.02), (0.012, 0.1, 0.2), 0.012)
        base = sdf.smin(base, keel, 0.07)
        d = sdf.shell(lambda Q: base, P, 0.012, 0.05)
        d = np.maximum(d, sdf.half_space(P, v(0, 0, top), (0, 0, 1)))           # neck line
        d = np.maximum(d, -sdf.half_space(P, v(0, 0, breast_bottom), (0, 0, 1)))
        for s, sxa in ((sh_l, 1.0), (sh_r, -1.0)):  # small arm holes, set out under the pauldrons
            d = np.maximum(d, -(np.linalg.norm(P - (s + v(sxa * 0.05, 0, -0.03)), axis=1) - 0.11))
        neck = np.linalg.norm(P[:, :2] - v(0, 0.01)[None, :2], axis=1) - 0.12
        d = np.maximum(d, -np.where(P[:, 2] > top - 0.08, neck, 1.0))
        return d
    lo, hi = v(-0.4, -0.3, breast_bottom - 0.05), v(0.4, 0.3, top + 0.05)
    pieces.append(Piece("breastplate", "chest", "plate", breastplate, lo, hi, 2000, rivets=[]))

    plack_top = z("chest") - 0.1
    plack_bottom = z("spine") - 0.09

    def plackart(P):
        d = sdf.shell(torso, P, 0.02, 0.062)
        d = np.maximum(d, sdf.half_space(P, v(0, 0, plack_top), (0, 0, 1)))
        return np.maximum(d, -sdf.half_space(P, v(0, 0, plack_bottom), (0, 0, 1)))
    pieces.append(Piece("plackart", "spine", "plate", plackart, v(-0.35, -0.3, plack_bottom - 0.05),
                        v(0.35, 0.3, plack_top + 0.05), 900))

    # ---- belt with a buckle (pelvis) ------------------------------------------------------------
    belt_z = z("spine") - 0.13

    def belt(P):
        d = sdf.shell(torso, P, 0.03, 0.075)
        d = np.maximum(d, np.abs(P[:, 2] - belt_z) - 0.045)
        buckle = sdf.sd_round_box(P, v(0, -0.18, belt_z), (0.06, 0.03, 0.055), 0.012)
        return sdf.smin(d, buckle, 0.01)
    belt_fn = belt
    pieces.append(Piece("belt", "pelvis", "leather", belt, v(-0.32, -0.28, belt_z - 0.1), v(0.32, 0.28, belt_z + 0.1),
                        700, facet_deg=40, rivets=_rivet_ring(belt_fn, v(0, 0, belt_z), 0.25, v(1, 0, 0), v(0, 1, 0), 10,
                                                              arc=(0.3, np.pi * 2 - 0.3))))

    # ---- per side (left; mirrored copies are made for the right) --------------------------------
    # One function call per side, so the plate functions defined inside capture that side's
    # joints (a plain loop would leave every closure pointing at the last side's values).
    def one_side(side: str, sx: float) -> None:
        M = np.array([sx, 1.0, 1.0])
        J = {k: j[k] for k in j}
        hip, knee, ankle, toe = J[f"hip_{side}"], J[f"knee_{side}"], J[f"ankle_{side}"], J[f"toe_{side}"]
        sh, el, wr, he = J[f"shoulder_{side}"], J[f"elbow_{side}"], J[f"wrist_{side}"], J[f"hand_end_{side}"]

        def mirror(names):
            # left-side body parts only (no mirrored copies); the right side reuses them mirrored
            left = sdf.Shape([p for p in body.prims if p.name in names])
            f = lambda P, s=left: sdf.eval_points(s, P)  # noqa: E731
            return (lambda P, f=f: f(P * M)) if sx < 0 else f
        legf = mirror({"thigh", "quad", "adductor", "knee"})
        shinf = mirror({"shin", "calf", "knee"})
        footf = mirror({"foot", "instep"})
        armf = mirror({"upperarm", "bicep", "tricep", "deltoid"})
        foref = mirror({"forearm", "forearm_mass"})
        handf = hand_field(body, side)

        # tassets: two overlapping lames hanging from the belt over the front and side of the thigh
        for i, (t0, t1, off) in enumerate(((belt_z - 0.02, belt_z - 0.17, 0.07), (belt_z - 0.14, belt_z - 0.29, 0.085))):
            def tasset(P, t0=t0, t1=t1, off=off):
                d = sdf.shell(lambda Q: np.minimum(torso(Q), legf(Q)), P, off - 0.03, off)
                d = np.maximum(d, sdf.half_space(P, v(0, 0, t0), (0, 0, 1)))
                d = np.maximum(d, -sdf.half_space(P, v(0, 0, t1), (0, 0, 1)))
                d = np.maximum(d, sdf.half_space(P, v(0, 0.03, 0), (0, 1, 0)))      # front and side only
                d = np.maximum(d, -sdf.half_space(P, v(sx * 0.03, 0, 0), (sx, 0, 0)))  # this side only
                return d
            c = hip + v(sx * 0.06, -0.05, 0)
            pieces.append(Piece(f"tasset{i}_{side}", f"thigh_{side}", "plate", tasset,
                                v(min(c[0] - 0.3, c[0] + 0.3), -0.3, t1 - 0.04), v(max(c[0] - 0.3, c[0] + 0.3), 0.1, t0 + 0.04), 350))

        # cuisse: plate over the front of the thigh
        def cuisse(P):
            d = sdf.shell(legf, P, 0.016, 0.042)
            d = np.maximum(d, sdf.half_space(P, v(0, 0, belt_z - 0.3), (0, 0, 1)))
            d = np.maximum(d, -sdf.half_space(P, knee + v(0, 0, 0.09), (0, 0, 1)))
            return np.maximum(d, sdf.half_space(P, v(0, 0.02, 0), (0, 1, 0)))
        pieces.append(Piece(f"cuisse_{side}", f"thigh_{side}", "plate", cuisse, np.minimum(hip, knee) - 0.2,
                            np.maximum(hip, knee) + 0.2, 450))

        # knee cop: a pointed dome with a side wing
        def poleyn(P):
            c = knee + v(0, -0.06, 0.0)
            dome = sdf.sd_ellipsoid(P, c, (0.085, 0.06, 0.085))
            inner = sdf.sd_ellipsoid(P, c + v(0, 0.02, 0), (0.07, 0.05, 0.07))
            d = np.maximum(dome, -inner)
            point = sdf.sd_round_cone(P, c + v(0, -0.03, 0), c + v(0, -0.085, 0.01), 0.03, 0.004)
            wing = sdf.sd_ellipsoid(P, c + v(sx * 0.07, 0.02, 0), (0.02, 0.05, 0.065))
            return sdf.smin(sdf.smin(d, point, 0.01), wing, 0.015)
        pieces.append(Piece(f"poleyn_{side}", f"calf_{side}", "plate", poleyn, knee - 0.18, knee + 0.18, 350, voxel=0.004))

        # greave: full plate around the shin and calf
        def greave(P):
            d = sdf.shell(shinf, P, 0.014, 0.04)
            d = np.maximum(d, sdf.half_space(P, knee - v(0, 0, 0.07), (0, 0, 1)))
            return np.maximum(d, -sdf.half_space(P, ankle + v(0, 0, 0.05), (0, 0, 1)))
        pieces.append(Piece(f"greave_{side}", f"calf_{side}", "plate", greave, np.minimum(knee, ankle) - 0.18,
                            np.maximum(knee, ankle) + 0.18, 600))

        # sabaton: plated boot with a pointed toe
        def sabaton(P):
            d = sdf.shell(footf, P, -0.02, 0.022)
            d = np.maximum(d, sdf.half_space(P, ankle + v(0, 0, 0.07), (0, 0, 1)))
            tip = sdf.sd_round_cone(P, toe + v(0, 0.03, 0.025), toe + v(0, -0.05, 0.015), 0.03, 0.006)
            return sdf.smin(d, tip, 0.03)
        pieces.append(Piece(f"sabaton_{side}", f"foot_{side}", "plate", sabaton,
                            np.minimum(ankle, toe) - v(0.15, 0.15, 0.1), np.maximum(ankle, toe) + v(0.15, 0.15, 0.15), 600))

        # pauldron: a big spiked dome over the shoulder with two lames below it
        out = v(sx, 0, 0.35)
        out = out / np.linalg.norm(out)
        pc = sh + v(sx * 0.02, 0.0, 0.05)

        def pauldron(P, pc=pc, out=out):
            dome = sdf.sd_ellipsoid(P, pc, (0.2, 0.21, 0.17))
            inner = sdf.sd_ellipsoid(P, pc, (0.165, 0.175, 0.135))
            d = np.maximum(dome, -inner)
            d = np.maximum(d, -sdf.half_space(P, pc - out * 0.07, out))  # keep the outer cap
            for k in range(3):  # spikes along the crest
                a = pc + out * 0.16 + v(0, (k - 1) * 0.1, 0.03 - abs(k - 1) * 0.02)
                spike = sdf.sd_round_cone(P, a - out * 0.03, a + (out * 0.9 + v(0, 0, 0.35)) * (0.17 - abs(k - 1) * 0.04),
                                          0.035, 0.003)
                d = sdf.smin(d, spike, 0.012)
            for i in range(2):  # lames
                c = pc - v(0, 0, 0.1 + 0.07 * i) + v(sx * 0.03 * (i + 1), 0, 0)
                ring = np.maximum(sdf.sd_ellipsoid(P, c, (0.185 - 0.015 * i, 0.19 - 0.015 * i, 0.12)),
                                  -sdf.sd_ellipsoid(P, c, (0.155 - 0.015 * i, 0.16 - 0.015 * i, 0.11)))
                ring = np.maximum(ring, -sdf.half_space(P, c - out * 0.02, out))
                ring = np.maximum(ring, np.abs(P[:, 2] - c[2]) - 0.03)
                d = np.minimum(d, ring)
            return d
        pieces.append(Piece(f"pauldron_{side}", f"upperarm_{side}", "plate", pauldron, pc - 0.4, pc + 0.45, 1150,
                            voxel=0.005, rivets=_rivet_ring(pauldron, pc - out * 0.03, 0.2, v(0, 1, 0),
                                                            np.cross(out, v(0, 1, 0)), 9, arc=(-1.2, 1.2))))

        def pauldron_rim(P, pc=pc, out=out):
            rim = np.maximum(sdf.sd_ellipsoid(P, pc, (0.215, 0.225, 0.185)), -sdf.sd_ellipsoid(P, pc, (0.19, 0.2, 0.16)))
            return np.maximum(rim, np.abs(sdf.half_space(P, pc - out * 0.055, out)) - 0.02)
        pieces.append(Piece(f"pauldron_rim_{side}", f"upperarm_{side}", "trim", pauldron_rim, pc - 0.3, pc + 0.3, 400,
                            voxel=0.005, facet_deg=40))

        # rerebrace: plate over the outer upper arm
        def rerebrace(P):
            d = sdf.shell(armf, P, 0.012, 0.036)
            axis = (el - sh) / np.linalg.norm(el - sh)
            t = (P - sh) @ axis
            d = np.maximum(d, np.maximum(0.13 - t, t - (np.linalg.norm(el - sh) - 0.06)))
            return d
        pieces.append(Piece(f"rerebrace_{side}", f"upperarm_{side}", "plate", rerebrace, np.minimum(sh, el) - 0.15,
                            np.maximum(sh, el) + 0.15, 450))

        # couter: elbow cop with a short spike
        def couter(P):
            c = el + v(0, 0.05, 0)
            dome = np.maximum(sdf.sd_ellipsoid(P, c, (0.07, 0.055, 0.07)), -sdf.sd_ellipsoid(P, c + v(0, -0.02, 0), (0.058, 0.045, 0.058)))
            spike = sdf.sd_round_cone(P, c + v(0, 0.03, 0), c + v(0, 0.1, -0.01), 0.022, 0.003)
            return sdf.smin(dome, spike, 0.01)
        pieces.append(Piece(f"couter_{side}", f"forearm_{side}", "plate", couter, el - 0.15, el + 0.2, 300, voxel=0.004))

        # vambrace: flared cuff over the forearm
        def vambrace(P):
            axis = (wr - el) / np.linalg.norm(wr - el)
            t = (P - el) @ axis
            L = np.linalg.norm(wr - el)
            flare = np.clip((t - 0.6 * L) / (0.4 * L), 0, 1) * 0.03
            d = sdf.shell(foref, P, 0.014, 0.04) - flare
            return np.maximum(d, np.maximum(0.07 - t, t - (L + 0.02)))
        pieces.append(Piece(f"vambrace_{side}", f"forearm_{side}", "plate", vambrace, np.minimum(el, wr) - 0.16,
                            np.maximum(el, wr) + 0.16, 500))

        # gauntlet: a thin plated glove (fingers stay separate) and a flared cuff (a raised
        # knuckle plate was tried and read as a floating slab on the fist)
        cuff_axis = (wr - el) / np.linalg.norm(wr - el)

        def gauntlet(P):
            d = sdf.shell(handf, P, -0.004, 0.0075)
            cuff = sdf.sd_round_cone(P, wr - cuff_axis * 0.075, wr + cuff_axis * 0.012, 0.075, 0.062)
            cuff = np.maximum(cuff, -sdf.sd_round_cone(P, wr - cuff_axis * 0.09, wr + cuff_axis * 0.02, 0.066, 0.052))
            return np.minimum(d, cuff)
        pieces.append(Piece(f"gauntlet_{side}", f"hand_{side}", "plate", gauntlet, np.minimum(wr, he) - 0.14,
                            np.maximum(wr, he) + 0.14, 1100, facet_deg=35, voxel=0.003))

    one_side("l", 1.0)
    one_side("r", -1.0)

    # ---- helmet (head): a closed great helm with a T-shaped visor, crest and forward horns -------
    hz = z("head")
    hc = v(0, 0.0, hz + 0.12)

    def helm(P):
        shell_out = sdf.sd_round_box(P, hc + v(0, -0.01, 0.0), (0.125, 0.14, 0.16), 0.09)
        dome = sdf.sd_ellipsoid(P, hc + v(0, 0.0, 0.06), (0.135, 0.15, 0.13))
        outer = sdf.smin(shell_out, dome, 0.03)
        inner = sdf.sd_round_box(P, hc + v(0, 0.0, -0.01), (0.1, 0.115, 0.15), 0.07)
        d = np.maximum(outer, -inner)
        d = np.maximum(d, -sdf.half_space(P, v(0, 0, hz - 0.075), (0, 0, 1)))    # open at the neck
        visor = sdf.sd_round_box(P, hc + v(0, -0.15, 0.02), (0.085, 0.06, 0.012), 0.006)
        breath = sdf.sd_round_box(P, hc + v(0, -0.15, -0.05), (0.012, 0.06, 0.06), 0.006)
        d = np.maximum(d, -np.minimum(visor, breath))
        crest = sdf.sd_round_box(P, hc + v(0, 0.0, 0.18), (0.012, 0.14, 0.03), 0.01)
        d = sdf.smin(d, crest, 0.02)
        for sxh in (1, -1):  # horns sweeping out, up and forward
            pts = [hc + v(sxh * 0.12, 0.02, 0.06), hc + v(sxh * 0.25, 0.0, 0.1), hc + v(sxh * 0.36, -0.06, 0.2),
                   hc + v(sxh * 0.38, -0.16, 0.33), hc + v(sxh * 0.33, -0.25, 0.42)]
            radii = [0.05, 0.042, 0.03, 0.017, 0.003]
            for a, b, r1, r2 in zip(pts, pts[1:], radii, radii[1:]):
                d = sdf.smin(d, sdf.sd_round_cone(P, a, b, r1, r2), 0.02)
        return d
    pieces.append(Piece("helm", "head", "plate", helm, hc - v(0.5, 0.4, 0.3), hc + v(0.5, 0.3, 0.6), 2400, voxel=0.005,
                        facet_deg=35,
                        rivets=_rivet_ring(helm, hc + v(0, 0, -0.07), 0.16, v(1, 0, 0), v(0, 1, 0), 12,
                                           arc=(0.25, np.pi - 0.25))))

    def helm_band(P):  # a brass band around the helm just above the visor
        outer = sdf.sd_round_box(P, hc + v(0, -0.01, 0.0), (0.135, 0.15, 0.16), 0.09)
        inner = sdf.sd_round_box(P, hc + v(0, -0.01, 0.0), (0.12, 0.135, 0.17), 0.085)
        band = np.maximum(outer, -inner)
        return np.maximum(band, np.abs(P[:, 2] - (hc[2] + 0.06)) - 0.022)
    pieces.append(Piece("helm_band", "head", "trim", helm_band, hc - 0.3, hc + 0.3, 350, voxel=0.005, facet_deg=40))

    # ---- gorget (chest): a collar of plate around the neck ------------------------------------
    def gorget(P):
        c = v(0, 0.02, z("chest_top") + 0.05)
        ring = np.maximum(sdf.sd_ellipsoid(P, c, (0.17, 0.15, 0.08)), -sdf.sd_ellipsoid(P, c, (0.13, 0.11, 0.1)))
        return np.maximum(ring, -sdf.half_space(P, c - v(0, 0, 0.05), (0, 0, 1)))
    pieces.append(Piece("gorget", "chest", "plate", gorget, v(-0.3, -0.3, z("chest_top") - 0.1),
                        v(0.3, 0.3, z("chest_top") + 0.2), 450))
    return pieces


def hand_field(body: sdf.Shape, side: str):
    """Distance to one hand (built per side, so a fist and a relaxed hand can differ)."""
    parts = {"palm", "finger0", "finger1", "finger2", "finger3", "thumb"}
    hand = sdf.Shape([p for p in body.prims if p.name.rsplit("_", 1)[0] in parts and p.name.endswith("_" + side)])
    return lambda P, s=hand: sdf.eval_points(s, P)


def _jagged(P, z_hem, depth, count, seed):
    """Distance-like term that eats a torn, jagged hem upward from z_hem (points hang down)."""
    rng = np.random.default_rng(seed)
    phases = rng.uniform(0, 2 * np.pi, 3)
    ang = np.arctan2(P[:, 1], P[:, 0])
    tear = (0.5 + 0.5 * np.abs(np.sin(ang * count / 2 + phases[0]))) * depth
    tear += 0.25 * depth * np.sin(ang * (count + 3) + phases[1])
    return P[:, 2] - (z_hem + tear)   # positive above the hem line (kept), negative below (cut)


def _folds(P, t, count: int, depth: float, seed: int):
    """Vertical cloth folds: an outward offset that varies around the body and grows toward the
    hem (t = 0 at the waist, 1 at the hem). Subtract from a skirt's distance."""
    rng = np.random.default_rng(seed)
    ph = rng.uniform(0, 2 * np.pi, 2)
    ang = np.arctan2(P[:, 1], P[:, 0])
    wave = 0.7 * np.sin(ang * count + ph[0]) + 0.3 * np.sin(ang * (count * 2 + 1) + ph[1])
    return depth * (0.25 + 0.75 * t) * wave


def glove(body: sdf.Shape, j: dict, side: str, build: str, material: str, tris: int = 700) -> "Piece":
    """A close-fitting glove over one hand, extracted on a fine grid so the fingers stay
    separate, with a flared cuff that reaches under the sleeve or bracer."""
    handf = hand_field(body, side)
    wr, el = j[f"wrist_{side}"], j[f"elbow_{side}"]
    axis = (wr - el) / np.linalg.norm(wr - el)
    r = 0.057 * body_sdf.BUILD_SCALES[build]["limb"]

    def fn(P):
        cuff = sdf.sd_round_cone(P, wr - axis * 0.07, wr + axis * 0.015, r + 0.008, r + 0.016)
        return np.minimum(sdf.shell(handf, P, -0.004, 0.006), cuff)
    he = j[f"hand_end_{side}"]
    return Piece(f"glove_{side}", f"hand_{side}", material, fn, np.minimum(wr - axis * 0.1, he) - 0.13,
                 np.maximum(wr, he) + 0.13, tris, facet_deg=40, voxel=0.0025)


def _draped_torso(torso, j):
    """The torso as cloth sees it: the chest and back filled out with a broad smooth volume,
    so a robe hangs over the pecs and shoulder blades instead of hugging them."""
    z = lambda name: float(j[name][2])  # noqa: E731
    c = np.array([0.0, 0.01, (z("chest") + z("chest_top")) / 2])

    def fn(P):
        chest = sdf.sd_round_box(P, c, (0.17, 0.125, 0.12), 0.1)
        return sdf.smin(torso(P), chest, 0.08)
    return fn


def arcanist_robe(j: dict, build: str = "lean", hands: tuple[str, str] = ("relaxed", "fist")) -> list[Piece]:
    """Frost mage: long hooded robe with a torn hem, layered collar with ice crystals, wrapped
    sleeves, sash, bracers and soft boots. Cloth pieces take their skin weights from the body."""
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    body = body_sdf.body_shape(j, build, hands)
    ev = lambda names: (lambda P, s=sdf.subset(body, names): sdf.eval_points(s, P))  # noqa: E731
    z = lambda name: float(j[name][2])  # noqa: E731
    torso = ev({"pelvis", "abdomen", "ribcage", "girdle", "pec", "lat", "trap", "glute"})
    draped = _draped_torso(torso, j)
    pieces: list[Piece] = []

    # robe: the torso shell continues into a skirt that flares from the hips to the ankles
    waist = z("spine") - 0.08
    hem = z("ankle_l") + 0.1

    def robe(P):
        upper = sdf.shell(draped, P, 0.008, 0.03)
        # skirt: a tapered cone around both legs, widening towards the hem
        t = np.clip((waist - P[:, 2]) / (waist - hem), 0, 1)
        radius_x = 0.2 + 0.1 * t
        radius_y = 0.15 + 0.1 * t
        rr = np.sqrt((P[:, 0] / radius_x) ** 2 + ((P[:, 1] - 0.01) / radius_y) ** 2)
        cone = (rr - 1.0) * np.minimum(radius_x, radius_y) - _folds(P, t, 7, 0.018, 11)
        skirt = np.maximum(cone, -(cone + 0.022))              # a 2 cm layer of cloth
        skirt = np.maximum(skirt, P[:, 2] - (waist + 0.05))
        d = np.minimum(np.where(P[:, 2] > waist - 0.02, upper, 10.0), skirt)
        d = sdf.smin(d, np.maximum(upper, P[:, 2] - (waist + 0.1)), 0.02)
        d = np.maximum(d, sdf.half_space(P, v(0, 0, z("chest_top") + 0.02), (0, 0, 1)))
        d = np.maximum(d, -_jagged(P, hem, 0.09, 13, 3))        # torn hem
        # a slit up the front so the legs can stride
        slit = np.maximum(np.abs(P[:, 0]) - 0.012, np.maximum(P[:, 1] + 0.05, P[:, 2] - (z("knee_l") + 0.1)))
        d = np.maximum(d, -slit)
        for s in (j["shoulder_l"], j["shoulder_r"]):
            d = np.maximum(d, -(np.linalg.norm(P - s, axis=1) - 0.1))
        return d
    pieces.append(Piece("robe", "spine", "cloth", robe, v(-0.45, -0.4, hem - 0.05), v(0.45, 0.4, z("chest_top") + 0.1),
                        3200, facet_deg=50, skin="transfer", skirt=True))

    # sash: a wide band at the waist with a hanging tail
    def sash(P):
        d = sdf.shell(torso, P, 0.028, 0.05)
        d = np.maximum(d, np.abs(P[:, 2] - waist) - 0.05)
        tail = sdf.sd_round_box(P, v(0.07, -0.19, waist - 0.25), (0.05, 0.012, 0.22), 0.01)
        return np.minimum(d, tail)
    pieces.append(Piece("sash", "pelvis", "trim", sash, v(-0.35, -0.35, waist - 0.55), v(0.35, 0.35, waist + 0.12), 700,
                        facet_deg=50, skin="transfer"))

    # hood: a deep cowl over the head, peaked at the back, open at the face
    hz = z("head")
    hc = v(0, 0.015, hz + 0.12)

    def hood(P):
        # a deep cowl: the rim stands well in front of the face, so the face sits in shadow
        outer = sdf.sd_ellipsoid(P, hc + v(0, -0.03, 0.01), (0.145, 0.2, 0.175))
        peak = sdf.sd_round_cone(P, hc + v(0, 0.05, 0.08), hc + v(0, 0.22, 0.2), 0.08, 0.01)
        outer = sdf.smin(outer, peak, 0.05)
        drape = sdf.sd_round_box(P, hc + v(0, 0.03, -0.12), (0.16, 0.15, 0.08), 0.07)
        outer = sdf.smin(outer, drape, 0.05)
        inner = sdf.sd_ellipsoid(P, hc + v(0, -0.04, -0.01), (0.118, 0.18, 0.148))
        d = np.maximum(outer, -inner)
        face = sdf.sd_ellipsoid(P, hc + v(0, -0.245, -0.04), (0.072, 0.1, 0.092))  # the face opening
        d = np.maximum(d, -face)
        return np.maximum(d, -sdf.half_space(P, v(0, 0, z("chest_top") - 0.02), (0, 0, 1)))
    pieces.append(Piece("hood", "head", "cloth", hood, hc - v(0.3, 0.35, 0.35), hc + v(0.3, 0.45, 0.4), 1600,
                        facet_deg=50, voxel=0.005))

    # eyes: two slanted glints of frost light in the shadow of the hood
    def eyes(P):
        d = np.full(len(P), 10.0)
        for sx in (1, -1):
            c = v(sx * 0.036, -0.124, hz + 0.123)   # just in front of the face (brow front at -0.118)
            d = np.minimum(d, sdf.sd_ellipsoid(P, c, (0.019, 0.009, 0.0075),
                                               rot=sdf.frame((sx * 1.0, 0.25 * sx, -0.3 * sx), up=(0, -1, 0))))
        return d
    pieces.append(Piece("eyes", "head", "eyes", eyes, v(-0.1, -0.17, hz + 0.08), v(0.1, -0.05, hz + 0.17), 200,
                        facet_deg=30, voxel=0.002))

    # collar: layered mantle over the shoulders with ice crystals
    def mantle(P):
        c = v(0, 0.02, z("chest_top") - 0.02)
        dome = sdf.sd_ellipsoid(P, c, (0.33, 0.21, 0.13))
        inner = sdf.sd_ellipsoid(P, c + v(0, 0, -0.02), (0.3, 0.18, 0.12))
        d = np.maximum(dome, -inner)
        d = np.maximum(d, -sdf.half_space(P, c - v(0, 0, 0.05), (0, 0, 1)))
        d = np.maximum(d, -_jagged(P, c[2] - 0.05, 0.05, 11, 7))
        d = np.maximum(d, -(np.linalg.norm(P[:, :2] - c[None, :2], axis=1) - 0.11))  # neck opening
        return d
    pieces.append(Piece("mantle", "chest", "cloth_dark", mantle, v(-0.4, -0.3, z("chest_top") - 0.25),
                        v(0.4, 0.3, z("chest_top") + 0.15), 900, facet_deg=45))

    def crystals(P):
        d = np.full(len(P), 10.0)
        for sx in (1, -1):
            base = j["shoulder_l" if sx > 0 else "shoulder_r"] + v(-sx * 0.05, 0.03, 0.06)
            for k, (dx, dy, dz, L, r) in enumerate(((0.02, 0.0, 1.0, 0.2, 0.035), (0.35, 0.1, 0.9, 0.15, 0.028),
                                                    (-0.2, 0.25, 0.9, 0.13, 0.025))):
                direction = v(sx * dx + sx * 0.25, dy, dz)
                direction = direction / np.linalg.norm(direction)
                d = np.minimum(d, sdf.sd_round_cone(P, base, base + direction * L, r, 0.003))
        return d
    pieces.append(Piece("crystals", "chest", "frost", crystals, v(-0.6, -0.3, z("chest_top") - 0.1),
                        v(0.6, 0.4, z("chest_top") + 0.35), 500, facet_deg=20, voxel=0.004))

    def one_side(side: str, sx: float) -> None:
        M = np.array([sx, 1.0, 1.0])

        def mirror(names):
            left = sdf.Shape([p for p in body.prims if p.name in names])
            f = lambda P, s=left: sdf.eval_points(s, P)  # noqa: E731
            return (lambda P, f=f: f(P * M)) if sx < 0 else f
        armf = mirror({"upperarm", "bicep", "tricep", "deltoid"})
        foref = mirror({"forearm", "forearm_mass"})
        footf = mirror({"foot", "instep"})
        sh, el, wr = j[f"shoulder_{side}"], j[f"elbow_{side}"], j[f"wrist_{side}"]
        ankle = j[f"ankle_{side}"]

        # sleeve: loose cloth from shoulder to elbow, flaring into a wide bell over the forearm
        def sleeve(P):
            upper = sdf.shell(armf, P, 0.006, 0.026)
            axis = (wr - el) / np.linalg.norm(wr - el)
            t = (P - el) @ axis
            L = np.linalg.norm(wr - el)
            flare = np.clip(t / L, 0, 1) * 0.05
            lower = sdf.shell(foref, P, 0.006 + flare * 0.3, 0.03 + flare)
            lower = np.maximum(lower, np.maximum(-t - 0.03, t - L * 0.75))
            d = np.minimum(upper, lower)
            return np.maximum(d, -(np.linalg.norm(P - sh, axis=1) - 0.06))
        pieces.append(Piece(f"sleeve_{side}", f"upperarm_{side}", "cloth", sleeve, np.minimum(sh, wr) - 0.18,
                            np.maximum(sh, wr) + 0.18, 900, facet_deg=50, skin="transfer"))

        # bracer: a leather wrap at the wrist
        def bracer(P):
            axis = (wr - el) / np.linalg.norm(wr - el)
            t = (P - el) @ axis
            L = np.linalg.norm(wr - el)
            d = sdf.shell(foref, P, 0.004, 0.022)
            return np.maximum(d, np.maximum(L * 0.72 - t, t - (L + 0.01)))
        pieces.append(Piece(f"bracer_{side}", f"forearm_{side}", "leather", bracer, np.minimum(el, wr) - 0.15,
                            np.maximum(el, wr) + 0.15, 300, facet_deg=45))

        # boot: soft leather boot to mid-shin (under the robe)
        def boot(P):
            d = sdf.shell(lambda Q: np.minimum(footf(Q), mirror({"shin", "calf"})(Q)), P, -0.02, 0.016)
            return np.maximum(d, sdf.half_space(P, ankle + v(0, 0, 0.18), (0, 0, 1)))
        pieces.append(Piece(f"boot_{side}", f"foot_{side}", "leather", boot, ankle - v(0.2, 0.3, 0.2), ankle + v(0.2, 0.2, 0.25),
                            500, facet_deg=45, skin="transfer"))
        pieces.append(glove(body, j, side, build, "leather", tris=700))

    one_side("l", 1.0)
    one_side("r", -1.0)
    return pieces


def oracle_vestments(j: dict, build: str = "lean", hands: tuple[str, str] = ("relaxed", "fist")) -> list[Piece]:
    """Blind seer healer: long cream robe with a neat hem and a front tabard, high collar,
    smooth shoulder caps, a cloth blindfold, a gold circlet of rays and a large halo ring
    behind the shoulders. Distinct from the hooded, spiky Arcanist at a glance."""
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    body = body_sdf.body_shape(j, build, hands)
    ev = lambda names: (lambda P, s=sdf.subset(body, names): sdf.eval_points(s, P))  # noqa: E731
    z = lambda name: float(j[name][2])  # noqa: E731
    torso = ev({"pelvis", "abdomen", "ribcage", "girdle", "pec", "lat", "trap", "glute"})
    draped = _draped_torso(torso, j)
    pieces: list[Piece] = []
    waist = z("spine") - 0.08
    hem = z("ankle_l") + 0.07

    def robe(P):
        upper = sdf.shell(draped, P, 0.008, 0.03)
        t = np.clip((waist - P[:, 2]) / (waist - hem), 0, 1)
        radius_x = 0.2 + 0.07 * t
        radius_y = 0.15 + 0.07 * t
        rr = np.sqrt((P[:, 0] / radius_x) ** 2 + ((P[:, 1] - 0.01) / radius_y) ** 2)
        cone = (rr - 1.0) * np.minimum(radius_x, radius_y) - _folds(P, t, 9, 0.013, 5)
        skirt = np.maximum(np.maximum(cone, -(cone + 0.022)), P[:, 2] - (waist + 0.05))
        d = np.minimum(np.where(P[:, 2] > waist - 0.02, upper, 10.0), skirt)
        d = sdf.smin(d, np.maximum(upper, P[:, 2] - (waist + 0.1)), 0.02)
        d = np.maximum(d, sdf.half_space(P, v(0, 0, z("chest_top") + 0.02), (0, 0, 1)))
        d = np.maximum(d, hem - P[:, 2])  # a neat, straight hem
        slit = np.maximum(np.abs(P[:, 0]) - 0.012, np.maximum(P[:, 1] + 0.05, P[:, 2] - (z("knee_l") + 0.05)))
        d = np.maximum(d, -slit)
        for s in (j["shoulder_l"], j["shoulder_r"]):
            d = np.maximum(d, -(np.linalg.norm(P - s, axis=1) - 0.1))
        return d
    pieces.append(Piece("robe", "spine", "cloth", robe, v(-0.45, -0.4, hem - 0.05), v(0.45, 0.4, z("chest_top") + 0.1),
                        3000, facet_deg=50, skin="transfer", skirt=True))

    # tabard: a long front panel with a gold border, from the belt to the shins
    def tabard(P):
        top, bottom = waist + 0.02, z("knee_l") + 0.08  # ends above the knee, so the legs swing behind it
        mid_z = (top + bottom) / 2
        t = np.clip((waist - P[:, 2]) / (waist - hem), 0, 1)
        front_y = -(0.15 + 0.07 * t) - 0.03            # just in front of the skirt
        panel = np.maximum(np.abs(P[:, 0]) - 0.11, np.abs(P[:, 1] - front_y) - 0.01)
        panel = np.maximum(panel, np.abs(P[:, 2] - mid_z) - (top - bottom) / 2)
        point = sdf.half_space(P, v(0, 0, bottom), (0.6, 0, 1)) * 0.0  # square hem
        return np.maximum(panel, point - 1.0)
    pieces.append(Piece("tabard", "pelvis", "trim_cloth", tabard, v(-0.2, -0.35, hem), v(0.2, -0.1, waist + 0.1), 400,
                        facet_deg=40))  # rigid on the pelvis: weights from both thighs tore it apart

    # sigil on the tabard: a sun disc weeping three rays of light (original emblem)
    tab_top, tab_bottom = waist + 0.02, z("knee_l") + 0.08
    sig_t = (waist - (tab_top - 0.12)) / (waist - hem)               # skirt position of the sigil
    sig_c = v(0, -(0.15 + 0.07 * sig_t) - 0.03 - 0.01 - 0.004, tab_top - 0.12)  # on the tabard's face

    def sigil(P):
        q = P - sig_c
        r = np.sqrt(q[:, 0] ** 2 + q[:, 2] ** 2)
        flat = np.abs(q[:, 1]) - 0.006
        ring = np.maximum(np.abs(r - 0.045) - 0.008, flat)
        dot = np.maximum(r - 0.018, flat)
        d = np.minimum(ring, dot)
        for dx, L in ((-0.028, 0.09), (0.0, 0.14), (0.028, 0.09)):   # the three falling rays
            ray = sdf.sd_round_cone(P, sig_c + v(dx, 0, -0.055), sig_c + v(dx * 1.3, 0, -0.055 - L), 0.009, 0.003)
            d = np.minimum(d, np.maximum(ray, flat))
        return d
    pieces.append(Piece("sigil", "pelvis", "gold", sigil, sig_c - v(0.08, 0.03, 0.25), sig_c + v(0.08, 0.03, 0.08), 500,
                        facet_deg=35, voxel=0.003))

    # gold border down both edges and along the bottom of the tabard
    def tabard_trim(P):
        t = np.clip((waist - P[:, 2]) / (waist - hem), 0, 1)
        front_y = -(0.15 + 0.07 * t) - 0.03
        yslab = np.abs(P[:, 1] - (front_y - 0.013)) - 0.006          # stands 8 mm proud of the panel
        sides = np.maximum(np.abs(np.abs(P[:, 0]) - 0.104) - 0.009, np.maximum(P[:, 2] - tab_top, tab_bottom - P[:, 2]))
        bottom = np.maximum(np.abs(P[:, 0]) - 0.113, np.abs(P[:, 2] - (tab_bottom + 0.009)) - 0.009)
        return np.maximum(np.minimum(sides, bottom), yslab)
    pieces.append(Piece("tabard_trim", "pelvis", "gold", tabard_trim, v(-0.2, -0.35, tab_bottom - 0.05),
                        v(0.2, -0.1, tab_top + 0.05), 300, facet_deg=40, voxel=0.004))

    # stole: a wine-dark band over the shoulders, lying on the robe down the chest and hanging
    # over the skirt to mid-thigh
    def stole(P):
        top, bottom = z("chest_top") + 0.03, waist - 0.34
        strip = np.abs(np.abs(P[:, 0]) - (0.1 + 0.03 * np.clip((top - P[:, 2]) / (top - bottom), 0, 1))) - 0.042
        upper = np.maximum(sdf.shell(draped, P, 0.031, 0.042), P[:, 1] + 0.02)     # on the chest, front only
        upper = np.maximum(upper, np.maximum(P[:, 2] - top, (waist - 0.01) - P[:, 2]))
        t = np.clip((waist - P[:, 2]) / (waist - hem), 0, 1)
        radius_x, radius_y = 0.2 + 0.07 * t, 0.15 + 0.07 * t
        rr = np.sqrt((P[:, 0] / radius_x) ** 2 + ((P[:, 1] - 0.01) / radius_y) ** 2)
        cone = (rr - 1.0) * np.minimum(radius_x, radius_y)
        lower = np.maximum(np.maximum(cone - 0.03, 0.02 - cone), P[:, 1] + 0.05)   # hangs just off the skirt
        lower = np.maximum(lower, np.maximum(P[:, 2] - waist, bottom - P[:, 2]))
        return np.maximum(np.minimum(upper, lower), strip)
    pieces.append(Piece("stole", "chest", "cloth_dark", stole, v(-0.3, -0.35, waist - 0.4),
                        v(0.3, 0.1, z("chest_top") + 0.1), 700, facet_deg=45, skin="transfer", skirt=True))

    # gold band at the hem
    def hem_band(P):
        t = np.clip((waist - P[:, 2]) / (waist - hem), 0, 1)
        radius_x = 0.2 + 0.07 * t
        radius_y = 0.15 + 0.07 * t
        rr = np.sqrt((P[:, 0] / radius_x) ** 2 + ((P[:, 1] - 0.01) / radius_y) ** 2)
        cone = (rr - 1.0) * np.minimum(radius_x, radius_y) - _folds(P, t, 9, 0.013, 5)
        d = np.maximum(cone - 0.004, -(cone + 0.004))
        d = np.maximum(d, np.maximum(hem - P[:, 2], P[:, 2] - (hem + 0.045)))
        slit = np.maximum(np.abs(P[:, 0]) - 0.016, P[:, 1] + 0.05)
        return np.maximum(d, -slit)
    pieces.append(Piece("hem_band", "spine", "gold", hem_band, v(-0.45, -0.4, hem - 0.03), v(0.45, 0.4, hem + 0.08), 900,
                        facet_deg=45, voxel=0.004, skin="transfer", skirt=True))

    # belt with a gold clasp
    def belt(P):
        d = sdf.shell(torso, P, 0.026, 0.05)
        d = np.maximum(d, np.abs(P[:, 2] - waist) - 0.035)
        clasp = sdf.sd_ellipsoid(P, v(0, -0.17, waist), (0.05, 0.02, 0.05))
        return sdf.smin(d, clasp, 0.01)
    pieces.append(Piece("belt", "pelvis", "gold", belt, v(-0.32, -0.3, waist - 0.1), v(0.32, 0.3, waist + 0.1), 500,
                        facet_deg=45))

    # high collar
    def collar(P):
        c = v(0, 0.01, z("chest_top"))
        r = np.linalg.norm((P[:, :2] - c[None, :2]) / np.array([1.0, 0.9]), axis=1)
        flare = np.clip((P[:, 2] - c[2]) / 0.16, 0, 1) * 0.04
        ring = np.abs(r - (0.105 + flare)) - 0.012
        ring = np.maximum(ring, np.abs(P[:, 2] - (c[2] + 0.07)) - 0.09)
        return np.maximum(ring, sdf.half_space(P, c + v(0, -0.09, 0.02), (0, -0.4, 1)))  # lower at the front
    pieces.append(Piece("collar", "chest", "cloth", collar, v(-0.25, -0.25, z("chest_top") - 0.05),
                        v(0.25, 0.25, z("chest_top") + 0.2), 500, facet_deg=45, voxel=0.005))

    # halo: a large ring behind the shoulders with short rays
    hz = z("head")
    halo_c = v(0, 0.2, hz + 0.08)

    def halo(P):
        q = P - halo_c
        r = np.sqrt(q[:, 0] ** 2 + q[:, 2] ** 2)
        ring = np.sqrt((r - 0.25) ** 2 + q[:, 1] ** 2) - 0.016
        ang = np.arctan2(q[:, 2], q[:, 0])
        rays = np.maximum(np.abs(q[:, 1]) - 0.008, np.abs(r - 0.305) - 0.042 * (0.5 + 0.5 * np.cos(ang * 12)) ** 8)
        rays = np.maximum(rays, 0.27 - r)
        return np.minimum(ring, rays)
    pieces.append(Piece("halo", "chest", "holy", halo, halo_c - v(0.5, 0.1, 0.5), halo_c + v(0.5, 0.1, 0.5), 1200,
                        facet_deg=30, voxel=0.005))

    # circlet of rays around the head, and a cloth blindfold over the eyes
    hc = v(0, 0.015, hz + 0.12)

    def circlet(P):
        q = P - (hc + v(0, 0, 0.035))
        r = np.sqrt((q[:, 0] / 1.0) ** 2 + (q[:, 1] / 1.14) ** 2)
        band = np.maximum(np.abs(r - 0.123) - 0.008, np.abs(q[:, 2]) - 0.014)   # sits on the coif
        ang = np.arctan2(q[:, 1], q[:, 0])
        ray_mask = (0.5 + 0.5 * np.cos(ang * 9 + np.pi)) ** 6          # nine rays
        front = np.clip(-q[:, 1] / 0.12, 0, 1)                           # taller over the brow
        rays = np.maximum(np.abs(r - 0.125) - 0.01, np.maximum(-q[:, 2], q[:, 2] - (0.03 + 0.09 * ray_mask * (0.4 + 0.6 * front))))
        rays = np.maximum(rays, 0.02 - ray_mask * 0.2)
        return np.minimum(band, rays)
    pieces.append(Piece("circlet", "head", "gold", circlet, hc - v(0.2, 0.2, 0.1), hc + v(0.2, 0.2, 0.25), 700,
                        facet_deg=30, voxel=0.004))

    # mask: a serene oval gold face with closed eyes (the seer is blind), standing just in front of
    # the face (its front at y = -0.13; the nose tip is at -0.121)
    mc = hc + v(0, -0.02, -0.035)
    ry = 0.125
    front = mc[1] - ry

    def mask(P):
        outer = sdf.sd_ellipsoid(P, mc, (0.093, ry, 0.12))
        nose = sdf.sd_round_cone(P, v(0, front - 0.002, mc[2] + 0.03), v(0, front - 0.014, mc[2] - 0.015), 0.008, 0.013)
        brow = sdf.sd_ellipsoid(P, v(0, front + 0.012, mc[2] + 0.045), (0.07, 0.02, 0.013))
        outer = sdf.smin(sdf.smin(outer, nose, 0.012), brow, 0.015)
        d = np.maximum(outer, -sdf.sd_ellipsoid(P, mc, (0.085, ry - 0.008, 0.112)))
        d = np.maximum(d, P[:, 1] - (mc[1] - 0.045))                  # the front of the face only
        for sx in (1, -1):                                              # closed eyes: curved grooves
            lid = sdf.sd_round_cone(P, v(sx * 0.016, front + 0.004, mc[2] + 0.02), v(sx * 0.048, front + 0.016, mc[2] + 0.014),
                                    0.0035, 0.0025)
            d = np.maximum(d, -lid)
        mouth = sdf.sd_round_cone(P, v(-0.015, front + 0.006, mc[2] - 0.05), v(0.015, front + 0.006, mc[2] - 0.05), 0.0025, 0.0025)
        return np.maximum(d, -mouth)
    pieces.append(Piece("mask", "head", "gold", mask, mc - v(0.12, 0.17, 0.15), mc + v(0.12, 0.05, 0.15), 1000,
                        facet_deg=35, voxel=0.0025))

    # coif: close cloth over the skull, ears and neck, open for the mask; the circlet sits on it
    skull = ev({"cranium", "jaw", "ear", "neck", "trap", "girdle"})

    def coif(P):
        d = sdf.shell(skull, P, 0.004, 0.016)
        d = np.maximum(d, -sdf.sd_ellipsoid(P, mc + v(0, -0.03, 0), (0.078, 0.11, 0.108)))   # face opening
        d = np.maximum(d, sdf.half_space(P, v(0, 0, z("chest_top") - 0.07), (0, 0, -1)))   # a wimple under the robe
        return d
    pieces.append(Piece("coif", "head", "trim_cloth", coif, hc - v(0.2, 0.2, 0.35), hc + v(0.2, 0.2, 0.2), 1200,
                        facet_deg=50, voxel=0.004, skin="transfer"))

    def one_side(side: str, sx: float) -> None:
        M = np.array([sx, 1.0, 1.0])

        def mirror(names):
            left = sdf.Shape([p for p in body.prims if p.name in names])
            f = lambda P, s=left: sdf.eval_points(s, P)  # noqa: E731
            return (lambda P, f=f: f(P * M)) if sx < 0 else f
        armf = mirror({"upperarm", "bicep", "tricep"})
        foref = mirror({"forearm", "forearm_mass"})
        footf = mirror({"foot", "instep"})
        sh, el, wr, ankle = j[f"shoulder_{side}"], j[f"elbow_{side}"], j[f"wrist_{side}"], j[f"ankle_{side}"]

        def cap(P):  # smooth shoulder cap with a gold rim
            c = sh + v(sx * 0.02, 0, 0.04)
            dome = np.maximum(sdf.sd_ellipsoid(P, c, (0.14, 0.15, 0.1)), -sdf.sd_ellipsoid(P, c + v(0, 0, -0.02), (0.12, 0.13, 0.09)))
            return np.maximum(dome, -sdf.half_space(P, c - v(0, 0, 0.04), (0, 0, 1)))
        pieces.append(Piece(f"shoulder_{side}", f"upperarm_{side}", "cloth", cap, sh - 0.25, sh + 0.25, 500, facet_deg=45))

        def sleeve(P):
            d = np.minimum(sdf.shell(armf, P, 0.006, 0.022), sdf.shell(foref, P, 0.006, 0.022))
            axis = (wr - el) / np.linalg.norm(wr - el)
            t = (P - el) @ axis
            return np.maximum(d, t - np.linalg.norm(wr - el) * 0.7)
        pieces.append(Piece(f"sleeve_{side}", f"upperarm_{side}", "cloth", sleeve, np.minimum(sh, wr) - 0.16,
                            np.maximum(sh, wr) + 0.16, 700, facet_deg=50, skin="transfer"))

        def bracer(P):
            axis = (wr - el) / np.linalg.norm(wr - el)
            t = (P - el) @ axis
            L = np.linalg.norm(wr - el)
            d = sdf.shell(foref, P, 0.008, 0.026)
            return np.maximum(d, np.maximum(L * 0.6 - t, t - (L + 0.01)))
        pieces.append(Piece(f"bracer_{side}", f"forearm_{side}", "gold", bracer, np.minimum(el, wr) - 0.15,
                            np.maximum(el, wr) + 0.15, 350, facet_deg=40))

        def boot(P):
            d = sdf.shell(footf, P, -0.02, 0.016)
            return np.maximum(d, sdf.half_space(P, ankle + v(0, 0, 0.08), (0, 0, 1)))
        pieces.append(Piece(f"shoe_{side}", f"foot_{side}", "leather", boot, ankle - v(0.2, 0.3, 0.2),
                            ankle + v(0.2, 0.2, 0.2), 350, facet_deg=45))
        pieces.append(glove(body, j, side, build, "leather", tris=700))

    one_side("l", 1.0)
    one_side("r", -1.0)
    return pieces


def _front_y(fn, z: float, back: bool = False) -> float:
    """Where a field's surface crosses the centre line at height z, in front (most negative y)
    or behind (most positive y)."""
    ys = np.linspace(0.45 if back else -0.45, 0.0, 451)
    P = np.stack([np.zeros_like(ys), ys, np.full_like(ys, z)], axis=1)
    inside = np.nonzero(fn(P) <= 0.0)[0]
    return float(ys[inside[0]]) if len(inside) else 0.0


def _sun(P, c, normal_axis: int, r: float, rays: int, flat: float):
    """A sun emblem lying in the plane through c across `normal_axis` (0 = x, 1 = y): a disc,
    a ring and pointed rays, `flat` thick."""
    q = P - c
    a, b = [i for i in range(3) if i != normal_axis]
    rr = np.sqrt(q[:, a] ** 2 + q[:, b] ** 2)
    slab = np.abs(q[:, normal_axis]) - flat
    disc = np.maximum(rr - r * 0.45, slab)
    ring = np.maximum(np.abs(rr - r * 0.7) - r * 0.08, slab)
    ang = np.arctan2(q[:, b], q[:, a])
    ray_w = (0.5 + 0.5 * np.cos(ang * rays)) ** 10
    ray = np.maximum(np.maximum(rr - r * (0.8 + 0.45 * ray_w), r * 0.8 - rr), slab)
    ray = np.maximum(ray, 0.25 - ray_w)
    return np.minimum(np.minimum(disc, ring), ray)


def templar_plate(j: dict, build: str = "heavy", hands: tuple[str, str] = ("relaxed", "fist")) -> list[Piece]:
    """Templar (M3-02): bright polished plate with gold trim, the opposite of the Warblade's
    blackened spikes at a glance. A smooth breastplate with a raised gold sun, a cream tabard
    hanging front and back below the belt (gold border, sun sigil), rounded pauldrons with gold
    rims and lames, plate limbs without spikes, a domed great helm with a cross visor, gold wings
    swept back and a sun-disc crest, and a heater shield strapped to the left forearm."""
    v = lambda *a: np.array(a, dtype=float)  # noqa: E731
    body = body_sdf.body_shape(j, build, hands)
    ev = lambda names: (lambda P, s=sdf.subset(body, names): sdf.eval_points(s, P))  # noqa: E731
    torso = ev({"pelvis", "abdomen", "ribcage", "girdle", "pec", "lat", "trap", "glute"})
    z = lambda name: float(j[name][2])  # noqa: E731
    pieces: list[Piece] = []

    # ---- breastplate: smooth and rounded, a raised gold sun on the chest -------------------------
    top = z("chest_top") + 0.035
    breast_bottom = z("chest") - 0.12
    sh_l, sh_r = j["shoulder_l"], j["shoulder_r"]
    chest_round = lambda P: sdf.smin(torso(P), sdf.sd_ellipsoid(P, v(0, -0.02, z("chest") + 0.02), (0.19, 0.15, 0.16)), 0.08)  # noqa: E731

    def breastplate(P):
        d = sdf.shell(chest_round, P, 0.012, 0.048)
        d = np.maximum(d, sdf.half_space(P, v(0, 0, top), (0, 0, 1)))
        d = np.maximum(d, -sdf.half_space(P, v(0, 0, breast_bottom), (0, 0, 1)))
        for s, sxa in ((sh_l, 1.0), (sh_r, -1.0)):
            d = np.maximum(d, -(np.linalg.norm(P - (s + v(sxa * 0.05, 0, -0.03)), axis=1) - 0.11))
        neck = np.linalg.norm(P[:, :2] - v(0, 0.01)[None, :2], axis=1) - 0.12
        return np.maximum(d, -np.where(P[:, 2] > top - 0.08, neck, 1.0))
    pieces.append(Piece("breastplate", "chest", "plate", breastplate, v(-0.4, -0.32, breast_bottom - 0.05),
                        v(0.4, 0.3, top + 0.05), 2000, facet_deg=30))

    sun_z = z("chest") + 0.03
    sun_y = _front_y(lambda P: chest_round(P) - 0.048, sun_z)
    sun_c = v(0, sun_y - 0.004, sun_z)

    def chest_sun(P):
        return _sun(P, sun_c, 1, 0.075, 8, 0.008)
    pieces.append(Piece("chest_sun", "chest", "gold", chest_sun, sun_c - v(0.12, 0.04, 0.12), sun_c + v(0.12, 0.04, 0.12),
                        400, facet_deg=35, voxel=0.003))

    plack_top, plack_bottom = z("chest") - 0.1, z("spine") - 0.09

    def plackart(P):
        d = sdf.shell(torso, P, 0.02, 0.06)
        d = np.maximum(d, sdf.half_space(P, v(0, 0, plack_top), (0, 0, 1)))
        return np.maximum(d, -sdf.half_space(P, v(0, 0, plack_bottom), (0, 0, 1)))
    pieces.append(Piece("plackart", "spine", "plate", plackart, v(-0.35, -0.3, plack_bottom - 0.05),
                        v(0.35, 0.3, plack_top + 0.05), 900, facet_deg=30))

    belt_z = z("spine") - 0.13

    def belt(P):
        d = sdf.shell(torso, P, 0.03, 0.075)
        d = np.maximum(d, np.abs(P[:, 2] - belt_z) - 0.045)
        buckle = sdf.sd_round_box(P, v(0, -0.18, belt_z), (0.06, 0.03, 0.055), 0.012)
        return sdf.smin(d, buckle, 0.01)
    pieces.append(Piece("belt", "pelvis", "leather", belt, v(-0.32, -0.28, belt_z - 0.1), v(0.32, 0.28, belt_z + 0.1),
                        700, facet_deg=40, rivets=_rivet_ring(belt, v(0, 0, belt_z), 0.25, v(1, 0, 0), v(0, 1, 0), 10,
                                                              arc=(0.3, np.pi * 2 - 0.3))))

    # ---- tabard: front and back panels below the belt, flaring out so the legs swing behind them
    tab_top, tab_bottom = belt_z + 0.02, z("knee_l") + 0.06
    fy = _front_y(torso, belt_z) - 0.09
    by = _front_y(torso, belt_z, back=True) + 0.09

    def panel_y(Pz, base, sign):
        t = np.clip((tab_top - Pz) / (tab_top - tab_bottom), 0, 1)
        return base + sign * 0.13 * t

    def tabard(P):
        d = 10.0
        for base, sign, half_w in ((fy, -1.0, 0.17), (by, 1.0, 0.17)):
            y = panel_y(P[:, 2], base, sign)
            panel = np.maximum(np.abs(P[:, 0]) - half_w, np.abs(P[:, 1] - y) - 0.01)
            panel = np.maximum(panel, np.maximum(P[:, 2] - tab_top, tab_bottom - P[:, 2]))
            point = (tab_bottom + 0.06 - P[:, 2]) - 0.4 * np.abs(P[:, 0])   # a shallow point at the hem
            d = np.minimum(d, np.maximum(panel, point))
        return d
    pieces.append(Piece("tabard", "pelvis", "trim_cloth", tabard, v(-0.25, -0.5, tab_bottom - 0.05),
                        v(0.25, 0.5, tab_top + 0.05), 600, facet_deg=40))

    def tabard_trim(P):
        d = 10.0
        for base, sign, half_w in ((fy, -1.0, 0.17), (by, 1.0, 0.17)):
            y = panel_y(P[:, 2], base, sign) + sign * 0.012
            slab = np.abs(P[:, 1] - y) - 0.005
            sides = np.maximum(np.abs(np.abs(P[:, 0]) - (half_w - 0.008)) - 0.009,
                               np.maximum(P[:, 2] - tab_top, tab_bottom - 0.02 - P[:, 2]))
            hem_line = (tab_bottom + 0.06 - P[:, 2]) - 0.4 * np.abs(P[:, 0])
            hem = np.maximum(np.abs(hem_line + 0.009) - 0.009, np.abs(P[:, 0]) - half_w)
            d = np.minimum(d, np.maximum(np.minimum(sides, hem), slab))
        return d
    pieces.append(Piece("tabard_trim", "pelvis", "gold", tabard_trim, v(-0.25, -0.55, tab_bottom - 0.05),
                        v(0.25, 0.55, tab_top + 0.05), 350, facet_deg=40, voxel=0.004))

    sig_z = tab_top - 0.16
    sig_c = v(0, float(panel_y(np.array([sig_z]), fy, -1.0)[0]) - 0.014, sig_z)

    def sigil(P):
        return _sun(P, sig_c, 1, 0.08, 12, 0.005)
    pieces.append(Piece("sigil", "pelvis", "gold", sigil, sig_c - v(0.13, 0.03, 0.13), sig_c + v(0.13, 0.03, 0.13), 400,
                        facet_deg=35, voxel=0.003))

    # ---- per side -----------------------------------------------------------------------------
    def one_side(side: str, sx: float) -> None:
        M = np.array([sx, 1.0, 1.0])
        hip, knee, ankle, toe = j[f"hip_{side}"], j[f"knee_{side}"], j[f"ankle_{side}"], j[f"toe_{side}"]
        sh, el, wr, he = j[f"shoulder_{side}"], j[f"elbow_{side}"], j[f"wrist_{side}"], j[f"hand_end_{side}"]

        def mirror(names):
            left = sdf.Shape([p for p in body.prims if p.name in names])
            f = lambda P, s=left: sdf.eval_points(s, P)  # noqa: E731
            return (lambda P, f=f: f(P * M)) if sx < 0 else f
        legf = mirror({"thigh", "quad", "adductor", "knee"})
        shinf = mirror({"shin", "calf", "knee"})
        footf = mirror({"foot", "instep"})
        armf = mirror({"upperarm", "bicep", "tricep", "deltoid"})
        foref = mirror({"forearm", "forearm_mass"})
        handf = hand_field(body, side)

        def cuisse(P):
            d = sdf.shell(legf, P, 0.016, 0.042)
            d = np.maximum(d, sdf.half_space(P, v(0, 0, belt_z - 0.12), (0, 0, 1)))
            d = np.maximum(d, -sdf.half_space(P, knee + v(0, 0, 0.09), (0, 0, 1)))
            return np.maximum(d, sdf.half_space(P, v(0, 0.04, 0), (0, 1, 0)))
        pieces.append(Piece(f"cuisse_{side}", f"thigh_{side}", "plate", cuisse, np.minimum(hip, knee) - 0.2,
                            np.maximum(hip, knee) + 0.2, 400, facet_deg=30))

        def poleyn(P):  # a rounded knee cop with a gold fan
            c = knee + v(0, -0.06, 0.0)
            d = np.maximum(sdf.sd_ellipsoid(P, c, (0.085, 0.06, 0.085)), -sdf.sd_ellipsoid(P, c + v(0, 0.02, 0), (0.07, 0.05, 0.07)))
            wing = sdf.sd_ellipsoid(P, c + v(sx * 0.07, 0.02, 0), (0.02, 0.05, 0.065))
            return sdf.smin(d, wing, 0.015)
        pieces.append(Piece(f"poleyn_{side}", f"calf_{side}", "trim", poleyn, knee - 0.18, knee + 0.18, 250, voxel=0.004))

        def greave(P):
            d = sdf.shell(shinf, P, 0.014, 0.04)
            d = np.maximum(d, sdf.half_space(P, knee - v(0, 0, 0.07), (0, 0, 1)))
            return np.maximum(d, -sdf.half_space(P, ankle + v(0, 0, 0.05), (0, 0, 1)))
        pieces.append(Piece(f"greave_{side}", f"calf_{side}", "plate", greave, np.minimum(knee, ankle) - 0.18,
                            np.maximum(knee, ankle) + 0.18, 500, facet_deg=30))

        def sabaton(P):  # a rounded plated boot
            d = sdf.shell(footf, P, -0.02, 0.024)
            return np.maximum(d, sdf.half_space(P, ankle + v(0, 0, 0.07), (0, 0, 1)))
        pieces.append(Piece(f"sabaton_{side}", f"foot_{side}", "plate", sabaton,
                            np.minimum(ankle, toe) - v(0.15, 0.15, 0.1), np.maximum(ankle, toe) + v(0.15, 0.15, 0.15), 500,
                            facet_deg=30))

        out = v(sx, 0, 0.35)
        out = out / np.linalg.norm(out)
        pc = sh + v(sx * 0.02, 0.0, 0.05)

        def pauldron(P, pc=pc, out=out):  # a big smooth dome over the shoulder, three lames below
            d = np.maximum(sdf.sd_ellipsoid(P, pc, (0.19, 0.2, 0.16)), -sdf.sd_ellipsoid(P, pc, (0.16, 0.17, 0.13)))
            d = np.maximum(d, -sdf.half_space(P, pc - out * 0.07, out))
            for i in range(3):
                c = pc - v(0, 0, 0.09 + 0.06 * i) + v(sx * 0.025 * (i + 1), 0, 0)
                ring = np.maximum(sdf.sd_ellipsoid(P, c, (0.18 - 0.015 * i, 0.185 - 0.015 * i, 0.11)),
                                  -sdf.sd_ellipsoid(P, c, (0.152 - 0.015 * i, 0.157 - 0.015 * i, 0.1)))
                ring = np.maximum(ring, -sdf.half_space(P, c - out * 0.02, out))
                ring = np.maximum(ring, np.abs(P[:, 2] - c[2]) - 0.026)
                d = np.minimum(d, ring)
            return d
        pieces.append(Piece(f"pauldron_{side}", f"upperarm_{side}", "plate", pauldron, pc - 0.4, pc + 0.4, 900,
                            voxel=0.005, facet_deg=30))

        def pauldron_rim(P, pc=pc, out=out):
            rim = np.maximum(sdf.sd_ellipsoid(P, pc, (0.205, 0.215, 0.175)), -sdf.sd_ellipsoid(P, pc, (0.18, 0.19, 0.15)))
            return np.maximum(rim, np.abs(sdf.half_space(P, pc - out * 0.055, out)) - 0.022)
        pieces.append(Piece(f"pauldron_rim_{side}", f"upperarm_{side}", "gold", pauldron_rim, pc - 0.3, pc + 0.3, 450,
                            voxel=0.005, facet_deg=40))

        def rerebrace(P):
            d = sdf.shell(armf, P, 0.012, 0.036)
            axis = (el - sh) / np.linalg.norm(el - sh)
            t = (P - sh) @ axis
            return np.maximum(d, np.maximum(0.13 - t, t - (np.linalg.norm(el - sh) - 0.06)))
        pieces.append(Piece(f"rerebrace_{side}", f"upperarm_{side}", "plate", rerebrace, np.minimum(sh, el) - 0.15,
                            np.maximum(sh, el) + 0.15, 450, facet_deg=30))

        def couter(P):
            c = el + v(0, 0.05, 0)
            return np.maximum(sdf.sd_ellipsoid(P, c, (0.07, 0.055, 0.07)), -sdf.sd_ellipsoid(P, c + v(0, -0.02, 0), (0.058, 0.045, 0.058)))
        pieces.append(Piece(f"couter_{side}", f"forearm_{side}", "trim", couter, el - 0.15, el + 0.15, 250, voxel=0.004))

        def vambrace(P):
            axis = (wr - el) / np.linalg.norm(wr - el)
            t = (P - el) @ axis
            L = np.linalg.norm(wr - el)
            flare = np.clip((t - 0.6 * L) / (0.4 * L), 0, 1) * 0.025
            d = sdf.shell(foref, P, 0.014, 0.04) - flare
            return np.maximum(d, np.maximum(0.07 - t, t - (L + 0.02)))
        pieces.append(Piece(f"vambrace_{side}", f"forearm_{side}", "plate", vambrace, np.minimum(el, wr) - 0.16,
                            np.maximum(el, wr) + 0.16, 500, facet_deg=30))

        cuff_axis = (wr - el) / np.linalg.norm(wr - el)

        def gauntlet(P):
            d = sdf.shell(handf, P, -0.004, 0.0075)
            cuff = sdf.sd_round_cone(P, wr - cuff_axis * 0.075, wr + cuff_axis * 0.012, 0.075, 0.062)
            cuff = np.maximum(cuff, -sdf.sd_round_cone(P, wr - cuff_axis * 0.09, wr + cuff_axis * 0.02, 0.066, 0.052))
            return np.minimum(d, cuff)
        pieces.append(Piece(f"gauntlet_{side}", f"hand_{side}", "plate", gauntlet, np.minimum(wr, he) - 0.14,
                            np.maximum(wr, he) + 0.14, 900, facet_deg=35, voxel=0.003))

        if side == "l":  # the heater shield, strapped to the outside of the left forearm
            up = (el - wr) / np.linalg.norm(el - wr)                 # along the forearm, toward the elbow
            face = v(0.75, -0.66, 0.0)                                 # out from the body and half forward
            nrm = face - up * (face @ up)
            nrm = nrm / np.linalg.norm(nrm)
            across = np.cross(up, nrm)
            sc = (el + wr) / 2 + nrm * 0.11 + up * 0.02
            W, H = 0.28, 0.4                                           # half width and half height

            def shield_coords(P):
                q = P - sc
                return q @ across, q @ up, q @ nrm

            def outline(u, w):
                # a heater: straight sides over the top half, curving in to a point at the bottom
                half = W * (1.0 - np.clip(-w / H, 0, 1) ** 1.7)
                return np.maximum(np.abs(u) - half, np.maximum(w - H * 0.62, -w - H))

            def shield(P):
                u, w, n = shield_coords(P)
                bow = 0.06 * (u / W) ** 2                               # bowed around its long axis
                body2 = np.maximum(outline(u, w), np.abs(n + bow) - 0.016)
                return body2
            box = np.abs(np.stack([across, up, nrm])).T @ v(W + 0.05, H + 0.05, 0.14)
            pieces.append(Piece("shield", "forearm_l", "plate", shield, sc - box, sc + box, 900, facet_deg=30, voxel=0.004))

            def shield_rim(P):
                u, w, n = shield_coords(P)
                bow = 0.06 * (u / W) ** 2
                o = outline(u, w)
                return np.maximum(np.abs(o + 0.013) - 0.013, np.abs(n + bow - 0.006) - 0.02)
            pieces.append(Piece("shield_rim", "forearm_l", "gold", shield_rim, sc - box, sc + box, 450, facet_deg=40, voxel=0.004))

            def shield_face(P):
                u, w, n = shield_coords(P)
                bow = 0.06 * (u / W) ** 2
                q = np.stack([u, n + bow - 0.02, w - 0.04], axis=1)
                return _sun(q, v(0, 0, 0), 1, 0.12, 8, 0.007)
            sun_at = sc + up * 0.04 + nrm * 0.02
            sun_box = v(0.2, 0.2, 0.2)                                  # the emblem only: a small grid
            pieces.append(Piece("shield_sun", "forearm_l", "holy", shield_face, sun_at - sun_box, sun_at + sun_box, 450,
                                facet_deg=35, voxel=0.0035))

    one_side("l", 1.0)
    one_side("r", -1.0)

    # ---- helm: a domed great helm with a cross visor, swept-back gold wings, a sun-disc crest ----
    hz = z("head")
    hc = v(0, 0.0, hz + 0.12)

    def helm_outer(P):
        return sdf.smin(sdf.sd_round_box(P, hc + v(0, -0.01, -0.02), (0.12, 0.135, 0.15), 0.1),
                        sdf.sd_ellipsoid(P, hc + v(0, 0.0, 0.05), (0.13, 0.145, 0.14)), 0.04)

    def helm(P):
        outer = helm_outer(P)
        inner = sdf.sd_round_box(P, hc + v(0, 0.0, -0.01), (0.1, 0.115, 0.15), 0.07)
        d = np.maximum(outer, -inner)
        d = np.maximum(d, -sdf.half_space(P, v(0, 0, hz - 0.075), (0, 0, 1)))
        slit = sdf.sd_round_box(P, hc + v(0, -0.15, 0.02), (0.08, 0.06, 0.01), 0.005)
        down = sdf.sd_round_box(P, hc + v(0, -0.15, -0.04), (0.01, 0.06, 0.06), 0.005)
        d = np.maximum(d, -np.minimum(slit, down))
        return d
    pieces.append(Piece("helm", "head", "plate", helm, hc - v(0.3, 0.3, 0.3), hc + v(0.3, 0.3, 0.35), 1700, voxel=0.005,
                        facet_deg=30))

    def helm_gold(P):
        band = sdf.shell(helm_outer, P, -0.004, 0.009)                  # a gold band on the helm's surface
        band = np.maximum(band, np.abs(P[:, 2] - (hc[2] + 0.075)) - 0.018)
        d = band
        for sxh in (1, -1):  # tall wings rising from the temples in a V: the class's mark at a distance
            for k in range(4):
                a = hc + v(sxh * 0.12, 0.02 + 0.025 * k, 0.04 + 0.035 * k)
                b = a + v(sxh * (0.13 - 0.02 * k), 0.06 + 0.035 * k, 0.3 - 0.045 * k)
                d = np.minimum(d, sdf.sd_round_cone(P, a, b, 0.034 - 0.005 * k, 0.007))
        crest = _sun(P, hc + v(0, -0.02, 0.235), 1, 0.07, 8, 0.01)   # a sun disc standing on the crown
        stem = sdf.sd_round_box(P, hc + v(0, -0.02, 0.185), (0.015, 0.01, 0.03), 0.005)
        return np.minimum(d, np.minimum(crest, stem))
    pieces.append(Piece("helm_gold", "head", "gold", helm_gold, hc - v(0.45, 0.3, 0.3), hc + v(0.45, 0.45, 0.55), 1100,
                        voxel=0.004, facet_deg=35))

    def gorget(P):
        c = v(0, 0.02, z("chest_top") + 0.05)
        ring = np.maximum(sdf.sd_ellipsoid(P, c, (0.17, 0.15, 0.08)), -sdf.sd_ellipsoid(P, c, (0.13, 0.11, 0.1)))
        return np.maximum(ring, -sdf.half_space(P, c - v(0, 0, 0.05), (0, 0, 1)))
    pieces.append(Piece("gorget", "chest", "trim", gorget, v(-0.3, -0.3, z("chest_top") - 0.1),
                        v(0.3, 0.3, z("chest_top") + 0.2), 450, facet_deg=30))
    return pieces


ARMOR_SETS = {"warblade_plate": warblade_plate, "arcanist_robe": arcanist_robe, "oracle_vestments": oracle_vestments,
              "templar_plate": templar_plate}
