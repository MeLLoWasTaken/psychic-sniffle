extends GdUnitTestSuite
## Arena twists (backlog M2-16): timed map events on match time. Gallows Courtyard's gallows
## collapse at 5:00 after a warning at 4:50, opening the centre for movement and line of sight;
## the server, the client's prediction, replays and the map's visuals all agree on when.

const TR: int = 60


func _gallows() -> Dictionary:
	return Data.maps["gallows_courtyard"]["twists"][0]


func test_stages_and_removed_tags_follow_match_time() -> void:
	var t: Dictionary = _gallows()
	assert_int(ArenaTwists.stage(t, -5.0)).is_equal(ArenaTwists.Stage.WAITING)
	assert_int(ArenaTwists.stage(t, 289.9)).is_equal(ArenaTwists.Stage.WAITING)
	assert_int(ArenaTwists.stage(t, 290.0)).is_equal(ArenaTwists.Stage.WARNED)
	assert_int(ArenaTwists.stage(t, 300.0)).is_equal(ArenaTwists.Stage.DONE)
	assert_dict(ArenaTwists.removed_tags([t], 299.9)).is_empty()
	assert_dict(ArenaTwists.removed_tags([t], 300.0)).is_equal({"gallows": true})
	assert_vector(ArenaTwists.center(t, Data.maps["gallows_courtyard"])).is_equal(Vector3.ZERO)


func test_the_gallows_collapse_on_the_server_and_the_match_replays() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 1.0, 3)
	runner.record()
	var a: Unit = runner.add_unit("warblade_carnage", 0)
	var b: Unit = runner.add_unit("arcanist_rime", 1)
	runner.sim.add_system(runner.system_combat_and_rules)
	var geo: ArenaGeometry = runner.geometry
	var west: Vector3 = Vector3(-6, Combat.EYE_HEIGHT, 0)
	var east: Vector3 = Vector3(6, Combat.EYE_HEIGHT, 0)
	var events: Array = []
	var start: int = runner.arena.start_tick
	while runner.sim.tick < start + 299 * TR:
		runner.sim.step()
		events.append_array(runner.arena.events)
		runner.arena.events.clear()
	assert_bool(geo.has_line_of_sight(west, east)).override_failure_message("the gallows should block until 5:00").is_false()
	var warned: Array = events.filter(func(e: Dictionary) -> bool: return e["type"] == "twist_warning")
	assert_int(warned.size()).is_equal(1)
	assert_int(int(warned[0]["tick"])).is_equal(start + 290 * TR)
	assert_str(str(warned[0]["text"])).is_equal("The gallows groan...")
	assert_str(str(warned[0]["sound"])).is_equal("gallows_groan")
	while runner.sim.tick <= start + 300 * TR:
		runner.sim.step()
		events.append_array(runner.arena.events)
		runner.arena.events.clear()
	var fell: Array = events.filter(func(e: Dictionary) -> bool: return e["type"] == "twist")
	assert_int(fell.size()).is_equal(1)
	assert_int(int(fell[0]["tick"])).is_equal(start + 300 * TR)
	assert_bool(geo.has_line_of_sight(west, east)).is_true()
	# where the block stood is open ground now
	assert_vector(geo.resolve(Vector3(0, 0, 0))).is_equal(Vector3.ZERO)
	assert_bool(a.is_alive() and b.is_alive()).is_true()
	runner.input_log.finish(runner.sim)
	var r: Dictionary = Replay.run(runner.input_log)
	assert_bool(r["ok"]).override_failure_message(str(r)).is_true()


func test_the_client_takes_the_collapse_from_match_time() -> void:
	var c: NetClient = auto_free(NetClient.new())
	c.map_id = "gallows_courtyard"
	c.geometry = ArenaGeometry.from_map(Data.maps["gallows_courtyard"])
	c._match_phase = ArenaMatch.Phase.ACTIVE
	c._match_start_tick = 1000
	c._apply_twists(1000 + 299 * TR)
	assert_dict(c.geometry.removed_tags).is_empty()
	c._apply_twists(1000 + 300 * TR)  # a predicted tick past the collapse
	assert_dict(c.geometry.removed_tags).is_equal({"gallows": true})
	assert_bool(c.geometry.has_line_of_sight(Vector3(-6, 1.6, 0), Vector3(6, 1.6, 0))).is_true()


func test_the_map_hides_the_gallows_and_leaves_a_wreck() -> void:
	var b: MapBuilder = auto_free(MapBuilder.new())
	b.map_id = "gallows_courtyard"
	b.use_kit = false
	b.bake_gi = false
	b.build_lighting = false
	b.build()
	var gallows: Array = b._tag_nodes["gallows"]
	assert_array(gallows).is_not_empty()
	b.set_match_time(310.0, true)  # preparation: nothing happens
	assert_array(b.wrecks).is_empty()
	b.set_match_time(299.0, false)
	assert_array(b.wrecks).is_empty()
	assert_bool((gallows[0] as Node3D).visible).is_true()
	b.set_match_time(300.5, false)
	assert_int(b.wrecks.size()).is_equal(1)
	for n: Node3D in gallows:
		assert_bool(n.visible).is_false()
		for body: Node in n.find_children("*", "StaticBody3D", true, false):
			assert_int((body as StaticBody3D).collision_layer).is_equal(0)
	b.set_match_time(320.0, false)  # every frame after: no second wreck
	assert_int(b.wrecks.size()).is_equal(1)
	# the wreck lies low: nothing in it stands taller than a unit's knees
	for piece: Node in b.wrecks[0].get_children():
		if piece is MeshInstance3D:
			assert_float((piece as MeshInstance3D).position.y).is_less(0.6)


func test_twists_are_announced() -> void:
	var view: Dictionary = {"me": {"id": 1, "team": 0}, "units": []}
	assert_str(EventText.line_for({"type": "twist", "text": "The gallows collapse!"}, view)).is_equal("The gallows collapse!")
	var flow: MatchFlow = MatchFlow.new(2.0, 2)
	var screens: MatchScreens = auto_free(MatchScreens.new(MenuStyle.new("main"), flow))
	screens.announce("The gallows groan...")
	assert_str(screens.announcement).is_equal("The gallows groan...")


# ------------------------------------------------------------------ flood (M2-09, Flooded Crypt)

func _flood() -> Dictionary:
	return Data.maps["flooded_crypt"]["twists"][0]


func test_the_crypt_floods_at_3_00_and_wading_is_slow_outside_the_aisles() -> void:
	var t: Dictionary = _flood()
	assert_float(ArenaTwists.flood_level(t, 160.0)).is_equal(0.0)
	assert_float(ArenaTwists.flood_level(t, 172.5)).is_equal_approx(0.5, 1e-6)
	assert_float(ArenaTwists.flood_level(t, 180.0)).is_equal(1.0)
	var geo: ArenaGeometry = ArenaGeometry.from_map(Data.maps["flooded_crypt"])
	geo.apply_twists([t], 179.9)
	assert_float(geo.ground_speed(Vector3(0, 0, 9))).is_equal(1.0)  # risen, not yet in effect
	geo.apply_twists([t], 180.0)
	assert_float(geo.ground_speed(Vector3(0, 0, 9))).is_equal_approx(0.7, 1e-6)  # the nave
	assert_float(geo.ground_speed(Vector3(0, 0, 15))).is_equal(1.0)  # an aisle
	assert_float(geo.ground_speed(Vector3(17, 0, 0))).is_equal(1.0)  # a gate landing
	assert_float(geo.ground_speed(Vector3(0, 0.5, 9))).is_equal(1.0)  # mid-jump over the water
	# movement: a second of running covers 30% less ground in the water
	var mv: Movement = Movement.new(Data.tuning, geo)
	var wet: Unit = Unit.new(1, 0)
	wet.position = Vector3(-10, 0, 8)
	var dry: Unit = Unit.new(2, 0)
	dry.position = Vector3(-10, 0, 15)
	for i: int in TR:
		mv.apply(wet, {"move": Vector2(0, 1), "yaw": -PI / 2}, 1.0 / TR)
		mv.apply(dry, {"move": Vector2(0, 1), "yaw": -PI / 2}, 1.0 / TR)
	assert_float((wet.position.x + 10.0) / (dry.position.x + 10.0)).is_equal_approx(0.7, 0.01)


func test_the_crypt_flood_on_the_server_replays_and_reaches_the_client() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["flooded_crypt"], "arena", "1v1", 1.0, 4)
	runner.record()
	runner.add_unit("warblade_carnage", 0)
	runner.add_unit("arcanist_rime", 1)
	runner.sim.add_system(runner.system_combat_and_rules)
	var events: Array = []
	var start: int = runner.arena.start_tick
	while runner.sim.tick <= start + 180 * TR:
		runner.sim.step()
		events.append_array(runner.arena.events)
		runner.arena.events.clear()
	assert_array(events.filter(func(e: Dictionary) -> bool: return e["type"] == "twist_warning")).has_size(1)
	assert_array(events.filter(func(e: Dictionary) -> bool: return e["type"] == "twist")).has_size(1)
	assert_float(runner.geometry.ground_speed(Vector3(0, 0, 9))).is_equal_approx(0.7, 1e-6)
	runner.input_log.finish(runner.sim)
	assert_bool(Replay.run(runner.input_log)["ok"]).is_true()
	var c: NetClient = auto_free(NetClient.new())
	c.map_id = "flooded_crypt"
	c.geometry = ArenaGeometry.from_map(Data.maps["flooded_crypt"])
	c._match_phase = ArenaMatch.Phase.ACTIVE
	c._match_start_tick = 0
	c._apply_twists(181 * TR)
	assert_float(c.geometry.ground_speed(Vector3(0, 0, 9))).is_equal_approx(0.7, 1e-6)


func test_the_crypt_water_rises_during_the_warning() -> void:
	var b: MapBuilder = auto_free(MapBuilder.new())
	b.map_id = "flooded_crypt"
	b.use_kit = false
	b.bake_gi = false
	b.build_lighting = false
	b.build()
	b.set_match_time(100.0, false)
	assert_object(b.water).is_null()
	b.set_match_time(172.5, false)
	assert_object(b.water).is_not_null()
	var half_y: float = b.water.position.y
	b.set_match_time(200.0, false)
	assert_float(b.water.position.y).is_greater(half_y)
	assert_float(b.water.position.y).is_equal_approx(MapBuilder.WATER_FULL_Y, 1e-6)
	# the water covers the nave and leaves the aisles dry
	var aabb: AABB = b.water.mesh.get_aabb()
	assert_float(aabb.size.x).is_greater(30.0)
	var faces: PackedVector3Array = b.water.mesh.get_faces()
	for i: int in range(0, faces.size(), 3):
		var centre: Vector3 = (faces[i] + faces[i + 1] + faces[i + 2]) / 3.0
		assert_bool(absf(centre.z) < 12.5).override_failure_message("water over an aisle at %s" % centre).is_true()


func test_a_match_picks_one_of_the_preset_arenas_for_its_bracket() -> void:
	var NetMatch: GDScript = load("res://scenes/game/net_match.gd")
	var p: Dictionary = {"map": "gallows_courtyard", "maps": ["gallows_courtyard", "flooded_crypt"], "bracket": "2v2"}
	var seen: Dictionary = {}
	for i: int in 40:
		seen[NetMatch.pick_map(p)] = true
	assert_dict(seen).contains_keys(["gallows_courtyard", "flooded_crypt"])
	assert_str(NetMatch.pick_map(p, "flooded_crypt")).is_equal("flooded_crypt")
	assert_str(NetMatch.pick_map({"map": "gallows_courtyard", "bracket": "2v2"})).is_equal("gallows_courtyard")
