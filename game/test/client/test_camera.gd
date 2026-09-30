extends GdUnitTestSuite
## Third-person camera (backlog M1-23): zoom limits and smoothing, pitch limits, and pulling in
## along its ray in front of pillars, walls and the floor.

const DT: float = 1.0 / 60.0

var cam: ThirdPersonCamera
var geometry: ArenaGeometry


func before_test() -> void:
	cam = auto_free(ThirdPersonCamera.new(Data.settings["default"]["camera"]))
	add_child(cam)
	geometry = ArenaGeometry.from_map(Data.maps["gallows_courtyard"])
	geometry.gates_open = true


func _settle(feet: Vector3, yaw: float, pitch: float, seconds: float = 3.0) -> void:
	for i: int in roundi(seconds / DT):
		cam.update(feet, yaw, pitch, DT)


func test_zoom_is_clamped_to_the_settings_limits() -> void:
	var s: Dictionary = Data.settings["default"]["camera"]
	assert_float(cam.zoom_target).is_equal(float(s["default_distance_m"]))
	cam.zoom_steps(100)
	assert_float(cam.zoom_target).is_equal(float(s["max_distance_m"]))
	cam.zoom_steps(-100)
	assert_float(cam.zoom_target).is_equal(float(s["min_distance_m"]))
	assert_float(cam.min_distance).is_equal_approx(2.0, 0.5)
	assert_float(cam.max_distance).is_equal_approx(25.0, 1.0)


func test_zoom_is_smoothed() -> void:
	# open ground and no blockers: only the floor
	cam.update(Vector3.ZERO, 0.0, deg_to_rad(20), DT)
	var start: float = cam.distance
	cam.zoom_steps(3)
	var target: float = cam.zoom_target
	assert_float(target).is_greater(start)
	cam.update(Vector3.ZERO, 0.0, deg_to_rad(20), DT)
	assert_float(cam.distance).is_greater(start)
	assert_float(cam.distance).is_less(target - 0.5)  # eases, does not jump
	_settle(Vector3.ZERO, 0.0, deg_to_rad(20), 2.0)
	assert_float(cam.distance).is_equal_approx(target, 0.01)
	var pivot: Vector3 = Vector3.UP * cam.pivot_height
	assert_float(cam.camera.global_position.distance_to(pivot)).is_equal_approx(target, 0.01)


func test_camera_sits_behind_the_character_and_looks_at_the_pivot() -> void:
	var feet: Vector3 = Vector3(3, 0, 2)
	var yaw: float = -PI / 2  # facing +x
	_settle(feet, yaw, deg_to_rad(15))
	var pivot: Vector3 = feet + Vector3.UP * cam.pivot_height
	var p: Vector3 = cam.camera.global_position
	assert_float(p.x).is_less(feet.x - 5.0)  # behind: -x
	assert_float(p.z).is_equal_approx(feet.z, 1e-3)
	assert_float(p.y).is_greater(pivot.y)
	var looking: Vector3 = -cam.camera.global_transform.basis.z
	assert_float(looking.angle_to(pivot - p)).is_less(0.001)


func test_pitch_limits() -> void:
	cam.update(Vector3.ZERO, 0.0, deg_to_rad(89), DT)
	assert_float(cam.pitch).is_equal_approx(cam.pitch_max, 1e-6)
	cam.update(Vector3.ZERO, 0.0, deg_to_rad(-89), DT)
	assert_float(cam.pitch).is_equal_approx(cam.pitch_min, 1e-6)


func test_camera_pulls_in_in_front_of_a_pillar() -> void:
	cam.geometry = geometry
	# stand 3 m in front of the pillar at (-8, 7), facing away from it (-Z): the camera's ray
	# behind the character runs into the pillar
	var feet: Vector3 = Vector3(-8, 0, 4)
	var pitch: float = deg_to_rad(15)
	_settle(feet, 0.0, pitch)
	var gap: float = 3.0 - 1.2 - cam.collision_radius
	var expected: float = gap / cos(pitch)
	assert_float(cam.distance).is_equal_approx(expected, 0.02)
	var p: Vector3 = cam.camera.global_position
	assert_float(Vector2(p.x + 8, p.z - 7).length()).is_greater_equal(1.2 + cam.collision_radius - 0.01)
	# the view is clear from pivot to camera
	var pivot: Vector3 = feet + Vector3.UP * cam.pivot_height
	assert_float(ArenaRay.cast(geometry, pivot, (p - pivot).normalized(), pivot.distance_to(p))).is_equal_approx(
		pivot.distance_to(p), 1e-4)
	# stepping aside clears the view; the camera eases back out rather than jumping
	var aside: Vector3 = Vector3(-4, 0, 4)
	cam.update(aside, 0.0, pitch, DT)
	assert_float(cam.distance).is_greater(expected)
	assert_float(cam.distance).is_less(cam.zoom_target - 0.5)
	_settle(aside, 0.0, pitch)
	assert_float(cam.distance).is_equal_approx(cam.zoom_target, 0.01)


func test_camera_pulls_in_at_once_when_a_wall_cuts_in() -> void:
	cam.geometry = geometry
	_settle(Vector3(-4, 0, 4), 0.0, deg_to_rad(15))
	# walk up to the pillar: the very next frame is already in front of it
	cam.update(Vector3(-8, 0, 4), 0.0, deg_to_rad(15), DT)
	assert_float(cam.distance).is_less(2.0)


func test_camera_stops_at_a_wall_and_above_the_floor() -> void:
	cam.geometry = geometry
	cam.zoom_steps(100)
	# 4 m from the south courtyard wall (z = 18 to 25, 6 m tall), camera zoomed out behind (+z)
	var feet: Vector3 = Vector3(0, 0, 14)
	var pitch: float = deg_to_rad(10)
	_settle(feet, 0.0, pitch)
	var p: Vector3 = cam.camera.global_position
	assert_float(p.z).is_less_equal(18.0 - cam.collision_radius + 0.001)
	assert_float(cam.distance).is_equal_approx((4.0 - cam.collision_radius) / cos(pitch), 0.02)
	# looking up from below: the floor pulls the camera in
	_settle(Vector3(0, 0, 12), PI / 2, cam.pitch_min)
	assert_float(cam.camera.global_position.y).is_greater_equal(cam.collision_radius - 0.001)
	assert_float(cam.distance).is_less(cam.zoom_target)
