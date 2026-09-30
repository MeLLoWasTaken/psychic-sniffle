class_name AudioDirector
extends Node3D
## Plays the game's sounds from world views and combat events (backlog M1-26). Which sound plays
## when comes from data (SoundBank: data/sound_map/default.json and data/sounds); there are no
## code branches per class or ability.
##
##   cast_start          the ability's cast_start at the caster, and its cast_loop following the
##                       caster until the cast ends (success, interrupt, failure, channel end)
##   cast_success        release at the caster ("@weapon_swing": the caster's weapon swing)
##   damage, heal, interrupt, dispel, and aura_applied right after the caster's cast_success
##                       impact at the unit hit, once per unit per tick ("@weapon_hit": the
##                       caster's weapon on the target's armor); periodic ticks of mapped auras
##   aura_applied        crowd control of the warning categories on the local player: the CC
##                       warning (2D), once per application (several in one tick count as one)
##   cast_start at me    an enemy cast that applies such crowd control: the incoming warning (2D)
##   cast_failed         for the local player, listed reasons: the interface error sound
##   views               footsteps every step_m of ground travel (cadence follows speed), a
##                       landing on touchdown; the target changing: the interface target tick
##
## World sounds are 3D (AudioStreamPlayer3D, inverse-distance falloff from the map's attenuation
## profiles) on the self, allies or enemies effects bus by who caused them; interface sounds and
## warnings are 2D. The self, allies and enemies buses send to the world bus (sound_map
## buses.world), whose AudioEffectReverb takes the room sound of the view's map (data/acoustics,
## backlog X-04) and whose compressor dips the world under the warnings (sound_map ducking);
## interface sounds and warnings bypass it, dry and on top. At most `max_voices` play at once (DESIGN.md: 64): a new sound takes the voice
## of the lowest-priority, oldest one when it outranks it, else it is dropped; enemy crowd control
## and burst abilities and the warnings are never dropped. Each sound also has a cap on copies of
## itself (max_instances). Voices end by game time (the views' tick), so counts are deterministic.
##   var audio: AudioDirector = AudioDirector.new()
##   add_child(audio)
##   audio.push_view(view); audio.push_events(events)   # every tick
##   audio.update(delta, renderer)                       # every frame: loops follow units

const EMIT_HEIGHT: float = 1.3  ## world sounds come from chest height
const FOOT_HEIGHT: float = 0.05
const HISTORY_MAX: int = 5000
const STOP_FADE_S: float = 0.08  ## loops fade out instead of stopping dead (a click)

var bank: SoundBank
var max_voices: int = 64
var cc_warning_enabled: bool = true  ## DESIGN.md settings: CC warning sound on or off
var listener_position: Variant = null  ## fixed listener (tests); else the camera, else the local unit
var me_id: int = -1
var me_team: int = -1
var tick: int = -1
var tick_rate: int = 60
var clock: float = 0.0  ## game time of the newest view, seconds
var target_id: int = -1
var acoustics_id: String = ""  ## map whose room sound the arena reverb has ("" = the default)

var voices: Array[Dictionary] = []  ## playing: {player, id, priority, critical, started, ends, unit, ...}
var units: Dictionary = {}  ## unit id -> {spec, team, pos, acc, airborne, loop}
## Every sound started, newest last: {id, bus, positional, unit, tick, critical, category}
var history: Array[Dictionary] = []
var counts: Dictionary = {}  ## sound id -> times played
var played: int = 0
var dropped: int = 0  ## not played for lack of a voice
var critical_requests: int = 0  ## never-drop sounds asked for (in range)
var critical_played: int = 0  ## never-drop sounds that got a voice
var stolen: int = 0  ## voices taken from a playing sound
var culled: int = 0  ## beyond the attenuation's max distance
var peak_voices: int = 0
var cc_warnings: int = 0

var _free3d: Array[AudioStreamPlayer3D] = []
var _free2d: Array[AudioStreamPlayer] = []
var _last_cast: Dictionary = {}  ## source id -> ability cast in this batch of events
var _impacts: Dictionary = {}  ## "ability|target|tick" already played
var _cc_warned_tick: int = -1
var _last_error: float = -INF
var _seq: int = 0


func _init(p_bank: SoundBank = null) -> void:
	name = "AudioDirector"
	bank = p_bank if p_bank != null else SoundBank.shared()
	max_voices = int(bank.map.get("voices", {}).get("max", max_voices))
	cc_warning_enabled = bool(bank.map.get("cc_warning", {}).get("enabled_default", true))
	apply_ducking()
	apply_acoustics("")


# ================================================================== mix (backlog X-04)

## The effect of `type` on `bus` (the first one), added at the end if the bus has none.
static func bus_effect(bus: String, type: String) -> AudioEffect:
	var idx: int = AudioServer.get_bus_index(bus)
	if idx == -1:
		Log.error("audio: no bus '%s'" % bus)
		return null
	for i: int in AudioServer.get_bus_effect_count(idx):
		var e: AudioEffect = AudioServer.get_bus_effect(idx, i)
		if e.is_class(type):
			return e
	var made: AudioEffect = ClassDB.instantiate(type)
	AudioServer.add_bus_effect(idx, made)
	return made


## Set the arena reverb on the world bus to the room sound of `map_id` (data/acoustics; the
## default file for maps without one). Views name their map, so a new map re-tunes the reverb.
func apply_acoustics(map_id: String) -> void:
	acoustics_id = map_id
	var a: Dictionary = bank.acoustics_for(map_id)
	var bus: String = str(bank.map.get("buses", {}).get("world", ""))
	if a.is_empty() or bus == "":
		return
	var rv: AudioEffectReverb = bus_effect(bus, "AudioEffectReverb")
	if rv == null:
		return
	var p: Dictionary = a["reverb"]
	rv.room_size = float(p["room_size"])
	rv.damping = float(p["damping"])
	rv.spread = float(p["spread"])
	rv.hipass = float(p["hipass"])
	rv.dry = float(p["dry"])
	rv.wet = float(p["wet"])
	rv.predelay_msec = float(p["predelay_ms"])
	rv.predelay_feedback = float(p["predelay_feedback"])


## The world dips under the warnings: a compressor on the ducking bus keyed by the warning bus.
func apply_ducking() -> void:
	var d: Dictionary = bank.map.get("ducking", {})
	if d.is_empty():
		return
	var c: AudioEffectCompressor = bus_effect(str(d["bus"]), "AudioEffectCompressor")
	if c == null:
		return
	c.sidechain = StringName(str(d["sidechain"]))
	c.threshold = float(d["threshold_db"])
	c.ratio = float(d["ratio"])
	c.attack_us = float(d["attack_us"])
	c.release_ms = float(d["release_ms"])


# ================================================================== input

## Take the newest world view: who the local player is, unit positions (footsteps, landings),
## loops following their casters, voices that have finished.
func push_view(v: Dictionary) -> void:
	if v.is_empty() or int(v["tick"]) == tick:
		return
	tick_rate = int(v.get("tick_rate", tick_rate))
	if v.has("map") and str(v["map"]) != acoustics_id:
		apply_acoustics(str(v["map"]))
	var dt: float = float(int(v["tick"]) - tick) / tick_rate if tick >= 0 else 0.0
	tick = int(v["tick"])
	clock = float(tick) / tick_rate
	var me: Dictionary = v.get("me", {})
	me_id = int(me.get("id", -1))
	me_team = int(me.get("team", -1))
	var seen: Dictionary = {}
	for u: Dictionary in v["units"]:
		seen[int(u["id"])] = true
		_update_unit(u, dt)
	for id: int in units.keys():
		if not seen.has(id):
			_stop_loop(id)
			units.erase(id)
	_reap()


## Combat events of one tick (MatchRunner.take_events or the client's event stream).
func push_events(evs: Array) -> void:
	_last_cast.clear()
	for ev: Dictionary in evs:
		_on_event(ev)


## Every frame: loops follow their casters' drawn positions and the target tick plays when the
## renderer's target changes.
func update(_delta: float, renderer: WorldRenderer = null) -> void:
	if renderer == null:
		return
	set_target(renderer.target_id)
	for v: Dictionary in voices:
		if bool(v.get("follow", false)) and (v["player"] as Node3D).is_inside_tree():
			var p: Vector3 = renderer.drawn_position(int(v["unit"]))
			if p.is_finite():
				(v["player"] as Node3D).global_position = p + Vector3.UP * EMIT_HEIGHT


## The local player's target changed: the interface target tick (not when cleared).
func set_target(id: int) -> void:
	if id == target_id:
		return
	target_id = id
	if id != -1:
		play_ui(str(bank.map["interface"]["target"]))


# ================================================================== events

func _on_event(ev: Dictionary) -> void:
	var type: String = str(ev.get("type", ""))
	var src: int = int(ev.get("source", -1))
	var tgt: int = int(ev.get("target", -1))
	var ab: String = str(ev.get("ability", ""))
	match type:
		"cast_start":
			_play_stage(ab, "cast_start", src, src, tgt)
			_start_loop(src, ab)
			_incoming_warning(src, tgt, ab)
		"cast_success":
			_stop_loop(src)
			_last_cast[src] = ab
			_play_stage(ab, "release", src, src, tgt)
		"cast_interrupted", "channel_end":
			_stop_loop(src)
		"cast_failed":
			_stop_loop(src, ab)
			var ui: Dictionary = bank.map["interface"]
			if src == me_id and str(ev.get("reason", "")) in ui["error_reasons"] \
					and clock - _last_error >= float(ui["error_throttle_s"]):
				_last_error = clock
				play_ui(str(ui["error"]))
		"damage", "heal":
			if not Data.abilities.has(ab) and bank.aura_tick(ab) != "":
				play(bank.aura_tick(ab), tgt, src)  # a periodic aura ticking
			else:
				_impact(ab, src, tgt)
		"interrupt", "dispel":
			_impact(ab, src, tgt)
		"aura_applied":
			if tgt == me_id and str(ev.get("cc", "none")) in bank.map["cc_warning"]["categories"]:
				_cc_warning()
			var cast_ab: String = str(_last_cast.get(src, ""))
			if cast_ab != "" and _applies(cast_ab, str(ev.get("aura", ""))):
				_impact(cast_ab, src, tgt)


## The ability's impact at the target, once per target per tick (an ability that damages and
## slows the same target plays one impact).
func _impact(ab: String, src: int, tgt: int) -> void:
	if tgt < 0 or ab == "":
		return
	var key: String = "%s|%d|%d" % [ab, tgt, tick]
	if _impacts.has(key):
		return
	_impacts[key] = true
	if _impacts.size() > 512:
		_impacts.clear()
		_impacts[key] = true
	_play_stage(ab, "impact", tgt, src, tgt)


func _play_stage(ab: String, stage: String, at_unit: int, src: int, tgt: int) -> void:
	var critical: bool = _critical(ab, src)
	for ref: Variant in bank.stage_refs(ab, stage):
		var id: String = bank.resolve(str(ref), _spec(src), _spec(tgt))
		if id != "":
			play(id, at_unit, src, critical)


func _start_loop(src: int, ab: String) -> void:
	var refs: Array = bank.stage_refs(ab, "cast_loop")
	if refs.is_empty() or not units.has(src):
		return
	_stop_loop(src)
	var v: Dictionary = play(str(refs[0]), src, src, _critical(ab, src))
	if not v.is_empty():
		v["follow"] = true
		v["ability"] = ab
		units[src]["loop"] = v


## Fade out the unit's cast loop (only if it belongs to `ab`, when given).
func _stop_loop(src: int, ab: String = "") -> void:
	var e: Dictionary = units.get(src, {})
	if e.is_empty() or (e["loop"] as Dictionary).is_empty():
		return
	var v: Dictionary = e["loop"]
	if ab != "" and str(v.get("ability", "")) != ab:
		return
	e["loop"] = {}
	v["follow"] = false
	v["ends"] = minf(float(v["ends"]), clock + STOP_FADE_S)
	var p: Node = v["player"]
	if p.is_inside_tree():
		var tw: Tween = p.create_tween()
		tw.tween_property(p, "volume_db", -60.0, STOP_FADE_S)
		v["tween"] = tw


func _cc_warning() -> void:
	if not cc_warning_enabled or _cc_warned_tick == tick:
		return
	_cc_warned_tick = tick
	cc_warnings += 1
	play_2d(str(bank.map["cc_warning"]["sound"]), str(bank.map["buses"]["warning"]), true)


## An enemy starts a cast at the local player that will crowd-control them.
func _incoming_warning(src: int, tgt: int, ab: String) -> void:
	if not cc_warning_enabled or tgt != me_id or tgt < 0 or _team(src) == me_team:
		return
	for e: Dictionary in Data.abilities.get(ab, {}).get("effects", []):
		if str(e.get("type", "")) == "apply_aura":
			var cat: String = str(Data.auras.get(str(e.get("aura", "")), {}).get("cc_category", "none"))
			if cat in bank.map["cc_warning"]["categories"]:
				play_2d(str(bank.map["cc_warning"]["incoming"]), str(bank.map["buses"]["warning"]), true)
				return


func _applies(ab: String, aura_id: String) -> bool:
	for e: Dictionary in Data.abilities.get(ab, {}).get("effects", []):
		if str(e.get("type", "")) == "apply_aura" and str(e.get("aura", "")) == aura_id:
			return true
	return false


## Never dropped: abilities of the protected kit slots (crowd control, burst) cast by enemies.
func _critical(ab: String, src: int) -> bool:
	var vc: Dictionary = bank.map["voices"]
	if not str(Data.abilities.get(ab, {}).get("kit_slot", "")) in vc["never_drop_kit_slots"]:
		return false
	return str(vc["never_drop_from"]) == "anyone" or (src != me_id and _team(src) != me_team)


# ================================================================== movement

func _update_unit(u: Dictionary, dt: float) -> void:
	var id: int = int(u["id"])
	var pos: Vector3 = u["position"]
	var mv: Dictionary = bank.map["movement"]
	var air: bool = pos.y > float(mv["airborne_min_height_m"])
	var e: Dictionary = units.get(id, {})
	var fs: Dictionary = bank.footsteps(str(u["spec"]))
	var step_m: float = float(fs.get("step_m", 2.5))
	if e.is_empty():
		units[id] = {"spec": str(u["spec"]), "team": int(u["team"]), "pos": pos, "acc": step_m * 0.5,
			"airborne": air, "loop": {}}
		return
	var prev: Vector3 = e["pos"]
	e["pos"] = pos
	e["team"] = int(u["team"])
	if int(u.get("health", 1)) <= 0:
		_stop_loop(id)
		e["airborne"] = air
		return
	if bool(e["airborne"]) and not air:
		play(str(fs["land"]), id, id, false, pos + Vector3.UP * FOOT_HEIGHT)
		e["acc"] = step_m * 0.5
	e["airborne"] = air
	if dt > 0.0 and not air:
		var d: float = Vector2(pos.x - prev.x, pos.z - prev.z).length()
		var speed: float = d / dt
		if speed >= float(mv["moving_min_mps"]) and speed < float(mv["teleport_min_mps"]):
			e["acc"] = float(e["acc"]) + d
			if float(e["acc"]) >= step_m:
				e["acc"] = fmod(float(e["acc"]), step_m)
				play(str(fs["step"]), id, id, false, pos + Vector3.UP * FOOT_HEIGHT)
		elif speed < float(mv["moving_min_mps"]):
			e["acc"] = step_m * 0.5  # the first step comes half a stride after starting to move
	var loop: Dictionary = e["loop"]
	if not loop.is_empty():
		if (u.get("cast", {}) as Dictionary).is_empty():
			_stop_loop(id)  # the cast ended without an event we saw
		elif (loop["player"] as Node3D).is_inside_tree():
			(loop["player"] as Node3D).global_position = pos + Vector3.UP * EMIT_HEIGHT


# ================================================================== playback

## Play a world sound at a unit (or at `at`), on the effects bus of `source`'s side. Sounds of
## a non-positional category play 2D on the interface bus. Returns the voice, or {} when it
## was dropped or culled.
func play(id: String, unit: int, source: int = -1, critical: bool = false, at: Variant = null) -> Dictionary:
	if not bank.has(id):
		Log.error("audio: unknown sound '%s'" % id)
		return {}
	var pb: Dictionary = bank.playback(id)
	if not bool(pb["positional"]):
		return play_2d(id, str(bank.map["buses"]["interface"]), critical)
	var pos: Vector3
	if at != null:
		pos = at
	elif units.has(unit):
		pos = (units[unit]["pos"] as Vector3) + Vector3.UP * EMIT_HEIGHT
	else:
		return {}
	var att: Dictionary = pb["attenuation"]
	var lp: Variant = _listener()
	if lp != null and (lp as Vector3).distance_to(pos) > float(att["max_distance_m"]):
		culled += 1
		return {}
	critical_requests += int(critical)
	var v: Dictionary = _acquire(id, pb, critical, true)
	if v.is_empty():
		return v
	var p: AudioStreamPlayer3D = v["player"]
	p.stream = bank.stream(id)
	p.bus = _bus_for(source)
	p.volume_db = float(pb["volume_db"])
	p.unit_size = float(att["unit_size_m"])
	p.max_distance = float(att["max_distance_m"])
	p.max_db = float(att.get("max_db", 0.0))
	p.attenuation_filter_cutoff_hz = float(att.get("filter_cutoff_hz", 5000.0))
	p.attenuation_filter_db = float(att.get("filter_db", -24.0))
	if p.is_inside_tree():
		p.global_position = pos
	else:
		p.position = pos
	v["unit"] = unit
	_start(v, p, pb)
	return v


## Play a 2D sound (interface, warnings) on `bus`.
func play_2d(id: String, bus: String, critical: bool = false) -> Dictionary:
	if not bank.has(id):
		Log.error("audio: unknown sound '%s'" % id)
		return {}
	var pb: Dictionary = bank.playback(id)
	critical = critical or str(pb["category"]) == "warning"
	critical_requests += int(critical)
	var v: Dictionary = _acquire(id, pb, critical, false)
	if v.is_empty():
		return v
	var p: AudioStreamPlayer = v["player"]
	p.stream = bank.stream(id)
	p.bus = bus
	p.volume_db = float(pb["volume_db"])
	_start(v, p, pb)
	return v


## Play an interface sound (clicks for the HUD, M1-27).
func play_ui(id: String) -> Dictionary:
	return play_2d(id, str(bank.map["buses"]["interface"]))


func _start(v: Dictionary, p: Node, pb: Dictionary) -> void:
	v["ends"] = clock + bank.length(str(v["id"]))
	if p.is_inside_tree():
		p.call("play")
	played += 1
	critical_played += int(bool(v["critical"]))
	counts[v["id"]] = int(counts.get(v["id"], 0)) + 1
	history.append({"id": v["id"], "bus": String(p.get("bus")), "positional": p is AudioStreamPlayer3D,
		"unit": int(v.get("unit", -1)), "tick": tick, "critical": bool(v["critical"]), "category": pb["category"]})
	if history.size() > HISTORY_MAX + 500:
		history = history.slice(history.size() - HISTORY_MAX)


## A voice for a new sound, taking one from a playing sound if needed; {} when dropped.
func _acquire(id: String, pb: Dictionary, critical: bool, positional: bool) -> Dictionary:
	var prio: int = int(pb["priority"])
	var same: Array[Dictionary] = []
	for v: Dictionary in voices:
		if v["id"] == id:
			same.append(v)
	if same.size() >= int(pb["max_instances"]):
		var oldest: Dictionary = _weakest(same)
		if bool(oldest["critical"]) and not critical:
			dropped += 1
			return {}
		_release(oldest)
		stolen += 1
	if voices.size() >= max_voices:
		var victim: Dictionary = _weakest(voices)
		if not critical and (bool(victim["critical"]) or int(victim["priority"]) > prio):
			dropped += 1
			return {}
		_release(victim)
		stolen += 1
	var player: Node
	if positional:
		player = _free3d.pop_back() if not _free3d.is_empty() else _new_player(true)
	else:
		player = _free2d.pop_back() if not _free2d.is_empty() else _new_player(false)
	_seq += 1
	var voice: Dictionary = {"player": player, "id": id, "priority": prio, "critical": critical, "started": _seq,
		"ends": INF, "unit": -1}
	voices.append(voice)
	peak_voices = maxi(peak_voices, voices.size())
	return voice


## The voice to give up first: not critical before critical, then lowest priority, then oldest.
static func _weakest(list: Array[Dictionary]) -> Dictionary:
	var best: Dictionary = list[0]
	var best_key: int = _rank(best)
	for v: Dictionary in list:
		var k: int = _rank(v)
		if k < best_key:
			best = v
			best_key = k
	return best


## Sort key of a voice: critical, then priority (0..100), then start order.
static func _rank(v: Dictionary) -> int:
	return (int(v["critical"]) << 50) | (int(v["priority"]) << 40) | int(v["started"])


func _new_player(positional: bool) -> Node:
	var p: Node
	if positional:
		var p3: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p3.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		p3.panning_strength = 1.0
		p3.top_level = true  # positions are world positions
		p = p3
	else:
		p = AudioStreamPlayer.new()
	p.name = "Voice%d" % (get_child_count() + 1)
	add_child(p)
	p.connect("finished", _on_finished.bind(p))
	return p


func _on_finished(p: Node) -> void:
	for v: Dictionary in voices:
		if v["player"] == p:
			_release(v)
			return


func _release(v: Dictionary) -> void:
	var idx: int = _index_of(v)
	if idx == -1:
		return
	voices.remove_at(idx)
	if v.has("tween") and (v["tween"] as Tween).is_valid():
		(v["tween"] as Tween).kill()
	var p: Node = v["player"]
	p.call("stop")
	p.set("volume_db", 0.0)
	if p is AudioStreamPlayer3D:
		_free3d.append(p)
	else:
		_free2d.append(p)
	var e: Dictionary = units.get(int(v.get("unit", -1)), {})
	if not e.is_empty() and int((e["loop"] as Dictionary).get("started", -1)) == int(v["started"]):
		e["loop"] = {}


## Position of a voice in `voices` by its start number (dictionaries compare by content, slowly).
func _index_of(v: Dictionary) -> int:
	var seq: int = int(v["started"])
	for i: int in voices.size():
		if int(voices[i]["started"]) == seq:
			return i
	return -1


## Release voices whose sound has ended by game time.
func _reap() -> void:
	var done: Array[Dictionary] = []
	for v: Dictionary in voices:
		if clock >= float(v["ends"]):
			done.append(v)
	for v: Dictionary in done:
		_release(v)


# ================================================================== helpers

func _bus_for(source: int) -> String:
	var b: Dictionary = bank.map["buses"]
	if source == me_id and source >= 0:
		return str(b["self"])
	if units.has(source) and _team(source) == me_team:
		return str(b["allies"])
	return str(b["enemies"])


func _team(id: int) -> int:
	return int(units.get(id, {}).get("team", -2))


func _spec(id: int) -> String:
	return str(units.get(id, {}).get("spec", ""))


func _listener() -> Variant:
	if listener_position != null:
		return listener_position
	if is_inside_tree():
		var cam: Camera3D = get_viewport().get_camera_3d()
		if cam != null:
			return cam.global_position
	if units.has(me_id):
		return units[me_id]["pos"]
	return null


## Never-drop sounds that found no voice (DESIGN.md: must be 0).
func dropped_critical() -> int:
	return critical_requests - critical_played


## Voices playing now.
func voice_count() -> int:
	return voices.size()


## How often a sound was started.
func count_of(id: String) -> int:
	return int(counts.get(id, 0))
