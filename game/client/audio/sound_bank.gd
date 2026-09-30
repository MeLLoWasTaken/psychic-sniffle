class_name SoundBank
extends RefCounted
## The game's sound data (backlog M1-26): recipes in data/sounds (levels, category, playback
## overrides) and the sound map data/sound_map/default.json (which sound plays when, buses,
## attenuation, voice limits, ducking), the room sound of each map (data/acoustics, X-04), plus
## the generated streams in assets/audio/sfx.
##
## Sound references in the map are sound ids, or "@weapon_swing" / "@weapon_hit", which resolve
## from the caster's spec weapon (data/specs weapon type and hands) and the target's class armor.
##   var bank: SoundBank = SoundBank.shared()
##   bank.stream("hit_mace_plate")            # AudioStreamRandomizer (3 variations)
##   bank.resolve("@weapon_hit", "oracle_grace", "warblade_carnage")  # "hit_mace_plate"

const SOUNDS_DIR: String = "res://data/sounds"
const MAP_DIR: String = "res://data/sound_map"
const ACOUSTICS_DIR: String = "res://data/acoustics"
const SFX_DIR: String = "res://assets/audio/sfx"

static var _shared: SoundBank = null

var sounds: Dictionary = {}  ## id -> recipe (data/sounds/<id>.json)
var map: Dictionary = {}  ## the sound map
var acoustics: Dictionary = {}  ## map id (or "default") -> room sound (data/acoustics, backlog X-04)
var _streams: Dictionary = {}
var _lengths: Dictionary = {}
var _playback: Dictionary = {}


## One bank for the whole game (streams load once).
static func shared() -> SoundBank:
	if _shared == null:
		_shared = SoundBank.new()
	return _shared


func _init(map_id: String = "default") -> void:
	var dir: DirAccess = DirAccess.open(SOUNDS_DIR)
	if dir == null:
		Log.error("sound_bank: cannot open %s" % SOUNDS_DIR)
	else:
		for f: String in dir.get_files():
			if f.ends_with(".json"):
				var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(SOUNDS_DIR.path_join(f)))
				if d is Dictionary:
					sounds[str(d["id"])] = d
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_DIR.path_join(map_id + ".json")))
	if parsed is Dictionary:
		map = parsed
	else:
		Log.error("sound_bank: cannot read sound map '%s'" % map_id)
	var adir: DirAccess = DirAccess.open(ACOUSTICS_DIR)
	if adir != null:
		for f: String in adir.get_files():
			if f.ends_with(".json"):
				var a: Variant = JSON.parse_string(FileAccess.get_file_as_string(ACOUSTICS_DIR.path_join(f)))
				if a is Dictionary:
					acoustics[str(a["id"])] = a


## The room sound of a map: its data/acoustics file, else "default" ({} if neither exists).
func acoustics_for(map_id: String) -> Dictionary:
	return acoustics.get(map_id, acoustics.get("default", {}))


## True when the sound has a recipe (and so a generated file).
func has(id: String) -> bool:
	return sounds.has(id)


## Path of the playable resource: the randomizer for sounds with variations, else the .ogg.
func stream_path(id: String) -> String:
	var variants: int = int(sounds.get(id, {}).get("variants", 1))
	return SFX_DIR.path_join(id + (".tres" if variants > 1 else ".ogg"))


func stream(id: String) -> AudioStream:
	if not _streams.has(id):
		var path: String = stream_path(id)
		_streams[id] = load(path) if ResourceLoader.exists(path) else null
		if _streams[id] == null:
			Log.error("sound_bank: no stream for '%s' (%s); run tools/audio/synth.py --data" % [id, path])
	return _streams[id]


## Longest play time in seconds (the longest variation, at the randomizer's lowest pitch);
## INF for loops.
func length(id: String) -> float:
	if _lengths.has(id):
		return _lengths[id]
	var s: AudioStream = stream(id)
	var out: float = 0.0
	if bool(sounds.get(id, {}).get("loops", false)):
		out = INF
	elif s is AudioStreamRandomizer:
		var r: AudioStreamRandomizer = s
		for i: int in r.streams_count:
			out = maxf(out, r.get_stream(i).get_length())
		out *= r.random_pitch
	elif s != null:
		out = s.get_length()
	_lengths[id] = out
	return out


## How a sound plays: its category's defaults with the sound's own overrides, plus
## "attenuation" resolved to the profile dictionary (empty for 2D sounds) and "category".
func playback(id: String) -> Dictionary:
	if _playback.has(id):
		return _playback[id]
	var s: Dictionary = sounds.get(id, {})
	var cat: String = str(s.get("category", "impact"))
	var pb: Dictionary = (map["categories"].get(cat, map["categories"]["impact"]) as Dictionary).duplicate()
	pb.merge(s.get("playback", {}), true)
	pb["category"] = cat
	pb["volume_db"] = float(pb.get("volume_db", 0.0))
	pb["attenuation"] = map["attenuation"].get(str(pb.get("attenuation", "")), {}) if bool(pb["positional"]) else {}
	_playback[id] = pb
	return pb


## The map entry of an ability: a dictionary of stages, or {} for none or unknown.
func ability_entry(ability_id: String) -> Dictionary:
	var e: Variant = map["abilities"].get(ability_id, {})
	return e if e is Dictionary else {}


## Sound references of one stage (cast_start, cast_loop, release, impact) of an ability.
func stage_refs(ability_id: String, stage: String) -> Array:
	var v: Variant = ability_entry(ability_id).get(stage, [])
	return v if v is Array else [v]


## A reference resolved to a sound id: "@weapon_swing" from the caster's weapon, "@weapon_hit"
## from the caster's weapon and the target's armor; other references are ids already.
func resolve(ref: String, source_spec: String, target_spec: String = "") -> String:
	if ref == "@weapon_swing":
		return str(weapon(source_spec).get("swing", ""))
	if ref == "@weapon_hit":
		var hits: Dictionary = weapon(source_spec).get("hit", {})
		var armor: String = armor_of(target_spec)
		if not hits.has(armor):
			armor = str(map["armor_fallback"].get(armor, "default"))
		return str(hits.get(armor, hits.get("default", "")))
	return ref


## Swing and hit sounds of a spec's weapon ("<type>_2h" for two-handed weapons when mapped).
func weapon(spec_id: String) -> Dictionary:
	var w: Dictionary = Data.specs.get(spec_id, {}).get("weapon", {})
	var t: String = str(w.get("type", "fist"))
	var key: String = t + "_2h" if int(w.get("hands", 1)) == 2 and map["weapons"].has(t + "_2h") else t
	return map["weapons"].get(key, {})


## The armor of a spec's class ("cloth" when unknown).
func armor_of(spec_id: String) -> String:
	var cls: String = str(Data.specs.get(spec_id, {}).get("class", ""))
	return str(Data.classes.get(cls, {}).get("armor", "cloth"))


## Footstep settings for a spec: {step, land, step_m}, following armor_fallback.
func footsteps(spec_id: String) -> Dictionary:
	var armor: String = armor_of(spec_id)
	if not map["footsteps"].has(armor):
		armor = str(map["armor_fallback"].get(armor, "cloth"))
	return map["footsteps"].get(armor, {})


## The tick sound of a periodic aura, or "".
func aura_tick(aura_id: String) -> String:
	return str(map["auras"].get(aura_id, {}).get("tick", ""))
