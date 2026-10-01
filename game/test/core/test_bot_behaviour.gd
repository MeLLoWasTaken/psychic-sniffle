extends GdUnitTestSuite
## The behaviours backlog item M1-13 asks bots for: interrupt casts, use defensives when low,
## heal the lowest ally, and break line of sight when losing. Each test places units by hand,
## gives only the unit under test a brain, and runs the real server pipeline (MatchRunner).

var runner: MatchRunner
var war: Unit
var ora_a: Unit
var arc: Unit
var ora_b: Unit
var brains: Dictionary = {}
var events: Array = []


func before_test() -> void:
	runner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 0.0, 5)
	war = runner.add_unit("warblade_carnage", 0)
	arc = runner.add_unit("arcanist_rime", 1)
	ora_a = runner.add_unit("oracle_grace", 0)
	ora_b = runner.add_unit("oracle_grace", 1)
	brains = {}
	events = []
	runner.sim.add_system(runner.bot_system(brains))
	runner.sim.add_system(runner.system_combat_and_rules)
	runner.sim.step()  # no preparation phase: the match is active and the gates are open
	_park_everyone()


func after_test() -> void:
	runner.sim._systems.clear()


## Move everyone to harmless corners so each test sets up only the units it needs.
func _park_everyone() -> void:
	war.position = Vector3(-17, 0, 17)
	ora_a.position = Vector3(-17, 0, 15)
	arc.position = Vector3(17, 0, -17)
	ora_b.position = Vector3(17, 0, -15)


func _brain(u: Unit) -> void:
	brains[u.id] = BotBrain.new(u.spec_id, 11, runner.geometry)


func _run(ticks: int) -> void:
	for i: int in ticks:
		runner.sim.step()
		events.append_array(runner.take_events())


func _casts_by(u: Unit) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["type"] == "cast_success" and int(e["source"]) == u.id)


func test_warblade_interrupts_a_cast_in_melee_range() -> void:
	_brain(war)
	war.position = Vector3(0, 0, 8)
	arc.position = Vector3(0, 0, 11)
	ora_b.position = Vector3(0, 0, -10)  # behind the central block, so the caster is the only target
	runner.combat.press(arc, "rime_bolt", war.id)
	assert_bool(arc.is_casting()).is_true()
	var cast_end: int = int(arc.cast["end_tick"])
	_run(cast_end - runner.sim.tick)
	var interrupts: Array = events.filter(func(e: Dictionary) -> bool: return e["type"] == "interrupt")
	assert_int(interrupts.size()).is_equal(1)
	assert_int(int(interrupts[0]["source"])).is_equal(war.id)
	assert_int(int(interrupts[0]["target"])).is_equal(arc.id)


func test_oracle_interrupts_a_cast_in_range() -> void:
	_brain(ora_a)
	ora_a.position = Vector3(-4, 0, 12)
	arc.position = Vector3(4, 0, 12)
	runner.combat.press(arc, "rime_bolt", ora_a.id)
	var cast_end: int = int(arc.cast["end_tick"])
	_run(cast_end - runner.sim.tick)
	var interrupts: Array = events.filter(func(e: Dictionary) -> bool: return e["type"] == "interrupt")
	assert_int(interrupts.size()).is_equal(1)
	assert_int(int(interrupts[0]["source"])).is_equal(ora_a.id)


func test_low_health_bots_use_a_defensive() -> void:
	for u: Unit in [war, arc, ora_a]:
		_brain(u)
		u.health = roundi(u.max_health * 0.3)
	war.position = Vector3(-10, 0, 12)
	ora_a.position = Vector3(-12, 0, 12)
	arc.position = Vector3(10, 0, 12)
	_run(30)
	for u: Unit in [war, arc, ora_a]:
		var defensive: Array = _casts_by(u).filter(func(e: Dictionary) -> bool:
			return Data.abilities[e["ability"]]["kit_slot"] == "defensive")
		assert_int(defensive.size()).override_failure_message("%s used no defensive at 30%% health" % u.spec_id).is_greater(0)


func test_healer_heals_the_lowest_ally() -> void:
	_brain(ora_a)
	war.position = Vector3(-6, 0, 12)
	ora_a.position = Vector3(-12, 0, 12)
	war.health = roundi(war.max_health * 0.5)
	ora_a.health = roundi(ora_a.max_health * 0.9)
	_run(3 * runner.sim.tick_rate)
	var heals: Array = events.filter(func(e: Dictionary) -> bool: return e["type"] == "heal" and int(e["source"]) == ora_a.id)
	assert_int(heals.size()).is_greater(0)
	assert_int(int(heals[0]["target"])).is_equal(war.id)
	assert_int(war.health).is_greater(roundi(war.max_health * 0.5))


func test_losing_caster_breaks_line_of_sight() -> void:
	_brain(arc)
	arc.health = roundi(arc.max_health * 0.2)
	war.position = Vector3(-12, 0, -2)  # an enemy that can see the arcanist but is not chasing
	arc.position = Vector3(-3, 0, 10)
	var eye: Vector3 = Vector3.UP * Combat.EYE_HEIGHT
	var chest: Vector3 = Vector3.UP * Combat.CHEST_HEIGHT
	assert_bool(runner.geometry.has_line_of_sight(war.position + eye, arc.position + chest)).is_true()
	_run(4 * runner.sim.tick_rate)
	assert_bool(runner.geometry.has_line_of_sight(war.position + eye, arc.position + chest)).is_false()


## Regression (review pass 2): two low-health Warblades in a 1v1 circled a pillar for the whole
## match, each "hiding" from the other. Hiding from a melee enemy is pointless for a melee bot,
## and without a healer there is nothing to wait for, so they fight it out.
func test_low_health_melee_duel_keeps_fighting() -> void:
	var duel: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "1v1", 0.0, 7)
	var a: Unit = duel.add_unit("warblade_carnage", 0)
	var b: Unit = duel.add_unit("warblade_carnage", 1)
	var duel_brains: Dictionary = {}
	duel.sim.add_system(duel.bot_system(duel_brains))
	duel.sim.add_system(duel.system_combat_and_rules)
	duel.sim.step()
	for u: Unit in [a, b]:
		duel_brains[u.id] = BotBrain.new(u.spec_id, 3 + u.id, duel.geometry)
		u.health = roundi(u.max_health * 0.2)
	a.position = Vector3(-6, 0, -6)  # beside a pillar
	b.position = Vector3(-4, 0, -6)
	# from a fifth of their health a real fight ends within seconds; the stalemate never ended
	var ended_s: float = -1.0
	for i: int in 30 * duel.sim.tick_rate:
		duel.sim.step()
		duel.take_events()
		if a.health <= 0 or b.health <= 0:
			ended_s = float(i) / duel.sim.tick_rate
			break
	assert_float(ended_s).override_failure_message("the duel stalled: nobody died in 30 s").is_greater_equal(0.0)
	duel.sim._systems.clear()


func test_a_hurt_bot_goes_for_an_active_pickup() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "1v1", 0.0, 4)
	var nav: NavGrid = NavGrid.new(runner.geometry)
	var bot: Unit = runner.add_unit("oracle_grace", 0)
	runner.add_unit("warblade_carnage", 1)  # no brain: stays in its room
	var brains: Dictionary = {bot.id: BotBrain.new("oracle_grace", 41, runner.geometry, nav)}
	runner.sim.add_system(runner.bot_system(brains))
	runner.sim.add_system(runner.system_combat_and_rules)
	runner.sim.step()
	bot.position = Vector3(-10, 0, 10)
	bot.health = 20000
	for p: Dictionary in runner.arena.pickups:
		p["active"] = true
	runner.arena._pickups_spawned = true
	var took: bool = false
	for i: int in 15 * 60:
		runner.sim.step()
		for e: Dictionary in runner.take_events():
			if e["type"] == "pickup_taken" and int(e["target"]) == bot.id:
				took = true
		if took:
			break
	assert_bool(took).override_failure_message("the bot at %s never reached a pickup" % bot.position).is_true()
