class_name NetClient
extends Node
## Game client networking: handshake, inputs, snapshots, own-unit prediction and
## reconciliation, remote-unit interpolation, and round-trip measurement.
##
## Command line (after `--`): [--host 127.0.0.1] [--port 24600] [--name player] [--spec id]
##   [--lag-ms 0] [--jitter-ms 0] [--loss 0] [--seconds 0] [--stats /abs/path.json]
## An input source (player controls or BotBrain) must be set before connecting.

signal welcomed(unit_id: int)
signal snapshot_received(snap: Dictionary)

const SNAPSHOT_BUFFER: int = 64

var transport: NetTransport = NetTransport.new()
var server_peer: ENetPacketPeer
var input_source: Callable  ## returns {move, yaw, jump, tab} for this tick
var player_name: String = "player"
var spec_id: String = "warblade_carnage"
var unit_id: int = -1
var connected: bool = false
var quit_after_s: float = 0.0
var stats_path: String = ""

## Prediction: the local copy of our own unit, advanced every tick with our own inputs.
var predicted: Unit
var movement: Movement
var _seq: int = 0
var _pending: Array[Dictionary] = []  ## inputs sent but not yet acknowledged by a snapshot
var _recent_inputs: Array[Dictionary] = []

var snapshots: Array[Dictionary] = []  ## newest last
var latest_tick: int = -1
var events_received: int = 0

const TELEPORT_M: float = 5.0  ## server moves larger than this in one snapshot are teleports

var _synced: bool = false
var _finished: bool = false  ## set once we start shutting down; later network events are ignored
var _last_server_pos: Vector3 = Vector3.ZERO
var _stats: Dictionary = {"snapshots": 0, "corrections": 0, "correction_sum": 0.0, "teleports": 0,
	"correction_max": 0.0, "rtt_ms": [], "stale_snapshots": 0, "inputs_sent": 0}
var _start_usec: int = 0
var _snap_window_start_usec: int = 0
var _next_ping_usec: int = 0


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	player_name = NetServer._arg(args, "--name", player_name)
	spec_id = NetServer._arg(args, "--spec", spec_id)
	quit_after_s = float(NetServer._arg(args, "--seconds", "0"))
	stats_path = NetServer._arg(args, "--stats", "")
	transport.configure_conditions(float(NetServer._arg(args, "--lag-ms", "0")),
		float(NetServer._arg(args, "--jitter-ms", "0")), float(NetServer._arg(args, "--loss", "0")),
		hash(player_name))
	Engine.physics_ticks_per_second = Data.tick_rate()
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = 240  # poll often without spinning the CPU


func connect_to_server(host: String = "", port: int = 0) -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	host = host if host != "" else NetServer._arg(args, "--host", "127.0.0.1")
	port = port if port != 0 else int(NetServer._arg(args, "--port", "24600"))
	server_peer = transport.start_client(host, port)
	if server_peer == null:
		Log.error("client: could not create connection to %s:%d" % [host, port])
		return
	_start_usec = Time.get_ticks_usec()
	Log.info("client: connecting to %s:%d%s" % [host, port,
		" (simulating %d ms lag, %d ms jitter, %.0f%% loss)" % [transport.lag_ms, transport.jitter_ms, transport.loss * 100]
		if transport.simulating() else ""])


func _process(_delta: float) -> void:
	if server_peer and not _finished:
		_poll_network()


func _poll_network() -> void:
	for ev: Dictionary in transport.poll():
		match ev["type"]:
			"connect":
				connected = true
				transport.send(server_peer, Protocol.CH_RELIABLE, Protocol.hello(player_name, spec_id), true)
			"disconnect":
				connected = false
				Log.warn("client: disconnected from server")
				_finish(1)
				return

			"receive":
				_on_packet(Protocol.decode(ev["data"]))


func _physics_process(_delta: float) -> void:
	if server_peer == null or _finished:
		return
	_poll_network()
	if unit_id != -1 and input_source.is_valid():
		_send_and_predict_input()
	var now: int = Time.get_ticks_usec()
	if connected and now >= _next_ping_usec:
		_next_ping_usec = now + 1_000_000
		transport.send(server_peer, Protocol.CH_RELIABLE, Protocol.ping(now), true)
	if quit_after_s > 0.0 and (now - _start_usec) / 1e6 >= quit_after_s:
		_finish(0)


func _on_packet(msg: Dictionary) -> void:
	match msg.get("type", 0):
		Protocol.Msg.WELCOME:
			unit_id = msg["unit_id"]
			var geo: ArenaGeometry = ArenaGeometry.from_map(Data.maps.get(msg["map"], {}))
			movement = Movement.new(Data.tuning, geo)
			predicted = Unit.new(unit_id, 0, spec_id)
			_snap_window_start_usec = Time.get_ticks_usec()
			Log.info("client: welcomed as unit %d on map %s" % [unit_id, msg["map"]])
			welcomed.emit(unit_id)
		Protocol.Msg.REJECT:
			Log.error("client: rejected by server: %s" % msg["reason"])
			_finish(1)
		Protocol.Msg.SNAPSHOT:
			_on_snapshot(msg)
		Protocol.Msg.PONG:
			_stats["rtt_ms"].append((Time.get_ticks_usec() - int(msg["t_usec"])) / 1000.0)
		Protocol.Msg.EVENT:
			events_received += 1


func _on_snapshot(snap: Dictionary) -> void:
	if snap["tick"] <= latest_tick:
		_stats["stale_snapshots"] += 1  # arrived out of order; a newer one was already applied
		return
	latest_tick = snap["tick"]
	_stats["snapshots"] += 1
	snapshots.append(snap)
	if snapshots.size() > SNAPSHOT_BUFFER:
		snapshots.pop_front()
	_reconcile(snap)
	snapshot_received.emit(snap)


## Reset our predicted unit to the server's state, then replay the inputs the server has not
## applied yet. The distance the prediction moves is the correction the player would see.
func _reconcile(snap: Dictionary) -> void:
	if predicted == null:
		return
	var mine: Dictionary = {}
	for u: Dictionary in snap["units"]:
		if u["id"] == unit_id:
			mine = u
			break
	if mine.is_empty():
		return
	var before: Vector3 = predicted.position
	predicted.position = mine["position"]
	predicted.velocity = mine["velocity"]
	predicted.health = mine["health"]
	predicted.max_health = mine["max_health"]
	predicted.target_id = mine["target_id"]
	predicted.team = mine["team"]
	while not _pending.is_empty() and int(_pending[0]["seq"]) <= int(snap["ack_seq"]):
		_pending.pop_front()
	if predicted.is_alive():
		for inp: Dictionary in _pending:
			movement.apply(predicted, inp, 1.0 / Data.tick_rate())
	else:
		_pending.clear()
	var server_pos: Vector3 = mine["position"]
	var teleported: bool = _synced and server_pos.distance_to(_last_server_pos) > TELEPORT_M
	_last_server_pos = server_pos
	if not _synced or teleported:
		_synced = true
		_stats["teleports"] += 1 if teleported else 0
		return  # spawns and respawns are not prediction errors
	var corr: float = before.distance_to(predicted.position)
	if corr > 0.0005 and predicted.is_alive():
		_stats["corrections"] += 1
		_stats["correction_sum"] += corr
		_stats["correction_max"] = maxf(_stats["correction_max"], corr)


func _send_and_predict_input() -> void:
	_seq += 1
	var raw: Dictionary = input_source.call()
	raw["seq"] = _seq
	var inp: Dictionary = Protocol.quantize_input(raw)
	_recent_inputs.append(inp)
	if _recent_inputs.size() > Protocol.INPUT_REDUNDANCY:
		_recent_inputs.pop_front()
	transport.send(server_peer, Protocol.CH_UNRELIABLE, Protocol.input_packet(_recent_inputs), false)
	_stats["inputs_sent"] += 1
	_pending.append(inp)
	if predicted.is_alive():
		movement.apply(predicted, inp, 1.0 / Data.tick_rate())


## Position of another unit, drawn `delay_ticks` behind the newest snapshot and interpolated
## between the two snapshots around that time.
func interpolated_position(id: int, delay_ticks: int = 3) -> Vector3:
	var render_tick: float = latest_tick - delay_ticks
	for i: int in range(snapshots.size() - 1, 0, -1):
		var a: Dictionary = snapshots[i - 1]
		var b: Dictionary = snapshots[i]
		if a["tick"] <= render_tick and render_tick <= b["tick"]:
			var t: float = (render_tick - a["tick"]) / float(maxi(b["tick"] - a["tick"], 1))
			var pa: Vector3 = _unit_pos(a, id)
			var pb: Vector3 = _unit_pos(b, id)
			return pa.lerp(pb, t)
	return _unit_pos(snapshots[-1], id) if not snapshots.is_empty() else Vector3.ZERO


static func _unit_pos(snap: Dictionary, id: int) -> Vector3:
	for u: Dictionary in snap["units"]:
		if u["id"] == id:
			return u["position"]
	return Vector3.ZERO


## Our own unit's view of the world from the newest snapshot (used by bots and the HUD).
func world_view() -> Dictionary:
	return snapshots[-1] if not snapshots.is_empty() else {}


func stats() -> Dictionary:
	var secs: float = (Time.get_ticks_usec() - _snap_window_start_usec) / 1e6
	var rtts: Array = _stats["rtt_ms"]
	var rtt_avg: float = 0.0
	for r: float in rtts:
		rtt_avg += r
	rtt_avg = rtt_avg / rtts.size() if rtts else 0.0
	return {"name": player_name, "unit_id": unit_id, "snapshots": _stats["snapshots"],
		"snapshot_rate_hz": _stats["snapshots"] / secs if secs > 0 else 0.0,
		"stale_snapshots": _stats["stale_snapshots"], "inputs_sent": _stats["inputs_sent"],
		"corrections": _stats["corrections"], "teleports": _stats["teleports"],
		"correction_avg_m": _stats["correction_sum"] / _stats["corrections"] if _stats["corrections"] else 0.0,
		"correction_max_m": _stats["correction_max"], "rtt_avg_ms": rtt_avg, "rtt_samples": rtts.size(),
		"events_received": events_received, "simulated_lag_ms": transport.lag_ms,
		"simulated_jitter_ms": transport.jitter_ms, "simulated_loss": transport.loss,
		"log_warnings": Log.warn_count, "log_errors": Log.error_count}


func _finish(code: int) -> void:
	if _finished:
		return
	_finished = true
	set_physics_process(false)
	var s: Dictionary = stats()
	if stats_path != "":
		var f: FileAccess = FileAccess.open(stats_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(s, "  "))
		f.close()
	Log.info("client: done; %d snapshots (%.1f Hz), avg correction %.3f m, max %.3f m, rtt %.0f ms" % [
		s["snapshots"], s["snapshot_rate_hz"], s["correction_avg_m"], s["correction_max_m"], s["rtt_avg_ms"]])
	if server_peer and connected:
		server_peer.peer_disconnect_later()
		transport.poll()
	get_tree().quit(code)
