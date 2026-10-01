extends GdUnitTestSuite
## Settings suite (backlog M2-13): profiles over the data profile, instant application to the
## engine and to running systems, the per-player rules (spell queue window, auto self-cast), the
## settings screen and event text.

const PATH: String = "user://test_settings.json"


func before_test() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	Settings.load_user("default", PATH)


func after_test() -> void:
	Settings.use_data()
	Settings.apply_all()
	Engine.max_fps = 0
	for bus: String in Settings.AUDIO_BUSES.values():
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index(bus), 0.0)


func test_changes_sit_over_the_data_profile_and_save_per_profile() -> void:
	assert_float(float(Settings.get_value("interface.ui_scale"))).is_equal(float(Data.settings["default"]["interface"]["ui_scale"]))
	Settings.set_value("interface.ui_scale", 1.25)
	Settings.set_value("mouse.invert_y", true)
	assert_bool(Settings.save()).is_true()
	var again: Dictionary = Settings.load_user("default", PATH)
	assert_float(float(again["interface"]["ui_scale"])).is_equal(1.25)
	assert_bool(bool(Settings.get_value("mouse.invert_y"))).is_true()
	# a second profile starts as a copy and keeps its own changes
	Settings.use_profile("Arena")
	Settings.set_value("interface.ui_scale", 0.9)
	Settings.use_profile("Default")
	assert_float(float(Settings.get_value("interface.ui_scale"))).is_equal(1.25)
	Settings.use_profile("Arena")
	assert_float(float(Settings.get_value("interface.ui_scale"))).is_equal(0.9)
	Settings.delete_profile("Arena")
	assert_array(Settings.profile_names()).is_equal(["Default"])
	Settings.reset()
	assert_float(float(Settings.get_value("interface.ui_scale"))).is_equal(float(Data.settings["default"]["interface"]["ui_scale"]))
	assert_float(float(Data.settings["default"]["interface"]["ui_scale"])).is_equal(1.0)  # the data stays as it was


func test_quality_presets_set_their_graphics_and_a_change_makes_them_custom() -> void:
	Settings.set_value("graphics.preset", "low")
	assert_str(str(Settings.get_value("graphics.shadows"))).is_equal("off")
	assert_bool(bool(Settings.get_value("graphics.ssao"))).is_false()
	assert_str(str(Settings.get_value("graphics.preset"))).is_equal("low")
	Settings.set_value("graphics.shadows", "high")
	assert_str(str(Settings.get_value("graphics.preset"))).is_equal("custom")


func test_engine_settings_apply_at_once_and_resolution_waits() -> void:
	Settings.set_value("graphics.max_fps", 60)
	assert_int(Engine.max_fps).is_equal(60)
	Settings.set_value("audio.effects_db", -12.0)
	assert_float(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Effects"))).is_equal_approx(-12.0, 0.01)
	Settings.restart_needed = false
	Settings.set_value("graphics.resolution", [1280, 720])
	assert_bool(Settings.restart_needed).is_true()


func test_the_hud_follows_interface_and_accessibility_settings() -> void:
	var hud: Hud = auto_free(Hud.new(Settings.values))
	add_child(hud)
	var m: LocalMatch = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"])
	hud.push(m.view())
	hud.root.size = Vector2(1920, 1080)
	hud.stretch_override = 1.0
	hud.relayout()
	var before: float = hud.scale_used
	Settings.set_value("interface.ui_scale", 1.3)
	assert_float(hud.scale_used).is_greater(before)
	Settings.set_value("interface.combat_text", false)
	assert_bool((hud.elements["combat_text"] as CombatText).visible).is_false()
	Settings.set_value("interface.aura_scale", 1.4)
	assert_float(((hud.elements["player_frame"] as Array)[0] as UnitFrame).aura_scale).is_equal(1.4)
	var friendly: Color = hud.style.color("friendly_name")
	Settings.set_value("accessibility.colorblind", "deuteranopia")
	assert_bool(hud.style.color("friendly_name") != friendly).is_true()
	assert_bool(Settings.team_colors()["ally"] != Color(0.2, 0.95, 0.3)).is_true()
	Settings.set_value("accessibility.event_text", true)
	assert_bool(hud.event_text.visible).is_true()
	var v: Dictionary = m.view()
	hud.push(v, [{"type": "gates_open", "tick": 1}])
	assert_int(hud.event_text.lines.size()).is_equal(1)


func test_controller_camera_and_effects_follow_their_settings() -> void:
	var ctl: PlayerController = PlayerController.new(Settings.values)
	Settings.set_value("mouse.sensitivity_deg_per_px", 0.6)
	assert_float(ctl.sensitivity).is_equal_approx(deg_to_rad(0.6), 1e-6)
	Settings.set_value("targeting.tab_range_m", 25)
	assert_float(ctl.targeting.tab_range).is_equal(25.0)
	var cam: ThirdPersonCamera = auto_free(ThirdPersonCamera.new(Settings.get_value("camera", {})))
	Settings.set_value("camera.fov_deg", 90)
	assert_float(cam.camera.fov).is_equal(90.0)
	var fx: EffectsDirector = auto_free(EffectsDirector.new(null))
	fx.my_id = 1
	var vfx: Vfx = auto_free(Vfx.new())
	vfx.source = 2
	var p: GPUParticles3D = GPUParticles3D.new()
	p.amount = 40
	vfx.add_emitter(p)
	Settings.set_value("graphics.particle_density", 0.5)
	Settings.set_value("graphics.others_effect_opacity", 0.4)
	fx._apply_settings(vfx)
	assert_int(vfx.amount).is_equal(20)
	assert_float(vfx.opacity).is_equal_approx(0.4, 1e-6)


func test_the_map_lighting_follows_graphics_settings() -> void:
	var b: MapBuilder = auto_free(MapBuilder.new())
	b.map_id = "gallows_courtyard"
	b.use_kit = false
	b.bake_gi = false
	b.build()
	assert_object(b.environment).is_not_null()
	Settings.set_value("graphics.glow", false)
	Settings.set_value("graphics.shadows", "off")
	b.apply_graphics()
	assert_bool(b.environment.glow_enabled).is_false()
	for n: Node in b.get_children():
		if n is DirectionalLight3D:
			assert_bool((n as DirectionalLight3D).shadow_enabled).is_false()


func test_the_spell_queue_window_and_auto_self_cast_are_each_players_own() -> void:
	var runner: MatchRunner = MatchRunner.new(Data.maps["gallows_courtyard"], "arena", "2v2", 0.0, 5)
	runner.record()
	var healer: Unit = runner.add_unit("oracle_grace", 0, "", {"spell_queue_ms": 0, "auto_self_cast": false})
	var foe: Unit = runner.add_unit("warblade_carnage", 1)
	runner.sim.add_system(runner.system_combat_and_rules)
	runner.sim.step()
	assert_int(healer.queue_window_ticks).is_equal(0)
	assert_bool(healer.auto_self_cast).is_false()
	# an ally heal with an enemy target goes nowhere when auto self-cast is off
	runner.combat.events.clear()
	runner.combat.press(healer, "swift_benediction", foe.id)
	var failed: Array = runner.combat.events.filter(func(e: Dictionary) -> bool: return e["type"] == "cast_failed")
	assert_int(failed.size()).is_equal(1)
	runner.set_prefs(healer, {"auto_self_cast": true, "spell_queue_ms": 200})
	assert_bool(healer.auto_self_cast).is_true()
	assert_int(healer.queue_window_ticks).is_equal(12)
	runner.input_log.finish(runner.sim)
	assert_bool(Replay.run(runner.input_log)["ok"]).is_true()
	var d: Dictionary = Protocol.decode(Protocol.prefs({"spell_queue_ms": 150, "auto_self_cast": false}))
	assert_int(int(d["prefs"]["spell_queue_ms"])).is_equal(150)
	assert_bool(bool(d["prefs"]["auto_self_cast"])).is_false()
	var h: Dictionary = Protocol.decode(Protocol.hello("p", "oracle_grace", "", {"spell_queue_ms": 300, "auto_self_cast": true}))
	assert_int(int(h["prefs"]["spell_queue_ms"])).is_equal(300)


func test_the_settings_screen_edits_every_page() -> void:
	var s: SettingsScreen = auto_free(SettingsScreen.new())
	add_child(s)  # sliders announce value changes inside the tree
	s.size = Vector2(1920, 1080)
	var pages: Array = s.pages.map(func(p: Dictionary) -> String: return p["id"])
	assert_array(pages).contains_exactly(["interface", "gameplay", "graphics", "audio", "accessibility", "keys"])
	for id: String in pages:
		s.show_page(id)
		for rc: Dictionary in s.row_controls:
			assert_float((rc["rect"] as Rect2).end.y).override_failure_message("%s: a row runs into the buttons" % id).is_less(1080.0 - 110.0)
	s.show_page("gameplay")
	for rc: Dictionary in s.row_controls:
		var row: Dictionary = rc["row"]
		if row.get("path", "") == "gameplay.spell_queue_ms":
			(rc["control"] as HSlider).value = 125.0
		elif row.get("path", "") == "gameplay.auto_self_cast":
			(rc["control"] as Button).button_pressed = false
	assert_int(int(Settings.get_value("gameplay.spell_queue_ms"))).is_equal(125)
	assert_bool(bool(Settings.get_value("gameplay.auto_self_cast"))).is_false()
	s.show_page("accessibility")
	for rc: Dictionary in s.row_controls:
		if rc["row"].get("path", "") == "accessibility.colorblind":
			s.cycle(rc["row"])
	assert_str(str(Settings.get_value("accessibility.colorblind"))).is_equal("protanopia")
	s.show_page("gameplay")
	s.press("reset_page")
	assert_int(int(Settings.get_value("gameplay.spell_queue_ms"))).is_equal(int(Data.settings["default"]["gameplay"]["spell_queue_ms"]))
	assert_str(str(Settings.get_value("accessibility.colorblind"))).is_equal("protanopia")  # another page
	s.press("new")
	assert_int(Settings.profile_names().size()).is_equal(2)
	s.press("delete")
	assert_int(Settings.profile_names().size()).is_equal(1)


func test_event_text_lines() -> void:
	var view: Dictionary = {"me": {"id": 1, "team": 0}, "units": [{"id": 1, "team": 0, "spec": "oracle_grace"},
		{"id": 2, "team": 0, "spec": "warblade_carnage"}, {"id": 3, "team": 1, "spec": "arcanist_rime"}]}
	assert_str(EventText.line_for({"type": "aura_applied", "target": 1, "source": 3, "cc": "stun", "aura": "pommel_cracked"}, view)).contains("You are stun")
	assert_str(EventText.line_for({"type": "aura_applied", "target": 2, "source": 3, "cc": "root", "aura": "rimebound"}, view)).contains("partner")
	assert_str(EventText.line_for({"type": "cast_start", "target": 1, "source": 3, "ability": "rime_bolt"}, view)).contains("Rime Bolt at you")
	assert_str(EventText.line_for({"type": "aura_applied", "target": 3, "source": 1, "cc": "disorient", "aura": "psalm_dread"}, view)).is_empty()


func test_the_pause_menu_opens_settings_over_the_match() -> void:
	var pm: PauseMenu = auto_free(PauseMenu.new(MenuStyle.new("main"), "Leave"))
	add_child(pm)
	var s: SettingsScreen = pm.open_settings()
	assert_object(pm.settings_layer).is_not_null()
	assert_int(pm.settings_layer.layer).is_greater(10)  # above the HUD
	s.press("done")
	await await_idle_frame()
	assert_object(pm.settings_layer).is_null()
