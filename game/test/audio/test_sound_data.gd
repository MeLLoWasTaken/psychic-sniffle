extends GdUnitTestSuite
## Backlog M1-26: every ability of the three kits has sounds, every sound the map names loads,
## weapons and armor resolve, and after bus gains nothing is louder than the CC warning.

const SPECS: Array[String] = ["warblade_carnage", "arcanist_rime", "oracle_grace"]


func _kit(spec_id: String) -> Array:
	var s: Dictionary = Data.specs[spec_id]
	return s["abilities"] + Data.classes[s["class"]].get("shared_abilities", [])


func test_every_ability_of_the_three_kits_has_playable_sounds() -> void:
	var bank: SoundBank = SoundBank.shared()
	for spec_id: String in SPECS:
		for ab: String in _kit(spec_id):
			assert_bool(bank.map["abilities"].has(ab)).override_failure_message("no sound entry for %s" % ab).is_true()
			var a: Dictionary = Data.abilities[ab]
			var entry: Dictionary = bank.ability_entry(ab)
			assert_bool(entry.is_empty()).override_failure_message("%s has no sounds" % ab).is_false()
			if a["cast_type"] in ["cast", "channel"]:
				assert_bool(entry.has("cast_start") and entry.has("cast_loop")).override_failure_message(
					"%s needs cast start and loop" % ab).is_true()
				var loop: AudioStream = bank.stream(str(entry["cast_loop"]))
				assert_bool(loop is AudioStreamOggVorbis and (loop as AudioStreamOggVorbis).loop).override_failure_message(
					"%s cast loop must loop" % ab).is_true()
			assert_bool(entry.has("release") or entry.has("impact")).is_true()
			for stage: String in ["cast_start", "release", "impact"]:
				for ref: Variant in bank.stage_refs(ab, stage):
					for target_spec: String in SPECS:  # weapon hits depend on the target's armor
						var id: String = bank.resolve(str(ref), spec_id, target_spec)
						assert_str(id).override_failure_message("%s %s %s -> nothing" % [ab, stage, ref]).is_not_empty()
						assert_object(bank.stream(id)).override_failure_message("%s: no stream %s" % [ab, id]).is_not_null()


func test_every_sound_loads_and_only_loops_loop() -> void:
	var bank: SoundBank = SoundBank.shared()
	assert_int(bank.sounds.size()).is_greater(60)
	for id: String in bank.sounds:
		var s: AudioStream = bank.stream(id)
		assert_object(s).override_failure_message("cannot load %s" % id).is_not_null()
		var loops: bool = bool(bank.sounds[id].get("loops", false))
		if s is AudioStreamOggVorbis:
			assert_bool((s as AudioStreamOggVorbis).loop).override_failure_message("%s loop flag" % id).is_equal(loops)
		if not loops:
			assert_float(bank.length(id)).is_between(0.03, 4.0)


func test_weapons_and_armor_resolve() -> void:
	var bank: SoundBank = SoundBank.shared()
	assert_str(bank.resolve("@weapon_swing", "warblade_carnage")).is_equal("swing_greatsword")
	assert_str(bank.resolve("@weapon_swing", "oracle_grace")).is_equal("swing_mace")
	assert_str(bank.resolve("@weapon_swing", "arcanist_rime")).is_equal("swing_staff")
	assert_str(bank.resolve("@weapon_hit", "warblade_carnage", "oracle_grace")).is_equal("hit_greatsword_cloth")
	assert_str(bank.resolve("@weapon_hit", "oracle_grace", "warblade_carnage")).is_equal("hit_mace_plate")
	assert_str(bank.resolve("@weapon_hit", "arcanist_rime", "warblade_carnage")).is_equal("hit_staff_plate")
	assert_str(bank.resolve("@weapon_hit", "arcanist_rime", "arcanist_rime")).is_equal("hit_staff_cloth")
	assert_str(bank.footsteps("warblade_carnage")["step"]).is_equal("footstep_plate")
	assert_str(bank.footsteps("oracle_grace")["step"]).is_equal("footstep_cloth")
	# wading (M2-09): the surface's sounds replace the armor's, the stride stays the armor's
	var wet: Dictionary = bank.footsteps("warblade_carnage", "water")
	assert_str(str(wet["step"])).is_equal("footstep_wade")
	assert_str(str(wet["land"])).is_equal("land_wade")
	assert_float(float(wet["step_m"])).is_equal(float(bank.footsteps("warblade_carnage")["step_m"]))
	assert_str(str(bank.footsteps("oracle_grace", "lava")["step"])).is_equal("footstep_cloth")
	# plate footsteps are the heavier, louder ones
	assert_float(float(bank.sounds["footstep_plate"]["peak_dbfs"])).is_greater(float(bank.sounds["footstep_cloth"]["peak_dbfs"]))


## Gain of a bus and every bus it sends to, in dB.
func _chain_db(bus: String) -> float:
	var db: float = 0.0
	var idx: int = AudioServer.get_bus_index(bus)
	while idx != -1:
		db += AudioServer.get_bus_volume_db(idx)
		var send: StringName = AudioServer.get_bus_send(idx)
		idx = AudioServer.get_bus_index(send) if send != &"" and idx != 0 else -1
	return db


func test_nothing_is_louder_than_the_cc_warning_after_buses_and_attenuation() -> void:
	# DESIGN.md quality bar: no sound louder than the crowd-control warning. The file levels are
	# checked by tests/test_audio.py; here the peak each sound can reach in game: file peak +
	# playback volume + its loudest possible bus chain (3D sounds never exceed max_db <= 0 dB).
	var bank: SoundBank = SoundBank.shared()
	var buses: Dictionary = bank.map["buses"]
	var warn_id: String = bank.map["cc_warning"]["sound"]
	var warn: float = float(bank.sounds[warn_id]["peak_dbfs"]) + float(bank.playback(warn_id)["volume_db"]) \
		+ _chain_db(str(buses["warning"]))
	for id: String in bank.sounds:
		if id == warn_id:
			continue
		var pb: Dictionary = bank.playback(id)
		var chains: Array = [buses["self"], buses["allies"], buses["enemies"]] if bool(pb["positional"]) \
			else [buses["interface"], buses["warning"]]
		var top: float = -INF
		for bus: Variant in chains:
			top = maxf(top, _chain_db(str(bus)))
		var level: float = float(bank.sounds[id]["peak_dbfs"]) + float(pb["volume_db"]) + top
		if bool(pb["positional"]):
			level += minf(0.0, float((pb["attenuation"] as Dictionary).get("max_db", 0.0)))
		assert_float(level).override_failure_message("%s reaches %.1f dB, the CC warning %.1f dB" % [id, level, warn]).is_less(warn)
