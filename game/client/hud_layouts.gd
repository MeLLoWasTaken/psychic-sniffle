class_name HudLayouts
extends RefCounted
## The player's HUD layouts (backlog M2-12): named profiles of changes over the base layout
## (data/hud_layouts/<id>.json), saved in the user's folder. A profile maps element ids to the
## fields edit mode changes (anchor, offset, scale, opacity, visible, columns, aura_side,
## spacing_px); everything else comes from the base, so data updates still reach edited layouts.
## A spec may use its own profile; otherwise the active one applies. Profiles export to a short
## text code and import from one.
##
##   {"active": "Default", "per_spec": {"oracle_grace": "Healer"}, "profiles": {"Default": {}, "Healer": {...}}}

const DEFAULT_PATH: String = "user://hud_layouts.json"
const EDITABLE: Array[String] = ["anchor", "offset", "scale", "opacity", "visible", "columns", "aura_side", "spacing_px"]
const MAX_PROFILES: int = 20

var path: String
var data: Dictionary = {"active": "Default", "per_spec": {}, "profiles": {"Default": {}}}


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and parsed.get("profiles") is Dictionary and not (parsed["profiles"] as Dictionary).is_empty():
			data = parsed
			data["per_spec"] = data.get("per_spec", {})


func save_file() -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "  "))
	return true


## A base layout with a profile's changes applied (a deep copy; the base is untouched).
static func merged(base: Dictionary, changes: Dictionary) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	for id: String in changes:
		if not out.get("elements", {}).has(id):
			continue
		for field: String in changes[id]:
			if field in EDITABLE:
				out["elements"][id][field] = changes[id][field]
	return out


func names() -> Array:
	var n: Array = data["profiles"].keys()
	n.sort()
	return n


## The profile a spec uses: its own when set, else the active one.
func profile_for(spec_id: String) -> String:
	var own: String = str(data["per_spec"].get(spec_id, ""))
	return own if data["profiles"].has(own) else str(data["active"])


func changes(profile_name: String) -> Dictionary:
	return data["profiles"].get(profile_name, {})


## Store a profile's changes (a new name adds a profile, up to MAX_PROFILES); false when full.
func put(profile_name: String, element_changes: Dictionary) -> bool:
	if not data["profiles"].has(profile_name) and data["profiles"].size() >= MAX_PROFILES:
		return false
	data["profiles"][profile_name] = element_changes.duplicate(true)
	return true


func remove(profile_name: String) -> void:
	if data["profiles"].size() <= 1:
		return
	data["profiles"].erase(profile_name)
	if str(data["active"]) == profile_name:
		data["active"] = names()[0]
	for s: String in data["per_spec"].keys():
		if str(data["per_spec"][s]) == profile_name:
			data["per_spec"].erase(s)


func set_active(profile_name: String) -> void:
	if data["profiles"].has(profile_name):
		data["active"] = profile_name


## Use a profile for one spec only ("" goes back to the active profile).
func set_for_spec(spec_id: String, profile_name: String) -> void:
	if profile_name == "":
		data["per_spec"].erase(spec_id)
	elif data["profiles"].has(profile_name):
		data["per_spec"][spec_id] = profile_name


static func export_text(element_changes: Dictionary) -> String:
	return Marshalls.utf8_to_base64(JSON.stringify(element_changes))


## {"changes", "error"} from an exported code; only editable fields of known elements are kept.
static func import_text(text: String, base: Dictionary) -> Dictionary:
	var raw: String = Marshalls.base64_to_utf8(text.strip_edges()) if text.strip_edges() != "" else ""
	var parsed: Variant = JSON.parse_string(raw) if raw != "" else null
	if not parsed is Dictionary:
		return {"changes": {}, "error": "not a HUD layout code"}
	var out: Dictionary = {}
	for id: String in parsed:
		if base.get("elements", {}).has(id) and parsed[id] is Dictionary:
			var kept: Dictionary = {}
			for field: String in parsed[id]:
				if field in EDITABLE:
					kept[field] = parsed[id][field]
			out[id] = kept
	return {"changes": out, "error": ""}
