extends GdUnitTestSuite
## Character animation hookup (backlog M1-24): CharacterAnimator picks and blends clips from the
## world view (velocity, cast, auras, health, match result) and combat events, as the states data
## (data/anim_states/humanoid.json) says. Deterministic: the tree is advanced by hand.

const DT: float = 1.0 / 60.0
const ME: int = 1
const ENEMY: int = 2


func _animator(spec: String, unit_id: int = ME, team: int = 0) -> CharacterAnimator:
	var asset: Dictionary = WorldRenderer.character_asset(spec)
	assert_bool(ResourceLoader.exists(CharacterRig.res_path(asset))).override_failure_message("%s not built" % spec).is_true()
	var model: Node3D = auto_free((load(CharacterRig.res_path(asset)) as PackedScene).instantiate())
	add_child(model)
	var a: CharacterAnimator = CharacterAnimator.create(CharacterRig.setup(asset, model), unit_id, team)
	assert_object(a).is_not_null()
	return a


func _unit(spec: String, id: int = ME, team: int = 0) -> Dictionary:
	return {"id": id, "team": team, "spec": spec, "position": Vector3.ZERO, "facing": 0.7, "health": 60000,
		"max_health": 60000, "target_id": -1, "cast": {}, "auras": []}


func _view(units: Array, phase: int = ArenaMatch.Phase.ACTIVE, winner: int = -1) -> Dictionary:
	return {"tick": 1, "tick_rate": 60, "units": units, "match": {"phase": phase, "winner": winner}}


func _run(a: CharacterAnimator, u: Dictionary, view: Dictionary, velocity: Vector3, seconds: float) -> void:
	for i: int in roundi(seconds / DT):
		a.update(u, view, velocity, DT)


func _cast(ability: String, channel: bool = false) -> Dictionary:
	return {"ability": ability, "target": ENEMY, "start_tick": 0, "end_tick": 120, "channel": channel,
		"ticks_done": 0, "tick_every": 40}


func _success(ability: String) -> Dictionary:
	return {"type": "cast_success", "source": ME, "target": ENEMY, "ability": ability}


func test_blend_space_follows_velocity_relative_to_facing() -> void:
	var a: CharacterAnimator = _animator("warblade_carnage")
	var u: Dictionary = _unit("warblade_carnage")
	var v: Dictionary = _view([u])
	var facing: float = float(u["facing"])
	var cases: Array = [
		[Movement.forward_of(facing) * 7.0, Vector2(0, 1), "run", 1.0],
		[-Movement.forward_of(facing) * 4.2, Vector2(0, -1), "backpedal", 1.0],
		[Movement.right_of(facing) * 7.0, Vector2(1, 0), "strafe_right", 1.0],
		[-Movement.right_of(facing) * 7.0, Vector2(-1, 0), "strafe_left", 1.0],
		[Movement.forward_of(facing) * 4.2, Vector2(0, 1), "run", 0.6],  # slowed 40%: clips play slower
		[Movement.forward_of(facing) * 20.0, Vector2(0, 1), "run", 1.4],  # sped up: capped
		[Vector3.ZERO, Vector2.ZERO, "idle", 1.0],
	]
	for c: Array in cases:
		_run(a, u, v, c[0], 1.0)
		assert_vector(a.blend_position).override_failure_message("%s: blend %s" % [c[2], a.blend_position]) \
			.is_equal_approx(c[1], Vector2.ONE * 0.01)
		var in_tree: Vector2 = a.tree.get("parameters/loco/blend_position")
		assert_vector(in_tree).is_equal_approx(a.blend_position, Vector2.ONE * 1e-5)
		assert_str(a.locomotion).is_equal(c[2])
		assert_float(a.time_scale).is_equal_approx(c[3], 0.01)
		assert_float(float(a.tree.get("parameters/loco_speed/scale"))).is_equal_approx(
			lerpf(1.0, c[3], a.blend_position.length()), 0.01)
	# the blend position eases toward a new velocity rather than jumping (no pops)
	a.update(u, v, Movement.forward_of(facing) * 7.0, DT)
	assert_float(a.blend_position.length()).is_between(0.05, 0.5)


func test_combat_idle_with_a_hostile_target_in_range() -> void:
	var a: CharacterAnimator = _animator("oracle_grace")
	var u: Dictionary = _unit("oracle_grace")
	var enemy: Dictionary = _unit("arcanist_rime", ENEMY, 1)
	enemy["position"] = Vector3(0, 0, -20)
	u["target_id"] = ENEMY
	_run(a, u, _view([u, enemy]), Vector3.ZERO, 0.5)
	assert_bool(a.in_combat).is_true()
	assert_str(a.locomotion).is_equal("combat_idle")
	assert_float(float(a.tree.get("parameters/loco/stand/blend_position"))).is_equal_approx(1.0, 1e-5)
	enemy["position"] = Vector3(0, 0, -60)  # out of range: back to idle
	_run(a, u, _view([u, enemy]), Vector3.ZERO, 0.5)
	assert_str(a.locomotion).is_equal("idle")
	assert_float(a.stand_blend).is_equal_approx(0.0, 1e-5)


func test_cast_bar_drives_start_loop_and_school_release() -> void:
	for c: Array in [["arcanist_rime", "rime_bolt", "cast_release_frost"], ["oracle_grace", "mending_light", "cast_release_holy"]]:
		var a: CharacterAnimator = _animator(c[0])
		var u: Dictionary = _unit(c[0])
		var v: Dictionary = _view([u])
		u["cast"] = _cast(c[1])
		_run(a, u, v, Vector3.ZERO, 0.1)
		assert_str(a.action).is_equal("cast_start")
		assert_str(str(a.tree.get("parameters/act_upper/current_state"))).is_equal("cast_start")
		_run(a, u, v, Vector3.ZERO, 0.4)
		assert_str(a.action).is_equal("cast_loop")
		assert_str(str(a.tree.get("parameters/act_lower/current_state"))).is_equal("cast_loop")
		assert_float(a.upper_weight).is_equal(1.0)
		assert_float(a.lower_weight).is_equal(1.0)  # standing: the legs join the cast
		_run(a, u, v, Vector3.ZERO, 1.0)
		assert_str(a.action).is_equal("cast_loop")  # held while the bar runs
		# the bar completes: the server clears the cast and reports success
		u["cast"] = {}
		a.push_event(_success(c[1]))
		a.update(u, v, Vector3.ZERO, DT)
		assert_str(a.action).is_equal(c[2])
		assert_str(str(a.tree.get("parameters/act_upper/current_state"))).is_equal(c[2])
		_run(a, u, v, Vector3.ZERO, 0.8)  # release (0.5 s) then the fade back
		assert_str(a.action).is_equal("")
		assert_str(a.state()).is_equal("idle")  # no target, no damage: out of combat once the cast ends
		assert_float(a.upper_weight).is_equal(0.0)


func test_interrupted_cast_returns_to_locomotion_and_channel_loops() -> void:
	var a: CharacterAnimator = _animator("arcanist_rime")
	var u: Dictionary = _unit("arcanist_rime")
	var v: Dictionary = _view([u])
	u["cast"] = _cast("rime_bolt")
	_run(a, u, v, Vector3.ZERO, 0.6)
	u["cast"] = {}  # interrupted: no success event
	a.push_event({"type": "cast_interrupted", "source": ME, "ability": "rime_bolt", "reason": "interrupt"})
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("")
	u["cast"] = _cast("hailstorm", true)
	_run(a, u, v, Vector3.ZERO, 2.0)
	assert_str(a.action).is_equal("channel")
	u["cast"] = {}
	a.push_event({"type": "channel_end", "source": ME, "ability": "hailstorm"})
	_run(a, u, v, Vector3.ZERO, 0.5)
	assert_str(a.action).is_equal("")
	assert_float(a.upper_weight).is_equal(0.0)


func test_instant_spells_play_their_release() -> void:
	var a: CharacterAnimator = _animator("arcanist_rime")
	var u: Dictionary = _unit("arcanist_rime")
	var v: Dictionary = _view([u])
	a.push_event(_success("shiver_lance"))
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("cast_release_frost")
	var o: CharacterAnimator = _animator("oracle_grace")
	var ou: Dictionary = _unit("oracle_grace")
	o.push_event(_success("psalm_of_dread"))  # shadow: no shadow release clip, the default plays
	o.update(ou, _view([ou]), Vector3.ZERO, DT)
	assert_str(o.action).is_equal("cast_release")


func test_melee_abilities_and_auto_attacks_cycle_attack_clips() -> void:
	var a: CharacterAnimator = _animator("warblade_carnage")
	var u: Dictionary = _unit("warblade_carnage")
	var v: Dictionary = _view([u])
	var seen: Array[String] = []
	for ab: String in ["grim_hack", "ruin_strike", "wide_hew", "gashing_blow"]:
		a.push_event(_success(ab))
		a.update(u, v, Vector3.ZERO, DT)
		seen.append(a.action)
		_run(a, u, v, Vector3.ZERO, 0.9)
	assert_array(seen).is_equal(["attack_1", "attack_2", "attack_3", "attack_1"])
	# auto-attack swings continue the cycle; a pause restarts it
	a.push_event({"type": "damage", "source": ME, "target": ENEMY, "ability": "auto_attack", "amount": 1200, "absorbed": 0})
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("attack_2")
	_run(a, u, v, Vector3.ZERO, 3.5)
	a.push_event(_success("grim_hack"))
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("attack_1")
	# a physical ranged instant plays the ranged shot; a charge swings on arrival
	_run(a, u, v, Vector3.ZERO, 1.0)
	a.push_event(_success("shield_breaker"))
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("ranged_shot")


func test_attacks_on_the_run_play_on_the_upper_body_only() -> void:
	var running: CharacterAnimator = _animator("warblade_carnage", ME)
	var swinging: CharacterAnimator = _animator("warblade_carnage", ME)
	var u: Dictionary = _unit("warblade_carnage")
	var v: Dictionary = _view([u])
	var vel: Vector3 = Movement.forward_of(float(u["facing"])) * 7.0
	_run(running, u, v, vel, 0.5)
	_run(swinging, u, v, vel, 0.5)
	swinging.push_event(_success("grim_hack"))
	running.update(u, v, vel, DT)
	swinging.update(u, v, vel, DT)
	_run(running, u, v, vel, 0.3)
	_run(swinging, u, v, vel, 0.3)
	assert_float(swinging.upper_weight).is_equal(1.0)
	assert_float(swinging.lower_weight).is_equal(0.0)
	var sk_run: Skeleton3D = CharacterRig.skeleton_of(running.get_parent())
	var sk_swing: Skeleton3D = CharacterRig.skeleton_of(swinging.get_parent())
	for bone: String in ["thigh_l", "calf_r", "foot_l"]:  # legs keep running
		var i: int = sk_run.find_bone(bone)
		assert_float(sk_run.get_bone_pose_rotation(i).angle_to(sk_swing.get_bone_pose_rotation(i))) \
			.override_failure_message("%s differs while swinging on the run" % bone).is_less(1e-3)
	var arm: int = sk_run.find_bone("upperarm_r")  # the sword arm swings
	assert_float(sk_run.get_bone_pose_rotation(arm).angle_to(sk_swing.get_bone_pose_rotation(arm))).is_greater(0.1)


func test_big_hits_play_a_throttled_hit_reaction() -> void:
	var a: CharacterAnimator = _animator("oracle_grace")
	var u: Dictionary = _unit("oracle_grace")
	var v: Dictionary = _view([u])
	var small: Dictionary = {"type": "damage", "source": ENEMY, "target": ME, "ability": "auto_attack", "amount": 1200, "absorbed": 0}
	var big: Dictionary = {"type": "damage", "source": ENEMY, "target": ME, "ability": "rime_bolt", "amount": 6000, "absorbed": 0}
	a.push_event(small)
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("")
	a.push_event(big)
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("hit")
	_run(a, u, v, Vector3.ZERO, 0.5)
	assert_str(a.action).is_equal("")
	a.push_event(big)  # within the cooldown
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("")
	_run(a, u, v, Vector3.ZERO, 1.2)
	u["cast"] = _cast("mending_light")  # a hit does not break a cast pose
	_run(a, u, v, Vector3.ZERO, 0.5)
	a.push_event(big)
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("cast_loop")


func test_stun_overrides_everything_and_recovers_cleanly() -> void:
	var a: CharacterAnimator = _animator("arcanist_rime")
	var u: Dictionary = _unit("arcanist_rime")
	var v: Dictionary = _view([u])
	u["cast"] = _cast("rime_bolt")
	_run(a, u, v, Vector3.ZERO, 0.5)
	u["auras"] = [{"id": "pommel_cracked", "source": ENEMY}]
	u["cast"] = {}
	_run(a, u, v, Vector3.ZERO, 0.3)
	assert_str(a.override).is_equal("stunned")
	assert_str(a.state()).is_equal("stunned")
	assert_str(a.action).is_equal("")
	assert_str(str(a.tree.get("parameters/ov/current_state"))).is_equal("stunned")
	assert_float(float(a.tree.get("parameters/override/blend_amount"))).is_equal(1.0)
	a.push_event(_success("shiver_lance"))  # nothing plays over crowd control
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.action).is_equal("")
	# incapacitate looks the same
	u["auras"] = [{"id": "effigy_encased", "source": ENEMY}]
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.override).is_equal("stunned")
	# the stun ends while the player holds forward: back to running, faded out
	u["auras"] = []
	var vel: Vector3 = Movement.forward_of(float(u["facing"])) * 7.0
	a.update(u, v, vel, DT)
	assert_str(a.override).is_equal("")
	assert_float(a.override_weight).is_between(0.5, 1.0)  # fading, not popping
	_run(a, u, v, vel, 0.4)
	assert_float(a.override_weight).is_equal(0.0)
	assert_str(a.state()).is_equal("run")


func test_fear_plays_the_feared_run() -> void:
	var a: CharacterAnimator = _animator("warblade_carnage")
	var u: Dictionary = _unit("warblade_carnage")
	var v: Dictionary = _view([u])
	u["auras"] = [{"id": "psalm_dread", "source": ENEMY}]
	_run(a, u, v, Movement.forward_of(float(u["facing"])) * 7.0, 0.5)  # the server moves feared units
	assert_str(a.state()).is_equal("feared_run")
	assert_str(str(a.tree.get("parameters/ov/current_state"))).is_equal("feared_run")
	u["auras"] = [{"id": "psalm_dread", "source": ENEMY}, {"id": "heartfrozen", "source": ENEMY}]
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.state()).is_equal("stunned")  # a stun on top of a fear wins (data order)
	u["auras"] = [{"id": "rimebound", "source": ENEMY}]  # a root is not an override: legs just stop
	_run(a, u, v, Vector3.ZERO, 0.5)
	assert_str(a.state()).is_equal("idle")


func test_death_plays_once_and_stays() -> void:
	var a: CharacterAnimator = _animator("oracle_grace")
	var u: Dictionary = _unit("oracle_grace")
	var v: Dictionary = _view([u])
	u["cast"] = _cast("mending_light")
	_run(a, u, v, Vector3.ZERO, 0.5)
	u["health"] = 0
	u["cast"] = {}
	_run(a, u, v, Vector3.ZERO, 0.5)
	assert_str(a.state()).is_equal("death")
	var changes: int = a.state_changes
	a.push_event({"type": "damage", "source": ENEMY, "target": ME, "ability": "rime_bolt", "amount": 9000, "absorbed": 0})
	_run(a, u, v, Vector3.ZERO, 5.0)
	assert_str(a.state()).is_equal("death")
	assert_int(a.state_changes).is_equal(changes)
	assert_float(a.override_weight).is_equal(1.0)
	var pos: float = float(a.tree.get("parameters/o_death/current_position"))
	assert_float(pos).is_equal_approx(a.player.get_animation("death").length, 0.02)  # held on its last frame


func test_winners_play_victory_losers_do_not() -> void:
	var win: CharacterAnimator = _animator("warblade_carnage", ME, 0)
	var lose: CharacterAnimator = _animator("arcanist_rime", ENEMY, 1)
	var u: Dictionary = _unit("warblade_carnage", ME, 0)
	var e: Dictionary = _unit("arcanist_rime", ENEMY, 1)
	var v: Dictionary = _view([u, e], ArenaMatch.Phase.ENDED, 0)
	_run(win, u, v, Vector3.ZERO, 0.3)
	_run(lose, e, v, Vector3.ZERO, 0.3)
	assert_str(win.state()).is_equal("victory")
	assert_str(lose.state()).is_not_equal("victory")


func test_airborne_units_jump() -> void:
	var a: CharacterAnimator = _animator("warblade_carnage")
	var u: Dictionary = _unit("warblade_carnage")
	var v: Dictionary = _view([u])
	_run(a, u, v, Vector3.ZERO, 0.2)
	u["position"] = Vector3(0, 0.6, 0)
	_run(a, u, v, Vector3.ZERO, 0.1)
	assert_str(a.locomotion).is_equal("jump")
	assert_bool(bool(a.tree.get("parameters/jump/active"))).is_true()
	u["position"] = Vector3.ZERO
	a.update(u, v, Vector3.ZERO, DT)
	assert_str(a.locomotion).is_equal("idle")


func test_every_ability_resolves_to_an_action_from_data() -> void:
	var st: Dictionary = Data.anim_states["humanoid"]
	var melee_m: float = float(Data.tuning["ranges"]["melee_m"])
	var expect: Dictionary = {"rime_bolt": "cast", "mending_light": "cast", "hailstorm": "channel", "grim_hack": "melee",
		"throat_punch": "melee", "warpath_charge": "melee", "shield_breaker": "ranged", "shiver_lance": "release",
		"chorus_of_mending": "release", "psalm_of_dread": "release", "bloody_resolve": "none", "break_free": "none",
		"dread_roar": "release", "auto_attack": "melee"}
	for id: String in expect:
		assert_str(CharacterAnimator.ability_action(st, Data.abilities[id], melee_m)) \
			.override_failure_message("%s" % id).is_equal(expect[id])
	for id: String in Data.abilities:
		var kind: String = CharacterAnimator.ability_action(st, Data.abilities[id], melee_m)
		assert_bool(kind in ["cast", "channel", "release", "melee", "ranged", "none"]).override_failure_message(
			"%s: %s" % [id, kind]).is_true()


func test_every_character_builds_a_tree_with_every_clip() -> void:
	for spec: String in ["warblade_carnage", "arcanist_rime", "oracle_grace"]:
		var a: CharacterAnimator = _animator(spec)
		for n: StringName in a.player.get_animation_list():
			if str(n) in ["idle", "combat_idle", "run", "backpedal", "strafe_left", "strafe_right", "jump"]:
				continue
			assert_bool(str(n) in a._action_inputs or str(n) in a._override_inputs) \
				.override_failure_message("%s: clip %s unused" % [spec, n]).is_true()
		assert_bool(a.tree.active).is_true()
		assert_str(a.state()).is_equal("idle")
