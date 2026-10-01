extends GdUnitTestSuite
## Tooltip text from data (backlog M2-06): numbers come from the combat formula, descriptions agree
## with them for every ability (talent abilities included), and talents change what is shown.


func _owner_spec(ab: Dictionary) -> String:
	if Data.specs.has(str(ab["owner"])):
		return str(ab["owner"])
	for sid: String in Data.specs:
		if Data.specs[sid]["class"] == ab["owner"]:
			return sid
	return "warblade_carnage"  # shared abilities: any spec (no power bonus differences today)


func test_number_formatting() -> void:
	assert_str(AbilityText.fmt(7800.0)).is_equal("7,800")
	assert_str(AbilityText.fmt(1234567.4)).is_equal("1,234,567")
	assert_str(AbilityText.fmt(-1500.0)).is_equal("-1,500")
	assert_str(AbilityText.fmt(950.0)).is_equal("950")
	assert_str(AbilityText.secs(1.5)).is_equal("1.5 s")
	assert_str(AbilityText.secs(90.0)).is_equal("1 min 30 s")
	assert_str(AbilityText.secs(82.5)).is_equal("1 min 22.5 s")
	assert_str(AbilityText.secs(120.0)).is_equal("2 min")


func test_every_description_agrees_with_the_data() -> void:
	var stale: Array = []
	for id: String in Data.abilities:
		var ab: Dictionary = Data.abilities[id]
		var text: AbilityText = AbilityText.new(AbilityText.spec_stats(_owner_spec(ab)))
		if not text.description_matches(ab):
			stale.append("%s: '%s' vs %s" % [id, ab.get("description", ""), text.effects(ab)["numbers"]])
	assert_array(stale).is_empty()


func test_meta_and_effects_read_from_the_data() -> void:
	var text: AbilityText = AbilityText.new(AbilityText.spec_stats("arcanist_rime"))
	var ab: Dictionary = Data.abilities["rime_bolt"]
	var meta: PackedStringArray = text.meta(ab)
	assert_str(meta[0]).is_equal("%s cast" % AbilityText.secs(float(ab["cast_time_s"])))
	assert_str(" ".join(meta)).contains("40 m")
	var fx: PackedStringArray = text.effects(ab)["lines"]
	assert_str(fx[0]).contains(AbilityText.fmt(float(ab["effects"][0]["base"])))
	assert_str(" ".join(fx)).contains("Applies")


func test_talents_change_the_numbers_shown() -> void:
	var trees: Dictionary = Talents.trees_for("warblade_carnage", Data.specs, Data.classes, Data.talents)
	var lo: Dictionary = {"class": {}, "spec": {"lingering_gash": 2}, "pvp": []}
	var node: Dictionary = Talents.node_of(trees["spec"], "lingering_gash")
	if not node.get("requires_any", []).is_empty() and not Talents.node_of(trees["spec"], node["requires_any"][0]).is_empty():
		fail("lingering_gash no longer hangs off Ruin Strike; pick another talent for this test")
		return
	assert_str(Talents.check(lo, trees)).is_equal("")
	var r: Dictionary = Talents.resolve(lo, trees, Data.abilities, Data.auras)
	var plain: AbilityText = AbilityText.new(AbilityText.spec_stats("warblade_carnage"))
	var talented: AbilityText = AbilityText.new(AbilityText.spec_stats("warblade_carnage"), r["auras"])
	var ab: Dictionary = Data.abilities["ruin_strike"]
	var base: float = float(Data.auras["ruin_bleed"]["periodic"]["effect"]["base"])
	var better: float = float(r["auras"]["ruin_bleed"]["periodic"]["effect"]["base"])
	assert_float(better).is_greater(base)
	assert_str(plain.aura_line("ruin_bleed", ab)).contains(AbilityText.fmt(base))
	assert_str(talented.aura_line("ruin_bleed", ab)).contains(AbilityText.fmt(better))


func test_tooltip_lines_for_abilities_and_auras() -> void:
	var text: AbilityText = AbilityText.new(AbilityText.spec_stats("oracle_grace"))
	var lines: Array = Tooltip.ability_lines(text, Data.abilities["mending_light"])
	assert_str(str(lines[0][0])).is_equal(Data.abilities["mending_light"]["name"])
	assert_str(str(lines[0][2])).is_equal("title")
	var al: Array = Tooltip.aura_lines(text, "lingering_grace", 4.25, 1)
	assert_str(str(al[-1][0])).contains("left")


func test_talented_descriptions_show_the_build_s_numbers() -> void:
	var base_text: AbilityText = AbilityText.new(AbilityText.spec_stats("oracle_grace"))
	var ab: Dictionary = Data.abilities["mending_light"].duplicate(true)
	var before: float = base_text.effects(ab)["numbers"][0]
	ab["effects"][0]["base"] = float(ab["effects"][0]["base"]) + 1500.0
	var after: float = base_text.effects(ab)["numbers"][0]
	var desc: String = base_text.description_for(ab, Data.abilities["mending_light"], base_text)
	assert_str(desc).contains(AbilityText.fmt(after))
	assert_bool(AbilityText.fmt(before) in desc).is_false()
	# untouched abilities keep their text
	assert_str(base_text.description_for(Data.abilities["hush"], Data.abilities["hush"], base_text)).is_equal(Data.abilities["hush"]["description"])


func test_names_and_ellipsis() -> void:
	assert_str(TalentLoadouts.title_case("choir_of_dawn")).is_equal("Choir of Dawn")
	assert_str(TalentLoadouts.title_case("shatter_burst")).is_equal("Shatter Burst")
	var font: Font = ThemeDB.fallback_font
	var long: String = "Applies Lingering Grace (18 s, cannot be dispelled): healing every 3 s"
	var cut: String = Tooltip.elide(font, long, 120.0, 16)
	assert_str(cut).ends_with("…")
	assert_float(font.get_string_size(cut, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x).is_less_equal(120.0)
	assert_str(Tooltip.elide(font, "short", 400.0, 16)).is_equal("short")
