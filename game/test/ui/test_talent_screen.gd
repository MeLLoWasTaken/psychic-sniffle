extends GdUnitTestSuite
## Talent screen and saved loadouts (backlog M2-05): the screen draws from the talent data, follows
## the loadout rules when ranks are added and removed, keeps up to 10 loadouts per spec, exports
## and imports the shared text, and is read-only when locked.

const SPEC: String = "warblade_carnage"
const PATH: String = "user://test_talents.json"

var store: TalentLoadouts


func before_test() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	store = TalentLoadouts.new(PATH)


func _screen(locked: bool = false) -> TalentScreen:
	var s: TalentScreen = auto_free(TalentScreen.new(SPEC, store, locked))
	s.size = Vector2(1920, 1080)
	return s


func _roots(layer: String, trees: Dictionary) -> Array:
	return trees[layer]["nodes"].filter(func(n: Dictionary) -> bool:
		return n.get("requires_any", []).all(func(r: String) -> bool: return Talents.node_of(trees[layer], r).is_empty()) \
			and int(n.get("gate", 0)) == 0)


func test_a_new_player_starts_with_the_bot_builds_as_loadouts() -> void:
	var all: Array = store.list(SPEC)
	assert_int(all.size()).is_equal(Data.bots[SPEC]["builds"].size())
	assert_str(store.active_text(SPEC)).is_equal(BotBrain.build_talents(SPEC)["talents"])


func test_every_node_has_a_place_and_nodes_do_not_overlap() -> void:
	var s: TalentScreen = _screen()
	var rects: Array = []
	for layer: String in ["class", "spec", "pvp"]:
		for n: Dictionary in s.trees[layer]["nodes"]:
			var r: Rect2 = s.node_rect(layer, n)
			assert_bool(Rect2(0, 0, 1920, 1000).encloses(r)).override_failure_message("%s off screen: %s" % [n["id"], r]).is_true()
			for o: Rect2 in rects:
				assert_bool(r.grow(-1.0).intersects(o)).override_failure_message("%s overlaps" % n["id"]).is_false()
			rects.append(r)
			var hit: Dictionary = s.node_at(r.get_center())
			assert_str(str(hit.get("id", ""))).is_equal(n["id"])


func test_adding_follows_the_rules_and_counts_points() -> void:
	var s: TalentScreen = _screen()
	s.reset()
	var root: Dictionary = _roots("spec", s.trees)[0]
	assert_str(s.add("spec", root["id"])).is_equal("")
	assert_int(s.spent("spec")).is_equal(1)
	# a node hanging off a root needs that root fully ranked
	for n: Dictionary in s.trees["spec"]["nodes"]:
		if root["id"] in n.get("requires_any", []) and Talents.max_rank(root) > 1:
			assert_str(s.add("spec", n["id"])).is_not_empty()
			assert_str(s.message).contains("Requires")
			break
	# a gated node refuses until enough points are spent
	for n: Dictionary in s.trees["spec"]["nodes"]:
		if int(n.get("gate", 0)) == 8:
			assert_str(s.add("spec", n["id"])).is_not_empty()
			break


func test_removing_a_rank_others_depend_on_is_refused() -> void:
	var s: TalentScreen = _screen()
	s.select_slot(0)
	var lo: Dictionary = s.loadout.duplicate(true)
	# find a taken node another taken node requires, with no other way in
	for n: Dictionary in s.trees["spec"]["nodes"]:
		var reqs: Array = n.get("requires_any", []).filter(func(r: String) -> bool: return lo["spec"].has(r))
		if lo["spec"].has(n["id"]) and reqs.size() == 1 and int(n.get("gate", 0)) == 0 \
				and n.get("requires_any", []).size() == 1:
			assert_str(s.remove("spec", reqs[0])).is_not_empty()
			assert_str(s.message).contains("depend")
			assert_dict(s.loadout).is_equal(lo)
			return
	fail("the default build has no dependent pair to test with")


func test_choice_nodes_take_the_clicked_side() -> void:
	var s: TalentScreen = _screen()
	for i: int in store.list(SPEC).size():
		s.select_slot(i)
		for layer: String in ["class", "spec"]:
			for n: Dictionary in s.trees[layer]["nodes"]:
				if n["type"] != "choice" or s.rank_of(layer, n["id"]) == 0:
					continue
				var r: Rect2 = s.node_rect(layer, n)
				assert_int(int(s.node_at(r.position + Vector2(3, r.size.y * 0.5))["side"])).is_equal(1)
				assert_int(int(s.node_at(r.end - Vector2(3, r.size.y * 0.5))["side"])).is_equal(2)
				var spent: int = s.spent(layer)
				var other: int = 3 - s.rank_of(layer, n["id"])
				assert_str(s.add(layer, n["id"], other)).is_equal("")
				assert_int(s.rank_of(layer, n["id"])).is_equal(other)
				assert_int(s.spent(layer)).is_equal(spent)  # switching sides costs nothing
				return
	fail("no bot build takes a choice node")


func test_pvp_takes_three_talents() -> void:
	var s: TalentScreen = _screen()
	s.reset()
	var ids: Array = s.trees["pvp"]["nodes"].map(func(n: Dictionary) -> String: return n["id"])
	for i: int in 3:
		assert_str(s.add("pvp", ids[i])).is_equal("")
	assert_str(s.add("pvp", ids[3])).is_not_empty()
	assert_str(s.message).contains("No points")
	assert_str(s.remove("pvp", ids[0])).is_equal("")
	assert_int(s.spent("pvp")).is_equal(2)


func test_export_import_and_saving_slots() -> void:
	var s: TalentScreen = _screen()
	s.select_slot(1)
	var text: String = s.export_text()
	assert_str(text).is_equal(str(store.list(SPEC)[1]["talents"]))
	s.reset()
	assert_int(s.spent("spec")).is_equal(0)
	assert_str(s.import_text(text)).is_equal("")
	assert_int(s.spent("spec")).is_equal(30)
	assert_str(s.import_text("not a code")).is_not_empty()
	var before: int = store.list(SPEC).size()
	assert_int(s.save_new()).is_equal(before)
	assert_int(store.list(SPEC).size()).is_equal(before + 1)
	# the file keeps it
	var again: TalentLoadouts = TalentLoadouts.new(PATH)
	assert_int(again.list(SPEC).size()).is_equal(before + 1)
	assert_int(again.active_index(SPEC)).is_equal(before)


func test_at_most_ten_loadouts_per_spec() -> void:
	var text: String = BotBrain.build_talents(SPEC)["talents"]
	while store.list(SPEC).size() < TalentLoadouts.MAX_PER_SPEC:
		assert_int(store.put(SPEC, store.list(SPEC).size(), "x", text)).is_greater_equal(0)
	assert_int(store.put(SPEC, TalentLoadouts.MAX_PER_SPEC, "one too many", text)).is_equal(-1)
	assert_int(store.put(SPEC, 0, "illegal", "garbage")).is_equal(-1)
	var s: TalentScreen = _screen()
	assert_int(s.save_new()).is_equal(-1)
	assert_bool((s.buttons["new"] as Button).disabled).is_true()


func test_deleting_keeps_the_active_slot_pointing_at_the_same_loadout() -> void:
	store.list(SPEC)
	store.set_active(SPEC, 2)
	var name_before: String = str(store.list(SPEC)[2]["name"])
	store.remove(SPEC, 0)
	assert_str(str(store.list(SPEC)[store.active_index(SPEC)]["name"])).is_equal(name_before)


func test_locked_screen_changes_nothing() -> void:
	var s: TalentScreen = _screen(true)
	s.select_slot(0)
	var lo: Dictionary = s.loadout.duplicate(true)
	var root: Dictionary = _roots("class", s.trees)[0]
	assert_str(s.add("class", root["id"])).is_not_empty()
	s.reset()
	assert_str(s.import_text("")).is_not_empty()
	assert_dict(s.loadout).is_equal(lo)
	assert_bool((s.buttons["save"] as Button).disabled).is_true()


func test_closing_reports_the_active_loadout() -> void:
	var s: TalentScreen = _screen()
	s.select_slot(1)
	var got: Array = []
	s.closed.connect(func(spec: String, text: String) -> void: got.append([spec, text]))
	s.close()
	assert_array(got).is_equal([[SPEC, str(store.list(SPEC)[1]["talents"])]])


func test_the_screen_draws_without_errors() -> void:
	var s: TalentScreen = _screen()
	add_child(s)
	s.hovered = {"layer": "spec", "id": s.trees["spec"]["nodes"][0]["id"], "side": 1}
	var errors: int = Log.error_count
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(Log.error_count).is_equal(errors)
	assert_bool(s.is_inside_tree()).is_true()
	s.queue_free()


func test_the_spellbook_lists_the_kit_and_the_loadout_s_abilities() -> void:
	var s: TalentScreen = _screen()
	s.show_tab("spellbook")
	for i: int in store.list(SPEC).size():
		s.select_slot(i)
		var ids: Array[String] = s.spellbook_abilities()
		for a: String in Data.specs[SPEC]["abilities"]:
			assert_array(ids).contains([a])
		for g: String in s.talented()["grants"]:
			assert_array(ids).contains([g])
		assert_array(ids).contains(["break_free"])
		assert_bool("auto_attack" in ids).is_false()
		for k: int in ids.size():
			var r: Rect2 = s.card_rect(k, ids.size())
			assert_bool(Rect2(0, 150, 1500, 800).encloses(r)).override_failure_message("card %d off its area: %s" % [k, r]).is_true()
			assert_str(s.card_at(r.get_center())).is_equal(ids[k])


func test_the_spellbook_draws_and_shows_a_tooltip() -> void:
	var s: TalentScreen = _screen()
	add_child(s)
	s.show_tab("spellbook")
	s.hovered = {"card": s.spellbook_abilities()[0]}
	var errors: int = Log.error_count
	await get_tree().process_frame
	await get_tree().process_frame
	assert_int(Log.error_count).is_equal(errors)
	s.queue_free()
