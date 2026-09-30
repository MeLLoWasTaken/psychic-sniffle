class_name NetServer
extends Node
## Dedicated, authoritative match server.
##
## Command line (after `--`): --server [--port 24600] [--map gallows_courtyard]
##   [--mode skirmish|arena] [--bracket 2v2] [--prep-seconds 60] [--match-seconds 300]
##   [--respawn] [--summary /abs/path.json] [--seed 1]
##   [--roster player:0,partner:0,enemy1:1,enemy2:1] [--host player] [--ready-file /abs/path]
## skirmish: free-for-all testing mode with optional respawns and no match rules.
## arena: preparation phase behind gates, dampening, and a winner (backlog M1-09); the server
##   writes its summary and exits a few seconds after the match ends.
## Runs the simulation at the tuning tick rate in _physics_process, applies one buffered input
## per client per tick, and sends every client a snapshot after every tick.
##
## Hosted matches (M1-28, a game client starts this server for "Play 2v2 vs bots"):
##   --roster: the names allowed to join and their teams; other names are rejected. In arena
##     mode the preparation countdown holds until the whole roster has joined, so nobody loses
##     preparation time to loading.
##   --host: the client that owns this server. If it has not joined within HOST_JOIN_TIMEOUT_S,
##     disconnects, or sends nothing for HOST_SILENCE_S, the server writes its summary and exits
##     (no server outlives the game that started it).
##   --ready-file: written once the server listens, so the launcher knows when to connect.

const CATCH_UP_BUFFER: int = 6  ## above this many queued inputs, apply two per tick to catch up
const GAP_GIVE_UP_INPUTS: int = 4  ## a missing input is treated as lost once this many newer ones are queued
const RESPAWN_S: float = 5.0
const END_LINGER_S: float = 3.0
const HOST_JOIN_TIMEOUT_S: float = 60.0
const HOST_SILENCE_S: float = 15.0

var transport: NetTransport = NetTransport.new()
var runner: MatchRunner
var sim: Sim
var combat: Combat
var arena: ArenaMatch
var map: Dictionary
var mode: String = "skirmish"
var port: int = 24600
var match_seconds: float = 0.0
var respawn: bool = false
var summary_path: String = ""

var clients: Dictionary = {}  ## peer instance id -> client record
var input_log_path: String = ""  ## --input-log: write the match's input log here on finish (M1-29)
var _tick_usec: PackedInt64Array = []
var _stats: Dictionary = {"damage_events": 0, "kills": 0, "heals": 0, "casts": 0, "interrupts": 0,
	"snapshots_sent": 0, "by_unit": {}}
var _dead_since: Dictionary = {}  ## unit id -> tick of death
var _last_report_tick: int = 0
var _finished: bool = false
var _ended_tick: int = -1
var _departed: Dictionary = {}  ## name -> stats of clients that already left
var _unit_names: Dictionary = {}  ## client name -> unit id, kept after the client leaves
var roster: Dictionary = {}  ## name -> team (hosted matches); empty = anyone joins, teams alternate
var host_name: String = ""  ## the client that owns this server (hosted matches), or ""
var end_reason: String = ""  ## why the server finished: match_end, time_limit, host_left...
var _started_usec: int = 0
var _host_seen: bool = false
var _host_last_usec: int = 0


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	port = int(_arg(args, "--port", "24600"))
	match_seconds = float(_arg(args, "--match-seconds", "0"))
	respawn = "--respawn" in args
	summary_path = _arg(args, "--summary", "")
	roster = parse_roster(_arg(args, "--roster", ""))
	host_name = _arg(args, "--host", "")
	mode = _arg(args, "--mode", "skirmish")
	var map_id: String = _arg(args, "--map", "gallows_courtyard")
	map = Data.maps.get(map_id, {})
	if map.is_empty():
		Log.error("server: unknown map %s" % map_id)
		get_tree().quit(1)
		return
	Engine.physics_ticks_per_second = Data.tick_rate()
	Engine.max_fps = 240  # poll the network often (accurate latency), without spinning the CPU
	var prep: float = float(_arg(args, "--prep-seconds", "-1"))
	runner = MatchRunner.new(map, mode, _arg(args, "--bracket", "2v2"), prep, int(_arg(args, "--seed", "1")))
	input_log_path = _arg(args, "--input-log", "")
	if input_log_path != "":
		runner.record()  # every input and world edit, for the replay test (M1-29)
	sim = runner.sim
	combat = runner.combat
	arena = runner.arena
	sim.add_system(_system_inputs_and_movement)
	sim.add_system(runner.system_combat_and_rules)
	sim.add_system(_system_rules)
	var err: Error = transport.start_server(port)
	if err != OK:
		Log.error("server: cannot listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	Log.info("server: listening on port %d, map %s, mode %s, tick %d Hz" % [port, map_id, mode, sim.tick_rate])
	_started_usec = Time.get_ticks_usec()
	var ready_file: String = _arg(args, "--ready-file", "")
	if ready_file != "":
		var rf: FileAccess = FileAccess.open(ready_file, FileAccess.WRITE)
		rf.store_string(str(OS.get_process_id()))
		rf.close()


## "player:0,partner:0,enemy1:1" -> {"player": 0, "partner": 0, "enemy1": 1}.
static func parse_roster(text: String) -> Dictionary:
	var out: Dictionary = {}
	for part: String in text.split(",", false):
		var kv: PackedStringArray = part.strip_edges().split(":")
		if kv.size() == 2:
			out[kv[0]] = int(kv[1])
	return out


func _process(_delta: float) -> void:
	if sim and not _finished:
		_handle_network()  # between ticks too, so replies (pongs) are not held for a tick


func _physics_process(_delta: float) -> void:
	if _finished or sim == null:
		return
	_handle_network()
	if _finished:
		return
	if _check_host():
		return
	if arena and not roster.is_empty() and clients.size() < roster.size():
		runner.hold_prep()  # preparation starts when everyone is in
	var t0: int = Time.get_ticks_usec()
	sim.step()
	_tick_usec.append(Time.get_ticks_usec() - t0)
	_send_snapshots()
	if sim.tick - _last_report_tick >= sim.tick_rate * 10:
		_last_report_tick = sim.tick
		Log.info("server: t=%.0f s, %d clients, tick avg %.3f ms" % [sim.time_s(), clients.size(), _avg_tick_ms()])
	if match_seconds > 0.0 and sim.time_s() >= match_seconds:
		end_reason = "time_limit"
		_finish()
	elif _ended_tick >= 0 and sim.tick - _ended_tick >= int(END_LINGER_S * sim.tick_rate):
		end_reason = "match_end"
		_finish()


## Hosted matches: finish when the host never came, left, or went silent. True when finished.
func _check_host() -> bool:
	if host_name == "":
		return false
	var now: int = Time.get_ticks_usec()
	var reason: String = ""
	if not _host_seen and (now - _started_usec) / 1e6 > HOST_JOIN_TIMEOUT_S:
		reason = "host_never_joined"
	elif _host_seen and (now - _host_last_usec) / 1e6 > HOST_SILENCE_S:
		reason = "host_silent"
	if reason == "":
		return false
	Log.info("server: finishing (%s)" % reason)
	end_reason = reason
	_finish()
	return true


# ------------------------------------------------------------------ network

func _handle_network() -> void:
	for ev: Dictionary in transport.poll():
		var peer: ENetPacketPeer = ev["peer"]
		var key: int = peer.get_instance_id()
		match ev["type"]:
			"connect":
				Log.info("server: peer connected")
			"disconnect":
				if clients.has(key):
					var c: Dictionary = clients[key]
					Log.info("server: %s disconnected" % c["name"])
					_departed[c["name"]] = _client_stats(c)
					if mode != "arena":
						runner.remove_unit(int(c["unit_id"]))  # arena keeps the unit so the match can finish
					clients.erase(key)
					if host_name != "" and c["name"] == host_name and not _finished:
						Log.info("server: the host left; finishing")
						end_reason = "host_left"
						_finish()
						return
			"receive":
				var from: Dictionary = clients.get(key, {})
				if host_name != "" and not from.is_empty() and from["name"] == host_name:
					_host_last_usec = Time.get_ticks_usec()
				_on_packet(peer, key, Protocol.decode(ev["data"]))


func _on_packet(peer: ENetPacketPeer, key: int, msg: Dictionary) -> void:
	match msg.get("type", 0):
		Protocol.Msg.HELLO:
			if msg["version"] != Protocol.VERSION:
				transport.send(peer, Protocol.CH_RELIABLE, Protocol.reject("protocol version mismatch"), true)
				Log.warn("server: rejected client with protocol version %d" % msg["version"])
				return
			if not Data.specs.has(msg["spec"]):
				transport.send(peer, Protocol.CH_RELIABLE, Protocol.reject("unknown spec"), true)
				Log.warn("server: rejected client with unknown spec %s" % msg["spec"])
				return
			if not roster.is_empty():
				var taken: bool = clients.values().any(func(c: Dictionary) -> bool: return c["name"] == msg["name"])
				if not roster.has(msg["name"]) or taken:
					transport.send(peer, Protocol.CH_RELIABLE, Protocol.reject("not in the roster"), true)
					Log.warn("server: rejected %s (not in the roster, or already joined)" % msg["name"])
					return
			_add_client(peer, key, msg["name"], msg["spec"])
		Protocol.Msg.INPUT:
			var c: Dictionary = clients.get(key, {})
			if c.is_empty():
				return
			for inp: Dictionary in msg["inputs"]:
				_queue_input(c, inp)
		Protocol.Msg.PING:
			transport.send(peer, Protocol.CH_RELIABLE, Protocol.pong(msg["t_usec"]), true)


## Keep every input not yet applied, sorted by sequence number, without duplicates. Packets
## can arrive out of order; each carries the last few inputs, so a lost packet is usually
## covered by the next one.
func _queue_input(c: Dictionary, inp: Dictionary) -> void:
	var seq: int = int(inp["seq"])
	if seq <= int(c["ack_seq"]):
		return
	var queue: Array = c["inputs"]
	var i: int = queue.size()
	while i > 0 and int(queue[i - 1]["seq"]) >= seq:
		if int(queue[i - 1]["seq"]) == seq:
			return
		i -= 1
	queue.insert(i, inp)
	c["last_received_seq"] = maxi(int(c["last_received_seq"]), seq)


func _client_stats(c: Dictionary) -> Dictionary:
	var secs: float = (sim.tick - int(c["joined_tick"])) / float(sim.tick_rate)
	return {"snapshots_sent": c["snapshots"], "seconds": secs, "spec": c["spec"],
		"snapshot_rate_hz": c["snapshots"] / secs if secs > 0 else 0.0, "starved_ticks": c["starved_ticks"],
		"lost_inputs": c["lost_inputs"]}


func _add_client(peer: ENetPacketPeer, key: int, player_name: String, spec_id: String) -> void:
	var team: int = int(roster.get(player_name, clients.size() % 2))
	var unit: Unit = runner.add_unit(spec_id, team)
	_unit_names[player_name] = unit.id
	clients[key] = {"peer": peer, "name": player_name, "spec": spec_id, "unit_id": unit.id, "inputs": [],
		"last_received_seq": 0, "ack_seq": 0, "snapshots": 0, "starved_ticks": 0, "lost_inputs": 0,
		"joined_tick": sim.tick}
	transport.send(peer, Protocol.CH_RELIABLE, Protocol.welcome(unit.id, sim.tick, sim.tick_rate, map["id"]), true)
	Log.info("server: %s joined as unit %d (%s) on team %d" % [player_name, unit.id, spec_id, team])
	if player_name == host_name:
		_host_seen = true
		_host_last_usec = Time.get_ticks_usec()
	if not roster.is_empty() and clients.size() == roster.size():
		Log.info("server: roster complete; preparation starts")


func _match_state() -> Dictionary:
	return runner.match_state()


func _send_snapshots() -> void:
	var units: Array = sim.units.values()
	var ms: Dictionary = _match_state()
	for c: Dictionary in clients.values():
		var own: Unit = sim.units.get(c["unit_id"])
		transport.send(c["peer"], Protocol.CH_UNRELIABLE, Protocol.snapshot(sim.tick, c["ack_seq"], units, ms, own), false)
		c["snapshots"] += 1
		_stats["snapshots_sent"] += 1


# ------------------------------------------------------------------ systems (run inside sim.step)

## Every client input is applied exactly once, in order: the client predicted exactly that,
## so the server's state matches the prediction. When no input has arrived the unit waits
## (a starved tick); when inputs pile up, two are applied per tick until caught up.
## Crowd control overrides player movement (feared units run, stunned units stand still).
func _system_inputs_and_movement(s: Sim, _inputs: Dictionary) -> void:
	var by_unit: Dictionary = {}
	for c: Dictionary in clients.values():
		by_unit[int(c["unit_id"])] = c
	for unit: Unit in s.turn_order():  # fair order: no player always moves first
		var c: Dictionary = by_unit.get(unit.id, {})
		if c.is_empty():
			continue
		var queue: Array = c["inputs"]
		var count: int = 2 if queue.size() > CATCH_UP_BUFFER else 1
		for i: int in count:
			# the next input in sequence; if it is missing, wait for it (it may arrive out of
			# order) until GAP_GIVE_UP_INPUTS newer ones are queued, then accept it as lost
			if queue.is_empty() or (int(queue[0]["seq"]) != int(c["ack_seq"]) + 1 and queue.size() < GAP_GIVE_UP_INPUTS):
				c["starved_ticks"] += 1
				break
			if int(queue[0]["seq"]) != int(c["ack_seq"]) + 1:
				c["lost_inputs"] += int(queue[0]["seq"]) - int(c["ack_seq"]) - 1
			var inp: Dictionary = queue.pop_front()
			c["ack_seq"] = inp["seq"]
			runner.apply_input(unit, inp)


func _system_rules(s: Sim, _inputs: Dictionary) -> void:
	if runner.ended() and _ended_tick < 0:
		_ended_tick = s.tick
		Log.info("server: match ended, winner %d" % arena.winner_team)
	var evs: Array = runner.take_events()
	for ev: Dictionary in evs:
		_count_event(s, ev)
	if not evs.is_empty() and not clients.is_empty():
		var pkt: PackedByteArray = Protocol.events(evs)
		for c: Dictionary in clients.values():
			transport.send(c["peer"], Protocol.CH_RELIABLE, pkt, true)
	if respawn:
		for uid: int in _dead_since.keys():
			if s.tick - int(_dead_since[uid]) >= int(RESPAWN_S * s.tick_rate):
				var u: Unit = s.units.get(uid)
				_dead_since.erase(uid)
				if u:
					var sp: Array = map["spawns"]["team_a" if u.team == 0 else "team_b"][0]
					runner.respawn_unit(u, Vector3(sp[0], sp[1], sp[2]))


func _count_event(s: Sim, ev: Dictionary) -> void:
	var src: String = str(ev.get("source", -1))
	var by: Dictionary = _stats["by_unit"]
	if not by.has(src):
		by[src] = {"damage": 0, "absorbed": 0, "healing": 0, "casts": 0, "interrupts": 0, "cc_applied": 0,
			"kills": 0}
	match ev["type"]:
		"damage":
			_stats["damage_events"] += 1
			by[src]["damage"] += int(ev["amount"])
			by[src]["absorbed"] += int(ev.get("absorbed", 0))
			if ev["killed"]:
				_stats["kills"] += 1
				by[src]["kills"] += 1
				_dead_since[ev["target"]] = s.tick
				Log.info("server: unit %s killed unit %d" % [src, ev["target"]])
		"heal":
			_stats["heals"] += 1
			by[src]["healing"] += int(ev["amount"])
		"cast_success":
			_stats["casts"] += 1
			by[src]["casts"] += 1
		"interrupt":
			_stats["interrupts"] += 1
			by[src]["interrupts"] += 1
		"aura_applied":
			if ev.get("cc", "none") != "none":
				by[src]["cc_applied"] += 1


# ------------------------------------------------------------------ summary

func _avg_tick_ms() -> float:
	if _tick_usec.is_empty():
		return 0.0
	var total: int = 0
	for t: int in _tick_usec:
		total += t
	return total / 1000.0 / _tick_usec.size()


func _finish() -> void:
	_finished = true
	var sorted_ticks: Array = Array(_tick_usec)
	sorted_ticks.sort()
	var per_client: Dictionary = _departed.duplicate()
	for c: Dictionary in clients.values():
		per_client[c["name"]] = _client_stats(c)
	var units: Dictionary = {}
	for u: Unit in sim.units.values():
		units[str(u.id)] = {"spec": u.spec_id, "team": u.team, "health": u.health, "alive": u.is_alive(),
			"name": _name_of(u.id)}
	var summary: Dictionary = {
		"ticks": sim.tick, "sim_seconds": sim.time_s(), "tick_rate_hz": sim.tick_rate, "mode": mode,
		"tick_ms": {"avg": _avg_tick_ms(),
			"p95": sorted_ticks[int(sorted_ticks.size() * 0.95)] / 1000.0 if sorted_ticks else 0.0,
			"max": sorted_ticks[-1] / 1000.0 if sorted_ticks else 0.0},
		"clients": per_client, "units": units, "damage_events": _stats["damage_events"],
		"kills": _stats["kills"], "heals": _stats["heals"], "casts": _stats["casts"],
		"interrupts": _stats["interrupts"], "by_unit": _stats["by_unit"],
		"winner_team": arena.winner_team if arena else -1, "end_reason": end_reason,
		"match_seconds": arena.match_seconds(sim.tick) if arena else sim.time_s(),
		"bytes_sent": transport.bytes_sent, "state_hash": sim.state_hash(),
		"log_warnings": Log.warn_count, "log_errors": Log.error_count,
	}
	if runner.input_log and input_log_path != "":
		runner.input_log.finish(sim)
		summary["input_log"] = input_log_path
		if runner.input_log.save(input_log_path) != OK:
			Log.error("server: cannot write the input log to %s" % input_log_path)
	if summary_path != "":
		var f: FileAccess = FileAccess.open(summary_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(summary, "  "))
		f.close()
	Log.info("server: match over after %.0f s; %d damage events, %d kills" % [
		sim.time_s(), _stats["damage_events"], _stats["kills"]])
	transport.close()
	get_tree().quit(0)


## The name of the client playing a unit (also after it left), or "".
func _name_of(unit_id: int) -> String:
	for c: Dictionary in clients.values():
		if int(c["unit_id"]) == unit_id:
			return c["name"]
	for n: String in _unit_names:
		if int(_unit_names[n]) == unit_id:
			return n
	return ""


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
