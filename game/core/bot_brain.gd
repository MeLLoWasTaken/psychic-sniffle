class_name BotBrain
extends RefCounted
## A test bot for one spec (backlog M1-13). Reads a world view (the same shape whether it comes
## from network snapshots or straight from an in-process simulation) and returns one input per
## tick. Behaviour and ability priorities come from data/bots/<spec>.json.

const RETARGET_S: float = 3.0
const LOCAL_PRESS_LOCK_TICKS: int = 12
const KITE_STEP_M: float = 6.0  ## do not re-press the same ability while the server catches up

var spec_id: String
var spec: Dictionary
var profile: Dictionary
var role: String
var geometry: ArenaGeometry
var nav: NavGrid
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _path: Array[Vector3] = []
var _path_goal: Vector3 = Vector3(INF, 0, INF)
var _path_tick: int = -999
var _gates_open_seen: bool = false

var target_id: int = -1
var _retarget_tick: int = -1
var _hold_until: int = -1  ## stand still until this tick (casting)
var _local_gcd_until: int = -1
var _press_lock: Dictionary = {}  ## ability -> tick
var _seen_casts: Dictionary = {}  ## "<unit>:<start_tick>" -> tick the bot will react
var _wander_goal: Vector3 = Vector3.ZERO
var _progress_pos: Vector3 = Vector3(INF, 0, INF)
var _progress_tick: int = 0
var _movement_impaired: bool = false
var _hide_since: int = -1  ## tick the current hiding spell began, or -1
var _hide_blocked_until: int = -1

const HIDE_MAX_S: float = 8.0
const MELEE_CLOSE_M: float = 5.0
const HIDE_COOLDOWN_S: float = 6.0
var stuck_count: int = 0
var stuck_log: Array = []  ## where and toward what the bot got stuck (explain mode only)  ## times this bot stopped making progress toward a goal (for reports)
var explain: bool = false  ## record why each priority rule was skipped (for traces)
var explanation: Array = []


func _init(p_spec_id: String, seed_value: int, p_geometry: ArenaGeometry, p_nav: NavGrid = null) -> void:
	nav = p_nav if p_nav else (NavGrid.new(p_geometry) if p_geometry else null)
	spec_id = p_spec_id
	spec = Data.specs.get(spec_id, {})
	profile = Data.bots.get(spec_id, {})
	role = spec.get("role", "dps")
	geometry = p_geometry
	rng.seed = seed_value


## One input for this tick: {move, yaw, jump, tab, ability, target}.
func next_input(view: Dictionary) -> Dictionary:
	var me: Dictionary = view["me"]
	var input: Dictionary = {"move": Vector2.ZERO, "yaw": me["facing"], "jump": false, "tab": false,
		"ability": "", "target": -1}
	if me["health"] <= 0 or view["match"].get("phase", 1) != ArenaMatch.Phase.ACTIVE:
		return input
	var tick: int = view["tick"]
	var enemies: Array = view["units"].filter(func(u: Dictionary) -> bool: return u["team"] != me["team"] and u["health"] > 0)
	var allies: Array = view["units"].filter(func(u: Dictionary) -> bool: return u["team"] == me["team"] and u["health"] > 0)
	if enemies.is_empty():
		return input
	var target: Dictionary = _choose_target(view, me, enemies, tick)
	input["target"] = target["id"]
	# abilities
	var press: Dictionary = _choose_ability(view, me, target, enemies, allies, tick)
	if not press.is_empty():
		input["ability"] = press["ability"]
		input["target"] = press["target"]
	# movement
	var casting: bool = not me["cast"].is_empty() or tick < _hold_until
	_movement_impaired = _has_cc(me, ["root", "stun", "incapacitate", "disorient"])
	if casting or _movement_impaired:
		_reset_progress(me["position"], tick)  # not trying to move, so not stuck
	if casting:
		input["yaw"] = _yaw_to(me["position"], _pos_of(view, int(me["cast"].get("target", target["id"]))))
		return input
	var final_goal: Vector3 = _movement_goal(view, me, target, enemies, allies)
	var goal: Vector3 = _steer_point(me["position"], final_goal, tick)
	var to: Vector3 = goal - me["position"]
	to.y = 0.0
	var remaining: Vector3 = final_goal - me["position"]
	remaining.y = 0.0
	# walk while the final goal is still away, steering by the next waypoint (which can be close)
	if remaining.length() > 0.4 and to.length() > 0.01:
		input["yaw"] = atan2(-to.x, -to.z)
		input["move"] = Vector2(0, 1)
	else:
		_reset_progress(me["position"], tick)
		input["yaw"] = _yaw_to(me["position"], target["position"])
	return input


# ------------------------------------------------------------------ targeting

func _choose_target(view: Dictionary, me: Dictionary, enemies: Array, tick: int) -> Dictionary:
	var current: Dictionary = _find(enemies, target_id)
	# kill window: commit to a low enemy that can be attacked
	var kw: float = float(profile["behavior"].get("kill_window_pct", 0.0))
	if kw > 0.0:
		for e: Dictionary in enemies:
			if _pct(e) < kw and _sees(me, e) and not _has_breakable_cc_from_team(e, me["team"], view) \
					and not _is_immune(e) and (current.is_empty() or _pct(e) < _pct(current)):
				target_id = e["id"]
				_retarget_tick = tick + roundi(RETARGET_S * view["tick_rate"])
				return e
	var broken_cc: bool = not current.is_empty() and _has_breakable_cc_from_team(current, me["team"], view)
	if current.is_empty() or tick >= _retarget_tick or broken_cc:
		var candidates: Array = enemies.filter(func(e: Dictionary) -> bool: return not _has_breakable_cc_from_team(e, me["team"], view))
		if candidates.is_empty():
			candidates = enemies
		var best: Dictionary = candidates[0]
		match profile["behavior"]["target_priority"]:
			"healer_first":
				var healers: Array = candidates.filter(func(e: Dictionary) -> bool: return Data.specs.get(e["spec"], {}).get("role", "") == "healer")
				var pool: Array = healers if not healers.is_empty() and _sees(me, healers[0]) else candidates
				best = _lowest(pool)
			"dps_first":
				var dps: Array = candidates.filter(func(e: Dictionary) -> bool: return Data.specs.get(e["spec"], {}).get("role", "") != "healer")
				var pool_d: Array = dps.filter(func(e: Dictionary) -> bool: return _sees(me, e))
				best = _lowest(pool_d if not pool_d.is_empty() else (dps if not dps.is_empty() else candidates))
			"lowest_health":
				best = _lowest(candidates)
			_:
				best = _nearest(me, candidates)
		target_id = best["id"]
		_retarget_tick = tick + roundi(RETARGET_S * view["tick_rate"])
		return best
	return current


func _has_breakable_cc_from_team(u: Dictionary, team: int, view: Dictionary) -> bool:
	for a: Dictionary in u["auras"]:
		var d: Dictionary = Data.auras.get(a["id"], {})
		if d.get("breaks_on_damage", "never") != "never" and d.get("cc_category", "none") != "none":
			var src: Dictionary = _find(view["units"], int(a["source"]))
			if not src.is_empty() and src["team"] == team:
				return true
	return false


# ------------------------------------------------------------------ abilities

func _choose_ability(view: Dictionary, me: Dictionary, target: Dictionary, enemies: Array,
		allies: Array, tick: int) -> Dictionary:
	var hard_cc: bool = _has_cc(me, ["stun", "incapacitate", "disorient"])
	for a: Dictionary in me["auras"]:
		if Data.auras.get(a["id"], {}).get("pacify", false):
			return {}  # sealed in an immunity: nothing can be used
	if explain:
		explanation = []
	for rule: Dictionary in profile["priorities"]:
		var ab_id: String = rule["ability"]
		var ab: Dictionary = Data.abilities.get(ab_id, {})
		if ab.is_empty() or tick < int(_press_lock.get(ab_id, -1)):
			_why(ab_id, "pressed_recently")
			continue
		if hard_cc and not _cc_allowed(me, ab):
			_why(ab_id, "crowd_controlled")
			continue
		if not _ready(view, me, ab, tick):
			_why(ab_id, "not_ready:" + _not_ready_reason(view, me, ab, tick))
			continue
		var on: Dictionary = _pick_on(rule.get("on", "target"), view, me, target, enemies, allies, tick, ab)
		if on.is_empty():
			_why(ab_id, "no_unit_for:" + str(rule.get("on", "target")))
			continue
		if not _conditions(rule.get("when", {}), view, me, on, enemies, allies, tick, ab):
			_why(ab_id, "conditions")
			continue
		if not _in_range(me, on, ab):
			_why(ab_id, "out_of_range_or_los")
			continue
		_why(ab_id, "PRESS")
		# press it
		_press_lock[ab_id] = tick + LOCAL_PRESS_LOCK_TICKS
		if ab["triggers_gcd"]:
			_local_gcd_until = tick + LOCAL_PRESS_LOCK_TICKS
		if ab["cast_type"] in ["cast", "channel"]:
			_hold_until = tick + roundi(float(ab["cast_time_s"]) * view["tick_rate"]) + 3
		return {"ability": ab_id, "target": on["id"]}
	return {}


func _why(ab_id: String, reason: String) -> void:
	if explain:
		explanation.append("%s=%s" % [ab_id, reason])


func _not_ready_reason(view: Dictionary, me: Dictionary, ab: Dictionary, tick: int) -> String:
	if int(view["cooldowns"].get(ab["id"], 0)) > tick:
		return "cooldown"
	if int(view.get("school_locks", {}).get(ab["school"], 0)) > tick:
		return "school_locked"
	if ab["triggers_gcd"] and int(view["gcd_ready_tick"]) > tick:
		return "gcd"
	if ab["triggers_gcd"] and tick < _local_gcd_until:
		return "local_gcd"
	if not me["cast"].is_empty():
		return "casting"
	if tick < _hold_until:
		return "holding"
	return "resource_or_silence"


func _ready(view: Dictionary, me: Dictionary, ab: Dictionary, tick: int) -> bool:
	if int(view["cooldowns"].get(ab["id"], 0)) > tick:
		return false
	if int(view.get("school_locks", {}).get(ab["school"], 0)) > tick:
		return false
	if ab["school"] != "physical" and _has_cc(me, ["silence"]) and not "silence" in ab.get("usable_while_cc", []):
		return false
	var off_gcd: bool = not ab["triggers_gcd"] and ab["cast_type"] == "instant"
	if ab["triggers_gcd"] and (int(view["gcd_ready_tick"]) > tick or tick < _local_gcd_until):
		return false
	if not off_gcd and (not me["cast"].is_empty() or tick < _hold_until):
		return false
	var cost: Dictionary = ab.get("cost", {})
	if not cost.is_empty() and float(me["resource"]) < float(cost["amount"]):
		return false
	return true


func _pick_on(on: String, view: Dictionary, me: Dictionary, target: Dictionary, enemies: Array,
		allies: Array, tick: int, ab: Dictionary) -> Dictionary:
	match on:
		"self":
			return me
		"target":
			return target
		"lowest_ally":
			return _lowest(allies)
		"enemy_healer":
			var h: Array = enemies.filter(func(e: Dictionary) -> bool: return Data.specs.get(e["spec"], {}).get("role", "") == "healer")
			return h[0] if not h.is_empty() else {}
		"ally_attacker":
			var low: Dictionary = _lowest(allies)
			for e: Dictionary in enemies:
				if int(e["target_id"]) == int(low["id"]) and _dist(e, low) < 8.0:
					return e
			return {}
		"cc_ally":
			for a: Dictionary in allies:
				if a["id"] != me["id"] and _has_cc(a, ["stun", "incapacitate", "disorient", "silence"]):
					return a
			return {}
		"enemy_caster":
			for e: Dictionary in enemies:
				if _casting_interruptible(e, tick, view) and _in_range(me, e, ab):
					return e
			return {}
	return {}


func _conditions(w: Dictionary, view: Dictionary, me: Dictionary, on: Dictionary, enemies: Array,
		allies: Array, tick: int, ab: Dictionary) -> bool:
	# never throw crowd control into diminishing returns at 25% or immune
	if on["team"] != me["team"]:
		for e: Dictionary in ab["effects"]:
			if e["type"] == "apply_aura":
				var cat: String = Data.auras.get(e["aura"], {}).get("cc_category", "none")
				if cat != "none" and cat != "knockback" and _dr_count(on, cat, tick) >= 2:
					return false
	if w.has("focus_health_below_pct"):
		var focus: Dictionary = _find(enemies, target_id)
		if focus.is_empty() or _pct(focus) >= float(w["focus_health_below_pct"]):
			return false
	if w.get("not_focus", false) and int(on["id"]) == target_id:
		return false
	if w.has("self_health_below_pct") and _pct(me) >= float(w["self_health_below_pct"]):
		return false
	if w.has("target_health_below_pct") and _pct(on) >= float(w["target_health_below_pct"]):
		return false
	if w.has("target_health_above_pct") and _pct(on) <= float(w["target_health_above_pct"]):
		return false
	if w.has("ally_health_below_pct") and _pct(_lowest(allies)) >= float(w["ally_health_below_pct"]):
		return false
	if w.get("target_casting", false) and not _casting_interruptible(on, tick, view):
		return false
	if w.get("target_not_cc", false) and _has_cc(on, ["stun", "incapacitate", "disorient", "root", "silence"]):
		return false
	if w.has("target_cc") and not _has_cc(on, w["target_cc"]):
		return false
	if w.has("target_has_aura") and not _has_aura(on, w["target_has_aura"]):
		return false
	if w.has("target_not_has_aura") and _has_aura(on, w["target_not_has_aura"]):
		return false
	if w.has("self_has_aura") and not _has_aura(me, w["self_has_aura"]):
		return false
	if w.has("self_not_has_aura") and _has_aura(me, w["self_not_has_aura"]):
		return false
	if w.get("self_hard_cc", false) and not _has_cc(me, ["stun", "incapacitate", "disorient"]):
		return false
	if w.get("ally_hard_cc", false) and on == me:
		return false
	if w.has("enemies_within_m"):
		var d: float = float(w["enemies_within_m"][0])
		var n: int = enemies.filter(func(e: Dictionary) -> bool: return _dist(me, e) <= d).size()
		if n < int(w["enemies_within_m"][1]):
			return false
	if w.has("target_distance_above_m") and _dist(me, on) <= float(w["target_distance_above_m"]):
		return false
	if w.has("target_distance_below_m") and _dist(me, on) >= float(w["target_distance_below_m"]):
		return false
	if w.has("resource_at_least") and float(me["resource"]) < float(w["resource_at_least"]):
		return false
	var dispel_rule: Variant = w.get("has_dispellable", false)
	if (dispel_rule is String or dispel_rule == true) and not _has_dispellable(on, me, ab, dispel_rule is String):
		return false
	if w.has("no_free_melee_within_m") and not _free_melee_near(me, enemies, float(w["no_free_melee_within_m"])).is_empty():
		return false
	return true


## The nearest enemy melee within `d` that is free to act (not rooted, stunned, incapacitated
## or feared), or empty.
func _free_melee_near(me: Dictionary, enemies: Array, d: float) -> Dictionary:
	for e: Dictionary in enemies:
		if Data.specs.get(e["spec"], {}).get("range", "") == "melee" and _dist(me, e) < d \
				and not _has_cc(e, ["root", "stun", "incapacitate", "disorient"]):
			return e
	return {}


func _in_range(me: Dictionary, on: Dictionary, ab: Dictionary) -> bool:
	if on["id"] == me["id"] or ab["target"] in ["self", "none"]:
		return true
	var d: float = _dist(me, on)
	if d > float(ab["range_m"]) + ArenaGeometry.UNIT_RADIUS - 0.2 or d < float(ab.get("min_range_m", 0.0)):
		return false
	return not ab["requires_los"] or _sees(me, on)


func _casting_interruptible(u: Dictionary, tick: int, view: Dictionary) -> bool:
	if u["cast"].is_empty():
		return false
	var ab: Dictionary = Data.abilities.get(u["cast"]["ability"], {})
	if not ab.get("interruptible", true):
		return false
	var key: String = "%d:%d" % [u["id"], u["cast"]["start_tick"]]
	if not _seen_casts.has(key):
		var r: Array = profile["behavior"]["reaction_ms"]
		_seen_casts[key] = int(u["cast"]["start_tick"]) + roundi(rng.randf_range(r[0], r[1]) / 1000.0 * view["tick_rate"])
	return tick >= int(_seen_casts[key]) and tick < int(u["cast"]["end_tick"]) - 2


func _has_dispellable(u: Dictionary, me: Dictionary, ab: Dictionary, major_only: bool = false) -> bool:
	var types: Array = []
	for e: Dictionary in ab["effects"]:
		if e["type"] == "dispel":
			types = e["dispel_types"]
	var want: String = "buff" if u["team"] != me["team"] else "debuff"
	for a: Dictionary in u["auras"]:
		var d: Dictionary = Data.auras.get(a["id"], {})
		if d.get("kind", "") == want and d.get("dispel_type", "") in types:
			if major_only and want == "buff" and not str(d.get("hud_priority", "")).begins_with("major"):
				continue
			return true
	return false


func _cc_allowed(me: Dictionary, ab: Dictionary) -> bool:
	var allowed: Array = ab.get("usable_while_cc", [])
	for a: Dictionary in me["auras"]:
		var cat: String = Data.auras.get(a["id"], {}).get("cc_category", "none")
		if cat in ["stun", "incapacitate", "disorient"] and not cat in allowed:
			return false
	return true


# ------------------------------------------------------------------ movement

func _movement_goal(view: Dictionary, me: Dictionary, target: Dictionary, enemies: Array, allies: Array) -> Vector3:
	var b: Dictionary = profile["behavior"]
	var pos: Vector3 = me["position"]
	# hide behind a pillar when low, but only when it can help (see _hiding_helps), and never for
	# longer than HIDE_MAX_S at a time, so two bots cannot hide from each other for the whole match
	var tick: int = view["tick"]
	var threats: Array = _threats(me, enemies)
	var want_hide: bool = b.has("break_los_below_pct") and _pct(me) < float(b["break_los_below_pct"]) \
		and tick >= _hide_blocked_until and not threats.is_empty() and _has_healer(allies)
	if want_hide:
		if _hide_since < 0:
			_hide_since = tick
		if tick - _hide_since > int(HIDE_MAX_S * 60):
			_hide_since = -1
			_hide_blocked_until = tick + int(HIDE_COOLDOWN_S * 60)
		else:
			var hide: Variant = _hide_spot(pos, threats)
			if hide != null:
				return hide
	else:
		_hide_since = -1
	# healers stay near the ally who needs them
	if b.has("stay_near_allies_m"):
		var ally: Dictionary = _lowest(allies)
		if ally["id"] != me["id"] and (_dist(me, ally) > float(b["stay_near_allies_m"]) or not _sees(me, ally)):
			return ally["position"]
	# casters back away from melee: always from a free one close in, and from a controlled one
	# until they reach kite distance (root, back off, then cast)
	if b.get("kite_melee", false):
		var kite_d: float = float(b.get("kite_distance_m", 8.0))
		for e: Dictionary in enemies:
			if Data.specs.get(e["spec"], {}).get("range", "") != "melee":
				continue
			var d_e: float = _dist(me, e)
			if d_e < 7.0 or (d_e < kite_d and _has_cc(e, ["root", "stun", "incapacitate", "disorient"])):
				return _kite_point(pos, e["position"])
	var lo: float = float(b["preferred_range_m"][0])
	var hi: float = float(b["preferred_range_m"][1])
	var d: float = _dist(me, target)
	if d > hi or not _sees(me, target):
		return target["position"]
	if d < lo:
		return _kite_point(pos, target["position"])
	return pos


func _reset_progress(pos: Vector3, tick: int) -> void:
	_progress_pos = pos
	_progress_tick = tick


## Enemies worth breaking line of sight from: those who see the bot and attack from range, or a
## melee enemy still more than MELEE_CLOSE_M from a ranged bot (a pillar denies its charge). A
## melee enemy on a melee bot just follows round the pillar, so it is not one.
func _threats(me: Dictionary, enemies: Array) -> Array:
	var i_am_ranged: bool = Data.specs.get(me["spec"], {}).get("range", "") != "melee"
	return enemies.filter(func(e: Dictionary) -> bool:
		if not _sees(e, me):
			return false
		if Data.specs.get(e["spec"], {}).get("range", "") != "melee":
			return true
		return i_am_ranged and _dist(me, e) > MELEE_CLOSE_M)


## Hiding only buys time: it helps while a living healer (an ally, or the bot itself) can heal
## the bot out of the enemies' sight.
static func _has_healer(allies: Array) -> bool:
	for a: Dictionary in allies:
		if Data.specs.get(a["spec"], {}).get("role", "") == "healer":
			return true
	return false


## Where to run from a melee threat: the most open direction that still gains distance, so a
## kiting bot circles through the arena instead of backing into a wall or corner.
func _kite_point(pos: Vector3, threat: Vector3) -> Vector3:
	var away: Vector3 = pos - threat
	away.y = 0.0
	if away.length() < 0.01:
		away = Vector3(0, 0, 1)
	away = away.normalized()
	# if every direction is blocked (a corner), head for the middle of the arena
	var to_mid: Vector3 = Vector3(-pos.x, 0.0, -pos.z)
	var best: Vector3 = pos + (to_mid.normalized() if to_mid.length() > 0.01 else away) * KITE_STEP_M
	var best_score: float = -INF
	for deg: float in [0.0, 35.0, -35.0, 70.0, -70.0, 105.0, -105.0]:
		var dir: Vector3 = away.rotated(Vector3.UP, deg_to_rad(deg))
		var p: Vector3 = pos + dir * KITE_STEP_M
		if geometry and geometry.resolve(p).distance_to(p) > 0.05:
			continue  # would walk into a wall or pillar
		var gain: float = Vector2(p.x - threat.x, p.z - threat.z).length() - Vector2(pos.x - threat.x, pos.z - threat.z).length()
		var score: float = gain + 1.5 * minf(_clearance(p), 6.0)
		if score > best_score:
			best_score = score
			best = p
	return best


## Distance from a point to the nearest arena edge or obstacle, in metres.
func _clearance(p: Vector3) -> float:
	if geometry == null:
		return 10.0
	var c: float = geometry.bounds_half - maxf(absf(p.x), absf(p.z))
	var q: Vector2 = Vector2(p.x, p.z)
	for circ: Dictionary in geometry.circles:
		c = minf(c, q.distance_to(circ["center"]) - float(circ["radius"]))
	for b: Dictionary in geometry.boxes:
		if b["gate"] and geometry.gates_open:
			continue
		var dx: float = maxf(maxf(b["min"].x - q.x, q.x - b["max"].x), 0.0)
		var dz: float = maxf(maxf(b["min"].y - q.y, q.y - b["max"].y), 0.0)
		c = minf(c, Vector2(dx, dz).length())
	return c


## The next point to walk toward on the way to `goal`, going around obstacles.
func _steer_point(pos: Vector3, goal: Vector3, tick: int) -> Vector3:
	if nav == null:
		return goal
	if geometry.gates_open != _gates_open_seen:
		_gates_open_seen = geometry.gates_open
		nav.rebuild()
		_path.clear()
	# stuck: wanted to move for half a second and barely did; plan again from here
	if pos.distance_to(_progress_pos) > 0.5:
		_progress_pos = pos
		_progress_tick = tick
	elif tick - _progress_tick > 30 and pos.distance_to(goal) > 1.0:
		_path.clear()
		_progress_tick = tick
		stuck_count += 1
		if explain:
			stuck_log.append({"tick": tick, "pos": [snappedf(pos.x, 0.1), snappedf(pos.z, 0.1)],
				"goal": [snappedf(goal.x, 0.1), snappedf(goal.z, 0.1)]})
	if _path.is_empty() or goal.distance_to(_path_goal) > 1.5 or tick - _path_tick > 30:
		_path = nav.path(pos, goal)
		_path_goal = goal
		_path_tick = tick
	# skip ahead only when the next leg is walkable from here (near a corner it may not be)
	while _path.size() > 1 and (Vector2(pos.x, pos.z).distance_to(Vector2(_path[0].x, _path[0].z)) < 0.15
			or nav.walkable(pos, _path[1])):
		_path.pop_front()
	return _path[0] if not _path.is_empty() else goal


## The spot behind a line-of-sight blocker that the fewest threats can see (then the nearest),
## or null when there is no blocker.
func _hide_spot(pos: Vector3, threats: Array) -> Variant:
	if geometry == null:
		return null
	var best: Variant = null
	var best_score: float = INF
	for c: Dictionary in geometry.circles:
		if not c["los"]:
			continue
		var centre: Vector3 = Vector3(c["center"].x, 0, c["center"].y)
		for t: Dictionary in threats:
			var dir: Vector3 = centre - Vector3(t["position"].x, 0, t["position"].z)
			if dir.length() < 0.01:
				continue
			var spot: Vector3 = centre + dir.normalized() * (float(c["radius"]) + 1.0)
			var seen: int = 0
			for u: Dictionary in threats:
				if geometry.has_line_of_sight(u["position"] + Vector3.UP * Combat.EYE_HEIGHT,
						spot + Vector3.UP * Combat.CHEST_HEIGHT):
					seen += 1
			var score: float = seen * 1000.0 + pos.distance_to(spot)
			if score < best_score:
				best_score = score
				best = spot
	return best


# ------------------------------------------------------------------ helpers

func _sees(a: Dictionary, b: Dictionary) -> bool:
	if geometry == null or a["id"] == b["id"]:
		return true
	return geometry.has_line_of_sight(a["position"] + Vector3.UP * Combat.EYE_HEIGHT,
		b["position"] + Vector3.UP * Combat.CHEST_HEIGHT)


static func _find(units: Array, id: int) -> Dictionary:
	for u: Dictionary in units:
		if u["id"] == id:
			return u
	return {}


static func _pos_of(view: Dictionary, id: int) -> Vector3:
	var u: Dictionary = _find(view["units"], id)
	return u["position"] if not u.is_empty() else view["me"]["position"]


static func _yaw_to(from: Vector3, to: Vector3) -> float:
	var d: Vector3 = to - from
	return atan2(-d.x, -d.z) if Vector2(d.x, d.z).length() > 0.01 else 0.0


static func _dist(a: Dictionary, b: Dictionary) -> float:
	return Vector2(a["position"].x, a["position"].z).distance_to(Vector2(b["position"].x, b["position"].z))


static func _pct(u: Dictionary) -> float:
	return 100.0 * float(u["health"]) / maxf(1.0, float(u["max_health"]))


static func _lowest(units: Array) -> Dictionary:
	var best: Dictionary = units[0]
	for u: Dictionary in units:
		if _pct(u) < _pct(best):
			best = u
	return best


static func _nearest(me: Dictionary, units: Array) -> Dictionary:
	var best: Dictionary = units[0]
	for u: Dictionary in units:
		if _dist(me, u) < _dist(me, best):
			best = u
	return best


## How many times this category has already diminished on the unit (0 = full duration).
static func _dr_count(u: Dictionary, cat: String, tick: int) -> int:
	var d: Dictionary = u.get("dr", {}).get(cat, {})
	if d.is_empty() or tick >= int(d["reset_tick"]):
		return 0
	return int(d["count"])


static func _is_immune(u: Dictionary) -> bool:
	for a: Dictionary in u["auras"]:
		if "damage" in Data.auras.get(a["id"], {}).get("immune", []):
			return true
	return false


static func _has_aura(u: Dictionary, id: String) -> bool:
	for a: Dictionary in u["auras"]:
		if a["id"] == id:
			return true
	return false


static func _has_cc(u: Dictionary, cats: Array) -> bool:
	for a: Dictionary in u["auras"]:
		if Data.auras.get(a["id"], {}).get("cc_category", "none") in cats:
			return true
	return false
