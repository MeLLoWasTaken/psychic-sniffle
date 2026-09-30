extends GdUnitTestSuite
## Rig modifiers (backlog X-02): head turning (LookAtModifier3D per bone) and foot grounding
## (FootGrounding + TwoBoneIK3D + FootAlign) on built characters, driven by CharacterAnimator from
## the states data (data/anim_states/humanoid.json, rig_modifiers). Deterministic: the tree and the
## skeleton's modifiers are advanced by hand; RigModifiers.flush reads the modified pose.

const DT: float = 1.0 / 60.0
const ME: int = 1
const ENEMY: int = 2
const STEP_H: float = 0.22

var _look: Dictionary = Data.anim_states["humanoid"]["rig_modifiers"]["look_at"]


func after_test() -> void:
	RigModifiers.graphics = {}  # back to the default profile's graphics section


## A character like WorldRenderer builds it: a root at `pos` turned to `facing`, the model inside
## turned PI (models face +Z, the game's forward is -Z).
func _char(spec: String, pos: Vector3 = Vector3.ZERO, facing: float = 0.0) -> Dictionary:
	var asset: Dictionary = WorldRenderer.character_asset(spec)
	assert_bool(ResourceLoader.exists(CharacterRig.res_path(asset))).override_failure_message("%s not built" % spec).is_true()
	var root: Node3D = auto_free(Node3D.new())
	add_child(root)
	root.position = pos
	root.rotation.y = facing
	var model: Node3D = (load(CharacterRig.res_path(asset)) as PackedScene).instantiate()
	model.rotation.y = PI
	root.add_child(model)
	var a: CharacterAnimator = CharacterAnimator.create(CharacterRig.setup(asset, model), ME, 0)
	assert_object(a.rig).is_not_null()
	var u: Dictionary = {"id": ME, "team": 0, "spec": spec, "position": Vector3(pos.x, 0.0, pos.z), "facing": facing,
		"health": 60000, "max_health": 60000, "target_id": -1, "cast": {}, "auras": []}
	return {"root": root, "animator": a, "rig": a.rig, "unit": u, "view": {"tick": 1, "units": [u], "match": {"phase": 1}}}


func _run(c: Dictionary, seconds: float, velocity: Vector3 = Vector3.ZERO) -> void:
	for i: int in roundi(seconds / DT):
		(c["animator"] as CharacterAnimator).update(c["unit"], c["view"], velocity, DT)
		(c["rig"] as RigModifiers).flush([])


## One more frame, returning the modified global poses (world space) of `bones`.
func _pose(c: Dictionary, bones: PackedStringArray) -> Dictionary:
	(c["animator"] as CharacterAnimator).update(c["unit"], c["view"], Vector3.ZERO, DT)
	var rig: RigModifiers = c["rig"]
	var sk_space: Dictionary = rig.flush(bones)
	var out: Dictionary = {}
	for b: String in bones:
		assert_bool(sk_space.has(b)).override_failure_message("no modified pose for %s" % b).is_true()
		out[b] = rig.skeleton.global_transform * (sk_space[b] as Transform3D)
	return out


## The same bones without modifiers (the skeleton restores the animated pose after each update).
func _animated(c: Dictionary, bones: PackedStringArray) -> Dictionary:
	var sk: Skeleton3D = (c["rig"] as RigModifiers).skeleton
	var out: Dictionary = {}
	for b: String in bones:
		out[b] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b))
	return out


## Head yaw (degrees, positive toward the character's left) and pitch relative to its facing.
func _head_angles(c: Dictionary, head: Transform3D) -> Vector2:
	var sg: Transform3D = (c["rig"] as RigModifiers).skeleton.global_transform
	var fwd: Vector3 = sg.basis.z.normalized()
	var up: Vector3 = sg.basis.y.normalized()
	var f: Vector3 = head.basis.z.normalized()  # standard skeleton bones face +Z
	return Vector2(rad_to_deg(fwd.signed_angle_to(f.slide(up), up)), rad_to_deg(asin(clampf(f.dot(up), -1.0, 1.0))))


## Puts an enemy target `yaw_deg` toward the character's left of its facing, `dist` metres away.
func _target_at(c: Dictionary, yaw_deg: float, dist: float = 6.0, height: float = 0.0) -> void:
	var sg: Transform3D = (c["rig"] as RigModifiers).skeleton.global_transform
	var fwd: Vector3 = sg.basis.z.normalized()
	var p: Vector3 = (c["root"] as Node3D).position + fwd.rotated(Vector3.UP, deg_to_rad(yaw_deg)) * dist
	p.y = height
	var enemy: Dictionary = {"id": ENEMY, "team": 1, "position": p, "health": 60000}
	c["view"]["units"] = [c["unit"], enemy]
	c["unit"]["target_id"] = ENEMY


func _box(pos: Vector3, size: Vector3, rot: Vector3 = Vector3.ZERO) -> void:
	var body: StaticBody3D = auto_free(StaticBody3D.new())
	body.collision_layer = 1 << (MapBuilder.LAYER_WORLD - 1)
	body.position = pos
	body.rotation = rot
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)


func _floor() -> void:
	_box(Vector3(0, -0.2, 0), Vector3(30, 0.4, 30))


func _settle_physics() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


# ------------------------------------------------------------------ look-at

func test_head_turns_toward_the_target_within_the_limits() -> void:
	var c: Dictionary = _char("warblade_carnage", Vector3(3, 0, 1), 0.4)
	var max_yaw: float = float(_look["max_yaw_deg"])
	for case: Array in [[30.0, 30.0], [-45.0, -45.0], [100.0, max_yaw], [-100.0, -max_yaw], [160.0, 0.0], [0.0, 0.0]]:
		_target_at(c, case[0])
		_run(c, 1.0)
		var yp: Vector2 = _head_angles(c, _pose(c, ["head"])["head"])
		assert_float(yp.x).override_failure_message("target at %s: head yaw %.1f, want %.1f" % [case[0], yp.x, case[1]]) \
			.is_equal_approx(case[1], 4.0)
		assert_float(absf(yp.x)).is_less_equal(max_yaw + 2.0)
		assert_str((c["rig"] as RigModifiers).look_goal).is_equal("target")
	# pitch: a target high above and one on the floor at the feet
	_target_at(c, 0.0, 2.0, 4.0)
	_run(c, 1.0)
	var up: Vector2 = _head_angles(c, _pose(c, ["head"])["head"])
	assert_float(up.y).is_less_equal(float(_look["max_pitch_up_deg"]) + 3.0)
	assert_float(up.y).is_greater(15.0)
	_target_at(c, 0.0, 1.0, -1.5)
	_run(c, 1.0)
	var down: Vector2 = _head_angles(c, _pose(c, ["head"])["head"])
	assert_float(down.y).is_greater_equal(-float(_look["max_pitch_down_deg"]) - 3.0)
	assert_float(down.y).is_less(-20.0)


func test_turn_is_spread_over_chest_neck_and_head() -> void:
	var c: Dictionary = _char("arcanist_rime")
	_target_at(c, 0.0)  # straight ahead (a hostile target also means the combat idle for both poses)
	_run(c, 1.0)
	var rest: Dictionary = _pose(c, ["chest", "neck", "head"])
	_target_at(c, 60.0)
	_run(c, 1.0)
	var turned: Dictionary = _pose(c, ["chest", "neck", "head"])
	var yaws: Array[float] = []
	for b: String in ["chest", "neck", "head"]:
		yaws.append(_head_angles(c, turned[b]).x - _head_angles(c, rest[b]).x)
	# every bone helps, the head the most, and chest < neck < head
	assert_float(yaws[0]).is_between(3.0, 20.0)
	assert_float(yaws[1]).is_greater(yaws[0])
	assert_float(yaws[2]).is_greater(yaws[1])
	assert_float(yaws[2]).is_equal_approx(60.0, 4.0)


func test_head_eases_to_a_new_target_without_snapping() -> void:
	var c: Dictionary = _char("oracle_grace")
	_target_at(c, 50.0)
	_run(c, 1.0)
	var before: float = _head_angles(c, _pose(c, ["head"])["head"]).x
	_target_at(c, -50.0)
	var prev: float = before
	var biggest: float = 0.0
	for i: int in 60:
		var yaw: float = _head_angles(c, _pose(c, ["head"])["head"]).x
		biggest = maxf(biggest, absf(yaw - prev))
		prev = yaw
	assert_float(biggest).override_failure_message("head jumped %.1f degrees in one frame" % biggest).is_less(12.0)
	assert_float(prev).is_equal_approx(-50.0, 4.0)  # arrived within a second


func test_without_a_target_the_head_leans_into_strafes_but_not_backpedal() -> void:
	var c: Dictionary = _char("warblade_carnage")
	var facing: float = float(c["unit"]["facing"])
	_run(c, 0.5, Movement.right_of(facing) * 7.0)
	var rig: RigModifiers = c["rig"]
	assert_str(rig.look_goal).is_equal("moving")
	var yaw: float = _head_angles(c, _pose(c, ["head"])["head"]).x
	assert_float(yaw).is_less(-25.0)  # toward the right (negative: the left is positive)
	_run(c, 0.5, -Movement.forward_of(facing) * 4.2)
	assert_str(rig.look_goal).is_equal("ahead")


func test_look_at_blends_out_in_crowd_control_death_and_big_swings() -> void:
	var c: Dictionary = _char("warblade_carnage")
	var a: CharacterAnimator = c["animator"]
	var rig: RigModifiers = c["rig"]
	_target_at(c, 50.0, 3.0)
	_run(c, 0.5)
	assert_float(rig.look_weight).is_equal(1.0)
	var cases: Array = [
		[[{"id": "pommel_cracked", "source": ENEMY}], 60000, "stunned"],
		[[{"id": "psalm_dread", "source": ENEMY}], 60000, "feared_run"],
		[[], 0, "death"],
	]
	for case: Array in cases:
		c["unit"]["auras"] = case[0]
		c["unit"]["health"] = case[1]
		(c["animator"] as CharacterAnimator).update(c["unit"], c["view"], Vector3.ZERO, DT)
		assert_float(rig.look_weight).override_failure_message("%s: fading, not popping" % case[2]).is_greater(0.5)
		_run(c, 0.3)
		assert_str(a.state()).is_equal(case[2])
		assert_float(rig.look_weight).is_equal(0.0)
		for la: LookAtModifier3D in rig.look_bones:
			assert_float(la.influence).is_equal(0.0)
		c["unit"]["auras"] = []
		c["unit"]["health"] = 60000
		if case[2] != "death":
			_run(c, 0.6)
			assert_float(rig.look_weight).is_equal(1.0)  # back after recovery
	# a melee swing: a big clip that the head must not fight
	var d: Dictionary = _char("warblade_carnage", Vector3(5, 0, 0))
	_target_at(d, 20.0, 3.0)
	_run(d, 0.5)
	(d["animator"] as CharacterAnimator).push_event({"type": "cast_success", "source": ME, "target": ENEMY, "ability": "grim_hack"})
	_run(d, 0.2)
	assert_str((d["animator"] as CharacterAnimator).action).is_equal("attack_1")
	assert_float((d["rig"] as RigModifiers).look_weight).is_equal(0.0)


# ------------------------------------------------------------------ feet

func test_feet_stand_on_both_levels_of_a_step() -> void:
	_floor()
	_box(Vector3(-1.0, STEP_H * 0.5, 0.0), Vector3(2.0, STEP_H, 2.0))  # upper level: x in [-2, 0]
	await _settle_physics()
	for spec: String in ["warblade_carnage", "arcanist_rime"]:
		# facing +Z (yaw PI): the right foot is at -x (on the step), the left at +x (below)
		var c: Dictionary = _char(spec, Vector3(0.0, STEP_H, 0.0), PI)
		_run(c, 1.0)
		var feet: Dictionary = _pose(c, ["foot_l", "foot_r", "pelvis"])
		var anim: Dictionary = _animated(c, ["foot_l", "foot_r", "pelvis"])
		var root_y: float = (c["root"] as Node3D).position.y
		# the animated clearance of each ankle above the character's feet, kept above the floor under it
		var want_r: float = STEP_H + ((anim["foot_r"] as Transform3D).origin.y - root_y)
		var want_l: float = 0.0 + ((anim["foot_l"] as Transform3D).origin.y - root_y)
		assert_float((feet["foot_r"] as Transform3D).origin.y).override_failure_message("%s right ankle" % spec).is_equal_approx(want_r, 0.02)
		assert_float((feet["foot_l"] as Transform3D).origin.y).override_failure_message("%s left ankle" % spec).is_equal_approx(want_l, 0.02)
		assert_float((feet["foot_l"] as Transform3D).origin.x).is_greater(0.0)
		# the pelvis went down by the step height, no more than the data allows
		var drop: float = (anim["pelvis"] as Transform3D).origin.y - (feet["pelvis"] as Transform3D).origin.y
		assert_float(drop).is_equal_approx(STEP_H, 0.01)
		assert_bool((c["rig"] as RigModifiers).feet.engaged).is_true()
		# the foot rotation is kept: the solver bending the knee does not tip the toes up
		var fr: Transform3D = feet["foot_r"]
		assert_float(rad_to_deg(fr.basis.y.angle_to((anim["foot_r"] as Transform3D).basis.y))).is_less(2.0)


func test_feet_follow_a_ramp_and_tilt_with_it() -> void:
	_floor()
	var slope: float = deg_to_rad(15.0)
	_box(Vector3(0.0, 0.0, 0.0), Vector3(3.0, 0.2, 2.0), Vector3(0, 0, slope))  # rises toward +x
	await _settle_physics()
	var c: Dictionary = _char("warblade_carnage", Vector3(0.0, 0.1 / cos(slope), 0.0), PI)
	_run(c, 1.0)
	var feet: Dictionary = _pose(c, ["foot_l", "foot_r"])
	var anim: Dictionary = _animated(c, ["foot_l", "foot_r"])
	var root_y: float = (c["root"] as Node3D).position.y
	for b: String in ["foot_l", "foot_r"]:
		var p: Vector3 = (feet[b] as Transform3D).origin
		var surface: float = 0.1 / cos(slope) + tan(slope) * p.x  # ramp height under the ankle
		var clearance: float = (anim[b] as Transform3D).origin.y - root_y
		assert_float(p.y).override_failure_message("%s on the ramp" % b).is_equal_approx(surface + clearance, 0.02)
	# the soles tilt toward the slope (feet turn about the heel-to-toe axis here)
	var tilt: float = rad_to_deg((feet["foot_l"] as Transform3D).basis.z.angle_to((anim["foot_l"] as Transform3D).basis.z))
	assert_float(tilt).is_between(8.0, 20.0)


func test_flat_ground_is_an_exact_no_op() -> void:
	_floor()
	await _settle_physics()
	var legs: PackedStringArray = ["pelvis", "thigh_l", "calf_l", "foot_l", "thigh_r", "calf_r", "foot_r"]
	var c: Dictionary = _char("oracle_grace", Vector3(2, 0, -3), 1.1)
	var facing: float = float(c["unit"]["facing"])
	for vel: Vector3 in [Vector3.ZERO, Movement.forward_of(facing) * 7.0, Movement.right_of(facing) * 7.0]:
		_run(c, 0.6, vel)
		(c["animator"] as CharacterAnimator).update(c["unit"], c["view"], vel, DT)
		var mod: Dictionary = (c["rig"] as RigModifiers).flush(legs)
		var feet: FootGrounding = (c["rig"] as RigModifiers).feet
		assert_bool(feet.engaged).is_false()
		assert_bool(feet.ik.active).is_false()
		assert_float(feet.pelvis_drop).is_equal(0.0)
		var sk: Skeleton3D = (c["rig"] as RigModifiers).skeleton
		for b: String in legs:
			var a: Transform3D = sk.get_bone_global_pose(sk.find_bone(b))
			var m: Transform3D = mod[b]
			assert_float(a.origin.distance_to(m.origin)).override_failure_message("%s moved" % b).is_less(1e-5)
			assert_bool(a.basis.is_equal_approx(m.basis)).is_true()
		assert_int(feet.rays_cast).is_greater(0)  # it did look at the floor


func test_every_arena_floor_is_level_so_grounding_never_engages() -> void:
	# the arenas so far are flat (data/maps): the feet must be left exactly as animated there,
	# at the spawns, next to the pillars and the gallows, and in the starting rooms
	for map_id: String in Data.maps:
		var builder: MapBuilder = auto_free(MapBuilder.new())
		builder.map_id = map_id
		builder.build_lighting = false
		add_child(builder)
		await _settle_physics()
		var spots: Array[Vector3] = [Vector3.ZERO]
		for team: String in Data.maps[map_id]["spawns"]:
			for s: Array in Data.maps[map_id]["spawns"][team]:
				spots.append(Vector3(float(s[0]), 0.0, float(s[2])))
		for col: Dictionary in Data.maps[map_id]["colliders"]:
			if col["type"] == "circle":  # right beside a pillar
				spots.append(Vector3(float(col["center"][0]) + float(col["radius"]) + 0.35, 0.0, float(col["center"][1])))
			elif col.get("tag", "") == "gallows":
				spots.append(Vector3(float(col["max"][0]) + 0.35, 0.0, 0.0))
		var c: Dictionary = _char("warblade_carnage", spots[0], 0.3)
		var feet: FootGrounding = (c["rig"] as RigModifiers).feet
		for p: Vector3 in spots:
			(c["root"] as Node3D).position = p
			c["unit"]["position"] = p
			_run(c, 0.25)
			assert_bool(feet.engaged).override_failure_message("%s at %s: offsets %s" % [map_id, p, feet.offsets]).is_false()
			assert_float(feet.pelvis_drop).is_equal(0.0)
		builder.queue_free()
		(c["root"] as Node3D).queue_free()
		await get_tree().process_frame


func test_feet_stay_planted_while_turning_in_place() -> void:
	_floor()
	await _settle_physics()
	var c: Dictionary = _char("warblade_carnage")
	_run(c, 0.5)
	var start: Dictionary = _pose(c, ["foot_l", "foot_r"])
	var root: Node3D = c["root"]
	var feet: FootGrounding = (c["rig"] as RigModifiers).feet
	assert_bool(feet.locked[0] and feet.locked[1]).is_true()
	# turn 15 degrees over a quarter second, as a keyboard turn does: the feet do not slide
	for i: int in 15:
		root.rotation.y += deg_to_rad(1.0)
		c["unit"]["facing"] = root.rotation.y
		_run(c, DT)
	var turned: Dictionary = _pose(c, ["foot_l", "foot_r"])
	var anim: Dictionary = _animated(c, ["foot_l", "foot_r"])
	for b: String in ["foot_l", "foot_r"]:
		var held: float = ((turned[b] as Transform3D).origin - (start[b] as Transform3D).origin).slide(Vector3.UP).length()
		var would: float = ((anim[b] as Transform3D).origin - (start[b] as Transform3D).origin).slide(Vector3.UP).length()
		assert_float(held).override_failure_message("%s slid %.3f m" % [b, held]).is_less(0.01)
		assert_float(would).is_greater(0.03)  # without the lock it would have slid
	# keep turning: past the limits one foot lets go at a time and returns to its animated place
	var both_free: bool = false
	for i: int in 90:
		root.rotation.y += deg_to_rad(1.0)
		c["unit"]["facing"] = root.rotation.y
		_run(c, DT)
		both_free = both_free or (not feet.locked[0] and not feet.locked[1])
	assert_bool(both_free).override_failure_message("both feet were off the floor at once").is_false()
	_run(c, 0.5)
	var settled: Dictionary = _pose(c, ["foot_l", "foot_r"])
	var anim2: Dictionary = _animated(c, ["foot_l", "foot_r"])
	for b: String in ["foot_l", "foot_r"]:
		assert_float((settled[b] as Transform3D).origin.distance_to((anim2[b] as Transform3D).origin)).is_less(0.17)
	# running releases the lock
	_run(c, 0.3, Movement.forward_of(root.rotation.y) * 7.0)
	assert_bool(feet.locked[0] or feet.locked[1]).is_false()


func test_grounding_is_off_in_the_air_and_when_dead() -> void:
	_floor()
	_box(Vector3(-1.0, STEP_H * 0.5, 0.0), Vector3(2.0, STEP_H, 2.0))
	await _settle_physics()
	var c: Dictionary = _char("warblade_carnage", Vector3(0.0, STEP_H, 0.0), PI)
	var rig: RigModifiers = c["rig"]
	_run(c, 0.5)
	assert_float(rig.foot_weight).is_equal(1.0)
	c["unit"]["position"] = Vector3(0, 1.0, 0)  # jumping
	_run(c, 0.3)
	assert_float(rig.foot_weight).is_equal(0.0)
	assert_bool(rig.feet.engaged).is_false()
	c["unit"]["position"] = Vector3.ZERO
	_run(c, 0.3)
	assert_float(rig.foot_weight).is_equal(1.0)
	c["unit"]["health"] = 0
	_run(c, 0.3)
	assert_float(rig.foot_weight).is_equal(0.0)


# ------------------------------------------------------------------ settings, LOD, data

func test_graphics_setting_and_distance_switch_everything_off() -> void:
	var c: Dictionary = _char("arcanist_rime")
	var rig: RigModifiers = c["rig"]
	_run(c, 0.2)
	assert_bool(rig.enabled).is_true()
	RigModifiers.use_settings({"graphics": {"rig_modifiers": false, "rig_modifier_max_distance_m": 35}})
	_run(c, 0.1)
	assert_bool(rig.enabled).is_false()
	for la: LookAtModifier3D in rig.look_bones:
		assert_bool(la.active).is_false()
	assert_bool(rig.feet.active).is_false()
	assert_bool(rig.feet.ik.active).is_false()
	RigModifiers.use_settings(Data.settings["default"])
	_run(c, 0.1)
	assert_bool(rig.enabled).is_true()
	# level of detail: a camera beyond the data's distance switches it off, a near one back on
	var cam: Camera3D = auto_free(Camera3D.new())
	add_child(cam)
	rig.camera = cam
	var limit: float = float(Data.settings["default"]["graphics"]["rig_modifier_max_distance_m"])
	cam.global_position = rig.skeleton.global_position + Vector3(0, 2, limit + 5.0)
	_run(c, 0.1)
	assert_bool(rig.enabled).is_false()
	cam.global_position = rig.skeleton.global_position + Vector3(0, 2, 8.0)
	_run(c, 0.1)
	assert_bool(rig.enabled).is_true()
	assert_float(rig.look_weight).is_equal(1.0)  # no fade from 0 when it comes back into range


func test_every_character_builds_the_modifier_chain_from_data() -> void:
	var cfg: Dictionary = Data.anim_states["humanoid"]["rig_modifiers"]
	for spec: String in ["warblade_carnage", "arcanist_rime", "oracle_grace"]:
		var c: Dictionary = _char(spec)
		var rig: RigModifiers = c["rig"]
		assert_int(rig.look_bones.size()).is_equal((cfg["look_at"]["bones"] as Array).size())
		for i: int in rig.look_bones.size():
			var b: Dictionary = cfg["look_at"]["bones"][i]
			assert_str(rig.look_bones[i].bone_name).is_equal(str(b["bone"]))
			assert_float(rig.look_bones[i].primary_limit_angle).is_equal_approx(deg_to_rad(float(b["yaw_limit_deg"])) * 2.0, 1e-4)
		var ik: TwoBoneIK3D = rig.feet.ik
		assert_int(ik.setting_count).is_equal(2)
		for i: int in 2:
			var leg: Dictionary = cfg["foot_ik"]["legs"][i]
			assert_str(ik.get_root_bone_name(i)).is_equal(str(leg["upper"]))
			assert_str(ik.get_end_bone_name(i)).is_equal(str(leg["foot"]))
		# order under the skeleton: grounding, solver, foot rotation, then the look-at bones
		var sk: Skeleton3D = rig.skeleton
		var order: Array[int] = [rig.feet.get_index(), ik.get_index(), rig.feet.align.get_index()]
		for la: LookAtModifier3D in rig.look_bones:
			order.append(la.get_index())
		for i: int in order.size() - 1:
			assert_int(order[i]).is_less(order[i + 1])
		assert_int(sk.modifier_callback_mode_process).is_equal(Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL)
