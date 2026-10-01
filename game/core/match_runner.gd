class_name MatchRunner
extends RefCounted
## One match's rules and state, shared by the networked server and the in-process batch
## simulator (tools/batch_sim.gd), so both behave identically.
##
## Owns the simulation, arena geometry, movement, combat and (in arena mode) the match rules.
## Callers feed inputs with apply_input() from inside a simulation system, then step the sim.

var sim: Sim
var map: Dictionary
var mode: String
var geometry: ArenaGeometry
var movement: Movement
var combat: Combat
var arena: ArenaMatch
var input_log: InputLog = null  ## set by record(): every input and world edit (M1-29)
var _next_unit_id: int = 1
var _spawn_count: Dictionary = {0: 0, 1: 0}
var _header: Dictionary = {}  ## what Replay needs to rebuild this match


func _init(p_map: Dictionary, p_mode: String = "skirmish", bracket: String = "2v2",
		prep_s: float = -1.0, seed_value: int = 1) -> void:
	map = p_map
	mode = p_mode
	sim = Sim.new(seed_value, Data.tick_rate())
	geometry = ArenaGeometry.from_map(map)
	movement = Movement.new(Data.tuning, geometry)
	combat = Combat.new(sim, Data.tuning, Data.abilities, Data.auras, Data.specs, Data.classes, geometry)
	combat.talent_trees = Data.talents
	if mode == "arena":
		var tuning: Dictionary = Data.tuning.duplicate(true)
		if prep_s >= 0.0:
			tuning["arena"]["prep_phase_s"] = prep_s
		arena = ArenaMatch.new(tuning, bracket, sim.tick_rate, geometry, sim.tick, map.get("pickups", []),
			map.get("twists", []))
		combat.arena = arena
	_header = {"map": map["id"], "mode": mode, "bracket": bracket, "prep_s": prep_s, "seed": seed_value,
		"tick_rate": sim.tick_rate}


## Start recording this match's input log (call before the first unit is added).
func record() -> InputLog:
	input_log = InputLog.new()
	input_log.header = _header.duplicate()
	return input_log


func _log(kind: String, payload: Variant) -> void:
	if input_log:
		input_log.add(sim.tick, sim.stepping, kind, payload)


## Create a unit for a spec on a team at the team's next spawn point, with a talent loadout in
## its shared text form (Talents.encode; "" for none). Check the text first with talent_error().
func add_unit(spec_id: String, team: int, talents: String = "", prefs: Dictionary = {}) -> Unit:
	_log("add", [spec_id, team, talents, prefs.duplicate()])
	var unit: Unit = Unit.new(_next_unit_id, team, spec_id)
	_next_unit_id += 1
	unit.loadout = loadout_from(spec_id, talents)
	_apply_prefs(unit, prefs)
	combat.init_unit(unit)
	var spawns: Array = map["spawns"]["team_a" if team == 0 else "team_b"]
	var sp: Array = spawns[int(_spawn_count[team]) % spawns.size()]
	_spawn_count[team] = int(_spawn_count[team]) + 1
	unit.position = Vector3(sp[0], sp[1], sp[2])
	unit.facing = -PI / 2 if team == 0 else PI / 2  # face the other team across the arena
	sim.add_unit(unit)
	return unit


## A player's gameplay settings that the rules use (M2-13): {"spell_queue_ms", "auto_self_cast"}.
## Allowed at any time; recorded for replays.
func set_prefs(unit: Unit, prefs: Dictionary) -> void:
	_log("prefs", [unit.id, prefs.duplicate()])
	_apply_prefs(unit, prefs)


func _apply_prefs(unit: Unit, prefs: Dictionary) -> void:
	if prefs.has("spell_queue_ms"):
		var ms: int = clampi(int(prefs["spell_queue_ms"]), 0, int(Data.tuning["pacing"]["spell_queue_window_ms"]))
		unit.queue_window_ticks = roundi(ms / 1000.0 * sim.tick_rate)
	if prefs.has("auto_self_cast"):
		unit.auto_self_cast = bool(prefs["auto_self_cast"])


## Why a talent string cannot be used for a spec, or "" when it can.
func talent_error(spec_id: String, talents: String) -> String:
	var trees: Dictionary = Talents.trees_for(spec_id, Data.specs, Data.classes, Data.talents)
	var d: Dictionary = Talents.decode(talents, trees)
	return d["error"] if d["error"] != "" else Talents.check(d["loadout"], trees)


func loadout_from(spec_id: String, talents: String) -> Dictionary:
	if talent_error(spec_id, talents) != "":
		return Talents.empty()
	return Talents.decode(talents, Talents.trees_for(spec_id, Data.specs, Data.classes, Data.talents))["loadout"]


## Change a unit's talents. Allowed until the arena gates open (docs/DESIGN.md: talents lock when
## the gates open); returns "" or why not.
func set_talents(unit: Unit, talents: String) -> String:
	if arena and arena.phase != ArenaMatch.Phase.PREP:
		return "talents_locked"
	var err: String = talent_error(unit.spec_id, talents)
	if err != "":
		return err
	_log("talents", [unit.id, talents])
	unit.loadout = loadout_from(unit.spec_id, talents)
	combat.init_unit(unit)
	return ""


func ended() -> bool:
	return arena != null and arena.phase == ArenaMatch.Phase.ENDED


## Apply one player input to a unit: movement (crowd control overrides it), targeting, and an
## ability press. Call from inside a simulation system, before combat runs.
func apply_input(unit: Unit, inp: Dictionary) -> void:
	_log("in", [unit.id, inp.duplicate(true)])
	if not unit.is_alive() or ended():
		return
	var forced: Dictionary = combat.forced_input(unit)
	var before: Vector3 = unit.position
	movement.apply(unit, forced if not forced.is_empty() else inp, sim.dt(), combat.speed_multiplier(unit))
	if Vector2(unit.position.x - before.x, unit.position.z - before.z).length() > 0.001:
		unit.moved_this_tick = true
	if inp.get("clear_target", false):
		unit.target_id = -1  # the player cleared their target or selected an ally (stops auto-attack)
	if inp.get("tab", false):
		unit.target_id = combat.tab_target(unit)
	var tid: int = int(inp.get("target", -1))
	var t: Unit = sim.units.get(tid)
	if t and t.team != unit.team and t.is_alive():
		unit.target_id = tid  # pressing an ability on an enemy (or clicking one) targets it
	if str(inp.get("ability", "")) != "":
		# a keybind's target mode (focus, mouseover, self, arena 1 to 3) casts on that unit without
		# changing the target; otherwise the ability goes to the target
		var atid: int = int(inp.get("ability_target", -1))
		combat.press(unit, inp["ability"], atid if atid >= 0 else tid)


## Hold the arena in preparation (the countdown restarts) while players are still joining.
func hold_prep() -> void:
	if arena:
		_log("hold", null)
		arena.hold_prep(sim.tick)


## A unit leaves the world (a player disconnected outside arena mode).
func remove_unit(unit_id: int) -> void:
	_log("leave", unit_id)
	sim.units.erase(unit_id)


## Bring a dead unit back at full health at a position (skirmish respawns).
func respawn_unit(unit: Unit, pos: Vector3) -> void:
	_log("respawn", [unit.id, pos])
	combat.init_unit(unit)
	unit.target_id = -1
	unit.position = pos


## A simulation system that drives bots: every bot decides from the same start-of-tick world,
## then the inputs are applied in this tick's turn order (see Sim.turn_order), so no bot sees
## another's move from the same tick and no team always moves first.
## `brains` maps unit id -> BotBrain. Register before system_combat_and_rules.
func bot_system(brains: Dictionary) -> Callable:
	return func(s: Sim, _inputs: Dictionary) -> void:
		var decided: Dictionary = {}
		for uid: int in brains:
			var u: Unit = s.units.get(uid)
			if u:
				decided[uid] = brains[uid].next_input(view_for(u))
		for u: Unit in s.turn_order():
			if decided.has(u.id):
				apply_input(u, decided[u.id])


## Combat and match rules for this tick. Register as the last simulation system.
func system_combat_and_rules(s: Sim, _inputs: Dictionary) -> void:
	combat.tick()
	if arena:
		arena.update(s.tick, s.units)
		for t: Dictionary in arena.take_pickups():
			var u: Unit = s.units.get(int(t["unit"]))
			if u:
				combat.apply_world_effects(u, arena.pickup_effects, "arena_pickup")


## Combat log and match events produced since the last call.
func take_events() -> Array:
	var evs: Array = combat.events.duplicate()
	combat.events.clear()
	if arena:
		evs.append_array(arena.events)
		arena.events.clear()
	return evs


func match_state() -> Dictionary:
	if arena == null:
		return {"phase": ArenaMatch.Phase.ACTIVE, "start_tick": 0, "dampening_pct": 0, "winner": -1, "pickups": 0}
	return {"phase": arena.phase, "start_tick": arena.start_tick, "dampening_pct": arena.dampening_pct(sim.tick),
		"winner": arena.winner_team, "pickups": arena.pickup_mask()}


## The world as a bot sees it: the same shape a client builds from snapshots.
func view_for(unit: Unit) -> Dictionary:
	var units: Array = []
	for u: Unit in sim.units.values():
		units.append(unit_view(u))
	return {"tick": sim.tick, "tick_rate": sim.tick_rate, "me": unit_view(unit), "units": units,
		"gcd_ready_tick": unit.gcd_ready_tick, "cooldowns": unit.cooldowns.duplicate(),
		"school_locks": unit.school_locks.duplicate(), "known": unit.known_abilities.duplicate(),
		"talent_abilities": unit.talent_abilities,
		"match": match_state(), "map": map["id"]}


static func unit_view(u: Unit) -> Dictionary:
	return {"id": u.id, "team": u.team, "spec": u.spec_id, "position": u.position, "facing": u.facing,
		"health": u.health, "max_health": u.max_health, "target_id": u.target_id,
		"resource": float(u.resources.get(u.primary_resource, 0.0)),
		"resource_max": float(u.resource_max.get(u.primary_resource, 0.0)),
		"cast": u.cast.duplicate(), "auras": u.auras.duplicate(true), "dr": u.dr.duplicate(true)}
