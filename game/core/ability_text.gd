class_name AbilityText
extends RefCounted
## Tooltip text for abilities and auras, computed from the data (backlog M2-06), the in-game twin
## of tools/codex/build_codex.py: cast type, cooldown, cost, range, and what the ability does
## with numbers by the combat formula (base x (1 + power bonus x coefficient) x PvP modifier,
## before crits, armor and damage-taken modifiers). Pass the player's talented copies (Unit
## talent_abilities / talent_auras, or Talents.resolve) to show that build's numbers.
##
## Every number shown comes from data. The hand-written description is shown too; numbers() lets
## a test check that a description's numbers are among the computed ones, as the codex does.

const STAT_WORDS: Dictionary = {"move_speed": "movement speed", "damage_taken": "damage taken", "damage_done": "damage done",
	"healing_done": "healing done", "cast_speed": "cast speed", "haste": "haste", "crit_chance": "critical strike chance",
	"armor": "armor", "healing_taken": "healing taken", "cooldown_rate": "cooldown recovery"}

var auras: Dictionary  ## aura id -> data (talented copies merged over Data.auras)
var stats: Dictionary  ## power_bonus, haste, crit_chance


func _init(p_stats: Dictionary, talent_auras: Dictionary = {}) -> void:
	stats = p_stats
	auras = Data.auras.duplicate()
	auras.merge(talent_auras, true)


## A spec's stat template (Combat.init_unit's rule), for tooltips outside a match.
static func spec_stats(spec_id: String) -> Dictionary:
	var c: Dictionary = Data.tuning["combat"]
	var st: Dictionary = Data.specs.get(spec_id, {}).get("stats", {})
	return {"power_bonus": float(st.get("power_bonus", c["power_bonus"])), "haste": float(st.get("haste", c["haste"])),
		"crit_chance": float(st.get("crit_chance", c["crit_chance"]))}


static func fmt(n: float) -> String:
	var s: String = str(absi(roundi(n)))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if roundi(n) < 0 else "") + s + out


static func secs(s: float) -> String:
	if s < 60.0:
		return "%s s" % _g(s)
	var m: int = floori(s / 60.0)
	var rest: float = snappedf(s - m * 60.0, 0.1)
	return ("%d min" % m) if rest == 0.0 else ("%d min %s s" % [m, _g(rest)])


static func _g(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else str(snappedf(v, 0.01))


func amount(base: float, eff: Dictionary, ab: Dictionary) -> float:
	var coef: float = float(eff.get("power_coefficient", 1.0))
	return base * (1.0 + float(stats["power_bonus"]) * coef) * float(ab.get("pvp_modifier", 1.0))


## Short facts: cast type, cooldown, cost, generated resource, range and target.
func meta(ab: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	match str(ab["cast_type"]):
		"instant":
			out.append("Instant")
		"cast":
			out.append("%s cast" % secs(float(ab.get("cast_time_s", 0.0))))
		"channel":
			out.append("%s channel" % secs(float(ab.get("cast_time_s", 0.0))))
		_:
			out.append(str(ab["cast_type"]).capitalize())
	out.append(("%s cooldown" % secs(float(ab["cooldown_s"]))) if float(ab["cooldown_s"]) > 0.0 else "No cooldown")
	if ab.has("cost"):
		out.append("%s %s" % [fmt(float(ab["cost"]["amount"])), ab["cost"]["resource"]])
	if ab.get("generates") is Dictionary:
		out.append("generates %s %s" % [fmt(float(ab["generates"]["amount"])), ab["generates"]["resource"]])
	var tgt: String = str(ab.get("target", "enemy"))
	if tgt == "self":
		out.append("Self")
	else:
		var rng: float = float(ab.get("range_m", 0.0))
		out.append(("Melee" if rng <= 5.0 else "%s m" % _g(rng)) + ("" if tgt == "enemy" else " · " + tgt))
	return out


## Notes such as "off the global cooldown".
func tags(ab: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	if not ab.get("triggers_gcd", true):
		out.append("off the global cooldown")
	if not ab.get("usable_while_cc", []).is_empty():
		out.append("usable while controlled")
	if ab.get("castable_while_moving", false):
		out.append("castable while moving")
	return out


## What the ability does, one line per effect, and every number shown (for description checks).
func effects(ab: Dictionary) -> Dictionary:
	var lines: PackedStringArray = []
	var numbers: Array[float] = []
	var ticks: int = int(ab.get("channel_ticks", 1))
	for e: Dictionary in ab.get("effects", []):
		var t: String = str(e["type"])
		var area: String = ""
		if str(e.get("affects", "")).ends_with("in_radius"):
			area = " to all %s within %s m" % ["enemies" if str(e["affects"]).begins_with("enemies") else "allies", _g(float(e["radius_m"]))]
		match t:
			"damage", "heal":
				var v: float = amount(float(e["base"]), e, ab)
				numbers.append_array([v, v * ticks])
				var per: String = (" per tick, %d ticks (%s total)" % [ticks, fmt(v * ticks)]) if ticks > 1 else ""
				var line: String = "%s %s %s%s%s" % [fmt(v), e.get("school", ab["school"]), "damage" if t == "damage" else "healing", per, area]
				if e.has("multiplier_if"):
					var mi: Dictionary = e["multiplier_if"]
					numbers.append(v * float(mi["value"]))
					line += "; %s against a target that is %s" % [fmt(v * float(mi["value"])), " or ".join(PackedStringArray(mi.get("target_cc", [])))]
				if e.has("leech_pct"):
					numbers.append(float(e["leech_pct"]))
					line += "; heals you for %s%% of the damage dealt" % _g(float(e["leech_pct"]))
				lines.append(line)
			"apply_aura":
				lines.append("Applies " + aura_line(str(e["aura"]), ab, numbers))
			"dispel":
				var kinds: PackedStringArray = PackedStringArray(e.get("dispel_types", [])).duplicate()
				kinds.erase("none")
				lines.append("Removes %d %s effect" % [int(e.get("dispel_count", 1)), " or ".join(kinds)])
			"interrupt":
				lines.append("Interrupts the cast and locks that school for %s" % secs(float(e["school_lock_s"])))
			"remove_cc":
				lines.append("Breaks crowd control on yourself")
			"teleport":
				lines.append("Teleports %s m forward" % _g(float(e["distance_m"])))
			"charge":
				lines.append("Charges to the target")
			"knockback":
				lines.append("Knocks back %s m" % _g(float(e.get("distance_m", 8.0))) + area)
			"pull":
				lines.append("Pulls the target to you")
			_:
				lines.append(t.replace("_", " ").capitalize())
	return {"lines": lines, "numbers": numbers}


## One aura described: name, duration and dispel, then what it does.
func aura_line(aura_id: String, ab: Dictionary = {}, numbers: Array[float] = []) -> String:
	var a: Dictionary = auras.get(aura_id, {})
	if a.is_empty():
		return aura_id
	var bits: PackedStringArray = aura_bits(a, ab, numbers)
	var dispel: String = str(a.get("dispel_type", "none"))
	var dur: float = float(a.get("duration_s", 0.0))
	var tail: String = (secs(dur) if dur > 0.0 else "until removed") + (", %s dispel" % dispel if dispel != "none" else ", cannot be dispelled")
	return "%s (%s): %s" % [a["name"], tail, "; ".join(bits) if not bits.is_empty() else str(a.get("description", ""))]


func aura_bits(a: Dictionary, ab: Dictionary = {}, numbers: Array[float] = []) -> PackedStringArray:
	var bits: PackedStringArray = []
	for m: Dictionary in a.get("modifiers", []):
		var word: String = STAT_WORDS.get(m["stat"], str(m["stat"]).replace("_", " "))
		if m["op"] == "multiply":
			var pct: int = roundi((float(m["value"]) - 1.0) * 100.0)
			if pct != 0:
				bits.append("%s %s%d%%" % [word, "+" if pct > 0 else "-", absi(pct)])
		elif float(m["value"]) != 0.0:
			var v: float = float(m["value"])
			bits.append(("%s %s%d%%" % [word, "+" if v > 0 else "-", absi(roundi(v * 100.0))]) if absf(v) < 1.0 else "%s %+d" % [word, roundi(v)])
	if a.has("absorb"):
		var v: float = amount(float(a["absorb"]), {}, ab)
		numbers.append(v)
		bits.append("absorbs %s damage" % fmt(v))
	if a.has("periodic"):
		var p: Dictionary = a["periodic"]
		var v: float = amount(float(p["effect"]["base"]), p["effect"], ab)
		var n: int = int(float(a["duration_s"]) / float(p["interval_s"])) if float(a["duration_s"]) > 0.0 else 0
		numbers.append_array([v, v * n])
		bits.append("%s %s every %s" % [fmt(v), p["effect"]["type"], secs(float(p["interval_s"]))] + (" (%s total)" % fmt(v * n) if n > 0 else ""))
	var cc: String = str(a.get("cc_category", "none"))
	if cc != "none":
		bits.append(cc.replace("_", " "))
	if str(a.get("breaks_on_damage", "never")) != "never":
		bits.append("breaks on damage")
	if a.get("immune") is Array and not a["immune"].is_empty():
		bits.append("immune to " + ", ".join(PackedStringArray(a["immune"])))
	if a.get("pacify", false):
		bits.append("cannot attack")
	return bits


## The description with this build's numbers: each number in the hand-written text that is one of
## the untalented computed numbers is replaced by the talented number in the same place
## (`untalented` is the same ability before talents, read with `base_text`).
func description_for(ab: Dictionary, untalented: Dictionary, base_text: AbilityText) -> String:
	var desc: String = str(ab.get("description", ""))
	if untalented.is_empty() or untalented == ab and base_text.auras == auras:
		return desc
	var before: Array[float] = base_text.effects(untalented)["numbers"]
	var after: Array[float] = effects(ab)["numbers"]
	var re: RegEx = RegEx.create_from_string("\\d[\\d,]{2,}")
	var out: String = ""
	var last: int = 0
	for m: RegExMatch in re.search_all(desc):
		var said: float = float(m.get_string().replace(",", ""))
		var k: int = -1
		for i: int in mini(before.size(), after.size()):
			if absf(said - before[i]) <= maxf(1.0, 0.01 * before[i]):
				k = i
				break
		out += desc.substr(last, m.get_start() - last) + (fmt(after[k]) if k >= 0 else m.get_string())
		last = m.get_end()
	return out + desc.substr(last)


## True when every number of 100 or more in the description is among the computed ones (within
## 1%), the codex's stale-text rule.
func description_matches(ab: Dictionary) -> bool:
	var computed: Array[float] = effects(ab)["numbers"]
	var re: RegEx = RegEx.create_from_string("\\d[\\d,]{2,}")
	for m: RegExMatch in re.search_all(str(ab.get("description", ""))):
		var said: float = float(m.get_string().replace(",", ""))
		if said < 100.0:
			continue
		if not computed.any(func(n: float) -> bool: return absf(said - n) <= maxf(1.0, 0.01 * n)):
			return false
	return true
