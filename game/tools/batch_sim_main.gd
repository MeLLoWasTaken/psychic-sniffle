extends Node
## Batch arena simulation with bots, in one process and faster than real time (backlog M1-13,
## and the balance simulations of the review pass). Uses the same MatchRunner as the server.
##
##   godot --headless --path game -s res://tools/batch_sim.gd -- --matches 100 \
##     --comp warblade_carnage+oracle_grace:arcanist_rime+oracle_grace --out /abs/report.json
## A spec may name a talent build from its bot profile: warblade_carnage@bleed ("@none" for no
## talents; a bare spec plays its first build). The summary reports each spec@build too.
## --comp may be given several times (matches are spread across comps; team sides alternate).
## Prints one line per match and a summary; exits 1 if any match raised an error.

var _results: Array = []
var _team1_first: bool = false
var _trace_path: String = ""
var _builds: Dictionary = {}  ## unit id -> talent build name (per match)
var _build_nodes: Dictionary = {}  ## "spec@build" -> the talent nodes it takes (Talents.picked_nodes)


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var matches: int = int(_arg(args, "--matches", "10"))
	var seed_base: int = int(_arg(args, "--seed", "1"))
	var out: String = _arg(args, "--out", "")
	_team1_first = "--team1-first" in args  # create team 1's units first (lower ids), to test ordering bias
	_trace_path = _arg(args, "--trace", "")  # write the first match's full event log here
	var max_minutes: float = float(_arg(args, "--max-minutes", "20"))
	var comps: Array = []
	for i: int in args.size():
		if args[i] == "--comp" and i + 1 < args.size():
			comps.append(args[i + 1])
	if comps.is_empty():
		comps = ["warblade_carnage+oracle_grace:arcanist_rime+oracle_grace"]
	var t0: int = Time.get_ticks_msec()
	for m: int in matches:
		var comp: String = comps[m % comps.size()]
		var sides: PackedStringArray = comp.split(":")
		var swap: bool = (m / comps.size()) % 2 == 1  # alternate sides so spawn position is not a factor
		var team_specs: Array = [sides[1].split("+"), sides[0].split("+")] if swap else [sides[0].split("+"), sides[1].split("+")]
		var r: Dictionary = _run_match(team_specs, seed_base + m, max_minutes)
		r["comp"] = comp
		r["swapped"] = swap
		_results.append(r)
		print("match %3d  %-60s winner %2d  %6.1f s  %s" % [m + 1, comp, r["winner"], r["seconds"], r["end_reason"]])
	var summary: Dictionary = _summarise()
	summary["wall_seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
	print(JSON.stringify(summary["headline"], "  "))
	if out != "":
		var f: FileAccess = FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify({"summary": summary, "matches": _results}, "  "))
		f.close()
	get_tree().quit(1 if summary["headline"]["errors"] > 0 else 0)


func _run_match(team_specs: Array, seed_value: int, max_minutes: float) -> Dictionary:
	var map: Dictionary = Data.maps["gallows_courtyard"]
	var bracket: String = "%dv%d" % [team_specs[0].size(), team_specs[1].size()]
	var runner: MatchRunner = MatchRunner.new(map, "arena", bracket, 0.0, seed_value)
	var brains: Dictionary = {}
	var nav: NavGrid = NavGrid.new(runner.geometry)
	for team: int in ([1, 0] if _team1_first else [0, 1]):
		for entry: String in team_specs[team]:
			var spec: String = entry.get_slice("@", 0)
			var build: Dictionary = BotBrain.build_talents(spec, entry.get_slice("@", 1) if "@" in entry else "")
			var u: Unit = runner.add_unit(spec, team, build["talents"])
			_builds[u.id] = build["name"]
			var bkey: String = "%s@%s" % [spec, build["name"]]
			if not _build_nodes.has(bkey):
				_build_nodes[bkey] = Talents.picked_nodes(u.loadout, Talents.trees_for(spec, Data.specs, Data.classes, Data.talents))
			brains[u.id] = BotBrain.new(spec, seed_value * 100 + u.id, runner.geometry, nav)
			brains[u.id].explain = _trace_path != "" and _results.is_empty()
	var errors_before: int = Log.error_count
	var stats: Dictionary = {}
	for uid: int in brains:
		stats[uid] = {"spec": runner.sim.units[uid].spec_id, "build": _builds.get(uid, "none"), "team": runner.sim.units[uid].team, "damage": 0,
			"healing": 0, "casts": 0, "interrupts": 0, "cc": 0, "failed": {}, "died": false}
	runner.sim.add_system(runner.bot_system(brains))
	runner.sim.add_system(runner.system_combat_and_rules)
	var limit: int = roundi(max_minutes * 60.0 * runner.sim.tick_rate)
	var end_reason: String = "limit"
	var first_death: Dictionary = {}
	var trace: Array = []
	var tracing: bool = _trace_path != "" and _results.is_empty()
	while runner.sim.tick < limit:
		runner.sim.step()
		if tracing and runner.sim.tick % 60 == 0:
			var snap: Array = []
			for u: Unit in runner.sim.units.values():
				snap.append({"id": u.id, "hp": u.health, "pos": [snappedf(u.position.x, 0.1), snappedf(u.position.z, 0.1)],
					"res": snappedf(float(u.resources.get(u.primary_resource, 0.0)), 1), "target": u.target_id,
					"cast": u.cast.get("ability", ""), "gcd": u.gcd_ready_tick, "why": brains[u.id].explanation.duplicate()})
			trace.append({"tick": runner.sim.tick, "type": "state", "units": snap})
		for ev: Dictionary in runner.take_events():
			if tracing:
				trace.append(ev)
			var src: int = int(ev.get("source", -1))
			match ev["type"]:
				"damage":
					if stats.has(src):
						stats[src]["damage"] += int(ev["amount"])
					if ev["killed"] and stats.has(int(ev["target"])):
						stats[int(ev["target"])]["died"] = true
						if first_death.is_empty():
							first_death = {"spec": stats[int(ev["target"])]["spec"], "team": stats[int(ev["target"])]["team"],
								"killer": stats[src]["spec"] if stats.has(src) else "", "ability": ev.get("ability", ""),
								"second": runner.arena.match_seconds(runner.sim.tick)}
				"heal":
					if stats.has(src):
						stats[src]["healing"] += int(ev["amount"])
				"cast_success":
					if stats.has(src):
						stats[src]["casts"] += 1
				"interrupt":
					if stats.has(src):
						stats[src]["interrupts"] += 1
				"aura_applied":
					if ev.get("cc", "none") != "none" and stats.has(src):
						stats[src]["cc"] += 1
				"cast_failed":
					if stats.has(src):
						var f: Dictionary = stats[src]["failed"]
						f[ev["reason"]] = int(f.get(ev["reason"], 0)) + 1
				"match_end":
					end_reason = ev["reason"]
		if runner.ended():
			break
	for uid: int in brains:
		stats[uid]["stuck"] = brains[uid].stuck_count
		if tracing:
			trace.append({"type": "stuck_log", "unit": uid, "spec": stats[uid]["spec"], "log": brains[uid].stuck_log})
	var result: Dictionary = {"winner": runner.arena.winner_team, "seconds": runner.arena.match_seconds(runner.sim.tick),
		"end_reason": end_reason, "first_death": first_death, "units": stats, "errors": Log.error_count - errors_before,
		"state_hash": runner.sim.state_hash()}
	if tracing:
		var f: FileAccess = FileAccess.open(_trace_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(trace))
		f.close()
	runner.sim._systems.clear()  # break the runner <-> system reference cycle so nothing leaks
	return result


func _summarise() -> Dictionary:
	var n: int = _results.size()
	var kills: int = 0
	var errors: int = 0
	var secs: float = 0.0
	var spec: Dictionary = {}
	var builds: Dictionary = {}
	for r: Dictionary in _results:
		if r["end_reason"] == "team_eliminated":
			kills += 1
		errors += int(r["errors"])
		secs += float(r["seconds"])
		for uid: Variant in r["units"]:
			var u: Dictionary = r["units"][uid]
			var s: Dictionary = spec.get(u["spec"], {"games": 0, "wins": 0, "damage": 0, "healing": 0, "interrupts": 0, "cc": 0, "deaths": 0, "stuck": 0})
			s["games"] += 1
			s["wins"] += 1 if r["winner"] == u["team"] else 0
			s["damage"] += u["damage"]
			s["healing"] += u["healing"]
			s["interrupts"] += u["interrupts"]
			s["cc"] += u["cc"]
			s["deaths"] += 1 if u["died"] else 0
			s["stuck"] += int(u.get("stuck", 0))
			spec[u["spec"]] = s
			var bk: String = "%s@%s" % [u["spec"], u.get("build", "none")]
			var bs: Dictionary = builds.get(bk, {"games": 0, "wins": 0})
			bs["games"] += 1
			bs["wins"] += 1 if r["winner"] == u["team"] else 0
			builds[bk] = bs
	for k: String in builds:
		builds[k]["win_rate"] = float(builds[k]["wins"]) / builds[k]["games"]
		builds[k]["nodes"] = _build_nodes.get(k, [])
	for k: String in spec:
		var s: Dictionary = spec[k]
		s["win_rate"] = float(s["wins"]) / s["games"]
		for f: String in ["damage", "healing", "interrupts", "cc", "deaths", "stuck"]:
			s[f + "_per_game"] = float(s[f]) / s["games"]
	return {"headline": {"matches": n, "ended_by_kill": kills, "kill_rate": float(kills) / maxi(n, 1),
		"avg_seconds": secs / maxi(n, 1), "errors": errors}, "specs": spec, "builds": builds}


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
