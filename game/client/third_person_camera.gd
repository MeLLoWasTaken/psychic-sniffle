class_name ThirdPersonCamera
extends Node3D
## Third-person MMO camera (backlog M1-23): orbits a pivot at shoulder height above the
## character, zooms with the mouse wheel between the settings' minimum and maximum distance with
## smoothing, clamps pitch, and pulls in along its ray in front of walls, pillars and the floor so
## they never block the view (ArenaRay against the server's map colliders).
##
## Yaw and pitch come from the PlayerController (character facing plus the orbit offset); this
## node only places the camera. Pitch is the camera's elevation above the pivot: positive looks
## down at the character, negative looks up from below.
##   cam.update(feet_position, controller.camera_yaw(), controller.pitch, delta)

var camera: Camera3D
var geometry: ArenaGeometry  ## blockers the camera avoids; null = only the floor

var min_distance: float = 2.0
var max_distance: float = 25.0
var zoom_step_ratio: float = 0.15
var smoothing_per_s: float = 10.0
var pitch_min: float = deg_to_rad(-35.0)
var pitch_max: float = deg_to_rad(80.0)
var pivot_height: float = 1.6
var collision_radius: float = 0.25

var zoom_target: float = 7.0  ## distance the player asked for with the wheel
var zoom_distance: float = 7.0  ## smoothed toward zoom_target
var distance: float = 7.0  ## shown distance: zoom_distance, pulled in by blockers
var yaw: float = 0.0
var pitch: float = 0.0
var pivot: Vector3 = Vector3.ZERO

const MIN_ZOOM_STEP_M: float = 0.5


func _init(camera_settings: Dictionary = {}) -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.top_level = true  # placed in world space, also before the node enters the tree (tests)
	add_child(camera)
	configure(camera_settings)


## Apply the "camera" section of a settings profile (data/settings/<id>.json).
func configure(s: Dictionary) -> void:
	if s.is_empty():
		return
	min_distance = float(s["min_distance_m"])
	max_distance = float(s["max_distance_m"])
	zoom_step_ratio = float(s["zoom_step_ratio"])
	smoothing_per_s = float(s["zoom_smoothing_per_s"])
	pitch_min = deg_to_rad(float(s["pitch_min_deg"]))
	pitch_max = deg_to_rad(float(s["pitch_max_deg"]))
	pivot_height = float(s["pivot_height_m"])
	collision_radius = float(s["collision_radius_m"])
	camera.fov = float(s["fov_deg"])
	zoom_target = clampf(float(s["default_distance_m"]), min_distance, max_distance)
	zoom_distance = zoom_target
	distance = zoom_target


## Mouse-wheel zoom: positive steps zoom out, negative zoom in. Each notch changes the target
## distance by zoom_step_ratio of itself (at least 0.5 m); the target stays within the limits.
func zoom_steps(steps: int) -> void:
	for i: int in absi(steps):
		var step: float = maxf(zoom_target * zoom_step_ratio, MIN_ZOOM_STEP_M)
		zoom_target = clampf(zoom_target + (step if steps > 0 else -step), min_distance, max_distance)


func clamp_pitch(p: float) -> float:
	return clampf(p, pitch_min, pitch_max)


## Direction from the pivot to the camera for a yaw (0 = character faces -Z, camera behind at +Z)
## and a pitch.
static func offset_dir(p_yaw: float, p_pitch: float) -> Vector3:
	return Vector3(sin(p_yaw) * cos(p_pitch), sin(p_pitch), cos(p_yaw) * cos(p_pitch))


## Place the camera for this frame. The zoom eases toward its target; a blocker pulls the camera
## in at once, and it eases back out when the view clears.
func update(feet: Vector3, p_yaw: float, p_pitch: float, delta: float) -> void:
	pivot = feet + Vector3.UP * pivot_height
	yaw = p_yaw
	pitch = clamp_pitch(p_pitch)
	var k: float = 1.0 - exp(-smoothing_per_s * maxf(delta, 0.0))
	zoom_distance = lerpf(zoom_distance, zoom_target, k)
	if absf(zoom_distance - zoom_target) < 0.001:
		zoom_distance = zoom_target
	var back: Vector3 = offset_dir(yaw, pitch)
	var free: float = ArenaRay.cast(geometry, pivot, back, zoom_distance, collision_radius)
	if free <= distance:
		distance = free
	else:
		distance = lerpf(distance, free, k)
		if absf(distance - free) < 0.001:
			distance = free
	var basis: Basis = Basis.from_euler(Vector3(-pitch, yaw, 0.0))
	camera.transform = Transform3D(basis, pivot + back * distance)
