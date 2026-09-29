class_name BotBrain
extends RefCounted
## Simple headless bot behaviour for testing (backlog M0-14): tab-target when it has no
## target, chase the target into melee range (auto-attack then happens on the server),
## otherwise wander. Deterministic for a given seed.

const MELEE_STOP_M: float = 3.5
const WANDER_RETARGET_S: float = 4.0

var client: NetClient
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _wander_goal: Vector3 = Vector3.ZERO
var _ticks_since_tab: int = 999
var _ticks_since_wander: int = 999


func _init(p_client: NetClient, seed_value: int) -> void:
	client = p_client
	rng.seed = seed_value


## Called once per tick by the client; returns this tick's raw input.
func next_input() -> Dictionary:
	var me: Unit = client.predicted
	var input: Dictionary = {"move": Vector2.ZERO, "yaw": me.facing, "jump": false, "tab": false}
	if not me.is_alive():
		return input
	_ticks_since_tab += 1
	_ticks_since_wander += 1
	var target_pos: Variant = _target_position(me.target_id)
	if target_pos == null:
		if _ticks_since_tab >= 60:  # try to acquire a target once a second
			input["tab"] = true
			_ticks_since_tab = 0
		if _ticks_since_wander >= int(WANDER_RETARGET_S * 60) or me.position.distance_to(_wander_goal) < 1.0:
			_wander_goal = Vector3(rng.randf_range(-15, 15), 0, rng.randf_range(-15, 15))
			_ticks_since_wander = 0
		return _steer(me, input, _wander_goal, 0.5)
	return _steer(me, input, target_pos, MELEE_STOP_M)


func _steer(me: Unit, input: Dictionary, goal: Vector3, stop_at: float) -> Dictionary:
	var to: Vector3 = goal - me.position
	to.y = 0.0
	if to.length() > 0.01:
		input["yaw"] = atan2(-to.x, -to.z)  # yaw so that forward (-Z rotated) points at the goal
	input["move"] = Vector2(0, 1) if to.length() > stop_at else Vector2.ZERO
	input["jump"] = rng.randf() < 0.002
	return input


func _target_position(target_id: int) -> Variant:
	if target_id < 0:
		return null
	for u: Dictionary in client.world_view().get("units", []):
		if u["id"] == target_id:
			return u["position"] if u["health"] > 0 else null
	return null
