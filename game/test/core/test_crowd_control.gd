extends GdUnitTestSuite
## Every crowd-control category from docs/DESIGN.md (backlog M2-02): what it blocks, when it
## breaks on damage, and its diminishing returns. Test-only abilities and auras keep each rule
## separate from kit tuning.

const TR: int = 60

var sim: Sim
var cb: Combat
var me: Unit
var foe: Unit
var abilities: Dictionary
var auras: Dictionary


func _ab(id: String, extra: Dictionary) -> Dictionary:
	var a: Dictionary = {"id": id, "name": id, "owner": "test", "kit_slot": "core", "school": "fire",
		"cast_type": "instant", "cooldown_s": 0, "triggers_gcd": false, "range_m": 40, "requires_los": true,
		"target": "enemy", "effects": [], "icon": {"symbol": "x"}}
	a.merge(extra, true)
	return a


func _cc(id: String, category: String, extra: Dictionary = {}) -> Dictionary:
	var a: Dictionary = {"id": id, "name": id, "kind": "debuff", "duration_s": 6, "dispel_type": "magic",
		"cc_category": category, "hud_priority": "cc"}
	a.merge(extra, true)
	return a


func before_test() -> void:
	auras = {
		"stunned": _cc("stunned", "stun", {"dispel_type": "none"}),
		"sheeped": _cc("sheeped", "incapacitate", {"breaks_on_damage": "any"}),
		"feared": _cc("feared", "disorient", {"breaks_on_damage": "threshold", "damage_threshold_pct": 10}),
		"hushed": _cc("hushed", "silence"),
		"frozen_feet": _cc("frozen_feet", "root", {"breaks_on_damage": "threshold", "damage_threshold_pct": 20}),
		"chained": _cc("chained", "root"),
		"disarmed": _cc("disarmed", "disarm", {"dispel_type": "none"}),
	}
	abilities = {
		"bolt": _ab("bolt", {"effects": [{"type": "damage", "base": 1000}]}),
		"slash": _ab("slash", {"school": "physical", "range_m": 5, "effects": [{"type": "damage", "base": 1000}]}),
		"shove": _ab("shove", {"school": "physical", "range_m": 5, "effects": [{"type": "knockback", "distance_m": 8}]}),
		"free": _ab("free", {"school": "physical", "kit_slot": "shared", "target": "self",
			"usable_while_cc": ["stun", "incapacitate", "disorient", "silence", "root", "disarm"], "effects": [{"type": "remove_cc"}]}),
	}
	for id: String in auras:
		abilities["give_" + id] = _ab("give_" + id, {"effects": [{"type": "apply_aura", "aura": id}]})
	var tuning: Dictionary = Data.tuning.duplicate(true)
	tuning["combat"]["crit_chance"] = 0.0
	sim = Sim.new(1, TR)
	cb = Combat.new(sim, tuning, abilities, auras, {}, {}, null)
	me = _unit(1, 0)
	foe = _unit(2, 1)
	foe.position = Vector3(0, 0, -3)


func _unit(id: int, team: int) -> Unit:
	var u: Unit = Unit.new(id, team, "test")
	u.armor = "cloth"
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


func _give(aura_id: String) -> int:
	## Applies the aura to foe; returns the duration it got in ticks (0 when immune).
	cb.events.clear()
	cb.press(me, "give_" + aura_id, 2)
	for e: Dictionary in cb.events:
		if e["type"] == "aura_applied":
			return e["duration_ticks"]
	return 0


func _hit(amount: int) -> void:
	cb.deal_damage(me, foe, float(amount), "fire", {"id": "test_hit"}, 0.0, false)


func _fail(u: Unit, ability_id: String) -> String:
	cb.events.clear()
	cb.press(u, ability_id, me.id if u == foe else foe.id)
	for e: Dictionary in cb.events:
		if e["type"] == "cast_failed":
			return e["reason"]
	return ""


func _speed() -> float:
	return Combat.speed_multiplier_from(foe.auras, auras)


# ------------------------------------------------------------ what each category blocks

func test_stun_blocks_everything_and_holds_through_damage() -> void:
	_give("stunned")
	assert_str(_fail(foe, "bolt")).is_equal("stun")
	assert_str(_fail(foe, "slash")).is_equal("stun")
	assert_float(_speed()).is_equal(0.0)
	_hit(20000)
	assert_bool(cb.has_aura(foe, "stunned")).is_true()


func test_incapacitate_blocks_everything_and_breaks_on_any_damage() -> void:
	_give("sheeped")
	assert_str(_fail(foe, "bolt")).is_equal("incapacitate")
	assert_float(_speed()).is_equal(0.0)
	_hit(1)
	assert_bool(cb.has_aura(foe, "sheeped")).is_false()


func test_disorient_takes_control_and_breaks_past_10_percent_of_max_health() -> void:
	_give("feared")
	assert_str(_fail(foe, "bolt")).is_equal("disorient")
	assert_bool(Combat.is_forced_from(foe.auras, auras)).is_true()
	_hit(3000)
	_hit(2999)  # 5,999 of the 6,000 threshold (10% of 60,000), added up over hits
	assert_bool(cb.has_aura(foe, "feared")).is_true()
	_hit(1)
	assert_bool(cb.has_aura(foe, "feared")).is_false()


func test_silence_blocks_spells_but_not_weapon_attacks_and_holds_through_damage() -> void:
	_give("hushed")
	assert_str(_fail(foe, "bolt")).is_equal("silenced")
	assert_str(_fail(foe, "slash")).is_equal("")
	assert_float(_speed()).is_equal(1.0)
	_hit(20000)
	assert_bool(cb.has_aura(foe, "hushed")).is_true()


func test_root_stops_movement_but_not_casting_and_breaks_by_its_data() -> void:
	_give("frozen_feet")
	assert_float(_speed()).is_equal(0.0)
	assert_str(_fail(foe, "bolt")).is_equal("")
	_hit(11999)
	assert_bool(cb.has_aura(foe, "frozen_feet")).is_true()
	_hit(1)  # 20% of 60,000
	assert_bool(cb.has_aura(foe, "frozen_feet")).is_false()
	_give("chained")  # a root without a threshold holds
	_hit(30000)
	assert_bool(cb.has_aura(foe, "chained")).is_true()


func test_disarm_blocks_weapon_attacks_and_auto_attack_but_not_spells() -> void:
	foe.target_id = me.id
	_give("disarmed")
	assert_str(_fail(foe, "slash")).is_equal("disarmed")
	assert_str(_fail(foe, "bolt")).is_equal("")
	assert_float(_speed()).is_equal(1.0)
	_hit(20000)
	assert_bool(cb.has_aura(foe, "disarmed")).is_true()
	var before: int = me.health
	_run(5 * TR)  # more than two swing intervals, in melee range
	assert_int(me.health).override_failure_message("auto attack swung while disarmed").is_equal(before)
	_run(4 * TR)  # the disarm ended at 6 s; swings resume
	assert_int(me.health).is_less(before)


func test_break_free_works_under_every_category() -> void:
	for id: String in ["stunned", "sheeped", "feared", "hushed", "frozen_feet", "disarmed"]:
		foe.auras.clear()
		foe.dr.clear()
		_give(id)
		cb.press(foe, "free", 2)
		assert_bool(cb.has_aura(foe, id)).override_failure_message(id).is_false()


# ------------------------------------------------------------ knockback and diminishing returns

func test_knockback_pushes_every_time_with_no_diminishing_returns() -> void:
	for i: int in 4:
		foe.position = Vector3(0, 0, -3)
		cb.press(me, "shove", 2)
		assert_float(foe.position.z).override_failure_message("push %d" % (i + 1)).is_equal_approx(-11.0, 0.01)
	assert_bool(foe.dr.has("knockback")).is_false()


func test_every_category_steps_100_50_25_then_immune() -> void:
	for id: String in ["stunned", "sheeped", "feared", "hushed", "frozen_feet", "disarmed"]:
		var got: Array[int] = []
		for i: int in 4:
			got.append(_give(id))
			foe.auras.clear()
		assert_array(got).override_failure_message(id).is_equal([6 * TR, 3 * TR, roundi(1.5 * TR), 0])


func test_categories_keep_separate_diminishing_returns() -> void:
	_give("stunned")
	_give("stunned")
	foe.auras.clear()
	assert_int(_give("sheeped")).is_equal(6 * TR)  # a fresh category starts at 100%
	foe.auras.clear()
	assert_int(_give("disarmed")).is_equal(6 * TR)


func test_diminishing_returns_reset_18_s_after_the_last_effect_ends_in_each_category() -> void:
	_give("hushed")  # ends at 6 s
	_run(6 * TR + 18 * TR - 1)
	assert_int(_give("hushed")).is_equal(3 * TR)  # one tick short of the reset: second step
	foe.auras.clear()
	_run(18 * TR + 3 * TR + 1)
	assert_int(_give("hushed")).is_equal(6 * TR)


func test_no_category_lasts_longer_than_8_s() -> void:
	for id: String in ["stunned", "sheeped", "feared", "hushed", "frozen_feet", "disarmed"]:
		auras[id]["duration_s"] = 30
		foe.auras.clear()
		assert_int(_give(id)).override_failure_message(id).is_equal(8 * TR)
