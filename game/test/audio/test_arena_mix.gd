extends GdUnitTestSuite
## Backlog X-04: the arena reverb and the warning duck. World sounds (self, allies, enemies) pass
## through the world bus, whose AudioEffectReverb takes the room sound of the view's map from
## data/acoustics; interface sounds and warnings bypass it (dry and on top); a compressor on the
## world bus keyed by the warning bus dips the world under the warnings; the bus layout's
## defaults match the data; the DESIGN.md buses behind the volume sliders are unchanged.


func after_test() -> void:
	# leave the shared bus state as a fresh director sets it (the default room)
	var a: AudioDirector = AudioDirector.new()
	a.free()


## Buses a sound on `bus` passes through, itself first, down to Master.
func _path(bus: String) -> Array[String]:
	var out: Array[String] = []
	var idx: int = AudioServer.get_bus_index(bus)
	while idx != -1:
		out.append(String(AudioServer.get_bus_name(idx)))
		if idx == 0:
			break
		idx = AudioServer.get_bus_index(AudioServer.get_bus_send(idx))
	return out


func _reverb() -> AudioEffectReverb:
	var bank: SoundBank = SoundBank.shared()
	var idx: int = AudioServer.get_bus_index(str(bank.map["buses"]["world"]))
	for i: int in AudioServer.get_bus_effect_count(idx):
		if AudioServer.get_bus_effect(idx, i) is AudioEffectReverb:
			return AudioServer.get_bus_effect(idx, i)
	return null


func _assert_reverb_is(p: Dictionary) -> void:
	var rv: AudioEffectReverb = _reverb()
	assert_object(rv).is_not_null()
	assert_float(rv.room_size).is_equal_approx(float(p["room_size"]), 0.001)
	assert_float(rv.damping).is_equal_approx(float(p["damping"]), 0.001)
	assert_float(rv.spread).is_equal_approx(float(p["spread"]), 0.001)
	assert_float(rv.hipass).is_equal_approx(float(p["hipass"]), 0.001)
	assert_float(rv.dry).is_equal_approx(float(p["dry"]), 0.001)
	assert_float(rv.wet).is_equal_approx(float(p["wet"]), 0.001)
	assert_float(rv.predelay_msec).is_equal_approx(float(p["predelay_ms"]), 0.01)
	assert_float(rv.predelay_feedback).is_equal_approx(float(p["predelay_feedback"]), 0.001)


func test_world_sounds_pass_the_reverb_bus_and_warnings_stay_dry() -> void:
	var b: Dictionary = SoundBank.shared().map["buses"]
	var world: String = str(b["world"])
	for side: String in ["self", "allies", "enemies"]:
		assert_array(_path(str(b[side]))).override_failure_message("%s does not reach %s" % [b[side], world]) \
			.contains([world])
	for dry: String in ["interface", "warning"]:
		assert_array(_path(str(b[dry]))).override_failure_message("%s passes the reverb" % b[dry]) \
			.not_contains([world])


func test_the_bus_layout_starts_with_the_default_room() -> void:
	# the .tres defaults match data/acoustics/default.json and the sound map's ducking, so the
	# editor shows what plays before any view arrives
	var layout: AudioBusLayout = load("res://default_bus_layout.tres")
	var idx: int = AudioServer.get_bus_index("Effects")
	var rv: Variant = layout.get("bus/%d/effect/0/effect" % idx)
	assert_bool(rv is AudioEffectReverb).is_true()
	var p: Dictionary = SoundBank.shared().acoustics["default"]["reverb"]
	assert_float((rv as AudioEffectReverb).wet).is_equal_approx(float(p["wet"]), 0.001)
	assert_float((rv as AudioEffectReverb).room_size).is_equal_approx(float(p["room_size"]), 0.001)
	assert_float((rv as AudioEffectReverb).hipass).is_equal_approx(float(p["hipass"]), 0.001)
	var comp: Variant = layout.get("bus/%d/effect/1/effect" % idx)
	assert_bool(comp is AudioEffectCompressor).is_true()
	assert_float((comp as AudioEffectCompressor).threshold) \
		.is_equal(float(SoundBank.shared().map["ducking"]["threshold_db"]))
	var a: AudioDirector = auto_free(AudioDirector.new())
	assert_str(a.acoustics_id).is_equal("")
	_assert_reverb_is(SoundBank.shared().acoustics["default"]["reverb"])


func test_the_reverb_takes_the_room_sound_of_the_views_map() -> void:
	var bank: SoundBank = SoundBank.shared()
	var a: AudioDirector = auto_free(AudioDirector.new())
	add_child(a)
	a.push_view({"tick": 1, "tick_rate": 60, "me": {}, "units": [], "map": "gallows_courtyard"})
	assert_str(a.acoustics_id).is_equal("gallows_courtyard")
	_assert_reverb_is(bank.acoustics["gallows_courtyard"]["reverb"])
	a.push_view({"tick": 2, "tick_rate": 60, "me": {}, "units": [], "map": "a_map_without_acoustics"})
	_assert_reverb_is(bank.acoustics["default"]["reverb"])
	# only one reverb on the bus however often the map changes
	var idx: int = AudioServer.get_bus_index(str(bank.map["buses"]["world"]))
	var reverbs: int = 0
	for i: int in AudioServer.get_bus_effect_count(idx):
		reverbs += int(AudioServer.get_bus_effect(idx, i) is AudioEffectReverb)
	assert_int(reverbs).is_equal(1)


func test_the_world_ducks_under_the_warnings_but_not_under_clicks() -> void:
	var bank: SoundBank = SoundBank.shared()
	var d: Dictionary = bank.map["ducking"]
	var a: AudioDirector = auto_free(AudioDirector.new())
	var c: AudioEffectCompressor = AudioDirector.bus_effect(str(d["bus"]), "AudioEffectCompressor")
	assert_str(String(c.sidechain)).is_equal(str(bank.map["buses"]["warning"]))
	assert_float(c.threshold).is_equal(float(d["threshold_db"]))
	assert_float(c.ratio).is_equal(float(d["ratio"]))
	# the threshold sits between the loudest interface sound and the quieter warning
	var loudest_ui: float = -INF
	var quietest_warning: float = INF
	for id: String in bank.sounds:
		var s: Dictionary = bank.sounds[id]
		if str(s["category"]) == "interface":
			loudest_ui = maxf(loudest_ui, float(s["peak_dbfs"]))
		elif str(s["category"]) == "warning":
			quietest_warning = minf(quietest_warning, float(s["peak_dbfs"]))
	assert_float(c.threshold).is_greater(loudest_ui)
	assert_float(c.threshold).is_less(quietest_warning)
	assert_object(a).is_not_null()


func test_the_volume_slider_buses_are_unchanged() -> void:
	# DESIGN.md: a volume slider per bus; X-04 adds effects, not buses
	for bus: String in ["Master", "Music", "Ambience", "Effects", "EffectsSelf", "EffectsAllies", "EffectsEnemies",
			"Interface", "Voice"]:
		assert_int(AudioServer.get_bus_index(bus)).override_failure_message("missing bus %s" % bus).is_not_equal(-1)
	assert_int(AudioServer.bus_count).is_equal(9)
