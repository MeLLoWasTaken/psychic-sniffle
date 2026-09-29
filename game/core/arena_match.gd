class_name ArenaMatch
extends RefCounted
## Arena match rules (backlog M1-09): preparation phase behind closed gates, dampening, win
## when a team is fully dead, draw at the time limit. Numbers come from tuning.json "arena".

enum Phase { PREP, ACTIVE, ENDED }

var phase: Phase = Phase.PREP
var bracket: String = "2v2"
var tick_rate: int = 60
var start_tick: int = 0  ## tick the gates opened (or will open)
var prep_ticks: int
var dampening_start_ticks: int
var dampening_step: float
var dampening_interval_ticks: int
var time_limit_ticks: int
var winner_team: int = -1  ## -1 while running; -2 for a draw
var geometry: ArenaGeometry
var events: Array[Dictionary] = []


func _init(tuning: Dictionary, p_bracket: String, p_tick_rate: int, p_geometry: ArenaGeometry,
		now_tick: int = 0) -> void:
	var a: Dictionary = tuning["arena"]
	bracket = p_bracket
	tick_rate = p_tick_rate
	geometry = p_geometry
	prep_ticks = roundi(float(a["prep_phase_s"]) * tick_rate)
	var damp_s: float = a["dampening_start_1v1_s"] if bracket == "1v1" else a["dampening_start_s"]
	dampening_start_ticks = roundi(float(damp_s) * tick_rate)
	dampening_step = float(a["dampening_step_pct"]) / 100.0
	dampening_interval_ticks = roundi(float(a["dampening_interval_s"]) * tick_rate)
	var limit_s: float = a["time_limit_1v1_s"] if bracket == "1v1" else a["time_limit_s"]
	time_limit_ticks = roundi(float(limit_s) * tick_rate)
	start_tick = now_tick + prep_ticks
	if geometry:
		geometry.gates_open = false


## Seconds of match time since the gates opened (negative during preparation).
func match_seconds(tick: int) -> float:
	return float(tick - start_tick) / tick_rate


## Healing multiplier from dampening: 1.0 until the start, then down 1% every interval.
func healing_multiplier(tick: int) -> float:
	var since: int = tick - start_tick - dampening_start_ticks
	if phase != Phase.ACTIVE or since < 0:
		return 1.0
	var steps: int = since / dampening_interval_ticks + 1
	return maxf(0.0, 1.0 - steps * dampening_step)


func dampening_pct(tick: int) -> int:
	return roundi((1.0 - healing_multiplier(tick)) * 100.0)


## Advance the rules one tick. Call after combat has run.
func update(tick: int, units: Dictionary) -> void:
	match phase:
		Phase.PREP:
			if tick >= start_tick:
				phase = Phase.ACTIVE
				if geometry:
					geometry.gates_open = true
				events.append({"tick": tick, "type": "gates_open"})
		Phase.ACTIVE:
			var alive: Dictionary = {}
			var teams: Dictionary = {}
			for u: Unit in units.values():
				teams[u.team] = true
				if u.is_alive():
					alive[u.team] = true
			if teams.size() >= 2 and alive.size() <= 1:
				winner_team = alive.keys()[0] if alive.size() == 1 else -2
				_end(tick, "team_eliminated")
			elif tick - start_tick >= time_limit_ticks:
				winner_team = -2
				_end(tick, "time_limit")


func _end(tick: int, reason: String) -> void:
	phase = Phase.ENDED
	events.append({"tick": tick, "type": "match_end", "winner": winner_team, "reason": reason})
