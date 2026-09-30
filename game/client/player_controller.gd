class_name PlayerController
extends RefCounted
## Turns the player's keyboard and mouse into the same input dictionary the bots produce
## ({move, yaw, jump, tab, ability, target, clear_target}; see Movement and
## MatchRunner.apply_input), so the server and simulation path is the same for people and bots
## (backlog M1-23). Actions come from the keybind profile (Keybinds), tuning from a settings
## profile (data/settings/<id>.json).
##
## Classic MMO controls:
## - W/S forward and back, Q/E strafe, A/D turn (A/D strafe while the right button is held),
##   Space jumps. Movement is relative to the character's facing.
## - Right-button drag steers: the character and camera turn together. Pressing it turns the
##   character to face the way the camera looks.
## - Left-button drag orbits the camera around the character, which keeps its facing. On release
##   the camera stays where it was left.
## - Both buttons held run forward. A press and release without dragging is a click: it selects
##   the unit under the cursor (Targeting). Tab cycles enemies; Escape clears the target.
## - The mouse wheel zooms (read pending_zoom each frame and pass it to ThirdPersonCamera).
##
## Feed events with handle_event(), then call next_input() once per simulation tick.

const MOVE_ACTIONS: Array[String] = ["move_forward", "move_back", "strafe_left", "strafe_right",
	"turn_left", "turn_right", "jump"]

var sensitivity: float = deg_to_rad(0.25)  ## radians per pixel of mouse travel
var invert_y: bool = false
var click_max_drag: float = 4.0
var turn_speed: float = deg_to_rad(180.0)
var pitch_min: float = deg_to_rad(-35.0)
var pitch_max: float = deg_to_rad(80.0)

var yaw: float = 0.0  ## the character's facing, sent to the server (0 faces -Z)
var orbit: float = 0.0  ## camera yaw relative to the character (left-button drag)
var pitch: float = deg_to_rad(15.0)  ## camera elevation (ThirdPersonCamera)
var steering: bool = false  ## right button held
var orbiting: bool = false  ## left button held
var held: Dictionary = {}  ## movement action -> held
var targeting: Targeting
var target_id: int = -1  ## the player's current target (any unit, ally or enemy), or -1
var pending_zoom: int = 0  ## wheel notches since the camera last read them (+ = out)

var _requests: Array = []  ## ["tab"], ["clear"], ["click", screen position], in arrival order
var _press_pos: Dictionary = {}  ## "steer"/"orbit" -> screen position of the press
var _drag: Dictionary = {}  ## "steer"/"orbit" -> pixels moved since the press


func _init(settings: Dictionary = {}) -> void:
	for a: String in MOVE_ACTIONS:
		held[a] = false
	targeting = Targeting.new(settings.get("targeting", {}))
	if settings.is_empty():
		return
	var m: Dictionary = settings["mouse"]
	sensitivity = deg_to_rad(float(m["sensitivity_deg_per_px"]))
	invert_y = bool(m["invert_y"])
	click_max_drag = float(m["click_max_drag_px"])
	turn_speed = deg_to_rad(float(settings["movement"]["keyboard_turn_deg_s"]))
	var c: Dictionary = settings["camera"]
	pitch_min = deg_to_rad(float(c["pitch_min_deg"]))
	pitch_max = deg_to_rad(float(c["pitch_max_deg"]))
	pitch = clampf(deg_to_rad(float(c["default_pitch_deg"])), pitch_min, pitch_max)


## Face a new direction with the camera behind (at spawn, or after the server moved the unit).
func reset_facing(p_yaw: float) -> void:
	yaw = wrapf(p_yaw, -PI, PI)
	orbit = 0.0


## The camera's yaw: the character's facing plus the orbit offset.
func camera_yaw() -> float:
	return wrapf(yaw + orbit, -PI, PI)


## True while a mouse button is held and has moved past the click threshold (hide the cursor).
func is_dragging() -> bool:
	return (steering and float(_drag.get("steer", 0.0)) > click_max_drag) \
		or (orbiting and float(_drag.get("orbit", 0.0)) > click_max_drag)


## Let go of everything (the window lost focus).
func release_all() -> void:
	for a: String in MOVE_ACTIONS:
		held[a] = false
	steering = false
	orbiting = false


## Handle one input event. Returns true when the event was a control this class uses.
func handle_event(ev: InputEvent) -> bool:
	if ev is InputEventMouseMotion:
		return _mouse_motion(ev as InputEventMouseMotion)
	if ev.is_echo():
		return false
	var used: bool = false
	if _is(ev, "camera_steer"):
		_button(ev, "steer")
		used = true
	if _is(ev, "camera_orbit"):
		_button(ev, "orbit")
		used = true
	if _pressed(ev, "camera_zoom_in"):
		pending_zoom -= 1
		used = true
	if _pressed(ev, "camera_zoom_out"):
		pending_zoom += 1
		used = true
	for a: String in MOVE_ACTIONS:
		if _is(ev, a):
			held[a] = ev.is_pressed()
			used = true
	if _pressed(ev, "target_nearest_enemy"):
		_requests.append(["tab"])
		used = true
	if _pressed(ev, "clear_target"):
		_requests.append(["clear"])
		used = true
	return used


## Actions missing from the loaded keybind profile never match (InputMap would log an error).
static func _is(ev: InputEvent, action: String) -> bool:
	return InputMap.has_action(action) and ev.is_action(action)


static func _pressed(ev: InputEvent, action: String) -> bool:
	return InputMap.has_action(action) and ev.is_action_pressed(action)


func _button(ev: InputEvent, which: String) -> void:
	var pos: Vector2 = (ev as InputEventMouse).position if ev is InputEventMouse else Vector2.ZERO
	var steer: bool = which == "steer"
	if ev.is_pressed():
		_press_pos[which] = pos
		_drag[which] = 0.0
		if steer:
			steering = true
			yaw = camera_yaw()  # the character turns to face the way the camera looks
			orbit = 0.0
		else:
			orbiting = true
		return
	var was_held: bool = steering if steer else orbiting
	if was_held and float(_drag.get(which, 0.0)) <= click_max_drag:
		_requests.append(["click", _press_pos.get(which, pos)])
	if steer:
		steering = false
	else:
		orbiting = false


func _mouse_motion(ev: InputEventMouseMotion) -> bool:
	if not (steering or orbiting):
		return false
	var rel: Vector2 = ev.relative
	for which: String in ["steer", "orbit"]:
		if (steering if which == "steer" else orbiting):
			_drag[which] = float(_drag.get(which, 0.0)) + rel.length()
	var dx: float = rel.x * sensitivity
	var dy: float = rel.y * sensitivity * (-1.0 if invert_y else 1.0)
	if steering:
		yaw = wrapf(yaw - dx, -PI, PI)  # mouse right turns right (yaw grows to the left)
	else:
		orbit = wrapf(orbit - dx, -PI, PI)
	pitch = clampf(pitch + dy, pitch_min, pitch_max)  # mouse down raises the camera to look down
	return true


## The input for one simulation tick of `dt` seconds. Resolves queued clicks and Tab presses
## against the world view: `view` is the player's world view (needs "me" and "units" for Tab),
## `units` the unit dictionaries at the positions on screen (for clicks), `camera` the camera
## the player sees through. Any of them may be empty or null (then targeting requests wait).
func next_input(dt: float, view: Dictionary = {}, camera: Camera3D = null, units: Array = [],
		geometry: ArenaGeometry = null) -> Dictionary:
	if units.is_empty():
		units = view.get("units", [])
	if camera != null and not view.is_empty():
		for r: Array in _requests:
			match r[0]:
				"clear":
					target_id = -1
				"click":
					target_id = targeting.click(camera, r[1], units, geometry, target_id)
				"tab":
					target_id = targeting.tab(camera, view["me"], view.get("units", []), geometry, target_id)
		_requests.clear()
	else:
		_requests = _requests.filter(func(r: Array) -> bool: return r[0] == "clear")
		if not _requests.is_empty():
			target_id = -1
			_requests.clear()
	var turn: float = 0.0
	var strafe: float = float(held["strafe_right"]) - float(held["strafe_left"])
	var side_keys: float = float(held["turn_right"]) - float(held["turn_left"])
	if steering:
		strafe += side_keys  # with the right button held the turn keys strafe
	else:
		turn = -side_keys * turn_speed * dt
	if turn != 0.0:
		yaw = wrapf(yaw + turn, -PI, PI)
		if orbiting:
			orbit = wrapf(orbit - turn, -PI, PI)  # the held camera stays put while the body turns
	var forward: float = float(held["move_forward"] or (steering and orbiting)) - float(held["move_back"])
	return {"move": Vector2(clampf(strafe, -1.0, 1.0), clampf(forward, -1.0, 1.0)), "yaw": yaw,
		"jump": bool(held["jump"]), "tab": false, "ability": "", "target": target_id,
		"clear_target": not _is_hostile(view, target_id)}


## True when `id` is a unit on another team than the player's in this view.
static func _is_hostile(view: Dictionary, id: int) -> bool:
	if id < 0 or not view.has("me"):
		return false
	for u: Dictionary in view.get("units", []):
		if int(u["id"]) == id:
			return int(u["team"]) != int(view["me"]["team"])
	return false
