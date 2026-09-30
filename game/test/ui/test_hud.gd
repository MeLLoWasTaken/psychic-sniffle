extends GdUnitTestSuite
## Basic HUD (backlog M1-27): layout data, action bars mapped to the spec and the keybind
## profile, cooldown and GCD sweeps from the view, target frame following the targeting, auras
## sorted with crowd control first and larger, bounded floating combat text, the loss-of-control
## alert, timer and dampening, ability presses by key and click, and scaling at three resolutions.

const DT: float = 1.0 / 60.0

var ctl: PlayerController
var hud: Hud
var match_: LocalMatch


func before_test() -> void:
	Keybinds.load_profile("default")
	ctl = PlayerController.new(Data.settings["default"])
	hud = auto_free(Hud.new(Data.settings["default"]))
	add_child(hud)
	hud.bind(ctl)
	match_ = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"])


func _view() -> Dictionary:
	return match_.view()


func _enemy_ids(v: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for u: Dictionary in v["units"]:
		if int(u["team"]) != int(v["me"]["team"]):
			out.append(int(u["id"]))
	return out


func _aura(id: String, tick: int, seconds: float, source: int = 99) -> Dictionary:
	return {"id": id, "source": source, "applied_tick": tick, "expires_tick": tick + roundi(seconds * 60.0), "stacks": 1}


func _key(code: Key, shift: bool = false) -> void:
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = code
	ev.shift_pressed = shift
	ev.pressed = true
	ctl.handle_event(ev)


func _bar(id: String) -> ActionBar:
	return hud.bars[id]


# ------------------------------------------------------------------ layout

func test_layout_data_is_loaded_and_every_element_is_built() -> void:
	var layout: Dictionary = Data.hud_layouts["default"]
	assert_str(str(Data.settings["default"]["interface"]["hud_layout"])).is_equal("default")
	assert_dict(hud.layout).is_equal(layout)
	for id: String in layout["elements"]:
		assert_bool(hud.elements.has(id)).override_failure_message("element %s not built" % id).is_true()
	assert_int(hud.bars.size()).is_equal(2)
	assert_int((hud.elements["arena_frames"] as Array).size()).is_equal(3)
	assert_int((hud.elements["party_frames"] as Array).size()).is_equal(4)
	# every element type in the schema's list has a builder
	var types: Dictionary = {}
	for id: String in layout["elements"]:
		types[str(layout["elements"][id]["type"])] = true
	assert_array(types.keys()).contains(["action_bar", "unit_frame", "cast_bar", "match_timer", "loss_of_control", "combat_text"])


# ------------------------------------------------------------------ action bars

func test_action_bars_map_slots_to_spec_abilities_and_keybind_labels() -> void:
	hud.push(_view())
	var kit: Array = Data.specs["warblade_carnage"]["abilities"]
	var b1: ActionBar = _bar("action_bar_1")
	var b2: ActionBar = _bar("action_bar_2")
	for i: int in 12:
		assert_str(str(b1.slots[i]["ability"])).is_equal(str(kit[i]))
		assert_str(str(b1.slots[i]["action"])).is_equal("bar1_slot%d" % (i + 1))
	assert_str(str(b2.slots[0]["ability"])).is_equal(str(kit[12]))
	assert_str(str(b2.slots[1]["ability"])).is_equal(str(kit[13]))
	assert_str(str(b2.slots[2]["ability"])).is_equal("")
	# the class's shared Break Free takes the last slot with its own bind (Shift+R); no auto attack
	assert_str(str(b2.slots[11]["ability"])).is_equal("break_free")
	assert_str(str(b2.slots[11]["action"])).is_equal("break_free")
	for s: Dictionary in b1.slots + b2.slots:
		assert_str(str(s["ability"])).is_not_equal("auto_attack")
	# labels from the keybind profile, shortened by the layout
	assert_str(str(b1.slots[0]["label"])).is_equal("1")
	assert_str(str(b1.slots[9]["label"])).is_equal("0")
	assert_str(str(b1.slots[10]["label"])).is_equal("-")
	assert_str(str(b1.slots[11]["label"])).is_equal("=")
	assert_str(str(b2.slots[0]["label"])).is_equal("S1")
	assert_str(str(b2.slots[11]["label"])).is_equal("SR")
	# the controller knows which key presses which ability
	assert_str(str(ctl.bar_actions["bar1_slot1"])).is_equal(str(kit[0]))
	assert_str(str(ctl.bar_actions["bar2_slot2"])).is_equal(str(kit[13]))
	assert_str(str(ctl.bar_actions["break_free"])).is_equal("break_free")


func test_every_slice_spec_fits_on_the_bars() -> void:
	for spec_id: String in ["warblade_carnage", "arcanist_rime", "oracle_grace"]:
		var a: Dictionary = HudLogic.bar_assignment(Data.hud_layouts["default"], spec_id)
		var placed: Array = []
		for bid: String in a:
			for ab: String in a[bid]:
				if ab != "":
					placed.append(ab)
		for ab: String in Data.specs[spec_id]["abilities"]:
			assert_array(placed).override_failure_message("%s: %s not on a bar" % [spec_id, ab]).contains([ab])
		assert_array(placed).contains(["break_free"])


func test_layout_assignments_replace_the_automatic_fill() -> void:
	var layout: Dictionary = Data.hud_layouts["default"].duplicate(true)
	layout["action_bars"]["assignments"] = {"warblade_carnage": {"action_bar_1": ["pommel_crack", "", "ruin_strike"]}}
	var a: Dictionary = HudLogic.bar_assignment(layout, "warblade_carnage")
	assert_array(a["action_bar_1"].slice(0, 4)).is_equal(["pommel_crack", "", "ruin_strike", ""])
	assert_str(str(a["action_bar_2"][0])).is_equal("")


func test_cooldown_sweep_and_gcd_state_follow_the_view() -> void:
	var v: Dictionary = _view().duplicate(true)
	var t0: int = 600
	v["tick"] = t0
	v["gcd_ready_tick"] = t0 + 90  # a 1.5 s GCD just started
	v["cooldowns"] = {"pommel_crack": t0 + 1800}  # a 30 s cooldown just started
	hud.push(v)
	var target: Dictionary = {}
	var v2: Dictionary = v.duplicate(true)
	v2["tick"] = t0 + 45
	hud.push(v2)
	var ruin: Dictionary = HudLogic.slot_state("ruin_strike", v2, target, hud.cd_starts)
	assert_bool(ruin["on_gcd"]).is_true()
	assert_float(ruin["gcd_frac"]).is_equal_approx(0.5, 1e-4)
	assert_float(ruin["gcd_left_s"]).is_equal_approx(0.75, 1e-4)
	assert_float(ruin["cd_left_s"]).is_equal(0.0)
	var pommel: Dictionary = HudLogic.slot_state("pommel_crack", v2, target, hud.cd_starts)
	assert_bool(pommel["on_gcd"]).is_false()  # its own cooldown ends later: that sweep shows
	assert_float(pommel["cd_left_s"]).is_equal_approx(29.25, 1e-4)
	assert_float(pommel["cd_frac"]).is_equal_approx(45.0 / 1800.0, 1e-4)
	var bf: Dictionary = HudLogic.slot_state("break_free", v2, target, hud.cd_starts)
	assert_bool(bf["on_gcd"]).is_false()  # off the GCD
	# the bars show the same states
	hud.update(0.0)
	var slot: Dictionary = _bar("action_bar_1").slots[0]
	assert_str(str(slot["ability"])).is_equal("ruin_strike")
	assert_bool(slot["state"]["on_gcd"]).is_true()
	# after the GCD and the cooldown
	var v3: Dictionary = v.duplicate(true)
	v3["tick"] = t0 + 1800
	hud.push(v3)
	assert_bool(HudLogic.slot_state("ruin_strike", v3, target, hud.cd_starts)["on_gcd"]).is_false()
	assert_float(HudLogic.slot_state("pommel_crack", v3, target, hud.cd_starts)["cd_left_s"]).is_equal(0.0)


func test_buttons_tint_by_range_resource_and_crowd_control() -> void:
	var v: Dictionary = _view().duplicate(true)
	var enemy: Dictionary = {}
	for u: Dictionary in v["units"]:
		if int(u["team"]) != int(v["me"]["team"]):
			enemy = u.duplicate(true)
	enemy["position"] = v["me"]["position"] + Vector3(20, 0, 0)
	v["me"]["resource"] = 100.0
	assert_bool(HudLogic.slot_state("ruin_strike", v, enemy, {})["range"]).is_false()  # melee at 20 m
	assert_bool(HudLogic.slot_state("shield_breaker", v, enemy, {})["range"]).is_true()  # 30 m throw
	enemy["position"] = v["me"]["position"] + Vector3(3, 0, 0)
	assert_bool(HudLogic.slot_state("ruin_strike", v, enemy, {})["range"]).is_true()
	v["me"]["resource"] = 0.0
	var cost: Dictionary = Data.abilities["ruin_strike"].get("cost", {})
	if not cost.is_empty():
		assert_bool(HudLogic.slot_state("ruin_strike", v, enemy, {})["resource_ok"]).is_false()
	# stunned: everything but Break Free is unusable
	v["me"]["auras"] = [_aura("pommel_cracked", int(v["tick"]), 3.0)]
	assert_bool(HudLogic.slot_state("grim_hack", v, enemy, {})["usable"]).is_false()
	assert_str(str(HudLogic.slot_state("grim_hack", v, enemy, {})["blocked_by"])).is_equal("stun")
	assert_bool(HudLogic.slot_state("break_free", v, enemy, {})["usable"]).is_true()
	# the execute lights up only below its health threshold
	v["me"]["auras"] = []
	v["me"]["resource"] = 100.0
	enemy["health"] = enemy["max_health"]
	assert_bool(HudLogic.slot_state("headsmans_verdict", v, enemy, {})["usable"]).is_false()
	enemy["health"] = int(enemy["max_health"]) / 10
	var hv: Dictionary = HudLogic.slot_state("headsmans_verdict", v, enemy, {})
	assert_bool(hv["usable"]).is_true()
	assert_bool(hv["highlight"]).is_true()


# ------------------------------------------------------------------ frames

func test_target_and_focus_frames_follow_the_targeting() -> void:
	var v: Dictionary = _view()
	hud.push(v)
	hud.update(0.0)
	var target_frame: UnitFrame = (hud.elements["target_frame"] as Array)[0]
	var focus_frame: UnitFrame = (hud.elements["focus_frame"] as Array)[0]
	assert_bool(target_frame.visible).is_false()
	var enemies: Array[int] = _enemy_ids(v)
	ctl.target_id = enemies[0]  # as Tab or a click would
	hud.update(0.0)
	assert_bool(target_frame.visible).is_true()
	assert_int(target_frame.unit_id()).is_equal(enemies[0])
	assert_bool(target_frame.hostile).is_true()
	# Shift+F makes it the focus; Tab to the other enemy moves only the target
	var set_focus: InputEventAction = InputEventAction.new()
	set_focus.action = "set_focus"
	set_focus.pressed = true
	ctl.handle_event(set_focus)
	ctl.next_input(DT, v)
	ctl.target_id = enemies[1]
	hud.update(0.0)
	assert_int(focus_frame.unit_id()).is_equal(enemies[0])
	assert_int(target_frame.unit_id()).is_equal(enemies[1])
	# the arena frame of the target is marked; clicking a party frame selects that ally
	var arena: Array = hud.elements["arena_frames"]
	assert_bool((arena[1] as UnitFrame).selected).is_true()
	assert_bool((arena[0] as UnitFrame).selected).is_false()
	assert_str((arena[0] as UnitFrame).prefix).is_equal("1")
	var party: UnitFrame = (hud.elements["party_frames"] as Array)[0]
	assert_bool(party.visible).is_true()
	assert_bool((hud.elements["party_frames"] as Array)[1].visible).is_false()  # 2v2: one partner
	party.clicked.emit(party.unit_id())
	hud.update(0.0)
	assert_int(ctl.target_id).is_equal(party.unit_id())
	assert_int(target_frame.unit_id()).is_equal(party.unit_id())
	assert_bool(target_frame.hostile).is_false()
	# clearing the target hides the frame
	ctl.target_id = -1
	var cleared: Dictionary = v.duplicate(true)
	cleared["me"]["target_id"] = -1
	hud.push(cleared)
	hud.update(0.0)
	assert_bool(target_frame.visible).is_false()


func test_auras_are_sorted_with_crowd_control_first_and_larger() -> void:
	var v: Dictionary = _view().duplicate(true)
	var tick: int = int(v["tick"])
	var u: Dictionary = v["me"]
	u["auras"] = [_aura("chilled", tick, 6.0), _aura("red_mist", tick, 10.0), _aura("ruin_bleed", tick, 2.0),
		_aura("glacier_shield", tick, 20.0), _aura("pommel_cracked", tick, 3.0), _aura("rimebound", tick, 5.0)]
	var list: Array = HudLogic.sorted_auras(u, v)
	var ids: Array = list.map(func(e: Dictionary) -> String: return e["id"])
	assert_array(ids).is_equal(["pommel_cracked", "rimebound", "glacier_shield", "red_mist", "ruin_bleed", "chilled"])
	assert_float(list[0]["size"]).is_greater(list[2]["size"])
	assert_float(list[2]["size"]).is_greater(list[4]["size"])
	assert_float(list[0]["remaining_s"]).is_equal_approx(3.0, 1e-4)
	# the frame draws them in that order, CC icons larger than the rest
	for f: UnitFrame in hud.elements["player_frame"]:
		f.set_unit(u, v, false, false, {}, 0.0)
	await await_idle_frame()
	await await_idle_frame()
	var frame: UnitFrame = (hud.elements["player_frame"] as Array)[0]
	assert_array(frame.drawn_auras).is_not_empty()
	assert_str(str(frame.drawn_auras[0]["id"])).is_equal("pommel_cracked")
	assert_float(frame.drawn_auras[0]["size_px"]).is_greater(frame.drawn_auras[-1]["size_px"])
	# the portrait shows the strongest CC: the stun
	var cc: Dictionary = HudLogic.active_cc(u, v, hud.style.cc.keys(), hud.style.cc)
	assert_str(str(cc["category"])).is_equal("stun")


func test_arena_frames_track_break_free_and_casts() -> void:
	var v: Dictionary = _view().duplicate(true)
	var enemy: int = _enemy_ids(v)[0]
	hud.push(v, [{"type": "cast_success", "source": enemy, "target": enemy, "ability": "break_free", "tick": int(v["tick"])}])
	assert_int(int(hud.break_free[enemy]["ready_tick"])).is_equal(int(v["tick"]) + 90 * 60)
	for u: Dictionary in v["units"]:
		if int(u["id"]) == enemy:
			u["cast"] = {"ability": "rime_bolt", "target": 1, "start_tick": int(v["tick"]), "end_tick": int(v["tick"]) + 108,
				"channel": false}
	hud.push(v)
	hud.update(0.0)
	var f: UnitFrame = (hud.elements["arena_frames"] as Array)[0]
	assert_int(f.unit_id()).is_equal(enemy)
	assert_int(int(f.break_free["ready_tick"])).is_equal(int(v["tick"]) + 5400)
	assert_bool(CastBar.has_content(f.unit, f.failure, f.clock)).is_true()
	# an interrupt holds the bar with the reason
	hud.push(v, [{"type": "interrupt", "source": 1, "target": enemy, "ability": "throat_punch", "tick": int(v["tick"])}])
	assert_str(str(hud.failures[enemy]["text"])).is_equal("Interrupted")


# ------------------------------------------------------------------ combat text, alert, timer

func test_combat_text_spawns_and_expires_with_a_bounded_count() -> void:
	var v: Dictionary = _view()
	var me: int = int(v["me"]["id"])
	var enemy: int = _enemy_ids(v)[0]
	hud.push(v, [{"type": "damage", "source": me, "target": enemy, "amount": 4321, "crit": false, "school": "physical"},
		{"type": "damage", "source": me, "target": enemy, "amount": 9000, "crit": true, "school": "physical"},
		{"type": "heal", "source": 2, "target": me, "amount": 2500, "crit": false},
		{"type": "aura_applied", "source": me, "target": enemy, "aura": "pommel_cracked", "cc": "stun"},
		{"type": "damage", "source": 3, "target": 4, "amount": 100, "crit": false, "school": "frost"}])
	var ct: CombatText = hud.elements["combat_text"]
	var texts: Array = ct.entries.map(func(e: Dictionary) -> String: return e["text"])
	assert_array(texts).is_equal(["4,321", "9,000!", "+2,500", "Stunned"])  # others' fights stay quiet
	assert_int(int(ct.entries[1]["size"])).is_greater(int(ct.entries[0]["size"]))  # crits bigger
	assert_int(int(ct.entries[1]["size"])).is_equal(hud.style.fs("combat_text_crit"))
	assert_int(ct.entries[0]["unit"]).is_equal(enemy)
	assert_int(ct.entries[2]["unit"]).is_equal(me)
	# bounded: a burst of 200 hits keeps at most max_live
	var burst: Array = []
	for i: int in 200:
		burst.append({"type": "damage", "source": me, "target": enemy, "amount": i + 1, "crit": false, "school": "physical"})
	hud.push(v, burst)
	assert_int(ct.entries.size()).is_equal(ct.max_live)
	assert_str(str(ct.entries[-1]["text"])).is_equal("200")
	# and everything expires after its lifetime
	hud.update(ct.lifetime * 0.5)
	assert_int(ct.entries.size()).is_equal(ct.max_live)
	hud.update(ct.lifetime * 0.6)
	assert_int(ct.entries.size()).is_equal(0)
	# the player's failed presses show an error line
	hud.push(v, [{"type": "cast_failed", "source": me, "ability": "ruin_strike", "reason": "out_of_range"}])
	assert_str(str(ct.errors[0]["text"])).is_equal("Out of range")


func test_combat_text_is_drawn_over_the_unit_through_the_camera() -> void:
	var cam: Camera3D = auto_free(Camera3D.new())
	add_child(cam)
	cam.position = Vector3(0, 2, 10)
	cam.look_at(Vector3(0, 2, 0))
	var ct: CombatText = hud.elements["combat_text"]
	ct.camera = cam
	ct.position_of = func(id: int) -> Vector3: return Vector3.ZERO if id == 7 else Vector3(INF, INF, INF)
	ct.spawn(7, "123", Color.WHITE)
	ct.spawn(8, "gone", Color.WHITE)
	var p: Variant = ct.screen_position(ct.entries[0])
	assert_object(p).is_not_null()
	var centre: Vector2 = cam.get_viewport().get_visible_rect().size * 0.5
	assert_float((p as Vector2).x).is_equal_approx(centre.x, 1.0)  # over the unit
	assert_float((p as Vector2).y).is_less(centre.y)  # above its feet
	assert_object(ct.screen_position(ct.entries[1])).is_null()
	ct.advance(ct.lifetime * 0.5)
	assert_float((ct.screen_position(ct.entries[0]) as Vector2).y).is_less((p as Vector2).y)  # rises
	# texts of units close together on screen step apart instead of overlapping
	var placed: Array[Rect2] = []
	var first: Vector2 = CombatText._free_spot(Vector2(100, 300), Vector2(60, 24), placed)
	var second: Vector2 = CombatText._free_spot(Vector2(110, 305), Vector2(60, 24), placed)
	assert_vector(first).is_equal(Vector2(100, 300))
	assert_bool(placed[0].intersects(placed[1])).is_false()
	assert_float(second.y).is_less(first.y)


func test_loss_of_control_alert_shows_stun_and_fear_for_the_local_player_and_hides_after() -> void:
	var alert: LossOfControlAlert = hud.elements["loss_of_control"]
	var v: Dictionary = _view().duplicate(true)
	var tick: int = int(v["tick"])
	hud.push(v)
	hud.update(0.0)
	assert_bool(alert.visible).is_false()
	v["me"]["auras"] = [_aura("pommel_cracked", tick, 3.0), _aura("rimebound", tick, 6.0)]
	v["tick"] = tick + 60
	hud.push(v)
	hud.update(0.0)
	assert_bool(alert.visible).is_true()
	assert_str(alert.label()).is_equal("Stunned")  # the stun outranks the root
	assert_float(alert.current["remaining_s"]).is_equal_approx(2.0, 1e-4)
	assert_str(str(alert.current["name"])).is_equal(str(Data.auras["pommel_cracked"]["name"]))
	v["me"]["auras"] = [_aura("dread_roared", tick, 6.0)]
	hud.push(v)
	hud.update(0.0)
	assert_str(alert.label()).is_equal("Feared")
	# crowd control on someone else raises nothing
	v["me"]["auras"] = []
	for u: Dictionary in v["units"]:
		u["auras"] = [_aura("pommel_cracked", tick, 3.0)]
	hud.push(v)
	hud.update(0.0)
	assert_bool(alert.visible).is_false()


func test_loss_of_control_follows_a_real_stun_in_the_simulation() -> void:
	match_ = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"],
		"2v2", 60.0)  # behind the gates: the bots cannot reach the player
	var me: Unit = match_.player
	var enemy: Unit = null
	for u: Unit in match_.runner.sim.units.values():
		if u.team != me.team:
			enemy = u
			break
	match_.runner.combat.apply_aura(enemy, me, "pommel_cracked")
	match_.step({"move": Vector2.ZERO, "yaw": me.facing})
	hud.push(match_.view(), match_.take_events())
	hud.update(0.0)
	var alert: LossOfControlAlert = hud.elements["loss_of_control"]
	assert_str(alert.label()).is_equal("Stunned")
	for i: int in 200:
		match_.step({"move": Vector2.ZERO, "yaw": me.facing})
	hud.push(match_.view(), match_.take_events())
	hud.update(0.0)
	assert_bool(alert.visible).is_false()


func test_timer_and_dampening_match_the_view() -> void:
	var timer: MatchTimer = hud.elements["match_timer"]
	var v: Dictionary = _view().duplicate(true)
	v["match"] = {"phase": ArenaMatch.Phase.ACTIVE, "start_tick": 600, "dampening_pct": 12, "winner": -1}
	v["tick"] = 600 + 222 * 60
	hud.push(v)
	hud.update(0.0)
	assert_str(timer.time_text()).is_equal("3:42")
	assert_str(timer.dampening_text()).is_equal("Dampening 12%")
	# the same numbers the arena rules produce
	var arena: ArenaMatch = ArenaMatch.new(Data.tuning, "2v2", 60, null, 0)
	arena.phase = ArenaMatch.Phase.ACTIVE
	var t: int = arena.start_tick + roundi(215.0 * 60)
	v["match"] = {"phase": arena.phase, "start_tick": arena.start_tick, "dampening_pct": arena.dampening_pct(t), "winner": -1}
	v["tick"] = t
	hud.push(v)
	hud.update(0.0)
	assert_str(timer.time_text()).is_equal("3:35")
	assert_int(timer.dampening_pct).is_equal(arena.dampening_pct(t))
	assert_int(timer.dampening_pct).is_greater(0)
	# preparation counts down to the gates
	v["match"] = {"phase": ArenaMatch.Phase.PREP, "start_tick": 3600, "dampening_pct": 0, "winner": -1}
	v["tick"] = 3600 - 45 * 60
	hud.push(v)
	hud.update(0.0)
	assert_str(timer.time_text()).is_equal("0:45")
	# the clock stops at the end
	v["match"] = {"phase": ArenaMatch.Phase.ENDED, "start_tick": 0, "dampening_pct": 5, "winner": 0}
	v["tick"] = 60 * 200
	hud.push(v)
	hud.update(0.0)
	v["tick"] = 60 * 260
	hud.push(v)
	hud.update(0.0)
	assert_str(timer.time_text()).is_equal("3:20")


# ------------------------------------------------------------------ presses

func test_pressing_a_slot_key_puts_its_ability_in_the_input() -> void:
	var v: Dictionary = _view()
	hud.push(v)
	var kit: Array = Data.specs["warblade_carnage"]["abilities"]
	_key(KEY_7)
	assert_str(str(ctl.next_input(DT, v)["ability"])).is_equal(str(kit[6]))
	assert_str(str(ctl.next_input(DT, v)["ability"])).is_equal("")  # one press, one send
	_key(KEY_1, true)  # Shift+1 is bar 2, not bar 1
	assert_str(str(ctl.next_input(DT, v)["ability"])).is_equal(str(kit[12]))
	_key(KEY_R, true)
	assert_str(str(ctl.next_input(DT, v)["ability"])).is_equal("break_free")
	# two presses in one tick go out on consecutive ticks, in order
	_key(KEY_1)
	_key(KEY_2)
	assert_str(str(ctl.next_input(DT, v)["ability"])).is_equal(str(kit[0]))
	assert_str(str(ctl.next_input(DT, v)["ability"])).is_equal(str(kit[1]))
	# scripted input (InputEventAction) takes the same path
	var ev: InputEventAction = InputEventAction.new()
	ev.action = "bar1_slot3"
	ev.pressed = true
	ctl.handle_event(ev)
	assert_str(str(ctl.next_input(DT, v)["ability"])).is_equal(str(kit[2]))


func test_clicking_an_action_button_presses_it_with_a_click_sound() -> void:
	hud.push(_view())
	var b: ActionBar = _bar("action_bar_1")
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = b.slot_rect(3).get_center()
	b._gui_input(ev)
	assert_str(str(ctl.next_input(DT, _view())["ability"])).is_equal(str(Data.specs["warblade_carnage"]["abilities"][3]))
	assert_int(hud.clicks).is_equal(1)
	# with the renderer bound, the click plays the interface sound on the Interface bus
	var r: WorldRenderer = auto_free(WorldRenderer.new())
	add_child(r)
	hud.bind(ctl, null, r)
	var before: int = r.audio.played
	b._gui_input(ev)
	assert_int(r.audio.played).is_equal(before + 1)
	assert_str(str(r.audio.history[-1]["id"])).is_equal("ui_click")
	assert_str(str(r.audio.history[-1]["bus"])).is_equal("Interface")


func test_a_pressed_key_reaches_the_simulation() -> void:
	var v: Dictionary = _view()
	hud.push(v)
	var slot: int = (Data.specs["warblade_carnage"]["abilities"] as Array).find("red_mist_ab")
	assert_int(slot).is_between(0, 11)
	var ev: InputEventAction = InputEventAction.new()
	ev.action = "bar1_slot%d" % (slot + 1)
	ev.pressed = true
	ctl.handle_event(ev)
	match_.step(ctl.next_input(DT, v))
	var used: bool = false
	for e: Dictionary in match_.take_events():
		if str(e.get("type", "")) == "cast_success" and str(e.get("ability", "")) == "red_mist_ab" \
				and int(e.get("source", -1)) == match_.player.id:
			used = true
	assert_bool(used).is_true()


# ------------------------------------------------------------------ scaling

func test_layout_scales_for_three_resolutions_without_overlaps() -> void:
	hud.push(_view())
	hud.update(0.0)
	var base: Vector2 = Vector2(1920, 1080)
	for res: Vector2 in [Vector2(1280, 720), Vector2(1920, 1080), Vector2(2560, 1440)]:
		hud.stretch_override = res.y / base.y
		hud.root.size = base  # canvas_items stretch: the logical screen stays 1920x1080 at 16:9
		hud.relayout()
		var s: float = hud.scale_used
		# the smallest text is at least min_text_px screen pixels
		var smallest_px: float = hud.style.smallest_font() * s * hud.stretch_override
		assert_float(smallest_px).override_failure_message("%s: smallest text %.1f px" % [res, smallest_px]) \
			.is_greater_equal(float(Data.settings["default"]["interface"]["min_text_px"]) - 0.01)
		var rects: Dictionary = hud.element_rects()
		var screen: Rect2 = Rect2(Vector2.ZERO, base)
		for id: String in rects:
			var r: Rect2 = rects[id]
			assert_bool(screen.encloses(r)).override_failure_message("%s: %s %s is off screen" % [res, id, r]).is_true()
		var ids: Array = rects.keys()
		for i: int in ids.size():
			for j: int in range(i + 1, ids.size()):
				var a: Rect2 = rects[ids[i]]
				var b: Rect2 = rects[ids[j]]
				assert_bool(a.grow(-0.5).intersects(b.grow(-0.5))).override_failure_message("%s: %s %s overlaps %s %s" % [
					res, ids[i], a, ids[j], b]).is_false()
	# ui_scale grows everything
	hud.stretch_override = 1.0
	hud.interface["ui_scale"] = 1.25
	hud.relayout()
	assert_float(hud.scale_used).is_equal_approx(1.25, 1e-4)
	assert_float((hud.bars["action_bar_1"] as ActionBar).scale.x).is_equal_approx(1.25, 1e-4)


func test_practice_scene_feeds_the_hud() -> void:
	var errors_before: int = Log.error_count
	var scene: Node3D = auto_free((load("res://scenes/game/practice.tscn") as PackedScene).instantiate())
	scene.options = {"manual": true, "kit": false, "gi": false, "lighting": false, "player_bot": true,
		"auto": "target_nearest_enemy,set_focus,target_nearest_enemy"}
	add_child(scene)
	for i: int in 4 * scene.world.tick_rate():
		scene.run_ticks(1)
	assert_int(Log.error_count - errors_before).is_equal(0)
	var h: Hud = scene.hud
	assert_object(h).is_not_null()
	assert_int(int(h.view["tick"])).is_equal(int(scene.world.view()["tick"]))
	var arena: Array = h.elements["arena_frames"]
	assert_bool((arena[0] as UnitFrame).visible and (arena[1] as UnitFrame).visible).is_true()
	assert_bool((arena[2] as UnitFrame).visible).is_false()
	assert_int(scene.controller.bar_actions.size()).is_greater(12)
	assert_array(["0:03", "0:04"]).contains([(h.elements["match_timer"] as MatchTimer).time_text()])
