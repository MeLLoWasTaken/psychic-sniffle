class_name TalentLoadouts
extends RefCounted
## The player's saved talent loadouts (docs/DESIGN.md "Talent trees", backlog M2-05): up to 10
## per spec, each a name and the loadout's shared text form (Talents.encode), so exporting is
## copying that text and importing is pasting it. One loadout per spec is active; Play and
## Practice send it to the match. Stored as JSON in the user's folder.
##
##   {"<spec id>": {"active": 0, "loadouts": [{"name": "Burst", "talents": "AQ..."}]}}

const MAX_PER_SPEC: int = 10
const DEFAULT_PATH: String = "user://talents.json"

var path: String
var data: Dictionary = {}


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path
	load_file()


func load_file() -> void:
	data = {}
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		data = parsed


func save_file() -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		Log.warn("talents: could not write %s" % path)
		return false
	f.store_string(JSON.stringify(data, "  "))
	return true


static func trees(spec_id: String) -> Dictionary:
	return Talents.trees_for(spec_id, Data.specs, Data.classes, Data.talents)


func _entry(spec_id: String) -> Dictionary:
	if not data.has(spec_id):
		data[spec_id] = {"active": 0, "loadouts": []}
	return data[spec_id]


## The spec's saved loadouts, [{"name", "talents"}, ...]. A spec with none starts with its bot
## profile's builds, so a new player has sensible loadouts to begin from.
func list(spec_id: String) -> Array:
	var e: Dictionary = _entry(spec_id)
	if e["loadouts"].is_empty():
		for b: Dictionary in Data.bots.get(spec_id, {}).get("builds", []):
			if e["loadouts"].size() >= MAX_PER_SPEC:
				break
			var text: String = BotBrain.build_talents(spec_id, b["name"])["talents"]
			e["loadouts"].append({"name": title_case(str(b["name"])), "talents": text})
	return e["loadouts"]


## "choir_of_dawn" -> "Choir of Dawn".
static func title_case(id: String) -> String:
	var words: PackedStringArray = id.split("_", false)
	for i: int in words.size():
		if i == 0 or not words[i] in ["of", "the", "and", "a", "an", "in", "on", "to"]:
			words[i] = words[i].substr(0, 1).to_upper() + words[i].substr(1)
	return " ".join(words)


func active_index(spec_id: String) -> int:
	var n: int = list(spec_id).size()
	return clampi(int(_entry(spec_id)["active"]), 0, maxi(n - 1, 0))


func set_active(spec_id: String, index: int) -> void:
	if index >= 0 and index < list(spec_id).size():
		_entry(spec_id)["active"] = index


## The active loadout's text, or "" (no talents) when it no longer fits the trees (they changed
## since it was saved) or there is none.
func active_text(spec_id: String) -> String:
	var all: Array = list(spec_id)
	if all.is_empty():
		return ""
	var text: String = str(all[active_index(spec_id)]["talents"])
	return text if error_of(spec_id, text) == "" else ""


## Abilities a loadout text grants (for the action bars), in tree order; [] for an unusable text.
static func granted_abilities(spec_id: String, text: String) -> Array:
	if error_of(spec_id, text) != "":
		return []
	var t: Dictionary = trees(spec_id)
	return Talents.resolve(Talents.decode(text, t)["loadout"], t, Data.abilities, Data.auras)["grants"]


## Why a text cannot be used for a spec, or "".
static func error_of(spec_id: String, text: String) -> String:
	var t: Dictionary = trees(spec_id)
	var d: Dictionary = Talents.decode(text, t)
	return d["error"] if d["error"] != "" else Talents.check(d["loadout"], t)


## Save a loadout into slot `index` (a new slot when index is the list size); returns the slot
## used, or -1 when the spec already has 10 or the text is not a legal loadout.
func put(spec_id: String, index: int, loadout_name: String, text: String) -> int:
	if error_of(spec_id, text) != "":
		return -1
	var all: Array = list(spec_id)
	var entry: Dictionary = {"name": loadout_name.strip_edges() if loadout_name.strip_edges() != "" else "Loadout %d" % (index + 1),
		"talents": text}
	if index >= 0 and index < all.size():
		all[index] = entry
		return index
	if all.size() >= MAX_PER_SPEC:
		return -1
	all.append(entry)
	return all.size() - 1


func remove(spec_id: String, index: int) -> void:
	var all: Array = list(spec_id)
	if index < 0 or index >= all.size():
		return
	var act: int = active_index(spec_id)
	all.remove_at(index)
	if index < act:
		act -= 1
	_entry(spec_id)["active"] = clampi(act, 0, maxi(all.size() - 1, 0))
