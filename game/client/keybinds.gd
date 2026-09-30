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

const DEADZONE: float = 0.2

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
