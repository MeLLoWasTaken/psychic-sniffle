extends GdUnitTestSuite
## Arena HUD for 2v2 and 3v3 (backlog M2-14): nameplates over units (class-colored health, cast
## bars, important auras, the target marked, overlapping plates stepped apart, the interface
## settings), spec icons in frame portraits, unit frames counting as mouseover, and the arena
## frames' Break Free box following the enemy's talented cooldown.

var ctl: PlayerController
var hud: Hud
var match_: LocalMatch
var cam: Camera3D
var spots: Dictionary = {}  ## unit id -> world position used by the plates


func before_test() -> void:
	Keybinds.load_profile("default")
	ctl = PlayerController.new(Data.settings["default"])
	hud = auto_free(Hud.new(Data.settings["default"]))
	add_child(hud)
	cam = auto_free(Camera3D.new())
	add_child(cam)
	cam.position = Vector3(0, 3, 14)
	cam.look_at(Vector3(0, 2, 0))
	hud.bind(ctl, cam)
	match_ = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"])
	spots.clear()
	var x: float = -6.0
	for u: Dictionary in match_.view()["units"]:
		spots[int(u["id"])] = Vector3(x, 0, 0)
		x += 4.0
	_plates().position_of = func(id: int) -> Vector3: return spots.get(id, Vector3(INF, INF, INF))
	hud.root.size = Vector2(1920, 1080)
	hud.stretch_override = 1.0
	hud.relayout()


func _plates() -> Nameplates:
	return hud.elements["nameplates"]


func _enemy(v: Dictionary, n: int = 0) -> Dictionary:
	var out: Array = []
	for u: Dictionary in v["units"]:
		if int(u["team"]) != int(v["me"]["team"]):
			out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	return out[n]


func _show(v: Dictionary, events: Array = []) -> void:
	hud.push(v, events)
	hud.update(0.0)
	await await_idle_frame()  # the plates fill `placed` when they draw
	await await_idle_frame()


func _placed(id: int) -> Dictionary:
	for p: Dictionary in _plates().placed:
		if int(p["id"]) == id:
			return p
	return {}


func test_every_other_living_unit_gets_a_plate_over_its_head() -> void:
	var v: Dictionary = match_.view().duplicate(true)
	await _show(v)
	var me: int = int(v["me"]["id"])
	assert_dict(_placed(me)).is_empty()  # never the player's own
	for u: Dictionary in v["units"]:
		if int(u["id"]) == me:
			continue
		var p: Dictionary = _placed(int(u["id"]))
		assert_dict(p).override_failure_message("no plate for %s" % u["spec"]).is_not_empty()
		var feet: Vector2 = cam.unproject_position(spots[int(u["id"])])
		var head: Vector2 = cam.unproject_position(spots[int(u["id"])] + Vector3.UP * _plates().height_m)
		assert_float((p["rect"] as Rect2).end.y).is_less(feet.y)  # above the unit
		assert_float(absf((p["rect"] as Rect2).get_center().x - head.x)).is_less(1.0)
	# dead units and units behind the camera get none
	var e: Dictionary = _enemy(v)
	e["health"] = 0
	spots[int(_enemy(v, 1)["id"])] = Vector3(0, 0, 30)
	await _show(v)
	assert_dict(_placed(int(e["id"]))).is_empty()
	assert_dict(_placed(int(_enemy(v, 1)["id"]))).is_empty()


func test_the_target_plate_is_marked_and_larger() -> void:
	var v: Dictionary = match_.view().duplicate(true)
	var a: int = int(_enemy(v, 0)["id"])
	var b: int = int(_enemy(v, 1)["id"])
	ctl.set_target(a)
	await _show(v)
	assert_bool(bool(_placed(a)["target"])).is_true()
	assert_bool(bool(_placed(b)["target"])).is_false()
	assert_float((_placed(a)["rect"] as Rect2).size.x).is_greater((_placed(b)["rect"] as Rect2).size.x)


func test_plates_show_casts_and_important_auras() -> void:
	var v: Dictionary = match_.view().duplicate(true)
	var tick: int = int(v["tick"])
	var me: int = int(v["me"]["id"])
	var e: Dictionary = _enemy(v)
	e["cast"] = {"ability": "rime_bolt", "target": me, "start_tick": tick, "end_tick": tick + 108, "channel": false}
	e["auras"] = [
		{"id": "pommel_cracked", "source": me, "applied_tick": tick, "expires_tick": tick + 180, "stacks": 1},  # crowd control
		{"id": "glacier_shield", "source": int(e["id"]), "applied_tick": tick, "expires_tick": tick + 480, "stacks": 1},  # major defensive
	]
	await _show(v)
	var p: Dictionary = _placed(int(e["id"]))
	assert_bool(bool(p["cast"])).is_true()
	assert_array(p["auras"]).contains_exactly(["pommel_cracked", "glacier_shield"])
	# only important auras and the player's own debuffs, at most max_auras
	var shown: Array = Nameplates.plate_auras(e, v, 999, 4).map(func(x: Dictionary) -> String: return x["id"])
	assert_array(shown).contains_exactly(["pommel_cracked", "glacier_shield"])
	# the interface settings turn cast bars and auras off
	Settings.use_data()
	Settings.set_value("interface.nameplate_cast_bars", false)
	Settings.set_value("interface.nameplate_debuffs", false)
	hud._on_setting("interface.nameplate_cast_bars", false)
	hud._on_setting("interface.nameplate_debuffs", false)
	await _show(v)
	p = _placed(int(e["id"]))
	assert_bool(bool(p["cast"])).is_false()
	assert_array(p["auras"]).is_empty()
	hud._on_setting("interface.nameplates", false)
	assert_bool(_plates().visible).is_false()
	Settings.use_data()


func test_overlapping_plates_step_apart() -> void:
	var rects: Array = Nameplates.unstack([Rect2(100, 300, 130, 30), Rect2(120, 310, 130, 30), Rect2(90, 305, 130, 30)])
	assert_object(rects[0]).is_equal(Rect2(100, 300, 130, 30))  # the nearest keeps its place
	for i: int in rects.size():
		for j: int in range(i + 1, rects.size()):
			assert_bool((rects[i] as Rect2).intersects(rects[j])).is_false()
	# two units side by side on screen get plates that do not cover each other
	var v: Dictionary = match_.view().duplicate(true)
	var a: int = int(_enemy(v, 0)["id"])
	var b: int = int(_enemy(v, 1)["id"])
	spots[a] = Vector3(0, 0, 0)
	spots[b] = Vector3(0.3, 0, -0.5)
	await _show(v)
	assert_bool((_placed(a)["rect"] as Rect2).intersects(_placed(b)["rect"])).is_false()


func test_frame_portraits_show_the_spec_icon() -> void:
	var v: Dictionary = match_.view().duplicate(true)
	await _show(v)
	for spec_id: String in Data.specs:
		assert_bool(Data.specs[spec_id].has("icon")).override_failure_message("%s has no icon" % spec_id).is_true()
		assert_object(hud.style.icon_texture(Data.specs[spec_id]["icon"])).is_not_null()
	var f: UnitFrame = (hud.elements["player_frame"] as Array)[0]
	assert_bool(f.portrait_glyph).is_true()


func test_a_unit_frame_under_the_pointer_counts_as_mouseover() -> void:
	var v: Dictionary = match_.view().duplicate(true)
	await _show(v)
	var f: UnitFrame = (hud.elements["arena_frames"] as Array)[1]
	var enemy: int = f.unit_id()
	assert_int(enemy).is_not_equal(-1)
	f.mouse_entered.emit()
	assert_int(ctl.frame_mouseover).is_equal(enemy)
	Keybinds.apply(Data.keybinds["default"].duplicate(true))  # a copy: the mode change stays out of the data
	Keybinds.set_target_mode(Keybinds.current, "bar1_slot3", "mouseover")
	assert_int(ctl.ability_target_for("bar1_slot3", v)).is_equal(enemy)
	f.mouse_exited.emit()
	assert_int(ctl.frame_mouseover).is_equal(-1)
	assert_int(ctl.ability_target_for("bar1_slot3", v)).is_equal(-1)  # no camera, no unit under the pointer
	Keybinds.load_profile("default")


func test_the_break_free_box_follows_the_enemy_talented_cooldown() -> void:
	var v: Dictionary = match_.view().duplicate(true)
	var enemy: int = int(_enemy(v)["id"])
	var tick: int = int(v["tick"])
	hud.push(v, [{"type": "cast_success", "source": enemy, "target": enemy, "ability": "break_free", "tick": tick,
		"cooldown_ticks": 75 * 60}])
	assert_int(int(hud.break_free[enemy]["ready_tick"])).is_equal(tick + 75 * 60)
	assert_int(int(hud.break_free[enemy]["total_ticks"])).is_equal(75 * 60)
