class_name MenuStyle
extends RefCounted
## Look and text of the menus and match flow screens (backlog M1-28), from a menu data file
## (data/menus/<id>.json): colors, the two typefaces (the HUD's: a display face for titles and
## big numbers, a text face for everything else, named in the data's "fonts"), the button theme
## (dark iron panels with bronze borders, like the HUD), outlined text and framed panels. Text is
## looked up by key with {placeholders}.

const OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.9)

var menu: Dictionary = {}
var colors: Dictionary = {}
var font: Font  ## the text face (buttons, body text, numbers)
var display_font: Font  ## the display face (titles, banners, outcome)
var theme: Theme


func _init(menu_id: String = "main") -> void:
	menu = Data.menus.get(menu_id, {})
	if menu.is_empty():
		Log.error("menu: no menu data '%s'" % menu_id)
	var fonts: Dictionary = menu.get("fonts", {})
	font = HudStyle.load_font(fonts.get("text", {}))
	display_font = HudStyle.load_font(fonts.get("display", {}))
	var style: Dictionary = menu.get("style", {})
	for k: String in style:
		colors[k] = Color.html(str(style[k]))
	theme = _make_theme()


## A style color by key; magenta when missing (easy to spot in a screenshot).
func color(key: String) -> Color:
	return colors.get(key, Color.MAGENTA)


## Text by key with {name} placeholders filled from `subs`; the key itself when missing.
func text(key: String, subs: Dictionary = {}) -> String:
	var s: String = str(menu.get("text", {}).get(key, key))
	for k: String in subs:
		s = s.replace("{%s}" % k, str(subs[k]))
	return s


## The font of a face name: "display" or "text".
func face(face_name: StringName) -> Font:
	return display_font if face_name == &"display" else font


## The button theme: framed dark panels, bronze border brightening on hover and focus.
func _make_theme() -> Theme:
	var t: Theme = Theme.new()
	t.default_font = font
	var states: Dictionary = {"normal": ["button_bg", "button_border"], "hover": ["button_hover", "button_border_hover"],
		"pressed": ["button_pressed", "button_border_hover"], "disabled": ["button_disabled", "button_border"],
		"focus": ["button_hover", "button_border_hover"]}
	for st: String in states:
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = color(states[st][0])
		sb.border_color = color(states[st][1])
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(2)
		sb.content_margin_left = 18
		sb.content_margin_right = 18
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		sb.shadow_color = Color(0, 0, 0, 0.5)
		sb.shadow_size = 4
		if st == "focus":
			sb.bg_color = Color(0, 0, 0, 0)
			sb.draw_center = false
			sb.shadow_size = 0
		t.set_stylebox(st, "Button", sb)
	t.set_font("font", "Button", font)
	t.set_color("font_color", "Button", color("text"))
	t.set_color("font_hover_color", "Button", color("title"))
	t.set_color("font_pressed_color", "Button", color("title"))
	t.set_color("font_focus_color", "Button", color("title"))
	t.set_color("font_hover_pressed_color", "Button", color("title"))
	t.set_color("font_disabled_color", "Button", color("text_dim").darkened(0.3))
	t.set_color("font_outline_color", "Button", OUTLINE)
	t.set_constant("outline_size", "Button", 4)
	t.set_font_size("font_size", "Button", 26)
	return t


## A menu button with this style.
func button(label: String, min_size: Vector2 = Vector2(420, 58), font_px: int = 26) -> Button:
	var b: Button = Button.new()
	b.text = label
	b.theme = theme
	b.custom_minimum_size = min_size
	b.size = min_size
	b.add_theme_font_size_override("font_size", font_px)
	return b


## Text with a dark outline; `pos` is the left end of the baseline (or of the box with `width`).
func draw_text(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0,
		face_name: StringName = &"text") -> void:
	var f: Font = face(face_name)
	var o: int = maxi(3, size / 7)
	var oc: Color = OUTLINE
	oc.a *= col.a
	ci.draw_string_outline(f, pos, s, align, width, size, o, oc)
	ci.draw_string(f, pos, s, align, width, size, col)


## Text centered in a box (vertically by ascent and descent).
func draw_text_in(ci: CanvasItem, box: Rect2, s: String, size: int, col: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER, face_name: StringName = &"text") -> void:
	var f: Font = face(face_name)
	var baseline: float = box.position.y + (box.size.y + f.get_ascent(size) - f.get_descent(size)) * 0.5
	draw_text(ci, Vector2(box.position.x, baseline), s, size, col, align, box.size.x, face_name)


## Width of a string in a face at a size.
func text_width(s: String, size: int, face_name: StringName = &"text") -> float:
	return face(face_name).get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## A framed panel: dark fill, black outer line, bronze inner line and small corner studs.
func draw_panel(ci: CanvasItem, r: Rect2, fill: Color = Color(), border: Color = Color()) -> void:
	ci.draw_rect(r, fill if fill != Color() else color("panel_bg"))
	ci.draw_rect(r.grow(2.0), Color(0, 0, 0, 0.95), false, 3.0)
	var b: Color = border if border != Color() else color("button_border")
	ci.draw_rect(r.grow(-2.0), b, false, 2.0)
	ci.draw_rect(r.grow(-7.0), Color(b, 0.35), false, 1.0)
	for corner: Vector2 in [r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y)]:
		ci.draw_circle(corner + (r.get_center() - corner).sign() * 8.0, 3.0, b.lightened(0.2))


## A thin bronze rule with a diamond in the middle (titles and section breaks).
func draw_rule(ci: CanvasItem, center: Vector2, half_width: float, col: Color = Color()) -> void:
	var c: Color = col if col != Color() else Color(color("accent"), 0.6)
	ci.draw_line(center - Vector2(half_width, 0), center - Vector2(12, 0), c, 2.0)
	ci.draw_line(center + Vector2(12, 0), center + Vector2(half_width, 0), c, 2.0)
	ci.draw_colored_polygon(PackedVector2Array([center + Vector2(0, -6), center + Vector2(7, 0), center + Vector2(0, 6),
		center + Vector2(-7, 0)]), c)


## Seconds as m:ss.
static func clock(seconds: float) -> String:
	var s: int = maxi(0, floori(seconds))
	return "%d:%02d" % [s / 60, s % 60]


## Seconds as m:ss rounded up (countdowns: "0:01" until the last second has passed).
static func countdown(seconds: float) -> String:
	var s: int = maxi(0, ceili(seconds - 1e-6))
	return "%d:%02d" % [s / 60, s % 60]
