class_name NetServer
extends Node
## Dedicated, authoritative match server.
##
## Command line (after `--`): --server [--port 24600] [--map gallows_courtyard]
##   [--match-seconds 300] [--respawn] [--summary /abs/path.json] [--seed 1]
## Runs the simulation at the tuning tick rate in _physics_process, applies one buffered input
## per client per tick, and sends every client a snapshot after every tick.

const CATCH_UP_BUFFER: int = 6  ## above this many queued inputs, apply two per tick to catch up
const RESPAWN_S: float = 5.0

var transport: NetTransport = NetTransport.new()
var sim: Sim
var geometry: ArenaGeometry
var movement: Movement
var combat: CombatBasic
var map: Dictionary
var port: int = 24600
var match_seconds: float = 0.0
var respawn: bool = false
var summary_path: String = ""

var clients: Dictionary = {}  ## peer instance id -> client record
var _next_unit_id: int = 1
var _tick_usec: PackedInt64Array = []
var _stats: Dictionary = {"damage_events": 0, "kills": 0, "snapshots_sent": 0}
var _dead_since: Dictionary = {}  ## unit id -> tick of death
var _last_report_tick: int = 0
var _finished: bool = false
var _departed: Dictionary = {}  ## name -> stats of clients that already left


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	port = int(_arg(args, "--port", "24600"))
	match_seconds = float(_arg(args, "--match-seconds", "0"))
	respawn = "--respawn" in args
	summary_path = _arg(args, "--summary", "")
	var map_id: String = _arg(args, "--map", "gallows_courtyard")
	map = Data.maps.get(map_id, {})
	if map.is_empty():
		Log.error("server: unknown map %s" % map_id)
		get_tree().quit(1)
		return
	Engine.physics_ticks_per_second = Data.tick_rate()
	Engine.max_fps = 240  # poll the network often (accurate latency), without spinning the CPU
	sim = Sim.new(int(_arg(args, "--seed", "1")), Data.tick_rate())
	geometry = ArenaGeometry.from_map(map)
	movement = Movement.new(Data.tuning, geometry)
	combat = CombatBasic.new(Data.tuning, geometry)
	sim.add_system(_system_inputs_and_movement)
	sim.add_system(_system_combat)
	sim.add_system(_system_respawn)
	var err: Error = transport.start_server(port)
	if err != OK:
		Log.error("server: cannot listen on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	Log.info("server: listening on port %d, map %s, tick %d Hz" % [port, map_id, sim.tick_rate])


func _process(_delta: float) -> void:
	if sim and not _finished:
		_handle_network()  # between ticks too, so replies (pongs) are not held for a tick


func _physics_process(_delta: float) -> void:
	if _finished or sim == null:
		return
	_handle_network()
	var t0: int = Time.get_ticks_usec()
	sim.step()
	_tick_usec.append(Time.get_ticks_usec() - t0)
	_send_snapshots()
	if sim.tick - _last_report_tick >= sim.tick_rate * 10:
		_last_report_tick = sim.tick
		Log.info("server: t=%.0f s, %d clients, tick avg %.3f ms" % [sim.time_s(), clients.size(), _avg_tick_ms()])
	if match_seconds > 0.0 and sim.time_s() >= match_seconds:
		_finish()


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
					sim.units.erase(c["unit_id"])
					clients.erase(key)
			"receive":
				_on_packet(peer, key, Protocol.decode(ev["data"]))


func _on_packet(peer: ENetPacketPeer, key: int, msg: Dictionary) -> void:
	match msg.get("type", 0):
		Protocol.Msg.HELLO:
			if msg["version"] != Protocol.VERSION:
				transport.send(peer, Protocol.CH_RELIABLE, Protocol.reject("protocol version mismatch"), true)
				Log.warn("server: rejected client with protocol version %d" % msg["version"])
				return
			_add_client(peer, key, msg["name"], msg["spec"])
		Protocol.Msg.INPUT:
			var c: Dictionary = clients.get(key, {})
			if c.is_empty():
				return
			for inp: Dictionary in msg["inputs"]:
				if inp["seq"] > c["last_received_seq"]:
					c["last_received_seq"] = inp["seq"]
					c["inputs"].append(inp)
		Protocol.Msg.PING:
			transport.send(peer, Protocol.CH_RELIABLE, Protocol.pong(msg["t_usec"]), true)


func _client_stats(c: Dictionary) -> Dictionary:
	var secs: float = (sim.tick - int(c["joined_tick"])) / float(sim.tick_rate)
	return {"snapshots_sent": c["snapshots"], "seconds": secs,
		"snapshot_rate_hz": c["snapshots"] / secs if secs > 0 else 0.0, "starved_ticks": c["starved_ticks"]}


func _add_client(peer: ENetPacketPeer, key: int, player_name: String, spec_id: String) -> void:
	var team: int = clients.size() % 2
	var unit: Unit = Unit.new(_next_unit_id, team, spec_id, int(Data.tuning["health"]["dps"]))
	_next_unit_id += 1
	var spawns: Array = map["spawns"]["team_a" if team == 0 else "team_b"]
	var sp: Array = spawns[(clients.size() / 2) % spawns.size()]
	unit.position = Vector3(sp[0], sp[1], sp[2])
	unit.facing = -PI / 2 if team == 0 else PI / 2  # face the other team across the arena
	sim.add_unit(unit)
	clients[key] = {"peer": peer, "name": player_name, "unit_id": unit.id, "inputs": [],
		"last_received_seq": 0, "ack_seq": 0, "snapshots": 0, "starved_ticks": 0,
		"joined_tick": sim.tick}
	transport.send(peer, Protocol.CH_RELIABLE, Protocol.welcome(unit.id, sim.tick, sim.tick_rate, map["id"]), true)
	Log.info("server: %s joined as unit %d on team %d" % [player_name, unit.id, team])


func _send_snapshots() -> void:
	var units: Array = sim.units.values()
	for c: Dictionary in clients.values():
		transport.send(c["peer"], Protocol.CH_UNRELIABLE, Protocol.snapshot(sim.tick, c["ack_seq"], units), false)
		c["snapshots"] += 1
		_stats["snapshots_sent"] += 1


# ------------------------------------------------------------------ systems (run inside sim.step)

## Every client input is applied exactly once, in order: the client predicted exactly that,
## so the server's state matches the prediction. When no input has arrived the unit waits
## (a starved tick); when inputs pile up, two are applied per tick until caught up.
func _system_inputs_and_movement(s: Sim, _inputs: Dictionary) -> void:
	for c: Dictionary in clients.values():
		var unit: Unit = s.units.get(c["unit_id"])
		if unit == null:
			continue
		var queue: Array = c["inputs"]
		if queue.is_empty():
			c["starved_ticks"] += 1
			continue
		var count: int = 2 if queue.size() > CATCH_UP_BUFFER else 1
		for i: int in count:
			var inp: Dictionary = queue.pop_front()
			c["ack_seq"] = inp["seq"]
			if not unit.is_alive():
				continue
			movement.apply(unit, inp, s.dt())
			if inp.get("tab", false):
				unit.target_id = combat.tab_target(unit, s.units)


func _system_combat(s: Sim, _inputs: Dictionary) -> void:
	for unit: Unit in s.units.values():
		combat.update_auto_attack(unit, s.units, s.dt(), s.tick)
	for ev: Dictionary in combat.events:
		_stats["damage_events"] += 1
		if ev["killed"]:
			_stats["kills"] += 1
			_dead_since[ev["target"]] = s.tick
			Log.info("server: unit %d killed unit %d" % [ev["source"], ev["target"]])
		var pkt: PackedByteArray = Protocol.event(ev)
		for c: Dictionary in clients.values():
			transport.send(c["peer"], Protocol.CH_RELIABLE, pkt, true)
	combat.events.clear()


func _system_respawn(s: Sim, _inputs: Dictionary) -> void:
	if not respawn:
		return
	for uid: int in _dead_since.keys():
		if s.tick - int(_dead_since[uid]) >= int(RESPAWN_S * s.tick_rate):
			var u: Unit = s.units.get(uid)
			_dead_since.erase(uid)
			if u:
				u.health = u.max_health
				u.target_id = -1
				var sp: Array = map["spawns"]["team_a" if u.team == 0 else "team_b"][0]
				u.position = Vector3(sp[0], sp[1], sp[2])


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
	var summary: Dictionary = {
		"ticks": sim.tick, "sim_seconds": sim.time_s(), "tick_rate_hz": sim.tick_rate,
		"tick_ms": {"avg": _avg_tick_ms(),
			"p95": sorted_ticks[int(sorted_ticks.size() * 0.95)] / 1000.0 if sorted_ticks else 0.0,
			"max": sorted_ticks[-1] / 1000.0 if sorted_ticks else 0.0},
		"clients": per_client, "damage_events": _stats["damage_events"], "kills": _stats["kills"],
		"bytes_sent": transport.bytes_sent, "state_hash": sim.state_hash(),
		"log_warnings": Log.warn_count, "log_errors": Log.error_count,
	}
	if summary_path != "":
		var f: FileAccess = FileAccess.open(summary_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(summary, "  "))
		f.close()
	Log.info("server: match over after %.0f s; %d damage events, %d kills" % [
		sim.time_s(), _stats["damage_events"], _stats["kills"]])
	transport.close()
	get_tree().quit(0)


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
