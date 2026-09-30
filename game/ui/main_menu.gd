class_name MainMenu
extends Control
## The client's main menu (backlog M1-28), built from data/menus/<id>.json: title, a spec picker
## (the specs the player can play, as cards with class color, role and playstyle), the buttons
## (Play 2v2 vs bots, Practice, Settings, Quit) and a controls line. It only emits what the
## player chose; the client entry scene routes it (GameFlow).
##
## Original look: a dark iron-and-bronze palette like the HUD, and an emblem drawn from simple
## shapes (a pointed gate arch with a lowered portcullis over two crossed blades).

signal action_chosen(action: String, spec: String)

const BASE: Vector2 = Vector2(1920, 1080)
const CARD_SIZE: Vector2 = Vector2(360, 196)

var style: MenuStyle
var menu: Dictionary
var spec: String = ""  ## the chosen spec
var buttons: Dictionary = {}  ## button id -> Button
var cards: Dictionary = {}  ## spec id -> SpecCard
var settings_panel: Control
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
		var cc: Color = Color.html(str(cls.get("color", "#888888")))
		var r: Rect2 = Rect2(Vector2.ZERO, size)
		draw_rect(Rect2(8, 8, 8, size.y - 16), cc)
		var on: bool = button_pressed
		var title_col: Color = style.color("title") if on else style.color("text")
		style.draw_text(self, Vector2(30, 44), str(s.get("name", spec_id)), 30, title_col)
		style.draw_text(self, Vector2(30, 74), str(cls.get("name", "")), 20, cc.lightened(0.25))
		var role: String = "%s, %s" % [str(s.get("role", "")).capitalize(), str(s.get("range", ""))]
		style.draw_text(self, Vector2(size.x - 16, 74), role, 17, style.color("text_dim"), HORIZONTAL_ALIGNMENT_RIGHT, -1)
		var desc: String = str(s.get("description", ""))
		draw_multiline_string(style.font, Vector2(30, 112), desc, HORIZONTAL_ALIGNMENT_LEFT, size.x - 50, 18, 3,
			style.color("text_dim") if not on else style.color("text"))
		if on:
			draw_rect(r.grow(-3.0), style.color("accent"), false, 3.0)


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
	settings_panel = _make_settings_panel()
	add_child(settings_panel)
	resized.connect(_layout)


func _ready() -> void:
	_layout()
	var first: Button = buttons.values()[0] if not buttons.is_empty() else null
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


## Emit a menu action with the chosen spec (buttons call this; tests too).
func choose(action: String) -> void:
	action_chosen.emit(action, spec)


## The Settings placeholder (the settings suite is M2).
func show_settings() -> void:
	settings_panel.visible = true
	(settings_panel.get_node("Close") as Button).grab_focus()


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
		c.position = Vector2(cx - row_w * 0.5 + i * (CARD_SIZE.x + gap), 356)
		c.size = CARD_SIZE
		i += 1
	var y: float = 606.0
	for b: Button in buttons.values():
		b.size = b.custom_minimum_size
		b.position = Vector2(cx - b.size.x * 0.5, y)
		y += b.size.y + 14.0
	settings_panel.position = Vector2(cx - settings_panel.size.x * 0.5, 330)
	queue_redraw()


func _make_settings_panel() -> Control:
	var p: Control = Control.new()
	p.name = "SettingsPanel"
	p.size = Vector2(760, 330)
	p.visible = false
	p.draw.connect(func() -> void:
		style.draw_panel(p, Rect2(Vector2.ZERO, p.size))
		style.draw_text_in(p, Rect2(0, 20, p.size.x, 50), style.text("settings_title"), 34, style.color("title"))
		var hint_text: String = ""
		for b: Dictionary in menu.get("buttons", []):
			if str(b["action"]) == "settings":
				hint_text = str(b.get("hint", ""))
		p.draw_multiline_string(style.font, Vector2(50, 120), hint_text, HORIZONTAL_ALIGNMENT_CENTER, p.size.x - 100, 22, -1,
			style.color("text")))
	var close: Button = style.button(style.text("close"), Vector2(220, 52), 22)
	close.name = "Close"
	close.position = Vector2(p.size.x * 0.5 - 110, p.size.y - 80)
	close.pressed.connect(func() -> void:
		p.visible = false
		(buttons.get("settings", buttons.values()[0]) as Button).grab_focus())
	p.add_child(close)
	return p


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
	for k: int in 6:
		draw_circle(Vector2(w * 0.5, 190), 520.0 - k * 70.0, Color(0.55, 0.32, 0.14, 0.025))
	_draw_emblem(Vector2(w * 0.5, 190), 1.0)
	style.draw_text(self, Vector2(0, 205), str(menu["title"]), 96, style.color("title"), HORIZONTAL_ALIGNMENT_CENTER, w)
	style.draw_text(self, Vector2(0, 258), str(menu.get("subtitle", "")), 24, style.color("subtitle"), HORIZONTAL_ALIGNMENT_CENTER, w)
	style.draw_text(self, Vector2(0, 336), str(menu["spec_picker"]["label"]).to_upper(), 20, style.color("accent"),
		HORIZONTAL_ALIGNMENT_CENTER, w)
	var line_y: float = 327.0
	draw_line(Vector2(w * 0.5 - 330, line_y), Vector2(w * 0.5 - 150, line_y), Color(style.color("accent"), 0.5), 2.0)
	draw_line(Vector2(w * 0.5 + 150, line_y), Vector2(w * 0.5 + 330, line_y), Color(style.color("accent"), 0.5), 2.0)
	if hint != "":
		style.draw_text(self, Vector2(0, 978), hint, 20, style.color("text_dim"), HORIZONTAL_ALIGNMENT_CENTER, w)
	style.draw_text(self, Vector2(0, h - 26), str(menu.get("controls_hint", "")), 17, Color(style.color("text_dim"), 0.8),
		HORIZONTAL_ALIGNMENT_CENTER, w)


## The emblem: two crossed blades behind a pointed gate arch with a lowered portcullis.
func _draw_emblem(c: Vector2, k: float) -> void:
	var col: Color = Color(style.color("accent"), 0.16)
	var dark: Color = Color(0, 0, 0, 0.35)
	for sgn: float in [-1.0, 1.0]:
		var dir: Vector2 = Vector2(sgn * 0.62, -0.78).normalized()
		var side: Vector2 = Vector2(-dir.y, dir.x)
		var tip: Vector2 = c + dir * 300.0 * k
		var base: Vector2 = c - dir * 230.0 * k
		draw_colored_polygon(PackedVector2Array([base + side * 14.0 * k, tip - dir * 40.0 * k + side * 14.0 * k, tip,
			tip - dir * 40.0 * k - side * 14.0 * k, base - side * 14.0 * k]), col)
		var guard: Vector2 = c - dir * 150.0 * k
		draw_line(guard - side * 55.0 * k, guard + side * 55.0 * k, col, 12.0 * k)
		draw_circle(base - dir * 18.0 * k, 16.0 * k, col)
	# pointed arch
	var arch: PackedVector2Array = []
	var half_w: float = 150.0 * k
	var foot_y: float = c.y + 150.0 * k
	var spring_y: float = c.y - 20.0 * k
	arch.append(Vector2(c.x - half_w, foot_y))
	for i: int in 13:
		var t: float = float(i) / 12.0
		var a: float = lerpf(PI, PI * 1.5 + 0.3, t) if i <= 12 else 0.0
		arch.append(Vector2(c.x + half_w + cos(a) * half_w * 2.0 - half_w * 2.0 + half_w, spring_y + sin(a) * 190.0 * k).lerp(
			Vector2(c.x - half_w + (half_w) * t, spring_y - 190.0 * k * sin(t * PI * 0.5)), 1.0))
	for i: int in 13:
		var t2: float = float(i) / 12.0
		arch.append(Vector2(c.x + half_w * t2, spring_y - 190.0 * k * sin((1.0 - t2) * PI * 0.5)))
	arch.append(Vector2(c.x + half_w, foot_y))
	draw_colored_polygon(arch, dark)
	draw_polyline(arch, col, 6.0 * k)
	# portcullis bars
	for i: int in 5:
		var x: float = c.x - half_w + (i + 1) * half_w * 2.0 / 6.0
		var top_y: float = spring_y - 190.0 * k * sin((1.0 - absf(x - c.x) / half_w) * PI * 0.5) + 8.0
		draw_line(Vector2(x, top_y), Vector2(x, foot_y - 10.0 * k), col, 5.0 * k)
	for j: int in 3:
		var y: float = spring_y + j * 55.0 * k
		draw_line(Vector2(c.x - half_w + 6, y), Vector2(c.x + half_w - 6, y), col, 4.0 * k)
