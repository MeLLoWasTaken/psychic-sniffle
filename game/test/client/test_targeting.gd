extends GdUnitTestSuite
## Targeting (backlog M1-23): a click selects the unit under the cursor, empty ground keeps the
## target, walls hide units; Tab picks enemies in front of the camera, in range and in sight,
## ordered by angle from the screen centre then distance, and cycles; Escape clears.

const ME: int = 1
const A: int = 2  ## enemy 10 m straight ahead
const B: int = 3  ## enemy 20 m ahead, a little right of the centre
const C: int = 4  ## enemy 14 m away, about 24 degrees off the centre
const D: int = 5  ## enemy behind the camera
const E: int = 6  ## enemy out of Tab range (settings limit 25 m in this test)
const F: int = 7  ## enemy hidden behind the pillar at (-8, 7)
const G: int = 8  ## ally ahead
const H: int = 9  ## dead enemy ahead

var viewport: SubViewport
var cam: ThirdPersonCamera
var geometry: ArenaGeometry
var targeting: Targeting
var settings: Dictionary


func before_test() -> void:
	settings = Data.settings["default"].duplicate(true)
	settings["targeting"]["tab_range_m"] = 25.0
	viewport = auto_free(SubViewport.new())
	viewport.size = Vector2i(1280, 720)
	viewport.disable_3d = false
	add_child(viewport)
	cam = ThirdPersonCamera.new(settings["camera"])
	viewport.add_child(cam)
	cam.camera.current = true
	geometry = ArenaGeometry.from_map(Data.maps["gallows_courtyard"])
	geometry.gates_open = true
	cam.geometry = geometry
	targeting = Targeting.new(settings["targeting"])
	_look(-PI / 2)  # the player at (-10, 0, 13) faces +x


func _look(yaw: float) -> void:
	for i: int in 5:
		cam.update(Vector3(-10, 0, 13), yaw, deg_to_rad(15), 1.0)


func _unit(id: int, team: int, pos: Vector3, health: int = 60000) -> Dictionary:
	return {"id": id, "team": team, "position": pos, "facing": 0.0, "health": health, "spec": "warblade_carnage"}


func _units() -> Array:
	return [
		_unit(ME, 0, Vector3(-10, 0, 13)),
		_unit(A, 1, Vector3(0, 0, 13)),
		_unit(B, 1, Vector3(10, 0, 15)),
		_unit(C, 1, Vector3(2, 0, 5)),
		_unit(D, 1, Vector3(-18, 0, 5)),
		_unit(E, 1, Vector3(18, 0, 11)),
		_unit(F, 1, Vector3(-5, 0, -2)),
		_unit(G, 0, Vector3(-5, 0, 11)),
		_unit(H, 1, Vector3(-3, 0, 14), 0),
	]


func _me() -> Dictionary:
	return _units()[0]


func _screen_of(pos: Vector3, height: float = 1.0) -> Vector2:
	return cam.camera.unproject_position(pos + Vector3.UP * height)


func test_tab_orders_enemies_in_front_by_angle_then_distance() -> void:
	var order: Array[int] = targeting.tab_order(cam.camera, _me(), _units(), geometry)
	assert_array(order).is_equal([A, B, C])


func test_tab_picks_the_nearest_enemy_in_front_and_cycles() -> void:
	var t: int = targeting.tab(cam.camera, _me(), _units(), geometry, -1)
	assert_int(t).is_equal(A)
	t = targeting.tab(cam.camera, _me(), _units(), geometry, t)
	assert_int(t).is_equal(B)
	t = targeting.tab(cam.camera, _me(), _units(), geometry, t)
	assert_int(t).is_equal(C)
	t = targeting.tab(cam.camera, _me(), _units(), geometry, t)
	assert_int(t).is_equal(A)
	# from an ally or an enemy not in the list, Tab starts at the front of the order
	assert_int(targeting.tab(cam.camera, _me(), _units(), geometry, G)).is_equal(A)
	assert_int(targeting.tab(cam.camera, _me(), _units(), geometry, D)).is_equal(A)


func test_tab_falls_back_to_the_nearest_enemy_when_none_is_in_front() -> void:
	var units: Array = [_me(), _unit(D, 1, Vector3(-16, 0, 16)), _unit(E, 1, Vector3(18, 0, 11))]
	assert_int(targeting.tab(cam.camera, _me(), units, geometry, -1)).is_equal(D)
	# nobody at all in range and sight: the target stays
	assert_int(targeting.tab(cam.camera, _me(), [_me(), _unit(E, 1, Vector3(18, 0, 11))], geometry, G)).is_equal(G)


func test_click_selects_the_unit_under_the_cursor() -> void:
	for id: int in [A, B, C, G]:
		var u: Dictionary = _units()[[ME, A, B, C, D, E, F, G, H].find(id)]
		assert_int(targeting.pick_at(cam.camera, _screen_of(u["position"]), _units(), geometry)).override_failure_message(
			"clicked unit %d" % id).is_equal(id)
	# the player's own character can be clicked too
	assert_int(targeting.pick_at(cam.camera, _screen_of(Vector3(-10, 0, 13), 1.2), _units(), geometry)).is_equal(ME)


func test_click_on_empty_ground_keeps_the_target_unless_set_to_clear() -> void:
	var ground: Vector2 = _screen_of(Vector3(-4, 0, 17), 0.0)
	assert_int(targeting.pick_at(cam.camera, ground, _units(), geometry)).is_equal(-1)
	assert_int(targeting.click(cam.camera, ground, _units(), geometry, B)).is_equal(B)
	var sky: Vector2 = Vector2(640, 5)
	assert_int(targeting.click(cam.camera, sky, _units(), geometry, B)).is_equal(B)
	var s: Dictionary = settings["targeting"].duplicate()
	s["click_empty_clears_target"] = true
	assert_int(Targeting.new(s).click(cam.camera, ground, _units(), geometry, B)).is_equal(-1)


func test_a_pillar_hides_a_unit_from_clicks() -> void:
	# a unit straight behind the pillar at (-8, 7) as seen from the camera; click its chest
	var cam_pos: Vector3 = cam.camera.global_position
	var flat: Vector3 = Vector3(-8.0 - cam_pos.x, 0.0, 7.0 - cam_pos.z)
	var behind: Vector3 = Vector3(cam_pos.x, 0.0, cam_pos.z) + flat * 1.6
	var units: Array = [_me(), _unit(F, 1, behind)]
	var at: Vector2 = _screen_of(behind, 1.0)
	assert_int(targeting.pick_at(cam.camera, at, units, geometry)).is_equal(-1)
	# with no pillar in the way the same unit is picked
	assert_int(targeting.pick_at(cam.camera, at, units, null)).is_equal(F)


func test_nearest_body_wins_when_bodies_overlap_on_screen() -> void:
	var units: Array = [_me(), _unit(A, 1, Vector3(0, 0, 13)), _unit(B, 1, Vector3(4, 0, 13))]
	var at: Vector2 = _screen_of(Vector3(0, 0, 13), 1.0)
	assert_int(targeting.pick_at(cam.camera, at, units, geometry)).is_equal(A)


func test_controller_resolves_tab_click_and_escape() -> void:
	Keybinds.load_profile("default")
	var ctl: PlayerController = PlayerController.new(settings)
	ctl.reset_facing(-PI / 2)
	var view: Dictionary = {"tick": 1, "me": _me(), "units": _units()}
	var tab: InputEventKey = InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.pressed = true
	ctl.handle_event(tab)
	var inp: Dictionary = ctl.next_input(1.0 / 60.0, view, cam.camera, [], geometry)
	assert_int(inp["target"]).is_equal(A)
	assert_bool(inp["clear_target"]).is_false()
	ctl.handle_event(tab)
	assert_int(ctl.next_input(1.0 / 60.0, view, cam.camera, [], geometry)["target"]).is_equal(B)
	# click the ally: selected, and the server is told there is no enemy target
	var click: InputEventMouseButton = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = _screen_of(Vector3(-5, 0, 11))
	click.pressed = true
	ctl.handle_event(click)
	click = click.duplicate()
	click.pressed = false
	ctl.handle_event(click)
	inp = ctl.next_input(1.0 / 60.0, view, cam.camera, [], geometry)
	assert_int(inp["target"]).is_equal(G)
	assert_bool(inp["clear_target"]).is_true()
	var esc: InputEventKey = InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	ctl.handle_event(esc)
	inp = ctl.next_input(1.0 / 60.0, view, cam.camera, [], geometry)
	assert_int(inp["target"]).is_equal(-1)
	assert_bool(inp["clear_target"]).is_true()
