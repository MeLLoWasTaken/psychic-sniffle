class_name EffectsData
extends RefCounted
## Read-only access to the spell effect data (backlog M1-25): the per-ability stages in
## data/effects/<ability id>.json (schema effect.schema.json) and the school color table,
## relation outline colors and budget in data/effect_palettes/default.json. Validated by
## tools/validate_data.py, which also checks every ability of a finished kit has an entry.

const PALETTE: String = "default"
const CC_STYLES: Array[String] = ["stun", "disorient", "root", "silence", "ice_block"]

static var _aura_index: Dictionary = {}  ## aura id -> visual with "school" and "ability" added
static var _indexed: bool = false


## Forget cached lookups (after Data.load_all()).
static func reset() -> void:
	_aura_index = {}
	_indexed = false


static func palette() -> Dictionary:
	return Data.effect_palettes.get(PALETTE, {})


## The effect stages of an ability, or empty when it has none (no file, or "none": true).
static func entry(ability_id: String) -> Dictionary:
	var e: Dictionary = Data.effects.get(ability_id, {})
	return {} if bool(e.get("none", false)) else e


## Color school of an ability's effects: the entry's override, else the ability's school.
static func school_of(ability_id: String) -> String:
	var e: Dictionary = Data.effects.get(ability_id, {})
	if e.has("school"):
		return str(e["school"])
	return str(Data.abilities.get(ability_id, {}).get("school", "physical"))


## {"primary", "secondary", "core"} Colors for a school (physical when unknown).
static func colors(school: String) -> Dictionary:
	var schools: Dictionary = palette().get("schools", {})
	var c: Dictionary = schools.get(school, schools.get("physical", {}))
	var gain: float = float(c.get("gain", 1.0))
	return {"primary": _rgb(c.get("primary", [1, 1, 1])) * gain, "secondary": _rgb(c.get("secondary", [1, 1, 1])) * gain,
		"core": _rgb(c.get("core", [1, 1, 1])) * gain}


## Every school in the palette, in file order.
static func schools() -> Array:
	return palette().get("schools", {}).keys()


static func intensity(kind: String) -> float:
	return float(palette().get("intensity", {}).get(kind, 1.0))


static func budget() -> Dictionary:
	return palette().get("budget", {})


static func defaults() -> Dictionary:
	return palette().get("defaults", {})


static func dust_color() -> Color:
	return _rgb(palette().get("dust", [0.5, 0.45, 0.38]))


## Outline color of a ground effect: red-tinted when an enemy of the local player cast it.
static func outline_color(hostile: bool) -> Color:
	var rel: Dictionary = palette().get("relation", {})
	var c: Array = rel.get("enemy_outline" if hostile else "ally_outline", [1, 1, 1, 1])
	return Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))


static func outline_width_m() -> float:
	return float(palette().get("relation", {}).get("outline_width_m", 0.3))


## Largest radius among the ability's area effects (0 when it has none).
static func radius_of(ability_id: String) -> float:
	var r: float = 0.0
	for eff: Dictionary in Data.abilities.get(ability_id, {}).get("effects", []):
		r = maxf(r, float(eff.get("radius_m", 0.0)))
	return r


## The visual of an aura ({"style", "size", "school", "ability"}), or empty when it has none.
static func aura_visual(aura_id: String) -> Dictionary:
	if not _indexed:
		_build_aura_index()
	return _aura_index.get(aura_id, {})


## True for crowd-control auras (drawn with priority and never dropped for the budget).
static func is_cc(aura_id: String) -> bool:
	var cat: String = str(Data.auras.get(aura_id, {}).get("cc_category", "none"))
	return cat != "none" and cat != "knockback"


static func _build_aura_index() -> void:
	_aura_index = {}
	for ability_id: String in Data.effects:
		var e: Dictionary = Data.effects[ability_id]
		for aura_id: String in e.get("auras", {}):
			var v: Variant = e["auras"][aura_id]
			if typeof(v) != TYPE_DICTIONARY:
				continue  # "none"
			var vis: Dictionary = (v as Dictionary).duplicate()
			vis["school"] = school_of(ability_id)
			vis["ability"] = ability_id
			_aura_index[aura_id] = vis
	_indexed = true


static func _rgb(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))
