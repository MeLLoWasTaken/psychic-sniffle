extends GdUnitTestSuite
## Arena map checks (backlog M1-14): the built scene matches the map data the server uses, the
## line-of-sight rules hold on the real map, and bots can path between the starting rooms.

const MAP_ID: String = "gallows_courtyard"

var map: Dictionary
var geometry: ArenaGeometry


func before_test() -> void:
	map = Data.maps[MAP_ID]
	geometry = ArenaGeometry.from_map(map)


func _free_point(rng: RandomNumberGenerator) -> Vector3:
	while true:
		var lim: float = geometry.bounds_half - 0.5
		var p: Vector3 = Vector3(rng.randf_range(-lim, lim), 0, rng.randf_range(-lim, lim))
		if geometry.resolve(p).distance_to(p) < 0.001:
			return p
	return Vector3.ZERO


func test_map_matches_the_design_brief() -> void:
	assert_float(float(map["size_m"])).is_between(35.0, 45.0)
	var pillars: int = map["colliders"].filter(func(c: Dictionary) -> bool: return c.get("tag", "") == "pillar").size()
	var gates: int = map["colliders"].filter(func(c: Dictionary) -> bool: return c.get("gate", false)).size()
	assert_int(pillars).is_equal(4)
	assert_int(gates).is_equal(2)
	for team: String in ["team_a", "team_b"]:
		assert_int(map["spawns"][team].size()).is_greater_equal(3)


func test_scene_line_of_sight_matches_the_server() -> void:
	# The scene's los_blocker collision and the server's pure-math line of sight must agree,
	# with the gates closed and open.
	var builder: MapBuilder = auto_free(MapBuilder.new())
	builder.map_id = MAP_ID
	builder.build_lighting = false
	add_child(builder)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 42
	for open: bool in [false, true]:
		builder.set_gates_open(open, 0.0)
		geometry.gates_open = open
		await get_tree().physics_frame
		await get_tree().physics_frame
		var space: PhysicsDirectSpaceState3D = builder.get_world_3d().direct_space_state
		var mismatches: int = 0
		var blocked: int = 0
		for i: int in 400:
			var a: Vector3 = _free_point(rng) + Vector3.UP * Combat.EYE_HEIGHT
			var b: Vector3 = _free_point(rng) + Vector3.UP * Combat.CHEST_HEIGHT
			var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(a, b, 1 << (MapBuilder.LAYER_LOS - 1))
			var scene_clear: bool = space.intersect_ray(q).is_empty()
			var server_clear: bool = geometry.has_line_of_sight(a, b)
			mismatches += 1 if scene_clear != server_clear else 0
			blocked += 0 if server_clear else 1
		assert_int(blocked).override_failure_message("too few blocked sightlines to be a real test").is_greater(40)
		assert_int(mismatches).override_failure_message("%d of 400 sightlines disagree (gates open: %s)" % [mismatches, open]).is_less_equal(2)


func test_line_of_sight_rules_on_this_map() -> void:
	var eye: Vector3 = Vector3.UP * Combat.EYE_HEIGHT
	var chest: Vector3 = Vector3.UP * Combat.CHEST_HEIGHT
	geometry.gates_open = true
	# a pillar blocks, the open floor does not
	var pillar: Dictionary = map["colliders"].filter(func(c: Dictionary) -> bool: return c.get("tag", "") == "pillar")[0]
	var pc: Vector3 = Vector3(pillar["center"][0], 0, pillar["center"][1])
	assert_bool(geometry.has_line_of_sight(pc + Vector3(0, 0, -4) + eye, pc + Vector3(0, 0, 4) + chest)).is_false()
	assert_bool(geometry.has_line_of_sight(Vector3(-11, 0, -11) + eye, Vector3(-11, 0, 11) + chest)).is_true()
	# the central gallows block
	assert_bool(geometry.has_line_of_sight(Vector3(-6, 0, 0) + eye, Vector3(6, 0, 0) + chest)).is_false()
	# a closed gate hides a starting room; an open one does not
	var sp: Array = map["spawns"]["team_a"][2]
	var inside: Vector3 = Vector3(sp[0], 0, sp[2])
	geometry.gates_open = false
	assert_bool(geometry.has_line_of_sight(Vector3(-10, 0, 0) + eye, inside + chest)).is_false()
	geometry.gates_open = true
	assert_bool(geometry.has_line_of_sight(Vector3(-10, 0, 0) + eye, inside + chest)).is_true()


func test_bots_can_path_between_rooms_only_when_gates_open() -> void:
	geometry.gates_open = true
	var nav: NavGrid = NavGrid.new(geometry)
	var a: Vector3 = Vector3(map["spawns"]["team_a"][0][0], 0, map["spawns"]["team_a"][0][2])
	var b: Vector3 = Vector3(map["spawns"]["team_b"][0][0], 0, map["spawns"]["team_b"][0][2])
	var path: Array[Vector3] = nav.path(a, b)
	assert_vector(path[-1]).is_equal(b)
	var prev: Vector3 = a
	for p: Vector3 in path:
		assert_bool(nav.walkable(prev, p)).is_true()
		prev = p
	geometry.gates_open = false
	nav.rebuild()
	var a_cell: Vector2i = nav._nearest_open(a)
	var b_cell: Vector2i = nav._nearest_open(b)
	assert_int(nav._astar.get_id_path(a_cell, b_cell).size()).is_equal(0)


func test_gates_sink_and_stop_blocking_when_opened() -> void:
	var builder: MapBuilder = auto_free(MapBuilder.new())
	builder.map_id = MAP_ID
	builder.build_lighting = false
	add_child(builder)
	assert_int(builder.gates.size()).is_equal(2)
	builder.set_gates_open(true, 0.0)
	for g: Node3D in builder.gates:
		# greybox gates sink into the floor; kit portcullises rise into the gatehouse
		var expected: float = MapBuilder.GATE_OPEN_RISE if builder.has_kit() else -MapBuilder.GATE_OPEN_DEPTH
		assert_float(g.position.y).is_equal_approx(expected, 0.001)
		var body: StaticBody3D = g.get_node("Mesh/Body")
		assert_int(body.collision_layer).is_equal(0)


func test_dressed_arena_stays_under_the_triangle_budget() -> void:
	var builder: MapBuilder = auto_free(MapBuilder.new())
	builder.map_id = MAP_ID
	builder.build_lighting = false
	add_child(builder)
	assert_bool(builder.has_kit()).is_true()
	var tris: int = builder.visible_triangles()
	print("arena visible triangles: %d" % tris)
	assert_int(tris).override_failure_message("%d visible triangles" % tris).is_less(1_500_000)
	assert_int(tris).is_greater(100_000)  # the kit really is there
