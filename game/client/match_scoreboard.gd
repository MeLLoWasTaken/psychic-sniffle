class_name MatchScoreboard
extends RefCounted
## Per-unit match totals for the end screen (backlog M1-28), counted on the client from the
## combat events the server sends (the same dictionaries MatchRunner.take_events produces), so
## the numbers are exactly what happened on the server.
##
## - damage: health removed plus damage soaked by absorb shields (`amount` + `absorbed`)
## - healing: effective healing (`amount`; overhealing is not counted)
## - kills: killing blows (`killed` on a damage event); deaths: the victims
## - interrupts: successful interrupts (`interrupt` events)
##
##   var board: MatchScoreboard = MatchScoreboard.new()
##   board.add_units(view)      # names, specs and teams from any world view
##   board.add_events(events)   # every tick's events
##   board.rows_for_team(0)

const STATS: Array[String] = ["damage", "healing", "kills", "deaths", "interrupts"]

var rows: Dictionary = {}  ## unit id -> {id, team, spec, alive, damage, healing, kills, deaths, interrupts}
var events_counted: int = 0


## Register the units of a world view (spec, team, alive). Safe to call every tick.
func add_units(view: Dictionary) -> void:
	for u: Dictionary in view.get("units", []):
		var r: Dictionary = _row(int(u["id"]))
		r["team"] = int(u["team"])
		r["spec"] = str(u["spec"])
		r["alive"] = int(u["health"]) > 0


## Count one batch of combat events.
func add_events(evs: Array) -> void:
	for ev: Dictionary in evs:
		var src: int = int(ev.get("source", -1))
		match str(ev.get("type", "")):
			"damage":
				events_counted += 1
				if src >= 0:
					_row(src)["damage"] += int(ev.get("amount", 0)) + int(ev.get("absorbed", 0))
				if bool(ev.get("killed", false)):
					if src >= 0:
						_row(src)["kills"] += 1
					_row(int(ev["target"]))["deaths"] += 1
					_row(int(ev["target"]))["alive"] = false
			"heal":
				events_counted += 1
				if src >= 0:
					_row(src)["healing"] += int(ev.get("amount", 0))
			"interrupt":
				events_counted += 1
				if src >= 0:
					_row(src)["interrupts"] += 1


## A unit's totals ({} values are zero for a unit never seen).
func row(id: int) -> Dictionary:
	return rows.get(id, _blank(id))


## One team's rows, most damage first.
func rows_for_team(team: int) -> Array:
	var out: Array = rows.values().filter(func(r: Dictionary) -> bool: return int(r["team"]) == team)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["damage"]) > int(b["damage"]) if int(a["damage"]) != int(b["damage"]) else int(a["id"]) < int(b["id"]))
	return out


## Sums of every stat over a team.
func team_totals(team: int) -> Dictionary:
	var t: Dictionary = {}
	for s: String in STATS:
		t[s] = 0
	for r: Dictionary in rows_for_team(team):
		for s: String in STATS:
			t[s] += int(r[s])
	return t


## Plain data for reports and tests: unit id (as a string) -> row.
func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for id: int in rows:
		out[str(id)] = (rows[id] as Dictionary).duplicate()
	return out


func _row(id: int) -> Dictionary:
	if not rows.has(id):
		rows[id] = _blank(id)
	return rows[id]


static func _blank(id: int) -> Dictionary:
	return {"id": id, "team": -1, "spec": "", "alive": true, "damage": 0, "healing": 0, "kills": 0,
		"deaths": 0, "interrupts": 0}
