class_name KeybindScreen
extends Control
## The keybinding screen (backlog M2-11): every action of the keybind profile, grouped (movement,
## targeting, camera, the two action bars, interface), with its key. Click a key, then press the
## new key or mouse button, with Shift, Ctrl or Alt held for a chord (Esc cancels). Action bar
## buttons also choose a target mode (the target, focus, mouseover, self, arena 1 to 3, party 1
## to 4): the ability on that key goes to that unit without changing the target. Keys bound to
## two actions are marked. Save writes the player's binds (Keybinds.save_user) and applies them;
## Reset goes back to the default profile; Export copies a code and Import reads one.
##
## Positions are logical pixels on the 1920x1080 canvas.

signal closed

const ROW_H: float = 30.0
const TOP: float = 196.0
const COL_X: Array[float] = [70.0, 1000.0]
const COL_W: float = 850.0
const GROUPS: Array = [["movement", ["move_", "strafe_", "turn_", "jump"]], ["targeting", ["target_", "clear_target", "set_focus", "focus_"]],
	["camera", ["camera_"]], ["bar1", ["bar1_"]], ["bar2", ["bar2_"]]]

var style: MenuStyle
var profile: Dictionary
var default_id: String
var path: String
var capturing: String = ""  ## the action waiting for a key
var message: String = ""
var rows: Array = []  ## [{"action", "group", "rect"}] or [{"header", "rect"}]
var key_buttons: Dictionary = {}  ## action -> Button
var mode_buttons: Dictionary = {}  ## action -> Button (action bar buttons only)
var buttons: Dictionary = {}
var code_edit: LineEdit


func _init(p_default_id: String = "default", p_path: String = Keybinds.USER_PATH, menu_id: String = "main") -> void:
	style = MenuStyle.new(menu_id)
	default_id = p_default_id
	path = p_path
	profile = Keybinds.user_profile(default_id, path)
	name = "KeybindScreen"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


static func group_of(action: String) -> String:
	for g: Array in GROUPS:
		for prefix: String in g[1]:
			if action.begins_with(prefix):
				return g[0]
	return "interface"


func action_label(action: String) -> String:
	var t: String = style.text("action_" + action)
	if t != "action_" + action:
		return t
	if action.begins_with("bar"):
		return style.text("keybinds_bar_button", {"bar": action.substr(3, 1), "n": action.get_slice("slot", 1)})
	return Tooltip.sentence(action.replace("_", " "))


static func key_label(bind: Dictionary) -> String:
	if bind.is_empty():
		return "—"
	var ev: InputEvent = Keybinds.event_for(bind)
	if ev is InputEventKey:
		return OS.get_keycode_string((ev as InputEventKey).get_keycode_with_modifiers())
	var mods: String = "".join(PackedStringArray(bind.get("modifiers", []).map(func(m: String) -> String: return m.capitalize() + "+")))
	var names: Dictionary = {"MOUSE_BUTTON_LEFT": "Mouse 1", "MOUSE_BUTTON_RIGHT": "Mouse 2", "MOUSE_BUTTON_MIDDLE": "Mouse 3",
		"MOUSE_BUTTON_XBUTTON1": "Mouse 4", "MOUSE_BUTTON_XBUTTON2": "Mouse 5", "MOUSE_BUTTON_WHEEL_UP": "Wheel Up",
		"MOUSE_BUTTON_WHEEL_DOWN": "Wheel Down", "MOUSE_BUTTON_1": "Mouse 1", "MOUSE_BUTTON_2": "Mouse 2",
		"MOUSE_BUTTON_3": "Mouse 3", "MOUSE_BUTTON_4": "Mouse 4", "MOUSE_BUTTON_5": "Mouse 5"}
	return mods + str(names.get(str(bind["key"]), str(bind["key"]).capitalize()))


func _build() -> void:
	# rows: groups in order, filling the left column then the right
	var actions: Array = profile["binds"].map(func(b: Dictionary) -> String: return b["action"])
	var ordered: Array = []
	for g: Array in GROUPS + [["interface", []]]:
		var members: Array = actions.filter(func(a: String) -> bool: return group_of(a) == g[0])
		if not members.is_empty():
			ordered.append({"header": g[0]})
			for a: String in members:
				ordered.append({"action": a, "group": g[0]})
	var per_col: int = ceili(ordered.size() / 2.0)
	for i: int in ordered.size():
		var col: int = 0 if i < per_col else 1
		var r: Dictionary = ordered[i]
		r["rect"] = Rect2(COL_X[col], TOP + (i - col * per_col) * ROW_H, COL_W, ROW_H - 3.0)
		rows.append(r)
		if r.has("action"):
			var kb: Button = style.button("", Vector2(210, ROW_H - 4.0), 17)
			kb.name = "Key_%s" % r["action"]
			kb.pressed.connect(start_capture.bind(r["action"]))
			add_child(kb)
			key_buttons[r["action"]] = kb
			if r["group"] in ["bar1", "bar2"]:
				var mb: Button = style.button("", Vector2(170, ROW_H - 4.0), 16)
				mb.name = "Mode_%s" % r["action"]
				mb.pressed.connect(cycle_mode.bind(r["action"]))
				add_child(mb)
				mode_buttons[r["action"]] = mb
	for spec: Array in [["save", "keybinds_save", save], ["reset", "keybinds_reset", reset], ["export", "talents_export", _on_export],
			["import", "talents_import", _on_import], ["done", "talents_done", close]]:
		var b: Button = style.button(style.text(spec[1]), Vector2(170, 46), 20)
		b.name = "Button_%s" % spec[0]
		b.pressed.connect(spec[2])
		add_child(b)
		buttons[spec[0]] = b
	code_edit = LineEdit.new()
	code_edit.name = "KeybindCode"
	code_edit.placeholder_text = style.text("keybinds_code_hint")
	code_edit.add_theme_font_override("font", style.font)
	code_edit.add_theme_font_size_override("font_size", 18)
	code_edit.add_theme_color_override("font_color", style.color("text"))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = style.color("button_bg")
	sb.border_color = style.color("button_border")
	sb.set_border_width_all(2)
	sb.content_margin_left = 12
	code_edit.add_theme_stylebox_override("normal", sb)
	add_child(code_edit)
	resized.connect(_layout)
	refresh()


func _layout() -> void:
	for r: Dictionary in rows:
		if not r.has("action"):
			continue
		var rect: Rect2 = r["rect"]
		(key_buttons[r["action"]] as Button).position = Vector2(rect.position.x + 380.0, rect.position.y + 1.0)
		if mode_buttons.has(r["action"]):
			(mode_buttons[r["action"]] as Button).position = Vector2(rect.position.x + 610.0, rect.position.y + 1.0)
	var y: float = size.y - 92.0
	var x: float = COL_X[0]
	for k: String in ["save", "reset"]:
		buttons[k].position = Vector2(x, y)
		x += 186.0
	code_edit.position = Vector2(x + 20.0, y)
	code_edit.size = Vector2(520, 46)
	x += 556.0
	for k: String in ["export", "import"]:
		buttons[k].position = Vector2(x, y)
		x += 186.0
	buttons["done"].position = Vector2(size.x - 60.0 - 170.0, 44.0)
	queue_redraw()


## Show each action's key and target mode, and mark keys bound twice.
func refresh() -> void:
	var clash: Dictionary = Keybinds.conflicts(profile)
	for a: String in key_buttons:
		var b: Button = key_buttons[a]
		b.text = style.text("keybinds_press_key") if capturing == a else key_label(Keybinds.bind_of(profile, a))
		b.add_theme_color_override("font_color", style.color("defeat") if clash.has(a) else style.color("text"))
	for a: String in mode_buttons:
		var mode: String = str(Keybinds.bind_of(profile, a).get("target_mode", "default"))
		(mode_buttons[a] as Button).text = style.text("keybinds_mode_" + mode)
	queue_redraw()


func start_capture(action: String) -> void:
	capturing = action
	message = style.text("keybinds_capture_hint", {"action": action_label(action)})
	refresh()


## Bind the action being captured to the pressed key or button; true when it was used.
func capture(ev: InputEvent) -> bool:
	if capturing == "" or not ev.is_pressed() or ev.is_echo():
		return false
	if ev is InputEventKey and (ev as InputEventKey).keycode == KEY_ESCAPE:
		capturing = ""
		message = ""
		refresh()
		return true
	var b: Dictionary = Keybinds.bind_from_event(ev)
	if b.is_empty():
		return ev is InputEventKey  # a lone modifier: keep waiting
	Keybinds.rebind(profile, capturing, b["key"], b["modifiers"])
	var clash: Array = Keybinds.conflicts(profile).get(capturing, [])
	message = style.text("keybinds_conflict", {"key": key_label(Keybinds.bind_of(profile, capturing)),
		"others": ", ".join(PackedStringArray(clash.map(func(a: String) -> String: return action_label(a))))}) if not clash.is_empty() else ""
	capturing = ""
	refresh()
	return true


func cycle_mode(action: String) -> void:
	var mode: String = str(Keybinds.bind_of(profile, action).get("target_mode", "default"))
	var i: int = Keybinds.TARGET_MODES.find(mode)
	Keybinds.set_target_mode(profile, action, Keybinds.TARGET_MODES[(i + 1) % Keybinds.TARGET_MODES.size()])
	refresh()


func save() -> void:
	Keybinds.save_user(profile, path)
	Keybinds.apply(profile)
	message = style.text("keybinds_saved")
	refresh()


func reset() -> void:
	profile = Data.keybinds.get(default_id, {}).duplicate(true)
	profile["id"] = "user"
	message = style.text("keybinds_reset_done")
	refresh()


func _on_export() -> void:
	code_edit.text = Keybinds.export_text(profile)
	DisplayServer.clipboard_set(code_edit.text)
	message = style.text("talents_exported")
	queue_redraw()


func _on_import() -> void:
	var text: String = code_edit.text.strip_edges()
	if text == "":
		text = DisplayServer.clipboard_get().strip_edges()
	var r: Dictionary = Keybinds.import_text(text)
	if r["error"] != "":
		message = style.text("talents_import_failed", {"why": r["error"]})
	else:
		profile = r["profile"]
		message = style.text("keybinds_imported")
	refresh()


func close() -> void:
	capturing = ""
	closed.emit()


func _input(event: InputEvent) -> void:
	if capturing != "" and is_visible_in_tree() and (event is InputEventKey or event is InputEventMouseButton):
		# the click that started the capture is a left release on the key button; take presses only
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
				and key_buttons[capturing].get_global_rect().has_point((event as InputEventMouseButton).position):
			return
		if capture(event):
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if is_visible_in_tree() and capturing == "" and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var top: Color = style.color("background_top")
	var bottom: Color = style.color("background_bottom")
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h), Vector2(0, h)]),
		PackedColorArray([top, top, bottom, bottom]))
	style.draw_text(self, Vector2(COL_X[0], 84), style.text("keybinds_title").to_upper(), 46, style.color("title"),
		HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	style.draw_text(self, Vector2(COL_X[0], 124), style.text("keybinds_subtitle"), 20, style.color("subtitle"))
	var clash: Dictionary = Keybinds.conflicts(profile)
	for r: Dictionary in rows:
		var rect: Rect2 = r["rect"]
		if r.has("header"):
			style.draw_text(self, Vector2(rect.position.x, rect.end.y - 6.0), style.text("keybinds_group_" + str(r["header"])).to_upper(),
				18, style.color("accent"), HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
			draw_line(Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.end.y), Color(style.color("button_border"), 0.5), 1.0)
			continue
		style.draw_text(self, Vector2(rect.position.x + 8.0, rect.end.y - 4.0), action_label(r["action"]), 18,
			style.color("defeat") if clash.has(r["action"]) else style.color("text"))
	if message != "":
		style.draw_text(self, Vector2(COL_X[0], h - 112.0), message, 20, style.color("subtitle"))
