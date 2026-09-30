class_name HudStyle
extends RefCounted
## Look of the HUD (backlog M1-27), read from a HUD layout's "style", "crowd_control",
## "icon_glyphs" and "key_label_abbreviations" (data/hud_layouts/<id>.json), plus the drawing
## helpers every HUD element shares: outlined text, iron-framed panels, bars, cooldown sweeps and
## the placeholder icons.
##
## Icons are original placeholders drawn from data, no image files: the ability's school color
## (effect palette) as a painted gradient, a glyph picked from the icon symbol by the layout's
## rules (crystal, blade, shield...), and the ability's initials. M3's Blender icon generator
## replaces them; the icon data (symbol, school) stays the same.

const GLYPHS: Array[String] = ["crystal", "shield", "drop", "wing", "chain", "rays", "fist", "wave", "arrow",
	"heart", "pillar", "rune", "blade", "orb", "star", "diamond", "spiral", "cross", "slash", "bars"]
const OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.92)

var layout: Dictionary
var font: Font
var colors: Dictionary = {}  ## style key -> Color
var resource_colors: Dictionary = {}  ## resource -> Color
var font_px: Dictionary = {}  ## size name -> logical pixels
var cc: Dictionary = {}  ## CC category -> {label, short, glyph, color: Color, priority}
var abbreviations: Array = []
var _glyph_rules: Array = []  ## [RegEx, glyph]


func _init(p_layout: Dictionary) -> void:
	layout = p_layout
	font = ThemeDB.fallback_font
	var style: Dictionary = layout.get("style", {})
	for key: String in style:
		if style[key] is String:
			colors[key] = Color.html(style[key])
	for res: String in style.get("resource_colors", {}):
		resource_colors[res] = Color.html(style["resource_colors"][res])
	font_px = style.get("font_px", {})
	for cat: String in layout.get("crowd_control", {}):
		var c: Dictionary = (layout["crowd_control"][cat] as Dictionary).duplicate()
		c["color"] = Color.html(str(c["color"]))
		cc[cat] = c
	abbreviations = layout.get("key_label_abbreviations", [])
	for rule: Dictionary in layout.get("icon_glyphs", []):
		var re: RegEx = RegEx.new()
		if re.compile(str(rule["match"])) == OK:
			_glyph_rules.append([re, str(rule["glyph"])])


## A style color by key ("text", "frame_bg"...); magenta when the layout lacks it.
func color(key: String) -> Color:
	return colors.get(key, Color.MAGENTA)


## Font size in logical pixels for a size name ("small", "normal", "timer"...).
func fs(size_name: String) -> int:
	return int(font_px.get(size_name, 16))


## The smallest font size the layout uses (for the min_text_px floor).
func smallest_font() -> float:
	var m: float = INF
	for k: String in font_px:
		m = minf(m, float(font_px[k]))
	return m if m != INF else 14.0


## A keybind label shortened for a button ("Shift+1" -> "S1").
func short_key(label: String) -> String:
	for pair: Array in abbreviations:
		label = label.replace(str(pair[0]), str(pair[1]))
	return label


## The glyph for an icon symbol: the first matching rule, else one picked by hash.
func glyph_for(symbol: String) -> String:
	for rule: Array in _glyph_rules:
		if (rule[0] as RegEx).search(symbol) != null:
			return rule[1]
	return GLYPHS[absi(hash(symbol)) % 13]  # the object glyphs, not the CC shapes


## Initials of a display name ("Pommel Crack" -> "PC", "Hush" -> "Hu").
static func initials(name: String) -> String:
	var words: PackedStringArray = name.replace("'", "").split(" ", false)
	if words.is_empty():
		return "?"
	if words.size() == 1:
		return words[0].substr(0, 2)
	return (words[0].substr(0, 1) + words[1].substr(0, 1)).to_upper()


static func school_color(school: String) -> Color:
	var c: Color = EffectsData.colors(school)["primary"]
	c.a = 1.0
	return c


## Class color of a spec (data/classes color), gray when unknown.
static func class_color(spec_id: String) -> Color:
	var spec: Dictionary = Data.specs.get(spec_id, {})
	var cls: Dictionary = Data.classes.get(str(spec.get("class", "")), {})
	return Color.html(str(cls.get("color", "#888888")))


## "Warblade · Carnage" style label of a spec.
static func spec_label(spec_id: String) -> String:
	var spec: Dictionary = Data.specs.get(spec_id, {})
	var cls: Dictionary = Data.classes.get(str(spec.get("class", "")), {})
	if spec.is_empty():
		return spec_id
	return "%s %s" % [str(spec.get("name", spec_id)), str(cls.get("name", ""))]


## Seconds as a compact countdown for small boxes (auras, Break Free): "2m" from a minute.
static func countdown_short(seconds: float) -> String:
	return "%dm" % ceili(seconds / 60.0) if seconds >= 60.0 else countdown(seconds)


## Seconds as a short countdown: "1:30" from a minute, "12", then "2.4" under 3 s.
static func countdown(seconds: float, decimals_below: float = 3.0) -> String:
	if seconds >= 60.0:
		var s: int = ceili(seconds)
		return "%d:%02d" % [s / 60, s % 60]
	if seconds < decimals_below:
		return "%.1f" % maxf(seconds, 0.0)
	return "%d" % ceili(seconds)


# ------------------------------------------------------------------ drawing helpers

## Text with a dark outline. `pos` is the left end of the baseline (or the box's left edge when
## `width` > 0 with an alignment).
func text(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, outline: int = -1) -> void:
	var o: int = outline if outline >= 0 else maxi(2, size / 6)
	var oc: Color = OUTLINE
	oc.a *= col.a
	ci.draw_string_outline(font, pos, s, align, width, size, o, oc)
	ci.draw_string(font, pos, s, align, width, size, col)


## Text centered in a box, vertically by the font's ascent and descent.
func text_in(ci: CanvasItem, box: Rect2, s: String, size: int, col: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER, pad: float = 0.0) -> void:
	var baseline: float = box.position.y + (box.size.y + font.get_ascent(size) - font.get_descent(size)) * 0.5
	text(ci, Vector2(box.position.x + pad, baseline), s, size, col, align, box.size.x - pad * 2.0)


func text_width(s: String, size: int) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## A dark iron-framed panel: black outer line, bronze inner line.
func panel(ci: CanvasItem, r: Rect2, bg: Color = Color(), border: Color = Color()) -> void:
	ci.draw_rect(r, bg if bg != Color() else color("frame_bg"))
	ci.draw_rect(r.grow(1.0), color("frame_border_dark"), false, 2.0)
	ci.draw_rect(r.grow(-1.0), border if border != Color() else color("frame_border"), false, 1.0)


## A horizontal bar filled `frac` from the left (or from the right when `reverse`).
func bar(ci: CanvasItem, r: Rect2, frac: float, fill: Color, bg: Color = Color(), reverse: bool = false) -> void:
	ci.draw_rect(r, bg if bg != Color() else color("bar_bg"))
	var w: float = r.size.x * clampf(frac, 0.0, 1.0)
	if w > 0.0:
		var fr: Rect2 = Rect2(r.position + Vector2(r.size.x - w if reverse else 0.0, 0.0), Vector2(w, r.size.y))
		ci.draw_rect(fr, fill)
		# painted look: lighter top third, darker bottom edge
		ci.draw_rect(Rect2(fr.position, Vector2(fr.size.x, fr.size.y * 0.35)), Color(1, 1, 1, 0.12))
		ci.draw_rect(Rect2(fr.position + Vector2(0, fr.size.y * 0.8), Vector2(fr.size.x, fr.size.y * 0.2)), Color(0, 0, 0, 0.22))
	ci.draw_rect(r, color("frame_border_dark"), false, 1.0)


## A clockwise cooldown sweep over a square: darkens the part of the square from `elapsed`
## (0..1 of a turn, starting at 12 o'clock) to the full turn, so the bright part grows clockwise.
static func sweep(ci: CanvasItem, r: Rect2, elapsed: float, col: Color) -> void:
	elapsed = clampf(elapsed, 0.0, 1.0)
	if elapsed >= 1.0:
		return
	var c: Vector2 = r.get_center()
	var half: Vector2 = r.size * 0.5
	var pts: PackedVector2Array = [c]
	var a0: float = elapsed * TAU
	var steps: int = maxi(2, ceili((TAU - a0) / (TAU / 48.0)))
	for i: int in steps + 1:
		var a: float = lerpf(a0, TAU, float(i) / steps)
		var d: Vector2 = Vector2(sin(a), -cos(a))
		var k: float = minf(half.x / maxf(absf(d.x), 1e-6), half.y / maxf(absf(d.y), 1e-6))
		pts.append(c + d * k)
	ci.draw_colored_polygon(pts, col)


## A square icon: school gradient, glyph, initials, bevel. `dim` darkens (unusable), `tint`
## multiplies (out of range, no resource).
func icon(ci: CanvasItem, r: Rect2, icon_data: Dictionary, name: String, tint: Color = Color.WHITE,
		show_initials: bool = true) -> void:
	var school: String = str(icon_data.get("school", "physical"))
	var base: Color = colors["icon_physical"] if school == "physical" and colors.has("icon_physical") else school_color(school)
	# a small per-symbol shift in value, so icons of one school do not all look the same
	var shade: int = absi(hash(str(icon_data.get("symbol", name)))) % 5 - 2
	base = base.lightened(shade * 0.06) if shade > 0 else base.darkened(-shade * 0.06)
	var top: Color = base.lerp(Color.WHITE, 0.1).darkened(0.12) * tint
	var bottom: Color = base.darkened(0.68) * tint
	top.a = 1.0
	bottom.a = 1.0
	var p: Vector2 = r.position
	var s: Vector2 = r.size
	ci.draw_polygon(PackedVector2Array([p, p + Vector2(s.x, 0), p + s, p + Vector2(0, s.y)]),
		PackedColorArray([top, top.darkened(0.2), bottom, bottom.lightened(0.05)]))
	# soft light from the top left, like the painted textures
	ci.draw_circle(p + s * Vector2(0.3, 0.28), s.x * 0.34, Color(1, 1, 1, 0.07 * tint.v))
	var glyph_col: Color = Color(1.0, 0.97, 0.9).lerp(base.lightened(0.6), 0.35) * tint
	glyph_col.a = 1.0
	draw_glyph(ci, glyph_for(str(icon_data.get("symbol", name))), r.grow(-s.x * 0.18), glyph_col)
	if show_initials and s.x >= 30.0:
		var fsz: int = maxi(fs("small"), int(s.x * 0.24))
		text(ci, p + Vector2(s.x * 0.08, s.y - s.y * 0.08), initials(name), fsz, Color(1, 1, 1, 0.9) * tint,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 3)
	ci.draw_rect(r, Color(0, 0, 0, 0.9), false, 2.0)
	ci.draw_rect(r.grow(-2.0), Color(1, 1, 1, 0.1), false, 1.0)


## A CC glyph icon (loss of control, portraits, DR tracker): CC color, category shape, and the
## short label when `labeled` so it never reads by color alone.
func cc_icon(ci: CanvasItem, r: Rect2, category: String, labeled: bool = true) -> void:
	var c: Dictionary = cc.get(category, {"color": Color.WHITE, "glyph": "orb", "short": category.to_upper()})
	var col: Color = c["color"]
	ci.draw_rect(r, Color(0.05, 0.04, 0.03, 0.95))
	ci.draw_rect(r.grow(-2.0), col.darkened(0.55))
	var g: Rect2 = r.grow(-r.size.x * 0.2)
	if labeled:
		g = Rect2(r.position + Vector2(r.size.x * 0.22, r.size.y * 0.1), Vector2(r.size.x * 0.56, r.size.y * 0.56))
	draw_glyph(ci, str(c["glyph"]), g, col.lightened(0.35))
	if labeled:
		var fsz: int = maxi(fs("small"), int(r.size.y * 0.2))
		text_in(ci, Rect2(r.position + Vector2(0, r.size.y * 0.66), Vector2(r.size.x, r.size.y * 0.32)),
			str(c["short"]), fsz, Color.WHITE)
	ci.draw_rect(r, col, false, 2.0)


## Draw one glyph shape inside `r` in `col` with a dark outline.
static func draw_glyph(ci: CanvasItem, glyph: String, r: Rect2, col: Color) -> void:
	var w: float = r.size.x
	var lw: float = maxf(2.0, w * 0.1)
	var dark: Color = Color(0, 0, 0, 0.75)
	var pt: Callable = func(x: float, y: float) -> Vector2: return r.position + r.size * Vector2(x, y)
	match glyph:
		"crystal":
			_poly(ci, [pt.call(0.5, 0.0), pt.call(0.7, 0.45), pt.call(0.5, 1.0), pt.call(0.3, 0.45)], col, dark)
			_poly(ci, [pt.call(0.18, 0.35), pt.call(0.3, 0.6), pt.call(0.2, 0.85), pt.call(0.08, 0.6)], col.darkened(0.15), dark)
			_poly(ci, [pt.call(0.82, 0.35), pt.call(0.92, 0.6), pt.call(0.8, 0.85), pt.call(0.7, 0.6)], col.darkened(0.15), dark)
		"shield":
			_poly(ci, [pt.call(0.15, 0.08), pt.call(0.85, 0.08), pt.call(0.85, 0.5), pt.call(0.5, 0.95), pt.call(0.15, 0.5)], col, dark)
			ci.draw_line(pt.call(0.5, 0.16), pt.call(0.5, 0.82), dark, lw * 0.6)
		"drop":
			var pts: Array = [pt.call(0.5, 0.02)]
			for i: int in 13:
				var a: float = PI * (-0.15 + 1.3 * i / 12.0)
				pts.append(r.position + r.size * Vector2(0.5 + 0.32 * cos(a), 0.64 + 0.32 * sin(a)))
			_poly(ci, pts, col, dark)
		"wing":
			for i: int in 4:
				var y: float = 0.15 + i * 0.18
				_poly(ci, [pt.call(0.1, 0.9 - i * 0.05), pt.call(0.9 - i * 0.12, y), pt.call(0.95 - i * 0.12, y + 0.1),
					pt.call(0.25, 0.95 - i * 0.03)], col.darkened(i * 0.08), dark)
		"chain":
			for c: Vector2 in [Vector2(0.35, 0.4), Vector2(0.65, 0.6)]:
				ci.draw_arc(r.position + r.size * c, w * 0.22, 0.0, TAU, 20, dark, lw * 1.6)
				ci.draw_arc(r.position + r.size * c, w * 0.22, 0.0, TAU, 20, col, lw)
		"rays":
			for i: int in 8:
				var a: float = TAU * i / 8.0
				var d: Vector2 = Vector2(cos(a), sin(a))
				ci.draw_line(r.get_center() + d * w * 0.3, r.get_center() + d * w * 0.5, dark, lw * 1.5)
				ci.draw_line(r.get_center() + d * w * 0.3, r.get_center() + d * w * 0.5, col, lw)
			ci.draw_circle(r.get_center(), w * 0.24, dark)
			ci.draw_circle(r.get_center(), w * 0.2, col)
		"fist":
			_poly(ci, [pt.call(0.2, 0.35), pt.call(0.8, 0.35), pt.call(0.8, 0.8), pt.call(0.6, 0.95), pt.call(0.2, 0.9)], col, dark)
			for i: int in 4:
				ci.draw_circle(pt.call(0.27 + i * 0.155, 0.3), w * 0.09, col.darkened(0.1))
		"wave":
			for i: int in 3:
				var rad: float = w * (0.2 + i * 0.15)
				ci.draw_arc(pt.call(0.15, 0.5), rad, -0.9, 0.9, 12, dark, lw * 1.5)
				ci.draw_arc(pt.call(0.15, 0.5), rad, -0.9, 0.9, 12, col, lw)
		"arrow":
			_poly(ci, [pt.call(0.05, 0.38), pt.call(0.55, 0.38), pt.call(0.55, 0.15), pt.call(0.95, 0.5),
				pt.call(0.55, 0.85), pt.call(0.55, 0.62), pt.call(0.05, 0.62)], col, dark)
		"heart":
			var hp: Array = []
			for i: int in 25:
				var t: float = TAU * i / 24.0
				var x: float = 16.0 * pow(sin(t), 3)
				var y: float = 13.0 * cos(t) - 5.0 * cos(2 * t) - 2.0 * cos(3 * t) - cos(4 * t)
				hp.append(r.position + r.size * Vector2(0.5 + x / 36.0, 0.45 - y / 36.0))
			_poly(ci, hp, col, dark)
		"pillar":
			_poly(ci, [pt.call(0.3, 0.2), pt.call(0.7, 0.2), pt.call(0.7, 0.85), pt.call(0.3, 0.85)], col, dark)
			_poly(ci, [pt.call(0.18, 0.05), pt.call(0.82, 0.05), pt.call(0.82, 0.2), pt.call(0.18, 0.2)], col.lightened(0.1), dark)
			_poly(ci, [pt.call(0.18, 0.85), pt.call(0.82, 0.85), pt.call(0.82, 0.97), pt.call(0.18, 0.97)], col.lightened(0.1), dark)
		"rune":
			for seg: Array in [[0.5, 0.05, 0.5, 0.95], [0.5, 0.3, 0.8, 0.1], [0.5, 0.3, 0.2, 0.1], [0.5, 0.6, 0.8, 0.8], [0.5, 0.6, 0.2, 0.8]]:
				ci.draw_line(pt.call(seg[0], seg[1]), pt.call(seg[2], seg[3]), dark, lw * 1.7)
			for seg: Array in [[0.5, 0.05, 0.5, 0.95], [0.5, 0.3, 0.8, 0.1], [0.5, 0.3, 0.2, 0.1], [0.5, 0.6, 0.8, 0.8], [0.5, 0.6, 0.2, 0.8]]:
				ci.draw_line(pt.call(seg[0], seg[1]), pt.call(seg[2], seg[3]), col, lw)
		"blade":
			_poly(ci, [pt.call(0.92, 0.02), pt.call(0.98, 0.08), pt.call(0.4, 0.66), pt.call(0.3, 0.56)], col, dark)
			_poly(ci, [pt.call(0.18, 0.5), pt.call(0.24, 0.44), pt.call(0.52, 0.72), pt.call(0.46, 0.78)], col.darkened(0.25), dark)
			_poly(ci, [pt.call(0.3, 0.64), pt.call(0.36, 0.7), pt.call(0.1, 0.96), pt.call(0.04, 0.9)], col.darkened(0.35), dark)
		"orb":
			ci.draw_circle(r.get_center(), w * 0.42, dark)
			ci.draw_circle(r.get_center(), w * 0.38, col)
			ci.draw_circle(r.get_center() - Vector2(w, w) * 0.12, w * 0.1, Color(1, 1, 1, 0.6))
		"star":
			var sp: Array = []
			for i: int in 10:
				var a: float = -PI / 2 + PI * i / 5.0
				var rad: float = 0.5 if i % 2 == 0 else 0.21
				sp.append(r.get_center() + Vector2(cos(a), sin(a)) * w * rad)
			_poly(ci, sp, col, dark)
		"diamond":
			_poly(ci, [pt.call(0.5, 0.02), pt.call(0.95, 0.5), pt.call(0.5, 0.98), pt.call(0.05, 0.5)], col, dark)
			_poly(ci, [pt.call(0.5, 0.3), pt.call(0.7, 0.5), pt.call(0.5, 0.7), pt.call(0.3, 0.5)], dark, dark)
		"spiral":
			var prev: Vector2 = r.get_center()
			for i: int in 40:
				var t: float = i / 39.0
				var a: float = t * TAU * 2.2
				var q: Vector2 = r.get_center() + Vector2(cos(a), sin(a)) * w * 0.48 * t
				ci.draw_line(prev, q, dark, lw * 1.6)
				prev = q
			prev = r.get_center()
			for i: int in 40:
				var t: float = i / 39.0
				var a: float = t * TAU * 2.2
				var q: Vector2 = r.get_center() + Vector2(cos(a), sin(a)) * w * 0.48 * t
				ci.draw_line(prev, q, col, lw)
				prev = q
		"cross":
			for seg: Array in [[0.12, 0.12, 0.88, 0.88], [0.88, 0.12, 0.12, 0.88]]:
				ci.draw_line(pt.call(seg[0], seg[1]), pt.call(seg[2], seg[3]), dark, lw * 2.4)
			for seg: Array in [[0.12, 0.12, 0.88, 0.88], [0.88, 0.12, 0.12, 0.88]]:
				ci.draw_line(pt.call(seg[0], seg[1]), pt.call(seg[2], seg[3]), col, lw * 1.5)
		"slash":
			_poly(ci, [pt.call(0.8, 0.02), pt.call(0.98, 0.1), pt.call(0.2, 0.98), pt.call(0.02, 0.9)], col, dark)
		"bars":
			for i: int in 4:
				var x: float = 0.14 + i * 0.24
				_poly(ci, [pt.call(x, 0.05), pt.call(x + 0.1, 0.05), pt.call(x + 0.1, 0.95), pt.call(x, 0.95)], col, dark)
			ci.draw_line(pt.call(0.05, 0.3), pt.call(0.95, 0.3), col.darkened(0.2), lw)
		_:
			ci.draw_circle(r.get_center(), w * 0.4, col)


static func _poly(ci: CanvasItem, pts: Array, col: Color, outline: Color) -> void:
	var packed: PackedVector2Array = PackedVector2Array(pts)
	if Geometry2D.triangulate_polygon(packed).is_empty():
		return
	ci.draw_colored_polygon(packed, col)
	var closed: PackedVector2Array = packed.duplicate()
	closed.append(packed[0])
	ci.draw_polyline(closed, outline, 1.5)
