extends Node
## Loads all game data from res://data (a link to the repository's /data folder).
## Data is validated by tools/validate_data.py before commit; this loader only reports
## files it cannot read. Access: Data.abilities["ruin_strike"], Data.tuning["pacing"]["gcd_s"].

const DATA_ROOT: String = "res://data"
const FOLDERS: Array[String] = [
	"classes", "specs", "abilities", "auras", "talents", "maps", "assets", "keybinds", "bots", "lighting",
	"animations", "anim_states", "settings", "effects", "effect_palettes", "hud_layouts"]

var tuning: Dictionary = {}
var classes: Dictionary = {}
var specs: Dictionary = {}
var abilities: Dictionary = {}
var auras: Dictionary = {}
var talents: Dictionary = {}
var maps: Dictionary = {}
var assets: Dictionary = {}
var keybinds: Dictionary = {}
var bots: Dictionary = {}
var lighting: Dictionary = {}
var animations: Dictionary = {}
var anim_states: Dictionary = {}  ## how characters pick and blend clips in game (CharacterAnimator)
var settings: Dictionary = {}  ## gameplay settings profiles (camera, mouse, targeting)
var effects: Dictionary = {}  ## spell effect stages per ability id (EffectsDirector, M1-25)
var effect_palettes: Dictionary = {}  ## school colors and effect budget (EffectsData)
var hud_layouts: Dictionary = {}  ## HUD element positions, styles and bar assignments (Hud, M1-27)


func _ready() -> void:
	load_all()


func load_all() -> void:
	tuning = _load_file(DATA_ROOT.path_join("tuning.json"))
	for folder: String in FOLDERS:
		var table: Dictionary = {}
		var dir: DirAccess = DirAccess.open(DATA_ROOT.path_join(folder))
		if dir == null:
			Log.error("data: cannot open folder %s" % folder)
			continue
		for file_name: String in dir.get_files():
			if not file_name.ends_with(".json"):
				continue
			var entry: Dictionary = _load_file(DATA_ROOT.path_join(folder).path_join(file_name))
			if entry.is_empty():
				continue
			var id: String = entry.get("tree_id", entry.get("id", ""))
			table[id] = entry
		set(folder, table)
	Log.info("data: loaded %d abilities, %d auras, %d specs, %d classes" % [
		abilities.size(), auras.size(), specs.size(), classes.size()])


## Tick rate used by the fixed-step simulation (tuning.json simulation.tick_rate_hz).
func tick_rate() -> int:
	return int(tuning.get("simulation", {}).get("tick_rate_hz", 60))


func _load_file(path: String) -> Dictionary:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		Log.error("data: cannot read %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		Log.error("data: %s is not a JSON object" % path)
		return {}
	return parsed
