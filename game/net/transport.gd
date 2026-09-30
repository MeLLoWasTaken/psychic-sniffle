class_name NetTransport
extends RefCounted
## ENet host wrapper with an optional network-conditions simulator (backlog M0-11).
##
## The simulator delays packets by `lag_ms` of round trip (half on send, half on receive),
## adds random jitter, and drops `loss` of unreliable packets in each direction. Reliable
## packets are never dropped (ENet would retransmit them) and keep their order.

var host: ENetConnection = ENetConnection.new()
var lag_ms: float = 0.0
var jitter_ms: float = 0.0
var loss: float = 0.0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var bytes_sent: int = 0
var bytes_received: int = 0

var _out_queue: Array[Dictionary] = []
var _in_queue: Array[Dictionary] = []
var _last_release: Dictionary = {}  ## "<direction>:<channel>" -> last release time for reliable order
var _jitter_offset: Dictionary = {"in": 0.0, "out": 0.0}  ## current jitter per direction, ms
var _open: bool = false


func configure_conditions(p_lag_ms: float, p_jitter_ms: float, p_loss: float, seed_value: int = 1) -> void:
	lag_ms = p_lag_ms
	jitter_ms = p_jitter_ms
	loss = p_loss
	rng.seed = seed_value


func simulating() -> bool:
	return lag_ms > 0.0 or jitter_ms > 0.0 or loss > 0.0


## ENet's packet throttle silently drops unreliable packets when round trip rises. The game
## manages its own send rate and bandwidth, so the throttle is pinned open on every peer.
static func disable_throttle(peer: ENetPacketPeer) -> void:
	peer.throttle_configure(5000, 32, 0)  # interval ms, acceleration (max), deceleration (never)


func start_server(port: int, max_peers: int = 32) -> Error:
	var err: Error = host.create_host_bound("127.0.0.1", port, max_peers, Protocol.CHANNELS)
	_open = err == OK
	return err


func start_client(address: String, port: int) -> ENetPacketPeer:
	var err: Error = host.create_host(1, Protocol.CHANNELS)
	if err != OK:
		return null
	_open = true
	# The throttle is configured on the connect event (see poll); configuring it before the
	# handshake completes makes ENet drop the connection.
	return host.connect_to_host(address, port, Protocol.CHANNELS)


## Send a packet, through the simulator when it is enabled.
func send(peer: ENetPacketPeer, channel: int, data: PackedByteArray, reliable: bool) -> void:
	var flags: int = ENetPacketPeer.FLAG_RELIABLE if reliable else ENetPacketPeer.FLAG_UNSEQUENCED
	bytes_sent += data.size()
	if not simulating():
		peer.send(channel, data, flags)
		return
	if not reliable and rng.randf() < loss:
		return
	var release: float = _release_time("out", channel, reliable)
	_out_queue.append({"t": release, "peer": peer, "channel": channel, "data": data, "flags": flags})


## Service the host and return events ready for the game:
## [{"type": "connect"|"disconnect"|"receive", "peer": ENetPacketPeer, "channel": int, "data": PackedByteArray}]
func poll() -> Array[Dictionary]:
	var ready: Array[Dictionary] = []
	var now: float = Time.get_ticks_usec() / 1000.0
	# release delayed outgoing packets
	if not _out_queue.is_empty():
		var keep: Array[Dictionary] = []
		for p: Dictionary in _out_queue:
			if p["t"] <= now:
				var peer: ENetPacketPeer = p["peer"]
				if peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
					peer.send(p["channel"], p["data"], p["flags"])
			else:
				keep.append(p)
		_out_queue = keep
	# receive everything waiting
	while true:
		var ev: Array = host.service(0)
		var etype: int = ev[0]
		if etype == ENetConnection.EVENT_NONE or etype == ENetConnection.EVENT_ERROR:
			break
		var out: Dictionary = {"peer": ev[1], "channel": ev[3]}
		match etype:
			ENetConnection.EVENT_CONNECT:
				out["type"] = "connect"
				disable_throttle(ev[1])
			ENetConnection.EVENT_DISCONNECT:
				out["type"] = "disconnect"
			ENetConnection.EVENT_RECEIVE:
				out["type"] = "receive"
				var peer_r: ENetPacketPeer = ev[1]
				out["data"] = peer_r.get_packet()
				bytes_received += (out["data"] as PackedByteArray).size()
				out["reliable"] = ev[3] == Protocol.CH_RELIABLE
			_:
				continue
		if simulating() and out["type"] == "receive":
			if not out["reliable"] and rng.randf() < loss:
				continue
			out["t"] = _release_time("in", out["channel"], out["reliable"])
			_in_queue.append(out)
		else:
			ready.append(out)
	# release delayed incoming packets
	if not _in_queue.is_empty():
		var keep_in: Array[Dictionary] = []
		for p: Dictionary in _in_queue:
			if p["t"] <= now:
				ready.append(p)
			else:
				keep_in.append(p)
		_in_queue = keep_in
	host.flush()
	return ready


func _release_time(direction: String, channel: int, reliable: bool) -> float:
	var now: float = Time.get_ticks_usec() / 1000.0
	# Jitter drifts as a bounded random walk: real network delay changes gradually (queueing),
	# so consecutive packets have similar delays and are rarely reordered.
	var off: float = float(_jitter_offset[direction]) + rng.randf_range(-jitter_ms, jitter_ms) * 0.15
	off = clampf(off, -jitter_ms * 0.5, jitter_ms * 0.5)
	_jitter_offset[direction] = off
	var t: float = now + lag_ms * 0.5 + off
	if reliable:
		var key: String = "%s:%d" % [direction, channel]
		t = maxf(t, float(_last_release.get(key, 0.0)))
		_last_release[key] = t
	return t


## Tell every connected peer we are leaving (so they see a disconnect at once instead of after
## ENet's timeout), then destroy the host.
func close() -> void:
	if not _open:
		return
	_open = false
	for peer: ENetPacketPeer in host.get_peers():
		if peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
			peer.peer_disconnect_now()
	host.flush()
	host.destroy()
