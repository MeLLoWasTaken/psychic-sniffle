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


func test_one_v_one_dampening_starts_at_40_percent_and_reaches_full_at_1_minute() -> void:
	# duels dampen from the moment the gates open (DECISIONS 2026-10-03, the human's choice)
	var a1: ArenaMatch = ArenaMatch.new(Data.tuning, "1v1", TR, null, 0)
	a1.update(a1.start_tick, units)
	assert_int(a1.dampening_pct(a1.start_tick)).is_equal(40)
	assert_int(a1.dampening_pct(a1.start_tick + 30 * TR)).is_equal(70)
	assert_int(a1.dampening_pct(a1.start_tick + 60 * TR)).is_equal(100)
	assert_float(a1.healing_multiplier(a1.start_tick + 90 * TR)).is_equal(0.0)
	# team brackets keep the 3-minute start
	assert_float(arena.healing_multiplier(arena.start_tick + 60 * TR)).is_equal(1.0)


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


# ------------------------------------------------------------ M2-07 1v1 and pickups

func test_one_v_one_is_a_draw_at_12_minutes() -> void:
	var duel: Dictionary = {1: Unit.new(1, 0), 2: Unit.new(2, 1)}
	var a1: ArenaMatch = ArenaMatch.new(Data.tuning, "1v1", TR, null, 0)
	a1.update(a1.start_tick, duel)
	a1.update(a1.start_tick + 12 * 60 * TR - 1, duel)
	assert_int(a1.phase).is_equal(ArenaMatch.Phase.ACTIVE)
	a1.update(a1.start_tick + 12 * 60 * TR, duel)
	assert_int(a1.phase).is_equal(ArenaMatch.Phase.ENDED)
	assert_int(a1.winner_team).is_equal(-2)


func _pickup_arena(bracket: String) -> ArenaMatch:
	return ArenaMatch.new(Data.tuning, bracket, TR, null, 0, [[0, 0, 13], [0, 0, -13]])


func test_pickups_light_up_once_at_1_30_in_1v1_and_2v2_only() -> void:
	for bracket: String in ["1v1", "2v2", "3v3"]:
		var a: ArenaMatch = _pickup_arena(bracket)
		var far: Dictionary = {1: Unit.new(1, 0), 2: Unit.new(2, 1)}
		a.update(a.start_tick, far)
		a.update(a.start_tick + 90 * TR - 1, far)
		assert_int(a.pickup_mask()).is_equal(0)
		a.update(a.start_tick + 90 * TR, far)
		var expect: int = 0b11 if bracket in Data.tuning["arena"]["pickup_brackets"] else 0
		assert_int(a.pickup_mask()).override_failure_message(bracket).is_equal(expect)


func test_the_first_player_in_reach_takes_a_pickup_and_it_does_not_return() -> void:
	var a: ArenaMatch = _pickup_arena("2v2")
	var near: Unit = Unit.new(1, 0)
	var nearer: Unit = Unit.new(2, 1)
	var dead: Unit = Unit.new(3, 0)
	near.position = Vector3(1.0, 0, 13)
	nearer.position = Vector3(0.4, 0, 13)
	dead.position = Vector3(0, 0, 13)
	dead.health = 0
	var us: Dictionary = {1: near, 2: nearer, 3: dead}
	a.update(a.start_tick, us)
	a.update(a.start_tick + 90 * TR, us)
	var taken: Array[Dictionary] = a.take_pickups()
	assert_int(taken.size()).is_equal(1)
	assert_int(int(taken[0]["unit"])).is_equal(2)  # the nearest living one
	assert_int(a.pickup_mask()).is_equal(0b10)  # spot 0 gone, spot 1 still lit
	a.update(a.start_tick + 200 * TR, us)
	assert_int(a.pickup_mask()).is_equal(0b10)
	assert_array(a.take_pickups()).is_empty()


func test_a_pickup_restores_health_and_mana_over_time_through_the_runner() -> void:
	# 2v2: duel dampening is already full by the time pickups light at 1:30 (DECISIONS 2026-10-03)
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 0.0, 3)
	var healer: Unit = runner.add_unit("oracle_grace", 0)
	var foe: Unit = runner.add_unit("warblade_carnage", 1)
	runner.sim.add_system(runner.system_combat_and_rules)
	runner.sim.step()
	healer.health = 30000
	healer.resources["mana"] = 0.0
	healer.position = Vector3(0, 0, 13)
	while runner.arena.match_seconds(runner.sim.tick) < 90.2:
		runner.sim.step()
		runner.take_events()
	assert_bool(runner.combat.has_aura(healer, "arena_renewal")).is_true()
	assert_bool(runner.combat.has_aura(healer, "arena_clarity")).is_true()
	for i: int in 11 * 60:
		runner.sim.step()
	assert_int(healer.health).is_greater(30000 + 9000)  # 10 heals of 1,500
	assert_float(float(healer.resources["mana"])).is_greater(15000.0)
	assert_int(runner.match_state()["pickups"]).is_equal(0b10)


func test_bracket_auras_apply_only_in_their_bracket_and_never_twice() -> void:
	# M2-07: duel balance as standing auras from tuning (arena.bracket_auras), by role or spec
	var duel: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "1v1", 5.0, 2)
	var healer: Unit = duel.add_unit("oracle_grace", 0)
	var blade: Unit = duel.add_unit("warblade_carnage", 1)
	var rules: Array = Data.tuning["arena"].get("bracket_auras", {}).get("1v1", [])
	assert_array(rules).is_not_empty()
	var ids: Array = healer.auras.map(func(a: Dictionary) -> String: return a["id"])
	for r: Dictionary in rules:
		var applies: bool = str(r.get("role", "")) == "healer" or str(r.get("spec", "")) == "oracle_grace"
		assert_bool(r["aura"] in ids).override_failure_message("%s on the Oracle" % r["aura"]).is_equal(applies)
	assert_bool(blade.auras.any(func(a: Dictionary) -> bool: return a.get("bracket", false))).is_equal(
		rules.any(func(r: Dictionary) -> bool: return str(r.get("spec", "")) == "warblade_carnage"))
	# a talent change during preparation re-initialises the unit: still one copy
	var n: int = healer.auras.filter(func(a: Dictionary) -> bool: return a.get("bracket", false)).size()
	duel.set_talents(healer, str(BotBrain.build_talents("oracle_grace")["talents"]))
	assert_int(healer.auras.filter(func(a: Dictionary) -> bool: return a.get("bracket", false)).size()).is_equal(n)
	# not in 2v2
	var team: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 5.0, 2)
	var h2: Unit = team.add_unit("oracle_grace", 0)
	assert_bool(h2.auras.any(func(a: Dictionary) -> bool: return a.get("bracket", false))).is_false()
