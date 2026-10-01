#!/usr/bin/env python3
"""Ability and talent codex: one HTML page generated from the game data.

    python3 tools/codex/build_codex.py [--out previews/codex/codex.html]

For every class and spec: role, armor, resource, health and stats; every ability in the kit (and
the shared ones) with its icon composed as the HUD draws it (school gradient, engraved glyph,
iron frame), cast type, cooldown, cost, range, and what it does, with numbers computed by the
combat formula (base x (1 + power bonus x coefficient) x PvP modifier, before crits, armor and
damage-taken modifiers); the auras it applies; and the class, spec and PvP talent trees.

A description whose numbers do not appear among the computed ones is flagged: the text is
hand-written in data and can fall behind balance changes.
"""
from __future__ import annotations

import argparse
import base64
import html
import io
import json
import re
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[2]
DATA = REPO / "data"
ICONS = REPO / "game" / "assets" / "icons"
SLOTS = [("core", "Core"), ("burst", "Burst"), ("cc", "Crowd control"), ("interrupt", "Interrupt"),
         ("defensive", "Defensive"), ("mobility", "Mobility"), ("utility", "Utility")]
PHYSICAL_ICON = (0x8a, 0x74, 0x58)  # worn bronze (DECISIONS: placeholder icons, physical)
STAT_WORDS = {"move_speed": "movement speed", "damage_taken": "damage taken", "damage_done": "damage done",
              "healing_done": "healing done", "cast_speed": "cast speed", "haste": "haste",
              "crit_chance": "critical strike chance", "armor": "armor", "healing_taken": "healing taken"}


def load(folder: str) -> dict:
    return {json.loads(p.read_text())["id" if folder != "talents" else "tree_id"]: json.loads(p.read_text())
            for p in sorted((DATA / folder).glob("*.json"))}


def fmt(n: float) -> str:
    return f"{int(round(n)):,}"


def secs(s: float) -> str:
    if s < 60:
        return f"{s:g} s"
    m, rest = int(s // 60), round(s - (s // 60) * 60, 1)
    return f"{m} min" if rest == 0 else f"{m} min {rest:g} s"


def rgb(c: list[float]) -> tuple[int, int, int]:
    return tuple(int(round(max(0.0, min(1.0, v)) * 255)) for v in c)


class Codex:
    def __init__(self) -> None:
        self.tuning = json.loads((DATA / "tuning.json").read_text())
        self.classes, self.specs = load("classes"), load("specs")
        self.abilities, self.auras, self.talents = load("abilities"), load("auras"), load("talents")
        self.palette = json.loads((DATA / "effect_palettes" / "default.json").read_text())["schools"]
        self.frame = Image.open(ICONS / "frame.png").convert("RGBA")
        self._icons: dict[str, str] = {}
        self.stale: list[str] = []

    # ------------------------------------------------------------------ icons
    def icon(self, spec_icon: dict | None, size: int = 56) -> str:
        if not spec_icon:
            return ""
        key = f"{spec_icon.get('image')}|{spec_icon.get('school')}|{size}"
        if key in self._icons:
            return self._icons[key]
        school = spec_icon.get("school", "physical")
        if school == "physical":
            top = PHYSICAL_ICON
            bottom = tuple(int(v * 0.45) for v in PHYSICAL_ICON)
        else:
            pal = self.palette.get(school, self.palette["physical"])
            top = rgb(pal["primary"])
            bottom = tuple(int(v * 0.3) for v in rgb(pal["secondary"] if school == "shadow" else pal["primary"]))
        bg = Image.new("RGBA", (128, 128))
        px = bg.load()
        for y in range(128):
            u = y / 127
            col = tuple(int(top[i] * (1 - u) * 0.85 + bottom[i] * u) for i in range(3)) + (255,)
            for x in range(128):
                px[x, y] = col
        glyph_path = ICONS / "glyphs" / f"{spec_icon.get('image', '')}.png"
        if glyph_path.exists():
            bg.alpha_composite(Image.open(glyph_path).convert("RGBA").resize((128, 128)))
        bg.alpha_composite(self.frame.resize((128, 128)))
        buf = io.BytesIO()
        bg.resize((size, size), Image.LANCZOS).save(buf, "PNG", optimize=True)
        uri = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()
        self._icons[key] = uri
        return uri

    # ------------------------------------------------------------------ numbers
    def unit_stats(self, spec: dict) -> dict:
        c, st = self.tuning["combat"], spec.get("stats", {})
        return {k: float(st.get(k, c[k])) for k in ("power_bonus", "haste", "crit_chance")}

    def amount(self, base: float, eff: dict, stats: dict, ab: dict) -> float:
        coef = float(eff.get("power_coefficient", 1.0))
        return base * (1 + stats["power_bonus"] * coef) * float(ab.get("pvp_modifier", 1.0))

    def aura_text(self, aura_id: str, stats: dict, ab: dict, numbers: list[float]) -> str:
        a = self.auras.get(aura_id)
        if not a:
            return html.escape(aura_id)
        bits = []
        for m in a.get("modifiers", []):
            word = STAT_WORDS.get(m["stat"], m["stat"].replace("_", " "))
            if m["op"] == "multiply":
                pct = round((float(m["value"]) - 1) * 100)
                bits.append(f"{word} {'+' if pct > 0 else '−'}{abs(pct)}%")
            else:
                bits.append(f"{word} {float(m['value']):+g}")
        if a.get("absorb"):
            v = self.amount(float(a["absorb"]), {}, stats, ab)
            numbers.append(v)
            bits.append(f"absorbs {fmt(v)} damage")
        if a.get("periodic"):
            p = a["periodic"]
            v = self.amount(float(p["effect"]["base"]), p["effect"], stats, ab)
            numbers.append(v)
            ticks = int(float(a["duration_s"]) // float(p["interval_s"]))
            numbers.append(v * ticks)
            bits.append(f"{fmt(v)} {p['effect']['type']} every {secs(float(p['interval_s']))} ({fmt(v * ticks)} total)")
        cc = a.get("cc_category", "none")
        if cc != "none":
            bits.append(cc.replace("_", " "))
        if a.get("breaks_on_damage", "never") != "never":
            bits.append("breaks on damage")
        if a.get("immune"):
            bits.append("immune to " + ", ".join(a["immune"]) if isinstance(a["immune"], list) else "immunity")
        if a.get("pacify"):
            bits.append("cannot attack")
        dispel = a.get("dispel_type", "none")
        tail = f"{secs(float(a['duration_s']))}" + (f", {dispel} dispel" if dispel != "none" else ", cannot be dispelled")
        icon = self.icon(a.get("icon"), 22)
        img = f'<img class="mini" src="{icon}" alt="">' if icon else ""
        what = "; ".join(bits) if bits else html.escape(a.get("description", ""))
        return (f'<span class="aura {html.escape(a["kind"])}">{img}<b>{html.escape(a["name"])}</b>'
                f' <span class="dim">({tail})</span> {what}</span>')

    def effects(self, ab: dict, stats: dict) -> tuple[list[str], list[float]]:
        out, numbers = [], []
        ticks = int(ab.get("channel_ticks", 1))
        for e in ab["effects"]:
            t = e["type"]
            area = ""
            if e.get("affects", "").endswith("in_radius"):
                who = "enemies" if e["affects"].startswith("enemies") else "allies"
                area = f" to all {who} within {e['radius_m']:g} m"
            if t in ("damage", "heal"):
                v = self.amount(float(e["base"]), e, stats, ab)
                numbers += [v, v * ticks]
                school = e.get("school", ab["school"])
                per = f" per tick, {ticks} ticks ({fmt(v * ticks)} total)" if ticks > 1 else ""
                word = "damage" if t == "damage" else "healing"
                line = f'<b class="num">{fmt(v)}</b> {school} {word}{per}{area}'
                if e.get("multiplier_if"):
                    mi = e["multiplier_if"]
                    numbers.append(v * float(mi["value"]))
                    line += (f'; <b class="num">{fmt(v * float(mi["value"]))}</b> against a target that is '
                             f'{" or ".join(mi.get("target_cc", []))}')
                out.append(line)
            elif t == "apply_aura":
                out.append("Applies " + self.aura_text(e["aura"], stats, ab, numbers))
            elif t == "dispel":
                kinds = [k for k in e.get("dispel_types", []) if k != "none"]
                out.append(f"Removes {e.get('dispel_count', 1)} {' or '.join(kinds)} effect")
            elif t == "interrupt":
                out.append(f"Interrupts the cast and locks that school for {secs(float(e['school_lock_s']))}")
            elif t == "remove_cc":
                out.append("Breaks crowd control on yourself")
            elif t == "teleport":
                out.append(f"Teleports {e['distance_m']:g} m forward")
            elif t == "charge":
                out.append("Charges to the target")
            else:
                out.append(html.escape(json.dumps(e)))
        return out, numbers

    def check_text(self, ab: dict, numbers: list[float]) -> bool:
        said = [float(m.replace(",", "")) for m in re.findall(r"\d[\d,]{2,}", ab.get("description", ""))]
        said = [s for s in said if s >= 100]
        if not said:
            return True
        ok = all(any(abs(s - n) <= max(1.0, 0.01 * n) for n in numbers) for s in said)
        if not ok:
            self.stale.append(ab["id"])
        return ok

    # ------------------------------------------------------------------ html
    def ability_card(self, ab: dict, spec: dict) -> str:
        stats = self.unit_stats(spec)
        lines, numbers = self.effects(ab, stats)
        ok = self.check_text(ab, numbers)
        cast = {"instant": "Instant", "cast": f"{ab.get('cast_time_s', 0):g} s cast",
                "channel": f"{ab.get('cast_time_s', 0):g} s channel"}.get(ab["cast_type"], ab["cast_type"])
        meta = [cast, f"{secs(float(ab['cooldown_s']))} cooldown" if ab["cooldown_s"] else "No cooldown"]
        if ab.get("cost"):
            meta.append(f"{fmt(ab['cost']['amount'])} {ab['cost']['resource']}")
        if ab.get("generates"):
            g = ab["generates"]
            meta.append(f"generates {fmt(g['amount'])} {g['resource']}" if isinstance(g, dict) else "generates resource")
        tgt = ab.get("target", "enemy")
        if tgt == "self":
            meta.append("Self")
        else:
            rng = float(ab.get("range_m", 0))
            meta.append(("Melee" if rng <= 5 else f"{rng:g} m") + ("" if tgt == "enemy" else f" · {tgt}"))
        tags = []
        if not ab.get("triggers_gcd", True):
            tags.append("off the global cooldown")
        if ab.get("usable_while_cc"):
            tags.append("usable while controlled")
        if ab.get("castable_while_moving"):
            tags.append("castable while moving")
        search = " ".join([ab["name"], ab["school"], ab["kit_slot"], ab.get("description", "")]).lower()
        icon = self.icon(ab.get("icon"))
        stale = '' if ok else '<p class="stale">The tooltip text above is out of date: its numbers differ from the data.</p>'
        return f'''<article class="ability" data-search="{html.escape(search)}">
  <img class="icon" src="{icon}" alt="" width="56" height="56">
  <div class="body">
    <header><h4>{html.escape(ab["name"])}</h4><span class="school s-{ab["school"]}">{ab["school"]}</span></header>
    <p class="meta">{" · ".join(html.escape(m) for m in meta)}</p>
    <p class="desc">{html.escape(ab.get("description", ""))}</p>{stale}
    <ul class="fx">{"".join(f"<li>{x}</li>" for x in lines)}</ul>
    {f'<p class="tags">{" · ".join(tags)}</p>' if tags else ""}
  </div>
</article>'''

    def tree(self, tree_id: str | None, label: str) -> str:
        t = self.talents.get(tree_id or "")
        if not t:
            return ""
        nodes = []
        for n in sorted(t["nodes"], key=lambda n: (n.get("pos", [0, 0])[1], n.get("pos", [0, 0])[0])):
            def effect_text(src: dict) -> str:
                parts = [f"{e['modify']} {e['per_rank']:+g} per rank" if "per_rank" in e
                         else f"{e['modify']} set to {json.dumps(e.get('set'))}" for e in src.get("effects", [])]
                if src.get("grants_ability"):
                    parts.insert(0, f"grants {self.abilities.get(src['grants_ability'], {}).get('name', src['grants_ability'])}")
                if src.get("grants_aura"):
                    parts.insert(0, f"passive {self.auras.get(src['grants_aura'], {}).get('name', src['grants_aura'])}")
                return "; ".join(parts)
            fx = effect_text(n)
            if n.get("choices"):
                fx = " or ".join(f"{c['name']} ({effect_text(c)})" for c in n["choices"])
            req = f' <span class="dim">requires {", ".join(n["requires_any"])}</span>' if n.get("requires_any") else ""
            nodes.append(f'<li><b>{html.escape(n["name"])}</b> <span class="dim">{n.get("type", "")}, '
                         f'{n.get("ranks", 1)} rank{"s" if n.get("ranks", 1) > 1 else ""}, row {n.get("pos", [0, 0])[1] + 1}</span>{req}'
                         f'<br>{html.escape(n.get("description", ""))} <span class="dim">{html.escape(fx)}</span></li>')
        status = t.get("status", "")
        note = ('<p class="draft">Draft: this tree is a placeholder. Talent trees and the talent screen are '
                'planned for M2.</p>') if status == "draft" else ""
        gates = f' · rows unlock at {", ".join(str(g) for g in t["gates"])} points' if t.get("gates") else ""
        return (f'<section class="tree"><h4>{label} <span class="dim">{t.get("points", "")} points{gates}</span></h4>'
                f'{note}<ol>{"".join(nodes)}</ol></section>')

    def spec_section(self, spec: dict) -> str:
        cls = self.classes[spec["class"]]
        stats = self.unit_stats(spec)
        health = spec.get("health_override", self.tuning["health"][spec["role"]])
        own = [self.abilities[a] for a in spec["abilities"] if a in self.abilities]
        groups = []
        for slot, title in SLOTS:
            cards = [self.ability_card(a, spec) for a in own if a.get("kit_slot") == slot]
            if cards:
                groups.append(f'<h3>{title}</h3><div class="grid">{"".join(cards)}</div>')
        shared = [self.ability_card(self.abilities[a], spec) for a in cls.get("shared_abilities", []) if a in self.abilities]
        if shared:
            groups.append(f'<h3>Every class</h3><div class="grid">{"".join(shared)}</div>')
        facts = [("Role", spec["role"].upper()), ("Range", spec.get("range", "")), ("Armor", cls["armor"]),
                 ("Resource", spec["primary_resource"]), ("Health", fmt(health)),
                 ("Critical strike", f"{stats['crit_chance'] * 100:g}%"), ("Haste", f"{stats['haste'] * 100:g}%"),
                 ("Weapon", spec.get("weapon", {}).get("type", ""))]
        anchor = spec["id"]
        return f'''<section class="spec" id="{anchor}" style="--class:{cls.get("color", "#999")}">
  <header class="spec-head">
    <p class="eyebrow">{html.escape(cls["name"])}</p>
    <h2>{html.escape(spec["name"])}</h2>
    <p class="lede">{html.escape(spec.get("description", ""))} {html.escape(cls.get("description", ""))}</p>
    <dl class="facts">{"".join(f"<div><dt>{k}</dt><dd>{html.escape(str(v))}</dd></div>" for k, v in facts)}</dl>
  </header>
  {"".join(groups)}
  <h3>Talents</h3>
  <div class="trees">{self.tree(cls.get("class_tree"), cls["name"] + " class tree")}{self.tree(spec.get("spec_tree"), spec["name"] + " spec tree")}{self.tree(spec.get("pvp_talents"), "PvP talents")}</div>
</section>'''

    def page(self) -> str:
        specs = [self.specs[s] for c in self.classes.values() for s in c["specs"] if s in self.specs]
        sections = "".join(self.spec_section(s) for s in specs)
        nav = "".join(f'<a href="#{s["id"]}" style="--class:{self.classes[s["class"]].get("color", "#999")}">'
                      f'<span>{html.escape(s["name"])}</span> {html.escape(self.classes[s["class"]]["name"])}</a>' for s in specs)
        count = sum(len(s["abilities"]) for s in specs)
        stale = (f'<p class="note">{len(self.stale)} ability descriptions have numbers that differ from the data '
                 f'(marked on each card). The figures in bold are computed from the data and are what the game uses.</p>'
                 if self.stale else "")
        css = (Path(__file__).parent / "codex.css").read_text()
        js = (Path(__file__).parent / "codex.js").read_text()
        pb = self.tuning["combat"]["power_bonus"]
        return f'''<title>Arena PvP Codex</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Cinzel:wght@600;700&family=Fira+Sans:wght@400;500;600&display=swap">
<style>{css}</style>
<div class="wrap">
  <header class="top">
    <p class="eyebrow">Vertical slice · {len(specs)} specs · {count} abilities</p>
    <h1>Arena PvP Codex</h1>
    <p class="lede">Every ability and talent tree in the game, generated from its data files. Bold numbers come from the combat formula: base × (1 + power bonus × coefficient), with the power bonus at {pb:g} unless a spec sets its own. Critical strikes multiply by {self.tuning["damage"]["crit_multiplier"]:g}; physical damage is then reduced by the target's armor (cloth {self.tuning["damage"]["armor_reduction"]["cloth"] * 100:g}%, plate {self.tuning["damage"]["armor_reduction"]["plate"] * 100:g}%).</p>
    {stale}
    <nav class="specnav">{nav}</nav>
    <label class="search" for="q">Find an ability <input id="q" type="search" placeholder="Name, school or effect"></label>
  </header>
  {sections}
  <footer class="foot">Generated by tools/codex/build_codex.py from data/. Icons: game-icons.net (CC BY 3.0).</footer>
</div>
<script>{js}</script>'''


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=REPO / "previews" / "codex" / "codex.html")
    args = ap.parse_args()
    cx = Codex()
    page = cx.page()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(page)
    print(f"{args.out} ({len(page) // 1024} KB); stale descriptions: {', '.join(cx.stale) or 'none'}")


if __name__ == "__main__":
    main()
