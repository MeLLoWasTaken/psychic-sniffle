class_name SettingsScreen
extends Control
## The settings suite (backlog M2-13), drawn from the menu data's "settings_screen" pages:
## Interface, Gameplay, Graphics, Audio, Accessibility and Key bindings. Each row is a slider,
## an on/off button, a choice that cycles, the audio output device, a note, or the button that
## opens the keybinding screen. A change applies at once through Settings.set_value (only the
## resolution waits for a restart); Done saves. Profiles: next, new, delete; reset the page or all.
##
## Positions are logical pixels on the 1920x1080 canvas.

signal closed

const ROW_H: float = 46.0
const TOP: float = 236.0
const LABEL_X: float = 260.0
const CONTROL_X: float = 1000.0
const CONTROL_W: float = 480.0

var style: MenuStyle
var pages: Array = []
var page: String = ""
var tab_buttons: Dictionary = {}
var row_controls: Array = []  ## [{"row", "control", "rect"}] for the shown page
var buttons: Dictionary = {}
var message: String = ""
var keybind_screen: KeybindScreen = null
var _syncing: bool = false


func _init(menu_id: String = "main") -> void:
	style = MenuStyle.new(menu_id)
	pages = style.menu.get("settings_screen", {}).get("pages", [])
	name = "SettingsScreen"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	if Settings.values.is_empty():
		Settings.use_data()
	var x: float = 120.0
	for p: Dictionary in pages:
		var tb: Button = style.button(str(p["label"]), Vector2(250, 48), 20)
		tb.name = "Tab_%s" % p["id"]
		tb.toggle_mode = true
		tb.position = Vector2(x, 150)
		tb.pressed.connect(show_page.bind(str(p["id"])))
		add_child(tb)
		tab_buttons[p["id"]] = tb
		x += 280.0
	for s: Array in [["next", "settings_profile_next"], ["new", "settings_profile_new"], ["delete", "settings_profile_delete"],
			["reset_page", "settings_reset_page"], ["reset_all", "settings_reset_all"], ["done", "talents_done"]]:
		var b: Button = style.button(style.text(s[1]), Vector2(200, 46), 20)
		b.name = "Button_%s" % s[0]
		b.pressed.connect(press.bind(s[0]))
		add_child(b)
		buttons[s[0]] = b
	Settings.bus.changed.connect(_on_changed)
	resized.connect(_layout)
	show_page(str(pages[0]["id"]) if not pages.is_empty() else "")


func _layout() -> void:
	var y: float = size.y - 92.0
	var x: float = 120.0
	for k: String in ["next", "new", "delete", "reset_page", "reset_all"]:
		buttons[k].position = Vector2(x, y)
		x += 214.0
	buttons["done"].position = Vector2(size.x - 120.0 - 200.0, y)
	queue_redraw()


func current_page() -> Dictionary:
	for p: Dictionary in pages:
		if p["id"] == page:
			return p
	return {}


func show_page(id: String) -> void:
	page = id
	for k: String in tab_buttons:
		(tab_buttons[k] as Button).set_pressed_no_signal(k == id)
	for rc: Dictionary in row_controls:
		if rc["control"] != null:
			(rc["control"] as Control).queue_free()
	row_controls.clear()
	var rows: Array = current_page().get("rows", [])
	for i: int in rows.size():
		var row: Dictionary = rows[i]
		var rect: Rect2 = Rect2(LABEL_X - 20.0, TOP + i * ROW_H, CONTROL_X + CONTROL_W - LABEL_X + 160.0, ROW_H - 6.0)
		var c: Control = _make_control(row)
		if c != null:
			c.position = Vector2(CONTROL_X, rect.position.y + 4.0)
			add_child(c)
		row_controls.append({"row": row, "control": c, "rect": rect})
	sync()


func _make_control(row: Dictionary) -> Control:
	match str(row["type"]):
		"toggle":
			var b: Button = style.button("", Vector2(150, 36), 18)
			b.toggle_mode = true
			b.toggled.connect(func(on: bool) -> void:
				if not _syncing:
					Settings.set_value(row["path"], on))
			return b
		"slider":
			var s: HSlider = HSlider.new()
			s.min_value = float(row["min"])
			s.max_value = float(row["max"])
			s.step = float(row["step"])
			s.custom_minimum_size = Vector2(CONTROL_W - 120.0, 30)
			s.size = s.custom_minimum_size
			_style_slider(s)
			s.value_changed.connect(func(v: float) -> void:
				if not _syncing:
					Settings.set_value(row["path"], _typed(row, v)))
			return s
		"choice", "device":
			var b: Button = style.button("", Vector2(CONTROL_W - 120.0, 36), 18)
			b.pressed.connect(cycle.bind(row))
			return b
		"keybinds":
			var b: Button = style.button(style.text("settings_open_keybinds"), Vector2(300, 40), 18)
			b.pressed.connect(open_keybinds)
			return b
	return null


## Sliders over whole numbers store whole numbers (pixels, milliseconds, metres of range).
static func _typed(row: Dictionary, v: float) -> Variant:
	var whole: bool = is_equal_approx(float(row["step"]), roundf(float(row["step"]))) and is_equal_approx(float(row["min"]), roundf(float(row["min"])))
	return int(roundf(v)) if whole else snappedf(v, float(row["step"]))


func _style_slider(s: HSlider) -> void:
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = style.color("button_bg")
	track.border_color = style.color("button_border")
	track.set_border_width_all(1)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	var fill: StyleBoxFlat = track.duplicate()
	fill.bg_color = Color(style.color("accent"), 0.6)
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)


## The choices of a row: its data list, or the audio output devices.
static func choices_of(row: Dictionary) -> Array:
	if str(row["type"]) == "device":
		var d: Array = Array(AudioServer.get_output_device_list())
		if not "Default" in d:
			d.push_front("Default")
		return d
	return row.get("choices", [])


func cycle(row: Dictionary) -> void:
	var c: Array = choices_of(row)
	if c.is_empty():
		return
	var i: int = c.find(Settings.get_value(row["path"]))
	Settings.set_value(row["path"], c[(i + 1) % c.size()])


func choice_label(row: Dictionary, v: Variant) -> String:
	if str(row["type"]) == "device":
		return style.text("settings_device_default") if str(v) == "Default" else str(v)
	var c: Array = row.get("choices", [])
	var i: int = c.find(v)
	return str(row["labels"][i]) if row.has("labels") and i >= 0 else str(v)


## Show every row's current value (after a change, a preset or a profile switch).
func sync() -> void:
	_syncing = true
	for rc: Dictionary in row_controls:
		var row: Dictionary = rc["row"]
		var c: Control = rc["control"]
		if c == null or not row.has("path"):
			continue
		var v: Variant = Settings.get_value(row["path"])
		match str(row["type"]):
			"toggle":
				(c as Button).button_pressed = bool(v)
				(c as Button).text = style.text("settings_on" if bool(v) else "settings_off")
			"slider":
				(c as HSlider).value = float(v)
			"choice", "device":
				(c as Button).text = choice_label(row, v)
	_syncing = false
	queue_redraw()


func _on_changed(_p: String, _v: Variant) -> void:
	if Settings.restart_needed:
		message = style.text("settings_restart")
	sync()


func press(what: String) -> void:
	match what:
		"next":
			var names: Array = Settings.profile_names()
			Settings.use_profile(names[(names.find(Settings.store["active"]) + 1) % names.size()])
		"new":
			var n: int = Settings.profile_names().size() + 1
			while Settings.store["profiles"].has("Profile %d" % n):
				n += 1
			Settings.use_profile("Profile %d" % n)
		"delete":
			Settings.delete_profile(str(Settings.store["active"]))
		"reset_page":
			var prefixes: Dictionary = {}
			for row: Dictionary in current_page().get("rows", []):
				if row.has("path"):
					prefixes[row["path"]] = true
			for p: String in prefixes:
				Settings.reset(p)
		"reset_all":
			Settings.reset()
		"done":
			close()
			return
	sync()


func open_keybinds() -> void:
	if keybind_screen != null:
		return
	keybind_screen = KeybindScreen.new()
	keybind_screen.closed.connect(func() -> void:
		keybind_screen.queue_free()
		keybind_screen = null)
	add_child(keybind_screen)
	keybind_screen.size = size


func close() -> void:
	Settings.save()
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if is_visible_in_tree() and keybind_screen == null and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var top: Color = style.color("background_top")
	var bottom: Color = style.color("background_bottom")
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h), Vector2(0, h)]),
		PackedColorArray([top, top, bottom, bottom]))
	style.draw_text(self, Vector2(120, 100), style.text("settings_title").to_upper(), 46, style.color("title"),
		HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	style.draw_text(self, Vector2(0, 100), style.text("settings_profile_label", {"name": Settings.store.get("active", "")}), 22,
		style.color("subtitle"), HORIZONTAL_ALIGNMENT_RIGHT, w - 120.0)
	for i: int in row_controls.size():
		var rc: Dictionary = row_controls[i]
		var row: Dictionary = rc["row"]
		var r: Rect2 = rc["rect"]
		if i % 2 == 0:
			draw_rect(r, style.color("row_alt"))
		style.draw_text(self, Vector2(LABEL_X, r.position.y + 29.0), str(row["label"]), 20, style.color("text"))
		match str(row["type"]):
			"slider":
				var v: Variant = Settings.get_value(row["path"])
				var typed: Variant = _typed(row, float(v))
				var shown: String = (str(typed) if typed is int else str(snappedf(float(v), float(row["step"])))) + str(row.get("suffix", ""))
				style.draw_text(self, Vector2(CONTROL_X + CONTROL_W - 100.0, r.position.y + 29.0), shown, 18, style.color("subtitle"))
			"note", "keybinds":
				style.draw_text(self, Vector2(CONTROL_X + (320.0 if row["type"] == "keybinds" else 0.0), r.position.y + 29.0),
					str(row.get("text", "")), 18, style.color("text_dim"))
	if message != "":
		style.draw_text(self, Vector2(120, h - 112.0), message, 20, style.color("subtitle"))
