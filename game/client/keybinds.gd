class_name Keybinds
extends RefCounted
## Registers a keybind profile (data/keybinds/<id>.json) in Godot's InputMap (backlog M1-23).
## Every action in the profile gets exactly the profile's key or mouse button, with its modifier
## keys; events already registered for those actions are replaced. Actions the profile does not
## name are left alone. The rebinding screen (M2) edits a copy of a profile and applies it here.
##
## Matching: an action bound without modifiers also fires while a modifier is held (Shift+W
## still moves forward). Checks that must tell "1" from "Shift+1" (the action bars) pass
## exact_match = true to InputEvent.is_action_pressed.
##
##   Keybinds.load_profile("default")
##
## The player's own binds (the keybinding screen, M2-11) are a full copy of a profile saved in
## the user's folder; load_user() applies it, or the default when there is none. Each bind may
## carry a target mode (target, focus, mouseover, self, arena 1 to 3, party 1 to 4) that the
## player controller uses for that key's ability.

const DEADZONE: float = 0.2
const USER_PATH: String = "user://keybinds.json"
const TARGET_MODES: Array[String] = ["default", "target", "focus", "mouseover", "self", "arena1", "arena2", "arena3",
	"party1", "party2", "party3", "party4"]

static var current: Dictionary = {}  ## the profile last applied

## Mouse button names a profile may use. MOUSE_BUTTON_1..5 follow DESIGN.md's "mouse buttons 1
## to 5": left, right, middle and the two side buttons.
const MOUSE_BUTTONS: Dictionary = {
	"MOUSE_BUTTON_LEFT": MOUSE_BUTTON_LEFT,
	"MOUSE_BUTTON_RIGHT": MOUSE_BUTTON_RIGHT,
	"MOUSE_BUTTON_MIDDLE": MOUSE_BUTTON_MIDDLE,
	"MOUSE_BUTTON_WHEEL_UP": MOUSE_BUTTON_WHEEL_UP,
	"MOUSE_BUTTON_WHEEL_DOWN": MOUSE_BUTTON_WHEEL_DOWN,
	"MOUSE_BUTTON_WHEEL_LEFT": MOUSE_BUTTON_WHEEL_LEFT,
	"MOUSE_BUTTON_WHEEL_RIGHT": MOUSE_BUTTON_WHEEL_RIGHT,
	"MOUSE_BUTTON_XBUTTON1": MOUSE_BUTTON_XBUTTON1,
	"MOUSE_BUTTON_XBUTTON2": MOUSE_BUTTON_XBUTTON2,
	"MOUSE_BUTTON_1": MOUSE_BUTTON_LEFT,
	"MOUSE_BUTTON_2": MOUSE_BUTTON_RIGHT,
	"MOUSE_BUTTON_3": MOUSE_BUTTON_MIDDLE,
	"MOUSE_BUTTON_4": MOUSE_BUTTON_XBUTTON1,
	"MOUSE_BUTTON_5": MOUSE_BUTTON_XBUTTON2,
}


## Load a profile from Data.keybinds into the InputMap. Returns the actions registered.
static func load_profile(profile_id: String = "default") -> Array[String]:
	var profile: Dictionary = Data.keybinds.get(profile_id, {})
	if profile.is_empty():
		Log.error("keybinds: no profile '%s'" % profile_id)
		return []
	return apply(profile)


## Register every bind of a profile dictionary. Returns the actions registered.
static func apply(profile: Dictionary) -> Array[String]:
	current = profile
	var done: Array[String] = []
	for bind: Dictionary in profile.get("binds", []):
		var action: String = bind["action"]
		var ev: InputEvent = event_for(bind)
		if ev == null:
			Log.error("keybinds: %s: unknown key '%s' for %s" % [profile.get("id", "?"), bind["key"], action])
			continue
		if InputMap.has_action(action):
			if action not in done:
				InputMap.action_erase_events(action)
		else:
			InputMap.add_action(action, DEADZONE)
		InputMap.action_add_event(action, ev)
		done.append(action)
	Log.info("keybinds: loaded profile '%s' (%d actions)" % [profile.get("id", "?"), done.size()])
	return done


## The input event for one bind ({key, modifiers}), or null when the key name is unknown.
static func event_for(bind: Dictionary) -> InputEvent:
	var key: String = bind["key"]
	var ev: InputEventWithModifiers
	if MOUSE_BUTTONS.has(key):
		var mb: InputEventMouseButton = InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTONS[key]
		ev = mb
	elif key.begins_with("KEY_"):
		var code: Key = OS.find_keycode_from_string(key.trim_prefix("KEY_"))
		if code == KEY_NONE:
			return null
		var k: InputEventKey = InputEventKey.new()
		k.keycode = code
		ev = k
	else:
		return null
	var mods: Array = bind.get("modifiers", [])
	ev.shift_pressed = "shift" in mods
	ev.ctrl_pressed = "ctrl" in mods
	ev.alt_pressed = "alt" in mods
	return ev


## Readable label of an action's first bind ("Shift+1", "Tab", "Mouse 2"), for keybind labels on
## the action bars (M1-27). Empty when the action has no bind.
static func label(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	var events: Array[InputEvent] = InputMap.action_get_events(action)
	if events.is_empty():
		return ""
	var ev: InputEvent = events[0]
	if ev is InputEventKey:
		return OS.get_keycode_string((ev as InputEventKey).get_keycode_with_modifiers())
	if ev is InputEventMouseButton:
		var m: InputEventMouseButton = ev
		var prefix: String = ("Shift+" if m.shift_pressed else "") + ("Ctrl+" if m.ctrl_pressed else "") \
			+ ("Alt+" if m.alt_pressed else "")
		match m.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				return prefix + "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN:
				return prefix + "Wheel Down"
			MOUSE_BUTTON_XBUTTON1:
				return prefix + "Mouse 4"
			MOUSE_BUTTON_XBUTTON2:
				return prefix + "Mouse 5"
			_:
				return prefix + "Mouse %d" % m.button_index
	return ev.as_text()


# ------------------------------------------------------------------ the player's own binds (M2-11)

## The player's saved profile, or a copy of `default_id` when none is saved (or it is broken).
static func user_profile(default_id: String = "default", path: String = USER_PATH) -> Dictionary:
	var base: Dictionary = Data.keybinds.get(default_id, {}).duplicate(true)
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and problem(parsed) == "":
			return parsed
		Log.warn("keybinds: ignoring the saved binds in %s" % path)
	base["id"] = "user"
	base["name"] = "Your key bindings"
	return base


## Apply the player's profile (or the default).
static func load_user(default_id: String = "default", path: String = USER_PATH) -> Array[String]:
	return apply(user_profile(default_id, path))


static func save_user(profile: Dictionary, path: String = USER_PATH) -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(profile, "  "))
	return true


## Why a profile cannot be used ("" when it can): every bind needs a known key and target mode.
static func problem(profile: Dictionary) -> String:
	if not profile.get("binds") is Array:
		return "no binds"
	for b: Variant in profile["binds"]:
		if not b is Dictionary or not b.has("action") or not b.has("key"):
			return "a bind without an action or key"
		if event_for(b) == null:
			return "unknown key %s" % b["key"]
		if str(b.get("target_mode", "default")) not in TARGET_MODES:
			return "unknown target mode %s" % b["target_mode"]
	return ""


## The bind of an action in a profile, or {}.
static func bind_of(profile: Dictionary, action: String) -> Dictionary:
	for b: Dictionary in profile.get("binds", []):
		if b["action"] == action:
			return b
	return {}


## A key and its modifiers as one comparable string ("KEY_1+shift").
static func chord(bind: Dictionary) -> String:
	var mods: Array = bind.get("modifiers", []).duplicate()
	mods.sort()
	return "+".join([str(bind["key"])] + mods)


## Actions sharing a key chord with another action: action -> the other actions.
static func conflicts(profile: Dictionary) -> Dictionary:
	var by_chord: Dictionary = {}
	for b: Dictionary in profile.get("binds", []):
		var c: String = chord(b)
		if not by_chord.has(c):
			by_chord[c] = []
		by_chord[c].append(b["action"])
	var out: Dictionary = {}
	for c: String in by_chord:
		var acts: Array = by_chord[c]
		if acts.size() > 1:
			for a: String in acts:
				out[a] = acts.filter(func(x: String) -> bool: return x != a)
	return out


## Bind an action to a chord (replacing its old one), keeping its target mode.
static func rebind(profile: Dictionary, action: String, key: String, modifiers: Array) -> void:
	var b: Dictionary = bind_of(profile, action)
	if b.is_empty():
		b = {"action": action}
		profile["binds"].append(b)
	b["key"] = key
	if modifiers.is_empty():
		b.erase("modifiers")
	else:
		b["modifiers"] = modifiers.duplicate()


static func set_target_mode(profile: Dictionary, action: String, mode: String) -> void:
	var b: Dictionary = bind_of(profile, action)
	if b.is_empty() or mode not in TARGET_MODES:
		return
	if mode == "default":
		b.erase("target_mode")
	else:
		b["target_mode"] = mode


## The target mode of an action in the applied profile ("default" when it has none).
static func target_mode(action: String) -> String:
	return str(bind_of(current, action).get("target_mode", "default"))


## The bind a pressed key or mouse button makes: {"key", "modifiers"}, or {} for a bare modifier
## key (Shift alone is held for a chord, not bound).
static func bind_from_event(ev: InputEvent) -> Dictionary:
	var key: String = ""
	if ev is InputEventKey:
		var k: InputEventKey = ev
		if k.keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
			return {}
		key = "KEY_" + OS.get_keycode_string(k.keycode).to_upper().replace(" ", "_")
		if OS.find_keycode_from_string(key.trim_prefix("KEY_")) == KEY_NONE:
			return {}
	elif ev is InputEventMouseButton:
		for name: String in MOUSE_BUTTONS:
			var numbered: bool = name[name.length() - 2] == "_" and name[name.length() - 1].is_valid_int()  # MOUSE_BUTTON_1..5 aliases
			if MOUSE_BUTTONS[name] == (ev as InputEventMouseButton).button_index and not numbered:
				key = name
				break
	if key == "":
		return {}
	var mods: Array = []
	var m: InputEventWithModifiers = ev
	if m.shift_pressed:
		mods.append("shift")
	if m.ctrl_pressed:
		mods.append("ctrl")
	if m.alt_pressed:
		mods.append("alt")
	return {"key": key, "modifiers": mods}


## The profile as a short text to share (base64 of its JSON).
static func export_text(profile: Dictionary) -> String:
	return Marshalls.utf8_to_base64(JSON.stringify({"binds": profile.get("binds", [])}))


## A profile from such a text: {"profile", "error"}.
static func import_text(text: String) -> Dictionary:
	var raw: String = Marshalls.base64_to_utf8(text.strip_edges()) if text.strip_edges() != "" else ""
	var parsed: Variant = JSON.parse_string(raw) if raw != "" else null
	if not parsed is Dictionary:
		return {"profile": {}, "error": "not a key binding code"}
	var profile: Dictionary = {"id": "user", "name": "Your key bindings", "binds": parsed.get("binds", [])}
	var err: String = problem(profile)
	return {"profile": profile if err == "" else {}, "error": err}
