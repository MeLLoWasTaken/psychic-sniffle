class_name Replay
extends RefCounted
## Rebuild a match from its input log and check the result (backlog M1-29).
##
## A new MatchRunner is made from the log's header; before each tick the edits recorded between
## ticks (units joining or leaving, the preparation hold) are applied, and during the tick the
## recorded inputs are applied in their recorded order in place of the players and bots, then
## combat and the match rules run as they did in the match, then the recorded respawns. The
## result must equal the recorded final state hash; any difference means the simulation is not
## deterministic (or the log is not the log of this build's rules).


## {"ok", "hash", "expected", "ticks", "entries", "first_divergence"(when a trace was given)}
static func run(log: InputLog) -> Dictionary:
	var h: Dictionary = log.header
	var map: Dictionary = Data.maps.get(str(h["map"]), {})
	if map.is_empty():
		return {"ok": false, "error": "unknown map %s" % h["map"]}
	var runner: MatchRunner = MatchRunner.new(map, str(h["mode"]), str(h["bracket"]), float(h["prep_s"]),
		int(h["seed"]))
	if runner.sim.tick_rate != int(h["tick_rate"]):
		return {"ok": false, "error": "tick rate %d, log has %d" % [runner.sim.tick_rate, h["tick_rate"]]}
	var entries: Array = log.entries
	var cursor: Array = [0]  # next entry (boxed so the systems below can advance it)
	var units_by_id: Callable = func(id: int) -> Unit: return runner.sim.units.get(id)

	var apply_between: Callable = func() -> void:
		while cursor[0] < entries.size():
			var e: Array = entries[cursor[0]]
			if int(e[0]) != runner.sim.tick or bool(e[1]):
				return
			match str(e[2]):
				"add":
					runner.add_unit(str(e[3][0]), int(e[3][1]))
				"leave":
					runner.remove_unit(int(e[3]))
				"hold":
					runner.hold_prep()
				"respawn":
					var ru: Unit = units_by_id.call(int(e[3][0]))
					if ru:
						runner.respawn_unit(ru, e[3][1])
				"in":
					var iu: Unit = units_by_id.call(int(e[3][0]))
					if iu:
						runner.apply_input(iu, e[3][1])
			cursor[0] += 1

	var apply_during: Callable = func(kinds: Array) -> void:
		while cursor[0] < entries.size():
			var e: Array = entries[cursor[0]]
			if int(e[0]) != runner.sim.tick or not bool(e[1]) or not (str(e[2]) in kinds):
				return
			var u: Unit = units_by_id.call(int(e[3][0]))
			if u:
				if str(e[2]) == "in":
					runner.apply_input(u, e[3][1])
				else:
					runner.respawn_unit(u, e[3][1])
			cursor[0] += 1

	runner.sim.add_system(func(_s: Sim, _i: Dictionary) -> void: apply_during.call(["in"]))
	runner.sim.add_system(runner.system_combat_and_rules)
	runner.sim.add_system(func(_s: Sim, _i: Dictionary) -> void:
		runner.take_events()
		apply_during.call(["respawn"]))
	while runner.sim.tick < log.final_tick:
		apply_between.call()
		runner.sim.step()
	apply_between.call()
	var got: String = runner.sim.state_hash()
	return {"ok": got == log.final_hash and cursor[0] == entries.size(), "hash": got, "expected": log.final_hash,
		"ticks": runner.sim.tick, "entries": entries.size(), "applied": cursor[0]}
