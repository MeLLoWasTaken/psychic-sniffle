class_name MainMenu
extends Control
## The client's main menu (backlog M1-28), built from data/menus/<id>.json: title, a spec picker
## (the specs the player can play, as cards with class color, role and playstyle), the buttons
## (Play 2v2 vs bots, Practice, Settings, Quit), a hint line for the hovered item and a controls
## line. It only emits what the player chose; the client entry scene (GameFlow) routes it.
## Settings opens a panel with the active settings profile's values and the key bindings
## (the rows and keys are data; editing comes with the M2 settings suite).
##
## Original look: the HUD's dark iron-and-bronze palette and typefaces, and an emblem drawn from
## simple shapes (a pointed gate arch with a lowered portcullis over two crossed blades).
## Positions are logical pixels on the 1920x1080 canvas (canvas_items stretch).

signal action_chosen(action: String, spec: String)

const CARD_SIZE: Vector2 = Vector2(360, 196)
const CARDS_Y: float = 364.0
const BUTTONS_Y: float = 596.0
const BUTTONS_BOTTOM: float = 940.0  ## the hint line sits below this
const ROW_BUTTON_W: float = 330.0  ## width of each button in a shared row

var style: MenuStyle
var menu: Dictionary
var spec: String = ""  ## the chosen spec
var buttons: Dictionary = {}  ## button id -> Button
var cards: Dictionary = {}  ## spec id -> SpecCard
var settings_screen: SettingsScreen  ## open over the menu, or null
var keybind_screen: KeybindScreen  ## open over the menu, or null
var hint: String = ""
var _group: ButtonGroup = ButtonGroup.new()


## A spec choice: class color stripe, spec and class names, role and the spec's description.
class SpecCard:
	extends Button
	var spec_id: String
	var style: MenuStyle

	func _init(p_style: MenuStyle, p_spec: String) -> void:
		style = p_style
		spec_id = p_spec
		toggle_mode = true
		theme = style.theme
		custom_minimum_size = MainMenu.CARD_SIZE
		size = MainMenu.CARD_SIZE
		focus_mode = Control.FOCUS_ALL

	func _draw() -> void:
		var s: Dictionary = Data.specs.get(spec_id, {})
		var cls: Dictionary = Data.classes.get(str(s.get("class", "")), {})
		var cc: Color = HudStyle.class_color(spec_id)
		var on: bool = button_pressed
		draw_rect(Rect2(10, 10, 7, size.y - 20), cc)
		var title_col: Color = style.color("title") if on else style.color("text")
		style.draw_text(self, Vector2(34, 50), str(s.get("name", spec_id)), 32, title_col, HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
		style.draw_text(self, Vector2(34, 80), str(cls.get("name", "")), 20, cc.lerp(Color.WHITE, 0.25))
		var role: String = "%s · %s" % [str(s.get("role", "")).to_upper(), str(s.get("range", "")).capitalize()]
		style.draw_text(self, Vector2(0, 80), role, 17, style.color("text_dim"), HORIZONTAL_ALIGNMENT_RIGHT, size.x - 20)
		draw_line(Vector2(34, 96), Vector2(size.x - 20, 96), Color(style.color("button_border"), 0.5), 1.0)
		draw_multiline_string(style.font, Vector2(34, 126), str(s.get("description", "")), HORIZONTAL_ALIGNMENT_LEFT,
			size.x - 56, 19, 3, style.color("text") if on else style.color("text_dim"))
		if on:
			draw_rect(Rect2(Vector2.ZERO, size).grow(-3.0), style.color("accent"), false, 3.0)


func _init(menu_id: String = "main") -> void:
	style = MenuStyle.new(menu_id)
	menu = style.menu
	name = "MainMenu"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	if menu.is_empty():
		return
	var picker: Dictionary = menu["spec_picker"]
	spec = str(picker["default"])
	for sid: String in picker["specs"]:
		var card: SpecCard = SpecCard.new(style, sid)
		card.name = "Spec_%s" % sid
		card.button_group = _group
		card.button_pressed = sid == spec
		card.pressed.connect(select_spec.bind(sid))
		card.mouse_entered.connect(_set_hint.bind(str(Data.specs.get(sid, {}).get("description", ""))))
		add_child(card)
		cards[sid] = card
	for b: Dictionary in menu["buttons"]:
		var btn: Button = style.button(str(b["label"]))
		btn.name = "Button_%s" % b["id"]
		btn.disabled = not bool(b.get("enabled", true))
		btn.pressed.connect(choose.bind(str(b["action"])))
		btn.mouse_entered.connect(_set_hint.bind(str(b.get("hint", ""))))
		btn.focus_entered.connect(_set_hint.bind(str(b.get("hint", ""))))
		add_child(btn)
		buttons[str(b["id"])] = btn
	resized.connect(_layout)


func _ready() -> void:
	_layout()
	focus_default()


## Put the keyboard focus on the first button (Play), as when the menu first opens.
func focus_default() -> void:
	var first: Button = buttons.get("play_bots", buttons.values()[0] if not buttons.is_empty() else null)  # Play 2v2
	if first:
		first.grab_focus.call_deferred()


## Pick the spec used by Play and Practice.
func select_spec(sid: String) -> void:
	if not cards.has(sid):
		return
	spec = sid
	(cards[sid] as SpecCard).button_pressed = true
	for c: SpecCard in cards.values():
		c.queue_redraw()


## Emit a menu action with the chosen spec (buttons call this).
func choose(action: String) -> void:
	action_chosen.emit(action, spec)


## The settings suite over the menu (M2-13); closing it returns focus to the Settings button.
func show_settings() -> SettingsScreen:
	if settings_screen != null:
		return settings_screen
	settings_screen = SettingsScreen.new()
	settings_screen.closed.connect(func() -> void:
		settings_screen.queue_free()
		settings_screen = null
		if buttons.has("settings"):
			(buttons["settings"] as Button).grab_focus())
	add_child(settings_screen)
	settings_screen.size = size
	return settings_screen


## The keybinding screen over the menu (from the Settings panel).
func show_keybinds() -> KeybindScreen:
	if keybind_screen != null:
		return keybind_screen
	keybind_screen = KeybindScreen.new()
	keybind_screen.closed.connect(func() -> void:
		keybind_screen.queue_free()
		keybind_screen = null)
	add_child(keybind_screen)
	keybind_screen.size = size
	return keybind_screen




func _set_hint(text: String) -> void:
	hint = text
	queue_redraw()


func _layout() -> void:
	var w: float = maxf(size.x, 1.0)
	var cx: float = w * 0.5
	var n: int = cards.size()
	var gap: float = 28.0
	var row_w: float = n * CARD_SIZE.x + (n - 1) * gap
	var i: int = 0
	for c: SpecCard in cards.values():
		c.position = Vector2(cx - row_w * 0.5 + i * (CARD_SIZE.x + gap), CARDS_Y)
		c.size = CARD_SIZE
		i += 1
	# buttons sharing a "row" id sit side by side; the rest stack, all above the hint line
	var rows: Array = []
	var row_of: Dictionary = {}
	for b: Dictionary in menu["buttons"]:
		var key: String = str(b.get("row", ""))
		if key != "" and row_of.has(key):
			(rows[row_of[key]] as Array).append(buttons[str(b["id"])])
		else:
			row_of[key if key != "" else str(b["id"])] = rows.size()
			rows.append([buttons[str(b["id"])]])
	var bgap: float = 10.0 if rows.size() <= 5 else 8.0
	var h: float = minf(58.0, (BUTTONS_BOTTOM - BUTTONS_Y - bgap * (rows.size() - 1)) / maxi(rows.size(), 1))
	var y: float = BUTTONS_Y
	for row: Array in rows:
		var bw: float = (row[0] as Button).custom_minimum_size.x if row.size() == 1 else ROW_BUTTON_W
		var total: float = row.size() * bw + (row.size() - 1) * 16.0
		for k: int in row.size():
			var b: Button = row[k]
			b.custom_minimum_size = Vector2(bw, h)
			b.size = b.custom_minimum_size
			b.position = Vector2(cx - total * 0.5 + k * (bw + 16.0), y)
		y += h + bgap
	queue_redraw()


func _draw() -> void:
	if menu.is_empty():
		return
	var w: float = size.x
	var h: float = size.y
	var top: Color = style.color("background_top")
	var bottom: Color = style.color("background_bottom")
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h), Vector2(0, h)]),
		PackedColorArray([top, top, bottom, bottom]))
	# warm glow behind the title, like torchlight on stone
	for k: int in 7:
		draw_circle(Vector2(w * 0.5, 200), 560.0 - k * 70.0, Color(0.55, 0.32, 0.14, 0.022))
	_draw_emblem(Vector2(w * 0.5, 150), 0.62)
	style.draw_text(self, Vector2(0, 222), str(menu["title"]), 104, style.color("title"), HORIZONTAL_ALIGNMENT_CENTER, w, &"display")
	style.draw_text(self, Vector2(0, 276), str(menu.get("subtitle", "")), 26, style.color("subtitle"), HORIZONTAL_ALIGNMENT_CENTER, w)
	var label: String = str(menu["spec_picker"]["label"]).to_upper()
	style.draw_text(self, Vector2(0, 344), label, 20, style.color("accent"), HORIZONTAL_ALIGNMENT_CENTER, w, &"display")
	var lw: float = style.text_width(label, 20, &"display") * 0.5 + 24.0
	draw_line(Vector2(w * 0.5 - lw - 200, 337), Vector2(w * 0.5 - lw, 337), Color(style.color("accent"), 0.5), 2.0)
	draw_line(Vector2(w * 0.5 + lw, 337), Vector2(w * 0.5 + lw + 200, 337), Color(style.color("accent"), 0.5), 2.0)
	if hint != "":
		style.draw_text(self, Vector2(0, 966), hint, 21, style.color("text_dim"), HORIZONTAL_ALIGNMENT_CENTER, w)
	draw_line(Vector2(w * 0.5 - 520, h - 66), Vector2(w * 0.5 + 520, h - 66), Color(style.color("button_border"), 0.35), 1.0)
	style.draw_text(self, Vector2(0, h - 32), str(menu.get("controls_hint", "")), 18, Color(style.color("text_dim"), 0.9),
		HORIZONTAL_ALIGNMENT_CENTER, w)


## The emblem: two crossed blades behind a pointed gate arch with a lowered portcullis.
func _draw_emblem(at: Vector2, k: float) -> void:
	draw_set_transform(at, 0.0, Vector2(k, k))
	var c: Vector2 = Vector2.ZERO
	var col: Color = Color(style.color("accent"), 0.09)
	var line: Color = Color(style.color("accent"), 0.13)
	for sgn: float in [-1.0, 1.0]:
		var dir: Vector2 = Vector2(sgn * 0.6, -0.8).normalized()
		var side: Vector2 = Vector2(-dir.y, dir.x)
		var tip: Vector2 = c + dir * 250.0
		var base: Vector2 = c - dir * 190.0
		draw_colored_polygon(PackedVector2Array([base + side * 12.0, tip - dir * 36.0 + side * 12.0, tip,
			tip - dir * 36.0 - side * 12.0, base - side * 12.0]), col)
		var guard: Vector2 = c - dir * 120.0
		draw_line(guard - side * 46.0, guard + side * 46.0, col, 11.0)
		draw_circle(base - dir * 14.0, 13.0, col)
	# equilateral pointed arch: two arcs of radius 2*half_w centered on the opposite springing points
	var half_w: float = 110.0
	var spring_y: float = c.y + 10.0
	var foot_y: float = c.y + 130.0
	var arch: PackedVector2Array = [Vector2(c.x - half_w, foot_y)]
	for i: int in 17:
		var a: float = PI + (PI / 3.0) * float(i) / 16.0
		arch.append(Vector2(c.x + half_w, spring_y) + Vector2(cos(a), sin(a)) * half_w * 2.0)
	for i: int in 17:
		var a: float = -PI / 3.0 + (PI / 3.0) * float(i) / 16.0
		arch.append(Vector2(c.x - half_w, spring_y) + Vector2(cos(a), sin(a)) * half_w * 2.0)
	arch.append(Vector2(c.x + half_w, foot_y))
	draw_colored_polygon(arch, Color(0, 0, 0, 0.22))
	draw_polyline(arch, line, 5.0)
	# portcullis: vertical bars clipped to the arch, three cross bars
	for i: int in 5:
		var x: float = c.x - half_w + (i + 1) * half_w * 2.0 / 6.0
		var dx: float = absf(x - c.x)
		var top_y: float = spring_y - sqrt(maxf(4.0 * half_w * half_w - pow(half_w + dx, 2.0), 0.0)) + 6.0
		draw_line(Vector2(x, top_y), Vector2(x, foot_y - 8.0), line, 4.0)
	for j: int in 3:
		var y: float = spring_y - 20.0 + j * 48.0
		draw_line(Vector2(c.x - half_w + 6.0, y), Vector2(c.x + half_w - 6.0, y), line, 3.0)
	draw_set_transform(Vector2.ZERO)
