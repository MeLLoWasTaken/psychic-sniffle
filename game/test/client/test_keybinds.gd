extends GdUnitTestSuite
## Keybind profiles (backlog M1-23): loading a profile registers every action in the InputMap
## with exactly the profile's key or mouse button and modifiers, replacing older events.


func _profile() -> Dictionary:
	return Data.keybinds["default"]


func test_default_profile_registers_every_action_with_its_key_and_modifiers() -> void:
	var actions: Array[String] = Keybinds.load_profile("default")
	var binds: Array = _profile()["binds"]
	assert_int(actions.size()).is_equal(binds.size())
	for b: Dictionary in binds:
		var action: String = b["action"]
		assert_bool(InputMap.has_action(action)).override_failure_message("no action %s" % action).is_true()
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		assert_int(events.size()).override_failure_message("%s has %d events" % [action, events.size()]).is_equal(1)
		var ev: InputEventWithModifiers = events[0]
		var key: String = b["key"]
		if key.begins_with("MOUSE_BUTTON_"):
			assert_object(ev).is_instanceof(InputEventMouseButton)
			assert_int((ev as InputEventMouseButton).button_index).is_equal(Keybinds.MOUSE_BUTTONS[key])
		else:
			assert_object(ev).is_instanceof(InputEventKey)
			var code: Key = (ev as InputEventKey).keycode
			assert_str("KEY_" + OS.get_keycode_string(code).to_upper()).override_failure_message(
				"%s: %s" % [action, OS.get_keycode_string(code)]).is_equal(key)
		var mods: Array = b.get("modifiers", [])
		assert_bool(ev.shift_pressed).is_equal("shift" in mods)
		assert_bool(ev.ctrl_pressed).is_equal("ctrl" in mods)
		assert_bool(ev.alt_pressed).is_equal("alt" in mods)


func test_loading_replaces_older_events() -> void:
	if not InputMap.has_action("move_forward"):
		InputMap.add_action("move_forward")
	var old: InputEventKey = InputEventKey.new()
	old.keycode = KEY_UP
	InputMap.action_add_event("move_forward", old)
	Keybinds.load_profile("default")
	var events: Array[InputEvent] = InputMap.action_get_events("move_forward")
	assert_int(events.size()).is_equal(1)
	assert_int((events[0] as InputEventKey).keycode).is_equal(KEY_W)


func test_modifier_binds_match_exactly() -> void:
	Keybinds.load_profile("default")
	var shift_1: InputEventKey = InputEventKey.new()
	shift_1.keycode = KEY_1
	shift_1.shift_pressed = true
	shift_1.pressed = true
	var plain_1: InputEventKey = InputEventKey.new()
	plain_1.keycode = KEY_1
	plain_1.pressed = true
	assert_bool(shift_1.is_action_pressed("bar2_slot1", false, true)).is_true()
	assert_bool(shift_1.is_action_pressed("bar1_slot1", false, true)).is_false()
	assert_bool(plain_1.is_action_pressed("bar1_slot1", false, true)).is_true()
	assert_bool(plain_1.is_action_pressed("bar2_slot1", false, true)).is_false()
	# a plain bind still fires with a modifier held (Shift+W moves forward)
	var shift_w: InputEventKey = InputEventKey.new()
	shift_w.keycode = KEY_W
	shift_w.shift_pressed = true
	shift_w.pressed = true
	assert_bool(shift_w.is_action_pressed("move_forward")).is_true()


func test_labels_and_mouse_button_names() -> void:
	Keybinds.load_profile("default")
	assert_str(Keybinds.label("bar2_slot1")).is_equal("Shift+1")
	assert_str(Keybinds.label("target_nearest_enemy")).is_equal("Tab")
	assert_str(Keybinds.label("camera_steer")).is_equal("Mouse 2")
	var side: InputEvent = Keybinds.event_for({"key": "MOUSE_BUTTON_4"})
	assert_int((side as InputEventMouseButton).button_index).is_equal(MOUSE_BUTTON_XBUTTON1)
	assert_object(Keybinds.event_for({"key": "KEY_NOT_A_KEY"})).is_null()
