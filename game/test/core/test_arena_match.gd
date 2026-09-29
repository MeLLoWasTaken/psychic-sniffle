extends GdUnitTestSuite
## M1-09: arena match rules.

const TR: int = 60

var geo: ArenaGeometry
var arena: ArenaMatch
var units: Dictionary


func before_test() -> void:
	geo = preload("res://test/fixtures/fixture_map.gd").geometry()
	arena = ArenaMatch.new(Data.tuning, "2v2", TR, geo, 0)
	units = {}
	for i: int in 4:
		units[i + 1] = Unit.new(i + 1, i % 2)


func _run_to(tick_from: int, tick_to: int) -> void:
	for t: int in range(tick_from, tick_to):
		arena.update(t, units)


func test_gates_hold_players_in_during_preparation_then_open() -> void:
	var mv: Movement = Movement.new(Data.tuning, geo)
	var u: Unit = Unit.new(9, 0)
	u.position = Vector3(-18, 0, 0)
	for i: int in 120:  # run east toward the gate at x = -15
		mv.apply(u, {"move": Vector2(0, 1), "yaw": -PI / 2}, 1.0 / TR)
	assert_float(u.position.x).is_less(-15.5)
	_run_to(0, 60 * TR + 1)
	assert_int(arena.phase).is_equal(ArenaMatch.Phase.ACTIVE)
	for i: int in 120:
		mv.apply(u, {"move": Vector2(0, 1), "yaw": -PI / 2}, 1.0 / TR)
	assert_float(u.position.x).is_greater(-14.0)


func test_dampening_starts_at_3_minutes_and_drops_1_percent_per_10_s() -> void:
	_run_to(0, 60 * TR + 1)
	var start: int = arena.start_tick
	assert_float(arena.healing_multiplier(start + 179 * TR)).is_equal(1.0)
	assert_float(arena.healing_multiplier(start + 180 * TR)).is_equal_approx(0.99, 1e-9)
	assert_float(arena.healing_multiplier(start + 200 * TR)).is_equal_approx(0.97, 1e-9)
	assert_int(arena.dampening_pct(start + 280 * TR)).is_equal(11)


func test_one_v_one_dampening_starts_at_1_minute() -> void:
	var a1: ArenaMatch = ArenaMatch.new(Data.tuning, "1v1", TR, null, 0)
	a1.update(a1.start_tick, units)
	assert_float(a1.healing_multiplier(a1.start_tick + 60 * TR)).is_equal_approx(0.99, 1e-9)


func test_team_elimination_wins() -> void:
	_run_to(0, 60 * TR + 1)
	units[2].health = 0
	units[4].health = 0
	arena.update(60 * TR + 2, units)
	assert_int(arena.phase).is_equal(ArenaMatch.Phase.ENDED)
	assert_int(arena.winner_team).is_equal(0)


func test_draw_at_20_minutes() -> void:
	_run_to(0, 60 * TR + 1)
	arena.update(arena.start_tick + 20 * 60 * TR, units)
	assert_int(arena.phase).is_equal(ArenaMatch.Phase.ENDED)
	assert_int(arena.winner_team).is_equal(-2)
