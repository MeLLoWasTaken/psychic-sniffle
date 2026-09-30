class_name FootGrounding
extends SkeletonModifier3D
## Foot grounding for one character (backlog X-02), the first of three skeleton modifiers that
## RigModifiers puts under the skeleton, in this order:
##   FootGrounding  casts a ray down at each animated ankle, lowers the pelvis when a foot must go
##                  down, and places the IK target and pole markers of both legs
##   TwoBoneIK3D    Godot's two-bone solver (thigh, calf, foot) reaching for those targets
##   FootAlign      gives each foot the rotation chosen here (the animated one, tilted to the
##                  slope, or held while locked); the solver would otherwise swing it with the calf
## Heights are relative to the character's origin (its feet): a floor level with the origin gives
## an offset of 0, and when every offset is 0 and no foot is held away from its animated place the
## solver and FootAlign are switched off, so flat ground is an exact no-op.
## Foot lock: while `lock_wanted` (standing), each foot keeps its place and heading on the floor
## as the body turns; past max_slide_m or max_turn_deg the foot farthest off lets go and eases
## back to its animated place over release_s, one foot at a time.
## A foot whose ray start moved less than RAY_REUSE_M since its last ray reuses that hit, so
## standing characters cast no rays. All numbers come from the states data (rig_modifiers.foot_ik).

const SIDES: int = 2
const POLE_SURE_BEND_M: float = 0.08  ## knee this far off the hip-ankle line: its bend plane is trusted
## A locked foot closer than this to its animated place needs no solver (flat ground stays a no-op).
const LOCK_STILL_M: float = 0.001
const LOCK_STILL_RAD: float = 0.005
## A foot this many times max_slide_m from its lock was carried by a teleport: it relocks at once.
const TELEPORT_SLIDES: float = 3.0
const RAY_REUSE_M: float = 0.01

var cfg: Dictionary = {}  ## rig_modifiers.foot_ik
var ik: TwoBoneIK3D
var align: FootAlign
var weight: float = 0.0  ## 0..1, set every frame by RigModifiers (airborne, death, LOD blend to 0)
var lock_wanted: bool = false  ## standing: lock the feet where they are
## Floor query override: func(from: Vector3, to: Vector3) -> Dictionary with "position" and
## "normal" (world), or empty for no floor. Unset: a physics ray on the data's ground layers.
var ground_query: Callable

## Per leg (index 0 = the first leg in data, the left): results of the last pass, read by tests
## and FootAlign.
var offsets: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])  ## smoothed floor offset (m)
var pelvis_drop: float = 0.0  ## smoothed pelvis lowering (m, >= 0)
var foot_basis: Array[Basis] = [Basis(), Basis()]  ## wanted foot rotation, skeleton space
var locked: Array[bool] = [false, false]
var lock_weight: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var engaged: bool = false  ## the solver ran this pass (false: exact no-op)
var rays_cast: int = 0  ## total rays (performance checks)

var _pelvis: int = -1
var _bones: PackedInt32Array = []  ## per leg: upper, lower, foot
var _targets: Array[Marker3D] = []
var _poles: Array[Marker3D] = []
var _lock_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]  ## world
var _lock_basis: Array[Basis] = [Basis(), Basis()]  ## world
var _releasing: int = -1
var _lock_moves: Array[bool] = [false, false]  ## the lock holds the foot away from its animated place
var _ray_from: Array[Vector3] = [Vector3.INF, Vector3.INF]  ## world start of each foot's last ray
var _ray_off: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _ray_normal: Array[Vector3] = [Vector3.UP, Vector3.UP]
var _query: PhysicsRayQueryParameters3D
# data, read once
var _ray_up: float
var _ray_down: float
var _dead: float
var _smooth_s: float
var _pelvis_smooth_s: float
var _max_drop: float
var _max_raise: float
var _max_pelvis_drop: float
var _tilt_max: float
var _lock_on: bool
var _lock_release_s: float
var _lock_slide: float
var _lock_turn: float


## Builds the three modifiers under `sk` (FootGrounding, TwoBoneIK3D, FootAlign) from the data's
## foot_ik section. Returns the grounding node, or null when a bone is missing.
static func build(sk: Skeleton3D, p_cfg: Dictionary) -> FootGrounding:
	var g: FootGrounding = FootGrounding.new()
	g.name = "FootGrounding"
	g.cfg = p_cfg
	g._pelvis = sk.find_bone(str(p_cfg["pelvis"]))
	if g._pelvis == -1:
		Log.error("foot_grounding: no pelvis bone '%s'" % p_cfg["pelvis"])
		g.free()
		return null
	for leg: Dictionary in p_cfg["legs"]:
		for key: String in ["upper", "lower", "foot"]:
			var idx: int = sk.find_bone(str(leg[key]))
			if idx == -1:
				Log.error("foot_grounding: no bone '%s'" % leg[key])
				g.free()
				return null
			g._bones.append(idx)
	g._read(p_cfg)
	sk.add_child(g)
	g.ik = TwoBoneIK3D.new()
	g.ik.name = "FootIK"
	sk.add_child(g.ik)
	g.ik.setting_count = SIDES
	for i: int in SIDES:
		var target: Marker3D = Marker3D.new()
		target.name = "FootTarget%d" % i
		g.add_child(target)
		var pole: Marker3D = Marker3D.new()
		pole.name = "KneePole%d" % i
		g.add_child(pole)
		g._targets.append(target)
		g._poles.append(pole)
		var leg: Dictionary = p_cfg["legs"][i]
		g.ik.set_root_bone_name(i, str(leg["upper"]))
		g.ik.set_middle_bone_name(i, str(leg["lower"]))
		g.ik.set_end_bone_name(i, str(leg["foot"]))
		g.ik.set_target_node(i, g.ik.get_path_to(target))
		g.ik.set_pole_node(i, g.ik.get_path_to(pole))  # TwoBoneIK3D does nothing without a pole
	g.align = FootAlign.new()
	g.align.name = "FootAlign"
	g.align.grounding = g
	sk.add_child(g.align)
	g.ik.active = false
	g.align.active = false
	return g


func _read(c: Dictionary) -> void:
	_ray_up = float(c["ray_up_m"])
	_ray_down = float(c["ray_down_m"])
	_dead = float(c["dead_zone_m"])
	_smooth_s = float(c["smoothing_s"])
	_pelvis_smooth_s = float(c["pelvis_smoothing_s"])
	_max_drop = float(c["max_drop_m"])
	_max_raise = float(c["max_raise_m"])
	_max_pelvis_drop = float(c["max_pelvis_drop_m"])
	_tilt_max = deg_to_rad(float(c["slope_tilt_max_deg"]))
	var lock: Dictionary = c["foot_lock"]
	_lock_on = bool(lock["enabled"])
	_lock_release_s = maxf(float(lock["release_s"]), 1e-3)
	_lock_slide = float(lock["max_slide_m"])
	_lock_turn = deg_to_rad(float(lock["max_turn_deg"]))
	_query = PhysicsRayQueryParameters3D.new()
	_query.hit_back_faces = false
	var mask: int = 0
	for layer: Variant in c["ground_layers"]:
		mask |= 1 << (int(layer) - 1)
	_query.collision_mask = mask


## Switches the whole foot chain on or off (graphics setting, LOD). Off resets locks and offsets,
## so switching back on starts from the animation.
func set_enabled(on: bool) -> void:
	active = on
	if not on:
		ik.active = false
		align.active = false
		engaged = false
		weight = 0.0
		pelvis_drop = 0.0
		for i: int in SIDES:
			offsets[i] = 0.0
			locked[i] = false
			lock_weight[i] = 0.0
			_lock_moves[i] = false
			_ray_from[i] = Vector3.INF
		_releasing = -1


func _process_modification_with_delta(delta: float) -> void:
	var sk: Skeleton3D = get_skeleton()
	if sk == null:
		return
	var sg: Transform3D = sk.global_transform
	var up: Vector3 = sg.basis.y.normalized()
	var ground: Vector3 = sg.origin
	var keep: float = exp(-delta / _smooth_s) if _smooth_s > 0.0 else 0.0
	var foot_l: Transform3D = sk.get_bone_global_pose(_bones[2])
	var foot_r: Transform3D = sk.get_bone_global_pose(_bones[5])
	var anim_feet: Array[Transform3D] = [foot_l, foot_r]
	var space: PhysicsDirectSpaceState3D = null
	for i: int in SIDES:
		var want: float = 0.0
		if weight > 0.0:
			var w_foot: Vector3 = sg * anim_feet[i].origin
			var from: Vector3 = w_foot - up * ((w_foot - ground).dot(up) - _ray_up)  # above the ankle, _ray_up over the origin's level
			if from.distance_squared_to(_ray_from[i]) > RAY_REUSE_M * RAY_REUSE_M:
				_ray_from[i] = from
				var hit: Dictionary
				if ground_query.is_valid():
					hit = ground_query.call(from, from - up * (_ray_up + _ray_down))
				else:
					if space == null:
						space = get_world_3d().direct_space_state
					_query.from = from
					_query.to = from - up * (_ray_up + _ray_down)
					hit = space.intersect_ray(_query)
				rays_cast += 1
				_ray_off[i] = 0.0
				_ray_normal[i] = up
				if not hit.is_empty():
					var off: float = ((hit["position"] as Vector3) - ground).dot(up)
					_ray_off[i] = 0.0 if absf(off) < _dead else off
					_ray_normal[i] = hit["normal"]
			want = clampf(_ray_off[i], -_max_drop, _max_raise)
		offsets[i] = want + (offsets[i] - want) * keep
		if want == 0.0 and absf(offsets[i]) < 1e-4:
			offsets[i] = 0.0
	var drop_want: float = clampf(-minf(0.0, minf(offsets[0], offsets[1])), 0.0, _max_pelvis_drop)
	pelvis_drop = drop_want + (pelvis_drop - drop_want) * (exp(-delta / _pelvis_smooth_s) if _pelvis_smooth_s > 0.0 else 0.0)
	if drop_want == 0.0 and pelvis_drop < 1e-4:
		pelvis_drop = 0.0
	_update_locks(delta, sg, up, anim_feet)
	var needed: bool = weight > 0.0 and (pelvis_drop > 0.0 or offsets[0] != 0.0 or offsets[1] != 0.0 \
		or _lock_moves[0] or _lock_moves[1])
	if needed != engaged:
		ik.active = needed
		align.active = needed
		engaged = needed
	if not needed:
		return
	ik.influence = weight
	align.influence = weight
	# lower the pelvis (a skeleton-space drop turned into the pelvis parent's frame)
	var inv: Transform3D = sg.affine_inverse()
	var up_sk: Vector3 = (inv.basis * up).normalized()
	var parent: int = sk.get_bone_parent(_pelvis)
	var drop_sk: Vector3 = -up_sk * pelvis_drop * weight
	var drop_local: Vector3 = drop_sk if parent == -1 else sk.get_bone_global_pose(parent).basis.inverse() * drop_sk
	sk.set_bone_pose_position(_pelvis, sk.get_bone_pose_position(_pelvis) + drop_local)
	for i: int in SIDES:
		var anim: Transform3D = anim_feet[i]
		var pos: Vector3 = anim.origin + up_sk * offsets[i]
		var basis: Basis = anim.basis
		var n_sk: Vector3 = (inv.basis * _ray_normal[i]).normalized()
		var tilt: float = up_sk.angle_to(n_sk)
		if tilt > 1e-3:
			basis = Basis(up_sk.cross(n_sk).normalized(), minf(tilt, _tilt_max)) * basis
		if lock_weight[i] > 0.0:
			# locked: hold the place on the floor and the heading; height and tilt still follow the floor
			var lp: Vector3 = inv * _lock_pos[i]
			lp += up_sk * (pos - lp).dot(up_sk)
			pos = pos.lerp(lp, lock_weight[i])
			var yaw: float = _signed_yaw(basis.y, inv.basis * _lock_basis[i].y, up_sk)
			basis = Basis(up_sk, yaw * lock_weight[i]) * basis
		foot_basis[i] = basis
		_targets[i].position = pos
		# pole: in front of the animated knee, in the plane the animation bends the leg
		var hip: Vector3 = sk.get_bone_global_pose(_bones[i * 3]).origin
		var knee: Vector3 = sk.get_bone_global_pose(_bones[i * 3 + 1]).origin
		var line: Vector3 = (pos - hip).normalized()
		var bend: Vector3 = (knee - hip) - line * (knee - hip).dot(line)
		# a nearly straight leg gives no reliable bend plane: then the knee points forward (+Z)
		var sure: float = clampf(bend.length() / POLE_SURE_BEND_M, 0.0, 1.0)
		var dir: Vector3 = Vector3(0, 0, 1).lerp(bend.normalized(), sure) if sure > 0.0 else Vector3(0, 0, 1)
		_poles[i].position = knee + dir.normalized() * 0.5


## Foot lock bookkeeping (world space, so the feet hold still while the body turns).
func _update_locks(delta: float, sg: Transform3D, up: Vector3, anim_feet: Array[Transform3D]) -> void:
	var on: bool = lock_wanted and _lock_on and weight > 0.0
	if not on and lock_weight[0] == 0.0 and lock_weight[1] == 0.0:
		locked[0] = false  # moving, nothing held: the usual case on the run
		locked[1] = false
		_lock_moves[0] = false
		_lock_moves[1] = false
		_releasing = -1
		return
	var rate: float = delta / _lock_release_s
	var worst: int = -1
	var worst_err: float = 0.0
	for i: int in SIDES:
		var want_pos: Vector3 = sg * anim_feet[i].origin + up * offsets[i]
		var want_basis: Basis = (sg.basis * anim_feet[i].basis).orthonormalized()
		var slide: float = (want_pos - _lock_pos[i]).slide(up).length()
		if lock_weight[i] > 0.0 and slide > _lock_slide * TELEPORT_SLIDES:
			# a blink or a correction moved the body at once: the feet come along, no stretch
			_lock_pos[i] = want_pos
			_lock_basis[i] = want_basis
			slide = 0.0
		var turn: float = absf(_signed_yaw(_lock_basis[i].y, want_basis.y, up))  # the foot bone runs heel to toe along +Y
		_lock_moves[i] = lock_weight[i] > 0.0 and (slide > LOCK_STILL_M or turn > LOCK_STILL_RAD)
		if not on:
			locked[i] = false
			lock_weight[i] = move_toward(lock_weight[i], 0.0, rate)
			continue
		if locked[i]:
			var err: float = maxf(slide / _lock_slide, turn / _lock_turn)
			if err > 1.0 and err > worst_err:
				worst = i
				worst_err = err
			continue
		# unlocked: ease back to the animated place, then lock there (no jump: it is where it was)
		lock_weight[i] = move_toward(lock_weight[i], 0.0, rate)
		if lock_weight[i] == 0.0:
			if _releasing == i:
				_releasing = -1
			locked[i] = true
			lock_weight[i] = 1.0
			_lock_pos[i] = want_pos
			_lock_basis[i] = want_basis
	if not on:
		_releasing = -1
		return
	if worst != -1 and _releasing == -1:
		_releasing = worst  # one foot steps at a time
		locked[worst] = false


## Signed angle around `up` from `a` to `b`, both flattened onto the plane `up` is normal to.
static func _signed_yaw(a: Vector3, b: Vector3, up: Vector3) -> float:
	var fa: Vector3 = a.slide(up)
	var fb: Vector3 = b.slide(up)
	if fa.length_squared() < 1e-8 or fb.length_squared() < 1e-8:
		return 0.0
	return fa.signed_angle_to(fb, up)
