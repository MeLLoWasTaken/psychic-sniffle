class_name CombatBasic
extends RefCounted
## M0 combat: tab targeting and melee auto-attack, run by the server each tick.
## Full abilities, auras and the damage formula arrive in M1-01..M1-05.

const TAB_CONE_DOT: float = 0.0  ## "in front" = within 90 degrees either side of facing
const TAB_MAX_RANGE: float = 40.0
const EYE_HEIGHT: float = 1.6
const CHEST_HEIGHT: float = 1.2

var range_m: float = 5.0
var swing_interval: float = 2.0
var base_damage: int = 1200
var geometry: ArenaGeometry
var events: Array[Dictionary] = []  ## combat log for this tick; cleared by the caller


func _init(tuning: Dictionary, p_geometry: ArenaGeometry) -> void:
	var aa: Dictionary = tuning.get("damage", {}).get("auto_attack", {})
	range_m = float(aa.get("range_m", range_m))
	swing_interval = float(aa.get("swing_interval_s", swing_interval))
	base_damage = int(aa.get("base_damage", base_damage))
	geometry = p_geometry


## Nearest living enemy in front of `unit` (within 90 degrees of facing, 40 m, in sight).
## Falls back to the nearest living enemy anywhere in range when none is in front.
func tab_target(unit: Unit, units: Dictionary) -> int:
	var fwd: Vector3 = Movement.forward_of(unit.facing)
	var best_front: int = -1
	var best_front_d: float = INF
	var best_any: int = -1
	var best_any_d: float = INF
	for other: Unit in units.values():
		if other.team == unit.team or not other.is_alive():
			continue
		var to: Vector3 = other.position - unit.position
		to.y = 0.0
		var d: float = to.length()
		if d > TAB_MAX_RANGE or not _sees(unit, other):
			continue
		if d < best_any_d:
			best_any_d = d
			best_any = other.id
		if d > 1e-6 and fwd.dot(to / d) >= TAB_CONE_DOT and d < best_front_d:
			best_front_d = d
			best_front = other.id
	return best_front if best_front != -1 else best_any


## Swing timers run only while the target is valid and in range; a swing lands the moment
## the timer reaches the interval.
func update_auto_attack(unit: Unit, units: Dictionary, dt: float, tick: int) -> void:
	var target: Unit = units.get(unit.target_id)
	if not unit.is_alive() or target == null or not target.is_alive() or target.team == unit.team:
		unit.swing_timer = 0.0
		return
	if unit.position.distance_to(target.position) > range_m or not _sees(unit, target):
		unit.swing_timer = minf(unit.swing_timer + dt, swing_interval)  # ready to swing on arrival
		return
	unit.swing_timer += dt
	if unit.swing_timer + 1e-9 >= swing_interval:
		unit.swing_timer = 0.0
		target.health = maxi(target.health - base_damage, 0)
		events.append({"tick": tick, "type": "damage", "source": unit.id, "target": target.id,
			"ability": "auto_attack", "amount": base_damage, "killed": target.health == 0})


func _sees(a: Unit, b: Unit) -> bool:
	if geometry == null:
		return true
	return geometry.has_line_of_sight(a.position + Vector3.UP * EYE_HEIGHT,
		b.position + Vector3.UP * CHEST_HEIGHT)
