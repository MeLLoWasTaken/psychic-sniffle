class_name NetClient
extends Node
## Game client networking: handshake, inputs, snapshots, own-unit prediction and
## reconciliation, remote-unit interpolation, and round-trip measurement.
##
## Command line (after `--`): [--host 127.0.0.1] [--port 24600] [--name player] [--spec id]
##   [--lag-ms 0] [--jitter-ms 0] [--loss 0] [--seconds 0] [--stats /abs/path.json]
##   [--server-silence 20]
## An input source (player controls or BotBrain) must be set before connecting.
##
## Inside the game client (M1-28) set `owns_tree = false`: finishing (leave(), a disconnect, a
## rejection) then emits `finished` instead of quitting the program, and the match scene draws
## from render_view() once per `ticked`.

signal welcomed(unit_id: int)
signal snapshot_received(snap: Dictionary)
signal events_received_signal(evs: Array)
## Emitted once the client stops (left, disconnected, rejected or timed out); `code` 0 is a
## normal end. Only when owns_tree is false does the program keep running afterwards.
signal finished(code: int, reason: String)
## Emitted at the end of every physics tick in which an input was sent (draw the new state).
signal ticked()

const SNAPSHOT_BUFFER: int = 64

var transport: NetTransport = NetTransport.new()
var server_peer: ENetPacketPeer
var input_source: Callable  ## returns {move, yaw, jump, tab} for this tick
var player_name: String = "player"
var spec_id: String = "warblade_carnage"
var unit_id: int = -1
var map_id: String = ""
var geometry: ArenaGeometry
var connected: bool = false
var quit_after_s: float = 0.0
var stats_path: String = ""
var owns_tree: bool = true  ## finishing quits the program (headless bots); false inside the game
var server_silence_s: float = 20.0  ## finish when the server sends nothing for this long (0 = never)
var finish_reason: String = ""

## Prediction: the local copy of our own unit, advanced every tick with our own inputs.
var predicted: Unit
var movement: Movement
var _seq: int = 0
var _pending: Array[Dictionary] = []  ## inputs sent but not yet acknowledged by a snapshot
var _recent_inputs: Array[Dictionary] = []

var snapshots: Array[Dictionary] = []  ## newest last
var latest_tick: int = -1
var events_received: int = 0
var recent_events: Array = []  ## last 200 combat log entries, for the HUD
var own_auras: Array = []  ## our unit's auras from the newest snapshot (prediction uses them)

const TELEPORT_M: float = 5.0  ## server moves larger than this in one snapshot are teleports
const STUCK_CAST_TICKS: int = 15  ## a cast shown this long past its end tick is stuck (M1-30)
var _stuck_casts: Dictionary = {}  ## "unit:start_tick" -> the stuck cast
var _end_view: Dictionary = {}  ## the first snapshot of the ended match: tick and every unit's health

var _synced: bool = false
var _finished: bool = false  ## set once we start shutting down; later network events are ignored
var _last_server_pos: Vector3 = Vector3.ZERO
var _stats: Dictionary = {"snapshots": 0, "corrections": 0, "correction_sum": 0.0, "teleports": 0,
	"correction_max": 0.0, "rtt_ms": [], "stale_snapshots": 0, "inputs_sent": 0,
	"effect_corrections": 0, "effect_correction_max": 0.0, "correction_log": []}
var _start_usec: int = 0
var _match_ended_usec: int = 0
var _last_displaced_tick: int = -1
var quit_on_match_end: bool = false  ## test bots leave one second after an arena match ends
var _snap_window_start_usec: int = 0
var _next_ping_usec: int = 0
var _last_packet_usec: int = 0
## Remote units are drawn at this server tick (fractional): it advances one tick per local
## physics tick and is steered toward the newest snapshot tick minus the interpolation delay.
var render_tick: float = -1.0
var interpolation_delay_ticks: int = 3


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	player_name = NetServer._arg(args, "--name", player_name)
	spec_id = NetServer._arg(args, "--spec", spec_id)
	quit_after_s = float(NetServer._arg(args, "--seconds", "0"))
	stats_path = NetServer._arg(args, "--stats", "")
	server_silence_s = float(NetServer._arg(args, "--server-silence", str(server_silence_s)))
	interpolation_delay_ticks = int(Data.tuning.get("simulation", {}).get("interpolation_delay_ticks", 3))
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
				if _match_ended_usec > 0:
					Log.info("client: the server closed after the match")  # expected
					finish_reason = "server_closed"
					_finish(0)
				else:
					Log.warn("client: disconnected from server")
					finish_reason = "disconnected"
					_finish(1)
				return

			"receive":
				_last_packet_usec = Time.get_ticks_usec()
				_on_packet(Protocol.decode(ev["data"]))


func _physics_process(_delta: float) -> void:
	if server_peer == null or _finished:
		return
	_poll_network()
	if _finished:
		return
	_advance_render_tick()
	var now: int = Time.get_ticks_usec()
	if server_silence_s > 0.0 and _last_packet_usec > 0 and (now - _last_packet_usec) / 1e6 > server_silence_s:
		Log.warn("client: nothing from the server for %.0f s; leaving" % server_silence_s)
		finish_reason = "server_silent"
		_finish(1)
		return
	# inputs start with the first snapshot: until then the input source cannot know the spawn
	# facing, and an input would turn the unit away from it
	if unit_id != -1 and input_source.is_valid() and _synced:
		_send_and_predict_input()
		ticked.emit()
	if connected and now >= _next_ping_usec:
		_next_ping_usec = now + 1_000_000
		transport.send(server_peer, Protocol.CH_RELIABLE, Protocol.ping(now), true)
	if quit_after_s > 0.0 and (now - _start_usec) / 1e6 >= quit_after_s:
		finish_reason = "time_up"
		_finish(0)
	elif quit_on_match_end and _match_ended_usec > 0 and now - _match_ended_usec >= 1_000_000:
		finish_reason = "match_over"
		_finish(0)  # the arena match is over; leave before the server closes


func _on_packet(msg: Dictionary) -> void:
	match msg.get("type", 0):
		Protocol.Msg.WELCOME:
			unit_id = msg["unit_id"]
			map_id = msg["map"]
			geometry = ArenaGeometry.from_map(Data.maps.get(map_id, {}))
			movement = Movement.new(Data.tuning, geometry)
			predicted = Unit.new(unit_id, 0, spec_id)
			_snap_window_start_usec = Time.get_ticks_usec()
			Log.info("client: welcomed as unit %d on map %s" % [unit_id, msg["map"]])
			welcomed.emit(unit_id)
		Protocol.Msg.REJECT:
			Log.error("client: rejected by server: %s" % msg["reason"])
			finish_reason = "rejected: %s" % msg["reason"]
			_finish(1)
		Protocol.Msg.SNAPSHOT:
			_on_snapshot(msg)
		Protocol.Msg.PONG:
			_stats["rtt_ms"].append((Time.get_ticks_usec() - int(msg["t_usec"])) / 1000.0)
		Protocol.Msg.EVENTS:
			var evs: Array = msg["events"]
			events_received += evs.size()
			recent_events.append_array(evs)
			if recent_events.size() > 200:
				recent_events = recent_events.slice(recent_events.size() - 200)
			events_received_signal.emit(evs)


func _on_snapshot(snap: Dictionary) -> void:
	if snap["tick"] <= latest_tick:
		_stats["stale_snapshots"] += 1  # arrived out of order; a newer one was already applied
		return
	latest_tick = snap["tick"]
	if geometry:
		# the gates block movement only during preparation, as on the server (prediction must agree)
		geometry.gates_open = int(snap["match"]["phase"]) != ArenaMatch.Phase.PREP
	if int(snap["match"]["phase"]) == ArenaMatch.Phase.ENDED and _match_ended_usec == 0:
		_match_ended_usec = Time.get_ticks_usec()
		Log.info("client: match over, winner team %d" % snap["match"]["winner"])
	_check_casts(snap)
	if int(snap["match"]["phase"]) == ArenaMatch.Phase.ENDED and _end_view.is_empty():
		var health: Dictionary = {}
		for u: Dictionary in snap["units"]:
			health[str(u["id"])] = int(u["health"])
		_end_view = {"tick": int(snap["tick"]), "health": health}
	_stats["snapshots"] += 1
	snapshots.append(snap)
	if snapshots.size() > SNAPSHOT_BUFFER:
		snapshots.pop_front()
	_reconcile(snap)
	snapshot_received.emit(snap)


## A cast still shown well past its end tick is stuck (backlog M1-30): the server ends every
## cast by its end tick, so a snapshot showing it later means a lost or wrong update.
func _check_casts(snap: Dictionary) -> void:
	for u: Dictionary in snap["units"]:
		var c: Dictionary = u.get("cast", {})
		if c.is_empty() or int(snap["tick"]) <= int(c["end_tick"]) + STUCK_CAST_TICKS:
			continue
		var key: String = "%d:%d" % [int(u["id"]), int(c["start_tick"])]
		if not _stuck_casts.has(key):
			_stuck_casts[key] = {"unit": int(u["id"]), "ability": str(c["ability"]), "start_tick": int(c["start_tick"]),
				"end_tick": int(c["end_tick"]), "seen_tick": int(snap["tick"])}
			Log.warn("client: stuck cast %s" % str(_stuck_casts[key]))


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
	var own: Dictionary = snap.get("own", {})
	predicted.position = own.get("position", mine["position"])  # full precision for our unit
	predicted.velocity = own.get("velocity", Vector3.ZERO)
	predicted.health = mine["health"]
	predicted.max_health = mine["max_health"]
	predicted.target_id = mine["target_id"]
	predicted.team = mine["team"]
	if not _synced:
		predicted.facing = float(mine["facing"])  # spawn facing (toward the gate); ours to steer from then on
	var effect_changed: bool = _movement_effects_changed(own_auras, mine["auras"], int(snap["tick"]))
	var displaced: int = int(own.get("displaced_tick", -1))
	if displaced != _last_displaced_tick:
		_last_displaced_tick = displaced
		effect_changed = true  # an ability moved us (charge, blink, knockback): server-decided
	own_auras = mine["auras"]
	while not _pending.is_empty() and int(_pending[0]["seq"]) <= int(snap["ack_seq"]):
		_pending.pop_front()
	if int(snap["match"]["phase"]) == ArenaMatch.Phase.ENDED:
		_pending.clear()  # the match is over and the server has frozen every unit
		return
	if predicted.is_alive():
		# the server applies pending input k at tick snap.tick + k (one input per tick)
		for k: int in _pending.size():
			_predict_move(_pending[k], int(snap["tick"]) + k)
	else:
		_pending.clear()
	var server_pos: Vector3 = predicted.position
	var teleported: bool = _synced and server_pos.distance_to(_last_server_pos) > TELEPORT_M
	_last_server_pos = server_pos
	if not _synced or teleported:
		_synced = true
		_stats["teleports"] += 1 if teleported else 0
		return  # spawns and respawns are not prediction errors
	var corr: float = before.distance_to(predicted.position)
	if corr > 0.0005 and predicted.is_alive():
		if effect_changed:
			# a stun, root, slow or fear the server applied or ended early (damage broke it, a
			# dispel, a trinket): no client can foresee these, so they are counted separately
			_stats["effect_corrections"] += 1
			_stats["effect_correction_max"] = maxf(_stats["effect_correction_max"], corr)
			return
		_stats["corrections"] += 1
		_stats["correction_sum"] += corr
		_stats["correction_max"] = maxf(_stats["correction_max"], corr)
		if _stats["correction_log"].size() < 20:
			_stats["correction_log"].append({"tick": snap["tick"], "m": corr, "pending": _pending.size(),
				"auras": own_auras.map(func(a: Dictionary) -> String: return "%s@%d" % [a["id"], a["expires_tick"]])})


## True when the movement-affecting auras in a new snapshot differ from what the previous one
## predicted: something was applied, refreshed or removed before its natural expiry.
static func _movement_effects_changed(before: Array, after: Array, snap_tick: int) -> bool:
	var expected: Array = []
	for a: Dictionary in before:
		if _affects_movement(a["id"]) and (int(a["expires_tick"]) == 0 or int(a["expires_tick"]) >= snap_tick):
			expected.append("%s@%d" % [a["id"], a["expires_tick"]])
	var now: Array = []
	for a: Dictionary in after:
		if _affects_movement(a["id"]):
			now.append("%s@%d" % [a["id"], a["expires_tick"]])
	expected.sort()
	now.sort()
	return expected != now


static func _affects_movement(aura_id: String) -> bool:
	var data: Dictionary = Data.auras.get(aura_id, {})
	if data.get("cc_category", "none") in ["root", "stun", "incapacitate", "disorient"]:
		return true
	for m: Dictionary in data.get("modifiers", []):
		if m["stat"] == "move_speed":
			return true
	return false


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
	if predicted.is_alive() and _match_ended_usec == 0:
		_predict_move(inp, latest_tick + _pending.size() - 1)


## Predict our own movement with the same rules the server uses, including roots, stuns, slows
## and fear from our known auras. `tick` is the server tick this input will be applied on, so
## effects that expire partway through the replay stop affecting it on time (the server moves a
## unit on the tick an aura expires, then removes the aura).
func _predict_move(inp: Dictionary, tick: int) -> void:
	var active: Array = own_auras.filter(func(a: Dictionary) -> bool:
		return int(a["expires_tick"]) == 0 or tick <= int(a["expires_tick"]))
	var mult: float = Combat.speed_multiplier_from(active, Data.auras)
	var use: Dictionary = inp
	var fear_from: Vector3 = _fear_source(active)
	if fear_from.x != INF:
		var away: Vector3 = predicted.position - fear_from
		away.y = 0.0
		var yaw: float = atan2(-away.x, -away.z) if away.length() > 0.01 else predicted.facing
		use = {"move": Vector2(0, 1), "yaw": yaw, "jump": false}
	elif Combat.is_forced_from(active, Data.auras):
		use = {"move": Vector2.ZERO, "yaw": predicted.facing, "jump": false}
	movement.apply(predicted, use, 1.0 / Data.tick_rate(), mult)


## Where the unit that feared us stands (newest snapshot), or INF when we are not feared.
func _fear_source(active: Array) -> Vector3:
	for a: Dictionary in active:
		if Data.auras.get(a["id"], {}).get("cc_category", "") == "disorient":
			return _unit_pos(snapshots[-1], int(a["source"])) if not snapshots.is_empty() else Vector3.ZERO
	return Vector3(INF, 0, 0)


## Position of another unit, drawn `delay_ticks` behind the newest snapshot and interpolated
## between the two snapshots around that time.
func interpolated_position(id: int, delay_ticks: int = 3) -> Vector3:
	return interpolated_position_at(id, float(latest_tick - delay_ticks))


## Position of a unit at a (fractional) server tick, interpolated between the two snapshots
## around it; the oldest or newest known position outside the buffer.
func interpolated_position_at(id: int, at_tick: float) -> Vector3:
	if not snapshots.is_empty() and at_tick >= float(snapshots[-1]["tick"]):
		return _unit_pos(snapshots[-1], id)
	for i: int in range(snapshots.size() - 1, 0, -1):
		var a: Dictionary = snapshots[i - 1]
		var b: Dictionary = snapshots[i]
		if a["tick"] <= at_tick and at_tick <= b["tick"]:
			var t: float = (at_tick - a["tick"]) / float(maxi(b["tick"] - a["tick"], 1))
			var pa: Vector3 = _unit_pos(a, id)
			var pb: Vector3 = _unit_pos(b, id)
			return pa.lerp(pb, t)
	return _unit_pos(snapshots[-1], id) if not snapshots.is_empty() else Vector3.ZERO


## One local tick of the remote-unit clock: +1 tick, pulled 10% toward the newest snapshot tick
## minus the delay (smooth under jitter and bursts), snapped when more than 10 ticks off.
func _advance_render_tick() -> void:
	if latest_tick < 0:
		return
	var goal: float = float(latest_tick - interpolation_delay_ticks)
	if render_tick < 0.0 or absf(render_tick + 1.0 - goal) > 10.0:
		render_tick = goal
	else:
		render_tick += 1.0
		render_tick += (goal - render_tick) * 0.1


static func _unit_pos(snap: Dictionary, id: int) -> Vector3:
	for u: Dictionary in snap["units"]:
		if u["id"] == id:
			return u["position"]
	return Vector3.ZERO


## Our own unit's view of the world from the newest snapshot (used by bots and the HUD).
func world_view() -> Dictionary:
	return snapshots[-1] if not snapshots.is_empty() else {}


## The world in the shape BotBrain reads (the same shape MatchRunner.view_for builds on the
## server): other units from the newest snapshot, our own unit at its predicted position, plus
## our cooldowns, global cooldown and school locks. Empty until the first snapshot with our unit.
func bot_view() -> Dictionary:
	if snapshots.is_empty() or predicted == null:
		return {}
	var snap: Dictionary = snapshots[-1]
	var me: Dictionary = {}
	var units: Array = []
	for u: Dictionary in snap["units"]:
		var copy: Dictionary = u.duplicate()
		if int(u["id"]) == unit_id:
			copy["position"] = predicted.position
			copy["facing"] = predicted.facing
			me = copy
		units.append(copy)
	if me.is_empty():
		return {}
	var own: Dictionary = snap.get("own", {})
	return {"tick": snap["tick"], "tick_rate": Data.tick_rate(), "me": me, "units": units,
		"gcd_ready_tick": int(own.get("gcd_ready_tick", 0)), "cooldowns": own.get("cooldowns", {}),
		"school_locks": own.get("school_locks", {}), "match": snap["match"], "map": map_id}


## The world for drawing (M1-28): bot_view() with the other units at their interpolated positions
## on the render clock (DESIGN.md: others are drawn about 3 ticks in the past) and our own unit
## at its predicted position. Same shape as MatchRunner.view_for, so WorldRenderer, the HUD and
## PlayerController read it unchanged. Empty until the first snapshot with our unit.
func render_view() -> Dictionary:
	var v: Dictionary = bot_view()
	if v.is_empty() or render_tick < 0.0:
		return v
	# the server tick our newest input will be applied on: one step per input sent, so it
	# advances every local tick even when no new snapshot arrived (the renderer draws each)
	v["draw_tick"] = latest_tick + _pending.size()
	for u: Dictionary in v["units"]:
		if int(u["id"]) != unit_id:
			u["position"] = interpolated_position_at(int(u["id"]), render_tick)
	return v


## True once the client has stopped (left, disconnected, rejected or timed out).
func is_finished() -> bool:
	return _finished


## Leave the server (the player left the match, or the match scene is closing).
func leave() -> void:
	if finish_reason == "":
		finish_reason = "left"
	_finish(0)


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
		"effect_corrections": _stats["effect_corrections"],
		"effect_correction_max_m": _stats["effect_correction_max"], "correction_log": _stats["correction_log"],
		"stuck_casts": _stuck_casts.values(), "end_view": _end_view,
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
	finished.emit(code, finish_reason)
	if owns_tree:
		get_tree().quit(code)
	else:
		transport.close()
		connected = false
