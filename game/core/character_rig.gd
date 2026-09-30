class_name CharacterRig
extends RefCounted
## Brings a built character to life (backlog M1-21): plays the shared animation library for its
## body build on its own skeleton and puts its weapon in its hand. Everything comes from data:
##   the character asset (data/assets, kind "character": body_build, params.weapon),
##   the library asset "anims_<build>" (kind "animation": out, params.set),
##   the animation set (data/animations/<set>.json: clip lengths, loop flags, weapon_grip).
## Usage: var player: AnimationPlayer = CharacterRig.setup(asset, model); player.play("run")

## Godot's glTF importer treats an animation whose name ends in one of these as looping and
## strips the suffix ("cast_loop" arrives as "cast"); clip names in data keep the suffix.
const IMPORT_LOOP_SUFFIXES: Array[String] = ["_loop", "-loop", "_cycle", "-cycle"]
const PLAYER_NAME: String = "AnimationPlayer"
const WEAPON_SLOT_NAME: String = "WeaponGrip"

## "<body build>/<hold>" -> {"library": AnimationLibrary, "rest": {bone: Transform3D}}
static var _cache: Dictionary = {}


## Adds an AnimationPlayer (with the build's clips, library name "") to the model and attaches
## its weapon. Returns the player, or null when the model has no skeleton or no library.
static func setup(asset: Dictionary, model: Node3D) -> AnimationPlayer:
	var sk: Skeleton3D = skeleton_of(model)
	if sk == null:
		Log.error("character_rig: %s has no skeleton" % asset.get("id", "?"))
		return null
	attach_weapon(asset, sk)
	var build: String = str(asset.get("body_build", ""))
	var entry: Dictionary = _library_entry(build, hold_of(asset))
	if entry.is_empty():
		return null
	_check_rest(asset, sk, entry["rest"])
	var player: AnimationPlayer = AnimationPlayer.new()
	player.name = PLAYER_NAME
	model.add_child(player)
	player.root_node = player.get_path_to(sk)  # tracks are "<.:bone>" relative to the skeleton
	player.add_animation_library("", entry["library"])
	return player


static func skeleton_of(model: Node) -> Skeleton3D:
	var found: Array[Node] = model.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null


static func res_path(asset: Dictionary) -> String:
	return "res://" + str(asset.get("out", "")).trim_prefix("game/")


## The animation-library asset for a body build (data/assets, kind "animation"), or empty.
static func animation_asset(build: String) -> Dictionary:
	for a: Dictionary in Data.assets.values():
		if a.get("kind", "") == "animation" and a.get("body_build", "") == build:
			return a
	return {}


## The animation set (data/animations) a body build's library was baked from, or empty.
static func animation_set(build: String) -> Dictionary:
	var lib: Dictionary = animation_asset(build)
	return Data.animations.get(str(lib.get("params", {}).get("set", "")), {})


## Name of a data clip inside an imported library (see IMPORT_LOOP_SUFFIXES), or "".
static func source_name(names: PackedStringArray, clip: String) -> String:
	if clip in names:
		return clip
	for suffix: String in IMPORT_LOOP_SUFFIXES:
		if clip.ends_with(suffix) and clip.trim_suffix(suffix) in names:
			return clip.trim_suffix(suffix)
	return ""


## How a character holds its weapon (the weapon asset's params.hold; "forward" by default).
static func hold_of(asset: Dictionary) -> String:
	var weapon: Dictionary = Data.assets.get(str(asset.get("params", {}).get("weapon", "")), {})
	return str(weapon.get("params", {}).get("hold", "forward"))


## Library clip name for a data clip and hold: holds with a hand rule (weapon_grip.holds.<hold>.
## wrist, e.g. an upright staff, or second_hand, a two-handed sword) have their own baked copy of
## every clip, "<clip>_<hold>".
static func variant_name(set_data: Dictionary, clip: String, hold: String) -> String:
	var holds: Dictionary = set_data.get("weapon_grip", {}).get("holds", {})
	var h: Dictionary = holds.get(hold, {})
	return "%s_%s" % [clip, hold] if h.has("wrist") or h.has("second_hand") else clip


## The retargeted, loop-flagged library for a body build and weapon hold, with clips under their
## data names (cached; shared by all characters of that build and hold).
static func library(build: String, hold: String = "forward") -> AnimationLibrary:
	var entry: Dictionary = _library_entry(build, hold)
	return entry.get("library", null)


static func _library_entry(build: String, hold: String) -> Dictionary:
	var key: String = "%s/%s" % [build, hold]
	if _cache.has(key):
		return _cache[key]
	var spec: Dictionary = animation_asset(build)
	var set_data: Dictionary = animation_set(build)
	if spec.is_empty() or set_data.is_empty() or not ResourceLoader.exists(res_path(spec)):
		Log.error("character_rig: no animation library for body build '%s'" % build)
		return {}
	var source: Node = (load(res_path(spec)) as PackedScene).instantiate()
	var players: Array[Node] = source.find_children("*", "AnimationPlayer", true, false)
	var src_sk: Skeleton3D = skeleton_of(source)
	if players.is_empty() or src_sk == null:
		Log.error("character_rig: %s has no AnimationPlayer or skeleton" % spec["out"])
		source.free()
		return {}
	var src_player: AnimationPlayer = players[0]
	var names: PackedStringArray = src_player.get_animation_list()
	var fps: float = float(set_data.get("fps", 30))
	var lib: AnimationLibrary = AnimationLibrary.new()
	var clips: Dictionary = set_data.get("clips", {})
	for clip: String in clips:
		var src_name: String = source_name(names, variant_name(set_data, clip, hold))
		if src_name == "":
			Log.error("character_rig: %s has no clip '%s'" % [spec["out"], variant_name(set_data, clip, hold)])
			continue
		var anim: Animation = src_player.get_animation(src_name).duplicate(true)
		_retarget(anim)
		anim.loop_mode = Animation.LOOP_LINEAR if bool(clips[clip].get("loop", false)) else Animation.LOOP_NONE
		_fit_length(anim, float(clips[clip]["length_s"]), fps, "%s:%s" % [spec["id"], clip])
		lib.add_animation(clip, anim)
	var rest: Dictionary = {}
	for i: int in src_sk.get_bone_count():
		rest[src_sk.get_bone_name(i)] = src_sk.get_bone_rest(i)
	source.free()
	var entry: Dictionary = {"library": lib, "rest": rest}
	_cache[key] = entry
	return entry


## Points every bone track at the skeleton the player's root_node names (paths ".:<bone>"),
## whatever the armature node is called; drops tracks that do not target a bone.
static func _retarget(anim: Animation) -> void:
	for t: int in range(anim.get_track_count() - 1, -1, -1):
		var bone: String = str(anim.track_get_path(t).get_concatenated_subnames())
		var kind: Animation.TrackType = anim.track_get_type(t)
		var is_bone_track: bool = kind in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D]
		if bone == "" or not is_bone_track:
			anim.remove_track(t)
			continue
		anim.track_set_path(t, NodePath(".:" + bone))


## Data is the source of truth for clip length. An imported clip that is off by more than half a
## frame means the library was exported at the wrong frame rate: report it (the asset validator
## and test_animations catch the same thing) rather than silently stretching it.
static func _fit_length(anim: Animation, length_s: float, fps: float, label: String) -> void:
	if absf(anim.length - length_s) > 0.5 / fps:
		Log.error("character_rig: %s is %.3f s, data says %.3f s; rebuild the animation library" % [
			label, anim.length, length_s])
		return
	anim.length = length_s


static func _check_rest(asset: Dictionary, sk: Skeleton3D, rest: Dictionary) -> void:
	for bone: String in rest:
		var i: int = sk.find_bone(bone)
		if i == -1:
			Log.warn("character_rig: %s has no bone %s" % [asset.get("id", "?"), bone])
			continue
		var a: Transform3D = sk.get_bone_rest(i)
		var b: Transform3D = rest[bone]
		if a.origin.distance_to(b.origin) > 0.001 or not a.basis.is_equal_approx(b.basis):
			Log.warn("character_rig: %s bone %s rest differs from its animation library" % [
				asset.get("id", "?"), bone])


## Blender character space (-Y forward, +Z up) to Godot model space (+Z forward, +Y up).
static func blender_to_godot(v: Array) -> Vector3:
	return Vector3(float(v[0]), float(v[2]), -float(v[1]))


## The held weapon's rest transform relative to the grip bone's global rest (for a child of a
## BoneAttachment3D on that bone). Mirrors grip_matrix in tools/blender/build_animations.py:
## start at the bone's head, go along_m along the bone and palm_m toward the palm; the weapon's
## blade axis (its local +Y) follows the hold's blade direction and its flat normal (local -Z)
## the hold's flat direction.
## along_m and palm_m are per body build (the fist's size differs between builds).
static func grip_transform(sk: Skeleton3D, grip: Dictionary, hold: String, build: String) -> Transform3D:
	var bone_name: String = str(grip["bone"])
	var rest: Transform3D = sk.get_bone_global_rest(sk.find_bone(bone_name))
	var along: Vector3 = rest.basis.y.normalized()  # imported bones keep Blender's frame: +Y runs head to tail
	var inward: Vector3 = Vector3.RIGHT if bone_name.ends_with("_r") else Vector3.LEFT
	var palm: Vector3 = (inward - along * along.dot(inward)).normalized()
	var point: Vector3 = rest.origin + along * float(grip["along_m"][build]) + palm * float(grip["palm_m"][build])
	var h: Dictionary = grip["holds"][hold]
	var blade: Vector3 = blender_to_godot(h["blade"]).normalized()
	point -= blade * float(h.get("slide_m", 0.0))  # two-handed: slid down so the first fist sits near the guard
	var flat: Vector3 = blender_to_godot(h["flat"])
	flat = (flat - blade * blade.dot(flat)).normalized()
	var z: Vector3 = -flat
	var held: Transform3D = Transform3D(Basis(blade.cross(z), blade, z), point)
	return rest.affine_inverse() * held


## Puts the character's weapon (params.weapon) in its hand, following the animated bone.
## Returns the weapon node, or null when the character has none or it is not built.
static func attach_weapon(asset: Dictionary, sk: Skeleton3D) -> Node3D:
	var weapon: Dictionary = Data.assets.get(str(asset.get("params", {}).get("weapon", "")), {})
	var grip: Dictionary = animation_set(str(asset.get("body_build", ""))).get("weapon_grip", {})
	if weapon.is_empty() or grip.is_empty() or not ResourceLoader.exists(res_path(weapon)):
		return null
	var slot: BoneAttachment3D = BoneAttachment3D.new()
	slot.name = WEAPON_SLOT_NAME
	slot.bone_name = str(grip["bone"])
	sk.add_child(slot)
	var node: Node3D = (load(res_path(weapon)) as PackedScene).instantiate()
	node.transform = grip_transform(sk, grip, str(weapon.get("params", {}).get("hold", "forward")),
		str(asset.get("body_build", "")))
	slot.add_child(node)
	return node
