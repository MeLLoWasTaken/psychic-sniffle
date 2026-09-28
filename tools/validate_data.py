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

Usage:
  python3 tools/validate_data.py [--data DIR]
Exit code 0 when valid, 1 when any error is found.
"""
from __future__ import annotations

import argparse
import json
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
    # (checked per tree below)

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

    # ---- talent trees --------------------------------------------------------
    for tid, t in trees.items():
        _check_tree(report, f"talents/{tid}.json", t, abilities, auras, tuning)

    # ---- maps ------------------------------------------------------------------
    for mid, m in db["maps"].items():
        rel = f"maps/{mid}.json"
        need = max(BRACKET_SIZE[b] for b in m["brackets"])
        for team in ("team_a", "team_b"):
            if len(m["spawns"][team]) < need:
                report.error(rel, f"{team} has {len(m['spawns'][team])} spawns; bracket needs {need}")

    # ---- assets ------------------------------------------------------------------
    for asid, a in db["assets"].items():
        rel = f"assets/{asid}.json"
        if a["tri_budget"]["min"] > a["tri_budget"]["max"]:
            report.error(rel, "tri_budget.min is larger than tri_budget.max")
        if not (data_dir.parent / "tools" / "blender" / a["builder"]).exists():
            report.error(rel, f"builder script tools/blender/{a['builder']} not found")
        if a["kind"] == "character" and a.get("spec") not in specs:
            report.error(rel, f"character asset needs a valid spec, got '{a.get('spec')}'")

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


def _check_tree_ref(report: Report, rel: str, trees: dict, tree_id: str, kind: str, owner: str) -> None:
    t = trees.get(tree_id)
    if t is None:
        report.error(rel, f"{kind} talent tree '{tree_id}' not found")
    elif t["kind"] != kind:
        report.error(rel, f"talent tree '{tree_id}' is kind '{t['kind']}', expected '{kind}'")
    elif t["owner"] != owner:
        report.error(rel, f"talent tree '{tree_id}' is owned by '{t['owner']}'")


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
        effects = list(n.get("effects", []))
        for c in n.get("choices", []):
            effects += c.get("effects", [])
        for e in effects:
            target = e["modify"].split(".", 1)[0]
            if target != "self" and target not in abilities and target not in auras:
                report.error(where, f"modifies '{e['modify']}', but '{target}' is not an ability, aura or 'self'")

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
            if e["type"] == "knockback":
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
