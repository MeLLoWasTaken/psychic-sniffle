class_name Appearance
extends RefCounted
## A character's look (backlog G-05; docs/DESIGN.md "Appearance and armor customization"):
## body type, height, face, colours, hair, beard, markings, one armor piece per slot and dyes.
## Cosmetic only: nothing here reaches the simulation. Options come from data/appearance and
## data/armor_sets; a piece is "<set>:<slot>" or "" for none. The server sanitizes what clients
## send, so a look always names real options and pieces of the class's armor type.

const SLOTS: Array[String] = ["head", "shoulders", "chest", "hands", "waist", "legs", "feet", "back"]
const REQUIRED_SLOTS: Array[String] = ["chest", "legs", "feet"]  ## can not be hidden
const BODY_TYPES: Array[String] = ["male", "female"]
const HEIGHT_MIN: float = 0.96
const HEIGHT_MAX: float = 1.04
const DYE_CHANNELS: Array[String] = ["primary", "secondary", "metal"]


## Ids of one option set (data/appearance/<kind>.json) usable by a body type.
static func option_ids(kind: String, body_type: String = "") -> Array[String]:
	var out: Array[String] = []
	for o: Dictionary in Data.appearance.get(kind, {}).get("options", []):
		var types: Array = o.get("body_types", [])
		if body_type == "" or types.is_empty() or body_type in types:
			out.append(str(o["id"]))
	return out


static func option(kind: String, id: String) -> Dictionary:
	for o: Dictionary in Data.appearance.get(kind, {}).get("options", []):
		if str(o["id"]) == id:
			return o
	return {}


## The armor type a spec's class wears (data/classes armor).
static func armor_type(spec_id: String) -> String:
	var cls: String = str(Data.specs.get(spec_id, {}).get("class", ""))
	return str(Data.classes.get(cls, {}).get("armor", ""))


## The class's default armor set (data/armor_sets default_for), or "".
static func default_set(spec_id: String) -> String:
	var cls: String = str(Data.specs.get(spec_id, {}).get("class", ""))
	for s: Dictionary in Data.armor_sets.values():
		if cls in s.get("default_for", []):
			return str(s["id"])
	return ""


## Dye colours of a set for a spec ("default" when the set has none for it).
static func set_dyes(set_id: String, spec_id: String) -> Dictionary:
	var dyes: Dictionary = Data.armor_sets.get(set_id, {}).get("dyes", {})
	return (dyes.get(spec_id, dyes.get("default", {"primary": "#cfc8bc", "secondary": "#d2c4a0", "metal": "#a9adb3"})) as Dictionary).duplicate()


## The look a spec starts with: its class's default set in its dyes on a plain male body.
static func default_for(spec_id: String) -> Dictionary:
	var set_id: String = default_set(spec_id)
	var pieces: Dictionary = {}
	var dyes: Dictionary = {}
	for slot: String in SLOTS:
		var has: bool = set_id != "" and Data.armor_sets[set_id].get("pieces", {}).has(slot)
		pieces[slot] = "%s:%s" % [set_id, slot] if has else ""
		dyes[slot] = set_dyes(set_id, spec_id)
	return {"body": "male", "height": 1.0, "face": "neutral", "skin": "light", "hair": "cropped",
		"hair_color": "brown", "beard": "none", "eyes": "brown", "marking": "none", "paint": "#2b3a52",
		"pieces": pieces, "dyes": dyes}


## A varied look for a bot: body, face, colours and hair drawn from `rng`, armor as default.
static func random_for(spec_id: String, rng: RandomNumberGenerator) -> Dictionary:
	var a: Dictionary = default_for(spec_id)
	a["body"] = BODY_TYPES[rng.randi() % BODY_TYPES.size()]
	a["height"] = snappedf(rng.randf_range(HEIGHT_MIN, HEIGHT_MAX), 0.005)
	for kind: String in ["faces", "skin_tones", "hair", "hair_colors", "eye_colors"]:
		var ids: Array[String] = option_ids(kind, str(a["body"]))
		var key: String = {"faces": "face", "skin_tones": "skin", "hair": "hair", "hair_colors": "hair_color",
			"eye_colors": "eyes"}[kind]
		if not ids.is_empty():
			a[key] = ids[rng.randi() % ids.size()]
	if a["body"] == "male":
		var beards: Array[String] = option_ids("beards", "male")
		a["beard"] = beards[rng.randi() % beards.size()] if not beards.is_empty() else "none"
	return a


## A valid look for `spec_id` from anything a client sent: unknown options fall back to the
## default, pieces must exist and be of the class's armor type, dyes must be colours.
static func sanitize(raw: Variant, spec_id: String) -> Dictionary:
	var base: Dictionary = default_for(spec_id)
	if typeof(raw) != TYPE_DICTIONARY:
		return base
	var a: Dictionary = raw
	var out: Dictionary = base.duplicate(true)
	var body: String = str(a.get("body", base["body"]))
	out["body"] = body if body in BODY_TYPES else base["body"]
	out["height"] = clampf(float(a.get("height", 1.0)), HEIGHT_MIN, HEIGHT_MAX)
	for pair: Array in [["face", "faces"], ["skin", "skin_tones"], ["hair", "hair"], ["hair_color", "hair_colors"],
			["beard", "beards"], ["eyes", "eye_colors"], ["marking", "markings"]]:
		var v: String = str(a.get(pair[0], ""))
		if v in option_ids(pair[1], str(out["body"])):
			out[pair[0]] = v
	if out["body"] != "male":
		out["beard"] = "none"
	if _is_colour(a.get("paint", "")):
		out["paint"] = str(a["paint"])
	var kind: String = armor_type(spec_id)
	var pieces: Dictionary = a.get("pieces", {}) if typeof(a.get("pieces")) == TYPE_DICTIONARY else {}
	for slot: String in SLOTS:
		if not pieces.has(slot):
			continue
		var p: String = str(pieces[slot])
		if p == "" and slot not in REQUIRED_SLOTS:
			out["pieces"][slot] = ""
		elif piece_valid(p, slot, kind):
			out["pieces"][slot] = p
	var dyes: Dictionary = a.get("dyes", {}) if typeof(a.get("dyes")) == TYPE_DICTIONARY else {}
	for slot: String in SLOTS:
		if typeof(dyes.get(slot)) != TYPE_DICTIONARY:
			continue
		for ch: String in DYE_CHANNELS:
			if _is_colour((dyes[slot] as Dictionary).get(ch, "")):
				out["dyes"][slot][ch] = str(dyes[slot][ch])
	return out


static func piece_valid(piece: String, slot: String, kind: String) -> bool:
	var parts: PackedStringArray = piece.split(":")
	if parts.size() != 2 or parts[1] != slot:
		return false
	var s: Dictionary = Data.armor_sets.get(parts[0], {})
	return not s.is_empty() and str(s.get("armor_type", "")) == kind and s.get("pieces", {}).has(slot)


## The built piece asset (data/assets, kind "piece") for a slot's piece on a body type, or "".
static func piece_asset(piece: String, body_type: String) -> String:
	if piece == "":
		return ""
	var parts: PackedStringArray = piece.split(":")
	var id: String = "%s_%s_%s" % [parts[0], parts[1], body_type]
	return id if Data.assets.has(id) else ""


## What the worn pieces hide (data/armor_sets "hides": hair, beard, face).
static func hidden(a: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for slot: String in SLOTS:
		var p: String = str(a.get("pieces", {}).get(slot, ""))
		if p == "":
			continue
		var parts: PackedStringArray = p.split(":")
		for h: Variant in Data.armor_sets.get(parts[0], {}).get("pieces", {}).get(parts[1], {}).get("hides", []):
			if str(h) not in out:
				out.append(str(h))
	return out


static func to_text(a: Dictionary) -> String:
	return JSON.stringify(a)


static func from_text(text: String, spec_id: String) -> Dictionary:
	return sanitize(JSON.parse_string(text) if text != "" else null, spec_id)


static func _is_colour(v: Variant) -> bool:
	var s: String = str(v)
	return s.length() == 7 and s.begins_with("#") and s.substr(1).is_valid_hex_number()


## The look the player saved for a spec (the creator, G-06), or the spec's default.
static func load_saved(spec_id: String) -> Dictionary:
	var path: String = "user://appearance/%s.json" % spec_id
	if not FileAccess.file_exists(path):
		return default_for(spec_id)
	return from_text(FileAccess.get_file_as_string(path), spec_id)


static func save(spec_id: String, a: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute("user://appearance")
	var f: FileAccess = FileAccess.open("user://appearance/%s.json" % spec_id, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(sanitize(a, spec_id), "\t"))
