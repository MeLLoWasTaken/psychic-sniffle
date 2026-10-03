class_name Protocol
extends RefCounted
## Binary wire format. Every packet starts with a one-byte message type.
## Inputs are quantized here, and the client predicts with the quantized values, so client
## prediction and the server see exactly the same input.
## Abilities, auras and specs travel as small indexes into their sorted id lists (both sides
## load the same data, and the protocol version changes whenever that could differ).

const VERSION: int = 12
const CH_RELIABLE: int = 0
const CH_UNRELIABLE: int = 1
const CHANNELS: int = 2
const INPUT_REDUNDANCY: int = 3  ## each input packet repeats the last N inputs to survive loss
const NO_ID: int = 0xFFFF

enum Msg { HELLO = 1, WELCOME = 2, INPUT = 3, SNAPSHOT = 4, PING = 5, PONG = 6, EVENTS = 7, REJECT = 8, PREFS = 9, TALENTS = 10 }

const CC_CATEGORIES: Array[String] = ["stun", "incapacitate", "disorient", "silence", "root", "disarm"]
const FLAG_JUMP: int = 1
const FLAG_TAB: int = 2
const FLAG_CLEAR_TARGET: int = 4  ## the player has no enemy target (cleared, or an ally selected)

static var _index_cache: Dictionary = {}


## Stable index of an id within a data table (sorted keys). -1 when unknown.
static func index_of(table: String, id: String) -> int:
	return _ids(table).find(id)


static func id_at(table: String, index: int) -> String:
	var ids: Array = _ids(table)
	return ids[index] if index >= 0 and index < ids.size() else ""


static func _ids(table: String) -> Array:
	if not _index_cache.has(table):
		var src: Dictionary = Data.tuning.get("resources", {}) if table == "resources" else Data.get(table)
		var keys: Array = src.keys()
		keys.sort()
		_index_cache[table] = keys
	return _index_cache[table]


static func _buf() -> StreamPeerBuffer:
	var b: StreamPeerBuffer = StreamPeerBuffer.new()
	b.big_endian = false
	return b


# ------------------------------------------------------------------ handshake

static func hello(player_name: String, spec_id: String, talents: String = "", prefs: Dictionary = {}) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.HELLO)
	b.put_u16(VERSION)
	b.put_utf8_string(player_name)
	b.put_utf8_string(spec_id)
	b.put_utf8_string(talents)
	_put_prefs(b, prefs)
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
		"clear_target": bool(input.get("clear_target", false)),
		"ability": str(input.get("ability", "")),
		"target": int(input.get("target", -1)),
		"ability_target": int(input.get("ability_target", -1)),
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
		b.put_u8((FLAG_JUMP if inp["jump"] else 0) | (FLAG_TAB if inp["tab"] else 0)
			| (FLAG_CLEAR_TARGET if inp.get("clear_target", false) else 0))
		var ai: int = index_of("abilities", inp.get("ability", "")) if inp.get("ability", "") != "" else -1
		b.put_u16(ai if ai >= 0 else NO_ID)
		b.put_u16(int(inp.get("target", -1)) if int(inp.get("target", -1)) >= 0 else NO_ID)
		b.put_u16(int(inp.get("ability_target", -1)) if int(inp.get("ability_target", -1)) >= 0 else NO_ID)
	return b.data_array


# ------------------------------------------------------------------ snapshot

## One snapshot per client: world tick, the last input the server applied for that client,
## match state, every unit's state, and the receiving player's own cooldowns.
## `match_state` = {phase, start_tick, dampening_pct, winner, pickups (bit mask of active spots)}. (Delta compression: backlog F-01.)
static func snapshot(tick: int, ack_seq: int, units: Array, match_state: Dictionary = {},
		own: Unit = null, own_speeds: Dictionary = {}) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.SNAPSHOT)
	b.put_u32(tick)
	b.put_u32(ack_seq)
	b.put_u8(int(match_state.get("phase", 1)))
	b.put_u32(int(match_state.get("start_tick", 0)))
	b.put_u8(int(match_state.get("dampening_pct", 0)))
	b.put_8(int(match_state.get("winner", -1)))
	b.put_u8(int(match_state.get("pickups", 0)))
	b.put_u8(units.size())
	for u: Unit in units:
		# Compact encoding (bandwidth budget): positions in centimetres (16 bits, +/-327 m),
		# facing in 16 bits, unit ids and sources in 8 bits, aura time as ticks remaining.
		b.put_u8(u.id)
		b.put_u8(u.team)
		var si: int = index_of("specs", u.spec_id)
		b.put_u8(si if si >= 0 else 255)
		b.put_16(clampi(roundi(u.position.x * 100.0), -32767, 32767))
		b.put_16(clampi(roundi(u.position.y * 100.0), -32767, 32767))
		b.put_16(clampi(roundi(u.position.z * 100.0), -32767, 32767))
		b.put_u16(roundi(fposmod(u.facing, TAU) / TAU * 65535.0) % 65536)
		b.put_32(u.health)
		b.put_32(u.max_health)
		b.put_u8(u.target_id if u.target_id >= 0 and u.target_id < 255 else 255)
		b.put_u16(clampi(roundi(float(u.resources.get(u.primary_resource, 0.0))), 0, 65535))
		b.put_u16(clampi(roundi(float(u.resource_max.get(u.primary_resource, 0.0))), 0, 65535))
		if u.is_casting():
			b.put_u16(index_of("abilities", u.cast["ability"]))
			b.put_u32(u.cast["start_tick"])
			b.put_u32(u.cast["end_tick"])
		else:
			b.put_u16(NO_ID)
		var drs: Array = u.dr.keys().filter(func(k: String) -> bool: return int(u.dr[k]["reset_tick"]) > tick)
		b.put_u8(drs.size())
		for k: String in drs:
			b.put_u8(CC_CATEGORIES.find(k))
			b.put_u8(int(u.dr[k]["count"]))
			b.put_u16(clampi(int(u.dr[k]["reset_tick"]) - tick, 0, 65535))
		b.put_u8(mini(u.auras.size(), 32))
		for a: Dictionary in u.auras.slice(0, 32):
			b.put_u16(index_of("auras", a["id"]))
			# 0 = permanent; a timed aura sends (ticks left + 1) so "expires this tick" stays timed
			var left: int = clampi(int(a["expires_tick"]) - tick, 0, 65533) + 1 if int(a["expires_tick"]) > 0 else 0
			b.put_u16(left)
			b.put_u8(a["stacks"])
			b.put_u8(clampi(int(a["source"]), 0, 255))
	if own:
		# The receiving player's own unit at full precision, for prediction and the HUD.
		b.put_u8(1)
		b.put_float(own.position.x)
		b.put_float(own.position.y)
		b.put_float(own.position.z)
		b.put_float(own.velocity.x)
		b.put_float(own.velocity.y)
		b.put_float(own.velocity.z)
		b.put_float(own.swing_timer)
		b.put_u32(own.gcd_ready_tick)
		b.put_32(own.displaced_tick)
		var cds: Array = own.cooldowns.keys().filter(func(k: String) -> bool: return int(own.cooldowns[k]) > tick)
		b.put_u8(cds.size())
		for k: String in cds:
			b.put_u16(index_of("abilities", k))
			b.put_u32(own.cooldowns[k])
		var locks: Array = own.school_locks.keys().filter(func(k: String) -> bool: return int(own.school_locks[k]) > tick)
		b.put_u8(locks.size())
		for k: String in locks:
			b.put_utf8_string(k)
			b.put_u32(own.school_locks[k])
		# talented movement speed of own auras (Combat.talented_speeds; X-12), by aura position
		var speeds: Array = own_speeds.keys().filter(func(i: int) -> bool: return i < 32)
		b.put_u8(speeds.size())
		for i: int in speeds:
			b.put_u8(i)
			b.put_u8((own_speeds[i] as Array).size())
			for v: float in own_speeds[i]:
				b.put_float(v)
		# the flee direction of each fear on our unit (Combat.forced_input; X-22), by aura position
		var flees: Array = range(mini(own.auras.size(), 32)).filter(func(i: int) -> bool: return own.auras[i].has("flee_yaw"))
		b.put_u8(flees.size())
		for i: int in flees:
			b.put_u8(i)
			b.put_float(float(own.auras[i]["flee_yaw"]))
		# every resource of our unit, a second one (runes) included, with its recharge timers (M3-08)
		var res_keys: Array = own.resource_max.keys()
		res_keys.sort()
		b.put_u8(res_keys.size())
		for k: String in res_keys:
			b.put_u8(index_of("resources", k))
			b.put_float(float(own.resources.get(k, 0.0)))
			b.put_float(float(own.resource_max[k]))
			var timers: Array = own.recharges.get(k, [])
			b.put_u8(mini(timers.size(), 32))
			for t: float in timers.slice(0, 32):
				b.put_float(t)
	else:
		b.put_u8(0)
	return b.data_array


# ------------------------------------------------------------------ ping and events

## A player's gameplay settings for the rules (M2-13): spell queue window (ms; 0xFFFF = the
## tuning's) and auto self-cast.
static func prefs(p: Dictionary) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.PREFS)
	_put_prefs(b, p)
	return b.data_array


static func _put_prefs(b: StreamPeerBuffer, p: Dictionary) -> void:
	b.put_u16(clampi(int(p["spell_queue_ms"]), 0, 4000) if p.has("spell_queue_ms") else 0xFFFF)
	b.put_u8(0 if not bool(p.get("auto_self_cast", true)) else 1)


static func _get_prefs(b: StreamPeerBuffer) -> Dictionary:
	var q: int = b.get_u16()
	var out: Dictionary = {"auto_self_cast": b.get_u8() != 0}
	if q != 0xFFFF:
		out["spell_queue_ms"] = q
	return out


## A talent change (M2-05b): the client asks for a loadout (its text form) during preparation;
## the server answers with the loadout it now uses and "" or why it refused ("talents_locked"
## once the gates are open, or the loadout's rule problem).
static func talents(text: String, error: String = "") -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.TALENTS)
	b.put_utf8_string(text)
	b.put_utf8_string(error)
	return b.data_array


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


## A tick's combat log entries, sent reliably as one packet.
static func events(evs: Array) -> PackedByteArray:
	var b: StreamPeerBuffer = _buf()
	b.put_u8(Msg.EVENTS)
	b.put_var(evs)
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
			var hello_msg: Dictionary = {"type": t, "version": b.get_u16()}
			if hello_msg["version"] != VERSION:
				return hello_msg  # the server answers with a version mismatch; the rest may differ
			hello_msg.merge({"name": b.get_utf8_string(), "spec": b.get_utf8_string(), "talents": b.get_utf8_string()})
			hello_msg["prefs"] = _get_prefs(b)
			return hello_msg
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
				var ai: int = b.get_u16()
				var ti: int = b.get_u16()
				var ati: int = b.get_u16()
				inputs.append({"seq": seq, "move": Vector2(mx / 127.0, my / 127.0),
					"yaw": qyaw / 65535.0 * TAU, "jump": flags & FLAG_JUMP != 0,
					"tab": flags & FLAG_TAB != 0, "clear_target": flags & FLAG_CLEAR_TARGET != 0,
					"ability": id_at("abilities", ai) if ai != NO_ID else "",
					"target": ti if ti != NO_ID else -1, "ability_target": ati if ati != NO_ID else -1})
			return {"type": t, "inputs": inputs}
		Msg.SNAPSHOT:
			var snap: Dictionary = {"type": t, "tick": b.get_u32(), "ack_seq": b.get_u32(),
				"match": {"phase": b.get_u8(), "start_tick": b.get_u32(), "dampening_pct": b.get_u8(),
					"winner": b.get_8(), "pickups": b.get_u8()}, "units": []}
			var count: int = b.get_u8()
			for i: int in count:
				var u: Dictionary = {"id": b.get_u8(), "team": b.get_u8(), "spec": id_at("specs", b.get_u8())}
				u["position"] = Vector3(b.get_16() / 100.0, b.get_16() / 100.0, b.get_16() / 100.0)
				u["facing"] = b.get_u16() / 65535.0 * TAU
				u["health"] = b.get_32()
				u["max_health"] = b.get_32()
				var tgt: int = b.get_u8()
				u["target_id"] = tgt if tgt != 255 else -1
				u["resource"] = float(b.get_u16())
				u["resource_max"] = float(b.get_u16())
				u["velocity"] = Vector3.ZERO
				u["swing_timer"] = 0.0
				u["cast"] = {}
				u["auras"] = []
				var ci: int = b.get_u16()
				if ci != NO_ID:
					u["cast"] = {"ability": id_at("abilities", ci), "start_tick": b.get_u32(), "end_tick": b.get_u32()}
				u["dr"] = {}
				var nd: int = b.get_u8()
				for j: int in nd:
					var cat: String = CC_CATEGORIES[b.get_u8()]
					var cnt: int = b.get_u8()
					u["dr"][cat] = {"count": cnt, "reset_tick": snap["tick"] + b.get_u16()}
				var na: int = b.get_u8()
				for j: int in na:
					var aid: String = id_at("auras", b.get_u16())
					var left: int = b.get_u16()
					u["auras"].append({"id": aid, "expires_tick": snap["tick"] + left - 1 if left > 0 else 0,
						"stacks": b.get_u8(), "source": b.get_u8()})
				snap["units"].append(u)
			if b.get_u8() == 1:
				var own: Dictionary = {"position": Vector3(b.get_float(), b.get_float(), b.get_float()),
					"velocity": Vector3(b.get_float(), b.get_float(), b.get_float()), "swing_timer": b.get_float(),
					"gcd_ready_tick": b.get_u32(), "displaced_tick": b.get_32(), "cooldowns": {}}
				var nc: int = b.get_u8()
				for j: int in nc:
					var ab_id: String = id_at("abilities", b.get_u16())
					own["cooldowns"][ab_id] = b.get_u32()
				own["school_locks"] = {}
				var nl: int = b.get_u8()
				for j: int in nl:
					var school: String = b.get_utf8_string()
					own["school_locks"][school] = b.get_u32()
				own["aura_speeds"] = {}
				var ns: int = b.get_u8()
				for j: int in ns:
					var pos: int = b.get_u8()
					var vals: Array = []
					for k: int in b.get_u8():
						vals.append(b.get_float())
					own["aura_speeds"][pos] = vals
				own["aura_flee"] = {}
				for j: int in b.get_u8():
					var fpos: int = b.get_u8()
					own["aura_flee"][fpos] = b.get_float()
				own["resources"] = {}
				own["resource_max"] = {}
				own["recharges"] = {}
				for j: int in b.get_u8():
					var rk: String = id_at("resources", b.get_u8())
					own["resources"][rk] = b.get_float()
					own["resource_max"][rk] = b.get_float()
					var timers: Array = []
					for k: int in b.get_u8():
						timers.append(b.get_float())
					own["recharges"][rk] = timers
				snap["own"] = own
			return snap
		Msg.PING, Msg.PONG:
			return {"type": t, "t_usec": b.get_u64()}
		Msg.PREFS:
			return {"type": t, "prefs": _get_prefs(b)}
		Msg.TALENTS:
			return {"type": t, "talents": b.get_utf8_string(), "error": b.get_utf8_string()}
		Msg.EVENTS:
			return {"type": t, "events": b.get_var()}
	return {"type": t}
