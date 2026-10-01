extends GdUnitTestSuite
## HUD edit mode and layout profiles (backlog M2-12).

const PATH: String = "user://test_hud_layouts.json"
const RESOLUTIONS: Array[Vector2] = [Vector2(1280, 720), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160), Vector2(3440, 1440)]

var hud: Hud
var match_: LocalMatch


func before_test() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	hud = auto_free(Hud.new(Data.settings["default"]))
	add_child(hud)
	match_ = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"])
	hud.push(match_.view())
	hud.root.size = Vector2(1920, 1080)
	hud.stretch_override = 1.0
	hud.update(0.0)
	hud.relayout()


func test_edits_never_touch_the_layout_data() -> void:
	var before: String = JSON.stringify(Data.hud_layouts["default"])
	hud.edit_element("player_frame", "scale", 1.5)
	hud.move_element("target_frame", Vector2(100, 100))
	assert_str(JSON.stringify(Data.hud_layouts["default"])).is_equal(before)
	assert_float(float(hud.layout["elements"]["player_frame"]["scale"])).is_equal(1.5)


func test_dragging_snaps_to_the_grid_and_anchors_to_the_nearest_third() -> void:
	hud.move_element("player_frame", Vector2(103, 61))
	var e: Dictionary = hud.layout["elements"]["player_frame"]
	assert_str(str(e["anchor"])).is_equal("top_left")
	for v: float in e["offset"]:
		assert_float(fmod(absf(v), Hud.EDIT_GRID)).is_equal(0.0)
	var r: Rect2 = hud.group_rect("player_frame")
	assert_float(absf(hud.group_rect("player_frame").position.x - 103.0)).is_less_equal(Hud.EDIT_GRID)
	hud.move_element("player_frame", Vector2(1600, 900))
	assert_str(str(hud.layout["elements"]["player_frame"]["anchor"])).is_equal("bottom_right")
	# off-screen drags stay on screen
	hud.move_element("player_frame", Vector2(-500, -500))
	assert_bool(Rect2(Vector2.ZERO, hud.root.size).grow(1.0).encloses(hud.group_rect("player_frame"))).is_true()
	assert_object(r).is_not_null()


func test_the_editor_scales_fades_hides_and_sets_options() -> void:
	hud.toggle_edit_mode()
	var ed: HudEditor = hud.editor
	assert_object(ed).is_not_null()
	ed.selected = "action_bar_1"
	for i: int in 20:
		ed.press("scale_up")
	assert_float(float(hud.layout["elements"]["action_bar_1"]["scale"])).is_equal(Hud.SCALE_RANGE.y)
	for i: int in 30:
		ed.press("scale_down")
	assert_float(float(hud.layout["elements"]["action_bar_1"]["scale"])).is_equal(Hud.SCALE_RANGE.x)
	ed.press("fade")
	assert_float((hud.bars["action_bar_1"] as ActionBar).modulate.a).is_less(1.0)
	var wide: float = (hud.bars["action_bar_1"] as ActionBar).size.x
	ed.press("option")  # 12 -> 6 columns
	assert_int(int(hud.layout["elements"]["action_bar_1"]["columns"])).is_equal(6)
	assert_float((hud.bars["action_bar_1"] as ActionBar).size.x).is_less(wide)
	ed.press("toggle")
	assert_bool((hud.bars["action_bar_1"] as ActionBar).visible).is_false()
	ed.press("toggle")
	assert_bool((hud.bars["action_bar_1"] as ActionBar).visible).is_true()
	ed.selected = "target_frame"
	var side: String = str(hud.layout["elements"]["target_frame"].get("aura_side", "below"))
	ed.press("option")
	assert_str(str(hud.layout["elements"]["target_frame"]["aura_side"])).is_not_equal(side)
	ed.press("reset_element")
	assert_str(str(hud.layout["elements"]["target_frame"].get("aura_side", "below"))).is_equal(side)
	ed.press("done")
	await await_idle_frame()
	assert_object(hud.editor).is_null()


func test_profiles_save_switch_follow_a_spec_and_travel_as_codes() -> void:
	var store: HudLayouts = HudLayouts.new(PATH)
	hud.set_profiles(store, "warblade_carnage")
	hud.toggle_edit_mode()
	var ed: HudEditor = hud.editor
	ed.selected = "player_frame"
	ed.press("scale_up")
	ed.name_edit.text = "Big frames"
	ed.press("save")
	var again: HudLayouts = HudLayouts.new(PATH)
	assert_array(again.names()).contains(["Big frames"])
	assert_str(again.profile_for("warblade_carnage")).is_equal("Big frames")
	assert_float(float(again.changes("Big frames")["player_frame"]["scale"])).is_equal_approx(1.1, 0.001)
	# a second profile only for this spec
	ed.press("reset_all")
	ed.name_edit.text = "Plain"
	ed.press("save_new")
	ed.press("spec_only")
	store.set_active("Big frames")  # the other specs follow the active layout
	assert_str(store.profile_for("warblade_carnage")).is_equal("Plain")
	assert_str(store.profile_for("oracle_grace")).is_equal("Big frames")
	# export the big one and import it
	var code: String = HudLayouts.export_text(store.changes("Big frames"))
	var r: Dictionary = HudLayouts.import_text(code, hud.base_layout)
	assert_str(r["error"]).is_empty()
	hud.apply_changes(r["changes"])
	assert_float(float(hud.layout["elements"]["player_frame"]["scale"])).is_equal_approx(1.1, 0.001)
	assert_str(HudLayouts.import_text("nonsense", hud.base_layout)["error"]).is_not_empty()
	ed.press("delete")
	assert_bool(store.names().has("Plain")).is_false()


func test_an_edited_layout_holds_at_every_design_resolution() -> void:
	hud.move_element("player_frame", Vector2(80, 600))
	hud.move_element("focus_frame", Vector2(1500, 520))
	hud.edit_element("action_bar_2", "scale", 0.8)
	var base: Vector2 = Vector2(1920, 1080)
	for res: Vector2 in RESOLUTIONS:
		hud.stretch_override = res.y / base.y
		hud.root.size = Vector2(base.y * res.x / res.y, base.y)
		hud.relayout()
		var screen: Rect2 = Rect2(Vector2.ZERO, hud.root.size)
		var rects: Dictionary = hud.element_rects()
		for id: String in rects:
			assert_bool(screen.grow(0.5).encloses(rects[id])).override_failure_message("%s: %s %s off screen" % [res, id, rects[id]]).is_true()
		# the moved frame keeps to its side of the screen
		assert_float(hud.group_rect("player_frame").position.x).is_less(hud.root.size.x / 3.0)
		assert_float(hud.group_rect("focus_frame").end.x).is_greater(hud.root.size.x * 2.0 / 3.0)
