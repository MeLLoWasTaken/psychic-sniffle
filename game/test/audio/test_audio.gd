extends GdUnitTestSuite
## M0-16: audio buses from docs/DESIGN.md exist and route correctly; generated sounds load and
## play on their bus.

const REQUIRED_BUSES: Dictionary = {
	"Master": "",
	"Music": "Master",
	"Ambience": "Master",
	"Effects": "Master",
	"EffectsSelf": "Effects",
	"EffectsAllies": "Effects",
	"EffectsEnemies": "Effects",
	"Interface": "Master",
	"Voice": "Master",
}
const SOUNDS: Array[String] = [
	"res://assets/audio/sfx/impact_slash_01.ogg",
	"res://assets/audio/sfx/frost_cast_loop.ogg",
	"res://assets/audio/sfx/holy_heal.ogg",
]


func test_required_buses_exist_and_route() -> void:
	for bus: String in REQUIRED_BUSES:
		var idx: int = AudioServer.get_bus_index(bus)
		assert_int(idx).override_failure_message("missing bus %s" % bus).is_not_equal(-1)
		if bus != "Master":
			assert_str(String(AudioServer.get_bus_send(idx))).is_equal(REQUIRED_BUSES[bus])


func test_sounds_load() -> void:
	for path: String in SOUNDS:
		var stream: AudioStream = load(path)
		assert_object(stream).override_failure_message("cannot load %s" % path).is_not_null()
		assert_bool(stream is AudioStreamOggVorbis).is_true()
		assert_float(stream.get_length()).is_greater(0.3)


func test_sound_plays_on_enemy_effects_bus() -> void:
	var player: AudioStreamPlayer = auto_free(AudioStreamPlayer.new())
	player.stream = load(SOUNDS[0])
	player.bus = &"EffectsEnemies"
	add_child(player)
	player.play()
	await get_tree().process_frame
	assert_bool(player.playing).is_true()
	assert_str(String(player.bus)).is_equal("EffectsEnemies")


func test_frost_cast_loop_is_marked_looping_on_import() -> void:
	var stream: AudioStreamOggVorbis = load(SOUNDS[1])
	assert_bool(stream.loop).override_failure_message("frost_cast_loop must loop").is_true()


func test_every_mapped_weapon_hit_is_a_playable_randomizer() -> void:
	# weapon sounds moved from tuning.json to data/sound_map (M1-26)
	var bank: SoundBank = SoundBank.shared()
	for key: String in bank.map["weapons"]:
		for armor: String in bank.map["weapons"][key]["hit"]:
			var sound: String = bank.map["weapons"][key]["hit"][armor]
			var r: AudioStreamRandomizer = load(bank.stream_path(sound))
			assert_object(r).override_failure_message("no randomizer for %s" % sound).is_not_null()
			assert_int(r.streams_count).is_equal(int(bank.sounds[sound]["variants"]))
