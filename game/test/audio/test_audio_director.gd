extends GdUnitTestSuite
## Backlog M1-26: AudioDirector turns views and combat events into the right sounds on the right
## buses; world sounds are 3D and interface sounds and warnings 2D; the CC warning plays once per
## crowd-control application on the local player; footsteps follow speed; the voice cap holds and
## enemy crowd control is never dropped.

const ME: int = 1  ## warblade (plate, greatsword), team 0
const ALLY: int = 2  ## oracle (cloth, mace), team 0
const FOE: int = 3  ## arcanist (cloth, staff), team 1
const FOE2: int = 4  ## oracle, team 1

var _tick: int = 0


func _unit(id: int, spec: String, team: int, pos: Vector3, cast: Dictionary = {}, auras: Array = []) -> Dictionary:
	return {"id": id, "team": team, "spec": spec, "position": pos, "facing": 0.0, "health": 50000,
		"max_health": 50000, "target_id": -1, "cast": cast, "auras": auras}


func _units() -> Array:
	return [_unit(ME, "warblade_carnage", 0, Vector3(0, 0, 0)), _unit(ALLY, "oracle_grace", 0, Vector3(3, 0, 0)),
		_unit(FOE, "arcanist_rime", 1, Vector3(0, 0, -10)), _unit(FOE2, "oracle_grace", 1, Vector3(4, 0, -12))]


func _view(units: Array) -> Dictionary:
	_tick += 1
	var me: Dictionary = {}
	for u: Dictionary in units:
		if int(u["id"]) == ME:
			me = u
	return {"tick": _tick, "tick_rate": 60, "me": me, "units": units}


func _director() -> AudioDirector:
	_tick = 0
	var a: AudioDirector = auto_free(AudioDirector.new())
	add_child(a)
	a.listener_position = Vector3.ZERO
	a.push_view(_view(_units()))
	return a


func _ev(type: String, src: int, tgt: int, extra: Dictionary = {}) -> Dictionary:
	var e: Dictionary = {"type": type, "source": src, "target": tgt, "tick": _tick}
	e.merge(extra)
	return e


## History entries of one sound id.
func _plays(a: AudioDirector, id: String) -> Array:
	return a.history.filter(func(h: Dictionary) -> bool: return h["id"] == id)


func test_enemy_cast_plays_start_loop_release_and_one_impact() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("cast_start", FOE, ME, {"ability": "rime_bolt"})])
	assert_int(_plays(a, "frost_cast_start").size()).is_equal(1)
	var loop: Dictionary = a.units[FOE]["loop"]
	assert_str(str(loop.get("id", ""))).is_equal("frost_cast_loop")
	assert_str(String((loop["player"] as AudioStreamPlayer3D).bus)).is_equal("EffectsEnemies")
	assert_bool((loop["player"] as AudioStreamPlayer3D).playing).is_true()
	# still casting in the next views: the loop keeps playing
	var casting: Array = _units()
	casting[2]["cast"] = {"ability": "rime_bolt"}
	for i: int in 30:
		a.push_view(_view(casting))
	assert_bool((a.units[FOE]["loop"] as Dictionary).is_empty()).is_false()
	# the bolt goes off: loop fades, release at the caster, impact at me once (damage and slow)
	a.push_view(_view(_units()))
	a.push_events([_ev("cast_success", FOE, ME, {"ability": "rime_bolt"}),
		_ev("damage", FOE, ME, {"ability": "rime_bolt", "amount": 3000}),
		_ev("aura_applied", FOE, ME, {"aura": "chilled", "cc": "none"})])
	assert_bool((a.units[FOE]["loop"] as Dictionary).is_empty()).is_true()
	var rel: Array = _plays(a, "rime_bolt_release")
	assert_int(rel.size()).is_equal(1)
	assert_int(int(rel[0]["unit"])).is_equal(FOE)
	var imp: Array = _plays(a, "rime_bolt_impact")
	assert_int(imp.size()).is_equal(1)
	assert_int(int(imp[0]["unit"])).is_equal(ME)
	assert_str(str(imp[0]["bus"])).is_equal("EffectsEnemies")
	assert_bool(bool(imp[0]["positional"])).is_true()
	# the faded loop's voice is released a moment later
	for i: int in 12:
		a.push_view(_view(_units()))
	for v: Dictionary in a.voices:
		assert_str(str(v["id"])).is_not_equal("frost_cast_loop")


func test_interrupted_cast_stops_the_loop_without_release() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("cast_start", ALLY, ME, {"ability": "mending_light"})])
	assert_str(str((a.units[ALLY]["loop"] as Dictionary).get("id", ""))).is_equal("holy_cast_loop")
	a.push_events([_ev("cast_interrupted", ALLY, -1, {"ability": "mending_light", "reason": "moved"})])
	assert_bool((a.units[ALLY]["loop"] as Dictionary).is_empty()).is_true()
	assert_int(_plays(a, "heal_release").size()).is_equal(0)
	assert_str(str(_plays(a, "holy_cast_start")[0]["bus"])).is_equal("EffectsAllies")


func test_channel_loop_and_ticking_impacts() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("cast_start", FOE, ME, {"ability": "hailstorm"})])
	assert_str(str((a.units[FOE]["loop"] as Dictionary).get("id", ""))).is_equal("frost_channel_loop")
	var casting: Array = _units()
	casting[2]["cast"] = {"ability": "hailstorm", "channel": true}
	for i: int in 3:  # three channel ticks, each a new impact
		for k: int in 20:
			a.push_view(_view(casting))
		a.push_events([_ev("damage", FOE, ME, {"ability": "hailstorm", "amount": 500})])
	assert_int(_plays(a, "hail_impact").size()).is_equal(3)
	a.push_events([_ev("channel_end", FOE, -1, {"ability": "hailstorm"})])
	assert_bool((a.units[FOE]["loop"] as Dictionary).is_empty()).is_true()


func test_weapon_swings_and_hits_follow_weapon_and_armor() -> void:
	var a: AudioDirector = _director()
	var cases: Array = [
		[ME, FOE, "swing_greatsword", "hit_greatsword_cloth", "EffectsSelf"],
		[FOE2, ME, "swing_mace", "hit_mace_plate", "EffectsEnemies"],
		[FOE, ALLY, "swing_staff", "hit_staff_cloth", "EffectsEnemies"],
		[ALLY, FOE, "swing_mace", "hit_mace_cloth", "EffectsAllies"],
	]
	for c: Array in cases:
		a.push_view(_view(_units()))
		a.push_events([_ev("cast_success", c[0], c[1], {"ability": "auto_attack"}),
			_ev("damage", c[0], c[1], {"ability": "auto_attack", "amount": 900})])
		var swing: Array = _plays(a, c[2])
		var hit: Array = _plays(a, c[3])
		assert_int(hit.size()).override_failure_message("no %s" % c[3]).is_greater_equal(1)
		assert_int(int(swing[-1]["unit"])).is_equal(c[0])
		assert_int(int(hit[-1]["unit"])).is_equal(c[1])
		assert_str(str(hit[-1]["bus"])).is_equal(c[4])
	# an ability hit layers the weapon hit and its own sound
	a.push_view(_view(_units()))
	a.push_events([_ev("cast_success", ME, FOE, {"ability": "headsmans_verdict"}),
		_ev("damage", ME, FOE, {"ability": "headsmans_verdict", "amount": 9000})])
	assert_int(_plays(a, "headsmans_verdict_impact").size()).is_equal(1)
	assert_int(_plays(a, "hit_greatsword_cloth").size()).is_equal(2)


func test_aura_only_abilities_play_their_impact_on_each_target() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("cast_success", FOE, -1, {"ability": "rimebind"}),
		_ev("aura_applied", FOE, ME, {"aura": "rimebound", "cc": "root"}),
		_ev("aura_applied", FOE, ALLY, {"aura": "rimebound", "cc": "root"})])
	var imp: Array = _plays(a, "root_ice_impact")
	assert_int(imp.size()).is_equal(2)
	assert_array(imp.map(func(h: Dictionary) -> int: return int(h["unit"]))).contains_exactly_in_any_order([ME, ALLY])
	# an aura applied without a matching cast in the batch (e.g. a talent) plays no impact
	a.push_events([_ev("aura_applied", FOE, ME, {"aura": "rimebound", "cc": "root"})])
	assert_int(_plays(a, "root_ice_impact").size()).is_equal(2)


func test_periodic_aura_ticks_play_their_tick_sound() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("damage", ME, FOE, {"ability": "ruin_bleed", "amount": 300})])
	a.push_events([_ev("heal", ALLY, ME, {"ability": "lingering_grace", "amount": 800})])
	assert_int(_plays(a, "bleed_tick").size()).is_equal(1)
	assert_int(_plays(a, "heal_hot_tick").size()).is_equal(1)
	assert_str(str(_plays(a, "heal_hot_tick")[0]["bus"])).is_equal("EffectsAllies")


func test_cc_warning_plays_once_per_application_on_the_local_player() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("cast_success", FOE2, ME, {"ability": "chains_of_awe"}),
		_ev("aura_applied", FOE2, ME, {"aura": "awed_silence", "cc": "silence"})])
	assert_int(a.cc_warnings).is_equal(1)
	var w: Array = _plays(a, "cc_warning")
	assert_int(w.size()).is_equal(1)
	assert_bool(bool(w[0]["positional"])).is_false()
	assert_str(str(w[0]["bus"])).is_equal("Interface")
	assert_bool(bool(w[0]["critical"])).is_true()
	# a second crowd control in the same tick is the same moment: no second warning
	a.push_events([_ev("aura_applied", FOE, ME, {"aura": "heartfrozen", "cc": "stun"})])
	assert_int(a.cc_warnings).is_equal(1)
	# a new application later warns again; crowd control on others and roots do not
	a.push_view(_view(_units()))
	a.push_events([_ev("aura_applied", FOE, ME, {"aura": "dread_roared", "cc": "disorient"})])
	assert_int(a.cc_warnings).is_equal(2)
	a.push_view(_view(_units()))
	a.push_events([_ev("aura_applied", FOE, ALLY, {"aura": "heartfrozen", "cc": "stun"}),
		_ev("aura_applied", FOE, ME, {"aura": "rimebound", "cc": "root"}),
		_ev("aura_refreshed", FOE, ME, {"aura": "dread_roared"})])
	assert_int(a.cc_warnings).is_equal(2)
	# the setting turns it off
	a.cc_warning_enabled = false
	a.push_view(_view(_units()))
	a.push_events([_ev("aura_applied", FOE, ME, {"aura": "heartfrozen", "cc": "stun"})])
	assert_int(_plays(a, "cc_warning").size()).is_equal(2)


func test_incoming_cc_cast_at_me_warns() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("cast_start", FOE, ALLY, {"ability": "frost_effigy"})])
	assert_int(_plays(a, "cc_incoming").size()).is_equal(0)
	a.push_events([_ev("cast_start", FOE, ME, {"ability": "rime_bolt"})])  # damage, no crowd control
	assert_int(_plays(a, "cc_incoming").size()).is_equal(0)
	a.push_events([_ev("cast_start", FOE, ME, {"ability": "frost_effigy"})])
	assert_int(_plays(a, "cc_incoming").size()).is_equal(1)
	assert_bool(bool(_plays(a, "cc_incoming")[0]["positional"])).is_false()


func test_world_sounds_are_3d_with_arena_attenuation_and_ui_is_2d() -> void:
	var a: AudioDirector = _director()
	var v: Dictionary = a.play("rime_bolt_impact", FOE, FOE)
	var p: AudioStreamPlayer3D = v["player"]
	assert_bool(p.playing).is_true()
	assert_int(p.attenuation_model).is_equal(AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE)
	assert_float(p.max_distance).is_greater_equal(57.0)  # the 40 m arena's diagonal is 57 m
	assert_float(p.max_db).is_less_equal(0.0)
	assert_float(p.global_position.distance_to(Vector3(0, AudioDirector.EMIT_HEIGHT, -10))).is_less(0.01)
	# at the far side of a 40 m arena a hit is still clearly audible (inverse distance: -12 dB at 40 m)
	var db_40m: float = linear_to_db(p.unit_size / 40.0)
	assert_float(db_40m).is_between(-20.0, -6.0)
	var ui: Dictionary = a.play_ui("ui_click")
	assert_bool(ui["player"] is AudioStreamPlayer).is_true()
	assert_str(String((ui["player"] as AudioStreamPlayer).bus)).is_equal("Interface")
	assert_bool((ui["player"] as AudioStreamPlayer).playing).is_true()


func test_sounds_beyond_the_attenuation_distance_are_not_played() -> void:
	var a: AudioDirector = _director()
	var far: Array = _units()
	far[3]["position"] = Vector3(0, 0, -150)
	a.push_view(_view(far))
	var before: int = a.played
	a.push_events([_ev("cast_success", FOE2, FOE, {"ability": "auto_attack"})])
	assert_int(a.played).is_equal(before)
	assert_int(a.culled).is_greater(0)


func test_footsteps_follow_speed_and_armor() -> void:
	var counts: Dictionary = {}
	for speed: float in [7.0, 3.5, 0.0]:
		var a: AudioDirector = _director()
		var z: float = 0.0
		for i: int in 180:  # 3 s at 60 Hz, the warblade (plate) and the enemy arcanist (cloth) running
			z -= speed / 60.0
			var us: Array = _units()
			us[0]["position"] = Vector3(0, 0, z)
			us[2]["position"] = Vector3(0, 0, -10 + z)
			a.push_view(_view(us))
		counts[speed] = [_plays(a, "footstep_plate").size(), _plays(a, "footstep_cloth").size()]
		for h: Dictionary in _plays(a, "footstep_plate"):
			assert_str(str(h["bus"])).is_equal("EffectsSelf")
	# 21 m at 2.55 m per step: 8 steps (the first after half a stride); half speed: half the steps
	assert_int(int(counts[7.0][0])).is_between(7, 9)
	assert_int(int(counts[3.5][0])).is_between(3, 5)
	assert_int(int(counts[0.0][0])).is_equal(0)
	assert_int(int(counts[7.0][1])).is_between(7, 9)


func test_footsteps_and_landings_sound_wet_where_the_map_says_water() -> void:
	var a: AudioDirector = _director()
	a.surface_at = func(p: Vector3) -> String: return "water" if p.z < -5.0 else ""
	var z: float = 0.0
	for i: int in 180:  # 21 m: the first 5 m dry, the rest wading
		z -= 7.0 / 60.0
		var us: Array = _units()
		us[0]["position"] = Vector3(0, 0, z)
		a.push_view(_view(us))
	assert_int(_plays(a, "footstep_plate").size()).is_between(1, 2)
	assert_int(_plays(a, "footstep_wade").size()).is_between(5, 7)
	for y: float in [0.6, 1.2, 0.4, 0.0, 0.0]:
		var us: Array = _units()
		us[0]["position"] = Vector3(0, y, z)
		a.push_view(_view(us))
	assert_int(_plays(a, "land_wade").size()).is_equal(1)
	assert_int(_plays(a, "land_plate").size()).is_equal(0)


func test_landing_plays_once_on_touchdown() -> void:
	var a: AudioDirector = _director()
	for y: float in [0.5, 1.2, 1.5, 0.8, 0.2, 0.0, 0.0]:
		var us: Array = _units()
		us[0]["position"] = Vector3(0, y, 0)
		a.push_view(_view(us))
	assert_int(_plays(a, "land_plate").size()).is_equal(1)


func test_interface_error_is_throttled_and_target_ticks() -> void:
	var a: AudioDirector = _director()
	a.push_events([_ev("cast_failed", ME, -1, {"ability": "ruin_strike", "reason": "out_of_range"})])
	a.push_events([_ev("cast_failed", ME, -1, {"ability": "ruin_strike", "reason": "out_of_range"})])
	a.push_events([_ev("cast_failed", FOE, -1, {"ability": "rime_bolt", "reason": "not_ready"})])
	assert_int(_plays(a, "ui_error").size()).is_equal(1)
	a.set_target(FOE)
	a.set_target(FOE)
	a.set_target(-1)
	assert_int(_plays(a, "ui_target").size()).is_equal(1)


func test_voices_end_by_game_time() -> void:
	var a: AudioDirector = _director()
	a.play("rime_bolt_impact", FOE, FOE)
	a.play("footstep_plate", ME, ME)
	assert_int(a.voice_count()).is_equal(2)
	for i: int in 180:
		a.push_view(_view(_units()))
	assert_int(a.voice_count()).is_equal(0)


func test_voice_cap_holds_in_a_20_player_brawl_and_enemy_cc_is_never_dropped() -> void:
	_tick = 0
	var a: AudioDirector = auto_free(AudioDirector.new())
	add_child(a)
	a.listener_position = Vector3.ZERO
	var specs: Array = ["warblade_carnage", "arcanist_rime", "oracle_grace"]
	var us: Array = []
	for i: int in 20:
		us.append(_unit(i + 1, specs[i % 3], i % 2, Vector3((i % 5) * 3.0, 0, (i / 5) * 3.0)))
	a.push_view(_view(us))
	assert_int(a.max_voices).is_equal(64)
	var critical_played: int = 0
	for t: int in 600:  # 10 s of a 20-player brawl: swings, hits, casts starting, footsteps
		var dir: float = 0.1 if (t / 60) % 2 == 0 else -0.1  # running back and forth near the listener
		for u: Dictionary in us:
			u["position"] = (u["position"] as Vector3) + Vector3(dir, 0, 0)
		a.push_view(_view(us))
		var evs: Array = []
		for i: int in 20:
			var src: int = i + 1
			var tgt: int = ((i + 1) % 20) + 1
			if (t + i) % 6 == 0:  # every unit swings and hits 10 times a second: 400 sounds/s
				evs.append(_ev("cast_success", src, tgt, {"ability": "auto_attack"}))
				evs.append(_ev("damage", src, tgt, {"ability": "auto_attack", "amount": 500}))
			if t % 30 == i:
				evs.append(_ev("cast_start", src, tgt, {"ability": "rime_bolt"}))
		if t % 50 == 0:  # an enemy of the local player (unit 1, team 0) stuns someone
			evs.append(_ev("cast_success", 2, 5, {"ability": "pommel_crack"}))
			evs.append(_ev("aura_applied", 2, 5, {"aura": "pommel_cracked", "cc": "stun"}))
		var before: int = a.count_of("pommel_crack_impact")
		a.push_events(evs)
		assert_int(a.voice_count()).is_less_equal(64)
		if t % 50 == 0:
			assert_int(a.count_of("pommel_crack_impact")).override_failure_message(
				"enemy crowd control dropped at tick %d" % t).is_equal(before + 1)
			critical_played += 1
	assert_int(a.peak_voices).is_less_equal(64)
	assert_int(a.peak_voices).is_greater(40)  # the cap was actually tested
	assert_int(a.dropped + a.stolen).is_greater(0)
	assert_int(critical_played).is_equal(12)
	assert_int(a.dropped_critical()).is_equal(0)
	# the players never outnumber the cap either (voices are pooled, not created per sound)
	assert_int(a.get_child_count()).is_less_equal(64)


func test_melee_impact_waits_for_the_swing_to_strike() -> void:
	# a swing striking 0.45 s in; the greatsword hit's contact is contact_s into its file, so the
	# hit starts that much earlier; the swing itself plays at once; a spell impact never waits
	var a: AudioDirector = _director()
	a.strike_delay = func(src: int, ab: String) -> float: return 0.45 if ab in ["auto_attack", "grim_hack"] else 0.0
	var lead: float = float(a.bank.sounds["hit_greatsword_cloth"].get("contact_s", 0.0))
	assert_float(lead).is_greater(0.0)
	var start: int = _tick
	a.push_events([_ev("cast_success", ME, FOE, {"ability": "grim_hack"}),
		_ev("damage", ME, FOE, {"ability": "grim_hack", "amount": 4000})])
	assert_int(_plays(a, "swing_greatsword").size()).is_equal(1)
	assert_int(_plays(a, "hit_greatsword_cloth").size()).is_equal(0)
	var due: int = start + roundi((0.45 - lead) * 60)
	while _tick < due - 1:
		a.push_view(_view(_units()))
	assert_int(_plays(a, "hit_greatsword_cloth").size()).is_equal(0)
	a.push_view(_view(_units()))
	var hit: Array = _plays(a, "hit_greatsword_cloth")
	assert_int(hit.size()).is_equal(1)
	assert_int(int(hit[0]["tick"])).is_equal(due)
	a.push_events([_ev("damage", FOE, ME, {"ability": "rime_bolt", "amount": 7800})])
	assert_int(_plays(a, "rime_bolt_impact").size()).is_equal(1)


func test_animator_reports_the_strike_of_its_next_swing() -> void:
	for clip: String in ["attack_1", "attack_2", "attack_3"]:
		assert_float(CharacterAnimator.strike_time_s(clip)).is_between(0.3, 0.6)
	assert_float(CharacterAnimator.strike_time_s("idle")).is_equal(0.0)
