extends Node3D
## Review views of the rig modifiers (backlog X-02): head turning and foot grounding on built
## characters, driven through CharacterAnimator exactly as in the game.
##
##   tools/screenshot.sh res://scenes/tests/rig_view.tscn previews/rig_modifiers/look_front.png 1600 900 30 \
##     --mode look [--cam-yaw 0] [--cam-pitch 12] [--cam-dist 9] [--spec arcanist_rime]
##   tools/screenshot.sh res://scenes/tests/rig_view.tscn previews/rig_modifiers/ground_front.png 1600 900 30 \
##     --mode ground [--view feet] [--spec warblade_carnage]
##
## "look": a row of characters facing the camera, each with its own target (a red orb at the height
## the look-at aims for) at a different angle: far left past the limit, left, ahead and low, high
## right, right, and behind (given up: looks ahead). Labels give the angle to the character's right.
## "ground": pairs of the same character with the modifiers on and off, standing across a 0.22 m
## step edge and on a 15 degree ramp that rises to their left (views front, feet, feet_step,
## feet_ramp), and on a ramp rising ahead of them (views side: on, side_off: off).
## Animation is fast-forwarded by --hold seconds (default 1.2) at 60 Hz and then held, so the frame
## is deterministic.

const DT: float = 1.0 / 60.0
const STEP_H: float = 0.22
const RAMP_DEG: float = 15.0
const LOOK_CASES: Array = [  # [label, yaw to the character's right (deg), target height offset (m)]
	["-100 (limit)", -100.0, 0.0], ["-45", -45.0, 0.0], ["0, low", 0.0, -1.2], ["+35, high", 35.0, 1.2],
	["+80", 80.0, 0.0], ["+150 (behind)", 150.0, 0.0]]

var chars: Array[Dictionary] = []  ## {"root", "animator", "unit", "view"}
var cam: Camera3D
var _hold_s: float = 1.2
var _physics_frames: int = 0
var _ready_done: bool = false


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = _arg(args, "--mode", "look")
	_hold_s = float(_arg(args, "--hold", "1.2"))
	_stage()
	cam = Camera3D.new()
	cam.fov = 40.0
	add_child(cam)
	cam.current = true
	var spec: String = _arg(args, "--spec", "warblade_carnage")
	if mode == "ground":
		_ground(spec, _arg(args, "--view", "front"), args)
	elif mode == "perf":
		_perf_setup(_arg(args, "--floor", "flat"), int(_arg(args, "--count", "20")))
	else:
		_look(spec, args)


func _physics_process(_delta: float) -> void:
	_physics_frames += 1
	if _physics_frames == 3 and not _ready_done:  # the floor colliders are in the physics space by now
		_ready_done = true
		if _perf:
			_perf_run(int(_arg(OS.get_cmdline_user_args(), "--frames-measured", "600")))
			get_tree().quit()
			return
		for i: int in roundi(_hold_s / DT):
			for c: Dictionary in chars:
				(c["animator"] as CharacterAnimator).update(c["unit"], c["view"], Vector3.ZERO, DT)
				var rig: RigModifiers = (c["animator"] as CharacterAnimator).rig
				if rig != null:
					rig.flush([])


func _process(_delta: float) -> void:
	if not _ready_done:
		return
	for c: Dictionary in chars:
		(c["animator"] as CharacterAnimator).update(c["unit"], c["view"], Vector3.ZERO, 0.0)  # hold the pose


func _character(spec: String, pos: Vector3, facing: float, id: int) -> Dictionary:
	var asset: Dictionary = WorldRenderer.character_asset(spec)
	var root: Node3D = Node3D.new()
	root.name = "Char%d" % id
	add_child(root)
	root.position = pos
	root.rotation.y = facing
	var model: Node3D = (load(CharacterRig.res_path(asset)) as PackedScene).instantiate()
	model.rotation.y = PI  # models face +Z; the game's forward is -Z (as WorldRenderer)
	root.add_child(model)
	var anim: CharacterAnimator = CharacterAnimator.create(CharacterRig.setup(asset, model), id, 0)
	# the view's height stays 0: the game's units are on flat floors, and height means airborne
	var u: Dictionary = {"id": id, "team": 0, "spec": spec, "position": Vector3(pos.x, 0.0, pos.z), "facing": facing,
		"health": 100, "max_health": 100, "target_id": -1, "cast": {}, "auras": []}
	var c: Dictionary = {"root": root, "animator": anim, "unit": u, "view": {"tick": 1, "units": [u], "match": {"phase": 1}}}
	chars.append(c)
	return c


# ------------------------------------------------------------------ look

func _look(spec: String, args: PackedStringArray) -> void:
	var n: int = LOOK_CASES.size()
	var spacing: float = 2.5
	var facing: float = PI  # facing +Z, toward the camera
	var look_cfg: Dictionary = Data.anim_states["humanoid"]["rig_modifiers"]["look_at"]
	for i: int in n:
		var case: Array = LOOK_CASES[i]
		var pos: Vector3 = Vector3((i - (n - 1) * 0.5) * spacing, 0.0, 0.0)
		var c: Dictionary = _character(spec, pos, facing, 10 + i)
		var fwd: Vector3 = Movement.forward_of(facing)
		var right: Vector3 = Movement.right_of(facing)
		var yaw: float = deg_to_rad(float(case[1]))
		var tpos: Vector3 = pos + (fwd * cos(yaw) + right * sin(yaw)) * 1.6 + Vector3(0, float(case[2]), 0)
		var target: Dictionary = {"id": 100 + i, "team": 1, "position": tpos, "health": 100}
		c["unit"]["target_id"] = 100 + i
		c["view"]["units"].append(target)
		_orb(tpos + Vector3(0, float(look_cfg["target_height_m"]), 0))
		_ray(pos + Vector3(0, 0.01, 0), Vector3(tpos.x, 0.01, tpos.z))
		_label(str(case[0]), pos + Vector3(0, 0.02, 0.9))
	_frame(args, Vector3(0, 1.1, 0), 0.0, 14.0, 15.0)


# ------------------------------------------------------------------ ground

func _ground(spec: String, view: String, args: PackedStringArray) -> void:
	var facing: float = PI  # facing +Z, toward the camera: their right foot is at -x
	var ramp: float = deg_to_rad(RAMP_DEG)
	var ramp_h: float = 0.1 / cos(ramp)  # surface height above a ramp block's centre
	var row: Array = []  # [label, on, kind]
	row = [["step, on", true, "step"], ["step, off", false, "step"], ["ramp, on", true, "ramp"],
		["ramp, off", false, "ramp"]]
	for i: int in row.size():
		var x: float = (i - (row.size() - 1) * 0.5) * 2.6
		var kind: String = row[i][2]
		var h: float = STEP_H
		if kind == "step":  # the upper level under the right foot, the edge between the feet
			_block(Vector3(x - 0.62, STEP_H * 0.5, 0.0), Vector3(1.2, STEP_H, 1.2))
		else:  # rises to their left; the low end is buried in the floor
			_block(Vector3(x, 0.0, 0.0), Vector3(2.4, 0.2, 1.2), Vector3(0, 0, ramp))
			h = ramp_h
		var c: Dictionary = _character(spec, Vector3(x, h, 0.0), facing, 1 + i)
		(c["animator"] as CharacterAnimator).rig.allowed = bool(row[i][1])
		_label(str(row[i][0]), Vector3(x, 0.03, 0.95))
	# ramp rising ahead of them (side view): at z = -6, on and off
	_block(Vector3(0.0, 0.0, -6.0), Vector3(5.0, 0.2, 3.0), Vector3(-ramp, 0, 0))
	for i: int in 2:
		var c: Dictionary = _character(spec, Vector3(-1.5 + 3.0 * i, ramp_h, -6.0), facing, 10 + i)
		(c["animator"] as CharacterAnimator).rig.allowed = i == 0
	match view:
		"feet":
			_frame(args, Vector3(0.0, 0.3, 0.0), 0.0, 7.5, 5.0)
		"feet_step":
			_frame(args, Vector3(-2.6, 0.35, 0.0), 0.0, 4.0, 14.0)
		"feet_ramp":
			_frame(args, Vector3(2.6, 0.35, 0.0), 0.0, 4.0, 14.0)
		"side":  # the one with the modifiers, seen from its right
			_frame(args, Vector3(-1.5, 0.45, -6.0), -90.0, 3.2, 6.0)
		"side_off":  # the one without, seen from its left
			_frame(args, Vector3(1.5, 0.45, -6.0), 90.0, 3.2, 6.0)
		_:
			_frame(args, Vector3(0.0, 0.9, 0.0), 0.0, 13.0, 10.0)


# ------------------------------------------------------------------ perf
# Headless CPU cost of the modifiers for a crowd (20 = a full battleground on screen):
#   godot --headless --path game res://scenes/tests/rig_view.tscn -- --mode perf [--floor flat|slope]
#     [--count 20] [--frames-measured 600]
# Characters run in circles around the centre, each targeting the next, so look-at, foot rays and
# (on "slope", a 10 degree tilted floor) the leg solver all work every frame. Prints the mean time of
# a frame's animation work for everyone (tree + modifiers) with the modifiers on and off.

var _perf: bool = false
var _t: float = 0.0


func _perf_setup(floor_kind: String, count: int) -> void:
	_perf = true
	if floor_kind == "slope":
		_block(Vector3(0, 2.0, 0), Vector3(40, 0.2, 40), Vector3(deg_to_rad(10.0), 0, 0))  # above the floor everywhere they run
	var specs: Array[String] = ["warblade_carnage", "arcanist_rime", "oracle_grace"]
	for i: int in count:
		var c: Dictionary = _character(specs[i % specs.size()], Vector3.ZERO, 0.0, 200 + i)
		c["phase"] = TAU * i / count
		c["radius"] = 3.0 + (i % 4) * 1.5
	for i: int in count:
		var c: Dictionary = chars[i]
		var other: Dictionary = chars[(i + 1) % count]
		c["unit"]["target_id"] = other["unit"]["id"]
		c["view"]["units"] = [c["unit"], other["unit"]]
	_perf_place(0.0)


## Every character on its circle at time `t`: node, view entry and ground velocity; standing still
## for the first second of every four (idle, foot lock) and running the rest.
func _perf_place(t: float) -> void:
	var running: bool = fmod(t, 4.0) >= 1.0
	for c: Dictionary in chars:
		var r: float = float(c["radius"])
		var w: float = 7.0 / r if running else 0.0
		var ang: float = float(c["phase"]) + t * 7.0 / r
		var pos: Vector3 = Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		var vel: Vector3 = Vector3(-sin(ang), 0.0, cos(ang)) * r * w
		var facing: float = atan2(sin(ang), -cos(ang))  # forward_of(facing) is the tangent
		var root: Node3D = c["root"]
		var ray: Dictionary = get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(pos + Vector3(0, 5, 0), pos + Vector3(0, -5, 0)))
		root.position = pos + Vector3(0, float((ray.get("position", Vector3.ZERO) as Vector3).y) if not ray.is_empty() else 0.0, 0)
		root.rotation.y = facing
		c["unit"]["position"] = pos
		c["unit"]["facing"] = facing
		c["velocity"] = vel


func _perf_frames(frames: int) -> float:
	var total: int = 0
	for f: int in frames:
		_t += DT
		_perf_place(_t)
		var t0: int = Time.get_ticks_usec()
		for c: Dictionary in chars:
			var a: CharacterAnimator = c["animator"]
			a.update(c["unit"], c["view"], c["velocity"], DT)
			if a.rig != null:
				a.rig.flush([])  # the modifiers now, not at the end of a frame that never renders
		total += Time.get_ticks_usec() - t0
	return total / 1000.0 / frames


func _perf_run(frames: int) -> void:
	_perf_frames(120)  # warm up
	var results: Dictionary = {}
	for rounds: int in 2:  # alternate, so a busy moment on the machine hits both
		for on: bool in [false, true]:  # ends on: the solver count below is for the modifiers on
			for c: Dictionary in chars:
				(c["animator"] as CharacterAnimator).rig.allowed = on
			_perf_frames(30)
			var ms: float = _perf_frames(frames / 2)
			results[on] = float(results.get(on, 0.0)) + ms / 2.0
	var engaged: int = 0
	for c: Dictionary in chars:
		engaged += 1 if (c["animator"] as CharacterAnimator).rig.feet.engaged else 0
	var n: int = chars.size()
	print("rig_perf: %d characters, %d frames: modifiers on %.3f ms/frame (%.1f us each), off %.3f ms/frame, cost %.3f ms/frame (%.1f us each); leg solver engaged on %d at the end" % [
		n, frames, results[true], results[true] * 1000.0 / n, results[false], results[true] - results[false],
		(results[true] - results[false]) * 1000.0 / n, engaged])


# ------------------------------------------------------------------ stage

func _frame(args: PackedStringArray, focus: Vector3, yaw_deg: float, dist: float, pitch_deg: float) -> void:
	var yaw: float = deg_to_rad(float(_arg(args, "--cam-yaw", str(yaw_deg))))
	var pitch: float = deg_to_rad(float(_arg(args, "--cam-pitch", str(pitch_deg))))
	var d: float = float(_arg(args, "--cam-dist", str(dist)))
	var offset: Vector3 = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * d
	cam.position = focus + offset
	cam.look_at(focus, Vector3.UP)


func _stage() -> void:
	_block(Vector3(0, -0.2, 0), Vector3(40, 0.4, 40))
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.2, 0.22, 0.26)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.57, 0.62)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	add_child(we)


## A static box on the world layer, drawn with a 0.25 m checker so heights and slopes read.
func _block(pos: Vector3, size: Vector3, rot: Vector3 = Vector3.ZERO) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	body.collision_layer = 1 << (MapBuilder.LAYER_WORLD - 1)
	body.collision_mask = 0
	body.position = pos
	body.rotation = rot
	add_child(body)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_texture = _checker()
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(2, 2, 2)
	mat.roughness = 0.9
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	body.add_child(mi)


static var _checker_tex: ImageTexture


static func _checker() -> ImageTexture:
	if _checker_tex == null:
		var img: Image = Image.create(8, 8, false, Image.FORMAT_RGB8)
		for x: int in 8:
			for y: int in 8:
				var dark: bool = (x < 4) != (y < 4)
				img.set_pixel(x, y, Color(0.3, 0.3, 0.31) if dark else Color(0.44, 0.44, 0.45))
		_checker_tex = ImageTexture.create_from_image(img)
	return _checker_tex


func _orb(pos: Vector3) -> void:
	var s: SphereMesh = SphereMesh.new()
	s.radius = 0.12
	s.height = 0.24
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.15, 0.1)
	mat.emission_enabled = true
	mat.emission = Color(0.95, 0.15, 0.1)
	mat.emission_energy_multiplier = 1.5
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = s
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


## A thin strip on the floor from a character to its target, so each orb reads as whose it is.
func _ray(a: Vector3, b: Vector3) -> void:
	var m: BoxMesh = BoxMesh.new()
	m.size = Vector3(0.04, 0.005, a.distance_to(b))
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.15, 0.1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	add_child(mi)
	mi.position = (a + b) * 0.5
	mi.look_at(b, Vector3.UP)


func _label(text: String, pos: Vector3) -> void:
	var l: Label3D = Label3D.new()
	l.text = text
	l.font_size = 40
	l.pixel_size = 0.004
	l.rotation_degrees = Vector3(-90, 0, 0)
	l.position = pos
	l.modulate = Color(0.95, 0.9, 0.7)
	l.outline_size = 8
	add_child(l)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i: int = args.find(key)
	return args[i + 1] if i != -1 and i + 1 < args.size() else fallback
