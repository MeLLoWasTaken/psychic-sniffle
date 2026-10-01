extends GdUnitTestSuite
## Keybinding screen and target modes (backlog M2-11).

const PATH: String = "user://test_keybinds.json"


func before_test() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func after_test() -> void:
	Keybinds.load_profile("default")


func _screen() -> KeybindScreen:
	var s: KeybindScreen = auto_free(KeybindScreen.new("default", PATH))
	s.size = Vector2(1920, 1080)
	s._layout()
	return s


func _key(code: Key, shift: bool = false, ctrl: bool = false, alt: bool = false) -> InputEventKey:
	var k: InputEventKey = InputEventKey.new()
	k.keycode = code
	k.pressed = true
	k.shift_pressed = shift
	k.ctrl_pressed = ctrl
	k.alt_pressed = alt
	return k


func _mouse(button: MouseButton) -> InputEventMouseButton:
	var m: InputEventMouseButton = InputEventMouseButton.new()
	m.button_index = button
	m.pressed = true
	return m


func test_every_action_has_a_row_on_screen() -> void:
	var s: KeybindScreen = _screen()
	var listed: Array = s.rows.filter(func(r: Dictionary) -> bool: return r.has("action")).map(func(r: Dictionary) -> String: return r["action"])
	for b: Dictionary in Data.keybinds["default"]["binds"]:
		assert_array(listed).contains([b["action"]])
	for r: Dictionary in s.rows:
		assert_float((r["rect"] as Rect2).end.y).override_failure_message("row below the buttons").is_less(1080.0 - 120.0)
	for a: String in s.mode_buttons:
		assert_bool(a.begins_with("bar")).is_true()


func test_chords_mouse_buttons_and_the_wheel_can_be_bound() -> void:
	var s: KeybindScreen = _screen()
	s.start_capture("bar1_slot1")
	assert_bool(s.capture(_key(KEY_SHIFT, true))).is_true()  # a lone modifier waits
	assert_str(s.capturing).is_equal("bar1_slot1")
	assert_bool(s.capture(_key(KEY_F, false, true, true))).is_true()
	var b: Dictionary = Keybinds.bind_of(s.profile, "bar1_slot1")
	assert_str(str(b["key"])).is_equal("KEY_F")
	assert_array(b["modifiers"]).contains_exactly_in_any_order(["ctrl", "alt"])
	for pair: Array in [[MOUSE_BUTTON_XBUTTON1, "MOUSE_BUTTON_XBUTTON1"], [MOUSE_BUTTON_XBUTTON2, "MOUSE_BUTTON_XBUTTON2"],
			[MOUSE_BUTTON_MIDDLE, "MOUSE_BUTTON_MIDDLE"], [MOUSE_BUTTON_WHEEL_UP, "MOUSE_BUTTON_WHEEL_UP"]]:
		s.start_capture("bar2_slot3")
		s.capture(_mouse(pair[0]))
		assert_str(str(Keybinds.bind_of(s.profile, "bar2_slot3")["key"])).is_equal(pair[1])
	# Esc cancels without changing the bind
	s.start_capture("jump")
	assert_bool(s.capture(_key(KEY_ESCAPE))).is_true()
	assert_str(s.capturing).is_empty()
	assert_str(str(Keybinds.bind_of(s.profile, "jump")["key"])).is_equal("KEY_SPACE")


func test_a_key_bound_twice_is_flagged() -> void:
	var s: KeybindScreen = _screen()
	assert_dict(Keybinds.conflicts(s.profile)).is_empty()
	s.start_capture("bar1_slot2")
	s.capture(_key(KEY_1))  # bar1_slot1's key
	var clash: Dictionary = Keybinds.conflicts(s.profile)
	assert_array(clash["bar1_slot2"]).contains(["bar1_slot1"])
	assert_str(s.message).contains("also bound")


func test_target_modes_save_and_reach_the_controller() -> void:
	var s: KeybindScreen = _screen()
	s.cycle_mode("bar1_slot1")  # default -> target
	s.cycle_mode("bar1_slot1")  # -> focus
	s.save()
	assert_str(Keybinds.target_mode("bar1_slot1")).is_equal("focus")
	var again: Dictionary = Keybinds.user_profile("default", PATH)
	assert_str(str(Keybinds.bind_of(again, "bar1_slot1")["target_mode"])).is_equal("focus")
	s.reset()
	assert_str(str(Keybinds.bind_of(s.profile, "bar1_slot1").get("target_mode", "default"))).is_equal("default")


func test_export_and_import() -> void:
	var s: KeybindScreen = _screen()
	Keybinds.rebind(s.profile, "jump", "KEY_V", ["shift"])
	var code: String = Keybinds.export_text(s.profile)
	var r: Dictionary = Keybinds.import_text(code)
	assert_str(r["error"]).is_empty()
	assert_str(str(Keybinds.bind_of(r["profile"], "jump")["key"])).is_equal("KEY_V")
	assert_str(Keybinds.import_text("not a code")["error"]).is_not_empty()


func test_the_controller_aims_each_mode_at_its_unit() -> void:
	var ctl: PlayerController = PlayerController.new()
	var view: Dictionary = {"me": {"id": 1, "team": 0}, "units": [
		{"id": 1, "team": 0}, {"id": 2, "team": 0}, {"id": 5, "team": 1}, {"id": 3, "team": 1}, {"id": 7, "team": 1}]}
	var profile: Dictionary = Data.keybinds["default"].duplicate(true)
	for pair: Array in [["bar1_slot1", "self"], ["bar1_slot2", "focus"], ["bar1_slot3", "arena1"], ["bar1_slot4", "arena3"],
			["bar1_slot5", "party1"], ["bar1_slot6", "party2"]]:
		Keybinds.set_target_mode(profile, pair[0], pair[1])
	Keybinds.apply(profile)
	ctl.focus_id = 7
	assert_int(ctl.ability_target_for("bar1_slot1", view)).is_equal(1)
	assert_int(ctl.ability_target_for("bar1_slot2", view)).is_equal(7)
	assert_int(ctl.ability_target_for("bar1_slot3", view)).is_equal(3)  # enemies by id: 3, 5, 7
	assert_int(ctl.ability_target_for("bar1_slot4", view)).is_equal(7)
	assert_int(ctl.ability_target_for("bar1_slot5", view)).is_equal(2)
	assert_int(ctl.ability_target_for("bar1_slot6", view)).is_equal(-1)  # no second party member
	assert_int(ctl.ability_target_for("bar1_slot7", view)).is_equal(-1)  # default: the target


func test_a_focus_cast_hits_the_focus_and_keeps_the_target() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 0.0, 2)
	var me: Unit = runner.add_unit("arcanist_rime", 0)
	var e1: Unit = runner.add_unit("warblade_carnage", 1)
	var e2: Unit = runner.add_unit("oracle_grace", 1)
	runner.sim.add_system(runner.system_combat_and_rules)
	runner.sim.step()
	me.position = Vector3(-10, 0, 13)  # north of the gallows and the pillars: clear sight lines
	e1.position = Vector3(10, 0, 15)
	e2.position = Vector3(10, 0, 11)
	runner.apply_input(me, {"move": Vector2.ZERO, "yaw": -PI / 2, "target": e1.id, "ability": "", "ability_target": -1})
	assert_int(me.target_id).is_equal(e1.id)
	runner.apply_input(me, {"move": Vector2.ZERO, "yaw": -PI / 2, "target": e1.id, "ability": "shiver_lance", "ability_target": e2.id})
	runner.sim.step()
	assert_int(me.target_id).is_equal(e1.id)
	assert_int(e2.health).is_less(e2.max_health)
	assert_int(e1.health).is_equal(e1.max_health)
	var q: Dictionary = Protocol.quantize_input({"seq": 1, "ability": "shiver_lance", "target": 3, "ability_target": 4})
	assert_int(int(Protocol.decode(Protocol.input_packet([q]))["inputs"][0]["ability_target"])).is_equal(4)
