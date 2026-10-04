extends GdUnitTestSuite
## The character creator (backlog G-06): every tab's rows step through real options, armor rows
## offer only the class's armor type, dyes recolour worn pieces, and Save keeps the look per spec.

const SPEC: String = "templar_vanguard"
var screen: CharacterScreen


func before_test() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://appearance/%s.json" % SPEC))
	screen = auto_free(CharacterScreen.new(SPEC))
	add_child(screen)


func after_test() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://appearance/%s.json" % SPEC))


func test_every_tab_steps_through_valid_choices() -> void:
	for t: String in CharacterScreen.TABS:
		screen.show_tab(t)
		var rows: Array = screen.rows()
		assert_int(rows.size()).override_failure_message("tab %s has no rows" % t).is_greater(0)
		for r: Array in rows:
			screen.step(str(r[0]), 1)
			assert_dict(Appearance.sanitize(screen.look, SPEC)).is_equal(screen.look)
		# the rows on screen show the same rows
		var shown: Array = screen.rows_box.get_children().filter(func(c: Node) -> bool: return not c.is_queued_for_deletion())
		assert_int(shown.size()).is_equal(screen.rows().size())


func test_armor_rows_offer_only_the_class_armor_type() -> void:
	for slot: String in Appearance.SLOTS:
		for p: String in screen.piece_options(slot):
			if p != "":
				assert_bool(Appearance.piece_valid(p, slot, "plate")).is_true()
	assert_array(screen.piece_options("chest")).not_contains([""])   # the chest can not be hidden
	assert_array(screen.piece_options("head")).contains([""])


func test_body_type_change_drops_the_beard() -> void:
	screen.look["beard"] = "full"
	screen.look = Appearance.sanitize(screen.look, SPEC)
	screen.step("body", 1)   # male -> female
	assert_str(str(screen.look["body"])).is_equal("female")
	assert_str(str(screen.look["beard"])).is_equal("none")


func test_dyes_recolour_the_chosen_piece() -> void:
	screen.show_tab("dyes")
	var before: String = str(screen.look["dyes"]["chest"]["primary"])
	screen.step("dye:primary", 1)
	assert_str(str(screen.look["dyes"]["chest"]["primary"])).is_not_equal(before)


func test_randomize_changes_the_person_not_the_armor() -> void:
	var pieces: Dictionary = screen.look["pieces"].duplicate()
	screen.randomize_look(5)
	assert_dict(screen.look["pieces"]).is_equal(pieces)


func test_save_keeps_the_look_for_the_spec() -> void:
	screen.step("face", 1)
	screen.step("skin", 2)
	screen.save()
	var loaded: Dictionary = Appearance.load_saved(SPEC)
	assert_str(str(loaded["face"])).is_equal(str(screen.look["face"]))
	assert_str(str(loaded["skin"])).is_equal(str(screen.look["skin"]))
	assert_str(str(Appearance.load_saved("templar_zealot")["face"])).is_equal("neutral")   # other specs untouched


func test_the_preview_shows_the_assembled_character() -> void:
	assert_object(screen.model).is_not_null()
	assert_object(CharacterRig.skeleton_of(screen.model)).is_not_null()
