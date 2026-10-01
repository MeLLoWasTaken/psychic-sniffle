class_name HudEditor
extends Control
## HUD edit mode (backlog M2-12), over the HUD while it runs. Every element gets a labeled outline
## (hidden ones dashed). Drag an element to move it (it snaps to an 8-pixel grid and anchors to
## the screen third it sits in, so it keeps its place at every resolution); the mouse wheel over
## it scales it from 50 to 200%. The panel changes the selected element's scale, opacity,
## visibility and its own option (action bar columns, which side unit frame auras sit on), and
## manages layout profiles: save, save as new, switch, delete, use for this spec only, export,
## import, reset. F10 or Done leaves edit mode; unsaved changes stay for this match only.

signal finished

const PANEL: Rect2 = Rect2(660, 305, 600, 470)
const COLUMN_CHOICES: Array[int] = [12, 6, 4, 3, 2, 1]

var hud: Hud
var style: MenuStyle
var selected: String = ""
var drag: Dictionary = {}  ## {"id", "grab"} while dragging
var message: String = ""
var buttons: Dictionary = {}
var name_edit: LineEdit
var code_edit: LineEdit
var profile: String = ""


func _init(p_hud: Hud) -> void:
	hud = p_hud
	style = MenuStyle.new("main")
	name = "HudEditor"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	if hud.layouts == null:
		hud.layouts = HudLayouts.new()
	profile = hud.layouts.profile_for(hud.profile_spec)
	_build()


func _build() -> void:
	var specs: Array = [["scale_down", "hudedit_scale_down"], ["scale_up", "hudedit_scale_up"], ["fade", "hudedit_fade"],
		["unfade", "hudedit_unfade"], ["toggle", "hudedit_toggle"], ["option", "hudedit_option"], ["reset_element", "hudedit_reset_element"],
		["save", "keybinds_save"], ["save_new", "talents_new"], ["next", "hudedit_next"], ["delete", "talents_delete"],
		["spec_only", "hudedit_spec_only"], ["export", "talents_export"], ["import", "talents_import"], ["reset_all", "hudedit_reset_all"],
		["done", "talents_done"]]
	for s: Array in specs:
		var b: Button = style.button(style.text(s[1]), Vector2(176, 36), 16)
		b.name = "Edit_%s" % s[0]
		b.pressed.connect(press.bind(s[0]))
		add_child(b)
		buttons[s[0]] = b
	name_edit = _edit("hudedit_name_hint")
	code_edit = _edit("hudedit_code_hint")
	resized.connect(_layout)
	_refresh()


func _edit(hint: String) -> LineEdit:
	var e: LineEdit = LineEdit.new()
	e.placeholder_text = style.text(hint)
	e.add_theme_font_override("font", style.font)
	e.add_theme_font_size_override("font_size", 16)
	e.add_theme_color_override("font_color", style.color("text"))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = style.color("button_bg")
	sb.border_color = style.color("button_border")
	sb.set_border_width_all(2)
	sb.content_margin_left = 10
	e.add_theme_stylebox_override("normal", sb)
	add_child(e)
	return e


## The panel sits in the screen's middle unless the selected element is there; then at the top.
func panel_rect() -> Rect2:
	var r: Rect2 = PANEL
	r.position = (size - r.size) * 0.5
	if selected != "" and hud.group_rect(selected).intersects(r):
		r.position.y = 40.0
	return r


func _layout() -> void:
	var r: Rect2 = panel_rect()
	var order: Array = ["scale_down", "scale_up", "fade", "unfade", "toggle", "option", "reset_element", "",
		"save", "save_new", "next", "delete", "spec_only", "export", "import", "reset_all"]
	for i: int in order.size():
		if order[i] == "":
			continue
		(buttons[order[i]] as Button).position = r.position + Vector2(20.0 + (i % 3) * 190.0, 120.0 + (i / 3) * 44.0)
	# the element row: 7 buttons over the first rows; the profile rows below
	name_edit.position = r.position + Vector2(20, 76)
	name_edit.size = Vector2(366, 34)
	code_edit.position = r.position + Vector2(20, r.size.y - 52)
	code_edit.size = Vector2(366, 34)
	buttons["done"].position = r.position + Vector2(r.size.x - 196.0, r.size.y - 52)
	queue_redraw()


func _refresh() -> void:
	name_edit.text = profile
	var has: bool = selected != ""
	for k: String in ["scale_down", "scale_up", "fade", "unfade", "toggle", "option", "reset_element"]:
		(buttons[k] as Button).disabled = not has
	var e: Dictionary = hud.layout["elements"].get(selected, {})
	(buttons["option"] as Button).text = option_label(e)
	(buttons["toggle"] as Button).text = style.text("hudedit_show" if not bool(e.get("visible", true)) else "hudedit_toggle")
	(buttons["spec_only"] as Button).text = style.text("hudedit_all_specs" if hud.layouts.data["per_spec"].has(hud.profile_spec) else "hudedit_spec_only")
	_layout()


func option_label(e: Dictionary) -> String:
	match str(e.get("type", "")):
		"action_bar":
			return style.text("hudedit_columns", {"n": int(e.get("columns", e.get("buttons", 12)))})
		"unit_frame":
			return style.text("hudedit_auras_" + str(e.get("aura_side", "below")))
	return style.text("hudedit_option")


func element_label(id: String) -> String:
	var t: String = style.text("hud_" + id)
	return t if t != "hud_" + id else Tooltip.sentence(id.replace("_", " "))


## The element (group) id under a point, or "".
func element_at(p: Vector2) -> String:
	var rects: Dictionary = hud.element_rects()
	var best: String = ""
	var best_area: float = INF
	for key: String in rects:
		var r: Rect2 = rects[key]
		if r.has_point(p) and r.get_area() < best_area:
			best = key if hud.layout["elements"].has(key) else key.substr(0, key.rfind("_"))
			best_area = r.get_area()
	return best


func press(what: String) -> void:
	var e: Dictionary = hud.layout["elements"].get(selected, {})
	match what:
		"scale_down", "scale_up":
			var v: float = snappedf(float(e.get("scale", 1.0)) + (0.1 if what == "scale_up" else -0.1), 0.05)
			hud.edit_element(selected, "scale", clampf(v, Hud.SCALE_RANGE.x, Hud.SCALE_RANGE.y))
		"fade", "unfade":
			var o: float = snappedf(float(e.get("opacity", 1.0)) + (0.1 if what == "unfade" else -0.1), 0.05)
			hud.edit_element(selected, "opacity", clampf(o, 0.2, 1.0))
		"toggle":
			hud.edit_element(selected, "visible", not bool(e.get("visible", true)))
		"option":
			if str(e["type"]) == "action_bar":
				var cur: int = COLUMN_CHOICES.find(int(e.get("columns", e.get("buttons", 12))))
				hud.edit_element(selected, "columns", COLUMN_CHOICES[(cur + 1) % COLUMN_CHOICES.size()])
			elif str(e["type"]) == "unit_frame":
				hud.edit_element(selected, "aura_side", "above" if str(e.get("aura_side", "below")) == "below" else "below")
		"reset_element":
			var ch: Dictionary = hud.changes.duplicate(true)
			ch.erase(selected)
			hud.apply_changes(ch)
		"save":
			var n: String = name_edit.text.strip_edges() if name_edit.text.strip_edges() != "" else profile
			if hud.layouts.put(n, hud.changes):
				profile = n
				if hud.layouts.data["per_spec"].has(hud.profile_spec):
					hud.layouts.set_for_spec(hud.profile_spec, n)
				else:
					hud.layouts.set_active(n)
				hud.layouts.save_file()
				message = style.text("hudedit_saved", {"name": n})
			else:
				message = style.text("hudedit_full")
		"save_new":
			var base: String = name_edit.text.strip_edges() if name_edit.text.strip_edges() != "" else "Layout"
			var n: String = base
			var i: int = 2
			while hud.layouts.data["profiles"].has(n):
				n = "%s %d" % [base, i]
				i += 1
			if hud.layouts.put(n, hud.changes):
				profile = n
				hud.layouts.set_active(n)
				hud.layouts.save_file()
				message = style.text("hudedit_saved", {"name": n})
		"next":
			var all: Array = hud.layouts.names()
			profile = all[(all.find(profile) + 1) % all.size()]
			hud.layouts.set_active(profile)
			hud.apply_changes(hud.layouts.changes(profile))
			message = style.text("hudedit_switched", {"name": profile})
		"delete":
			hud.layouts.remove(profile)
			profile = hud.layouts.profile_for(hud.profile_spec)
			hud.apply_changes(hud.layouts.changes(profile))
			hud.layouts.save_file()
		"spec_only":
			if hud.layouts.data["per_spec"].has(hud.profile_spec):
				hud.layouts.set_for_spec(hud.profile_spec, "")
			else:
				hud.layouts.set_for_spec(hud.profile_spec, profile)
			hud.layouts.save_file()
		"export":
			code_edit.text = HudLayouts.export_text(hud.changes)
			DisplayServer.clipboard_set(code_edit.text)
			message = style.text("talents_exported")
		"import":
			var text: String = code_edit.text.strip_edges() if code_edit.text.strip_edges() != "" else DisplayServer.clipboard_get()
			var r: Dictionary = HudLayouts.import_text(text, hud.base_layout)
			if r["error"] != "":
				message = style.text("talents_import_failed", {"why": r["error"]})
			else:
				hud.apply_changes(r["changes"])
				message = style.text("hudedit_imported")
		"reset_all":
			hud.apply_changes({})
		"done":
			finish()
			return
	_refresh()


func finish() -> void:
	finished.emit()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		var at: String = element_at(mb.position)
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and at != "":
				selected = at
				drag = {"id": at, "grab": mb.position - hud.group_rect(at).position}
				_refresh()
			elif not mb.pressed:
				drag = {}
			accept_event()
		elif mb.pressed and at != "" and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			selected = at
			press("scale_up" if mb.button_index == MOUSE_BUTTON_WHEEL_UP else "scale_down")
			accept_event()
	elif event is InputEventMouseMotion and not drag.is_empty():
		var g: Rect2 = hud.group_rect(drag["id"])
		var first_offset: Vector2 = hud.element_rects().get(drag["id"], hud.element_rects().get(drag["id"] + "_1", g)).position - g.position
		hud.move_element(drag["id"], (event as InputEventMouseMotion).position - drag["grab"] + first_offset)
		queue_redraw()


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.25))
	var rects: Dictionary = hud.element_rects()
	for key: String in rects:
		var r: Rect2 = rects[key]
		var id: String = key if hud.layout["elements"].has(key) else key.substr(0, key.rfind("_"))
		var e: Dictionary = hud.layout["elements"][id]
		var col: Color = style.color("accent") if id == selected else Color(style.color("button_border_hover"), 0.8)
		draw_rect(r, Color(col, 0.12))
		if bool(e.get("visible", true)):
			draw_rect(r, col, false, 3.0 if id == selected else 2.0)
			if id == selected:
				draw_rect(r.grow(3.0), Color(col, 0.5), false, 1.0)
		else:
			for side: Array in [[r.position, Vector2(r.end.x, r.position.y)], [Vector2(r.end.x, r.position.y), r.end],
					[r.end, Vector2(r.position.x, r.end.y)], [Vector2(r.position.x, r.end.y), r.position]]:
				draw_dashed_line(side[0], side[1], col, 2.0, 8.0)
		if key == id or key.ends_with("_1"):
			# inside the top left corner on a dark backing: never off screen or over a neighbour
			var label: String = element_label(id)
			var w: float = style.text_width(label, 14) + 10.0
			draw_rect(Rect2(r.position + Vector2(2, 2), Vector2(w, 20)), Color(0, 0, 0, 0.75))
			style.draw_text(self, r.position + Vector2(7, 17), label, 14, col)
	var p: Rect2 = panel_rect()
	style.draw_panel(self, p, Color(style.color("panel_bg"), 0.96))
	style.draw_text(self, p.position + Vector2(20, 34), style.text("hudedit_title").to_upper(), 22, style.color("title"),
		HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	var info: String = style.text("hudedit_none")
	if selected != "":
		var e: Dictionary = hud.layout["elements"][selected]
		info = "%s · %s · %d%% · %d%%" % [element_label(selected), str(e["anchor"]).replace("_", " "),
			roundi(float(e.get("scale", 1.0)) * 100.0), roundi(float(e.get("opacity", 1.0)) * 100.0)]
	style.draw_text(self, p.position + Vector2(20, 62), info, 16, style.color("text"))
	style.draw_text(self, p.position + Vector2(400, 98), style.text("hudedit_profile", {"name": profile}), 15, style.color("subtitle"))
	if message != "":
		style.draw_text(self, p.position + Vector2(20, p.size.y - 64), message, 15, style.color("subtitle"))
