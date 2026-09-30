class_name RigModifiers
extends Node
## Runtime polish on top of a character's animation (backlog X-02), from Godot's built-in skeleton
## modifiers, configured by the states data (data/anim_states/<set>.json, "rig_modifiers"):
##   look-at  one LookAtModifier3D per bone of look_at.bones (chest, neck, head): each turns its
##            bone toward one look marker, by its share (influence) and within its own limits.
##            The marker is placed here: toward the target's head, else ahead along the facing
##            (leaning into the direction of movement), clamped to max_yaw/pitch around the body's
##            facing, given up (look ahead) past give_up_deg, and eased with time constant turn_s
##            in world space, so the head leads when the body turns. Blends to 0 while the
##            animator plays a clip of look_at.suppress (crowd control, death, big swings).
##   feet     FootGrounding + TwoBoneIK3D + FootAlign (see foot_grounding.gd): feet on uneven
##            floors, pelvis lowered for the lower foot, foot lock while standing. Off while
##            airborne or during a clip of foot_ik.suppress.
## Everything switches off with the graphics setting rig_modifiers (data/settings) and beyond
## rig_modifier_max_distance_m from the camera; off means no modifier runs at all.
## The skeleton's modifiers are processed manually (like the AnimationTree): CharacterAnimator
## calls update() after advancing its tree, so paused scenes hold still and tests are exact.

## Per-frame work is kept small (up to 20 characters on screen): data values are read once into
## typed fields, the graphics setting is cached, and a character with everything off runs no
## modifier at all.

const MARKER_NAME: String = "LookTarget"

## Graphics settings used by every rig (data/settings/<profile>.json "graphics"); the settings
## screen or the practice scene replaces them with use_settings().
static var graphics: Dictionary = {}:
	set(value):
		graphics = value
		_gfx_loaded = false
static var _gfx_loaded: bool = false
static var _gfx_on: bool = true
static var _gfx_max_distance: float = INF

var cfg: Dictionary = {}  ## rig_modifiers section of the states data
var skeleton: Skeleton3D
var look_bones: Array[LookAtModifier3D] = []
var look_shares: PackedFloat32Array = []
var feet: FootGrounding
var look_marker: Marker3D
var look_weight: float = 0.0  ## 0..1 after suppression blending
var look_dir: Vector3 = Vector3.ZERO  ## eased world direction of the look marker from the head
var look_goal: String = "ahead"  ## "target", "override", "moving", "ahead" (tests, debugging)
var enabled: bool = true  ## graphics setting, distance and `allowed`, combined
var allowed: bool = true  ## per character switch (review scenes compare with and without)
var foot_weight: float = 0.0
## Camera used for the distance cut-off; null: the viewport's current camera, none: always near.
var camera: Camera3D
## World direction to look in when there is no target (e.g. the local player's camera), or ZERO.
var look_override: Vector3 = Vector3.ZERO

var _head: int = -1
var _first: bool = true
var _poses: Dictionary = {}  ## bone name -> modified global pose, when capturing
var _capture: PackedStringArray = []
# look_at data, read once (angles in radians)
var _max_yaw: float
var _pitch_up: float
var _pitch_down: float
var _give_up: float
var _target_h: float
var _min_target_d: float
var _marker_d: float
var _turn_s: float
var _in_s: float
var _out_s: float
var _mv_share: float
var _mv_max: float
var _mv_min_speed: float
var _look_suppress: Dictionary = {}  ## clip -> true
# foot_ik data
var _foot_blend_s: float
var _foot_suppress: Dictionary = {}


## The graphics section in use (the default profile's unless use_settings was called).
static func graphics_settings() -> Dictionary:
	if graphics.is_empty():
		return Data.settings.get("default", {}).get("graphics", {})
	return graphics


static func use_settings(profile: Dictionary) -> void:
	graphics = profile.get("graphics", {})


static func _load_graphics() -> void:
	var g: Dictionary = graphics_settings()
	_gfx_on = bool(g.get("rig_modifiers", true))
	_gfx_max_distance = float(g.get("rig_modifier_max_distance_m", INF))
	_gfx_loaded = true


## Builds the modifiers under the skeleton next to `player` (CharacterRig.setup). Returns null when
## the data has no rig_modifiers section or the skeleton lacks a bone it names.
static func create(p_player: AnimationPlayer, p_cfg: Dictionary) -> RigModifiers:
	if p_cfg.is_empty():
		return null
	var sk: Skeleton3D = CharacterRig.skeleton_of(p_player.get_parent())
	if sk == null:
		return null
	var r: RigModifiers = RigModifiers.new()
	r.name = "RigModifiers"
	r.cfg = p_cfg
	r.skeleton = sk
	p_player.get_parent().add_child(r)
	if not r._build():
		r.queue_free()
		return null
	return r


func _build() -> bool:
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var foot_cfg: Dictionary = cfg.get("foot_ik", {})
	if not foot_cfg.is_empty():
		feet = FootGrounding.build(skeleton, foot_cfg)
		if feet == null:
			return false
		_foot_blend_s = float(foot_cfg["blend_s"])
		for c: Variant in foot_cfg["suppress"]:
			_foot_suppress[str(c)] = true
	var look: Dictionary = cfg.get("look_at", {})
	if not look.is_empty():
		_read_look(look)
		look_marker = Marker3D.new()
		look_marker.name = MARKER_NAME
		add_child(look_marker)
		look_marker.top_level = true
		for b: Dictionary in look["bones"]:
			if skeleton.find_bone(str(b["bone"])) == -1:
				Log.error("rig_modifiers: no bone '%s'" % b["bone"])
				return false
			var la: LookAtModifier3D = LookAtModifier3D.new()
			la.name = "Look_" + str(b["bone"])
			skeleton.add_child(la)
			la.bone_name = str(b["bone"])
			la.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_Z  # standard skeleton: bones face +Z, run along +Y
			la.primary_rotation_axis = Vector3.AXIS_Y
			la.use_secondary_rotation = true
			la.relative = true  # limits around the animated pose, so clips keep their head motion
			la.use_angle_limitation = true
			la.symmetry_limitation = true
			la.primary_limit_angle = deg_to_rad(float(b["yaw_limit_deg"])) * 2.0  # full range
			la.secondary_limit_angle = deg_to_rad(float(b["pitch_limit_deg"])) * 2.0
			la.duration = 0.0  # easing is done on the marker
			la.target_node = la.get_path_to(look_marker)
			la.influence = 0.0
			look_bones.append(la)
			look_shares.append(float(b["share"]))
		_head = skeleton.find_bone(str(look["bones"][-1]["bone"]))
	apply_settings()
	return true


func _read_look(look: Dictionary) -> void:
	_max_yaw = deg_to_rad(float(look["max_yaw_deg"]))
	_pitch_up = deg_to_rad(float(look["max_pitch_up_deg"]))
	_pitch_down = deg_to_rad(float(look["max_pitch_down_deg"]))
	_give_up = deg_to_rad(float(look["give_up_deg"]))
	_target_h = float(look["target_height_m"])
	_min_target_d = float(look["min_target_distance_m"])
	_marker_d = float(look["marker_distance_m"])
	_turn_s = float(look["turn_s"])
	_in_s = float(look["blend_in_s"])
	_out_s = float(look["blend_out_s"])
	_mv_share = float(look["moving"]["share"])
	_mv_max = deg_to_rad(float(look["moving"]["max_deg"]))
	_mv_min_speed = float(look["moving"]["min_speed_mps"])
	for c: Variant in look["suppress"]:
		_look_suppress[str(c)] = true


## Re-reads the graphics setting (after the settings screen changed it with use_settings).
func apply_settings() -> void:
	_gfx_loaded = false
	_set_enabled(_wanted())


func _wanted() -> bool:
	if not _gfx_loaded:
		_load_graphics()
	return allowed and _gfx_on and _near()


## Advance by `delta`: `u` is the unit's view entry, `view` the whole view, `state` what the
## animator plays ({"clips": [override, action], "airborne": bool, "standing": bool,
## "velocity": ground velocity in m/s}).
## Then processes the skeleton's modifiers (manual mode).
func update(u: Dictionary, view: Dictionary, state: Dictionary, delta: float) -> void:
	var on: bool = _wanted()
	if on != enabled:
		_set_enabled(on)
	if enabled:
		var clips: Array = state["clips"]
		if not look_bones.is_empty():
			_update_look(u, view, clips, state["velocity"], delta)
		if feet != null:
			var want: float = 0.0 if bool(state["airborne"]) or _any_in(_foot_suppress, clips) else 1.0
			foot_weight = want if _first else _approach(foot_weight, want, delta, _foot_blend_s)
			feet.weight = foot_weight
			feet.lock_wanted = bool(state["standing"])
		_first = false
	skeleton.advance(delta)


## Processes the modifiers now instead of at the end of the frame, and returns the modified global
## poses (skeleton space) of `bones` (tests and review tools; the skeleton restores the unmodified
## pose right after rendering, so these are only readable while it updates).
func flush(bones: PackedStringArray) -> Dictionary:
	_capture = bones
	_poses = {}
	if not bones.is_empty() and not skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		skeleton.skeleton_updated.connect(_on_skeleton_updated)
	skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	return _poses


func _on_skeleton_updated() -> void:
	for b: String in _capture:
		_poses[b] = skeleton.get_bone_global_pose(skeleton.find_bone(b))


func _set_enabled(on: bool) -> void:
	enabled = on
	for la: LookAtModifier3D in look_bones:
		la.active = on
	if feet != null:
		feet.set_enabled(on)
	if not on:
		look_weight = 0.0
		foot_weight = 0.0
		_first = true  # when it comes back, it starts where it should be rather than blending from 0


func _near() -> bool:
	if _gfx_max_distance == INF:
		return true
	var cam: Camera3D = camera
	if cam == null and is_inside_tree():
		cam = get_viewport().get_camera_3d()
	if cam == null or not skeleton.is_inside_tree():
		return true
	return cam.global_position.distance_squared_to(skeleton.global_position) <= _gfx_max_distance * _gfx_max_distance


static func _any_in(set_of: Dictionary, clips: Array) -> bool:
	for c: Variant in clips:
		if set_of.has(c):
			return true
	return false


static func _approach(cur: float, target: float, delta: float, secs: float) -> float:
	return target if secs <= 0.0 else move_toward(cur, target, delta / secs)


func _update_look(u: Dictionary, view: Dictionary, clips: Array, velocity: Vector3, delta: float) -> void:
	var want_w: float = 0.0 if _any_in(_look_suppress, clips) else 1.0
	look_weight = want_w if _first else _approach(look_weight, want_w, delta, _in_s if want_w > look_weight else _out_s)
	for i: int in look_bones.size():
		look_bones[i].influence = look_shares[i] * look_weight
	var sg: Transform3D = skeleton.global_transform
	var fwd: Vector3 = sg.basis.z.normalized()  # standard skeleton faces +Z
	var up: Vector3 = sg.basis.y.normalized()
	var side: Vector3 = up.cross(fwd)  # skeleton +X, the character's left
	var eye: Vector3 = sg * skeleton.get_bone_global_pose(_head).origin
	var goal: Vector3 = _clamp_direction(_goal_direction(u, view, velocity, eye, fwd, up), fwd, up, side)
	if _first or look_dir == Vector3.ZERO:
		look_dir = goal
	else:
		var t: float = 1.0 - exp(-delta / _turn_s) if _turn_s > 0.0 else 1.0
		look_dir = _clamp_direction(look_dir.slerp(goal, t), fwd, up, side)  # the body may have turned meanwhile
	look_marker.global_position = eye + look_dir * _marker_d


## Where the character wants to look (world direction from its eyes).
func _goal_direction(u: Dictionary, view: Dictionary, velocity: Vector3, eye: Vector3, fwd: Vector3, up: Vector3) -> Vector3:
	var tid: int = int(u.get("target_id", -1))
	if tid >= 0 and tid != int(u["id"]):
		for other: Dictionary in view["units"]:
			if int(other["id"]) == tid:
				var to: Vector3 = (other["position"] as Vector3) + up * _target_h - eye
				if to.slide(up).length_squared() > _min_target_d * _min_target_d:
					look_goal = "target"
					return to.normalized()
				break
	if look_override != Vector3.ZERO:
		look_goal = "override"
		return look_override.normalized()
	var vel: Vector3 = velocity.slide(up)
	if vel.length_squared() > _mv_min_speed * _mv_min_speed and fwd.angle_to(vel) <= _mv_max:
		look_goal = "moving"
		return fwd.slerp(vel.normalized(), _mv_share).normalized()
	look_goal = "ahead"
	return fwd


## Limits a world direction to max_yaw/pitch around the body's facing; past give_up_deg the
## character looks straight ahead instead.
func _clamp_direction(d: Vector3, fwd: Vector3, up: Vector3, side: Vector3) -> Vector3:
	var yaw: float = atan2(d.dot(side), d.dot(fwd))
	var pitch: float = asin(clampf(d.dot(up), -1.0, 1.0))
	if absf(yaw) > _give_up:
		return fwd
	yaw = clampf(yaw, -_max_yaw, _max_yaw)
	pitch = clampf(pitch, -_pitch_down, _pitch_up)
	var cp: float = cos(pitch)
	return fwd * (cos(yaw) * cp) + side * (sin(yaw) * cp) + up * sin(pitch)
