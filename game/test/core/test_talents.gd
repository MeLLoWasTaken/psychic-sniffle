extends GdUnitTestSuite
## Talent system (backlog M2-03): loadout rules, effects applied per unit from data paths,
## the shared text form, and the lock when the arena gates open. Uses fixture trees so the rules
## do not depend on the slice specs' trees (M2-04).

const TR: int = 60

var abilities: Dictionary
var auras: Dictionary
var trees: Dictionary  ## tree id -> tree
var specs: Dictionary
var classes: Dictionary
var sim: Sim
var cb: Combat


func _ab(id: String, extra: Dictionary) -> Dictionary:
	var a: Dictionary = {"id": id, "name": id, "owner": "test", "kit_slot": "core", "school": "fire",
		"cast_type": "instant", "cooldown_s": 10, "triggers_gcd": false, "range_m": 40, "requires_los": true,
		"target": "enemy", "effects": [], "icon": {"symbol": "x"}}
	a.merge(extra, true)
	return a


func _n(id: String, pos: Array, extra: Dictionary = {}) -> Dictionary:
	var n: Dictionary = {"id": id, "name": id, "type": "passive", "ranks": 1, "pos": pos}
	n.merge(extra, true)
	return n


func before_test() -> void:
	abilities = {
		"bolt": _ab("bolt", {"effects": [{"type": "damage", "base": 1000}]}),
		"rend": _ab("rend", {"effects": [{"type": "apply_aura", "aura": "bleed"}]}),
		"leap": _ab("leap", {"target": "self", "effects": []}),
	}
	auras = {
		"bleed": {"id": "bleed", "name": "bleed", "kind": "debuff", "duration_s": 9, "dispel_type": "none",
			"cc_category": "none", "hud_priority": "normal",
			"periodic": {"interval_s": 3, "effect": {"type": "damage", "base": 300, "can_crit": false, "school": "physical"}}},
		"thick_skin": {"id": "thick_skin", "name": "thick_skin", "kind": "buff", "duration_s": 0, "dispel_type": "none",
			"cc_category": "none", "hud_priority": "hidden", "modifiers": [{"stat": "damage_taken", "op": "multiply", "value": 1.0}]},
	}
	trees = {
		"t_class": {"tree_id": "t_class", "kind": "class", "owner": "c", "points": 30, "gates": [], "status": "draft", "nodes": [
			_n("toughness", [0, 0], {"ranks": 3, "effects": [{"modify": "self.max_health", "per_rank": 2000}]}),
			_n("skin", [1, 0], {"ranks": 2, "grants_aura": "thick_skin", "effects": [{"modify": "thick_skin.modifiers.0.value", "per_rank": -0.05}]}),
			_n("pounce", [0, 1], {"type": "active", "requires_any": ["toughness"], "grants_ability": "leap"}),
		]},
		"t_spec": {"tree_id": "t_spec", "kind": "spec", "owner": "s", "points": 30, "gates": [8, 20], "status": "draft", "nodes": [
			_n("hot_bolt", [0, 0], {"ranks": 3, "effects": [{"modify": "bolt.effects.0.base", "per_rank": 100}]}),
			_n("deep_cuts", [1, 0], {"ranks": 3, "requires_any": ["rend"], "effects": [{"modify": "bleed.periodic.effect.base", "per_rank": 100}]}),
			_n("quick_bolt", [0, 1], {"ranks": 2, "requires_any": ["hot_bolt"], "effects": [{"modify": "bolt.cooldown_s", "per_rank": -2}]}),
			_n("fork", [0, 2], {"type": "choice", "requires_any": ["quick_bolt"], "choices": [
				{"id": "fork_power", "name": "power", "effects": [{"modify": "bolt.effects.0.base", "set": 5000}]},
				{"id": "fork_haste", "name": "haste", "effects": [{"modify": "self.stats.haste", "per_rank": 0.2}]}]}),
			_n("gated", [0, 3], {"gate": 8, "requires_any": ["fork"], "effects": [{"modify": "bolt.pvp_modifier", "per_rank": -0.5}]}),
			_n("capstone", [0, 4], {"type": "capstone", "gate": 20, "requires_any": ["gated"], "effects": [{"modify": "bolt.cooldown_s", "set": 0}]}),
			_n("filler_a", [1, 1], {"ranks": 3, "requires_any": ["deep_cuts"]}),
			_n("filler_b", [1, 2], {"ranks": 3, "requires_any": ["filler_a"]}),
			_n("filler_c", [1, 3], {"ranks": 3, "gate": 8, "requires_any": ["filler_b"]}),
			_n("filler_d", [1, 4], {"ranks": 3, "gate": 8, "requires_any": ["filler_c"]}),
			_n("filler_e", [1, 5], {"ranks": 3, "gate": 8, "requires_any": ["filler_d"]}),
		]},
		"t_pvp": {"tree_id": "t_pvp", "kind": "pvp", "owner": "s", "points": 3, "status": "draft", "nodes": [
			{"id": "p1", "name": "p1", "type": "passive", "effects": [{"modify": "bolt.effects.0.base", "per_rank": 1}]},
			{"id": "p2", "name": "p2", "type": "passive", "effects": [{"modify": "self.stats.crit_chance", "per_rank": 0.5}]},
			{"id": "p3", "name": "p3", "type": "passive"},
			{"id": "p4", "name": "p4", "type": "passive"},
		]},
	}
	specs = {"s": {"class": "c", "role": "dps", "primary_resource": "mana", "abilities": ["bolt", "rend"],
		"spec_tree": "t_spec", "pvp_talents": "t_pvp"}}
	classes = {"c": {"armor": "cloth", "class_tree": "t_class"}}
	var tuning: Dictionary = Data.tuning.duplicate(true)
	tuning["combat"]["crit_chance"] = 0.0
	sim = Sim.new(1, TR)
	cb = Combat.new(sim, tuning, abilities, auras, specs, classes, null)
	cb.talent_trees = trees


func _trees() -> Dictionary:
	return Talents.trees_for("s", specs, classes, trees)


func _unit(id: int, team: int, loadout: Dictionary) -> Unit:
	var u: Unit = Unit.new(id, team, "s")
	u.loadout = loadout
	cb.init_unit(u)
	u.stats["crit_chance"] = 0.0
	u.position = Vector3(0, 0, -5.0 * id)
	sim.add_unit(u)
	return u


func _lo(class_picks: Dictionary, spec_picks: Dictionary, pvp: Array = []) -> Dictionary:
	return {"class": class_picks, "spec": spec_picks, "pvp": pvp}


func _run(ticks: int) -> void:
	for i: int in ticks:
		cb.tick()
		sim.tick += 1


# ------------------------------------------------------------ effects, per unit

func test_ranks_change_ability_numbers_for_that_unit_only() -> void:
	var talented: Unit = _unit(1, 0, _lo({}, {"hot_bolt": 3}))
	var plain: Unit = _unit(2, 0, Talents.empty())
	var foe: Unit = _unit(3, 1, Talents.empty())
	cb.press(talented, "bolt", 3)
	assert_int(60000 - foe.health).is_equal(1300)
	foe.health = 60000
	cb.press(plain, "bolt", 3)
	assert_int(60000 - foe.health).is_equal(1000)
	assert_float(float(abilities["bolt"]["effects"][0]["base"])).is_equal(1000.0)  # shared data untouched


func test_talented_aura_keeps_its_source_numbers_on_the_target() -> void:
	var talented: Unit = _unit(1, 0, _lo({}, {"deep_cuts": 2}))
	var plain: Unit = _unit(2, 0, Talents.empty())
	var foe_a: Unit = _unit(3, 1, Talents.empty())
	var foe_b: Unit = _unit(4, 1, Talents.empty())
	cb.press(talented, "rend", 3)
	cb.press(plain, "rend", 4)
	_run(3 * TR + 1)
	assert_int(60000 - foe_a.health).is_equal(450)  # (300 + 2 x 100), less 10% for cloth
	assert_int(60000 - foe_b.health).is_equal(270)


func test_self_effects_granted_auras_and_abilities() -> void:
	var u: Unit = _unit(1, 0, _lo({"toughness": 3, "skin": 2, "pounce": 1}, {}))
	assert_int(u.max_health).is_equal(66000)
	assert_int(u.health).is_equal(66000)
	assert_bool("leap" in u.known_abilities).is_true()
	assert_bool(cb.has_aura(u, "thick_skin")).is_true()
	var foe: Unit = _unit(2, 1, Talents.empty())
	cb.press(foe, "bolt", 1)
	assert_int(66000 - u.health).is_equal(900)  # thick_skin at 1.0 - 2 x 0.05


func test_choice_node_applies_only_the_picked_option() -> void:
	var path: Dictionary = {"hot_bolt": 3, "quick_bolt": 2}
	var power: Unit = _unit(1, 0, _lo({}, path.merged({"fork": 1})))
	var haste: Unit = _unit(2, 0, _lo({}, path.merged({"fork": 2})))
	assert_float(float(power.talent_abilities["bolt"]["effects"][0]["base"])).is_equal(5000.0)
	assert_float(float(power.talent_abilities["bolt"]["cooldown_s"])).is_equal(6.0)
	assert_float(float(haste.talent_abilities["bolt"]["effects"][0]["base"])).is_equal(1300.0)
	assert_float(float(haste.stats["haste"])).is_equal_approx(float(Data.tuning["combat"]["haste"]) + 0.2, 0.0001)


func test_pvp_talents_apply_and_cooldowns_follow_the_unit() -> void:
	var u: Unit = _unit(1, 0, _lo({}, {"hot_bolt": 3, "quick_bolt": 2}, ["p1"]))
	var foe: Unit = _unit(2, 1, Talents.empty())
	cb.press(u, "bolt", 2)
	assert_int(60000 - foe.health).is_equal(1301)
	assert_int(int(u.cooldowns["bolt"]) - sim.tick).is_equal(6 * TR)  # 10 s - 2 x 2 s
	# the cast event carries the talented cooldown, so every client shows it (arena Break Free box)
	var cast: Array = cb.events.filter(func(e: Dictionary) -> bool: return e["type"] == "cast_success")
	assert_int(int(cast[-1]["cooldown_ticks"])).is_equal(6 * TR)


# ------------------------------------------------------------ loadout rules

func test_loadout_rules() -> void:
	var t: Dictionary = _trees()
	var path: Dictionary = {"hot_bolt": 3, "quick_bolt": 2, "fork": 1}
	assert_str(Talents.check(_lo({}, path), t)).is_equal("")
	assert_str(Talents.check(_lo({}, {"quick_bolt": 1}), t)).contains("locked")  # needs hot_bolt fully ranked
	assert_str(Talents.check(_lo({}, {"hot_bolt": 2, "quick_bolt": 1}), t)).contains("locked")
	assert_str(Talents.check(_lo({}, {"hot_bolt": 4}), t)).contains("3 ranks")
	assert_str(Talents.check(_lo({}, {"nope": 1}), t)).contains("no node")
	assert_str(Talents.check(_lo({}, path.merged({"fork": 3}, true)), t)).contains("options 1 to 2")
	assert_str(Talents.check(_lo({}, {"deep_cuts": 1}), t)).is_equal("")  # hangs off an ability
	assert_str(Talents.check(_lo({}, {}, ["p1", "p2", "p3", "p4"]), t)).contains("3 slots")
	assert_str(Talents.check(_lo({}, {}, ["p1", "p1"]), t)).contains("twice")


func test_gates_need_points_spent_behind_them() -> void:
	var t: Dictionary = _trees()
	var seven: Dictionary = {"hot_bolt": 3, "quick_bolt": 2, "fork": 1, "deep_cuts": 1}  # 7 points
	assert_str(Talents.check(_lo({}, seven.merged({"gated": 1})), t)).contains("locked")
	var eight: Dictionary = seven.merged({"deep_cuts": 2}, true)
	assert_str(Talents.check(_lo({}, eight.merged({"gated": 1})), t)).is_equal("")
	# the capstone waits for 20 points in nodes before the 20-point gate
	var nineteen: Dictionary = {"hot_bolt": 3, "quick_bolt": 2, "fork": 1, "deep_cuts": 3, "filler_a": 3, "filler_b": 3,
		"gated": 1, "filler_c": 3}  # 15 before the 8-point gate, 4 behind it
	assert_str(Talents.check(_lo({}, nineteen), t)).is_equal("")
	assert_int(Talents.spent(t["spec"], nineteen)).is_equal(19)
	assert_str(Talents.check(_lo({}, nineteen.merged({"capstone": 1})), t)).contains("locked")
	var twenty: Dictionary = nineteen.merged({"filler_d": 1})
	assert_str(Talents.check(_lo({}, twenty.merged({"capstone": 1})), t)).is_equal("")


func test_points_cannot_exceed_the_tree() -> void:
	var t: Dictionary = _trees()
	trees["t_spec"]["points"] = 5
	assert_str(Talents.check(_lo({}, {"hot_bolt": 3, "quick_bolt": 2}), t)).is_equal("")
	assert_str(Talents.check(_lo({}, {"hot_bolt": 3, "quick_bolt": 2, "fork": 1}), t)).contains("6 points spent, 5 available")


func test_an_illegal_loadout_gives_no_talents() -> void:
	var u: Unit = _unit(1, 0, _lo({}, {"quick_bolt": 2}))
	assert_bool(u.talent_abilities.is_empty()).is_true()


# ------------------------------------------------------------ text form

func test_text_form_round_trips_and_is_short() -> void:
	var t: Dictionary = _trees()
	var lo: Dictionary = _lo({"toughness": 3, "pounce": 1}, {"hot_bolt": 3, "quick_bolt": 2, "fork": 2}, ["p2", "p1"])
	var text: String = Talents.encode(lo, t)
	assert_int(text.length()).is_less(24)
	var back: Dictionary = Talents.decode(text, t)
	assert_str(back["error"]).is_equal("")
	assert_dict(back["loadout"]).is_equal(lo)
	assert_dict(Talents.decode("", t)["loadout"]).is_equal(Talents.empty())


func test_text_form_refuses_strings_for_another_tree_layout() -> void:
	var text: String = Talents.encode(_lo({"toughness": 1}, {}), _trees())
	trees["t_class"]["nodes"].append(_n("new_node", [2, 0]))
	assert_str(Talents.decode(text, _trees())["error"]).contains("different version")
	assert_str(Talents.decode("garbage!!", _trees())["error"]).is_not_empty()


# ------------------------------------------------------------ the real pipeline (MatchRunner, Replay, wire)

func _warblade_string(picks: Dictionary) -> String:
	var t: Dictionary = Talents.trees_for("warblade_carnage", Data.specs, Data.classes, Data.talents)
	return Talents.encode({"class": picks, "spec": {}, "pvp": []}, t)


func test_talents_change_during_preparation_and_lock_when_the_gates_open() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 1.0, 5)
	var u: Unit = runner.add_unit("warblade_carnage", 0, _warblade_string({"iron_hide": 1}))
	assert_bool(runner.combat.has_aura(u, "iron_hide")).is_true()
	assert_str(runner.set_talents(u, _warblade_string({"iron_hide": 2, "grim_resolve": 1}))).is_equal("")
	assert_float(float(u.talent_abilities["break_free"]["cooldown_s"])).is_equal(75.0)
	assert_int(u.auras.filter(func(a: Dictionary) -> bool: return a["id"] == "iron_hide").size()).is_equal(1)
	assert_str(runner.set_talents(u, _warblade_string({"grim_resolve": 1}))).contains("locked")  # needs iron_hide
	runner.sim.add_system(runner.system_combat_and_rules)
	while runner.arena.phase == ArenaMatch.Phase.PREP:
		runner.sim.step()
	assert_str(runner.set_talents(u, "")).is_equal("talents_locked")
	assert_float(float(u.talent_abilities["break_free"]["cooldown_s"])).is_equal(75.0)


func test_a_match_with_talents_replays_to_the_same_hash() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 1.0, 9)
	runner.record()
	var brains: Dictionary = {}
	var nav: NavGrid = NavGrid.new(runner.geometry)
	var a: Unit = runner.add_unit("warblade_carnage", 0, _warblade_string({"iron_hide": 2}))
	var b: Unit = runner.add_unit("warblade_carnage", 1)
	assert_str(runner.set_talents(b, _warblade_string({"iron_hide": 1}))).is_equal("")
	for u: Unit in [a, b]:
		brains[u.id] = BotBrain.new("warblade_carnage", 900 + u.id, runner.geometry, nav)
	runner.sim.add_system(runner.bot_system(brains))
	runner.sim.add_system(runner.system_combat_and_rules)
	while runner.sim.tick < 60 * 30 and not runner.ended():
		runner.sim.step()
		runner.take_events()
	runner.input_log.finish(runner.sim)
	var r: Dictionary = Replay.run(runner.input_log)
	assert_bool(r["ok"]).override_failure_message(str(r)).is_true()


func test_the_hello_message_carries_the_talent_string() -> void:
	var text: String = _warblade_string({"iron_hide": 2})
	var h: Dictionary = Protocol.decode(Protocol.hello("p1", "warblade_carnage", text))
	assert_str(h["talents"]).is_equal(text)
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 1.0, 5)
	assert_str(runner.talent_error("warblade_carnage", text)).is_equal("")
	assert_str(runner.talent_error("arcanist_rime", text)).contains("different version")


func test_every_bot_build_is_legal_and_round_trips() -> void:
	for spec_id: String in Data.bots:
		var trees: Dictionary = Talents.trees_for(spec_id, Data.specs, Data.classes, Data.talents)
		for b: Dictionary in Data.bots[spec_id].get("builds", []):
			var lo: Dictionary = {"class": b["class"], "spec": b["spec"], "pvp": b["pvp"]}
			assert_str(Talents.check(lo, trees)).override_failure_message("%s@%s" % [spec_id, b["name"]]).is_equal("")
			var text: String = BotBrain.build_talents(spec_id, b["name"])["talents"]
			assert_str(Talents.decode(text, trees)["error"]).is_equal("")


func test_random_builds_are_legal_spend_the_points_and_repeat_by_seed() -> void:
	# M2-04 balance simulations: random legal builds of the real slice trees
	for spec_id: String in Data.specs:
		var t: Dictionary = Talents.trees_for(spec_id, Data.specs, Data.classes, Data.talents)
		for seed_value: int in [1, 2, 3]:
			var lo: Dictionary = Talents.random_build(t, seed_value)
			assert_str(Talents.check(lo, t)).override_failure_message("%s seed %d" % [spec_id, seed_value]).is_empty()
			for layer: String in ["class", "spec"]:
				assert_int(Talents.spent(t[layer], lo[layer])).is_equal(int(t[layer]["points"]))
			assert_int((lo["pvp"] as Array).size()).is_equal(int(t["pvp"]["points"]))
			assert_dict(Talents.random_build(t, seed_value)).is_equal(lo)
		assert_bool(Talents.random_build(t, 1) != Talents.random_build(t, 2)).is_true()
	var named: Dictionary = BotBrain.build_talents("warblade_carnage", "random4")
	assert_str(str(named["name"])).is_equal("random4")
	assert_str(str(named["talents"])).is_equal(str(BotBrain.build_talents("warblade_carnage", "random4")["talents"]))
