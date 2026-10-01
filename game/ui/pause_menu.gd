class_name PauseMenu
extends Control
## The in-match menu (backlog M1-28): Escape with no target opens it, over the arena; the match
## keeps running (it is online). Resume closes it, Leave ends the match (online) or goes back to
## the main menu (practice). Settings opens the settings suite over everything (M2-13), so
## changes show at once in the running match. Talents opens the talent screen (M2-05b): during
## preparation a new loadout is offered with talents_chosen; once the gates open it is read-only.
## Style and text from the menu data (MenuStyle).

signal resume_pressed()
signal leave_pressed()
## The talent screen closed with this loadout active (not emitted when it was read-only).
signal talents_chosen(talents: String)

const SIZE: Vector2 = Vector2(560, 560)

var style: MenuStyle
var note: String = ""
var resume_button: Button
var leave_button: Button
var settings_button: Button
var talents_button: Button
var settings_layer: CanvasLayer = null  ## the open settings screen's layer, or null
var talents_layer: CanvasLayer = null  ## the open talent screen's layer, or null
var spec_id: String = ""  ## the player's spec (the talent screen); "" hides the Talents button
var talents_locked: Callable  ## returns true once talents can no longer change (gates open)
var status: String = ""  ## a line under the buttons (the server's answer to a talent change)


func _init(p_style: MenuStyle, leave_label: String, p_note: String = "") -> void:
	style = p_style
	note = p_note
	name = "PauseMenu"
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	resume_button = style.button(style.text("resume"), Vector2(360, 58), 24)
	resume_button.name = "Resume"
	resume_button.position = Vector2((SIZE.x - 360.0) * 0.5, 130)
	resume_button.pressed.connect(func() -> void: resume_pressed.emit())
	add_child(resume_button)
	settings_button = style.button(style.text("settings_title"), Vector2(360, 58), 24)
	settings_button.name = "Settings"
	settings_button.position = Vector2((SIZE.x - 360.0) * 0.5, 206)
	settings_button.pressed.connect(open_settings)
	add_child(settings_button)
	talents_button = style.button(style.text("talents_title"), Vector2(360, 58), 24)
	talents_button.name = "Talents"
	talents_button.position = Vector2((SIZE.x - 360.0) * 0.5, 282)
	talents_button.pressed.connect(func() -> void: open_talents())
	talents_button.visible = false  # until set_spec
	add_child(talents_button)
	leave_button = style.button(leave_label, Vector2(360, 58), 24)
	leave_button.name = "Leave"
	leave_button.position = Vector2((SIZE.x - 360.0) * 0.5, 358)
	leave_button.pressed.connect(func() -> void: leave_pressed.emit())
	add_child(leave_button)


## The settings suite on its own layer above the HUD; closing it comes back here.
func open_settings() -> SettingsScreen:
	if settings_layer != null:
		return settings_layer.get_child(0)
	settings_layer = CanvasLayer.new()
	settings_layer.layer = 30
	var s: SettingsScreen = SettingsScreen.new()
	settings_layer.add_child(s)
	get_tree().root.add_child(settings_layer)
	s.closed.connect(func() -> void:
		settings_layer.queue_free()
		settings_layer = null
		focus_first())
	return s


## The talent screen on its own layer above the HUD, read-only once talents are locked.
func open_talents(store: TalentLoadouts = null) -> TalentScreen:
	if talents_layer != null:
		return talents_layer.get_child(0)
	var locked: bool = talents_locked.is_valid() and bool(talents_locked.call())
	talents_layer = CanvasLayer.new()
	talents_layer.layer = 30
	var t: TalentScreen = TalentScreen.new(spec_id, store, locked)
	talents_layer.add_child(t)
	get_tree().root.add_child(talents_layer)
	t.closed.connect(func(_spec: String, text: String) -> void:
		talents_layer.queue_free()
		talents_layer = null
		if not locked:
			talents_chosen.emit(text)
		focus_first())
	return t


func set_spec(p_spec_id: String, p_locked: Callable) -> void:
	spec_id = p_spec_id
	talents_locked = p_locked
	talents_button.visible = spec_id != "" and Data.specs.has(spec_id)


func set_status(text: String) -> void:
	status = text
	queue_redraw()


func focus_first() -> void:
	resume_button.grab_focus.call_deferred()


func _draw() -> void:
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	style.draw_panel(self, r)
	style.draw_text(self, Vector2(0, 82), style.text("menu_title"), 42, style.color("title"), HORIZONTAL_ALIGNMENT_CENTER,
		size.x, &"display")
	style.draw_rule(self, Vector2(size.x * 0.5, 104), 150.0)
	if status != "":
		style.draw_text(self, Vector2(0, 458), status, 19, style.color("subtitle"), HORIZONTAL_ALIGNMENT_CENTER, size.x)
	if note != "":
		style.draw_text(self, Vector2(0, 498), note, 19, style.color("text_dim"), HORIZONTAL_ALIGNMENT_CENTER, size.x)
