class_name Protocol
extends RefCounted
## Binary wire format. Every packet starts with a one-byte message type.
## Inputs are quantized here, and the client predicts with the quantized values, so client
## prediction and the server see exactly the same input.

const VERSION: int = 1
const CH_RELIABLE: int = 0
const CH_UNRELIABLE: int = 1
const CHANNELS: int = 2
const INPUT_REDUNDANCY: int = 3  ## each input packet repeats the last N inputs to survive loss

enum Msg { HELLO = 1, WELCOME = 2, INPUT = 3, SNAPSHOT = 4, PING = 5, PONG = 6, EVENT = 7, REJECT = 8 }

const FLAG_JUMP: int = 1
const FLAG_TAB: int = 2


static func _buf() -> StreamPeerBuffer:
	var b: StreamPeerBuffer = StreamPeerBuffer.new()
	b.big_endian = false
	return b


# ------------------------------------------------------------------ handshake

static func hello(player_name: String, spec_id: String) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.HELLO)
	b.put_u16(VERSION)
	b.put_utf8_string(player_name)
	b.put_utf8_string(spec_id)
	return b.data_array


static func welcome(unit_id: int, tick: int, tick_rate: int, map_id: String) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.WELCOME)
	b.put_u16(unit_id)
	b.put_u32(tick)
	b.put_u8(tick_rate)
	b.put_utf8_string(map_id)
	return b.data_array


static func reject(reason: String) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.REJECT)
	b.put_utf8_string(reason)
	return b.data_array


# ------------------------------------------------------------------ input

## Quantize an input the same way the wire does: move to int8 steps, yaw to 16 bits.
static func quantize_input(input: Dictionary) -> Dictionary:
	var mv: Vector2 = input.get("move", Vector2.ZERO)
	if mv.length() > 1.0:
		mv = mv.normalized()
	var qx: int = clampi(roundi(mv.x * 127.0), -127, 127)
	var qy: int = clampi(roundi(mv.y * 127.0), -127, 127)
	var yaw: float = fposmod(float(input.get("yaw", 0.0)), TAU)
	var qyaw: int = roundi(yaw / TAU * 65535.0) % 65536
	return {
		"seq": int(input.get("seq", 0)),
		"move": Vector2(qx / 127.0, qy / 127.0),
		"yaw": qyaw / 65535.0 * TAU,
		"jump": bool(input.get("jump", false)),
		"tab": bool(input.get("tab", false)),
	}


## `inputs` is the most recent inputs, newest last (already quantized).
static func input_packet(inputs: Array) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.INPUT)
	b.put_u8(inputs.size())
	for inp: Dictionary in inputs:
		var mv: Vector2 = inp["move"]
		b.put_u32(inp["seq"])
		b.put_8(roundi(mv.x * 127.0))
		b.put_8(roundi(mv.y * 127.0))
		b.put_u16(roundi(fposmod(inp["yaw"], TAU) / TAU * 65535.0) % 65536)
		b.put_u8((FLAG_JUMP if inp["jump"] else 0) | (FLAG_TAB if inp["tab"] else 0))
	return b.data_array


# ------------------------------------------------------------------ snapshot

## One snapshot per client: world tick, the last input sequence the server applied for that
## client, and every unit's state. (Delta compression is a later optimisation.)
static func snapshot(tick: int, ack_seq: int, units: Array) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.SNAPSHOT)
	b.put_u32(tick)
	b.put_u32(ack_seq)
	b.put_u8(units.size())
	for u: Unit in units:
		b.put_u16(u.id)
		b.put_u8(u.team)
		b.put_float(u.position.x)
		b.put_float(u.position.y)
		b.put_float(u.position.z)
		b.put_float(u.velocity.x)
		b.put_float(u.velocity.y)
		b.put_float(u.velocity.z)
		b.put_float(u.facing)
		b.put_32(u.health)
		b.put_32(u.max_health)
		b.put_16(u.target_id)
		b.put_float(u.swing_timer)
	return b.data_array


# ------------------------------------------------------------------ ping and events

static func ping(t_usec: int) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.PING)
	b.put_u64(t_usec)
	return b.data_array


static func pong(t_usec: int) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.PONG)
	b.put_u64(t_usec)
	return b.data_array


static func event(ev: Dictionary) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.EVENT)
	b.put_var(ev)
	return b.data_array


# ------------------------------------------------------------------ decode

static func decode(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}
	var b: StreamPeerBuffer = _buf()
	b.data_array = data
	var t: int = b.get_u8()
	match t:
		Msg.HELLO:
			return {"type": t, "version": b.get_u16(), "name": b.get_utf8_string(),
				"spec": b.get_utf8_string()}
		Msg.WELCOME:
			return {"type": t, "unit_id": b.get_u16(), "tick": b.get_u32(), "tick_rate": b.get_u8(),
				"map": b.get_utf8_string()}
		Msg.REJECT:
			return {"type": t, "reason": b.get_utf8_string()}
		Msg.INPUT:
			var n: int = b.get_u8()
			var inputs: Array[Dictionary] = []
			for i: int in n:
				var seq: int = b.get_u32()
				var mx: int = b.get_8()
				var my: int = b.get_8()
				var qyaw: int = b.get_u16()
				var flags: int = b.get_u8()
				inputs.append({"seq": seq, "move": Vector2(mx / 127.0, my / 127.0),
					"yaw": qyaw / 65535.0 * TAU, "jump": flags & FLAG_JUMP != 0,
					"tab": flags & FLAG_TAB != 0})
			return {"type": t, "inputs": inputs}
		Msg.SNAPSHOT:
			var snap: Dictionary = {"type": t, "tick": b.get_u32(), "ack_seq": b.get_u32(), "units": []}
			var count: int = b.get_u8()
			for i: int in count:
				snap["units"].append({
					"id": b.get_u16(), "team": b.get_u8(),
					"position": Vector3(b.get_float(), b.get_float(), b.get_float()),
					"velocity": Vector3(b.get_float(), b.get_float(), b.get_float()),
					"facing": b.get_float(), "health": b.get_32(), "max_health": b.get_32(),
					"target_id": b.get_16(), "swing_timer": b.get_float()})
			return snap
		Msg.PING, Msg.PONG:
			return {"type": t, "t_usec": b.get_u64()}
		Msg.EVENT:
			return {"type": t, "event": b.get_var()}
	return {"type": t}
