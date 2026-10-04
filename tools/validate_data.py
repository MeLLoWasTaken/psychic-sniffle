#!/usr/bin/env python3
"""Validate all game data in /data.

Checks, in order:
  1. Every file parses and matches its JSON Schema (data/schemas).
  2. Ids are unique per type and match their file names.
  3. Every cross-reference resolves (class <-> spec, spec -> abilities and talent trees,
     ability -> aura, talent -> node/ability, asset -> builder script).
  4. Talent trees: valid gates, no unreachable nodes, capstones behind the last gate.
  5. Design rules for content marked "complete": ability kit template from docs/DESIGN.md,
     talent point totals from tuning.json.
  6. Maps have enough spawns for their brackets; keybind profiles have no conflicts.
  7. Spell effects: every ability of a finished kit has an effect entry (or "none" with a
     reason), stages fit the ability (cast glow only with a cast bar, ground only with a radius),
     each applied aura has exactly one visual, crowd control uses a CC style, the palette covers
     every school.

Usage:
  python3 tools/validate_data.py [--data DIR]
Exit code 0 when valid, 1 when any error is found.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

REPO = Path(__file__).resolve().parent.parent

# folder -> (schema file, id field)
FOLDERS = {
    "classes": ("class.schema.json", "id"),
    "specs": ("spec.schema.json", "id"),
    "abilities": ("ability.schema.json", "id"),
    "auras": ("aura.schema.json", "id"),
    "talents": ("talent_tree.schema.json", "tree_id"),
    "maps": ("map.schema.json", "id"),
    "assets": ("asset.schema.json", "id"),
    "keybinds": ("keybind_profile.schema.json", "id"),
    "bots": ("bot_profile.schema.json", "id"),
    "lighting": ("lighting.schema.json", "id"),
    "animations": ("animation_set.schema.json", "id"),
    "anim_states": ("anim_states.schema.json", "id"),
    "settings": ("settings.schema.json", "id"),
    "effects": ("effect.schema.json", "id"),
    "effect_palettes": ("effect_palette.schema.json", "id"),
    "sounds": ("sound.schema.json", "id"),
    "sound_map": ("sound_map.schema.json", "id"),
    "hud_layouts": ("hud_layout.schema.json", "id"),
    "sound_processing": ("sound_processing.schema.json", "id"),
    "acoustics": ("acoustics.schema.json", "id"),
    "capture_sources": ("capture_source.schema.json", "id"),
    "captures": ("capture.schema.json", "id"),
    "menus": ("menu.schema.json", "id"),
    "ambient_effects": ("ambient_effect.schema.json", "id"),
    "appearance": ("appearance_options.schema.json", "id"),
    "armor_sets": ("armor_set.schema.json", "id"),
}

# Ability kit template (docs/DESIGN.md, "Ability kit template"): slot -> (min, max)
KIT_TEMPLATE = {
    "core": (4, 6),
    "burst": (1, 2),
    "cc": (2, 3),
    "interrupt": (1, 1),
    "defensive": (2, 3),
    "mobility": (1, 2),
    "utility": (1, 2),
}
KIT_BAR_RANGE = (14, 18)
BRACKET_SIZE = {"1v1": 1, "2v2": 2, "3v3": 3, "10v10": 10}


def _check_ability_text(report: "Report", data_dir: Path) -> None:
    """Numbers written in an ability's description must be ones the data produces (computed as the
    codex does: base x (1 + power bonus x coefficient), per tick and in total), so the text cannot
    fall behind a balance change (review 3 found six that had)."""
    if data_dir.resolve() != (REPO / "data").resolve():
        return  # the fixtures' copies: the codex reads the real data folder
    sys.path.insert(0, str(REPO / "tools" / "codex"))
    import build_codex

    cx = build_codex.Codex()
    for spec in cx.specs.values():
        cls = cx.classes.get(spec["class"], {})
        for aid in spec["abilities"] + cls.get("shared_abilities", []):
            ab = cx.abilities.get(aid)
            if ab is None or aid in cx.stale:
                continue
            _lines, numbers = cx.effects(ab, cx.unit_stats(spec))
            if not cx.check_text(ab, numbers):
                report.error(f"abilities/{aid}.json", "description numbers differ from what the data computes "
                             f"({', '.join(build_codex.fmt(n) for n in sorted(set(numbers)))}) for {spec['id']}")


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def error(self, where: str, msg: str) -> None:
        self.errors.append(f"{where}: {msg}")


def load_schemas(schema_dir: Path) -> tuple[Registry, dict[str, dict]]:
    schemas = {}
    for path in sorted(schema_dir.glob("*.schema.json")):
        schemas[path.name] = json.loads(path.read_text())
    registry = Registry().with_resources(
        (name, Resource.from_contents(s)) for name, s in schemas.items()
    )
    return registry, schemas


def load_json(path: Path, report: Report, rel: str):
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        report.error(rel, f"invalid JSON: {exc}")
        return None


def _humanoid_bones() -> set[str]:
    """Standard bone names from tools/blender/humanoid.py (read as text: it needs bpy to import)."""
    import ast
    tree = ast.parse((REPO / "tools" / "blender" / "humanoid.py").read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "BONES" for t in node.targets):
            return {row[0] for row in ast.literal_eval(node.value)}
    return set()


def _check_anim_states(report: Report, rel: str, st: dict, db: dict, schemas: dict) -> None:
    """Animation states (backlog M1-24): every clip exists in the animation set of the same id,
    bones are standard, the last ability rule catches everything, overrides name real abilities."""
    aset = db["animations"].get(st["id"])
    if aset is None:
        report.error(rel, f"no animation set '{st['id']}' (data/animations/{st['id']}.json)")
        return
    clips = set(aset["clips"])
    loco, actions = st["locomotion"], st["actions"]
    used = [loco["stand"], loco["combat_stand"], loco["jump"], st["death"], st["victory"], *loco["directions"]]
    used += [actions["cast"]["start"], actions["cast"]["loop"], actions["channel"]["loop"], actions["release"]["clip"],
             actions["ranged"]["clip"], actions["hit"]["clip"], *actions["melee"]["cycle"]]
    used += list(st["crowd_control"].values())
    for clip in used:
        if clip not in clips:
            report.error(rel, f"clip '{clip}' is not in animation set '{st['id']}'")
    for name, looped in (("cast loop", actions["cast"]["loop"]), ("channel", actions["channel"]["loop"])):
        if looped in clips and not aset["clips"][looped].get("loop", False):
            report.error(rel, f"{name} clip '{looped}' must loop")
    bones = _humanoid_bones()
    upper, lower = set(st["body_split"]["upper"]), set(st["body_split"]["lower"])
    for bone in sorted((upper | lower) - bones):
        report.error(rel, f"unknown bone '{bone}' in body_split")
    for bone in sorted(upper & lower):
        report.error(rel, f"bone '{bone}' is in both halves of body_split")
    for bone in sorted(bones - upper - lower):
        report.error(rel, f"bone '{bone}' is in neither half of body_split")
    if st["ability_rules"][-1]["when"]:
        report.error(rel, "the last ability rule must have no conditions, so every ability resolves")
    for aid in st["ability_overrides"]:
        if aid not in db["abilities"]:
            report.error(rel, f"ability override for unknown ability '{aid}'")
    speed = loco["speed_scale"]
    if speed["min"] > 1.0 or speed["max"] < 1.0:
        report.error(rel, "speed_scale must include 1.0 (full speed plays clips as authored)")
    if "rig_modifiers" in st:
        _check_rig_modifiers(report, rel, st["rig_modifiers"], clips)


def _humanoid_parents() -> dict[str, str | None]:
    """Bone -> parent from tools/blender/humanoid.py BONES (read as text, like _humanoid_bones)."""
    import ast
    tree = ast.parse((REPO / "tools" / "blender" / "humanoid.py").read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "BONES" for t in node.targets):
            return {row[0]: row[3] for row in ast.literal_eval(node.value)}
    return {}


def _is_ancestor(parents: dict, ancestor: str, bone: str) -> bool:
    node = parents.get(bone)
    while node is not None:
        if node == ancestor:
            return True
        node = parents.get(node)
    return False


def _check_rig_modifiers(report: Report, rel: str, rig: dict, clips: set) -> None:
    """Rig modifiers (backlog X-02): standard bones in parent-to-child chains, clips that exist,
    limits the look-at chain can actually reach, foot correction the pelvis can follow."""
    parents = _humanoid_parents()
    look = rig.get("look_at")
    if look is not None:
        names = [b["bone"] for b in look["bones"]]
        for bone in names:
            if bone not in parents:
                report.error(rel, f"rig_modifiers.look_at: unknown bone '{bone}'")
        if len(set(names)) != len(names):
            report.error(rel, "rig_modifiers.look_at: a bone is listed twice")
        for a, b in zip(names, names[1:]):
            if a in parents and b in parents and not _is_ancestor(parents, a, b):
                report.error(rel, f"rig_modifiers.look_at: '{a}' must be a parent (or ancestor) of '{b}' (parents first)")
        if look["bones"] and look["bones"][-1]["share"] != 1.0:
            report.error(rel, "rig_modifiers.look_at: the last bone (the head) must have share 1.0, or it never faces the look direction")
        for axis, limit_key, bone_key in (("yaw", "max_yaw_deg", "yaw_limit_deg"),
                                           ("pitch", "max_pitch_down_deg", "pitch_limit_deg"),
                                           ("pitch", "max_pitch_up_deg", "pitch_limit_deg")):
            reach = sum(b[bone_key] for b in look["bones"])
            if reach < look[limit_key]:
                report.error(rel, f"rig_modifiers.look_at: the bones' {axis} limits add up to {reach} degrees, less than {limit_key} {look[limit_key]}")
        if look["give_up_deg"] < look["max_yaw_deg"]:
            report.error(rel, "rig_modifiers.look_at: give_up_deg must be at least max_yaw_deg")
        for clip in look["suppress"]:
            if clip not in clips:
                report.error(rel, f"rig_modifiers.look_at: suppress clip '{clip}' is not in the animation set")
    feet = rig.get("foot_ik")
    if feet is not None:
        pelvis = feet["pelvis"]
        if pelvis not in parents:
            report.error(rel, f"rig_modifiers.foot_ik: unknown pelvis bone '{pelvis}'")
        for i, leg in enumerate(feet["legs"]):
            chain = [leg["upper"], leg["lower"], leg["foot"]]
            unknown = [b for b in chain if b not in parents]
            for bone in unknown:
                report.error(rel, f"rig_modifiers.foot_ik: unknown bone '{bone}' in leg {i}")
            if unknown:
                continue
            if parents[leg["lower"]] != leg["upper"] or parents[leg["foot"]] != leg["lower"]:
                report.error(rel, f"rig_modifiers.foot_ik: leg {i} must be a chain (upper -> lower -> foot)")
            if pelvis in parents and not _is_ancestor(parents, pelvis, leg["upper"]):
                report.error(rel, f"rig_modifiers.foot_ik: pelvis '{pelvis}' must be an ancestor of '{leg['upper']}'")
        feet_bones = [leg["foot"] for leg in feet["legs"]]
        if len(set(feet_bones)) != len(feet_bones):
            report.error(rel, "rig_modifiers.foot_ik: both legs end in the same foot")
        if feet["max_pelvis_drop_m"] > feet["max_drop_m"]:
            report.error(rel, "rig_modifiers.foot_ik: max_pelvis_drop_m must not exceed max_drop_m")
        if feet["ray_up_m"] < feet["max_raise_m"] or feet["ray_down_m"] < feet["max_drop_m"]:
            report.error(rel, "rig_modifiers.foot_ik: the rays must reach max_raise_m above and max_drop_m below the origin")
        for clip in feet["suppress"]:
            if clip not in clips:
                report.error(rel, f"rig_modifiers.foot_ik: suppress clip '{clip}' is not in the animation set")


def validate(data_dir: Path) -> list[str]:
    report = Report()
    registry, schemas = load_schemas(data_dir / "schemas")

    def check_schema(obj, schema_name: str, rel: str) -> bool:
        validator = Draft202012Validator(schemas[schema_name], registry=registry)
        errs = sorted(validator.iter_errors(obj), key=lambda e: list(e.path))
        for e in errs:
            loc = "/".join(str(p) for p in e.path) or "(root)"
            report.error(rel, f"schema: at {loc}: {e.message}")
        return not errs

    # ---- load everything -------------------------------------------------
    db: dict[str, dict[str, dict]] = {folder: {} for folder in FOLDERS}
    for folder, (schema_name, id_field) in FOLDERS.items():
        for path in sorted((data_dir / folder).glob("*.json")):
            rel = f"{folder}/{path.name}"
            obj = load_json(path, report, rel)
            if obj is None or not check_schema(obj, schema_name, rel):
                continue
            obj_id = obj[id_field]
            if obj_id != path.stem:
                report.error(rel, f"id '{obj_id}' does not match file name '{path.stem}'")
            if obj_id in db[folder]:
                report.error(rel, f"duplicate id '{obj_id}'")
            db[folder][obj_id] = obj

    tuning = None
    tuning_path = data_dir / "tuning.json"
    if not tuning_path.exists():
        report.error("tuning.json", "missing")
    else:
        t = load_json(tuning_path, report, "tuning.json")
        if t is not None and check_schema(t, "tuning.schema.json", "tuning.json"):
            tuning = t

    classes, specs = db["classes"], db["specs"]
    abilities, auras, trees = db["abilities"], db["auras"], db["talents"]

    # ids must be unique across abilities and talent nodes, since talents can reference either
    # (checked per tree below); and across abilities and auras, since a talent effect's path
    # starts with one of them and would otherwise silently change the ability
    for clash in sorted(set(abilities) & set(auras)):
        report.error(f"auras/{clash}.json", f"aura id '{clash}' is also an ability id; talent paths could not tell them apart")

    # ---- tuning sanity -----------------------------------------------------
    if tuning:
        p = tuning["pacing"]
        if p["gcd_min_s"] > p["gcd_s"]:
            report.error("tuning.json", "pacing.gcd_min_s is larger than pacing.gcd_s")
        dr = tuning["crowd_control"]["dr_multipliers"]
        if not dr or dr[-1] != 0 or dr != sorted(dr, reverse=True):
            report.error("tuning.json", "crowd_control.dr_multipliers must decrease and end at 0 (immune)")
        sim = tuning["simulation"]
        if sim["snapshot_rate_hz"] > sim["tick_rate_hz"]:
            report.error("tuning.json", "simulation.snapshot_rate_hz cannot exceed tick_rate_hz")

    # ---- classes -------------------------------------------------------------
    for cid, c in classes.items():
        rel = f"classes/{cid}.json"
        for sid in c["specs"]:
            if sid not in specs:
                report.error(rel, f"spec '{sid}' not found")
            elif specs[sid]["class"] != cid:
                report.error(rel, f"spec '{sid}' belongs to class '{specs[sid]['class']}'")
        _check_tree_ref(report, rel, trees, c["class_tree"], "class", cid)
        for aid in c.get("shared_abilities", []):
            if aid not in abilities:
                report.error(rel, f"shared ability '{aid}' not found")

    # ---- specs ---------------------------------------------------------------
    for sid, s in specs.items():
        rel = f"specs/{sid}.json"
        if s["class"] not in classes:
            report.error(rel, f"class '{s['class']}' not found")
        elif sid not in classes[s["class"]]["specs"]:
            report.error(rel, f"class '{s['class']}' does not list this spec")
        for aid in s["abilities"]:
            if aid not in abilities:
                report.error(rel, f"ability '{aid}' not found")
            elif abilities[aid]["owner"] not in (sid, s["class"], "shared"):
                report.error(rel, f"ability '{aid}' is owned by '{abilities[aid]['owner']}'")
        _check_tree_ref(report, rel, trees, s["spec_tree"], "spec", sid)
        _check_tree_ref(report, rel, trees, s["pvp_talents"], "pvp", sid)
        _check_talent_order(report, rel, _trees_for(s, classes, trees))
        if "asset" in s and s["asset"] not in db["assets"]:
            report.error(rel, f"asset '{s['asset']}' not found")
        if s["kit_status"] == "complete":
            _check_kit(report, rel, s, abilities, auras)

    # ---- abilities and auras ------------------------------------------------
    owners = set(classes) | set(specs) | {"shared"}
    for aid, a in abilities.items():
        rel = f"abilities/{aid}.json"
        if a["owner"] not in owners:
            report.error(rel, f"owner '{a['owner']}' is not a class, spec or 'shared'")
        for i, eff in enumerate(a["effects"]):
            if eff["type"] == "apply_aura" and eff["aura"] not in auras:
                report.error(rel, f"effects/{i}: aura '{eff['aura']}' not found")
    for auid, au in auras.items():
        rel = f"auras/{auid}.json"
        eff = au.get("periodic", {}).get("effect")
        if eff and eff["type"] == "apply_aura" and eff["aura"] not in auras:
            report.error(rel, f"periodic effect aura '{eff['aura']}' not found")
        if au["cc_category"] != "none" and au["kind"] != "debuff":
            report.error(rel, "crowd control auras must be debuffs")

    # ---- burst windows stay 1 to 3 minutes (DESIGN.md kit template), whatever talents stack ----
    for aid, ab in abilities.items():
        if ab.get("kit_slot") != "burst":
            continue
        low = high = float(ab["cooldown_s"])
        for t in trees.values():
            for n in t["nodes"]:
                ranks = n.get("ranks", 1)
                options = n.get("choices") or [n]
                deltas = [sum(e.get("per_rank", 0) * (ranks if src is n else 1) for e in src.get("effects", [])
                              if e["modify"] == f"{aid}.cooldown_s") for src in options]
                low += min(0, min(deltas))
                high += max(0, max(deltas))
        if low < 60 or high > 180:
            report.error(f"abilities/{aid}.json", f"burst cooldown can reach {low:g} to {high:g} s with talents; "
                         "burst windows are 60 to 180 s (DESIGN.md kit template)")

    # ---- talent trees --------------------------------------------------------
    for tid, t in trees.items():
        _check_tree(report, f"talents/{tid}.json", t, abilities, auras, tuning)

    # ---- animation sets ----------------------------------------------------------
    sys.path.insert(0, str(REPO / "tools" / "blender"))
    import animation as anim_mod  # pure Python part: term table and key checks

    for aid, a in db["animations"].items():
        rel = f"animations/{aid}.json"
        for problem in anim_mod.validate_set(a):
            report.error(rel, problem)
        missing = [c for c in anim_mod.REQUIRED_CLIPS if c not in a["clips"]]
        if missing:
            report.error(rel, f"missing required clips: {', '.join(missing)}")
        for cname, clip in a["clips"].items():
            cap = clip.get("capture")
            if not cap:
                continue
            src = cap["source"]
            if src not in db["capture_sources"]:
                report.error(rel, f"clip {cname}: no capture source '{src}' (data/capture_sources/{src}.json)")
                continue
            if src not in db["captures"]:
                report.error(rel, f"clip {cname}: capture '{src}' not fitted (run tools/blender/build_capture.py)")
                continue
            fitted = db["captures"][src]
            if fitted["loop"] != clip["loop"]:
                report.error(rel, f"clip {cname}: loop is {clip['loop']} but capture '{src}' loop is {fitted['loop']}")
            for bone in cap.get("bones", []):
                if bone not in fitted["channels"]:
                    report.error(rel, f"clip {cname}: capture '{src}' has no channels for bone '{bone}'")
            for key in cap.get("gains", {}):
                bone, _, term = key.partition(".")
                if not any(anim_mod.family(b) == bone or b == bone for b in fitted["channels"]) or not term:
                    report.error(rel, f"clip {cname}: gain '{key}' matches no captured channel")
            if "capture_leg_m" not in a:
                report.error(rel, "clips use captures but capture_leg_m (leg length per build) is missing")
    for sid, src in db["capture_sources"].items():
        if not (REPO / "tools" / "blender" / "mocap_src" / src["file"]).exists():
            report.error(f"capture_sources/{sid}.json", f"file not found: tools/blender/mocap_src/{src['file']}")
        if not src["loop"] and "length_s" not in src:
            report.error(f"capture_sources/{sid}.json", "a capture that does not loop needs length_s")
    for cid, c in db["captures"].items():
        if cid not in db["capture_sources"]:
            report.error(f"captures/{cid}.json", "no matching capture source (stale fitted file)")
        for bone, terms in c["channels"].items():
            for term, v in terms.items():
                if len(v) != c["samples"]:
                    report.error(f"captures/{cid}.json", f"{bone}.{term}: {len(v)} samples, expected {c['samples']}")
    _check_ability_text(report, data_dir)
    _check_effects(report, db, schemas)
    _check_hud_layouts(report, db)
    _check_icons_and_fonts(report, db, data_dir)
    _check_menus(report, db)
    sys.path.insert(0, str(REPO / "tools" / "audio"))
    import sound_data  # sounds and the sound map (backlog M1-26); weapon sounds per spec

    sound_data.check(report.error, db, data_dir)
    for sid, st in db["anim_states"].items():
        _check_anim_states(report, f"anim_states/{sid}.json", st, db, schemas)
    for asid, asset in db["assets"].items():
        if asset["kind"] == "animation":
            set_id = asset.get("params", {}).get("set", "")
            if set_id not in db["animations"]:
                report.error(f"assets/{asid}.json", f"unknown animation set '{set_id}'")

    # ---- maps ------------------------------------------------------------------
    for mid, m in db["maps"].items():
        rel = f"maps/{mid}.json"
        if m.get("kit"):
            needed = {"floor_tile", "wall", "corner"} | {c.get("tag", "") for c in m["colliders"]} - {""}
            needed |= {d["piece"] for d in m.get("decor", [])}
            needed = {"gate" if n == "gate" else n for n in needed}
            if any(c.get("gate") for c in m["colliders"]):
                needed.add("gate_lintel")
            # dressing (backlog F-05): every piece it names must have a spec
            dr = m.get("dressing", {})
            needed |= {v for k, v in dr.get("wall_top", {}).items() if isinstance(v, str)}
            if dr.get("gatehouse"):
                needed.add(dr["gatehouse"]["piece"])
            for base, table in dr.get("variants", {}).items():
                needed |= {base} | set(table)
            needed |= {s["piece"] for s in dr.get("skyline", {}).get("pieces", [])}
            for piece in sorted(needed):
                if f"{m['kit']}_{piece}" not in db["assets"]:
                    report.error(rel, f"kit '{m['kit']}' has no asset spec for piece '{piece}' "
                                      f"(expected assets/{m['kit']}_{piece}.json)")
        for i, dec in enumerate(m.get("decor", [])):
            if dec.get("effect") and dec["effect"] not in db["ambient_effects"]:
                report.error(rel, f"decor/{i}: unknown ambient effect '{dec['effect']}'")
        margin = 1.0  # the skyline stands beyond the walls: never inside the playable square
        for i, s in enumerate(m.get("dressing", {}).get("skyline", {}).get("pieces", [])):
            if max(abs(s["pos"][0]), abs(s["pos"][1])) < m["bounds_half_m"] + margin:
                report.error(rel, f"dressing/skyline/pieces/{i}: '{s['piece']}' at {s['pos']} is inside the "
                                  f"walls (bounds {m['bounds_half_m']} m)")
        if m.get("lighting_preset") and m["lighting_preset"] not in db["lighting"]:
            report.error(rel, f"unknown lighting preset '{m['lighting_preset']}'")
        need = max(BRACKET_SIZE[b] for b in m["brackets"])
        for team in ("team_a", "team_b"):
            if len(m["spawns"][team]) < need:
                report.error(rel, f"{team} has {len(m['spawns'][team])} spawns; bracket needs {need}")
            for sp in m["spawns"][team]:
                blocker = _spawn_blocked(m, sp[0], sp[2])
                if blocker:
                    report.error(rel, f"{team} spawn {sp} is inside or touching {blocker}")
        pickup_brackets = set((tuning or {}).get("arena", {}).get("pickup_brackets", []))
        if pickup_brackets & set(m["brackets"]) and not m.get("pickups"):
            report.error(rel, f"hosts {', '.join(sorted(pickup_brackets & set(m['brackets'])))}, which spawn "
                         "regeneration pickups, but lists no pickups")
        for sp in m.get("pickups", []):
            blocker = _spawn_blocked(m, sp[0], sp[2])
            if blocker:
                report.error(rel, f"pickup {sp} is inside or touching {blocker}")
        # twists (M2-16): what a collapse takes away exists, never a wall or gate, and its sounds exist
        tags = {c.get("tag", "") for c in m["colliders"]}
        for t in m.get("twists", []):
            for tag in t.get("tags", []):
                if tag not in tags:
                    report.error(rel, f"twist '{t['id']}' takes away '{tag}', which no collider has")
                elif tag in ("wall", "gate"):
                    report.error(rel, f"twist '{t['id']}' takes away '{tag}' colliders; the arena would open to its outside")
            for k in ("warn_sound", "sound", "loop_sound", "push_sound"):
                if t.get(k) and t[k] not in db.get("sounds", {}):
                    report.error(rel, f"twist '{t['id']}' {k} '{t[k]}' is not in data/sounds")
            if t.get("warn_s", 0) > 0 and not t.get("warn_text"):
                report.error(rel, f"twist '{t['id']}' warns {t['warn_s']} s ahead but has no warn_text")
            if t["type"] == "rotate":
                for e in _rotate_problems(m, t):
                    report.error(rel, f"twist '{t['id']}': {e}")

    # ---- bracket auras (M2-07): each names a real aura and a real role or spec -------------
    for b, rules in (tuning or {}).get("arena", {}).get("bracket_auras", {}).items():
        for i, r in enumerate(rules):
            where = f"tuning.arena.bracket_auras.{b}/{i}"
            if r["aura"] not in db["auras"]:
                report.error("tuning.json", f"{where}: aura '{r['aura']}' not found")
            elif db["auras"][r["aura"]].get("dispel_type", "none") != "none" or db["auras"][r["aura"]].get("duration_s", 0) != 0:
                report.error("tuning.json", f"{where}: aura '{r['aura']}' must be permanent and undispellable")
            if "spec" in r and r["spec"] not in specs:
                report.error("tuning.json", f"{where}: unknown spec '{r['spec']}'")
            if "role" in r and r["role"] not in {s.get("role") for s in specs.values()}:
                report.error("tuning.json", f"{where}: no spec has role '{r['role']}'")
            if "role" not in r and "spec" not in r:
                report.error("tuning.json", f"{where}: name a role or a spec")

    # ---- assets ------------------------------------------------------------------
    for asid, a in db["assets"].items():
        rel = f"assets/{asid}.json"
        if a["tri_budget"]["min"] > a["tri_budget"]["max"]:
            report.error(rel, "tri_budget.min is larger than tri_budget.max")
        if not (data_dir.parent / "tools" / "blender" / a["builder"]).exists():
            report.error(rel, f"builder script tools/blender/{a['builder']} not found")
        if a["kind"] == "character" and a.get("spec") not in specs:
            report.error(rel, f"character asset needs a valid spec, got '{a.get('spec')}'")

    # ---- bot profiles ------------------------------------------------------------
    for bid, b in db["bots"].items():
        rel = f"bots/{bid}.json"
        if bid not in specs:
            report.error(rel, f"no spec '{bid}'")
            continue
        known = set(specs[bid]["abilities"]) | set(classes.get(specs[bid]["class"], {}).get("shared_abilities", []))
        spec_trees = _trees_for(specs[bid], classes, db["talents"])
        for tree in spec_trees.values():
            for n in (tree or {}).get("nodes", []):
                known |= {g for g in [n.get("grants_ability")] + [c.get("grants_ability") for c in n.get("choices", [])] if g}
        names = [bd["name"] for bd in b.get("builds", [])]
        for dup in sorted({x for x in names if names.count(x) > 1}):
            report.error(rel, f"two builds are named '{dup}'")
        for bd in b.get("builds", []):
            problem = loadout_problem(bd, spec_trees)
            if problem:
                report.error(rel, f"build '{bd['name']}': {problem}")
        for i, r in enumerate(b["priorities"]):
            if r["ability"] not in known:
                report.error(rel, f"priorities/{i}: '{r['ability']}' is not in the {bid} kit")

    # ---- keybinds ------------------------------------------------------------------
    for kid, k in db["keybinds"].items():
        rel = f"keybinds/{kid}.json"
        seen: dict[tuple, str] = {}
        actions: set[str] = set()
        for b in k["binds"]:
            combo = (b["key"], tuple(sorted(b.get("modifiers", []))))
            if combo in seen:
                report.error(rel, f"key conflict: {'+'.join(combo[1] + (combo[0],))} bound to both '{seen[combo]}' and '{b['action']}'")
            seen[combo] = b["action"]
            if b["action"] in actions:
                report.error(rel, f"action '{b['action']}' is bound more than once")
            actions.add(b["action"])

    return report.errors


# Spell effects (backlog M1-25): crowd control must be readable, so CC auras need a CC style.
EFFECT_STAGES = ("cast", "projectile", "impact", "ground", "melee", "displacement", "auras")
CC_AURA_STYLES = {"stun", "disorient", "root", "silence", "ice_block"}
UNIT_TARGETS = ("enemy", "ally", "any_unit")


# Text keys the client reads from a menu (game/ui/main_menu.gd, match_overlay.gd, end_screen.gd).
# Every text key the client's menu and match flow screens read (game/ui/main_menu.gd,
# game/ui/match_screens.gd, game/ui/pause_menu.gd).
MENU_TEXT_KEYS = [
    "starting_server", "loading_arena", "connecting", "waiting", "preparation", "gates_in", "gates_open",
    "fight", "victory", "defeat", "draw", "reason_enemy_eliminated", "reason_team_eliminated",
    "reason_both_eliminated", "reason_time_limit", "failed", "failed_server_lost", "failed_disconnected",
    "failed_rejected", "failed_start", "failed_silent", "back_to_menu", "menu_title", "resume",
    "leave_match", "leave_practice", "leave_note", "your_team", "enemy_team", "you", "partner", "enemy",
    "total", "player_column", "match_time", "settings_title", "settings_profile", "settings_keys",
    "settings_note", "yes", "no", "close",
]


def _check_menus(report: Report, db: dict) -> None:
    """Menus (backlog M1-28): picker specs are finished kits with a bot comp each, comps fill the
    bracket with existing finished specs that have bot profiles, the map exists, every text key the
    client reads is present."""
    specs, bots = db["specs"], db["bots"]
    for mid, m in db["menus"].items():
        rel = f"menus/{mid}.json"
        picker = m["spec_picker"]
        if picker["default"] not in picker["specs"]:
            report.error(rel, f"spec_picker.default '{picker['default']}' is not in spec_picker.specs")
        _check_settings_screen(report, rel, m.get("settings_screen", {}), db["settings"].get("default", {}))
        presets = {k: m[k] for k in ("play_bots", "play_1v1", "play_3v3") if k in m}
        for key, pb in presets.items():
            if pb["map"] not in db["maps"]:
                report.error(rel, f"{key}.map '{pb['map']}' not found in maps")
            elif pb["bracket"] not in db["maps"][pb["map"]]["brackets"]:
                report.error(rel, f"{key}: map '{pb['map']}' does not host {pb['bracket']}")
            for mid in pb.get("maps", []):
                if mid not in db["maps"]:
                    report.error(rel, f"{key}.maps: '{mid}' not found in maps")
                elif pb["bracket"] not in db["maps"][mid]["brackets"]:
                    report.error(rel, f"{key}.maps: '{mid}' does not host {pb['bracket']}")
            lo, hi = pb["port_range"]
            if lo > hi:
                report.error(rel, f"{key}.port_range must be [low, high]")
            size = int(pb["bracket"][0])
            if len(pb["bot_names"]["enemies"]) < size or len(pb["bot_names"]["allies"]) < size - 1:
                report.error(rel, f"{key}.bot_names needs {size - 1} ally and {size} enemy names")
            if pb["host_name"] in pb["bot_names"]["allies"] + pb["bot_names"]["enemies"]:
                report.error(rel, f"{key}.host_name must differ from every bot name")

        def playable(sid: str, where: str, need_bot: bool) -> None:
            if sid not in specs:
                report.error(rel, f"{where}: unknown spec '{sid}'")
            elif specs[sid].get("kit_status") != "complete":
                report.error(rel, f"{where}: spec '{sid}' is not a complete kit")
            elif need_bot and sid not in bots:
                report.error(rel, f"{where}: spec '{sid}' has no bot profile")

        for sid in picker["specs"]:
            playable(sid, "spec_picker", False)
        for key, pb in presets.items():
            size = int(pb["bracket"][0])
            for sid in picker["specs"]:
                if sid not in pb["comps"]:
                    report.error(rel, f"{key}.comps has no comp for picker spec '{sid}'")
            for sid, comp in pb["comps"].items():
                playable(sid, f"{key}.comps.{sid}", False)
                if len(comp["allies"]) != size - 1:
                    report.error(rel, f"{key}.comps.{sid}.allies must have {size - 1} specs for {pb['bracket']}")
                for a in comp["allies"]:
                    playable(a, f"{key}.comps.{sid}.allies", True)
                if len(comp["enemies"]) != size:
                    report.error(rel, f"{key}.comps.{sid}.enemies must have {size} specs for {pb['bracket']}")
                for e in comp["enemies"]:
                    playable(e, f"{key}.comps.{sid}.enemies", True)
        for key in MENU_TEXT_KEYS:
            if key not in m["text"]:
                report.error(rel, f"text is missing '{key}'")
        actions = {b["action"] for b in m["buttons"]}
        for needed in ("play_bots", "quit"):
            if needed not in actions:
                report.error(rel, f"no button with action '{needed}'")
        ids = [b["id"] for b in m["buttons"]]
        if len(ids) != len(set(ids)):
            report.error(rel, "button ids must be unique")
        for face, spec in m["fonts"].items():
            path = REPO / "game" / "assets" / "fonts" / spec["file"]
            if not path.exists():
                report.error(rel, f"fonts.{face}: font file '{spec['file']}' not found in game/assets/fonts")
            elif not (path.parent / "OFL.txt").exists():
                report.error(rel, f"fonts.{face}: no licence (OFL.txt) next to '{spec['file']}'")
        if "settings" in actions and not m.get("settings_screen", {}).get("pages"):
            report.error(rel, "a button opens the settings but there is no settings_screen")


def _check_hud_layouts(report: Report, db: dict) -> None:
    """HUD layouts (backlog M1-27): bars bound to real keys, assignments inside the spec's kit,
    every CC category drawn with a label and glyph, every complete kit fits on the bars."""
    abilities, specs, classes, auras = db["abilities"], db["specs"], db["classes"], db["auras"]
    for sid, s in db["settings"].items():
        lay = s.get("interface", {}).get("hud_layout")
        if lay is not None and lay not in db["hud_layouts"]:
            report.error(f"settings/{sid}.json", f"interface.hud_layout '{lay}' not found in hud_layouts")
    used_cc = {a["cc_category"] for a in auras.values()} - {"none", "knockback"}
    for lid, lay in db["hud_layouts"].items():
        rel = f"hud_layouts/{lid}.json"
        elements = lay["elements"]
        bars = {eid: e for eid, e in elements.items() if e["type"] == "action_bar"}
        for eid, e in bars.items():
            for kid, k in db["keybinds"].items():
                bound = {b["action"] for b in k["binds"]}
                missing = [f"{e['action_prefix']}{n}" for n in range(1, e["buttons"] + 1)
                           if f"{e['action_prefix']}{n}" not in bound]
                if missing:
                    report.error(rel, f"elements/{eid}: actions {', '.join(missing)} not bound in keybinds/{kid}.json")
        ab = lay["action_bars"]
        for bid in ab["fill_order"]:
            if bid not in bars:
                report.error(rel, f"action_bars.fill_order: '{bid}' is not an action_bar element")
        for aid in ab["exclude"]:
            if aid not in abilities:
                report.error(rel, f"action_bars.exclude: ability '{aid}' not found")
        capacity = sum(bars[b]["buttons"] for b in ab["fill_order"] if b in bars)
        for spec_id, spec in specs.items():
            kit = list(spec["abilities"]) + list(classes.get(spec["class"], {}).get("shared_abilities", []))
            if spec_id in ab["assignments"]:
                for bid, slots in ab["assignments"][spec_id].items():
                    if bid not in bars:
                        report.error(rel, f"action_bars.assignments/{spec_id}: '{bid}' is not an action_bar element")
                        continue
                    if len(slots) > bars[bid]["buttons"]:
                        report.error(rel, f"action_bars.assignments/{spec_id}/{bid}: {len(slots)} slots on a {bars[bid]['buttons']}-button bar")
                    for aid in slots:
                        if aid == "":
                            continue
                        if aid not in abilities:
                            report.error(rel, f"action_bars.assignments/{spec_id}/{bid}: ability '{aid}' not found")
                        elif aid not in kit:
                            report.error(rel, f"action_bars.assignments/{spec_id}/{bid}: '{aid}' is not in the {spec_id} kit")
                continue
            placed = [a for a in kit if a not in ab["exclude"] and abilities.get(a, {}).get("cast_type") != "passive"]
            if spec.get("kit_status") == "complete" and len(placed) > capacity:
                report.error(rel, f"{spec_id}: {len(placed)} abilities do not fit on {capacity} action buttons")
        for cat in used_cc:
            if cat not in lay["crowd_control"]:
                report.error(rel, f"crowd_control: no label and glyph for CC category '{cat}' (used by auras)")
        for key in ("loss_of_control", "dr_categories"):
            for cat in lay[key]:
                if cat not in lay["crowd_control"]:
                    report.error(rel, f"{key}: '{cat}' has no crowd_control entry")
        for i, rule in enumerate(lay["icon_glyphs"]):
            try:
                re.compile(rule["match"])
            except re.error as exc:
                report.error(rel, f"icon_glyphs/{i}: bad pattern: {exc}")
        for eid, e in elements.items():
            if e["type"] == "combat_text" and e.get("lifetime_s", 1) > 5:
                report.error(rel, f"elements/{eid}: combat text lifetime over 5 s clutters the screen")


def _check_icons_and_fonts(report: Report, db: dict, data_dir: Path) -> None:
    """Icons and typefaces (backlog X-03): every icon.image names a game-icons.net SVG copied into
    game/assets/icons/game-icons, rendered to a glyph PNG and credited in ATTRIBUTION.md; every
    HUD font file exists next to its OFL.txt; the icon layers exist."""
    game = data_dir.parent / "game"
    if not game.is_dir():  # a copy of /data alone (validator tests): check against the repo
        game = REPO / "game"
    icons = game / "assets" / "icons"
    credited: set[str] = set()
    attribution = icons / "game-icons" / "ATTRIBUTION.md"
    if attribution.exists():
        for line in attribution.read_text().splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) >= 3 and cells[0] not in ("Icon", "---"):
                credited.add(f"{cells[1].lower().replace(' ', '-')}/{cells[0]}")
    owners = [(f"{folder}/{oid}.json", obj) for folder in ("abilities", "auras") for oid, obj in db[folder].items()]
    for tid, t in db["talents"].items():
        for n in t["nodes"]:
            owners.append((f"talents/{tid}.json node '{n['id']}'", n))
            owners += [(f"talents/{tid}.json node '{n['id']}' option '{c['id']}'", c) for c in n.get("choices", [])]
    for rel, obj in owners:
            img = obj.get("icon", {}).get("image")
            if not img:
                continue
            if not (icons / "game-icons" / f"{img}.svg").exists():
                report.error(rel, f"icon image '{img}' not found (game/assets/icons/game-icons/{img}.svg)")
            elif not (icons / "glyphs" / f"{img}.png").exists():
                report.error(rel, f"icon image '{img}' has no rendered glyph (run tools/build_icons.py)")
            elif img not in credited:
                report.error(rel, f"icon image '{img}' is not credited in game-icons/ATTRIBUTION.md (run tools/build_icons.py)")
    for lid, lay in db["hud_layouts"].items():
        rel = f"hud_layouts/{lid}.json"
        style = lay["style"]
        for face, spec in style.get("fonts", {}).items():
            path = game / "assets" / "fonts" / spec["file"]
            if not path.exists():
                report.error(rel, f"style.fonts.{face}: font file '{spec['file']}' not found in game/assets/fonts")
            elif not (path.parent / "OFL.txt").exists():
                report.error(rel, f"style.fonts.{face}: no licence (OFL.txt) next to '{spec['file']}'")
        art = style.get("icon_art")
        if art:
            if not (icons / art["glyphs"]).is_dir():
                report.error(rel, f"style.icon_art.glyphs: folder '{art['glyphs']}' not found in game/assets/icons")
            for key in ("frame", "shade"):
                if not (icons / art[key]).exists():
                    report.error(rel, f"style.icon_art.{key}: '{art[key]}' not found in game/assets/icons")


def _check_effects(report: Report, db: dict, schemas: dict) -> None:
    abilities, auras, effects = db["abilities"], db["auras"], db["effects"]
    palettes = db["effect_palettes"]
    if "default" not in palettes:
        report.error("effect_palettes", "missing the 'default' palette")
    schools = schemas["common.schema.json"]["$defs"]["school"]["enum"]
    for pid, p in palettes.items():
        for school in schools:
            if school not in p["schools"]:
                report.error(f"effect_palettes/{pid}.json", f"no colors for school '{school}'")
    # every ability of a finished kit (and its class's shared abilities) has an entry
    covered: set[str] = set()
    for sid, s in db["specs"].items():
        if s["kit_status"] != "complete":
            continue
        covered |= set(s["abilities"])
        covered |= set(db["classes"].get(s["class"], {}).get("shared_abilities", []))
    # talent-granted abilities count too, and talents can change what an ability applies (X-13)
    talent_auras = _talent_applied_auras(db["talents"])
    for t in db["talents"].values():
        for n in t["nodes"]:
            for src in n.get("choices") or [n]:
                if src.get("grants_ability"):
                    covered.add(src["grants_ability"])
    for aid in sorted(covered):
        if aid in abilities and aid not in effects:
            report.error(f"effects/{aid}.json", f"ability '{aid}' has no effect entry (add one, or \"none\": true with a reason)")
    defined: dict[str, str] = {}  # aura id -> effect file defining its visual
    for eid, e in effects.items():
        rel = f"effects/{eid}.json"
        a = abilities.get(eid)
        if a is None:
            report.error(rel, f"no ability '{eid}'")
            continue
        stages = [s for s in EFFECT_STAGES if s in e]
        if e.get("none"):
            if stages:
                report.error(rel, f"marked none but has stages: {', '.join(stages)}")
            if not e.get("reason"):
                report.error(rel, "marked none without a reason")
            continue
        if not stages:
            report.error(rel, "has no stages (mark it \"none\": true with a reason instead)")
        effect_types = {x["type"] for x in a["effects"]}
        radius = [x for x in a["effects"] if x.get("radius_m")]
        applied = {x["aura"] for x in a["effects"] if x["type"] == "apply_aura"} | talent_auras.get(eid, set())
        if "cast" in e and a["cast_type"] not in ("cast", "channel"):
            report.error(rel, f"cast glow on a {a['cast_type']} ability")
        if "projectile" in e and a["target"] not in UNIT_TARGETS:
            report.error(rel, f"projectile needs a unit target, ability targets '{a['target']}'")
        if e.get("impact", {}).get("at", "target") == "target" and "impact" in e and a["target"] not in UNIT_TARGETS:
            report.error(rel, f"impact at the target, but the ability targets '{a['target']}' (use 'self' or 'hits')")
        if "ground" in e:
            if not radius:
                report.error(rel, "ground effect on an ability without a radius effect (the radius comes from the ability)")
            if e["ground"].get("center", "caster") == "target" and a["target"] not in UNIT_TARGETS:
                report.error(rel, "ground effect centred on the target, but the ability has no unit target")
        if "displacement" in e and not effect_types & {"charge", "teleport"}:
            report.error(rel, "displacement on an ability that neither charges nor teleports")
        if e.get("trigger") == "damage" and "damage" not in effect_types:
            report.error(rel, "trigger 'damage' on an ability that deals no damage")
        for auid, vis in e.get("auras", {}).items():
            if auid not in auras:
                report.error(rel, f"aura '{auid}' not found")
                continue
            if auid not in applied:
                report.error(rel, f"aura '{auid}' is not applied by ability '{eid}' (nor by a talented version of it)")
            if auid in defined:
                report.error(rel, f"aura '{auid}' already has a visual in effects/{defined[auid]}.json")
            defined[auid] = eid
            cat = auras[auid]["cc_category"]
            if cat not in ("none", "knockback"):
                style = vis if vis == "none" else vis["style"]
                if style not in CC_AURA_STYLES:
                    report.error(rel, f"aura '{auid}' is crowd control ({cat}) and needs a readable CC style "
                                      f"({', '.join(sorted(CC_AURA_STYLES))}), not '{style}'")
    # every aura a covered ability applies, in its data or through a talent, has a visual (or "none")
    for aid in sorted(covered & set(abilities)):
        applies = [x["aura"] for x in abilities[aid]["effects"] if x["type"] == "apply_aura"] + sorted(talent_auras.get(aid, set()))
        for auid in applies:
            if auid in auras and auid not in defined:
                report.error(f"effects/{aid}.json", f"aura '{auid}' applied by '{aid}' has no visual in any effect file")
                defined[auid] = aid  # report once


def _talent_applied_auras(trees: dict) -> dict[str, set[str]]:
    """Ability id -> auras that talents make it apply: apply_aura entries in a talent effect that
    sets or adds to "<ability>.effects" (or one of its entries)."""
    out: dict[str, set[str]] = {}

    def walk(v):
        if isinstance(v, dict):
            if v.get("type") == "apply_aura" and "aura" in v:
                yield v["aura"]
            for x in v.values():
                yield from walk(x)
        elif isinstance(v, list):
            for x in v:
                yield from walk(x)

    for t in trees.values():
        for n in t["nodes"]:
            for src in n.get("choices") or [n]:
                for e in src.get("effects", []):
                    parts = e["modify"].split(".")
                    if len(parts) >= 2 and parts[1] == "effects":
                        for auid in walk([e.get(k) for k in ("set", "add", "per_rank") if k in e]):
                            out.setdefault(parts[0], set()).add(auid)
    return out


def _check_tree_ref(report: Report, rel: str, trees: dict, tree_id: str, kind: str, owner: str) -> None:
    t = trees.get(tree_id)
    if t is None:
        report.error(rel, f"{kind} talent tree '{tree_id}' not found")
    elif t["kind"] != kind:
        report.error(rel, f"talent tree '{tree_id}' is kind '{t['kind']}', expected '{kind}'")
    elif t["owner"] != owner:
        report.error(rel, f"talent tree '{tree_id}' is owned by '{t['owner']}'")


def _check_talent_order(report: Report, rel: str, spec_trees: dict) -> None:
    """Talents apply class tree, spec tree, then PvP, each in node order (Talents.resolve). A talent
    that sets a whole field after another talent edited inside it would wipe that edit out, and two
    talents setting one field leave only the later one; both depend on file order, so reject them.
    The two options of one choice node never apply together, so they may set the same field."""
    seen: list[tuple[str, str, str]] = []  # (modify path, node id, how)
    for layer in ("class", "spec", "pvp"):
        for n in (spec_trees.get(layer) or {}).get("nodes", []):
            for src in n.get("choices") or [n]:
                for e in src.get("effects", []):
                    path = e["modify"]
                    if "set" in e:
                        for other, node, how in seen:
                            if node == n["id"]:
                                continue
                            if other.startswith(path + "."):
                                report.error(rel, f"talent '{n['id']}' sets {path} after '{node}' changed {other}, "
                                             "which the set would undo; move the set earlier")
                            elif other == path and how == "set":
                                report.error(rel, f"talents '{node}' and '{n['id']}' both set {path}; only the later would count")
                    seen.append((path, n["id"], "set" if "set" in e else "add"))


def _check_settings_screen(report: Report, rel: str, screen: dict, profile: dict) -> None:
    """Every settings row names a setting of the default profile, of the row's kind; a slider's
    default lies in its range and a choice's among its choices (M2-13)."""
    for page in screen.get("pages", []):
        for i, row in enumerate(page["rows"]):
            where = f"settings_screen.{page['id']}.rows/{i}"
            if row["type"] in ("note", "keybinds"):
                continue
            node = profile
            for part in row.get("path", "").split("."):
                node = node.get(part) if isinstance(node, dict) else None
            if node is None:
                report.error(rel, f"{where}: no setting '{row.get('path')}' in settings/default.json")
                continue
            if row["type"] == "toggle" and not isinstance(node, bool):
                report.error(rel, f"{where}: '{row['path']}' is not on/off")
            elif row["type"] == "slider":
                if isinstance(node, bool) or not isinstance(node, (int, float)):
                    report.error(rel, f"{where}: '{row['path']}' is not a number")
                elif not row["min"] <= node <= row["max"]:
                    report.error(rel, f"{where}: default {node} is outside {row['min']} to {row['max']}")
            elif row["type"] == "choice":
                if node not in row["choices"]:
                    report.error(rel, f"{where}: default {node!r} is not one of the choices")
                if "labels" in row and len(row["labels"]) != len(row["choices"]):
                    report.error(rel, f"{where}: {len(row['labels'])} labels for {len(row['choices'])} choices")


def _trees_for(spec: dict, classes: dict, trees: dict) -> dict:
    cls = classes.get(spec["class"], {})
    return {"class": trees.get(cls.get("class_tree", "")), "spec": trees.get(spec.get("spec_tree", "")),
            "pvp": trees.get(spec.get("pvp_talents", ""))}


def loadout_problem(loadout: dict, trees: dict) -> str:
    """Why a loadout breaks its trees' rules, or ''. Mirrors Talents.check in game/core/talents.gd
    (game/test/core/test_talents.gd checks every bot build with that one too)."""
    def cost(n, v):
        return 1 if n["type"] == "choice" else v

    for layer in ("class", "spec"):
        picks = loadout.get(layer, {})
        if not picks:
            continue
        tree = trees.get(layer)
        if not tree:
            return f"{layer}: no {layer} tree"
        by_id = {n["id"]: n for n in tree["nodes"]}
        for nid, val in picks.items():
            n = by_id.get(nid)
            if n is None:
                return f"{layer}: no node '{nid}'"
            top = len(n["choices"]) if n["type"] == "choice" else n.get("ranks", 1)
            if not 1 <= val <= top:
                return f"{layer}: '{nid}' takes 1 to {top}, not {val}"
        spent = sum(cost(by_id[k], v) for k, v in picks.items())
        if spent > tree["points"]:
            return f"{layer}: {spent} points spent, {tree['points']} available"
        for nid in picks:
            n = by_id[nid]
            gate = n.get("gate", 0)
            before = sum(cost(by_id[k], v) for k, v in picks.items() if by_id[k].get("gate", 0) < gate)
            if gate and before < gate:
                return f"{layer}: '{nid}' needs {gate} points before its gate, has {before}"
            reqs = n.get("requires_any", [])
            ok = not reqs or any(r not in by_id or picks.get(r, 0) >= (1 if by_id[r]["type"] == "choice" else by_id[r].get("ranks", 1)) for r in reqs)
            if not ok:
                return f"{layer}: '{nid}' needs one of {', '.join(reqs)} fully ranked"
    pvp = loadout.get("pvp", [])
    tree = trees.get("pvp") or {"nodes": [], "points": 0}
    ids = {n["id"] for n in tree["nodes"]}
    if len(pvp) > tree["points"]:
        return f"pvp: {len(pvp)} talents, {tree['points']} slots"
    for x in pvp:
        if x not in ids:
            return f"pvp: no talent '{x}'"
    if len(set(pvp)) != len(pvp):
        return "pvp: a talent is picked twice"
    return ""


# What a talent effect may change on the unit itself (Talents.apply_self in game/core/talents.gd)
# and the ability or aura fields it may add to when the data leaves them out (Talents.PATH_DEFAULTS).
TALENT_SELF_STATS = ("power_bonus", "haste", "crit_chance")
TALENT_PATH_DEFAULTS = ("pvp_modifier",)


def _talent_path_problem(e: dict, abilities: dict, auras: dict, tuning: dict | None) -> str:
    """Why a talent effect's path does not name a field it can change, or ''."""
    target, _, path = e["modify"].partition(".")
    parts = path.split(".") if path else []
    adds = "set" not in e
    if target == "self":
        if parts == ["max_health"]:
            return ""
        if len(parts) == 2 and parts[0] == "stats":
            return "" if parts[1] in TALENT_SELF_STATS else f"units have no stat '{parts[1]}' (stats: {', '.join(TALENT_SELF_STATS)})"
        if len(parts) == 2 and parts[0] == "resource_max":
            known = (tuning or {}).get("resources", {})
            return "" if not known or parts[1] in known else f"no resource '{parts[1]}'"
        return "a talent can change self.max_health, self.stats.<stat> or self.resource_max.<resource>"
    if not parts:
        return "names no field"
    node = abilities.get(target, auras.get(target))
    for i, key in enumerate(parts):
        last = i == len(parts) - 1
        if isinstance(node, list):
            if not key.isdigit() or int(key) >= len(node):
                return f"'{key}' is not an index of the list at '{'.'.join(parts[:i]) or target}'"
            node = node[int(key)]
        elif isinstance(node, dict):
            if key not in node:
                if last and (key in TALENT_PATH_DEFAULTS or not adds):
                    return ""  # a default the game fills in, or a new field the talent sets
                return f"'{target}' has no field '{'.'.join(parts[:i + 1])}'"
            node = node[key]
        else:
            return f"'{'.'.join(parts[:i])}' is a value, not a group of fields"
    if adds and (isinstance(node, bool) or not isinstance(node, (int, float))):
        return "per_rank adds to a number, but this field is not one (use 'set')"
    return ""


def _check_tree(report: Report, rel: str, t: dict, abilities: dict, auras: dict, tuning: dict | None) -> None:
    nodes = t["nodes"]
    ids = [n["id"] for n in nodes]
    by_id = {n["id"]: n for n in nodes}
    for dup in sorted({i for i in ids if ids.count(i) > 1}):
        report.error(rel, f"duplicate node id '{dup}'")
    for nid in ids:
        if nid in abilities:
            report.error(rel, f"node id '{nid}' clashes with an ability id")

    gates = t.get("gates", [])
    if t["kind"] == "pvp" and gates:
        report.error(rel, "pvp talent trees have no gates")
    valid_gates = {0, *gates}

    for n in nodes:
        where = f"{rel} node '{n['id']}'"
        if n.get("gate", 0) not in valid_gates:
            report.error(where, f"gate {n.get('gate')} is not 0 or one of the tree's gates {gates}")
        if t["kind"] != "pvp" and "pos" not in n:
            report.error(where, "missing pos (needed to draw the talent screen)")
        if n["type"] == "capstone" and gates and n.get("gate", 0) != max(gates):
            report.error(where, f"capstones must sit behind the last gate ({max(gates)} points)")
        for req in n.get("requires_any", []):
            if req not in by_id and req not in abilities:
                report.error(where, f"requires '{req}', which is neither a node in this tree nor an ability")
        grants = [n.get("grants_ability")] + [c.get("grants_ability") for c in n.get("choices", [])]
        for g in grants:
            if g and g not in abilities:
                report.error(where, f"grants ability '{g}', which does not exist")
        for g in [n.get("grants_aura")] + [c.get("grants_aura") for c in n.get("choices", [])]:
            if g and g not in auras:
                report.error(where, f"grants aura '{g}', which does not exist")
        effects = list(n.get("effects", []))
        for c in n.get("choices", []):
            effects += c.get("effects", [])
        for e in effects:
            target = e["modify"].split(".", 1)[0]
            if target != "self" and target not in abilities and target not in auras:
                report.error(where, f"modifies '{e['modify']}', but '{target}' is not an ability, aura or 'self'")
                continue
            problem = _talent_path_problem(e, abilities, auras, tuning)
            if problem:
                report.error(where, f"modifies '{e['modify']}': {problem}")

    if t["kind"] != "pvp":
        spots: dict[tuple, str] = {}
        for n in nodes:
            if "pos" not in n:
                continue
            spot = tuple(n["pos"])
            if spot in spots:
                report.error(rel, f"nodes '{spots[spot]}' and '{n['id']}' share position {list(spot)}")
            spots.setdefault(spot, n["id"])

    # reachability: a node is reachable when it is a root (no node requirements) or any
    # required node is reachable. Requirements that name abilities count as satisfied.
    reachable: set[str] = set()
    changed = True
    while changed:
        changed = False
        for n in nodes:
            if n["id"] in reachable:
                continue
            node_reqs = [r for r in n.get("requires_any", []) if r in by_id]
            ability_reqs = [r for r in n.get("requires_any", []) if r not in by_id]
            if not node_reqs or ability_reqs or any(r in reachable for r in node_reqs):
                reachable.add(n["id"])
                changed = True
    for nid in ids:
        if nid not in reachable:
            report.error(rel, f"node '{nid}' is unreachable")

    if t["status"] != "complete" or tuning is None:
        return
    for n in nodes:
        for item, label in [(n, f"node '{n['id']}'")] + [(c, f"node '{n['id']}' option '{c['id']}'") for c in n.get("choices", [])]:
            if not item.get("description"):
                report.error(rel, f"{label} needs a description (the talent screen's tooltip)")
            if n["type"] != "choice" or item is not n:
                if not item.get("icon", {}).get("image"):
                    report.error(rel, f"{label} needs an icon image")
    tt = tuning["talents"]
    if t["kind"] == "pvp":
        if t["points"] != tt["pvp_slots"]:
            report.error(rel, f"pvp trees have {tt['pvp_slots']} slots, found {t['points']}")
        if len(nodes) != tt["pvp_talents_per_spec"]:
            report.error(rel, f"pvp trees need {tt['pvp_talents_per_spec']} talents, found {len(nodes)}")
        return
    expected = tt["class_tree_points"] if t["kind"] == "class" else tt["spec_tree_points"]
    if t["points"] != expected:
        report.error(rel, f"{t['kind']} trees spend {expected} points, found {t['points']}")
    if t["kind"] == "spec" and gates != tt["spec_tree_gates"]:
        report.error(rel, f"spec tree gates must be {tt['spec_tree_gates']}, found {gates}")
    total_ranks = sum(n.get("ranks", 1) for n in nodes)
    if total_ranks < t["points"]:
        report.error(rel, f"only {total_ranks} ranks available for {t['points']} points")


UNIT_RADIUS = 0.45  # matches ArenaGeometry.UNIT_RADIUS in game/core/arena_geometry.gd


ROTATE_CLEARANCE_M = 1.0  # a unit (0.45 m radius) fits between a turning collider and anything else


def _rotate_problems(m: dict, t: dict) -> list[str]:
    """M2-10: a rotate twist turns circle colliders only (needs center, period_s), and along their
    whole path they keep ROTATE_CLEARANCE_M from every other collider and the bounds, so nobody
    can be pinned and nothing passes through a wall."""
    import math
    out = []
    for k in ("center", "period_s"):
        if k not in t:
            out.append(f"a rotate twist needs '{k}'")
    if out:
        return out
    turning = [c for c in m["colliders"] if c.get("tag", "") in t.get("tags", [])]
    if any(c["type"] != "circle" for c in turning):
        out.append("only circle colliders can turn")
    cx, cz = t["center"]
    others = [c for c in m["colliders"] if c.get("tag", "") not in t.get("tags", [])]
    half = float(m.get("bounds_half_m", 20.0))
    for c in (c for c in turning if c["type"] == "circle"):
        r0 = math.hypot(c["center"][0] - cx, c["center"][1] - cz)
        a0 = math.atan2(c["center"][1] - cz, c["center"][0] - cx)
        worst = (math.inf, "")
        for i in range(720):
            a = a0 + i * math.tau / 720
            px, pz = cx + r0 * math.cos(a), cz + r0 * math.sin(a)
            for o in others:
                if o["type"] == "circle":
                    d = math.hypot(px - o["center"][0], pz - o["center"][1]) - o["radius"]
                else:
                    dx = max(o["min"][0] - px, 0.0, px - o["max"][0])
                    dz = max(o["min"][1] - pz, 0.0, pz - o["max"][1])
                    d = math.hypot(dx, dz)
                d -= c["radius"]
                if d < worst[0]:
                    worst = (d, f"the {o.get('tag', o['type'])} collider")
            d = min(half - abs(px), half - abs(pz)) - c["radius"]
            if d < worst[0]:
                worst = (d, "the bounds")
        if worst[0] < ROTATE_CLEARANCE_M:
            out.append(f"the '{c.get('tag')}' circle at {c['center']} passes {max(worst[0], 0):.2f} m from {worst[1]} "
                       f"(at least {ROTATE_CLEARANCE_M} m, so nobody is pinned)")
    return out


def _spawn_blocked(m: dict, x: float, z: float) -> str:
    """Name of what a player standing at (x, z) would overlap, or '' if the spot is clear.
    Gates count: players spawn behind them while they are closed."""
    half = m["bounds_half_m"] - UNIT_RADIUS
    if abs(x) > half or abs(z) > half:
        return "the arena bounds"
    for i, c in enumerate(m["colliders"]):
        if c["type"] == "circle":
            if math.hypot(x - c["center"][0], z - c["center"][1]) < c["radius"] + UNIT_RADIUS:
                return f"collider {i} ({c.get('tag', 'circle')})"
        elif (c["min"][0] - UNIT_RADIUS < x < c["max"][0] + UNIT_RADIUS
              and c["min"][1] - UNIT_RADIUS < z < c["max"][1] + UNIT_RADIUS):
            return f"collider {i} ({c.get('tag', 'box')})"
    return ""


def _check_kit(report: Report, rel: str, spec: dict, abilities: dict, auras: dict) -> None:
    kit = [abilities[a] for a in spec["abilities"] if a in abilities]
    on_bar = [a for a in kit if a["cast_type"] != "passive" and a["kit_slot"] != "shared"]
    lo, hi = KIT_BAR_RANGE
    if not lo <= len(on_bar) <= hi:
        report.error(rel, f"kit has {len(on_bar)} abilities on the bars; template needs {lo} to {hi}")
    for slot, (smin, smax) in KIT_TEMPLATE.items():
        n = sum(1 for a in on_bar if a["kit_slot"] == slot)
        if not smin <= n <= smax:
            report.error(rel, f"kit slot '{slot}' has {n}; template needs {smin} to {smax}")
    categories = set()
    for a in on_bar:
        if a["kit_slot"] != "cc":
            continue
        for e in a["effects"]:
            if e["type"] == "apply_aura" and e["aura"] in auras:
                cat = auras[e["aura"]]["cc_category"]
                if cat != "none":
                    categories.add(cat)
            if e["type"] in ("knockback", "pull"):  # displacement: a pull counts like a knockback
                categories.add("knockback")
    if len(categories) < 2:
        report.error(rel, f"kit CC covers {len(categories)} categories; template needs at least 2")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", type=Path, default=REPO / "data")
    args = parser.parse_args()
    errors = validate(args.data)
    if errors:
        for e in errors:
            print(f"ERROR {e}")
        print(f"FAIL data validation: {len(errors)} error(s)")
        return 1
    print("PASS data validation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
