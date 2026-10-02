extends GdUnitTestSuite
## The rotate twist (backlog M2-10): Burning Foundry's casting wheel turns its two crucibles about
## the furnace from 2:30, pushing aside whoever stands in their way. Like every twist its state is
## a pure function of match time, so the server, the client's prediction, replays and the map's
## visuals all agree.

const TR: int = 60
const W: float = TAU / 50.0  ## one turn per 50 s


func _wheel() -> Dictionary:
	return Data.maps["burning_foundry"]["twists"][0]


func test_the_wheel_angle_follows_match_time() -> void:
	var t: Dictionary = _wheel()
	assert_float(ArenaTwists.rotation(t, -3.0)).is_equal(0.0)
	assert_float(ArenaTwists.rotation(t, 150.0)).is_equal(0.0)
	# speeding up evenly over 4 s: half way, a quarter of the spin-up's distance
	assert_float(ArenaTwists.rotation(t, 152.0)).is_equal_approx(W * 4.0 / 8.0, 1e-6)
	assert_float(ArenaTwists.rotation(t, 160.0)).is_equal_approx(W * 8.0, 1e-6)
	# a quarter turn after the spin-up: the north crucible (0, 9) stands west (-9, 0)
	var s: float = 150.0 + 2.0 + PI / 2.0 / W
	assert_vector(ArenaTwists.rotated(t, Vector2(0, 9), s)).is_equal_approx(Vector2(-9, 0), Vector2(1e-4, 1e-4))


func test_the_crucibles_move_cover_and_push_whoever_is_in_the_way() -> void:
	var map: Dictionary = Data.maps["burning_foundry"]
	var geo: ArenaGeometry = ArenaGeometry.from_map(map)
	var mv: Movement = Movement.new(Data.tuning, geo)
	var twists: Array = map["twists"]
	var west: Vector3 = Vector3(-6, Combat.EYE_HEIGHT, 9)
	var east: Vector3 = Vector3(6, Combat.EYE_HEIGHT, 9)
	geo.apply_twists(twists, 140.0)
	assert_bool(geo.has_line_of_sight(west, east)).override_failure_message("the crucible covers the north lane").is_false()
	# a player standing still on the ring just ahead of the north crucible
	var u: Unit = Unit.new(1, 0, "warblade_carnage")
	var start: Vector2 = Vector2(0, 9).rotated(0.4)
	u.position = Vector3(start.x, 0, start.y)
	var moved_max: float = 0.0
	var crucible: Dictionary = geo.circles.filter(func(c: Dictionary) -> bool: return c["home"] == Vector2(0, 9))[0]
	for tick: int in range(150 * TR, 170 * TR):
		geo.apply_twists(twists, float(tick) / TR)
		mv.apply(u, {"move": Vector2.ZERO, "yaw": 0.0}, 1.0 / TR)
		var gap: float = Vector2(u.position.x, u.position.z).distance_to(crucible["center"])
		assert_float(gap).override_failure_message("inside the crucible at tick %d" % tick).is_greater_equal(
			float(crucible["radius"]) + ArenaGeometry.UNIT_RADIUS - 1e-3)
		moved_max = maxf(moved_max, Vector2(u.position.x, u.position.z).distance_to(start))
	assert_bool(crucible["moving"]).is_true()
	assert_float(moved_max).override_failure_message("never pushed").is_greater(0.5)
	# the crucible went past: it is further round than where the player started
	assert_float(absf(crucible["center"].angle_to(Vector2(0, 9)))).is_greater(0.6)
	# the north lane is open now, and the cover stands somewhere else
	assert_bool(geo.has_line_of_sight(west, east)).is_true()


func test_the_wheel_turns_on_the_server_and_the_match_replays() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["burning_foundry"], "arena", "2v2", 1.0, 5)
	runner.record()
	runner.add_unit("warblade_carnage", 0)
	runner.add_unit("arcanist_rime", 1)
	runner.sim.add_system(runner.system_combat_and_rules)
	var events: Array = []
	var start: int = runner.arena.start_tick
	while runner.sim.tick <= start + 165 * TR:
		runner.sim.step()
		events.append_array(runner.arena.events)
		runner.arena.events.clear()
	var types: Array = events.filter(func(e: Dictionary) -> bool: return str(e.get("twist", "")) == "casting_wheel").map(
		func(e: Dictionary) -> Array: return [e["type"], int(e["tick"]) - start, e["sound"]])
	assert_array(types).is_equal([["twist_warning", 140 * TR, "foundry_gears"], ["twist", 150 * TR, "foundry_wheel"]])
	var north: Dictionary = runner.geometry.circles.filter(func(c: Dictionary) -> bool: return c["home"] == Vector2(0, 9))[0]
	# sim.tick is the next tick to run: the arena last updated the twists for the one before
	var expect: Vector2 = ArenaTwists.rotated(_wheel(), Vector2(0, 9), runner.arena.match_seconds(runner.sim.tick - 1))
	assert_vector(north["center"]).is_equal_approx(expect, Vector2(1e-4, 1e-4))
	runner.input_log.finish(runner.sim)
	var r: Dictionary = Replay.run(runner.input_log)
	assert_bool(r["ok"]).override_failure_message(str(r)).is_true()


func test_the_client_predicts_against_the_turned_crucibles() -> void:
	var c: NetClient = auto_free(NetClient.new())
	c.map_id = "burning_foundry"
	c.geometry = ArenaGeometry.from_map(Data.maps["burning_foundry"])
	c._match_phase = ArenaMatch.Phase.ACTIVE
	c._match_start_tick = 1000
	var tick: int = 1000 + 163 * TR
	c._apply_twists(tick)
	var north: Dictionary = c.geometry.circles.filter(func(x: Dictionary) -> bool: return x["home"] == Vector2(0, 9))[0]
	assert_vector(north["center"]).is_equal_approx(ArenaTwists.rotated(_wheel(), Vector2(0, 9), 163.0), Vector2(1e-5, 1e-5))
	assert_bool(north["moving"]).is_true()


func test_the_map_turns_the_crucibles_with_the_wheel() -> void:
	var b: MapBuilder = auto_free(MapBuilder.new())
	b.map_id = "burning_foundry"
	b.use_kit = false
	b.bake_gi = false
	b.build_lighting = false
	b.build()
	var nodes: Array = b._tag_nodes.get("crucible", [])
	assert_int(nodes.size()).is_equal(2)
	var s: float = 150.0 + 2.0 + PI / 2.0 / W  # a quarter turn after the spin-up
	b.set_match_time(s, false)
	var at: Array = nodes.map(func(n: Node3D) -> Vector3: return n.position.snapped(Vector3.ONE * 0.001))
	assert_array(at).contains_exactly_in_any_order([Vector3(-9, 0, 0), Vector3(9, 0, 0)])
	# idempotent: the same time gives the same pose, and back before the twist the crucibles are home
	b.set_match_time(s, false)
	assert_array(nodes.map(func(n: Node3D) -> Vector3: return n.position.snapped(Vector3.ONE * 0.001))).is_equal(at)
	b.set_match_time(100.0, false)
	assert_array(nodes.map(func(n: Node3D) -> Vector3: return n.position.snapped(Vector3.ONE * 0.001))).contains_exactly_in_any_order(
		[Vector3(0, 0, 9), Vector3(0, 0, -9)])


func test_bots_stop_pathing_around_the_crucibles_once_they_move() -> void:
	var geo: ArenaGeometry = ArenaGeometry.from_map(Data.maps["burning_foundry"])
	var nav: NavGrid = NavGrid.new(geo)
	var before: String = nav.state_key()
	geo.apply_twists(Data.maps["burning_foundry"]["twists"], 149.0)
	assert_str(nav.state_key()).is_equal(before)
	geo.apply_twists(Data.maps["burning_foundry"]["twists"], 151.0)
	assert_str(nav.state_key()).is_not_equal(before)  # one rebuild when the wheel starts, not one per tick
