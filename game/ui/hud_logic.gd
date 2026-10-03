class_name HudLogic
extends RefCounted
## What the HUD shows, computed from the world view and data with no drawing (backlog M1-27), so
## tests can check it directly: which ability sits on which action button, a button's cooldown,
## GCD and usability state, the order and size of auras on a unit frame, and the crowd control
## that drives the loss-of-control alert and the big CC icon on portraits.

const AURA_GROUP: Dictionary = {"cc": 0, "major_defensive": 1, "major_offensive": 2, "normal": 3}
const AURA_SIZE: Dictionary = {"cc": 1.5, "major_defensive": 1.2, "major_offensive": 1.2, "normal": 1.0}
const NO_CC: Array[String] = ["none", "knockback"]


# ------------------------------------------------------------------ action bars

## Abilities per action bar for a spec: bar element id -> ability ids by slot ("" = empty).
## The layout's assignments for the spec win; otherwise the spec's abilities fill the bars in
## fill_order, then abilities the player's talents grant (`extra`), and class-shared abilities
## (Break Free) take the last slots of the last bar. Passive and excluded abilities are left out.
static func bar_assignment(layout: Dictionary, spec_id: String, extra: Array = []) -> Dictionary:
	var bars_cfg: Dictionary = layout.get("action_bars", {})
	var order: Array = bars_cfg.get("fill_order", [])
	var elements: Dictionary = layout.get("elements", {})
	var out: Dictionary = {}
	var sizes: Array[int] = []
	for bid: String in order:
		var n: int = int(elements.get(bid, {}).get("buttons", 12))
		sizes.append(n)
		var slots: Array[String] = []
		slots.resize(n)
		slots.fill("")
		out[bid] = slots
	var fixed: Dictionary = bars_cfg.get("assignments", {}).get(spec_id, {})
	if not fixed.is_empty():
		for bid: String in fixed:
			if out.has(bid):
				var arr: Array = fixed[bid]
				for i: int in mini(arr.size(), (out[bid] as Array).size()):
					out[bid][i] = str(arr[i])
		return out
	var spec: Dictionary = Data.specs.get(spec_id, {})
	var cls: Dictionary = Data.classes.get(str(spec.get("class", "")), {})
	var exclude: Array = bars_cfg.get("exclude", [])
	var kit: Array[String] = []
	var shared: Array[String] = []
	for a: String in spec.get("abilities", []):
		if _placeable(a, exclude):
			kit.append(a)
	for a: String in extra:
		if _placeable(a, exclude) and not a in kit:
			kit.append(a)
	for a: String in cls.get("shared_abilities", []):
		if _placeable(a, exclude) and not a in kit:
			shared.append(a)
	if not bool(bars_cfg.get("shared_at_end", true)):
		kit.append_array(shared)
		shared.clear()
	var flat: Array[String] = []
	var total: int = 0
	for n: int in sizes:
		total += n
	flat.resize(total)
	flat.fill("")
	for i: int in mini(kit.size(), total):
		flat[i] = kit[i]
	for j: int in shared.size():
		var at: int = total - shared.size() + j
		if at >= 0 and flat[at] == "":
			flat[at] = shared[j]
	var k: int = 0
	for bi: int in order.size():
		for s: int in sizes[bi]:
			out[order[bi]][s] = flat[k]
			k += 1
	return out


static func _placeable(ability_id: String, exclude: Array) -> bool:
	var ab: Dictionary = Data.abilities.get(ability_id, {})
	return not ab.is_empty() and not ability_id in exclude and str(ab.get("cast_type", "")) != "passive"


## The state of one action button for the local player, from the view:
## {ability, cd_left_s, cd_frac (elapsed 0..1), gcd_frac, gcd_left_s, on_gcd, range (true when in
## range or no range check), resource_ok, usable, blocked_by, highlight}.
## `cd_starts` remembers when each cooldown (and "gcd") began: {key: [start_tick, ready_tick]};
## pass the same dictionary every tick (update_cooldown_starts fills it).
static func slot_state(ability_id: String, view: Dictionary, target: Dictionary, cd_starts: Dictionary) -> Dictionary:
	var st: Dictionary = {"ability": ability_id, "cd_left_s": 0.0, "cd_frac": 1.0, "gcd_frac": 1.0, "gcd_left_s": 0.0,
		"on_gcd": false, "range": true, "resource_ok": true, "usable": true, "blocked_by": "", "highlight": false}
	var ab: Dictionary = Data.abilities.get(ability_id, {})
	if ab.is_empty() or view.is_empty():
		st["usable"] = false
		return st
	var tick: int = int(view["tick"])
	var rate: float = float(view.get("tick_rate", 60))
	var me: Dictionary = view["me"]
	var ready: int = int(view.get("cooldowns", {}).get(ability_id, 0))
	if ready > tick:
		var span: Array = cd_starts.get(ability_id, [])
		var start: int = int(span[0]) if span.size() == 2 and int(span[1]) == ready else ready - roundi(float(ab.get("cooldown_s", 0.0)) * rate)
		st["cd_left_s"] = (ready - tick) / rate
		st["cd_frac"] = clampf(float(tick - start) / maxf(1.0, ready - start), 0.0, 1.0)
	var gcd_ready: int = int(view.get("gcd_ready_tick", 0))
	if bool(ab.get("triggers_gcd", false)) and gcd_ready > tick and gcd_ready >= ready:
		var g: Array = cd_starts.get("gcd", [])
		var gstart: int = int(g[0]) if g.size() == 2 and int(g[1]) == gcd_ready else gcd_ready - roundi(1.5 * rate)
		st["on_gcd"] = true
		st["gcd_left_s"] = (gcd_ready - tick) / rate
		st["gcd_frac"] = clampf(float(tick - gstart) / maxf(1.0, gcd_ready - gstart), 0.0, 1.0)
	# resource
	var cost: Dictionary = ab.get("cost", {})
	if not cost.is_empty() and view.get("resources", {}).has(str(cost["resource"])):  # every own resource (M3-08)
		st["resource_ok"] = float(view["resources"][str(cost["resource"])]) >= float(cost["amount"])
	elif not cost.is_empty() and str(me.get("resource_kind", _primary_resource(str(me.get("spec", ""))))) == str(cost["resource"]):
		st["resource_ok"] = float(me.get("resource", 0.0)) >= float(cost["amount"])
	# usability: dead, crowd control, school lock, conditions
	if int(me.get("health", 1)) <= 0:
		st["usable"] = false
		st["blocked_by"] = "dead"
	else:
		var block: String = cc_block(me.get("auras", []), ab)
		if block == "" and int(view.get("school_locks", {}).get(str(ab.get("school", "")), 0)) > tick:
			block = "school_locked"
		if block == "":
			block = condition_block(me, target, ab)
		if block != "":
			st["usable"] = false
			st["blocked_by"] = block
		elif not (ab.get("usable_if", {}) as Dictionary).is_empty():
			st["highlight"] = true  # a conditional ability (execute) that is usable now
	# range to the current target, for abilities that take one
	var kind: String = str(ab.get("target", "none"))
	if not target.is_empty() and int(target.get("id", -1)) != int(me["id"]) and kind in ["enemy", "any_unit", "ally"]:
		var hostile: bool = int(target["team"]) != int(me["team"])
		if (kind == "enemy" and hostile) or kind == "any_unit" or (kind == "ally" and not hostile):
			var a: Vector3 = me["position"]
			var b: Vector3 = target["position"]
			var d: float = Vector2(a.x - b.x, a.z - b.z).length()
			st["range"] = d <= float(ab.get("range_m", 0.0)) + ArenaGeometry.UNIT_RADIUS
	return st


## Remember when each cooldown and the GCD started, so sweeps run over the real length.
static func update_cooldown_starts(view: Dictionary, cd_starts: Dictionary) -> void:
	if view.is_empty():
		return
	var tick: int = int(view["tick"])
	var cds: Dictionary = view.get("cooldowns", {})
	for a: String in cds:
		var ready: int = int(cds[a])
		var span: Array = cd_starts.get(a, [])
		if ready > tick and (span.size() != 2 or int(span[1]) != ready):
			cd_starts[a] = [tick, ready]
	var g: int = int(view.get("gcd_ready_tick", 0))
	var gs: Array = cd_starts.get("gcd", [])
	if g > tick and (gs.size() != 2 or int(gs[1]) != g):
		cd_starts["gcd"] = [tick, g]


static func _primary_resource(spec_id: String) -> String:
	return str(Data.specs.get(spec_id, {}).get("primary_resource", ""))


## Why crowd control stops an ability ("stun", "silenced"...), or "" (mirrors Combat._cc_blocks).
static func cc_block(auras: Array, ab: Dictionary) -> String:
	var allowed: Array = ab.get("usable_while_cc", [])
	for a: Dictionary in auras:
		var cat: String = str(Data.auras.get(str(a["id"]), {}).get("cc_category", "none"))
		if cat in Combat.HARD_CC and not cat in allowed:
			return cat
		if cat == "silence" and str(ab.get("school", "")) != "physical" and not "silence" in allowed:
			return "silenced"
		if cat == "disarm" and str(ab.get("school", "")) == "physical" and str(ab.get("kit_slot", "")) != "shared" \
				and not "disarm" in allowed:
			return "disarmed"
	return ""


## Why an ability's usable_if conditions fail for this target, or "" (mirrors Combat._usable_if).
static func condition_block(me: Dictionary, target: Dictionary, ab: Dictionary) -> String:
	var c: Dictionary = ab.get("usable_if", {})
	if c.is_empty():
		return ""
	var has_t: bool = not target.is_empty()
	if c.has("target_health_below_pct") and (not has_t or float(target["health"]) * 100.0 / maxf(1.0, float(target["max_health"])) >= float(c["target_health_below_pct"])):
		return "target_health_too_high"
	if c.has("target_has_aura") and (not has_t or not _has_aura(target, str(c["target_has_aura"]))):
		return "target_missing_aura"
	if c.has("target_cc") and (not has_t or cc_category(target.get("auras", []), c["target_cc"]) == ""):
		return "target_not_controlled"
	if c.has("caster_has_aura") and not _has_aura(me, str(c["caster_has_aura"])):
		return "caster_missing_aura"
	if c.has("caster_not_has_aura") and _has_aura(me, str(c["caster_not_has_aura"])):
		return "caster_has_aura"
	return ""


static func _has_aura(u: Dictionary, aura_id: String) -> bool:
	for a: Dictionary in u.get("auras", []):
		if str(a["id"]) == aura_id:
			return true
	return false


## The first CC category among `categories` that one of the auras carries, or "".
static func cc_category(auras: Array, categories: Array) -> String:
	for a: Dictionary in auras:
		var cat: String = str(Data.auras.get(str(a["id"]), {}).get("cc_category", "none"))
		if cat in categories:
			return cat
	return ""


# ------------------------------------------------------------------ auras and crowd control

## A unit's auras as the frames show them: hidden ones dropped; crowd control first, then major
## defensives, major offensives, then the rest (debuffs before buffs); within a group the one
## ending soonest first. Each entry: {id, aura (data), group, cc, category, kind, remaining_s,
## duration_s, stacks, size (1.5 for CC, 1.2 for major, 1.0)}.
static func sorted_auras(unit: Dictionary, view: Dictionary) -> Array:
	var tick: int = int(view.get("tick", 0))
	var rate: float = float(view.get("tick_rate", 60))
	var out: Array = []
	for a: Dictionary in unit.get("auras", []):
		var data: Dictionary = Data.auras.get(str(a["id"]), {})
		if data.is_empty():
			continue
		var prio: String = str(data.get("hud_priority", "normal"))
		if prio == "hidden":
			continue
		var cat: String = str(data.get("cc_category", "none"))
		var is_cc: bool = not cat in NO_CC or prio == "cc"
		var group: String = "cc" if is_cc else prio
		if not AURA_GROUP.has(group):
			group = "normal"
		var expires: int = int(a.get("expires_tick", 0))
		var applied: int = int(a.get("applied_tick", -1))
		var dur: float = (expires - applied) / rate if expires > 0 and applied >= 0 else float(data.get("duration_s", 0.0))
		out.append({"id": str(a["id"]), "aura": data, "group": group, "cc": is_cc, "category": cat,
			"kind": str(data.get("kind", "buff")), "remaining_s": (expires - tick) / rate if expires > 0 else -1.0,
			"duration_s": dur, "stacks": int(a.get("stacks", 1)),
			"size": float(AURA_SIZE[group]), "source": int(a.get("source", -1))})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		var gx: int = AURA_GROUP[x["group"]]
		var gy: int = AURA_GROUP[y["group"]]
		if gx != gy:
			return gx < gy
		if x["kind"] != y["kind"]:
			return x["kind"] == "debuff"
		var rx: float = x["remaining_s"] if x["remaining_s"] >= 0.0 else INF
		var ry: float = y["remaining_s"] if y["remaining_s"] >= 0.0 else INF
		if rx != ry:
			return rx < ry
		return str(x["id"]) < str(y["id"]))
	return out


## The crowd control on a unit worth showing, among `categories`: the highest priority category
## (the layout's crowd_control priority), the longest-lasting aura of it. {} when none.
## {category, aura_id, name, remaining_s, duration_s}.
static func active_cc(unit: Dictionary, view: Dictionary, categories: Array, cc_style: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	for e: Dictionary in sorted_auras(unit, view):
		var cat: String = e["category"]
		if not cat in categories:
			continue
		var prio: int = int(cc_style.get(cat, {}).get("priority", 99))
		var rem: float = e["remaining_s"] if e["remaining_s"] >= 0.0 else INF
		if best.is_empty() or prio < int(best["priority"]) or (prio == int(best["priority"]) and rem > float(best["remaining_s"])):
			best = {"category": cat, "aura_id": e["id"], "name": str(e["aura"].get("name", e["id"])),
				"remaining_s": rem, "duration_s": e["duration_s"], "priority": prio}
	return best
