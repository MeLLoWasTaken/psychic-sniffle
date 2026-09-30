extends GdUnitTestSuite
## Backlog M1-26: sound in the practice scene. A 30 s bot-played 3v3 fight plays sounds from the
## event stream on every effects bus, the voice cap holds (also with a tiny cap that forces voice
## stealing), and the CC warning plays exactly once per crowd-control application on the player.


func _run(seconds: float, cap: int = -1) -> Dictionary:
	var errors_before: int = Log.error_count
	var scene: Node3D = auto_free((load("res://scenes/game/practice.tscn") as PackedScene).instantiate())
	scene.options = {"manual": true, "kit": false, "gi": false, "lighting": false, "player_bot": true,
		"spec": "arcanist_rime", "ally": "warblade_carnage,oracle_grace", "enemies": "warblade_carnage,arcanist_rime,oracle_grace"}
	add_child(scene)
	var audio: AudioDirector = scene.renderer.audio
	if cap > 0:
		audio.max_voices = cap
	var cats: Array = audio.bank.map["cc_warning"]["categories"]
	var applied_ticks: Dictionary = {}  ## simulation ticks at which crowd control landed on the player
	var max_seen: int = 0
	for i: int in roundi(seconds * scene.world.tick_rate()):
		scene.run_ticks(1)
		max_seen = maxi(max_seen, audio.voice_count())
		for a: Dictionary in scene.world.view()["me"]["auras"]:
			if str(Data.auras[str(a["id"])]["cc_category"]) in cats:
				applied_ticks[int(a["applied_tick"])] = true
	return {"audio": audio, "applications": applied_ticks.size(), "max_seen": max_seen,
		"errors": Log.error_count - errors_before}


func test_thirty_second_fight_plays_sounds_within_the_voice_cap() -> void:
	var r: Dictionary = _run(30.0)
	var audio: AudioDirector = r["audio"]
	assert_int(int(r["errors"])).is_equal(0)
	assert_int(audio.peak_voices).is_less_equal(64)
	assert_int(int(r["max_seen"])).is_less_equal(64)
	assert_int(audio.played).is_greater(100)
	var buses: Dictionary = {}
	var cats: Dictionary = {}
	for h: Dictionary in audio.history:
		buses[h["bus"]] = true
		cats[h["category"]] = true
		if h["category"] in ["interface", "warning"]:
			assert_bool(bool(h["positional"])).is_false()
		else:
			assert_bool(bool(h["positional"])).override_failure_message("%s should be 3D" % h["id"]).is_true()
	for bus: String in ["EffectsSelf", "EffectsAllies", "EffectsEnemies"]:
		assert_bool(buses.has(bus)).override_failure_message("nothing on %s; buses %s" % [bus, buses.keys()]).is_true()
	for cat: String in ["footstep", "swing", "impact", "release", "cast"]:
		assert_bool(cats.has(cat)).override_failure_message("no %s sound; seen %s" % [cat, cats.keys()]).is_true()
	# once per crowd-control application on the player, counted independently from the view
	assert_int(int(r["applications"])).override_failure_message("the fight never crowd-controlled the player").is_greater(0)
	assert_int(audio.cc_warnings).is_equal(int(r["applications"]))
	assert_int(audio.count_of("cc_warning")).is_equal(int(r["applications"]))


func test_tiny_voice_cap_steals_voices_and_holds() -> void:
	var r: Dictionary = _run(12.0, 6)
	var audio: AudioDirector = r["audio"]
	assert_int(int(r["errors"])).is_equal(0)
	assert_int(audio.peak_voices).is_less_equal(6)
	assert_int(audio.stolen + audio.dropped).is_greater(0)
	# enemy crowd control and burst were never dropped, even with 6 voices
	assert_int(audio.dropped_critical()).is_equal(0)
	assert_int(audio.critical_played).is_greater(0)
