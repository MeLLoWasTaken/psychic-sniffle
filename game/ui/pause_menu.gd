class_name PauseMenu
extends Control
## The in-match menu (backlog M1-28): Escape with no target opens it, over the arena; the match
## keeps running (it is online). Resume closes it, Leave ends the match (online) or goes back to
## the main menu (practice). Settings opens the settings suite over everything (M2-13), so
## changes show at once in the running match. Style and text from the menu data (MenuStyle).

signal resume_pressed()
signal leave_pressed()

const SIZE: Vector2 = Vector2(560, 456)

var style: MenuStyle
var note: String = ""
var resume_button: Button
var leave_button: Button
var settings_button: Button
var settings_layer: CanvasLayer = null  ## the open settings screen's layer, or null


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
	leave_button = style.button(leave_label, Vector2(360, 58), 24)
	leave_button.name = "Leave"
	leave_button.position = Vector2((SIZE.x - 360.0) * 0.5, 282)
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


func focus_first() -> void:
	resume_button.grab_focus.call_deferred()


func _draw() -> void:
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	style.draw_panel(self, r)
	style.draw_text(self, Vector2(0, 82), style.text("menu_title"), 42, style.color("title"), HORIZONTAL_ALIGNMENT_CENTER,
		size.x, &"display")
	style.draw_rule(self, Vector2(size.x * 0.5, 104), 150.0)
	if note != "":
		style.draw_text(self, Vector2(0, 398), note, 19, style.color("text_dim"), HORIZONTAL_ALIGNMENT_CENTER, size.x)
