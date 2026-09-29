extends GdUnitTestSuite
## Shared animation libraries (backlog M1-21): both body builds import with every clip of the
## animation set at its data length, retarget onto every character's own skeleton, loop as the
## data says, drive the bones, and put each weapon in the right hand the data-driven way.

const LIBRARIES: Array[String] = ["anims_heavy", "anims_lean"]
const CHARACTERS: Array[String] = ["char_warblade_carnage", "char_arcanist_rime", "char_oracle_grace"]


func _anim_set() -> Dictionary:
	return Data.animations["humanoid"]


func _frame() -> float:
	return 1.0 / float(_anim_set().get("fps", 30))


func _model(char_id: String) -> Node3D:
	var asset: Dictionary = Data.assets[char_id]
	assert_bool(ResourceLoader.exists(CharacterRig.res_path(asset))).override_failure_message(
		"%s not built" % char_id).is_true()
	return auto_free((load(CharacterRig.res_path(asset)) as PackedScene).instantiate())


## Skeleton transform in model space (the armature node may carry a transform of its own).
func _skeleton_in_model(model: Node3D, sk: Skeleton3D) -> Transform3D:
	var t: Transform3D = Transform3D.IDENTITY
	var n: Node = sk
	while n != model and n is Node3D:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


func test_libraries_hold_every_clip_at_its_data_length() -> void:
	var clips: Dictionary = _anim_set()["clips"]
	for lib_id: String in LIBRARIES:
		var spec: Dictionary = Data.assets[lib_id]
		assert_str(spec.get("kind", "")).is_equal("animation")
		var path: String = CharacterRig.res_path(spec)
		assert_bool(ResourceLoader.exists(path)).override_failure_message("%s not imported" % path).is_true()
		var root: Node = auto_free((load(path) as PackedScene).instantiate())
		var player: AnimationPlayer = root.find_children("*", "AnimationPlayer", true, false)[0]
		var names: PackedStringArray = player.get_animation_list()
		for clip: String in clips:
			var src: String = CharacterRig.source_name(names, clip)
			assert_str(src).override_failure_message("%s: no clip %s" % [lib_id, clip]).is_not_empty()
			if src == "":
				continue
			var length: float = player.get_animation(src).length
			var want: float = float(clips[clip]["length_s"])
			assert_float(length).override_failure_message("%s:%s is %.3f s, data says %.3f s" % [
				lib_id, clip, length, want]).is_equal_approx(want, _frame())


func test_retargeted_tracks_resolve_on_every_character() -> void:
	var clips: Dictionary = _anim_set()["clips"]
	for char_id: String in CHARACTERS:
		var model: Node3D = _model(char_id)
		var player: AnimationPlayer = CharacterRig.setup(Data.assets[char_id], model)
		assert_object(player).override_failure_message("%s: no player" % char_id).is_not_null()
		var sk: Skeleton3D = CharacterRig.skeleton_of(model)
		var target: Node = player.get_node(player.root_node)
		assert_object(target).is_same(sk)
		for clip: String in clips:
			assert_bool(player.has_animation(clip)).override_failure_message("%s: no %s" % [char_id, clip]).is_true()
			var anim: Animation = player.get_animation(clip)
			assert_int(anim.get_track_count()).is_greater(0)
			for t: int in anim.get_track_count():
				var path: NodePath = anim.track_get_path(t)
				var bone: String = str(path.get_concatenated_subnames())
				var node: Node = target.get_node_or_null(NodePath(str(path).get_slice(":", 0)))
				assert_object(node).override_failure_message("%s:%s track %s: no node" % [char_id, clip, path]).is_same(sk)
				assert_int(sk.find_bone(bone)).override_failure_message(
					"%s:%s track %s: no bone" % [char_id, clip, path]).is_not_equal(-1)


func test_loop_modes_and_lengths_follow_the_data() -> void:
	var clips: Dictionary = _anim_set()["clips"]
	for build: String in ["heavy", "lean"]:
		var lib: AnimationLibrary = CharacterRig.library(build)
		assert_object(lib).is_not_null()
		for clip: String in clips:
			var anim: Animation = lib.get_animation(clip)
			var want: Animation.LoopMode = Animation.LOOP_LINEAR if bool(clips[clip]["loop"]) else Animation.LOOP_NONE
			assert_int(anim.loop_mode).override_failure_message("%s:%s loop mode %d" % [
				build, clip, anim.loop_mode]).is_equal(want)
			assert_float(anim.length).is_equal_approx(float(clips[clip]["length_s"]), _frame())


func test_weapons_sit_in_the_right_hand_at_rest() -> void:
	var grip: Dictionary = _anim_set()["weapon_grip"]
	# greatsword held forward, staff held upright (weapon_*.json params.hold)
	var expect: Dictionary = {"char_warblade_carnage": Vector3(0, 0, 1), "char_arcanist_rime": Vector3(0, 1, 0)}
	for char_id: String in expect:
		var model: Node3D = _model(char_id)
		var sk: Skeleton3D = CharacterRig.skeleton_of(model)
		var weapon: Node3D = CharacterRig.attach_weapon(Data.assets[char_id], sk)
		assert_object(weapon).override_failure_message("%s: no weapon" % char_id).is_not_null()
		var bone_rest: Transform3D = sk.get_bone_global_rest(sk.find_bone(str(grip["bone"])))
		var in_model: Transform3D = _skeleton_in_model(model, sk) * bone_rest * weapon.transform
		var blade: Vector3 = in_model.basis.y.normalized()
		var angle: float = rad_to_deg(blade.angle_to(expect[char_id]))
		assert_float(angle).override_failure_message("%s: blade %s is %.1f deg off %s" % [
			char_id, blade, angle, expect[char_id]]).is_less(10.0)
		var hand_head: Vector3 = (_skeleton_in_model(model, sk) * bone_rest).origin
		var dist: float = in_model.origin.distance_to(hand_head)
		assert_float(dist).override_failure_message("%s: grip %.3f m from the hand" % [char_id, dist]).is_less(0.12)


func test_run_drives_the_skeleton() -> void:
	var model: Node3D = _model("char_warblade_carnage")
	add_child(model)  # the player processes and applies poses only inside the tree
	var player: AnimationPlayer = CharacterRig.setup(Data.assets["char_warblade_carnage"], model)
	var sk: Skeleton3D = CharacterRig.skeleton_of(model)
	var bone: int = sk.find_bone("thigh_r")
	var rest: Quaternion = sk.get_bone_rest(bone).basis.get_rotation_quaternion()
	player.play("run")
	player.seek(0.18, true)
	var posed: Quaternion = sk.get_bone_pose_rotation(bone)
	var deg: float = rad_to_deg(rest.angle_to(posed))
	assert_float(deg).override_failure_message("thigh_r moved only %.1f deg" % deg).is_greater(5.0)
	# the weapon follows the hand: its world position moves with the pose
	var weapon: Node3D = sk.get_node(CharacterRig.WEAPON_SLOT_NAME).get_child(0)
	var at_run: Vector3 = weapon.global_position
	player.play("attack_1")
	player.seek(0.28, true)
	sk.force_update_all_bone_transforms()
	(sk.get_node(CharacterRig.WEAPON_SLOT_NAME) as BoneAttachment3D).on_skeleton_update()
	assert_float(weapon.global_position.distance_to(at_run)).is_greater(0.1)


## An upright staff stays upright while its wielder runs: the hold's wrist rule (baked into the
## "<clip>_upright" variants) cancels the arm's swing and elbow bend.
func test_upright_staff_stays_upright_while_running() -> void:
	var asset: Dictionary = Data.assets["char_arcanist_rime"]
	assert_str(CharacterRig.hold_of(asset)).is_equal("upright")
	var model: Node3D = _model("char_arcanist_rime")
	add_child(model)
	var player: AnimationPlayer = CharacterRig.setup(asset, model)
	var sk: Skeleton3D = CharacterRig.skeleton_of(model)
	var slot: BoneAttachment3D = sk.get_node(CharacterRig.WEAPON_SLOT_NAME)
	var staff: Node3D = slot.get_child(0)
	player.play("run")
	var length: float = player.get_animation("run").length
	var worst: float = 0.0
	for i: int in 8:
		player.seek(length * i / 8.0, true)
		sk.force_update_all_bone_transforms()
		slot.on_skeleton_update()
		var up: Vector3 = model.global_transform.basis.inverse() * staff.global_transform.basis.y
		worst = maxf(worst, rad_to_deg(up.angle_to(Vector3.UP)))
	assert_float(worst).override_failure_message("staff tilts %.1f deg from vertical" % worst).is_less(30.0)
