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
var _next_unit_id: int = 1
var _spawn_count: Dictionary = {0: 0, 1: 0}


func _init(p_map: Dictionary, p_mode: String = "skirmish", bracket: String = "2v2",
		prep_s: float = -1.0, seed_value: int = 1) -> void:
	map = p_map
	mode = p_mode
	sim = Sim.new(seed_value, Data.tick_rate())
	geometry = ArenaGeometry.from_map(map)
	movement = Movement.new(Data.tuning, geometry)
	combat = Combat.new(sim, Data.tuning, Data.abilities, Data.auras, Data.specs, Data.classes, geometry)
	if mode == "arena":
		var tuning: Dictionary = Data.tuning.duplicate(true)
		if prep_s >= 0.0:
			tuning["arena"]["prep_phase_s"] = prep_s
		arena = ArenaMatch.new(tuning, bracket, sim.tick_rate, geometry, sim.tick)
		combat.arena = arena


## Create a unit for a spec on a team at the team's next spawn point.
func add_unit(spec_id: String, team: int) -> Unit:
	var unit: Unit = Unit.new(_next_unit_id, team, spec_id)
	_next_unit_id += 1
	combat.init_unit(unit)
	var spawns: Array = map["spawns"]["team_a" if team == 0 else "team_b"]
	var sp: Array = spawns[int(_spawn_count[team]) % spawns.size()]
	_spawn_count[team] = int(_spawn_count[team]) + 1
	unit.position = Vector3(sp[0], sp[1], sp[2])
	unit.facing = -PI / 2 if team == 0 else PI / 2  # face the other team across the arena
	sim.add_unit(unit)
	return unit


func ended() -> bool:
	return arena != null and arena.phase == ArenaMatch.Phase.ENDED


## Apply one player input to a unit: movement (crowd control overrides it), targeting, and an
## ability press. Call from inside a simulation system, before combat runs.
func apply_input(unit: Unit, inp: Dictionary) -> void:
	if not unit.is_alive() or ended():
		return
	var forced: Dictionary = combat.forced_input(unit)
	var before: Vector3 = unit.position
	movement.apply(unit, forced if not forced.is_empty() else inp, sim.dt(), combat.speed_multiplier(unit))
	if Vector2(unit.position.x - before.x, unit.position.z - before.z).length() > 0.001:
		unit.moved_this_tick = true
	if inp.get("tab", false):
		unit.target_id = combat.tab_target(unit)
	var tid: int = int(inp.get("target", -1))
	var t: Unit = sim.units.get(tid)
	if t and t.team != unit.team and t.is_alive():
		unit.target_id = tid  # pressing an ability on an enemy (or clicking one) targets it
	if str(inp.get("ability", "")) != "":
		combat.press(unit, inp["ability"], tid)


## Combat and match rules for this tick. Register as the last simulation system.
func system_combat_and_rules(s: Sim, _inputs: Dictionary) -> void:
	combat.tick()
	if arena:
		arena.update(s.tick, s.units)


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
		return {"phase": ArenaMatch.Phase.ACTIVE, "start_tick": 0, "dampening_pct": 0, "winner": -1}
	return {"phase": arena.phase, "start_tick": arena.start_tick, "dampening_pct": arena.dampening_pct(sim.tick),
		"winner": arena.winner_team}


## The world as a bot sees it: the same shape a client builds from snapshots.
func view_for(unit: Unit) -> Dictionary:
	var units: Array = []
	for u: Unit in sim.units.values():
		units.append(unit_view(u))
	return {"tick": sim.tick, "tick_rate": sim.tick_rate, "me": unit_view(unit), "units": units,
		"gcd_ready_tick": unit.gcd_ready_tick, "cooldowns": unit.cooldowns.duplicate(),
		"school_locks": unit.school_locks.duplicate(),
		"match": match_state(), "map": map["id"]}


static func unit_view(u: Unit) -> Dictionary:
	return {"id": u.id, "team": u.team, "spec": u.spec_id, "position": u.position, "facing": u.facing,
		"health": u.health, "max_health": u.max_health, "target_id": u.target_id,
		"resource": float(u.resources.get(u.primary_resource, 0.0)),
		"resource_max": float(u.resource_max.get(u.primary_resource, 0.0)),
		"cast": u.cast.duplicate(), "auras": u.auras.duplicate(true), "dr": u.dr.duplicate(true)}
