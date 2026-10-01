class_name ArenaMatch
extends RefCounted
## Arena match rules (backlog M1-09): preparation phase behind closed gates, dampening, win
## when a team is fully dead, draw at the time limit. Numbers come from tuning.json "arena".
## Regeneration pickups (M2-07): in the brackets tuning names, the map's pickup spots light up
## once, pickup_spawn_s after the gates open; the first living player within the radius takes
## one (lowest unit id on a tie). The caller applies its effects (take_pickups).

enum Phase { PREP, ACTIVE, ENDED }

var phase: Phase = Phase.PREP
var bracket: String = "2v2"
var tick_rate: int = 60
var start_tick: int = 0  ## tick the gates opened (or will open)
var prep_ticks: int
var dampening_start_ticks: int
var dampening_step: float
var dampening_interval_ticks: int
var time_limit_ticks: int
var winner_team: int = -1  ## -1 while running; -2 for a draw
var geometry: ArenaGeometry
var events: Array[Dictionary] = []
var pickups: Array[Dictionary] = []  ## {"pos": Vector3, "active": bool}
var pickup_ticks: int = -1  ## match ticks until they light up; -1 when this bracket has none
var pickup_radius: float = 1.5
var pickup_effects: Array = []
var _pickups_spawned: bool = false
var _taken: Array[Dictionary] = []  ## {"unit", "pickup"} since the last take_pickups()
var twists: Array = []  ## the map's twists (ArenaTwists), happening on match time
var twist_stages: Array[int] = []  ## each twist's last announced stage (ArenaTwists.Stage)


func _init(tuning: Dictionary, p_bracket: String, p_tick_rate: int, p_geometry: ArenaGeometry,
		now_tick: int = 0, pickup_spots: Array = [], p_twists: Array = []) -> void:
	var a: Dictionary = tuning["arena"]
	bracket = p_bracket
	tick_rate = p_tick_rate
	geometry = p_geometry
	prep_ticks = roundi(float(a["prep_phase_s"]) * tick_rate)
	var damp_s: float = a["dampening_start_1v1_s"] if bracket == "1v1" else a["dampening_start_s"]
	dampening_start_ticks = roundi(float(damp_s) * tick_rate)
	dampening_step = float(a["dampening_step_pct"]) / 100.0
	dampening_interval_ticks = roundi(float(a["dampening_interval_s"]) * tick_rate)
	var limit_s: float = a["time_limit_1v1_s"] if bracket == "1v1" else a["time_limit_s"]
	time_limit_ticks = roundi(float(limit_s) * tick_rate)
	start_tick = now_tick + prep_ticks
	if bracket in a.get("pickup_brackets", []) and not pickup_spots.is_empty():
		pickup_ticks = roundi(float(a["pickup_spawn_s"]) * tick_rate)
		pickup_radius = float(a["pickup_radius_m"])
		pickup_effects = a["pickup_effects"]
		for sp: Array in pickup_spots:
			pickups.append({"pos": Vector3(sp[0], sp[1], sp[2]), "active": false})
	twists = p_twists
	for t: Dictionary in twists:
		twist_stages.append(ArenaTwists.Stage.WAITING)
	if geometry:
		geometry.gates_open = false


## Keep the preparation countdown from running (a server waiting for its full roster, M1-28):
## the gates open a full preparation phase after the last call. No effect once the gates are open.
func hold_prep(tick: int) -> void:
	if phase == Phase.PREP:
		start_tick = tick + prep_ticks


## Seconds of match time since the gates opened (negative during preparation).
func match_seconds(tick: int) -> float:
	return float(tick - start_tick) / tick_rate


## Healing multiplier from dampening: 1.0 until the start, then down 1% every interval.
func healing_multiplier(tick: int) -> float:
	var since: int = tick - start_tick - dampening_start_ticks
	if phase != Phase.ACTIVE or since < 0:
		return 1.0
	var steps: int = since / dampening_interval_ticks + 1
	return maxf(0.0, 1.0 - steps * dampening_step)


func dampening_pct(tick: int) -> int:
	return roundi((1.0 - healing_multiplier(tick)) * 100.0)


## Advance the rules one tick. Call after combat has run.
func update(tick: int, units: Dictionary) -> void:
	match phase:
		Phase.PREP:
			if tick >= start_tick:
				phase = Phase.ACTIVE
				if geometry:
					geometry.gates_open = true
				events.append({"tick": tick, "type": "gates_open"})
		Phase.ACTIVE:
			var alive: Dictionary = {}
			var teams: Dictionary = {}
			for u: Unit in units.values():
				teams[u.team] = true
				if u.is_alive():
					alive[u.team] = true
			if teams.size() >= 2 and alive.size() <= 1:
				winner_team = alive.keys()[0] if alive.size() == 1 else -2
				_end(tick, "team_eliminated")
			elif tick - start_tick >= time_limit_ticks:
				winner_team = -2
				_end(tick, "time_limit")
			if phase == Phase.ACTIVE:
				_update_pickups(tick, units)
				_update_twists(tick)


func _update_pickups(tick: int, units: Dictionary) -> void:
	if pickup_ticks < 0:
		return
	if not _pickups_spawned and tick - start_tick >= pickup_ticks:
		_pickups_spawned = true
		for p: Dictionary in pickups:
			p["active"] = true
		events.append({"tick": tick, "type": "pickup_spawned", "count": pickups.size()})
	var ids: Array = units.keys()
	ids.sort()
	for i: int in pickups.size():
		var p: Dictionary = pickups[i]
		if not p["active"]:
			continue
		var best: Unit = null
		var best_d: float = INF
		for id: int in ids:
			var u: Unit = units[id]
			var d: float = Vector2(u.position.x - p["pos"].x, u.position.z - p["pos"].z).length()
			if u.is_alive() and d <= pickup_radius and d < best_d:
				best = u
				best_d = d
		if best != null:
			p["active"] = false
			_taken.append({"unit": best.id, "pickup": i})
			events.append({"tick": tick, "type": "pickup_taken", "target": best.id, "pickup": i})


## Announce each twist's warning and its moment as match time reaches them, and take away the
## colliders a collapse removes. The geometry follows match time, so it holds for any tick.
func _update_twists(tick: int) -> void:
	if twists.is_empty():
		return
	var s: float = match_seconds(tick)
	for i: int in twists.size():
		var st: int = ArenaTwists.stage(twists[i], s)
		while twist_stages[i] < st:
			twist_stages[i] += 1
			var t: Dictionary = twists[i]
			var warned: bool = twist_stages[i] == ArenaTwists.Stage.WARNED
			if warned and float(t.get("warn_s", 0.0)) <= 0.0:
				continue  # no warning time, no warning
			events.append({"tick": tick, "type": "twist_warning" if warned else "twist", "twist": str(t.get("id", i)),
				"text": str(t.get("warn_text" if warned else "text", "")), "sound": str(t.get("warn_sound" if warned else "sound", ""))})
	if geometry:
		geometry.removed_tags = ArenaTwists.removed_tags(twists, s)


## Pickups taken since the last call, [{"unit", "pickup"}]; the caller applies pickup_effects.
func take_pickups() -> Array[Dictionary]:
	var out: Array[Dictionary] = _taken.duplicate()
	_taken.clear()
	return out


## Active pickups as bits (bit i = spot i), for snapshots.
func pickup_mask() -> int:
	var m: int = 0
	for i: int in pickups.size():
		if pickups[i]["active"]:
			m |= 1 << i
	return m


func _end(tick: int, reason: String) -> void:
	phase = Phase.ENDED
	events.append({"tick": tick, "type": "match_end", "winner": winner_team, "reason": reason})
