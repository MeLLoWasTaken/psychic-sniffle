extends GdUnitTestSuite
## Player controls (backlog M1-23): key and mouse events become the same input dictionary the
## bots produce. W/S forward and back, A/D turn (strafe with the right button held), Q/E strafe,
## both buttons run forward; right drag steers the character, left drag orbits only the camera.

const DT: float = 1.0 / 60.0

var ctl: PlayerController


func before_test() -> void:
	Keybinds.load_profile("default")
	ctl = PlayerController.new(Data.settings["default"])
	ctl.reset_facing(0.0)


func _key(code: Key, pressed: bool) -> void:
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = code
	ev.pressed = pressed
	ctl.handle_event(ev)


func _button(index: MouseButton, pressed: bool, pos: Vector2 = Vector2(400, 300)) -> void:
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = index
	ev.pressed = pressed
	ev.position = pos
	ctl.handle_event(ev)


func _motion(rel: Vector2) -> void:
	var ev: InputEventMouseMotion = InputEventMouseMotion.new()
	ev.relative = rel
	ctl.handle_event(ev)


func test_forward_back_and_strafe_keys() -> void:
	_key(KEY_W, true)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(0, 1))
	_key(KEY_S, true)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(0, 0))
	_key(KEY_W, false)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(0, -1))
	_key(KEY_S, false)
	_key(KEY_Q, true)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(-1, 0))
	_key(KEY_Q, false)
	_key(KEY_E, true)
	var inp: Dictionary = ctl.next_input(DT)
	assert_vector(inp["move"]).is_equal(Vector2(1, 0))
	assert_float(inp["yaw"]).is_equal(0.0)  # strafing never turns
	_key(KEY_E, false)
	_key(KEY_SPACE, true)
	assert_bool(ctl.next_input(DT)["jump"]).is_true()
	_key(KEY_SPACE, false)
	assert_bool(ctl.next_input(DT)["jump"]).is_false()


func test_input_has_the_bot_input_shape() -> void:
	var inp: Dictionary = ctl.next_input(DT)
	for k: String in ["move", "yaw", "jump", "tab", "ability", "target"]:
		assert_bool(inp.has(k)).override_failure_message("missing %s" % k).is_true()


func test_a_and_d_turn_at_the_keyboard_turn_speed() -> void:
	var speed: float = deg_to_rad(float(Data.settings["default"]["movement"]["keyboard_turn_deg_s"]))
	_key(KEY_A, true)
	var inp: Dictionary = {}
	for i: int in 30:
		inp = ctl.next_input(DT)
	assert_vector(inp["move"]).is_equal(Vector2.ZERO)
	assert_float(inp["yaw"]).is_equal_approx(speed * 0.5, 1e-4)  # turning left raises yaw
	_key(KEY_A, false)
	_key(KEY_D, true)
	for i: int in 30:
		inp = ctl.next_input(DT)
	assert_float(inp["yaw"]).is_equal_approx(0.0, 1e-4)
	assert_float(ctl.orbit).is_equal(0.0)  # the camera stays behind the turning character


func test_a_and_d_strafe_while_the_right_button_is_held() -> void:
	_button(MOUSE_BUTTON_RIGHT, true)
	_key(KEY_A, true)
	var inp: Dictionary = ctl.next_input(DT)
	assert_vector(inp["move"]).is_equal(Vector2(-1, 0))
	assert_float(inp["yaw"]).is_equal(0.0)
	_key(KEY_A, false)
	_key(KEY_D, true)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(1, 0))
	_button(MOUSE_BUTTON_RIGHT, false)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2.ZERO)  # D turns again


func test_both_mouse_buttons_run_forward() -> void:
	_button(MOUSE_BUTTON_LEFT, true)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2.ZERO)
	_button(MOUSE_BUTTON_RIGHT, true)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(0, 1))
	_button(MOUSE_BUTTON_LEFT, false)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2.ZERO)


func test_right_drag_steers_character_and_camera() -> void:
	var sens: float = deg_to_rad(float(Data.settings["default"]["mouse"]["sensitivity_deg_per_px"]))
	_button(MOUSE_BUTTON_RIGHT, true)
	_motion(Vector2(40, 0))  # mouse right turns right: yaw falls
	var inp: Dictionary = ctl.next_input(DT)
	assert_float(inp["yaw"]).is_equal_approx(-40 * sens, 1e-5)
	assert_float(ctl.camera_yaw()).is_equal_approx(-40 * sens, 1e-5)
	var pitch_before: float = ctl.pitch
	_motion(Vector2(0, 20))  # mouse down raises the camera
	assert_float(ctl.pitch).is_equal_approx(pitch_before + 20 * sens, 1e-5)
	_button(MOUSE_BUTTON_RIGHT, false)


func test_left_drag_orbits_the_camera_only_and_release_keeps_it() -> void:
	var sens: float = deg_to_rad(float(Data.settings["default"]["mouse"]["sensitivity_deg_per_px"]))
	_button(MOUSE_BUTTON_LEFT, true)
	_motion(Vector2(-100, 0))
	var inp: Dictionary = ctl.next_input(DT)
	assert_float(inp["yaw"]).is_equal(0.0)  # the character keeps facing
	assert_float(ctl.camera_yaw()).is_equal_approx(100 * sens, 1e-5)
	_button(MOUSE_BUTTON_LEFT, false)
	assert_float(ctl.camera_yaw()).is_equal_approx(100 * sens, 1e-5)  # stays where it was left
	# walking forward goes the way the character faces, not the camera
	_key(KEY_W, true)
	inp = ctl.next_input(DT)
	assert_vector(inp["move"]).is_equal(Vector2(0, 1))
	assert_float(inp["yaw"]).is_equal(0.0)
	# pressing the right button turns the character to face the camera's way
	_button(MOUSE_BUTTON_RIGHT, true)
	assert_float(ctl.next_input(DT)["yaw"]).is_equal_approx(100 * sens, 1e-5)
	assert_float(ctl.orbit).is_equal(0.0)


func test_pitch_is_clamped_and_invert_flips_it() -> void:
	var s: Dictionary = Data.settings["default"].duplicate(true)
	_button(MOUSE_BUTTON_RIGHT, true)
	_motion(Vector2(0, 100000))
	assert_float(ctl.pitch).is_equal_approx(deg_to_rad(float(s["camera"]["pitch_max_deg"])), 1e-5)
	_motion(Vector2(0, -100000))
	assert_float(ctl.pitch).is_equal_approx(deg_to_rad(float(s["camera"]["pitch_min_deg"])), 1e-5)
	s["mouse"]["invert_y"] = true
	ctl = PlayerController.new(s)
	var p0: float = ctl.pitch
	_button(MOUSE_BUTTON_RIGHT, true)
	_motion(Vector2(0, 10))
	assert_float(ctl.pitch).is_less(p0)


func test_wheel_counts_zoom_steps_and_a_short_press_is_a_click() -> void:
	_button(MOUSE_BUTTON_WHEEL_UP, true)
	_button(MOUSE_BUTTON_WHEEL_UP, false)
	_button(MOUSE_BUTTON_WHEEL_DOWN, true)
	_button(MOUSE_BUTTON_WHEEL_DOWN, true)
	assert_int(ctl.pending_zoom).is_equal(1)
	_button(MOUSE_BUTTON_LEFT, true, Vector2(100, 100))
	_motion(Vector2(2, 1))
	_button(MOUSE_BUTTON_LEFT, false, Vector2(102, 101))
	assert_int(ctl._requests.size()).is_equal(1)
	assert_vector(ctl._requests[0][1]).is_equal(Vector2(100, 100))
	_button(MOUSE_BUTTON_LEFT, true, Vector2(100, 100))
	_motion(Vector2(30, 0))  # a drag, not a click
	assert_bool(ctl.is_dragging()).is_true()
	_button(MOUSE_BUTTON_LEFT, false, Vector2(130, 100))
	assert_int(ctl._requests.size()).is_equal(1)


func test_scripted_actions_use_the_same_path() -> void:
	var s: ScriptedInput = ScriptedInput.new("move_forward:1,wait:0.5,strafe_left:0.5")
	assert_float(s.length()).is_equal_approx(2.0, 1e-6)
	for ev: InputEvent in s.events_until(0.0):
		ctl.handle_event(ev)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(0, 1))
	for ev: InputEvent in s.events_until(1.6):
		ctl.handle_event(ev)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2(-1, 0))
	for ev: InputEvent in s.events_until(2.0):
		ctl.handle_event(ev)
	assert_vector(ctl.next_input(DT)["move"]).is_equal(Vector2.ZERO)


func test_after_death_the_camera_watches_a_living_teammate_and_tab_cycles() -> void:
	# F-16: in the reference video the camera stayed on the player's body for the last 80 s
	var view: Dictionary = {"me": {"id": 1, "team": 0, "health": 50000},
		"units": [{"id": 1, "team": 0, "health": 50000}, {"id": 2, "team": 0, "health": 30000},
			{"id": 4, "team": 0, "health": 20000}, {"id": 3, "team": 1, "health": 40000}]}
	assert_int(PlayerController.watched_unit(view, 0)).is_equal(1)  # alive: the player
	view["me"]["health"] = 0
	view["units"][0]["health"] = 0
	assert_int(PlayerController.watched_unit(view, 0)).is_equal(2)
	assert_int(PlayerController.watched_unit(view, 1)).is_equal(4)
	assert_int(PlayerController.watched_unit(view, 2)).is_equal(2)  # around again
	view["units"][1]["health"] = 0
	assert_int(PlayerController.watched_unit(view, 0)).is_equal(4)  # never a dead teammate or an enemy
	view["units"][2]["health"] = 0
	assert_int(PlayerController.watched_unit(view, 0)).is_equal(1)  # nobody left: the body
	# Tab while dead moves the camera on instead of targeting
	view["units"][1]["health"] = 30000
	view["units"][2]["health"] = 20000
	var cam: Camera3D = auto_free(Camera3D.new())
	add_child(cam)
	var before: int = ctl.target_id
	ctl._requests.append(["tab"])
	ctl.next_input(DT, view, cam)
	assert_int(ctl.spectate_step).is_equal(1)
	assert_int(ctl.target_id).is_equal(before)
	assert_int(PlayerController.watched_unit(view, ctl.spectate_step)).is_equal(4)
