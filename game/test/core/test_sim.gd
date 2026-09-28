extends GdUnitTestSuite
## M0-09 acceptance tests for the fixed-step simulation core.


func _random_walk(sim: Sim, _inputs: Dictionary) -> void:
	# A system that uses the seeded RNG, so determinism covers random rolls too.
	for u: Unit in sim.units.values():
		u.position.x += sim.rng.randf_range(-0.1, 0.1)
		u.position.z += sim.rng.randf_range(-0.1, 0.1)
		u.health -= sim.rng.randi_range(0, 50)


func _make_sim(seed_value: int) -> Sim:
	var sim: Sim = Sim.new(seed_value, 60)
	sim.add_unit(Unit.new(1, 0, "warblade_carnage"))
	sim.add_unit(Unit.new(2, 1, "arcanist_rime"))
	sim.add_system(_random_walk)
	return sim


func test_600_ticks_is_10_seconds() -> void:
	var sim: Sim = Sim.new(1, 60)
	for i: int in 600:
		sim.step()
	assert_int(sim.tick).is_equal(600)
	assert_float(sim.time_s()).is_equal_approx(10.0, 1e-9)


func test_advance_is_independent_of_frame_rate() -> void:
	var fast: Sim = Sim.new(1, 60)
	var slow: Sim = Sim.new(1, 60)
	for i: int in 1440:  # 144 fps for 10 s
		fast.advance(1.0 / 144.0)
	for i: int in 300:  # 30 fps for 10 s
		slow.advance(1.0 / 30.0)
	assert_int(fast.tick).is_equal(600)
	assert_int(slow.tick).is_equal(600)


func test_same_seed_and_inputs_give_same_hash() -> void:
	var a: Sim = _make_sim(42)
	var b: Sim = _make_sim(42)
	for i: int in 600:
		a.step()
		b.step()
	assert_str(a.state_hash()).is_equal(b.state_hash())


func test_different_seed_gives_different_hash() -> void:
	var a: Sim = _make_sim(42)
	var b: Sim = _make_sim(43)
	for i: int in 60:
		a.step()
		b.step()
	assert_str(a.state_hash()).is_not_equal(b.state_hash())
