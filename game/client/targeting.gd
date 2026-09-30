class_name Targeting
extends RefCounted
## Client-side target selection (backlog M1-23), on world-view unit dictionaries (the shape
## MatchRunner.view_for and NetClient.bot_view build: id, team, position, health...).
##
## Click: the unit whose body (an upright capsule, settings targeting.pick_height_m and
## pick_radius_m) is under the cursor, nearest first; walls and pillars in front hide units.
## Tab: enemies alive, within tab_range_m of the player and in line of sight (the server's eye
## to chest rule). Those within tab_max_angle_deg of the screen centre count as in front and are
## ordered by angle from the centre in tab_angle_band_deg bands, then by distance; repeated presses
## step through that order. With nobody in front, the nearest enemy anywhere in range and sight
## is taken, the same fallback as the server's Combat.tab_target.

var tab_range: float = Combat.TAB_MAX_RANGE
var tab_max_angle: float = deg_to_rad(60.0)
var tab_band: float = deg_to_rad(10.0)
var pick_height: float = 1.9
var pick_radius: float = 0.5
var click_empty_clears: bool = false


func _init(targeting_settings: Dictionary = {}) -> void:
	if targeting_settings.is_empty():
		return
	var s: Dictionary = targeting_settings
	tab_range = float(s["tab_range_m"])
	tab_max_angle = deg_to_rad(float(s["tab_max_angle_deg"]))
	tab_band = deg_to_rad(float(s["tab_angle_band_deg"]))
	pick_height = float(s["pick_height_m"])
	pick_radius = float(s["pick_radius_m"])
	click_empty_clears = bool(s["click_empty_clears_target"])


## Id of the unit under a screen point, or -1. `units` are view dictionaries; pass the positions
## the player sees (the renderer's interpolated positions) so the click matches the picture.
func pick_at(camera: Camera3D, screen_pos: Vector2, units: Array, geometry: ArenaGeometry) -> int:
	var origin: Vector3 = camera.project_ray_origin(screen_pos)
	var dir: Vector3 = camera.project_ray_normal(screen_pos)
	var best_id: int = -1
	var best_t: float = ArenaRay.NO_HIT
	for u: Dictionary in units:
		var t: float = ArenaRay.capsule(origin, dir, u["position"], pick_height, pick_radius)
		if t < best_t:
			best_t = t
			best_id = int(u["id"])
	if best_id == -1:
		return -1
	# a wall or pillar in front of the body hides it (the floor cannot, units stand on it)
	if ArenaRay.cast(geometry, origin, dir, best_t, 0.0, false) < best_t - 1e-4:
		return -1
	return best_id


## What a click at a point selects: the unit under it, or (on empty ground) the current target,
## unless the settings say an empty click clears it.
func click(camera: Camera3D, screen_pos: Vector2, units: Array, geometry: ArenaGeometry, current: int) -> int:
	var id: int = pick_at(camera, screen_pos, units, geometry)
	if id != -1:
		return id
	return -1 if click_empty_clears else current


## Enemy ids in Tab order for the player `me` and this camera (see the class comment).
func tab_order(camera: Camera3D, me: Dictionary, units: Array, geometry: ArenaGeometry) -> Array[int]:
	var cam_pos: Vector3 = camera.global_transform.origin
	var cam_fwd: Vector3 = -camera.global_transform.basis.z
	var my_pos: Vector3 = me["position"]
	var front: Array = []  # [band, distance, id]
	var nearest_id: int = -1
	var nearest_d: float = INF
	for u: Dictionary in units:
		if int(u["team"]) == int(me["team"]) or int(u["health"]) <= 0:
			continue
		var pos: Vector3 = u["position"]
		var d: float = Vector2(pos.x - my_pos.x, pos.z - my_pos.z).length()
		if d > tab_range:
			continue
		if geometry and not geometry.has_line_of_sight(my_pos + Vector3.UP * Combat.EYE_HEIGHT,
				pos + Vector3.UP * Combat.CHEST_HEIGHT):
			continue
		if d < nearest_d:
			nearest_d = d
			nearest_id = int(u["id"])
		var to: Vector3 = pos + Vector3.UP * Combat.CHEST_HEIGHT - cam_pos
		var angle: float = cam_fwd.angle_to(to) if to.length_squared() > 1e-9 else 0.0
		if angle <= tab_max_angle:
			front.append([floori(angle / tab_band), d, int(u["id"])])
	front.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if not is_equal_approx(a[1], b[1]):
			return a[1] < b[1]
		return a[2] < b[2])
	var order: Array[int] = []
	for f: Array in front:
		order.append(int(f[2]))
	if order.is_empty() and nearest_id != -1:
		order.append(nearest_id)
	return order


## The target after one Tab press: the next enemy after the current one in Tab order, or the
## first when the current target is not in it. Keeps the current target when no enemy qualifies.
func tab(camera: Camera3D, me: Dictionary, units: Array, geometry: ArenaGeometry, current: int) -> int:
	var order: Array[int] = tab_order(camera, me, units, geometry)
	if order.is_empty():
		return current
	var i: int = order.find(current)
	return order[(i + 1) % order.size()] if i != -1 else order[0]
