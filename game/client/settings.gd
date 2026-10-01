class_name Settings
extends RefCounted
## The player's settings (backlog M2-13): named profiles of changes over a data profile
## (data/settings/<id>.json), saved in the user's folder. `values` is the data profile with the
## active profile's changes applied; everything reads it. set_value() changes one setting, applies
## what the engine owns at once (window, vertical sync, frame cap, audio buses, output device)
## and announces the change on `bus`, so the HUD, camera, controller, effects and audio update
## while they run. Only the resolution waits for a restart.
##
##   {"active": "Default", "profiles": {"Default": {"interface.ui_scale": 1.25}}}

const DEFAULT_PATH: String = "user://settings.json"
const RESTART_PATHS: Array[String] = ["graphics.resolution"]
const AUDIO_BUSES: Dictionary = {"audio.master_db": "Master", "audio.effects_db": "Effects", "audio.interface_db": "Interface",
	"audio.ambience_db": "Ambience", "audio.music_db": "Music"}

## Quality presets: the graphics settings each one sets.
const PRESETS: Dictionary = {
	"low": {"graphics.shadows": "off", "graphics.particle_density": 0.4, "graphics.glow": false, "graphics.ssao": false, "graphics.fog": false, "graphics.render_scale": 0.75},
	"medium": {"graphics.shadows": "low", "graphics.particle_density": 0.7, "graphics.glow": true, "graphics.ssao": false, "graphics.fog": true, "graphics.render_scale": 1.0},
	"high": {"graphics.shadows": "high", "graphics.particle_density": 1.0, "graphics.glow": true, "graphics.ssao": true, "graphics.fog": true, "graphics.render_scale": 1.0},
}


class Bus:
	extends RefCounted
	signal changed(path: String, value: Variant)


static var bus: Bus = Bus.new()
static var values: Dictionary = {}  ## the settings in effect (data profile + changes)
static var base_id: String = "default"
static var path: String = DEFAULT_PATH
static var store: Dictionary = {"active": "Default", "profiles": {"Default": {}}}
static var restart_needed: bool = false
static var _focus_muted: bool = false


## Load the player's settings over a data profile and apply them. Returns `values`.
static func load_user(p_base_id: String = "default", p_path: String = DEFAULT_PATH) -> Dictionary:
	base_id = p_base_id
	path = p_path
	store = {"active": "Default", "profiles": {"Default": {}}}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and parsed.get("profiles") is Dictionary and not (parsed["profiles"] as Dictionary).is_empty():
			store = parsed
	_rebuild()
	apply_all()
	return values


## Settings for a data profile without the player's changes (tests, tools, a fresh run).
static func use_data(p_base_id: String = "default") -> Dictionary:
	base_id = p_base_id
	store = {"active": "Default", "profiles": {"Default": {}}}
	_rebuild()
	return values


static func _rebuild() -> void:
	values = Data.settings.get(base_id, {}).duplicate(true)
	var ch: Dictionary = store["profiles"].get(str(store["active"]), {})
	for p: String in ch:
		_put(values, p, ch[p])


static func save() -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(store, "  "))
	return true


static func get_value(p: String, default: Variant = null) -> Variant:
	var node: Variant = values
	for part: String in p.split("."):
		if not node is Dictionary or not (node as Dictionary).has(part):
			return default
		node = node[part]
	return node


static func _put(d: Dictionary, p: String, v: Variant) -> void:
	var parts: PackedStringArray = p.split(".")
	var node: Dictionary = d
	for i: int in parts.size() - 1:
		if not node.get(parts[i]) is Dictionary:
			node[parts[i]] = {}
		node = node[parts[i]]
	node[parts[-1]] = v


## Change a setting: recorded in the active profile, applied, announced on `bus`. A quality
## preset sets its graphics settings too; changing one of those marks the preset "custom".
static func set_value(p: String, v: Variant) -> void:
	var ch: Dictionary = store["profiles"][str(store["active"])]
	var base: Variant = _base_value(p)
	if base == v:
		ch.erase(p)
	else:
		ch[p] = v
	_put(values, p, v)
	if p in RESTART_PATHS:
		restart_needed = true
	_apply(p, v)
	bus.changed.emit(p, v)
	if p == "graphics.preset" and PRESETS.has(str(v)):
		for q: String in PRESETS[v]:
			if get_value(q) != PRESETS[v][q]:
				set_value(q, PRESETS[v][q])
		_put(values, "graphics.preset", v)  # the preset's own settings do not make it custom
		ch["graphics.preset"] = v
	elif p.begins_with("graphics.") and PRESETS.has(str(get_value("graphics.preset"))) and PRESETS[get_value("graphics.preset")].has(p) \
			and PRESETS[get_value("graphics.preset")][p] != v:
		_put(values, "graphics.preset", "custom")
		ch["graphics.preset"] = "custom"
		bus.changed.emit("graphics.preset", "custom")


static func _base_value(p: String) -> Variant:
	var node: Variant = Data.settings.get(base_id, {})
	for part: String in p.split("."):
		if not node is Dictionary or not (node as Dictionary).has(part):
			return null
		node = node[part]
	return node


## Back to the data profile's values, for every setting or those starting with `prefix`.
static func reset(prefix: String = "") -> void:
	var ch: Dictionary = store["profiles"][str(store["active"])]
	for p: String in ch.keys():
		if prefix == "" or p.begins_with(prefix):
			ch.erase(p)
			var base: Variant = _base_value(p)
			_put(values, p, base)
			_apply(p, base)
			bus.changed.emit(p, base)


static func profile_names() -> Array:
	var n: Array = store["profiles"].keys()
	n.sort()
	return n


static func use_profile(profile_name: String) -> void:
	if not store["profiles"].has(profile_name):
		store["profiles"][profile_name] = (store["profiles"][str(store["active"])] as Dictionary).duplicate(true)
	store["active"] = profile_name
	_rebuild()
	apply_all()
	for p: String in ["interface", "gameplay", "camera", "mouse", "targeting", "graphics", "audio", "accessibility"]:
		bus.changed.emit(p, values.get(p))


static func delete_profile(profile_name: String) -> void:
	if store["profiles"].size() <= 1:
		return
	store["profiles"].erase(profile_name)
	if str(store["active"]) == profile_name:
		use_profile(profile_names()[0])


## Apply every engine-owned setting (startup, profile switch).
static func apply_all() -> void:
	for p: String in ["graphics.window_mode", "graphics.vsync", "graphics.max_fps", "audio.output_device"] + AUDIO_BUSES.keys():
		_apply(p, get_value(p))


## What the engine owns, applied at once. Everything else listens on `bus`.
static func _apply(p: String, v: Variant) -> void:
	if v == null:
		return
	if AUDIO_BUSES.has(p):
		var i: int = AudioServer.get_bus_index(AUDIO_BUSES[p])
		if i >= 0:
			AudioServer.set_bus_volume_db(i, float(v))
		return
	match p:
		"audio.output_device":
			var devices: PackedStringArray = AudioServer.get_output_device_list()
			if str(v) in devices:
				AudioServer.output_device = str(v)
		"graphics.max_fps":
			Engine.max_fps = int(v)
		"graphics.vsync":
			if DisplayServer.get_name() != "headless":
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(v) else DisplayServer.VSYNC_DISABLED)
		"graphics.window_mode":
			if DisplayServer.get_name() != "headless":
				var modes: Dictionary = {"windowed": DisplayServer.WINDOW_MODE_WINDOWED, "fullscreen": DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
					"borderless": DisplayServer.WINDOW_MODE_FULLSCREEN}
				DisplayServer.window_set_mode(modes.get(str(v), DisplayServer.WINDOW_MODE_WINDOWED))


## The gameplay settings the server's rules use, for the hello message and PREFS.
static func rule_prefs() -> Dictionary:
	return {"spell_queue_ms": int(get_value("gameplay.spell_queue_ms", 400)), "auto_self_cast": bool(get_value("gameplay.auto_self_cast", true))}


## Team colors for the chosen color-blind mode: {"ally", "enemy"} (target rings, frame names).
static func team_colors() -> Dictionary:
	match str(get_value("accessibility.colorblind", "off")):
		"protanopia", "deuteranopia":
			return {"ally": Color(0.25, 0.55, 1.0), "enemy": Color(1.0, 0.62, 0.1)}
		"tritanopia":
			return {"ally": Color(0.2, 0.85, 0.85), "enemy": Color(0.95, 0.2, 0.45)}
	return {"ally": Color(0.2, 0.95, 0.3), "enemy": Color(0.95, 0.12, 0.08)}


## Mute the master bus while the window is out of focus (when the setting asks).
static func focus_changed(focused: bool) -> void:
	var i: int = AudioServer.get_bus_index("Master")
	if i < 0:
		return
	if not focused and bool(get_value("audio.mute_unfocused", false)):
		AudioServer.set_bus_mute(i, true)
		_focus_muted = true
	elif focused and _focus_muted:
		AudioServer.set_bus_mute(i, false)
		_focus_muted = false
