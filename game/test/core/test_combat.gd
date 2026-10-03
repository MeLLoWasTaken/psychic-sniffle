extends GdUnitTestSuite
## Acceptance tests for the combat core (backlog M1-01 to M1-08).
## Uses small made-up abilities and auras so each rule is tested on its own.

const TR: int = 60

var sim: Sim
var cb: Combat
var me: Unit
var foe: Unit
var abilities: Dictionary
var auras: Dictionary


func _ab(id: String, extra: Dictionary) -> Dictionary:
	var a: Dictionary = {"id": id, "name": id, "owner": "test", "kit_slot": "core", "school": "fire",
		"cast_type": "instant", "cooldown_s": 0, "triggers_gcd": true, "range_m": 40, "requires_los": true,
		"target": "enemy", "effects": [], "icon": {"symbol": "x"}}
	a.merge(extra, true)
	return a


func _aura(id: String, extra: Dictionary) -> Dictionary:
	var a: Dictionary = {"id": id, "name": id, "kind": "debuff", "duration_s": 10, "dispel_type": "magic",
		"cc_category": "none", "hud_priority": "normal"}
	a.merge(extra, true)
	return a


func before_test() -> void:
	abilities = {
		"bolt": _ab("bolt", {"effects": [{"type": "damage", "base": 1000}]}),
		"slow_bolt": _ab("slow_bolt", {"cast_type": "cast", "cast_time_s": 2.0, "effects": [{"type": "damage", "base": 5000}]}),
		"beam": _ab("beam", {"cast_type": "channel", "cast_time_s": 3.0, "channel_ticks": 3, "effects": [{"type": "damage", "base": 700}]}),
		"strike": _ab("strike", {"school": "physical", "range_m": 5, "effects": [{"type": "damage", "base": 1000}]}),
		"costly": _ab("costly", {"cost": {"resource": "mana", "amount": 60000}, "effects": []}),
		"rune_strike": _ab("rune_strike", {"triggers_gcd": false, "cost": {"resource": "runes", "amount": 2},
			"generates": {"resource": "runic_power", "amount": 20}, "effects": [{"type": "damage", "base": 100}]}),
		"tether": _ab("tether", {"school": "shadow", "triggers_gcd": false, "range_m": 30, "effects": [{"type": "pull", "distance_m": 2.0}]}),
		"rune_tap": _ab("rune_tap", {"triggers_gcd": false, "target": "self",
			"effects": [{"type": "resource", "resource": "runes", "amount": 1}]}),
		"kick": _ab("kick", {"school": "physical", "triggers_gcd": false, "cooldown_s": 15, "effects": [{"type": "interrupt", "school_lock_s": 4}]}),
		"stun": _ab("stun", {"school": "physical", "triggers_gcd": false, "effects": [{"type": "apply_aura", "aura": "stunned"}]}),
		"poly": _ab("poly", {"triggers_gcd": false, "effects": [{"type": "apply_aura", "aura": "sheeped"}]}),
		"burn": _ab("burn", {"triggers_gcd": false, "effects": [{"type": "apply_aura", "aura": "burning"}]}),
		"stack": _ab("stack", {"triggers_gcd": false, "target": "self", "effects": [{"type": "apply_aura", "aura": "rage_stack"}]}),
		"cleanse": _ab("cleanse", {"target": "ally", "triggers_gcd": false, "effects": [{"type": "dispel", "dispel_types": ["magic"]}]}),
		"free": _ab("free", {"school": "physical", "triggers_gcd": false, "target": "self", "cooldown_s": 90,
			"usable_while_cc": ["stun", "incapacitate", "disorient", "silence", "root"], "effects": [{"type": "remove_cc"}]}),
		"frostbolt": _ab("frostbolt", {"school": "frost", "cast_type": "cast", "cast_time_s": 2.0, "effects": [{"type": "damage", "base": 100}]}),
		"quick": _ab("quick", {"cast_type": "cast", "cast_time_s": 2.0, "castable_while_moving": true, "effects": []}),
		"execute": _ab("execute", {"school": "physical", "range_m": 5, "usable_if": {"target_health_below_pct": 20}, "effects": []}),
	}
	auras = {
		"stunned": _aura("stunned", {"duration_s": 6, "cc_category": "stun", "dispel_type": "none", "hud_priority": "cc"}),
		"sheeped": _aura("sheeped", {"duration_s": 8, "cc_category": "incapacitate", "breaks_on_damage": "any", "hud_priority": "cc"}),
		"burning": _aura("burning", {"duration_s": 6, "periodic": {"interval_s": 2, "effect": {"type": "damage", "base": 300, "can_crit": false, "school": "fire"}}}),
		"rage_stack": _aura("rage_stack", {"kind": "buff", "duration_s": 5, "max_stacks": 3, "refresh": "add_stack", "dispel_type": "none",
			"modifiers": [{"stat": "damage_done", "op": "multiply", "value": 1.1}]}),
	}
	var tuning: Dictionary = Data.tuning.duplicate(true)
	tuning["combat"]["crit_chance"] = 0.0  # exact numbers in tests
	sim = Sim.new(1, TR)
	cb = Combat.new(sim, tuning, abilities, auras, {}, {}, null)
	me = _unit(1, 0, "cloth")
	foe = _unit(2, 1, "cloth")
	foe.position = Vector3(0, 0, -10)


func _unit(id: int, team: int, armor: String) -> Unit:
	var u: Unit = Unit.new(id, team, "test")
	u.armor = armor
	u.stats = {"power_bonus": 0.0, "haste": 0.0, "crit_chance": 0.0}
	u.known_abilities.assign(abilities.keys())
	u.resource_max = {"mana": 50000.0}
	u.resources = {"mana": 50000.0}
	sim.add_unit(u)
	return u


func _run(ticks: int) -> void:
	for i: int in ticks:
		cb.tick()
		sim.tick += 1


func _count(type: String) -> int:
	var n: int = 0
	for e: Dictionary in cb.events:
		if e["type"] == type:
			n += 1
	return n


func _last_fail() -> String:
	for i: int in range(cb.events.size() - 1, -1, -1):
		if cb.events[i]["type"] == "cast_failed":
			return cb.events[i]["reason"]
	return ""


# ------------------------------------------------------------ M1-01 ability system

func test_instant_cast_and_channel_from_data_only() -> void:
	cb.press(me, "bolt", 2)
	assert_int(foe.health).is_equal(60000 - 1000)
	_run(90)  # past the GCD
	cb.press(me, "slow_bolt", 2)
	_run(119)
	assert_int(foe.health).is_equal(59000)  # not finished yet
	_run(1)
	assert_int(foe.health).is_equal(59000 - 5000)
	_run(90)
	cb.press(me, "beam", 2)
	_run(181)
	assert_int(foe.health).is_equal(54000 - 3 * 700)
	assert_int(_count("channel_end")).is_equal(1)


# ------------------------------------------------------------ M1-02 GCD and spell queue

func test_gcd_blocks_then_releases_after_1_5_s() -> void:
	cb.press(me, "bolt", 2)
	_run(30)  # 1.0 s left on the GCD: outside the 400 ms window
	cb.press(me, "bolt", 2)
	assert_str(_last_fail()).is_equal("not_ready")
	_run(60)
	cb.press(me, "bolt", 2)
	assert_int(foe.health).is_equal(58000)


func test_press_inside_queue_window_fires_on_first_tick_after_gcd() -> void:
	cb.press(me, "bolt", 2)  # GCD ends at tick 90
	_run(66)  # 400 ms before the end
	cb.press(me, "bolt", 2)
	assert_int(foe.health).is_equal(59000)  # queued, not fired
	_run(24)  # tick 90: queued press fires this tick
	assert_int(foe.health).is_equal(59000)
	_run(1)
	assert_int(foe.health).is_equal(58000)


func test_press_500ms_before_gcd_end_is_rejected_and_100ms_is_queued() -> void:
	cb.press(me, "bolt", 2)
	_run(60)  # 500 ms left
	cb.press(me, "bolt", 2)
	assert_str(_last_fail()).is_equal("not_ready")
	_run(24)  # 100 ms left
	cb.press(me, "bolt", 2)
	_run(7)
	assert_int(foe.health).is_equal(58000)


func test_haste_shortens_gcd_to_a_floor_of_0_75_s() -> void:
	me.stats["haste"] = 3.0  # would give 0.375 s without the floor
	cb.press(me, "bolt", 2)
	assert_int(me.gcd_ready_tick - sim.tick).is_equal(45)


func test_energy_users_have_a_fixed_1_s_gcd_that_haste_does_not_shorten() -> void:
	# DESIGN.md: energy specs use a fixed 1.0 s global cooldown (no energy class until M3; a test unit)
	me.primary_resource = "energy"
	cb.press(me, "bolt", 2)
	assert_int(me.gcd_ready_tick - sim.tick).is_equal(60)
	_run(61)
	me.stats["haste"] = 1.0  # halves a normal global cooldown, not this one
	cb.press(me, "bolt", 2)
	assert_int(me.gcd_ready_tick - sim.tick).is_equal(60)


# ------------------------------------------------------------ M1-03 resources

func test_cannot_cast_without_resource_and_mana_regenerates() -> void:
	cb.press(me, "costly", 2)
	assert_str(_last_fail()).is_equal("no_resource")
	me.resources["mana"] = 1000.0
	_run(60)
	assert_float(me.resources["mana"]).is_equal_approx(1400.0, 0.01)


func test_rage_builds_from_damage_and_decays_out_of_combat() -> void:
	foe.resource_max = {"rage": 100.0}
	foe.resources = {"rage": 0.0}
	cb.press(me, "bolt", 2)  # 1000 damage taken -> 6 rage
	assert_float(foe.resources["rage"]).is_equal_approx(6.0, 0.001)
	_run(TR * 6)  # combat ends after 5 s, then decays 2 per second
	assert_float(foe.resources["rage"]).is_equal_approx(6.0 - 2.0, 0.05)


func _rune_user() -> void:
	me.resource_max = {"runic_power": 100.0, "runes": 6.0}
	me.resources = {"runic_power": 0.0, "runes": 6.0}


func test_runes_recharge_three_at_a_time_and_build_runic_power() -> void:
	_rune_user()  # M3-08: six runes, 10 s each, three recharging at once
	cb.press(me, "rune_strike", 2)
	assert_float(me.resources["runes"]).is_equal(4.0)
	assert_float(me.resources["runic_power"]).is_equal(20.0)
	cb.press(me, "rune_strike", 2)
	cb.press(me, "rune_strike", 2)
	assert_float(me.resources["runes"]).is_equal(0.0)
	cb.press(me, "rune_strike", 2)
	assert_str(_last_fail()).is_equal("no_resource")
	assert_int(me.recharges["runes"].size()).is_equal(6)
	_run(TR * 10 - 1)
	assert_float(me.resources["runes"]).is_equal(0.0)
	_run(1)  # the first three come back together after 10 s, the other three start then
	assert_float(me.resources["runes"]).is_equal(3.0)
	_run(TR * 5)
	assert_float(me.resources["runes"]).is_equal(3.0)
	assert_float(float(me.recharges["runes"][0])).is_equal_approx(5.0, 0.02)
	_run(TR * 5)
	assert_float(me.resources["runes"]).is_equal(6.0)
	assert_bool((me.recharges["runes"] as Array).is_empty()).is_true()


func test_two_runes_spent_from_full_come_back_together() -> void:
	_rune_user()
	cb.press(me, "rune_strike", 2)
	_run(TR * 5)
	assert_float(me.resources["runes"]).is_equal(4.0)  # whole runes only, both halfway
	_run(TR * 5)
	assert_float(me.resources["runes"]).is_equal(6.0)


func test_a_rune_refund_keeps_running_recharges() -> void:
	_rune_user()
	cb.press(me, "rune_strike", 2)
	cb.press(me, "rune_strike", 2)
	cb.press(me, "rune_strike", 2)
	_run(TR * 4)
	cb.press(me, "rune_tap", -1)  # one rune back: the last queued recharge goes, the running ones keep 6 s left
	assert_float(me.resources["runes"]).is_equal(1.0)
	assert_int(me.recharges["runes"].size()).is_equal(5)
	assert_float(float(me.recharges["runes"][0])).is_equal_approx(6.0, 0.02)
	_run(TR * 6)
	assert_float(me.resources["runes"]).is_equal(4.0)


func test_a_pull_drags_the_target_in_front_of_the_caster_and_stops_its_cast() -> void:
	foe.position = Vector3(0, 0, -20)  # M3: the Deathsworn's tether
	foe.known_abilities.assign(abilities.keys())
	foe.target_id = me.id
	cb.press(foe, "slow_bolt", me.id)
	assert_bool(foe.is_casting()).is_true()
	cb.press(me, "tether", foe.id)
	assert_float(foe.position.distance_to(Vector3(0, 0, -2))).is_less(0.01)
	assert_bool(foe.is_casting()).is_false()
	assert_int(foe.displaced_tick).is_equal(sim.tick)
	assert_int(_count("pull")).is_equal(1)


func test_crowd_control_immunity_stops_a_pull() -> void:
	foe.position = Vector3(0, 0, -20)
	auras["unshakable"] = _aura("unshakable", {"kind": "buff", "dispel_type": "none", "immune": ["cc"]})
	cb.apply_aura(foe, foe, "unshakable")
	cb.press(me, "tether", foe.id)
	assert_float(foe.position.z).is_equal(-20.0)


# ------------------------------------------------------------ M1-04 auras

func test_periodic_damage_and_expiry() -> void:
	cb.press(me, "burn", 2)
	_run(TR * 7)
	assert_int(foe.health).is_equal(60000 - 3 * 300)
	assert_bool(cb.has_aura(foe, "burning")).is_false()


func test_stacking_buff_caps_at_max_stacks() -> void:
	for i: int in 5:
		cb.press(me, "stack", 1)
	assert_int(me.auras[0]["stacks"]).is_equal(3)
	cb.press(me, "bolt", 2)
	assert_int(foe.health).is_equal(60000 - roundi(1000 * pow(1.1, 3)))


func test_dispel_removes_a_magic_debuff_from_an_ally() -> void:
	var ally: Unit = _unit(3, 0, "cloth")
	cb.press(foe, "burn", 3)
	assert_bool(cb.has_aura(ally, "burning")).is_true()
	cb.press(me, "cleanse", 3)
	assert_bool(cb.has_aura(ally, "burning")).is_false()


# ------------------------------------------------------------ M1-05 damage formula

func test_physical_damage_by_armor_type() -> void:
	var expected: Dictionary = {"cloth": 900, "leather": 800, "mail": 750, "plate": 700}
	for armor: String in expected:
		foe.health = 60000
		foe.armor = armor
		foe.position = Vector3(0, 0, -3)
		me.gcd_ready_tick = 0
		cb.press(me, "strike", 2)
		assert_int(60000 - foe.health).override_failure_message(armor).is_equal(expected[armor])


func test_magic_ignores_armor_and_crits_multiply_by_1_5() -> void:
	foe.armor = "plate"
	me.stats["crit_chance"] = 1.0
	cb.press(me, "bolt", 2)
	assert_int(60000 - foe.health).is_equal(1500)


# ------------------------------------------------------------ M1-06 casting and interrupts

func test_moving_cancels_a_cast_unless_castable_while_moving() -> void:
	cb.press(me, "slow_bolt", 2)
	_run(10)
	me.moved_this_tick = true
	_run(1)
	assert_bool(me.is_casting()).is_false()
	assert_int(_count("cast_interrupted")).is_equal(1)
	_run(90)
	cb.press(me, "quick", 2)
	me.moved_this_tick = true
	_run(1)
	assert_bool(me.is_casting()).is_true()


func test_interrupt_locks_the_school_and_other_schools_still_work() -> void:
	foe.position = Vector3(0, 0, -3)
	cb.press(foe, "slow_bolt", 1)  # fire
	_run(30)
	cb.press(me, "kick", 2)
	assert_bool(foe.is_casting()).is_false()
	_run(1)
	cb.press(foe, "slow_bolt", 1)
	assert_str(_last_fail()).is_equal("school_locked")
	foe.gcd_ready_tick = 0  # the interrupted cast's GCD is not what this test checks
	cb.press(foe, "frostbolt", 1)  # frost is not locked
	assert_bool(foe.is_casting()).is_true()
	foe.cast = {}
	_run(TR * 4)
	foe.gcd_ready_tick = 0
	cb.press(foe, "slow_bolt", 1)  # lock over after 4 s
	assert_bool(foe.is_casting()).is_true()


# ------------------------------------------------------------ M1-07 crowd control

func test_stun_diminishing_returns_100_50_25_then_immune() -> void:
	var durations: Array[int] = []
	for i: int in 4:
		cb.events.clear()
		cb.press(me, "stun", 2)
		var applied: Array = cb.events.filter(func(e: Dictionary) -> bool: return e["type"] == "aura_applied")
		durations.append(applied[0]["duration_ticks"] if applied else 0)
		foe.auras.clear()
	assert_array(durations).is_equal([6 * TR, 3 * TR, roundi(1.5 * TR), 0])


func test_dr_resets_18_s_after_the_last_cc_ends() -> void:
	cb.press(me, "stun", 2)
	_run(6 * TR)  # stun expires
	_run(18 * TR + 1)
	cb.events.clear()
	cb.press(me, "stun", 2)
	var applied: Array = cb.events.filter(func(e: Dictionary) -> bool: return e["type"] == "aura_applied")
	assert_int(applied[0]["duration_ticks"]).is_equal(6 * TR)


func test_no_cc_lasts_longer_than_8_s() -> void:
	auras["sheeped"]["duration_s"] = 20
	cb.press(me, "poly", 2)
	assert_int(foe.auras[0]["expires_tick"] - sim.tick).is_equal(8 * TR)


func test_incapacitate_breaks_on_damage() -> void:
	cb.press(me, "poly", 2)
	cb.press(me, "bolt", 2)
	assert_bool(cb.has_aura(foe, "sheeped")).is_false()


func test_stun_blocks_abilities_but_break_free_removes_it() -> void:
	foe.position = Vector3(0, 0, -3)
	cb.press(me, "stun", 2)
	cb.press(foe, "bolt", 1)
	assert_str(_last_fail()).is_equal("stun")
	cb.press(foe, "free", 2)
	assert_bool(cb.has_aura(foe, "stunned")).is_false()
	cb.press(foe, "bolt", 1)
	assert_int(me.health).is_equal(59000)


func test_execute_only_usable_below_20_percent() -> void:
	foe.position = Vector3(0, 0, -3)
	cb.press(me, "execute", 2)
	assert_str(_last_fail()).is_equal("target_health_too_high")
	foe.health = 11000
	cb.press(me, "execute", 2)
	assert_int(_count("cast_success")).is_equal(1)


# ------------------------------------------------------------ M1-08 line of sight

func test_cast_fails_if_target_steps_behind_a_pillar_before_it_finishes() -> void:
	cb.geometry = preload("res://test/fixtures/fixture_map.gd").geometry()
	me.position = Vector3(7, 0, -14)
	foe.position = Vector3(3, 0, -7)  # visible, west of the pillar at (7, -7)
	cb.press(me, "slow_bolt", 2)
	_run(60)
	foe.position = Vector3(7, 0, -3)  # now directly behind the pillar
	_run(60)
	assert_str(_last_fail()).is_equal("line_of_sight")
	assert_int(foe.health).is_equal(60000)


# ------------------------------------------------------------ M2-01 rules without a test until now

func _learn(id: String, ab: Dictionary) -> void:
	abilities[id] = ab
	for u: Unit in [me, foe]:
		u.known_abilities.append(id)


func test_only_the_strongest_slow_applies() -> void:
	auras["chill"] = _aura("chill", {"modifiers": [{"stat": "move_speed", "op": "multiply", "value": 0.5}]})
	auras["hobble"] = _aura("hobble", {"modifiers": [{"stat": "move_speed", "op": "multiply", "value": 0.7}]})
	auras["sprint"] = _aura("sprint", {"kind": "buff", "modifiers": [{"stat": "move_speed", "op": "multiply", "value": 1.3}]})
	assert_float(Combat.speed_multiplier_from([{"id": "chill"}, {"id": "hobble"}], auras)).is_equal_approx(0.5, 0.0001)
	assert_float(Combat.speed_multiplier_from([{"id": "hobble"}], auras)).is_equal_approx(0.7, 0.0001)
	# a speed boost still counts on top of the strongest slow
	assert_float(Combat.speed_multiplier_from([{"id": "chill"}, {"id": "hobble"}, {"id": "sprint"}], auras)).is_equal_approx(0.65, 0.0001)


func test_power_bonus_damage_taken_and_pvp_modifier_scale_damage() -> void:
	me.stats["power_bonus"] = 0.5
	cb.press(me, "bolt", 2)
	assert_int(60000 - foe.health).is_equal(1500)  # 1000 x (1 + 0.5)
	auras["exposed"] = _aura("exposed", {"modifiers": [{"stat": "damage_taken", "op": "multiply", "value": 1.2}]})
	_learn("expose", _ab("expose", {"triggers_gcd": false, "effects": [{"type": "apply_aura", "aura": "exposed"}]}))
	cb.press(me, "expose", 2)
	foe.health = 60000
	me.gcd_ready_tick = 0
	cb.press(me, "bolt", 2)
	assert_int(60000 - foe.health).is_equal(1800)  # x 1.2 damage taken
	_learn("tuned_bolt", _ab("tuned_bolt", {"pvp_modifier": 0.8, "effects": [{"type": "damage", "base": 1000}]}))
	foe.health = 60000
	me.gcd_ready_tick = 0
	cb.press(me, "tuned_bolt", 2)
	assert_int(60000 - foe.health).is_equal(1440)  # x 0.8 PvP modifier


func test_break_free_waits_90_s_between_uses() -> void:
	cb.press(me, "free", 1)
	assert_int(_count("cast_success")).is_equal(1)
	_run(89 * TR)
	cb.press(me, "free", 1)
	assert_str(_last_fail()).is_equal("not_ready")
	_run(TR)
	cb.press(me, "free", 1)
	assert_int(_count("cast_success")).is_equal(2)


func test_offensive_dispel_strips_one_magic_buff() -> void:
	auras["ward"] = _aura("ward", {"kind": "buff"})
	auras["quicken"] = _aura("quicken", {"kind": "buff"})
	auras["fury"] = _aura("fury", {"kind": "buff", "dispel_type": "none"})
	_learn("ward_up", _ab("ward_up", {"target": "self", "triggers_gcd": false,
		"effects": [{"type": "apply_aura", "aura": "ward"}, {"type": "apply_aura", "aura": "quicken"}, {"type": "apply_aura", "aura": "fury"}]}))
	_learn("purge", _ab("purge", {"triggers_gcd": false, "effects": [{"type": "dispel", "dispel_types": ["magic"]}]}))
	cb.press(foe, "ward_up", 2)
	cb.press(me, "burn", 2)  # a magic debuff on the target: an offensive dispel leaves it alone
	cb.press(me, "purge", 2)
	var magic_buffs: int = int(cb.has_aura(foe, "ward")) + int(cb.has_aura(foe, "quicken"))
	assert_int(magic_buffs).is_equal(1)
	assert_bool(cb.has_aura(foe, "fury")).is_true()
	assert_bool(cb.has_aura(foe, "burning")).is_true()
	assert_int(_count("dispel")).is_equal(1)


func test_spec_health_comes_from_the_role_template() -> void:
	var specs: Dictionary = {}
	for role: String in ["dps", "healer", "tank"]:
		specs["t_" + role] = {"class": "c", "role": role, "primary_resource": "mana", "abilities": []}
	var c2: Combat = Combat.new(sim, Data.tuning, abilities, auras, specs, {"c": {"armor": "plate"}}, null)
	var expected: Dictionary = {"dps": 60000, "healer": 60000, "tank": 72000}
	for role: String in expected:
		var u: Unit = Unit.new(10, 0, "t_" + role)
		c2.init_unit(u)
		assert_int(u.max_health).override_failure_message(role).is_equal(expected[role])
		assert_int(u.health).is_equal(expected[role])
