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


# ------------------------------------------------------------------ dressing (backlog F-05)

## Guard: dressing must never change gameplay collision. When a collider change is deliberate,
## check bot navigation and balance, then update this fingerprint.
const COLLIDERS_MD5: String = "6c6eb84b4aa202d8f4067a92c7a4d663"  # 2026-10-01: starting rooms deepened from 4.5 to 8 m (M1-32)


func _dressed_builder() -> MapBuilder:
	var builder: MapBuilder = auto_free(MapBuilder.new())
	builder.map_id = MAP_ID
	builder.build_lighting = false
	add_child(builder)
	return builder


func test_gameplay_colliders_are_unchanged() -> void:
	var md5: String = JSON.stringify(map["colliders"]).md5_text()
	assert_str(md5).override_failure_message("map colliders changed (md5 %s): gameplay collision must only change deliberately" % md5).is_equal(COLLIDERS_MD5)


func test_dressing_adds_no_collision() -> void:
	var builder: MapBuilder = _dressed_builder()
	assert_bool(builder.has_kit()).is_true()
	var bodies: Array[Node] = builder.find_children("*", "CollisionObject3D", true, false)
	# one body per map collider, plus the floor and the four perimeter walls; all on greybox meshes
	assert_int(bodies.size()).is_equal(map["colliders"].size() + 5)
	for b: Node in bodies:
		assert_bool(b.get_parent().has_meta("greybox")).override_failure_message("%s is not a greybox body" % b.get_path()).is_true()
	for root: String in ["Kit", "Skyline"]:
		assert_int(builder.get_node(root).find_children("*", "CollisionObject3D", true, false).size()).is_equal(0)


func test_skyline_stands_outside_the_walls_and_casts_no_shadow() -> void:
	var builder: MapBuilder = _dressed_builder()
	var sky: Node3D = builder.get_node("Skyline")
	var bounds: float = float(map["bounds_half_m"])
	var drawn: int = 0
	for n: Node in sky.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi: MultiMeshInstance3D = n
		assert_int(mmi.cast_shadow).is_equal(GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		drawn += mmi.multimesh.instance_count
	# placements (headless multimeshes do not keep their instance transforms)
	var placed: int = 0
	for piece: String in builder.skyline_placements:
		for xf: Transform3D in builder.skyline_placements[piece]:
			var box: AABB = xf * builder._piece_aabb(piece)
			var nearest: float = maxf(minf(absf(box.position.x), absf(box.end.x)) if box.position.x * box.end.x > 0.0 else 0.0,
				minf(absf(box.position.z), absf(box.end.z)) if box.position.z * box.end.z > 0.0 else 0.0)
			assert_float(nearest).override_failure_message("%s reaches to %.1f m from the centre" % [piece, nearest]).is_greater(bounds + 2.0)
			placed += 1
	assert_int(placed).is_equal(map["dressing"]["skyline"]["pieces"].size())
	assert_int(drawn).is_greater_equal(placed)


func test_every_dressing_piece_is_built() -> void:
	var builder: MapBuilder = _dressed_builder()
	var pieces: Dictionary = {}
	for d: Dictionary in map["decor"]:
		pieces[d["piece"]] = true
	var dr: Dictionary = map["dressing"]
	for s: Dictionary in dr["skyline"]["pieces"]:
		pieces[s["piece"]] = true
	pieces[dr["gatehouse"]["piece"]] = true
	for key: String in ["walk", "parapet", "outer_wall"]:
		if dr["wall_top"].has(key):
			pieces[dr["wall_top"][key]] = true
	for base: String in dr["variants"]:
		for v: String in dr["variants"][base]:
			pieces[v] = true
	for p: String in pieces:
		assert_object(builder._kit_piece(p)).override_failure_message("kit piece %s is not built" % p).is_not_null()


func test_gatehouses_hide_the_raised_portcullis() -> void:
	var builder: MapBuilder = _dressed_builder()
	builder.set_gates_open(true, 0.0)
	var box: AABB = builder._piece_aabb(map["dressing"]["gatehouse"]["piece"])
	for i: int in builder.gates.size():
		var g: Node3D = builder.gates[i]
		var house: Node3D = builder.get_node("Kit/Gatehouse%d" % i)
		var height: float = float(g.get_meta("collider").get("height", 5.0))
		var grille_top: float = g.position.y + height  # the raised portcullis
		var world: AABB = house.global_transform * box
		assert_float(world.end.y).is_greater(grille_top + 0.3)
		# it spans the gate: the gate's centre line lies inside the gatehouse footprint
		assert_bool(world.grow(0.01).has_point(Vector3(g.position.x, grille_top - 0.5, g.position.z))).is_true()


func test_braziers_burn_with_a_flickering_light() -> void:
	var builder: MapBuilder = _dressed_builder()
	var fires: Array[Node] = builder.find_children("Fx_*", "Node3D", true, false).filter(func(n: Node) -> bool: return n is AmbientFx)
	var braziers: int = map["decor"].filter(func(d: Dictionary) -> bool: return d.get("effect", "") == "brazier_fire").size()
	assert_int(braziers).is_greater(0)
	assert_int(fires.size()).is_equal(braziers)
	var fx: AmbientFx = fires[0]
	assert_int(fx.flames.size()).is_greater(0)
	assert_object(fx.light).is_not_null()
	var energies: Dictionary = {}
	for k: int in 12:
		fx.advance(0.05)
		energies[snappedf(fx.light.light_energy, 0.001)] = true
	assert_int(energies.size()).is_greater(6)  # it flickers
	var base: float = float(Data.ambient_effects["brazier_fire"]["light"]["energy"])
	assert_float(fx.light.light_energy).is_between(base * 0.6, base * 1.4)


func test_floor_tiles_stop_at_the_bounds() -> void:
	var builder: MapBuilder = _dressed_builder()
	var bounds: float = float(map["bounds_half_m"])
	var checked: int = 0
	for piece: String in builder._placements:
		if not piece.begins_with("floor_tile"):
			continue
		for xf: Transform3D in builder._placements[piece]:
			var world: AABB = xf * builder._piece_aabb(piece)
			assert_float(maxf(maxf(absf(world.position.x), absf(world.end.x)), maxf(absf(world.position.z), absf(world.end.z)))).is_less_equal(bounds + 0.05)
			checked += 1
	assert_int(checked).is_greater(50)
	assert_bool(builder._placements.has("floor_tile_worn")).override_failure_message("no worn tile variants placed").is_true()
