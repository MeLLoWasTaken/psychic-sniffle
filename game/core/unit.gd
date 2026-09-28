class_name Unit
extends RefCounted
## One combatant in the simulation. Plain data; systems in game/core change it.

var id: int
var team: int
var spec_id: String
var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var facing: float = 0.0  ## radians around the up axis; 0 faces -Z (Godot forward)
var health: int = 1
var max_health: int = 1
var resources: Dictionary = {}  ## resource name -> float
var auras: Array[Dictionary] = []  ## active aura instances


func _init(p_id: int, p_team: int, p_spec_id: String = "", p_max_health: int = 60000) -> void:
	id = p_id
	team = p_team
	spec_id = p_spec_id
	max_health = p_max_health
	health = p_max_health


func is_alive() -> bool:
	return health > 0


## Deterministic text form used for state hashing. Floats are rounded so tiny
## representation differences cannot change the hash.
func snapshot_string() -> String:
	var res_keys: Array = resources.keys()
	res_keys.sort()
	var res_parts: PackedStringArray = []
	for k: String in res_keys:
		res_parts.append("%s=%.4f" % [k, resources[k]])
	return "%d|%d|%s|%.4f,%.4f,%.4f|%.4f|%d/%d|%s|%d" % [
		id, team, spec_id, position.x, position.y, position.z, facing,
		health, max_health, ",".join(res_parts), auras.size()]
