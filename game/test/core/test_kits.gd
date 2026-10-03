extends GdUnitTestSuite
## M1-10 to M1-12: each kit's unique mechanics, using the real kit data.

const TR: int = 60

var sim: Sim
var cb: Combat
var war: Unit
var arc: Unit
var ora: Unit
var foe_heal: Unit


func before_test() -> void:
	var tuning: Dictionary = Data.tuning.duplicate(true)
	tuning["combat"]["crit_chance"] = 0.0
	sim = Sim.new(1, TR)
	cb = Combat.new(sim, tuning, Data.abilities, Data.auras, Data.specs, Data.classes, null)
	war = _spawn(1, 0, "warblade_carnage", Vector3(0, 0, 0))
	arc = _spawn(2, 1, "arcanist_rime", Vector3(0, 0, -4))
	ora = _spawn(3, 1, "oracle_grace", Vector3(3, 0, -6))
	foe_heal = _spawn(4, 0, "oracle_grace", Vector3(-3, 0, 2))


func _spawn(id: int, team: int, spec: String, pos: Vector3) -> Unit:
	var u: Unit = Unit.new(id, team, spec)
	cb.init_unit(u)
	u.stats["crit_chance"] = 0.0
	u.position = pos
	sim.add_unit(u)
	return u


func _run(ticks: int) -> void:
	for i: int in ticks:
		cb.tick()
		sim.tick += 1


func _ready_all() -> void:
	for u: Unit in sim.units.values():
		u.gcd_ready_tick = 0
		u.cooldowns.clear()


## Base amount of an ability's first effect, so tests follow balance changes in data.
func _base(ability: String) -> int:
	return int(Data.abilities[ability]["effects"][0]["base"])


func _fail() -> String:
	for i: int in range(cb.events.size() - 1, -1, -1):
		if cb.events[i]["type"] == "cast_failed":
			return cb.events[i]["reason"]
	return ""


# ------------------------------------------------------------ Warblade Carnage (M1-10)

func test_kit_sizes_fill_the_template() -> void:
	for spec: String in ["warblade_carnage", "arcanist_rime", "oracle_grace"]:
		assert_str(Data.specs[spec]["kit_status"]).is_equal("complete")
		assert_int(Data.specs[spec]["abilities"].size()).is_between(14, 18)


func test_rage_is_built_then_spent() -> void:
	assert_float(war.resources["rage"]).is_equal(0.0)
	cb.press(war, "wide_hew", 2)
	assert_str(_fail()).is_equal("no_resource")
	cb.press(war, "grim_hack", 2)
	# abilities give only their own fixed rage; damage they deal gives none
	assert_float(war.resources["rage"]).is_equal_approx(12.0, 0.01)
	war.resources["rage"] = 20.0
	_ready_all()
	cb.press(war, "wide_hew", 2)
	assert_float(war.resources["rage"]).is_equal_approx(0.0, 0.01)  # a spender never refunds itself


func test_auto_attacks_and_damage_taken_build_rage() -> void:
	var per_1000: float = float(Data.tuning["resources"]["rage"]["per_1000_auto_attack_damage"])
	var swing: int = roundi(float(Data.tuning["damage"]["auto_attack"]["base_damage"]) * 0.9)  # cloth
	war.target_id = 2
	var hp_before: int = arc.health
	_run(roundi(2.0 * TR) + 2)
	var hits: int = (hp_before - arc.health) / swing
	assert_int(hits).is_greater_equal(1)
	assert_float(war.resources["rage"]).is_greater_equal(swing / 1000.0 * per_1000 - 0.5)
	var rage: float = war.resources["rage"]
	cb.deal_damage(arc, war, 5000.0, "frost", {"id": "test"}, 0.0)
	assert_float(war.resources["rage"]).is_greater(rage)


func test_headsmans_verdict_only_below_20_percent() -> void:
	war.resources["rage"] = 100.0
	cb.press(war, "headsmans_verdict", 2)
	assert_str(_fail()).is_equal("target_health_too_high")
	arc.health = 11000
	cb.press(war, "headsmans_verdict", 2)
	assert_bool(arc.is_alive()).is_false()


func test_gashing_blow_cuts_healing() -> void:
	war.resources["rage"] = 100.0
	cb.press(war, "gashing_blow", 2)
	arc.health = 30000
	cb.press(ora, "swift_benediction", 2)
	_run(roundi(1.3 * TR / 1.1) + 1)  # Oracle has 10% haste
	var mult: float = Data.auras["gashed"]["modifiers"][0]["value"]
	assert_float(mult).is_less(1.0)
	assert_int(arc.health).is_equal(30000 + roundi(_base("swift_benediction") * mult))


func test_warpath_charge_closes_distance_and_stuns() -> void:
	arc.position = Vector3(0, 0, -20)
	cb.press(war, "warpath_charge", 2)
	assert_float(war.position.distance_to(arc.position)).is_less(2.0)
	assert_bool(cb.has_aura(arc, "charge_dazed")).is_true()
	assert_float(war.resources["rage"]).is_greater_equal(20.0)


# ------------------------------------------------------------ Arcanist Rime (M1-11)

func test_shiver_lance_triples_on_frozen_targets() -> void:
	arc.position = Vector3(0, 0, -20)
	cb.press(arc, "shiver_lance", 1)
	var normal: int = war.max_health - war.health
	assert_int(normal).is_equal(_base("shiver_lance"))  # frost is magic: plate armor does not reduce it
	war.health = war.max_health
	cb.apply_aura(arc, war, "rimebound")
	_ready_all()
	cb.press(arc, "shiver_lance", 1)
	assert_int(war.max_health - war.health).is_equal(_base("shiver_lance") * 3)


func test_heartfreeze_needs_a_frozen_target() -> void:
	cb.press(arc, "heartfreeze", 1)
	assert_str(_fail()).is_equal("target_not_controlled")
	cb.apply_aura(arc, war, "rimebound")
	cb.press(arc, "heartfreeze", 1)
	assert_bool(cb.has_aura(war, "heartfrozen")).is_true()


func test_spellsever_locks_holy_for_4_s() -> void:
	cb.press(foe_heal, "mending_light", 4)
	_run(10)
	cb.press(arc, "spellsever", 4)
	assert_bool(foe_heal.is_casting()).is_false()
	_ready_all()
	cb.press(foe_heal, "mending_light", 4)
	assert_str(_fail()).is_equal("school_locked")
	_run(4 * TR - 1)
	_ready_all()
	cb.press(foe_heal, "mending_light", 4)
	assert_str(_fail()).is_equal("school_locked")  # one tick before the 4 s lock ends
	_run(1)
	_ready_all()
	cb.press(foe_heal, "mending_light", 4)
	assert_bool(foe_heal.is_casting()).is_true()


func test_frost_step_breaks_a_root_and_moves_15_m() -> void:
	cb.apply_aura(war, arc, "rimebound")  # use any source for the root
	arc.facing = 0.0
	var start: Vector3 = arc.position
	cb.press(arc, "frost_step", 1)
	assert_bool(cb.has_aura(arc, "rimebound")).is_false()
	assert_float(arc.position.distance_to(start)).is_equal_approx(15.0, 0.01)


func test_rime_sepulcher_blocks_damage_and_actions() -> void:
	cb.press(arc, "rime_sepulcher_ab", 2)
	war.resources["rage"] = 100.0
	cb.press(war, "grim_hack", 2)
	assert_int(arc.health).is_equal(arc.max_health)
	cb.press(arc, "shiver_lance", 1)
	assert_str(_fail()).is_equal("pacified")


# ------------------------------------------------------------ Oracle Grace (M1-12)

func test_absolve_removes_a_magic_slow_from_an_ally() -> void:
	cb.apply_aura(foe_heal, arc, "chilled")
	cb.press(ora, "absolve", 2)
	assert_bool(cb.has_aura(arc, "chilled")).is_false()


func test_healing_is_reduced_by_dampening() -> void:
	var geo_arena: ArenaMatch = ArenaMatch.new(Data.tuning, "2v2", TR, null, 0)
	cb.arena = geo_arena
	geo_arena.update(geo_arena.start_tick, sim.units)
	sim.tick = geo_arena.start_tick + 180 * TR + 90 * TR  # 10 steps of dampening = 10%
	arc.health = 20000
	cb.press(ora, "mending_light", 2)
	_run(roundi(2.0 * TR / 1.1) + 1)
	assert_int(arc.health).is_equal(20000 + roundi(_base("mending_light") * 0.9))


func test_shields_are_dampened_like_healing() -> void:
	var geo_arena: ArenaMatch = ArenaMatch.new(Data.tuning, "2v2", TR, null, 0)
	cb.arena = geo_arena
	geo_arena.update(geo_arena.start_tick, sim.units)
	sim.tick = geo_arena.start_tick + 180 * TR + 90 * TR  # 10% dampening
	cb.apply_aura(arc, arc, "glacier_shield")
	for inst: Dictionary in arc.auras:
		if inst["id"] == "glacier_shield":
			assert_int(int(inst["absorb_left"])).is_equal(roundi(12000 * 0.9))


func test_psalm_of_dread_makes_nearby_enemies_flee() -> void:
	war.position = Vector3(3, 0, -9)
	cb.press(ora, "psalm_of_dread", 3)
	assert_bool(cb.has_aura(war, "psalm_dread")).is_true()
	var forced: Dictionary = cb.forced_input(war)
	assert_bool(forced.is_empty()).is_false()
	var away: Vector3 = Movement.forward_of(forced["yaw"])
	assert_float(away.dot((war.position - ora.position).normalized())).is_greater(0.9)
	# the run keeps the direction the fear set when it landed, wherever the Oracle goes next (X-22)
	ora.position = war.position + away * 4.0
	assert_float(cb.forced_input(war)["yaw"]).is_equal(forced["yaw"])
