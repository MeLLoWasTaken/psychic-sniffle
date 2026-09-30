"""Checks for the sound data (backlog M1-26), called by tools/validate_data.py.

  - every ability has an entry in the sound map (sounds per stage, or "none");
  - casts and channels have a cast start and a cast loop, and only they do; loops loop;
  - every sound id the map names has a recipe in data/sounds, which the build step
    (tools/audio/synth.py --data) turns into game files; builtin recipes exist;
  - weapon types and armors in use resolve to swing, hit and footstep sounds;
  - recipe rules that can be read from the text (tools/audio/layers.py static_problems):
    impacts hold no pure tone above 200 Hz, no layer is cut off while still loud;
  - levels: only warnings may peak above -2 dBFS, and the CC warning has the highest peak.
Backlog X-04 adds:
  - processing chains (data/sound_processing, tools/audio/processing.py problems): every
    category and "processing" reference names a chain, chains start with a high-pass, loops use
    no time-varying effect, interface and warning chains are dry;
  - acoustics (data/acoustics) are named after maps, and a default exists;
  - the world bus that carries the arena reverb is not the interface or warning bus, and the
    ducking compressor listens to the warning bus.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
WEAPON_REFS = ("@weapon_swing", "@weapon_hit")
CAST_TYPES = ("cast", "channel")


def _refs(value) -> list[str]:
    if value is None:
        return []
    return list(value) if isinstance(value, list) else [value]


def check(error: Callable[[str, str], None], db: dict[str, dict], data_dir: Path) -> None:
    sys.path.insert(0, str(HERE))
    import layers
    import synth

    sounds: dict = db.get("sounds", {})
    maps: dict = db.get("sound_map", {})
    abilities, auras, specs, classes = db["abilities"], db["auras"], db["specs"], db["classes"]

    # ---- recipes -------------------------------------------------------------------
    for sid, s in sounds.items():
        rel = f"sounds/{sid}.json"
        if "builtin" in s and s["builtin"] not in synth.RECIPES:
            error(rel, f"builtin recipe '{s['builtin']}' not found in tools/audio/synth.py")
        if s["category"] == "loop" and not s.get("loops"):
            error(rel, "loop sounds must set \"loops\": true")
        if s.get("loops") and s["category"] != "loop":
            error(rel, f"only the loop category may loop, not '{s['category']}'")
        for problem in layers.static_problems(s):
            error(rel, problem)
        if s["category"] != "warning" and s["peak_dbfs"] > -2.0:
            error(rel, f"peak {s['peak_dbfs']} dBFS: only warnings may peak above -2 dBFS")
    warnings = {sid: s for sid, s in sounds.items() if s["category"] == "warning"}

    if "default" not in maps:
        error("sound_map", "missing the 'default' sound map (data/sound_map/default.json)")
        return
    for mid, m in maps.items():
        rel = f"sound_map/{mid}.json"

        def need(sound: str, where: str) -> None:
            if sound not in sounds:
                error(rel, f"{where}: sound '{sound}' has no recipe (data/sounds/{sound}.json)")

        # ---- categories and levels ---------------------------------------------------
        for cat, c in m["categories"].items():
            if c["positional"] and c.get("attenuation") not in m["attenuation"]:
                error(rel, f"categories/{cat}: positional sounds need an attenuation profile from 'attenuation'")
        for sid, s in sounds.items():
            att = s.get("playback", {}).get("attenuation")
            if att and att not in m["attenuation"]:
                error(f"sounds/{sid}.json", f"attenuation '{att}' is not in sound_map/{mid}.json")
        cc = m["cc_warning"]
        need(cc["sound"], "cc_warning/sound")
        need(cc["incoming"], "cc_warning/incoming")
        if cc["sound"] in sounds:
            top = sounds[cc["sound"]]["peak_dbfs"]
            if sounds[cc["sound"]]["category"] != "warning":
                error(rel, f"cc_warning/sound '{cc['sound']}' must be in the warning category")
            for sid, s in sounds.items():
                if sid != cc["sound"] and s["peak_dbfs"] > top:
                    error(f"sounds/{sid}.json", f"peak {s['peak_dbfs']} dBFS is above the CC warning's {top} dBFS")
        for sid in warnings:
            if sid not in (cc["sound"], cc["incoming"]):
                error(f"sounds/{sid}.json", "the warning category is reserved for the CC warnings")

        # ---- abilities ---------------------------------------------------------------
        for aid in sorted(abilities):
            if aid not in m["abilities"]:
                error(rel, f"ability '{aid}' has no sound entry (add its sounds, or \"none\")")
        for aid, entry in m["abilities"].items():
            where = f"abilities/{aid}"
            a = abilities.get(aid)
            if a is None:
                error(rel, f"{where}: no ability '{aid}'")
                continue
            if entry == "none":
                continue
            casts = a["cast_type"] in CAST_TYPES
            for stage in ("cast_start", "cast_loop"):
                if casts and stage not in entry:
                    error(rel, f"{where}: a {a['cast_type']} needs '{stage}'")
                if not casts and stage in entry:
                    error(rel, f"{where}: '{stage}' on an {a['cast_type']} ability")
            loop = entry.get("cast_loop")
            if loop:
                need(loop, f"{where}/cast_loop")
                if loop in sounds and not sounds[loop].get("loops"):
                    error(rel, f"{where}/cast_loop: sound '{loop}' does not loop")
            for stage in ("cast_start", "release", "impact"):
                for ref in _refs(entry.get(stage)):
                    if ref in WEAPON_REFS:
                        if stage == "cast_start":
                            error(rel, f"{where}/{stage}: {ref} only fits release or impact")
                        continue
                    need(ref, f"{where}/{stage}")
                    if ref in sounds and sounds[ref].get("loops"):
                        error(rel, f"{where}/{stage}: '{ref}' is a loop; one-shot stages need one-shot sounds")
        for auid, au in m["auras"].items():
            if auid not in auras:
                error(rel, f"auras/{auid}: no aura '{auid}'")
            elif "periodic" not in auras[auid]:
                error(rel, f"auras/{auid}: the aura has no periodic effect to tick")
            need(au["tick"], f"auras/{auid}/tick")

        # ---- weapons, armor, footsteps ---------------------------------------------------
        for key, wpn in m["weapons"].items():
            need(wpn["swing"], f"weapons/{key}/swing")
            for armor, hit in wpn["hit"].items():
                need(hit, f"weapons/{key}/hit/{armor}")
        armors_used = {c["armor"] for c in classes.values()}
        for armor in sorted(armors_used):
            use = armor if armor in m["footsteps"] else m["armor_fallback"].get(armor, "")
            if use not in m["footsteps"]:
                error(rel, f"footsteps: armor '{armor}' has no footsteps (add it, or an armor_fallback)")
        for armor, fs in m["footsteps"].items():
            need(fs["step"], f"footsteps/{armor}/step")
            need(fs["land"], f"footsteps/{armor}/land")
        for sid, s in specs.items():
            w = s["weapon"]
            key = f"{w['type']}_2h" if w.get("hands") == 2 and f"{w['type']}_2h" in m["weapons"] else w["type"]
            if key not in m["weapons"]:
                error(f"specs/{sid}.json", f"weapon type '{w['type']}' has no swing and hit sounds in sound_map/{mid}.json")
                continue
            hits = m["weapons"][key]["hit"]
            for armor in sorted(armors_used):
                a2 = armor if armor in hits else m["armor_fallback"].get(armor, "")
                if a2 not in hits and "default" not in hits:
                    error(rel, f"weapons/{key}: no hit for armor '{armor}' (add it or 'default')")
        for name in ("click", "target", "error"):
            need(m["interface"][name], f"interface/{name}")

        # ---- world bus, arena reverb and ducking (backlog X-04) ---------------------------
        b = m["buses"]
        world = b.get("world")
        if world is not None and world in (b["interface"], b["warning"]):
            error(rel, f"buses/world: '{world}' carries the arena reverb; interface and warning sounds must stay dry")
        duck = m.get("ducking")
        if duck is not None:
            if duck["sidechain"] != b["warning"]:
                error(rel, f"ducking/sidechain: must be the warning bus '{b['warning']}' (the world dips under the warning)")
            if duck["bus"] in (b["interface"], b["warning"]):
                error(rel, "ducking/bus: the warning must not duck itself")

    # ---- processing chains and acoustics (backlog X-04) -------------------------------
    import processing
    procs: dict = db.get("sound_processing", {})
    if "default" not in procs:
        error("sound_processing", "missing data/sound_processing/default.json (the build's processing chains)")
    else:
        for where, problem in processing.problems(procs["default"], sounds):
            error(where, problem)
    acoustics: dict = db.get("acoustics", {})
    if "default" not in acoustics:
        error("acoustics", "missing data/acoustics/default.json (the reverb for maps without their own)")
    for aid in acoustics:
        if aid != "default" and aid not in db.get("maps", {}):
            error(f"acoustics/{aid}.json", f"no map '{aid}' (acoustics files are named after maps, or 'default')")
