extends GdUnitTestSuite
## M0-12 (movement rules) and M0-13 (targeting and auto-attack) unit tests.

const DT: float = 1.0 / 60.0

var tuning: Dictionary
var geo: ArenaGeometry


func before_test() -> void:
	tuning = Data.tuning
	geo = preload("res://test/fixtures/fixture_map.gd").geometry()


func test_runs_7_metres_per_second_forward() -> void:
	var mv: Movement = Movement.new(tuning, null)
	var u: Unit = Unit.new(1, 0)
	for i: int in 60:
		mv.apply(u, {"move": Vector2(0, 1), "yaw": 0.0}, DT)
	assert_float(u.position.z).is_equal_approx(-7.0, 1e-4)  # Vector3 is 32-bit float  # yaw 0 faces -Z
	assert_float(u.position.x).is_equal_approx(0.0, 1e-4)


func test_backpedal_is_slower() -> void:
	var mv: Movement = Movement.new(tuning, null)
	var u: Unit = Unit.new(1, 0)
	for i: int in 60:
		mv.apply(u, {"move": Vector2(0, -1), "yaw": 0.0}, DT)
	assert_float(u.position.z).is_equal_approx(7.0 * 0.6, 1e-4)


func test_jump_goes_up_and_lands() -> void:
	var mv: Movement = Movement.new(tuning, null)
	var u: Unit = Unit.new(1, 0)
	mv.apply(u, {"jump": true}, DT)
	var peak: float = 0.0
	for i: int in 120:
		mv.apply(u, {}, DT)
		peak = maxf(peak, u.position.y)
	assert_float(peak).is_between(1.4, 1.8)  # about 1.6 m
	assert_float(u.position.y).is_equal(0.0)


func test_pillar_blocks_movement() -> void:
	var mv: Movement = Movement.new(tuning, geo)
	var u: Unit = Unit.new(1, 0)
	u.position = Vector3(7, 0, -12)  # south of the pillar at (7, -7), running north (-Z is north here? no: toward +Z)
	var yaw_toward_plus_z: float = PI  # forward = -Z rotated 180 degrees = +Z
	for i: int in 120:
		mv.apply(u, {"move": Vector2(0, 1), "yaw": yaw_toward_plus_z}, DT)
	# stopped at the pillar surface: centre (7,-7), radius 1.2 + unit radius 0.45
	assert_float(u.position.z).is_less_equal(-7.0 - 1.64)


func test_bounds_keep_unit_inside() -> void:
	var mv: Movement = Movement.new(tuning, geo)
	var u: Unit = Unit.new(1, 0)
	u.position = Vector3(18, 0, 0)
	for i: int in 120:
		mv.apply(u, {"move": Vector2(1, 0), "yaw": 0.0}, DT)
	assert_float(u.position.x).is_less_equal(20.0 - ArenaGeometry.UNIT_RADIUS + 1e-6)


func test_line_of_sight_blocked_by_pillar() -> void:
	var eye: Vector3 = Vector3.UP * 1.6
	assert_bool(geo.has_line_of_sight(Vector3(7, 0, -12) + eye, Vector3(7, 0, -2) + eye)).is_false()
	assert_bool(geo.has_line_of_sight(Vector3(-15, 0, 12) + eye, Vector3(15, 0, 12) + eye)).is_true()


func _combat_with(units: Array) -> Combat:
	var sim: Sim = Sim.new(1, 60)
	for u: Unit in units:
		sim.add_unit(u)
	var t: Dictionary = tuning.duplicate(true)
	t["combat"]["crit_chance"] = 0.0
	return Combat.new(sim, t, Data.abilities, Data.auras, Data.specs, Data.classes, null)


func test_tab_picks_nearest_enemy_in_front() -> void:
	var me: Unit = Unit.new(1, 0)
	var behind: Unit = Unit.new(2, 1)
	behind.position = Vector3(0, 0, 3)  # behind (yaw 0 faces -Z), closer
	var front: Unit = Unit.new(3, 1)
	front.position = Vector3(0, 0, -8)
	var ally: Unit = Unit.new(4, 0)
	ally.position = Vector3(0, 0, -2)
	var cb: Combat = _combat_with([me, behind, front, ally])
	assert_int(cb.tab_target(me)).is_equal(3)


func test_auto_attack_swings_every_2_seconds_in_range_only() -> void:
	var me: Unit = Unit.new(1, 0)
	me.stats = {"power_bonus": 0.0, "haste": 0.0, "crit_chance": 0.0}
	var foe: Unit = Unit.new(2, 1)
	foe.armor = "cloth"
	foe.position = Vector3(0, 0, -4)
	me.target_id = 2
	var cb: Combat = _combat_with([me, foe])
	for t: int in 600:  # 10 s in range
		cb.tick()
		cb.sim.tick += 1
	var hits: Array = cb.events.filter(func(e: Dictionary) -> bool: return e["type"] == "damage")
	assert_int(hits.size()).is_equal(5)
	assert_int(foe.health).is_equal(60000 - 5 * roundi(1200 * 0.9))  # cloth takes 10% less physical
	cb.events.clear()
	foe.position = Vector3(0, 0, -6)  # out of 5 m range
	for t: int in 600:
		cb.tick()
		cb.sim.tick += 1
	assert_int(cb.events.filter(func(e: Dictionary) -> bool: return e["type"] == "damage").size()).is_equal(0)
