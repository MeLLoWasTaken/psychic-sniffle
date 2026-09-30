extends GdUnitTestSuite
## Ability icons and typography (backlog X-03): every ability and aura icon names a game-icons.net
## glyph that loads as a mipmapped texture, the shared frame and shade layers load, icons without
## an image fall back to the placeholder glyph, both HUD faces load from the layout's style.fonts
## (the display face as a weight of the variable font), the project's default font is set, and a
## button glows when its cooldown comes off.

var style: HudStyle


## The layers are drawn at 20-60 px from 128 px art: they must be imported with mipmaps (the
## headless renderer does not report mipmaps on the texture itself, so read the import settings).
static func _mipmapped(tex: Texture2D) -> bool:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(tex.resource_path + ".import") != OK:
		return false
	return bool(cfg.get_value("params", "mipmaps/generate", false))


func before_test() -> void:
	style = HudStyle.new(Data.hud_layouts["default"])


func test_every_ability_and_aura_icon_loads_its_glyph() -> void:
	var count: int = 0
	var images: Dictionary = {}
	for kind: Dictionary in [Data.abilities, Data.auras]:
		for id: String in kind:
			var icon: Dictionary = kind[id].get("icon", {})
			assert_str(str(icon.get("image", ""))).override_failure_message("%s has no icon image" % id).is_not_empty()
			var tex: Texture2D = style.icon_texture(icon)
			assert_object(tex).override_failure_message("%s: glyph %s did not load" % [id, icon.get("image")]).is_not_null()
			if tex != null:
				assert_int(tex.get_width()).is_equal(128)
				assert_bool(_mipmapped(tex)).override_failure_message("%s: not imported with mipmaps" % id).is_true()
			images[icon.get("image")] = true
			count += 1
	assert_int(count).is_greater(60)
	assert_int(images.size()).is_greater(40)


func test_frame_and_shade_layers_load() -> void:
	for key: String in ["frame", "shade"]:
		var tex: Texture2D = style.icon_layer(str(style.icon_art[key]))
		assert_object(tex).override_failure_message("%s layer missing" % key).is_not_null()
		assert_bool(_mipmapped(tex)).is_true()


func test_icons_in_one_bar_use_different_glyphs() -> void:
	# at action-bar size the glyph carries the meaning: no two abilities of a spec share one
	for spec_id: String in Data.specs:
		var seen: Dictionary = {}
		for aid: String in Data.specs[spec_id]["abilities"]:
			var img: String = str(Data.abilities[aid]["icon"].get("image", ""))
			assert_bool(seen.has(img)).override_failure_message("%s: %s and %s share %s" % [spec_id, aid, seen.get(img, ""), img]).is_false()
			seen[img] = aid


func test_an_icon_without_an_image_falls_back_to_the_placeholder() -> void:
	assert_object(style.icon_texture({"symbol": "ice_bolt", "school": "frost"})).is_null()
	assert_object(style.icon_texture({"symbol": "ice_bolt", "image": "nobody/missing-glyph"})).is_null()
	assert_str(style.glyph_for("ice_bolt")).is_equal("crystal")
	# drawing either kind of icon works on a live canvas item
	var c: Control = auto_free(Control.new())
	add_child(c)
	c.draw.connect(func() -> void:
		style.icon(c, Rect2(0, 0, 50, 50), {"symbol": "ice_bolt", "school": "frost"}, "Rime Bolt")
		style.icon(c, Rect2(60, 0, 50, 50), Data.abilities["rime_bolt"]["icon"], "Rime Bolt"))
	c.queue_redraw()
	await await_idle_frame()


func test_fonts_load_from_the_layout() -> void:
	var fonts: Dictionary = Data.hud_layouts["default"]["style"]["fonts"]
	assert_object(style.font).is_not_same(ThemeDB.fallback_font)
	assert_str(style.font.get_font_name()).starts_with("Fira Sans")
	assert_str(str(fonts["text"]["file"])).contains("firasans")
	assert_object(style.display_font).is_instanceof(FontVariation)
	var dv: FontVariation = style.display_font
	assert_str(dv.base_font.get_font_name()).starts_with("Cinzel")
	assert_int(int(dv.variation_opentype.values()[0])).is_equal(int(fonts["display"]["weight"]))
	assert_object(style.face(&"display")).is_same(style.display_font)
	assert_object(style.face(&"text")).is_same(style.font)
	# both faces have the digits and signs the HUD prints
	for f: Font in [style.font, style.display_font]:
		for ch: String in "0123456789:.%-+k…":
			assert_bool(f.has_char(ch.unicode_at(0))).override_failure_message("%s lacks %s" % [f.get_font_name(), ch]).is_true()
	# a missing entry falls back to the engine font instead of failing
	assert_object(HudStyle.load_font({})).is_same(ThemeDB.fallback_font)


func test_the_project_default_font_is_the_text_face_family() -> void:
	var path: String = str(ProjectSettings.get_setting("gui/theme/custom_font", ""))
	assert_str(path).starts_with("res://assets/fonts/firasans/")
	var f: Font = load(path)
	assert_str(f.get_font_name()).starts_with("Fira Sans")


func test_text_sizes_keep_the_minimum_rule() -> void:
	# the fonts change the faces, not the sizes: the smallest size still drives min_text_px
	assert_float(style.smallest_font()).is_equal(14.0)
	assert_float(style.text_width("Swift Benediction", style.fs("small"))).is_greater(0.0)
	assert_float(style.text_width("Carnage Warblade", style.fs("normal"), &"display")).is_greater(0.0)


func test_a_button_glows_when_its_cooldown_comes_off() -> void:
	Keybinds.load_profile("default")
	var ctl: PlayerController = PlayerController.new(Data.settings["default"])
	var hud: Hud = auto_free(Hud.new(Data.settings["default"]))
	add_child(hud)
	hud.bind(ctl)
	var m: LocalMatch = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"])
	var v: Dictionary = m.view().duplicate(true)
	var t0: int = 600
	v["tick"] = t0
	v["cooldowns"] = {"pommel_crack": t0 + 120}
	hud.push(v)
	hud.update(0.0)
	var bar: ActionBar = null
	var slot: int = -1
	for b: ActionBar in hud.bars.values():
		for i: int in b.slots.size():
			if b.slots[i]["ability"] == "pommel_crack":
				bar = b
				slot = i
	assert_int(slot).is_not_equal(-1)
	assert_float(bar.ready_glow(slot)).is_equal(0.0)
	var v2: Dictionary = v.duplicate(true)
	v2["tick"] = t0 + 121
	hud.push(v2)
	hud.update(0.0)
	assert_float(bar.ready_glow(slot)).is_greater(0.0)  # just came off cooldown
	hud.update(0.3)
	assert_float(bar.ready_glow(slot)).is_greater(0.0)
	hud.update(1.0)
	assert_float(bar.ready_glow(slot)).is_equal(0.0)  # faded
