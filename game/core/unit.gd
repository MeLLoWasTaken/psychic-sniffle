class_name Unit
extends RefCounted
## One combatant in the simulation. Plain data; systems in game/core change it.
## Times are stored as simulation ticks so everything is deterministic.

var id: int
var team: int
var spec_id: String
var class_id: String = ""
var armor: String = "plate"
var weapon_type: String = "sword"
var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var facing: float = 0.0  ## radians around the up axis; 0 faces -Z (Godot forward)
var health: int = 1
var max_health: int = 1
var resources: Dictionary = {}  ## resource name -> current amount
var resource_max: Dictionary = {}  ## resource name -> maximum
var primary_resource: String = ""
## Whole-unit resources (runes): resource name -> seconds left on each spent unit's recharge, in
## the order they recharge; the first `recharging_at_once` count down together (Combat).
var recharges: Dictionary = {}
var auras: Array[Dictionary] = []  ## active aura instances (see Combat.apply_aura)
var target_id: int = -1
var swing_timer: float = 0.0

# ability state
var known_abilities: Array[String] = []
var cooldowns: Dictionary = {}  ## ability id -> tick when ready again
var gcd_ready_tick: int = 0
var cast: Dictionary = {}  ## current cast or channel; empty when idle
var queued: Dictionary = {}  ## ability press waiting for the GCD or a cast to finish
var school_locks: Dictionary = {}  ## school -> tick when the interrupt lock ends
var dr: Dictionary = {}  ## crowd-control category -> {count, reset_tick}
var combat_until_tick: int = 0
var stats: Dictionary = {"power_bonus": 0.0, "haste": 0.0, "crit_chance": 0.1}
var moved_this_tick: bool = false
var displaced_tick: int = -1  ## last tick an ability moved this unit (charge, blink, knockback)
var loadout: Dictionary = {}  ## talent picks (see Talents); applied by Combat.init_unit
var queue_window_ticks: int = -1  ## the player's spell queue window (M2-13); -1 uses the tuning's
var auto_self_cast: bool = true  ## an ally ability with no friendly target goes to the caster
var talent_abilities: Dictionary = {}  ## ability id -> this unit's talented copy
var talent_auras: Dictionary = {}  ## aura id -> this unit's talented copy


func _init(p_id: int, p_team: int, p_spec_id: String = "", p_max_health: int = 60000) -> void:
	id = p_id
	team = p_team
	spec_id = p_spec_id
	max_health = p_max_health
	health = p_max_health


func is_alive() -> bool:
	return health > 0


func is_casting() -> bool:
	return not cast.is_empty()


## Deterministic text form used for state hashing. Floats are rounded so tiny
## representation differences cannot change the hash.
func snapshot_string() -> String:
	var res_keys: Array = resources.keys()
	res_keys.sort()
	var res_parts: PackedStringArray = []
	for k: String in res_keys:
		res_parts.append("%s=%.4f" % [k, resources[k]])
		if not (recharges.get(k, []) as Array).is_empty():
			res_parts.append("%s~%s" % [k, ",".join((recharges[k] as Array).map(func(t: float) -> String: return "%.4f" % t))])
	var aura_parts: PackedStringArray = []
	for a: Dictionary in auras:
		aura_parts.append("%s:%d:%d:%d" % [a["id"], a["source"], a["expires_tick"], a["stacks"]])
	var cd_keys: Array = cooldowns.keys()
	cd_keys.sort()
	var cd_parts: PackedStringArray = []
	for k: String in cd_keys:
		cd_parts.append("%s=%d" % [k, cooldowns[k]])
	return "%d|%d|%s|%.4f,%.4f,%.4f|%.4f,%.4f,%.4f|%.4f|%d/%d|%s|%s|%d|%.4f|%s|%d|%s" % [
		id, team, spec_id, position.x, position.y, position.z, velocity.x, velocity.y, velocity.z,
		facing, health, max_health, ",".join(res_parts), ";".join(aura_parts), target_id, swing_timer,
		",".join(cd_parts), gcd_ready_tick, str(cast.get("ability", "")) + "@" + str(cast.get("end_tick", 0))]
