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
