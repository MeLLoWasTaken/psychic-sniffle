extends GdUnitTestSuite
## Backlog M1-29: every match records its input log, and replaying it reproduces the same final
## state hash. Matches here run the real pipeline (MatchRunner with bot brains, as the batch
## simulator and the server do) with recording on; nothing edits the world behind the log's back.

const LOG_PATH: String = "user://test_replay.inputlog"


func _bot_match(seed_value: int, max_ticks: int, prep_s: float = 2.0) -> MatchRunner:
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", prep_s, seed_value)
	runner.record()
	var brains: Dictionary = {}
	var nav: NavGrid = NavGrid.new(runner.geometry)
	for pair: Array in [["warblade_carnage", 0], ["arcanist_rime", 1], ["oracle_grace", 0], ["oracle_grace", 1]]:
		var u: Unit = runner.add_unit(pair[0], pair[1])
		brains[u.id] = BotBrain.new(pair[0], seed_value * 100 + u.id, runner.geometry, nav)
	runner.sim.add_system(runner.bot_system(brains))
	runner.sim.add_system(runner.system_combat_and_rules)
	while runner.sim.tick < max_ticks and not runner.ended():
		runner.sim.step()
		runner.take_events()
	runner.input_log.finish(runner.sim)
	return runner


func test_bot_arena_match_replays_to_the_same_hash() -> void:
	var runner: MatchRunner = _bot_match(7, 60 * 90)
	var log: InputLog = runner.input_log
	assert_int(log.entries.size()).is_greater(1000)
	assert_str(log.final_hash).is_equal(runner.sim.state_hash())
	assert_int(log.save(LOG_PATH)).is_equal(OK)
	var loaded: InputLog = InputLog.load_file(LOG_PATH)
	assert_object(loaded).is_not_null()
	var r: Dictionary = Replay.run(loaded)
	assert_bool(r["ok"]).override_failure_message(str(r)).is_true()
	assert_int(r["ticks"]).is_equal(runner.sim.tick)
	assert_int(r["applied"]).is_equal(log.entries.size())


func test_a_changed_input_changes_the_result() -> void:
	var runner: MatchRunner = _bot_match(11, 60 * 40)
	var log: InputLog = runner.input_log
	# the first ability press after the gates open goes to a different ability
	var changed: bool = false
	for e: Array in log.entries:
		if str(e[2]) == "in" and str(e[3][1].get("ability", "")) != "" and int(e[0]) > 150:
			e[3][1]["ability"] = ""
			e[3][1]["move"] = Vector2(1, 0)
			changed = true
			break
	assert_bool(changed).is_true()
	var r: Dictionary = Replay.run(log)
	assert_bool(r["ok"]).is_false()
	assert_str(r["hash"]).is_not_equal(log.final_hash)


func test_world_edits_join_hold_leave_and_respawn_replay() -> void:
	# a skirmish with the edits the server makes: late joins, a leave, a respawn; and an arena hold
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "skirmish", "2v2", -1.0, 3)
	runner.record()
	var a: Unit = runner.add_unit("warblade_carnage", 0)
	var b: Unit = null
	runner.sim.add_system(func(s: Sim, _i: Dictionary) -> void:
		for u: Unit in s.turn_order():
			runner.apply_input(u, {"move": Vector2(0, 1), "turn": 0.01 * u.id, "seq": s.tick}))
	runner.sim.add_system(runner.system_combat_and_rules)
	for t: int in 600:
		if t == 60:
			b = runner.add_unit("arcanist_rime", 1)
		if t == 200:
			runner.add_unit("oracle_grace", 0)
		if t == 301:
			runner.respawn_unit(b, Vector3(3, 0, 4))
		if t == 400:
			runner.remove_unit(a.id)
		runner.sim.step()
	runner.input_log.finish(runner.sim)
	var r: Dictionary = Replay.run(runner.input_log)
	assert_bool(r["ok"]).override_failure_message(str(r)).is_true()
	var arena: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 1.0, 4)
	arena.record()
	arena.add_unit("warblade_carnage", 0)
	arena.sim.add_system(arena.system_combat_and_rules)
	for t: int in 200:
		if t < 90:
			arena.hold_prep()
		arena.sim.step()
	arena.input_log.finish(arena.sim)
	assert_bool(Replay.run(arena.input_log)["ok"]).is_true()


func test_floats_survive_the_file_exactly() -> void:
	var log: InputLog = InputLog.new()
	log.header = {"map": "gallows_courtyard"}
	var v: Vector2 = Vector2(0.1 + 0.2, 1.0 / 3.0)
	log.add(5, true, "in", [1, {"move": v, "turn": PI / 7.0}])
	assert_int(log.save(LOG_PATH)).is_equal(OK)
	var back: InputLog = InputLog.load_file(LOG_PATH)
	var inp: Dictionary = back.entries[0][3][1]
	assert_bool(inp["move"] == v).is_true()
	assert_bool(float(inp["turn"]) == PI / 7.0).is_true()
