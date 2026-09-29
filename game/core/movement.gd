class_name Movement
extends RefCounted
## Character movement rules shared by the server simulation and client prediction.
## Input dictionary: {move: Vector2 (x = strafe right, y = forward, length <= 1), yaw: float,
## jump: bool}. Yaw 0 faces -Z (Godot forward).

var run_speed: float = 7.0
var backpedal_mult: float = 0.6
var jump_velocity: float = 8.0
var gravity: float = 20.0
var geometry: ArenaGeometry


func _init(tuning: Dictionary, p_geometry: ArenaGeometry) -> void:
	var m: Dictionary = tuning.get("movement", {})
	run_speed = float(m.get("run_speed_mps", run_speed))
	backpedal_mult = float(m.get("backpedal_speed_mult", backpedal_mult))
	jump_velocity = float(m.get("jump_velocity_mps", jump_velocity))
	gravity = float(m.get("gravity_mps2", gravity))
	geometry = p_geometry


static func forward_of(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


static func right_of(yaw: float) -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


## Advance one unit by one tick. `speed_mult` covers slows and roots (0 = rooted).
func apply(unit: Unit, input: Dictionary, dt: float, speed_mult: float = 1.0) -> void:
	unit.facing = float(input.get("yaw", unit.facing))
	var move: Vector2 = input.get("move", Vector2.ZERO)
	if move.length() > 1.0:
		move = move.normalized()
	var speed: float = run_speed * speed_mult
	if move.y < 0.0:
		speed *= backpedal_mult
	var on_ground: bool = unit.position.y <= 0.0001
	var horizontal: Vector3 = (forward_of(unit.facing) * move.y + right_of(unit.facing) * move.x) * speed
	if on_ground:
		unit.velocity.x = horizontal.x
		unit.velocity.z = horizontal.z
		unit.velocity.y = jump_velocity if bool(input.get("jump", false)) and speed_mult > 0.0 else 0.0
	else:
		unit.velocity.y -= gravity * dt  # no air steering: momentum carries through a jump
	var next: Vector3 = unit.position + unit.velocity * dt
	if next.y < 0.0:
		next.y = 0.0
		unit.velocity.y = 0.0
	unit.position = geometry.resolve(next) if geometry else next
