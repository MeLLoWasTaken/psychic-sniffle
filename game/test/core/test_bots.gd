extends GdUnitTestSuite
## Bot AI and navigation (backlog M1-13).

const MAP: String = "gallows_courtyard"


func _runner(seed_value: int = 7) -> MatchRunner:
	return MatchRunner.new(Data.maps[MAP], "arena", "2v2", 0.0, seed_value)


## Run a bot match in-process; returns [runner, seconds]. Clears the runner's systems at the end
## so the runner and its closures do not keep each other alive.
func _play(specs_a: Array, specs_b: Array, seed_value: int, max_s: float) -> Dictionary:
	var runner: MatchRunner = _runner(seed_value)
	var nav: NavGrid = NavGrid.new(runner.geometry)
	var brains: Dictionary = {}
	for team: int in 2:
		for spec: String in (specs_a if team == 0 else specs_b):
			var u: Unit = runner.add_unit(spec, team)
			brains[u.id] = BotBrain.new(spec, seed_value * 100 + u.id, runner.geometry, nav)
	var feed: Callable = func(_s: Sim, _inputs: Dictionary) -> void:
		for uid: int in brains:
			var u: Unit = runner.sim.units[uid]
			runner.apply_input(u, brains[uid].next_input(runner.view_for(u)))
	runner.sim.add_system(feed)
	runner.sim.add_system(runner.system_combat_and_rules)
	var limit: int = roundi(max_s * runner.sim.tick_rate)
	while runner.sim.tick < limit and not runner.ended():
		runner.sim.step()
		runner.take_events()
	var out: Dictionary = {"ended": runner.ended(), "winner": runner.arena.winner_team,
		"hash": runner.sim.state_hash(), "tick": runner.sim.tick}
	runner.sim._systems.clear()
	return out


func test_nav_path_goes_around_the_central_block() -> void:
	var runner: MatchRunner = _runner()
	runner.geometry.gates_open = true
	var nav: NavGrid = NavGrid.new(runner.geometry)
	var from: Vector3 = Vector3(-6, 0, 0)
	var to: Vector3 = Vector3(6, 0, 0)
	var path: Array[Vector3] = nav.path(from, to)
	assert_int(path.size()).is_greater(1)  # the straight line crosses the central box
	assert_vector(path[-1]).is_equal(to)
	var prev: Vector3 = from
	for p: Vector3 in path:
		assert_bool(runner.geometry.has_line_of_sight(prev + Vector3.UP, p + Vector3.UP)).is_true()
		prev = p


func test_nav_straight_line_when_clear() -> void:
	var runner: MatchRunner = _runner()
	var nav: NavGrid = NavGrid.new(runner.geometry)
	var path: Array[Vector3] = nav.path(Vector3(-3, 0, 10), Vector3(3, 0, 10))
	assert_int(path.size()).is_equal(1)


func test_closed_gates_block_paths_until_rebuilt() -> void:
	var runner: MatchRunner = _runner()
	runner.geometry.gates_open = false
	var nav: NavGrid = NavGrid.new(runner.geometry)
	var inside: Vector3 = Vector3(-17, 0, 0)
	assert_bool(nav._clear(inside, Vector3(-10, 0, 0))).is_false()
	runner.geometry.gates_open = true
	nav.rebuild()
	assert_bool(nav._clear(inside, Vector3(-10, 0, 0))).is_true()


func test_bots_idle_before_the_match_starts() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps[MAP], "arena", "2v2", 30.0, 1)
	var u: Unit = runner.add_unit("warblade_carnage", 0)
	runner.add_unit("arcanist_rime", 1)
	var brain: BotBrain = BotBrain.new("warblade_carnage", 1, runner.geometry)
	var inp: Dictionary = brain.next_input(runner.view_for(u))
	assert_str(inp["ability"]).is_equal("")
	assert_vector(inp["move"]).is_equal(Vector2.ZERO)


func test_every_complete_spec_has_a_bot_profile_using_its_kit() -> void:
	for spec_id: String in Data.specs:
		if Data.specs[spec_id].get("kit_status", "") != "complete":
			continue
		assert_bool(Data.bots.has(spec_id)).is_true()


func test_bot_match_ends_by_a_kill_and_is_deterministic() -> void:
	var a: Dictionary = _play(["warblade_carnage", "oracle_grace"], ["arcanist_rime", "oracle_grace"], 3, 600.0)
	assert_bool(a["ended"]).is_true()
	assert_int(a["winner"]).is_not_equal(-1)
	var b: Dictionary = _play(["warblade_carnage", "oracle_grace"], ["arcanist_rime", "oracle_grace"], 3, 600.0)
	assert_int(b["tick"]).is_equal(a["tick"])
	assert_str(b["hash"]).is_equal(a["hash"])
