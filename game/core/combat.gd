class_name Combat
extends RefCounted
## The combat rules (backlog M1-01..M1-08), shared by the server and tests.
##
## Everything is driven by data (abilities, auras, specs, tuning). Times are simulation ticks.
## The server calls, each tick and in this order:
##   press(unit, ability, target) for ability inputs, then tick() once.
## Every outcome is appended to `events` (the combat log); the caller clears it.

const HARD_CC: Array[String] = ["stun", "incapacitate", "disorient"]
const EYE_HEIGHT: float = 1.6
const CHEST_HEIGHT: float = 1.2
const TAB_MAX_RANGE: float = 40.0

var sim: Sim
var tuning: Dictionary
var abilities: Dictionary
var auras_db: Dictionary
var talent_trees: Dictionary = {}  ## tree id -> tree (Data.talents); set by MatchRunner
var specs: Dictionary
var classes: Dictionary
var geometry: ArenaGeometry
var arena: ArenaMatch  ## optional; supplies dampening
var events: Array[Dictionary] = []

var _queue_window_ticks: int
var _gcd_ticks: int
var _gcd_min_ticks: int
var _gcd_energy_ticks: int
var _dr: Array
var _dr_reset_ticks: int
var _max_cc_ticks: int
var _in_combat_ticks: int
var _crit_mult: float
var _armor: Dictionary
var _aa: Dictionary


func _init(p_sim: Sim, p_tuning: Dictionary, p_abilities: Dictionary, p_auras: Dictionary,
		p_specs: Dictionary, p_classes: Dictionary, p_geometry: ArenaGeometry) -> void:
	sim = p_sim
	tuning = p_tuning
	abilities = p_abilities
	auras_db = p_auras
	specs = p_specs
	classes = p_classes
	geometry = p_geometry
	var pace: Dictionary = tuning["pacing"]
	_queue_window_ticks = _ticks(float(pace["spell_queue_window_ms"]) / 1000.0)
	_gcd_ticks = _ticks(pace["gcd_s"])
	_gcd_min_ticks = _ticks(pace["gcd_min_s"])
	_gcd_energy_ticks = _ticks(pace["gcd_energy_s"])
	var cc: Dictionary = tuning["crowd_control"]
	_dr = cc["dr_multipliers"]
	_dr_reset_ticks = _ticks(cc["dr_reset_s"])
	_max_cc_ticks = _ticks(cc["max_cc_duration_s"])
	_in_combat_ticks = _ticks(tuning["combat"]["in_combat_s"])
	_crit_mult = float(tuning["damage"]["crit_multiplier"])
	_armor = tuning["damage"]["armor_reduction"]
	_aa = tuning["damage"]["auto_attack"]


func _ticks(seconds: float) -> int:
	return roundi(seconds * sim.tick_rate)


# ================================================================== unit setup

## Fill a unit from its spec: health, armor, resources, stats, known abilities, weapon.
func init_unit(u: Unit) -> void:
	var spec: Dictionary = specs.get(u.spec_id, {})
	if spec.is_empty():
		return
	var cls: Dictionary = classes.get(spec["class"], {})
	u.class_id = spec["class"]
	u.armor = cls.get("armor", "plate")
	u.weapon_type = spec.get("weapon", {}).get("type", "fist")
	u.max_health = int(spec.get("health_override", tuning["health"][spec["role"]]))
	u.health = u.max_health
	var c: Dictionary = tuning["combat"]
	var st: Dictionary = spec.get("stats", {})
	u.stats = {"power_bonus": float(st.get("power_bonus", c["power_bonus"])),
		"haste": float(st.get("haste", c["haste"])), "crit_chance": float(st.get("crit_chance", c["crit_chance"]))}
	u.primary_resource = spec["primary_resource"]
	for res: String in [spec["primary_resource"], spec.get("secondary_resource", "")]:
		if res == "":
			continue
		var r: Dictionary = tuning["resources"][res]
		u.resource_max[res] = float(r["max"])
		u.resources[res] = 0.0 if res in ["rage", "runic_power", "fury", "combo_points"] else float(r["max"])
	u.known_abilities.clear()
	for a: String in spec["abilities"] + cls.get("shared_abilities", []):
		if not a in u.known_abilities:
			u.known_abilities.append(a)
	_apply_talents(u)


## Apply the unit's talent loadout: talented copies of abilities and auras, changes to the unit's
## own numbers, granted abilities. An illegal loadout is ignored (the server checks it on join).
func _apply_talents(u: Unit) -> void:
	for i: int in range(u.auras.size() - 1, -1, -1):
		if u.auras[i].get("talent", false):
			u.auras.remove_at(i)  # loadout changed during preparation: drop the old passives
	u.talent_abilities = {}
	u.talent_auras = {}
	if Talents.is_empty(u.loadout):
		return
	var trees: Dictionary = Talents.trees_for(u.spec_id, specs, classes, talent_trees)
	if Talents.check(u.loadout, trees) != "":
		return
	var t: Dictionary = Talents.resolve(u.loadout, trees, abilities, auras_db)
	u.talent_abilities = t["abilities"]
	u.talent_auras = t["auras"]
	for g: String in t["grants"]:
		if not g in u.known_abilities:
			u.known_abilities.append(g)
	var full: Array = u.resources.keys().filter(func(r: String) -> bool: return u.resources[r] >= u.resource_max[r])
	for aura_id: String in t["grant_auras"]:
		apply_aura(u, u, aura_id)
		for inst: Dictionary in u.auras:
			if inst["id"] == aura_id and inst["source"] == u.id:
				inst["talent"] = true
	Talents.apply_self(u, t["self"])
	u.health = u.max_health
	for r: String in full:
		u.resources[r] = float(u.resource_max[r])


## The unit's version of an ability: its talented copy when its talents change it.
func ability_of(u: Unit, ability_id: String) -> Dictionary:
	return u.talent_abilities.get(ability_id, abilities.get(ability_id, {}))


## The unit's version of an aura it is about to apply.
func aura_of(u: Unit, aura_id: String) -> Dictionary:
	return u.talent_auras.get(aura_id, auras_db[aura_id])


## An aura instance's data: the talented copy of the unit that applied it, if it had one.
func aura_data(inst: Dictionary) -> Dictionary:
	if inst.has("v"):
		var src: Unit = sim.units.get(int(inst["v"]))
		if src and src.talent_auras.has(inst["id"]):
			return src.talent_auras[inst["id"]]
	return auras_db[inst["id"]]


# ================================================================== pressing abilities

## Handle an ability press. Uses it now, queues it (spell queue window), or logs why not.
func press(u: Unit, ability_id: String, target_id: int) -> void:
	var result: String = try_use(u, ability_id, target_id)
	if result == "queued" or result == "ok":
		return
	_log({"type": "cast_failed", "source": u.id, "ability": ability_id, "reason": result})


## Returns "ok", "queued" or a failure reason.
func try_use(u: Unit, ability_id: String, target_id: int, from_queue: bool = false) -> String:
	var ab: Dictionary = ability_of(u, ability_id)
	if ab.is_empty() or not ability_id in u.known_abilities:
		return "unknown_ability"
	if not u.is_alive():
		return "dead"
	if ab["cast_type"] == "passive":
		return "passive"
	var cc_block: String = _cc_blocks(u, ab)
	if cc_block != "":
		return cc_block
	if _has_flag(u, "pacify"):
		return "pacified"
	if int(u.school_locks.get(ab["school"], 0)) > sim.tick:
		return "school_locked"
	# timing: casting, GCD and cooldown, with the spell queue window
	var now: int = sim.tick
	var wait: int = 0
	var off_gcd_instant: bool = not ab["triggers_gcd"] and ab["cast_type"] == "instant"
	if u.is_casting() and not off_gcd_instant:
		wait = maxi(wait, int(u.cast["end_tick"]) - now)
	if ab["triggers_gcd"]:
		wait = maxi(wait, u.gcd_ready_tick - now)
	wait = maxi(wait, int(u.cooldowns.get(ability_id, 0)) - now)
	if wait > 0:
		if wait <= _queue_window_ticks and not from_queue:
			u.queued = {"ability": ability_id, "target": target_id, "expires_tick": now + _queue_window_ticks + wait}
			return "queued"
		return "not_ready" if not from_queue else "waiting"
	# cost
	var cost: Dictionary = ab.get("cost", {})
	if not cost.is_empty() and float(u.resources.get(cost["resource"], 0.0)) < float(cost["amount"]):
		return "no_resource"
	# target, range and sight
	var target: Unit = _resolve_target(u, ab, target_id)
	if target == null and ab["target"] in ["enemy", "ally", "any_unit"]:
		return "no_target"
	if target != null and target != u:
		var reason: String = _range_and_sight(u, target, ab)
		if reason != "":
			return reason
	var cond: String = _usable_if(u, target, ab)
	if cond != "":
		return cond
	_begin(u, ab, target)
	return "ok"


func _begin(u: Unit, ab: Dictionary, target: Unit) -> void:
	var now: int = sim.tick
	u.queued = {}
	if ab["triggers_gcd"]:
		u.gcd_ready_tick = now + _gcd_length(u, ab)
	var tid: int = target.id if target else -1
	if ab["cast_type"] == "instant":
		_pay_and_cooldown(u, ab)
		_log({"type": "cast_success", "source": u.id, "target": tid, "ability": ab["id"]})
		_apply_effects(u, ab, target, 1.0)
		_on_hostile_action(u, target, ab)
		return
	var length: int = maxi(1, roundi(_ticks(ab["cast_time_s"]) / _haste_mult(u)))
	u.cast = {"ability": ab["id"], "target": tid, "start_tick": now, "end_tick": now + length,
		"channel": ab["cast_type"] == "channel", "ticks_done": 0,
		"tick_every": maxi(1, length / int(ab.get("channel_ticks", 1)))}
	if ab["cast_type"] == "channel":
		_pay_and_cooldown(u, ab)  # channels pay and start their cooldown up front
	_log({"type": "cast_start", "source": u.id, "target": tid, "ability": ab["id"], "end_tick": now + length})


func _gcd_length(u: Unit, ab: Dictionary) -> int:
	if ab.has("gcd_override_s"):
		return _ticks(ab["gcd_override_s"])
	if u.primary_resource == "energy":
		return _gcd_energy_ticks
	return maxi(_gcd_min_ticks, roundi(_gcd_ticks / _haste_mult(u)))


func _haste_mult(u: Unit) -> float:
	return (1.0 + float(u.stats["haste"])) * _mod(u, "haste", 1.0) * _mod(u, "cast_speed", 1.0)


func _pay_and_cooldown(u: Unit, ab: Dictionary) -> void:
	var cost: Dictionary = ab.get("cost", {})
	if not cost.is_empty():
		u.resources[cost["resource"]] = float(u.resources.get(cost["resource"], 0.0)) - float(cost["amount"])
	var gen: Dictionary = ab.get("generates", {})
	if not gen.is_empty():
		_add_resource(u, gen["resource"], float(gen["amount"]))
	if float(ab["cooldown_s"]) > 0.0:
		u.cooldowns[ab["id"]] = sim.tick + _ticks(float(ab["cooldown_s"]) / _mod(u, "cooldown_rate", 1.0))
	if ab.has("consumes_aura"):
		_remove_aura_by_id(u, ab["consumes_aura"], "consumed")


func _cc_blocks(u: Unit, ab: Dictionary) -> String:
	var allowed: Array = ab.get("usable_while_cc", [])
	for a: Dictionary in u.auras:
		var cat: String = aura_data(a)["cc_category"]
		if cat in HARD_CC and not cat in allowed:
			return cat
		if cat == "silence" and ab["school"] != "physical" and not "silence" in allowed:
			return "silenced"
		if cat == "disarm" and ab["school"] == "physical" and ab["kit_slot"] != "shared" and not "disarm" in allowed:
			return "disarmed"
	return ""


func _resolve_target(u: Unit, ab: Dictionary, target_id: int) -> Unit:
	var t: Unit = sim.units.get(target_id)
	match ab["target"]:
		"self", "none", "ground":
			return u if ab["target"] == "self" else null
		"enemy":
			return t if t and t.is_alive() and t.team != u.team else null
		"ally":
			# auto self-cast: no valid friendly target means the caster
			return t if t and t.is_alive() and t.team == u.team else u
		"any_unit":
			return t if t and t.is_alive() else null
	return null


func _range_and_sight(u: Unit, t: Unit, ab: Dictionary) -> String:
	var dist: float = _flat(u.position).distance_to(_flat(t.position))
	var rng: float = float(ab["range_m"])
	if rng <= float(tuning["ranges"]["melee_m"]) and (u.velocity.length() > 0.1 or t.velocity.length() > 0.1):
		rng += float(tuning["combat"]["melee_leeway_m"])  # latency compensation while moving
	if dist > rng + ArenaGeometry.UNIT_RADIUS:
		return "out_of_range"
	if dist < float(ab.get("min_range_m", 0.0)):
		return "too_close"
	if ab["requires_los"] and not sees(u, t):
		return "line_of_sight"
	return ""


func _usable_if(u: Unit, t: Unit, ab: Dictionary) -> String:
	var c: Dictionary = ab.get("usable_if", {})
	if c.has("target_health_below_pct") and (t == null or t.health * 100.0 / t.max_health >= float(c["target_health_below_pct"])):
		return "target_health_too_high"
	if c.has("target_has_aura") and (t == null or not has_aura(t, c["target_has_aura"])):
		return "target_missing_aura"
	if c.has("target_cc") and (t == null or not has_cc_in(t, c["target_cc"])):
		return "target_not_controlled"
	if c.has("caster_has_aura") and not has_aura(u, c["caster_has_aura"]):
		return "caster_missing_aura"
	if c.has("caster_not_has_aura") and has_aura(u, c["caster_not_has_aura"]):
		return "caster_has_aura"
	return ""


# ================================================================== the tick

func tick() -> void:
	for u: Unit in _sorted_units():
		_update_cast(u)
	for u: Unit in _sorted_units():
		_update_auras(u)
	for u: Unit in _sorted_units():
		_update_auto_attack(u)
		_update_resources(u)
		if not u.queued.is_empty():
			if sim.tick > int(u.queued["expires_tick"]):
				u.queued = {}
			else:
				var r: String = try_use(u, u.queued["ability"], u.queued["target"], true)
				if r != "ok" and r != "waiting":
					_log({"type": "cast_failed", "source": u.id, "ability": u.queued["ability"], "reason": r})
					u.queued = {}
		u.moved_this_tick = false


func _sorted_units() -> Array:
	return sim.turn_order()


func _update_cast(u: Unit) -> void:
	if not u.is_casting():
		return
	var ab: Dictionary = ability_of(u, u.cast["ability"])
	if not u.is_alive():
		u.cast = {}
		return
	if u.moved_this_tick and not ab.get("castable_while_moving", false):
		_cancel_cast(u, "moved")
		return
	var target: Unit = sim.units.get(u.cast["target"]) if int(u.cast["target"]) >= 0 else null
	# A tick's time has passed once it is processed: a 120-tick cast started at tick T
	# completes while processing tick T + 119.
	var elapsed: int = sim.tick + 1 - int(u.cast["start_tick"])
	var length: int = int(u.cast["end_tick"]) - int(u.cast["start_tick"])
	if u.cast["channel"]:
		var due: int = mini(elapsed / int(u.cast["tick_every"]), int(ab.get("channel_ticks", 1)))
		while int(u.cast["ticks_done"]) < due:
			u.cast["ticks_done"] = int(u.cast["ticks_done"]) + 1
			if target and target != u and (not target.is_alive() or _range_and_sight(u, target, ab) != ""):
				_cancel_cast(u, "target_lost")
				return
			_apply_effects(u, ab, target, 1.0)
			_on_hostile_action(u, target, ab)
		if elapsed >= length:
			_log({"type": "channel_end", "source": u.id, "ability": ab["id"]})
			u.cast = {}
		return
	if elapsed < length:
		return
	# cast complete: re-check the target, range, sight and cost
	var reason: String = ""
	if ab["target"] in ["enemy", "ally", "any_unit"]:
		if target == null or not target.is_alive():
			reason = "target_lost"
		elif target != u:
			reason = _range_and_sight(u, target, ab)
	var cost: Dictionary = ab.get("cost", {})
	if reason == "" and not cost.is_empty() and float(u.resources.get(cost["resource"], 0.0)) < float(cost["amount"]):
		reason = "no_resource"
	u.cast = {}
	if reason != "":
		_log({"type": "cast_failed", "source": u.id, "ability": ab["id"], "reason": reason})
		return
	_pay_and_cooldown(u, ab)
	_log({"type": "cast_success", "source": u.id, "target": target.id if target else -1, "ability": ab["id"]})
	_apply_effects(u, ab, target, 1.0)
	_on_hostile_action(u, target, ab)


func _cancel_cast(u: Unit, reason: String) -> void:
	_log({"type": "cast_interrupted", "source": u.id, "ability": u.cast["ability"], "reason": reason})
	u.cast = {}


# ================================================================== effects

func _apply_effects(u: Unit, ab: Dictionary, target: Unit, scale: float) -> void:
	for eff: Dictionary in ab["effects"]:
		for t: Unit in _affected(u, ab, target, eff):
			apply_effect(u, t, eff, ab, scale)


func _affected(u: Unit, ab: Dictionary, target: Unit, eff: Dictionary) -> Array:
	var affects: String = eff.get("affects", "target")
	if affects == "self":
		return [u]
	if affects == "target":
		return [target] if target else []
	var centre: Unit = target if target else u
	var radius: float = float(eff.get("radius_m", 8.0))
	var want_enemy: bool = affects == "enemies_in_radius"
	var out: Array = []
	for other: Unit in _sorted_units():
		if not other.is_alive() or (other.team != u.team) != want_enemy:
			continue
		if _flat(other.position).distance_to(_flat(centre.position)) <= radius and sees(centre, other):
			out.append(other)
	if eff.has("max_targets"):
		out = out.slice(0, int(eff["max_targets"]))
	return out


func apply_effect(u: Unit, t: Unit, eff: Dictionary, ab: Dictionary, scale: float = 1.0) -> void:
	if not t.is_alive() and eff["type"] != "resource":
		return
	match eff["type"]:
		"damage":
			var mult: float = scale
			var mi: Dictionary = eff.get("multiplier_if", {})
			if (mi.has("target_has_aura") and has_aura(t, mi["target_has_aura"])) \
					or (mi.has("target_cc") and has_cc_in(t, mi["target_cc"])):
				mult *= float(mi["value"])
			if eff.has("condition") and not _condition(u, t, eff["condition"]):
				return
			deal_damage(u, t, float(eff["base"]) * mult, eff.get("school", ab["school"]), ab,
				float(eff.get("power_coefficient", 1.0)), bool(eff.get("can_crit", true)))
		"heal":
			heal(u, t, float(eff["base"]) * scale, ab, float(eff.get("power_coefficient", 1.0)),
				bool(eff.get("can_crit", true)))
		"apply_aura", "absorb":
			apply_aura(u, t, eff["aura"])
		"dispel":
			_dispel(u, t, eff, ab)
		"interrupt":
			_interrupt(u, t, float(eff["school_lock_s"]), ab)
		"resource":
			_add_resource(t, eff["resource"], float(eff["amount"]))
		"remove_cc":
			for i: int in range(t.auras.size() - 1, -1, -1):
				if aura_data(t.auras[i])["cc_category"] != "none":
					_remove_aura_at(t, i, "broken_free")
		"knockback":
			if _immune(t, "cc"):
				return
			var dir: Vector3 = _flat3(t.position - u.position).normalized()
			if dir == Vector3.ZERO:
				dir = Movement.forward_of(u.facing)
			var to: Vector3 = t.position + dir * float(eff.get("distance_m", 8.0))
			t.position = geometry.resolve(to) if geometry else to
			t.displaced_tick = sim.tick
			_cancel_if_casting(t, "knocked_back")
			_log({"type": "knockback", "source": u.id, "target": t.id})
		"charge":
			# rush the caster to the target, stopping 1.5 m short; pillars and walls stop it
			var goal: Vector3 = t.position - _flat3(t.position - u.position).normalized() * 1.5
			var pos: Vector3 = u.position
			var step: Vector3 = (goal - pos) / 40.0
			for i: int in 40:
				var nxt: Vector3 = pos + step
				var res: Vector3 = geometry.resolve(nxt) if geometry else nxt
				if res.distance_to(nxt) > 0.05:
					break
				pos = res
			u.position = pos
			u.displaced_tick = sim.tick
			var to_t: Vector3 = _flat3(t.position - u.position)
			if to_t.length() > 0.01:
				u.facing = atan2(-to_t.x, -to_t.z)
			_log({"type": "charge", "source": u.id, "target": t.id})
		"teleport":
			var fwd: Vector3 = Movement.forward_of(t.facing)
			var dist: float = float(eff.get("distance_m", 15.0))
			var dest: Vector3 = t.position
			for step: int in 30:  # walk forward in small steps so walls and pillars stop the blink
				var nxt: Vector3 = dest + fwd * (dist / 30.0)
				var res: Vector3 = geometry.resolve(nxt) if geometry else nxt
				if res.distance_to(nxt) > 0.05:
					break
				dest = res
			t.position = dest
			t.displaced_tick = sim.tick
			_log({"type": "teleport", "source": u.id, "target": t.id})


## Damage formula (docs/DESIGN.md): base x (1 + power bonus x coefficient) x crit x armor
## x target damage-taken mods x caster damage-done mods x PvP modifier. Absorbs soak first.
func deal_damage(u: Unit, t: Unit, base: float, school: String, ab: Dictionary,
		coef: float = 1.0, can_crit: bool = true) -> int:
	if _immune(t, "damage") or _immune(t, "physical" if school == "physical" else "magic"):
		_log({"type": "immune", "source": u.id if u else -1, "target": t.id, "ability": ab.get("id", "")})
		return 0
	var amount: float = base
	var crit: bool = false
	if u:
		amount *= 1.0 + float(u.stats["power_bonus"]) * coef
		amount *= _mod(u, "damage_done", 1.0)
		if can_crit and sim.rng.randf() < float(u.stats["crit_chance"]) + _mod_add(u, "crit_chance"):
			crit = true
			amount *= _crit_mult
	if school == "physical":
		amount *= 1.0 - clampf(float(_armor.get(t.armor, 0.0)) + _mod_add(t, "armor"), 0.0, 0.9)
	amount *= _mod(t, "damage_taken", 1.0)
	amount *= float(ab.get("pvp_modifier", 1.0))
	var dmg: int = maxi(0, roundi(amount))
	var absorbed: int = _absorb(t, dmg)
	var dealt: int = mini(dmg - absorbed, t.health)
	t.health -= dealt
	_log({"type": "damage", "source": u.id if u else -1, "target": t.id, "ability": ab.get("id", ""),
		"school": school, "amount": dealt, "absorbed": absorbed, "crit": crit, "killed": t.health <= 0,
		"weapon": u.weapon_type if u and ab.get("id", "") == "auto_attack" else ""})
	_after_damage(u, t, dealt + absorbed, str(ab.get("id", "")))
	return dealt


func heal(u: Unit, t: Unit, base: float, ab: Dictionary, coef: float = 1.0, can_crit: bool = true) -> int:
	var amount: float = base * (1.0 + float(u.stats["power_bonus"]) * coef) * _mod(u, "healing_done", 1.0)
	var crit: bool = false
	if can_crit and sim.rng.randf() < float(u.stats["crit_chance"]) + _mod_add(u, "crit_chance"):
		crit = true
		amount *= _crit_mult
	amount *= _mod(t, "healing_taken", 1.0)
	if arena:
		amount *= arena.healing_multiplier(sim.tick)
	var raw: int = maxi(0, roundi(amount))
	var done: int = mini(raw, t.max_health - t.health)
	t.health += done
	_log({"type": "heal", "source": u.id, "target": t.id, "ability": ab.get("id", ""), "amount": done,
		"overheal": raw - done, "crit": crit})
	return done


func _after_damage(u: Unit, t: Unit, amount: int, ability_id: String = "") -> void:
	var now: int = sim.tick
	t.combat_until_tick = now + _in_combat_ticks
	if u:
		u.combat_until_tick = now + _in_combat_ticks
	var rage: Dictionary = tuning["resources"]["rage"]
	if u and u.resource_max.has("rage") and ability_id == "auto_attack":
		# rage comes from weapon swings and from being hit; abilities spend it (or grant a fixed
		# amount in their own data), so no spender can pay for itself
		_add_resource(u, "rage", amount / 1000.0 * float(rage["per_1000_auto_attack_damage"]))
	if t.resource_max.has("rage"):
		_add_resource(t, "rage", amount / 1000.0 * float(rage["per_1000_damage_taken"]))
	# crowd control that breaks on damage
	for i: int in range(t.auras.size() - 1, -1, -1):
		var inst: Dictionary = t.auras[i]
		var data: Dictionary = aura_data(inst)
		var brk: String = data.get("breaks_on_damage", "never")
		if brk == "any" and amount > 0:
			_remove_aura_at(t, i, "broken_by_damage")
		elif brk == "threshold":
			inst["damage_taken"] = int(inst.get("damage_taken", 0)) + amount
			if inst["damage_taken"] >= t.max_health * float(data["damage_threshold_pct"]) / 100.0:
				_remove_aura_at(t, i, "broken_by_damage")
	if t.health <= 0:
		_on_death(t)


func _on_death(t: Unit) -> void:
	t.cast = {}
	t.queued = {}
	t.auras.clear()
	t.target_id = -1


func _absorb(t: Unit, dmg: int) -> int:
	var absorbed: int = 0
	for i: int in range(t.auras.size() - 1, -1, -1):
		var inst: Dictionary = t.auras[i]
		if not inst.has("absorb_left") or absorbed >= dmg:
			continue
		var take: int = mini(int(inst["absorb_left"]), dmg - absorbed)
		inst["absorb_left"] = int(inst["absorb_left"]) - take
		absorbed += take
		if int(inst["absorb_left"]) <= 0:
			_remove_aura_at(t, i, "absorb_depleted")
	return absorbed


func _dispel(u: Unit, t: Unit, eff: Dictionary, ab: Dictionary) -> void:
	var types: Array = eff["dispel_types"]
	var count: int = int(eff.get("dispel_count", 1))
	var offensive: bool = t.team != u.team
	var removed: int = 0
	for i: int in range(t.auras.size() - 1, -1, -1):
		if removed >= count:
			break
		var data: Dictionary = aura_data(t.auras[i])
		var wanted_kind: String = "buff" if offensive else "debuff"
		if data["kind"] == wanted_kind and data["dispel_type"] in types:
			_log({"type": "dispel", "source": u.id, "target": t.id, "ability": ab["id"], "aura": t.auras[i]["id"]})
			_remove_aura_at(t, i, "dispelled")
			removed += 1


func _interrupt(u: Unit, t: Unit, lock_s: float, ab: Dictionary) -> void:
	if not t.is_casting():
		return
	var casting: Dictionary = ability_of(t, t.cast["ability"])
	if not casting.get("interruptible", true):
		_log({"type": "interrupt_failed", "source": u.id, "target": t.id, "ability": ab["id"], "reason": "uninterruptible"})
		return
	var school: String = casting["school"]
	t.school_locks[school] = sim.tick + _ticks(lock_s)
	_log({"type": "interrupt", "source": u.id, "target": t.id, "ability": ab["id"],
		"interrupted": casting["id"], "school": school, "lock_s": lock_s})
	t.cast = {}


func _cancel_if_casting(t: Unit, reason: String) -> void:
	if t.is_casting():
		_cancel_cast(t, reason)


func _condition(u: Unit, t: Unit, c: Dictionary) -> bool:
	if c.has("target_health_below_pct") and t.health * 100.0 / t.max_health >= float(c["target_health_below_pct"]):
		return false
	if c.has("target_has_aura") and not has_aura(t, c["target_has_aura"]):
		return false
	if c.has("caster_has_aura") and not has_aura(u, c["caster_has_aura"]):
		return false
	return true


func _add_resource(u: Unit, res: String, amount: float) -> void:
	if not u.resource_max.has(res):
		return
	u.resources[res] = clampf(float(u.resources.get(res, 0.0)) + amount, 0.0, float(u.resource_max[res]))


func _on_hostile_action(u: Unit, target: Unit, ab: Dictionary) -> void:
	if target and target.team != u.team:
		u.combat_until_tick = sim.tick + _in_combat_ticks
		target.combat_until_tick = sim.tick + _in_combat_ticks


# ================================================================== auras and crowd control

## Apply an aura, with crowd-control diminishing returns and the 8 s cap.
func apply_aura(u: Unit, t: Unit, aura_id: String) -> void:
	var data: Dictionary = aura_of(u, aura_id)
	var now: int = sim.tick
	var duration: int = _ticks(float(data["duration_s"]))
	var cat: String = data["cc_category"]
	if cat != "none":
		if _immune(t, "cc"):
			_log({"type": "immune", "source": u.id, "target": t.id, "aura": aura_id})
			return
		if cat != "knockback":
			var state: Dictionary = t.dr.get(cat, {"count": 0, "reset_tick": 0})
			if now >= int(state["reset_tick"]) and not _has_cc_category(t, cat):
				state["count"] = 0
			var mult: float = float(_dr[mini(int(state["count"]), _dr.size() - 1)])
			if mult <= 0.0:
				_log({"type": "immune", "source": u.id, "target": t.id, "aura": aura_id, "reason": "diminishing_returns"})
				return
			duration = mini(roundi(duration * mult), _max_cc_ticks)
			state["count"] = int(state["count"]) + 1
			state["reset_tick"] = now + duration + _dr_reset_ticks
			t.dr[cat] = state
	for inst: Dictionary in t.auras:
		if inst["id"] == aura_id and inst["source"] == u.id:
			match data.get("refresh", "refresh"):
				"ignore":
					return
				"extend":
					inst["expires_tick"] = int(inst["expires_tick"]) + duration
				"add_stack":
					inst["stacks"] = mini(int(inst["stacks"]) + 1, int(data.get("max_stacks", 1)))
					inst["expires_tick"] = now + duration
				_:
					inst["expires_tick"] = now + duration
			if data.has("absorb"):
				inst["absorb_left"] = int(data["absorb"])
			_log({"type": "aura_refreshed", "source": u.id, "target": t.id, "aura": aura_id})
			return
	var inst_new: Dictionary = {"id": aura_id, "source": u.id, "applied_tick": now,
		"expires_tick": now + duration if duration > 0 else 0, "stacks": 1}
	if u.talent_auras.has(aura_id):
		inst_new["v"] = u.id  # numbers come from the source's talented copy (see aura_data)
	if data.has("periodic"):
		inst_new["next_tick"] = now + _ticks(float(data["periodic"]["interval_s"]))
	if data.has("absorb"):
		inst_new["absorb_left"] = int(data["absorb"])
	t.auras.append(inst_new)
	if cat in HARD_CC or cat == "silence":
		_cancel_if_casting(t, "crowd_controlled")
	_log({"type": "aura_applied", "source": u.id, "target": t.id, "aura": aura_id,
		"cc": cat, "duration_ticks": duration})


func _update_auras(u: Unit) -> void:
	var now: int = sim.tick
	var i: int = 0
	while i < u.auras.size():
		var inst: Dictionary = u.auras[i]
		var data: Dictionary = aura_data(inst)
		if data.has("periodic") and now >= int(inst["next_tick"]):
			inst["next_tick"] = int(inst["next_tick"]) + _ticks(float(data["periodic"]["interval_s"]))
			var src: Unit = sim.units.get(inst["source"])
			var eff: Dictionary = data["periodic"]["effect"]
			var fake_ab: Dictionary = {"id": inst["id"], "school": eff.get("school", "physical"), "pvp_modifier": 1.0}
			apply_effect(src if src else u, u, eff, fake_ab, float(inst["stacks"]))
			if not u.is_alive():
				return
			if i >= u.auras.size() or u.auras[i] != inst:
				continue  # the aura was removed by its own effect
		if int(inst["expires_tick"]) > 0 and now >= int(inst["expires_tick"]):
			_remove_aura_at(u, i, "expired")
			continue
		i += 1


func _remove_aura_at(u: Unit, i: int, reason: String) -> void:
	var inst: Dictionary = u.auras[i]
	var cat: String = aura_data(inst)["cc_category"]
	u.auras.remove_at(i)
	if cat != "none" and cat != "knockback" and u.dr.has(cat):
		u.dr[cat]["reset_tick"] = sim.tick + _dr_reset_ticks  # DR resets 18 s after the CC ends
	_log({"type": "aura_removed", "target": u.id, "aura": inst["id"], "reason": reason})


func _remove_aura_by_id(u: Unit, aura_id: String, reason: String) -> void:
	for i: int in range(u.auras.size() - 1, -1, -1):
		if u.auras[i]["id"] == aura_id:
			_remove_aura_at(u, i, reason)
			return


func has_aura(u: Unit, aura_id: String) -> bool:
	for a: Dictionary in u.auras:
		if a["id"] == aura_id:
			return true
	return false


func has_cc_in(u: Unit, categories: Array) -> bool:
	for a: Dictionary in u.auras:
		if aura_data(a)["cc_category"] in categories:
			return true
	return false


func _has_cc_category(u: Unit, cat: String) -> bool:
	for a: Dictionary in u.auras:
		if aura_data(a)["cc_category"] == cat:
			return true
	return false


func _has_flag(u: Unit, flag: String) -> bool:
	for a: Dictionary in u.auras:
		if aura_data(a).get(flag, false):
			return true
	return false


func _immune(u: Unit, kind: String) -> bool:
	for a: Dictionary in u.auras:
		if kind in aura_data(a).get("immune", []):
			return true
	return false


## Product of multiply modifiers for a stat (times `base`).
func _mod(u: Unit, stat: String, base: float) -> float:
	var v: float = base
	for a: Dictionary in u.auras:
		for m: Dictionary in aura_data(a).get("modifiers", []):
			if m["stat"] == stat and m["op"] == "multiply":
				v *= pow(float(m["value"]), float(a["stacks"]))
	return v


func _mod_add(u: Unit, stat: String) -> float:
	var v: float = 0.0
	for a: Dictionary in u.auras:
		for m: Dictionary in aura_data(a).get("modifiers", []):
			if m["stat"] == stat and m["op"] == "add":
				v += float(m["value"]) * float(a["stacks"])
	return v


# ================================================================== movement rules for the server

## Speed multiplier from auras: roots and hard CC stop movement; only the strongest slow
## applies; speed boosts multiply.
func speed_multiplier(u: Unit) -> float:
	return speed_multiplier_from(u.auras, auras_db, sim.units)


## The same rule for an aura list (the client predicts with auras from snapshots).
static func speed_multiplier_from(aura_list: Array, db: Dictionary, units: Dictionary = {}) -> float:
	var slow: float = 1.0
	var boost: float = 1.0
	for a: Dictionary in aura_list:
		var data: Dictionary = db.get(a["id"], {})
		if a.has("v") and units.has(int(a["v"])):
			data = (units[int(a["v"])] as Unit).talent_auras.get(a["id"], data)
		if data.is_empty():
			continue
		var cat: String = data["cc_category"]
		if cat == "root" or cat == "stun" or cat == "incapacitate":
			return 0.0
		for m: Dictionary in data.get("modifiers", []):
			if m["stat"] == "move_speed" and m["op"] == "multiply":
				var v: float = float(m["value"])
				if v < 1.0:
					slow = minf(slow, v)
				else:
					boost *= v
	return slow * boost


## True when crowd control takes movement away from the player (stun, incapacitate, disorient).
static func is_forced_from(aura_list: Array, db: Dictionary) -> bool:
	for a: Dictionary in aura_list:
		if db.get(a["id"], {}).get("cc_category", "none") in HARD_CC:
			return true
	return false


## When a unit is feared (disorient), the server moves it away from the source instead of
## applying the player's input. Returns an input dictionary, or empty when not feared.
func forced_input(u: Unit) -> Dictionary:
	for a: Dictionary in u.auras:
		var data: Dictionary = aura_data(a)
		if data["cc_category"] == "disorient":
			var src: Unit = sim.units.get(a["source"])
			var away: Vector3 = _flat3(u.position - src.position) if src else Movement.forward_of(u.facing)
			var yaw: float = atan2(-away.x, -away.z) if away.length() > 0.01 else u.facing
			return {"move": Vector2(0, 1), "yaw": yaw, "jump": false}
		if data["cc_category"] in ["stun", "incapacitate"]:
			return {"move": Vector2.ZERO, "yaw": u.facing, "jump": false}
	return {}


# ================================================================== auto-attack, targeting, resources

func _update_auto_attack(u: Unit) -> void:
	var target: Unit = sim.units.get(u.target_id)
	var swing: float = float(_aa["swing_interval_s"])
	if not u.is_alive() or target == null or not target.is_alive() or target.team == u.team \
			or _cc_blocks(u, {"school": "physical", "kit_slot": "core"}) != "" or _has_flag(u, "pacify") \
			or (arena and arena.phase != ArenaMatch.Phase.ACTIVE):
		u.swing_timer = 0.0
		return
	var dt: float = 1.0 / sim.tick_rate
	if _flat(u.position).distance_to(_flat(target.position)) > float(_aa["range_m"]) + ArenaGeometry.UNIT_RADIUS \
			or not sees(u, target):
		u.swing_timer = minf(u.swing_timer + dt, swing)  # ready to swing on arrival
		return
	u.swing_timer += dt
	if u.swing_timer + 1e-9 >= swing:
		u.swing_timer = 0.0
		deal_damage(u, target, float(_aa["base_damage"]), "physical", ability_of(u, "auto_attack") if abilities.has("auto_attack") else {"id": "auto_attack"}, 0.0)


## Nearest living enemy in front (within 90 degrees of facing, 40 m, in sight); falls back to
## the nearest in range anywhere.
func tab_target(u: Unit) -> int:
	var fwd: Vector3 = Movement.forward_of(u.facing)
	var best_front: int = -1
	var best_front_d: float = INF
	var best_any: int = -1
	var best_any_d: float = INF
	for other: Unit in _sorted_units():
		if other.team == u.team or not other.is_alive():
			continue
		var to: Vector3 = _flat3(other.position - u.position)
		var d: float = to.length()
		if d > TAB_MAX_RANGE or not sees(u, other):
			continue
		if d < best_any_d:
			best_any_d = d
			best_any = other.id
		if d > 1e-6 and fwd.dot(to / d) >= 0.0 and d < best_front_d:
			best_front_d = d
			best_front = other.id
	return best_front if best_front != -1 else best_any


func _update_resources(u: Unit) -> void:
	if not u.is_alive():
		return
	var dt: float = 1.0 / sim.tick_rate
	var in_combat: bool = sim.tick < u.combat_until_tick
	for res: String in u.resource_max.keys():
		var r: Dictionary = tuning["resources"][res]
		if r.has("regen_per_s"):
			_add_resource(u, res, float(r["regen_per_s"]) * dt)
		if not in_combat and r.has("decay_per_s_out_of_combat"):
			_add_resource(u, res, -float(r["decay_per_s_out_of_combat"]) * dt)


func sees(a: Unit, b: Unit) -> bool:
	if geometry == null or a == b:
		return true
	return geometry.has_line_of_sight(a.position + Vector3.UP * EYE_HEIGHT, b.position + Vector3.UP * CHEST_HEIGHT)


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


static func _flat3(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _log(ev: Dictionary) -> void:
	ev["tick"] = sim.tick
	events.append(ev)
