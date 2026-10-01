class_name Tooltip
extends RefCounted
## A tooltip panel (backlog M2-06): lines of text in roles (title, accent, text, dim, warn), wrapped
## to a width and placed beside the thing it describes, kept on screen. Used by the talent screen,
## the spellbook and the HUD; the colors come from whichever style the caller uses.
##
## A line is [text, pixel size, role].

const WIDTH: float = 420.0
const PAD: float = 16.0
const GAP: float = 6.0


## Lines for an ability: name, facts (cast, cooldown, cost, range), the description, what it does
## with computed numbers, and notes. With the untalented ability (and a text for it), the
## description's numbers become this build's.
static func ability_lines(text: AbilityText, ab: Dictionary, untalented: Dictionary = {}, base_text: AbilityText = null) -> Array:
	var lines: Array = [[str(ab.get("name", "")), 24, "title"], [" · ".join(text.meta(ab)), 17, "accent"]]
	if str(ab.get("description", "")) != "":
		var desc: String = text.description_for(ab, untalented, base_text) if base_text != null else str(ab["description"])
		lines.append([desc, 18, "text"])
	for l: String in text.effects(ab)["lines"]:
		lines.append(["• " + l, 17, "dim"])
	var tags: PackedStringArray = text.tags(ab)
	if not tags.is_empty():
		lines.append([sentence(", ".join(tags)), 16, "accent"])
	return lines


## Lines for an aura on a unit: name, what it does, time left.
static func aura_lines(text: AbilityText, aura_id: String, seconds_left: float = -1.0, stacks: int = 1) -> Array:
	var a: Dictionary = text.auras.get(aura_id, {})
	if a.is_empty():
		return [[aura_id, 22, "title"]]
	var head: String = str(a["name"]) + (" ×%d" % stacks if stacks > 1 else "")
	var lines: Array = [[head, 22, "title" if a["kind"] == "buff" else "warn"]]
	if str(a.get("description", "")) != "":
		lines.append([str(a["description"]), 18, "text"])
	var bits: PackedStringArray = text.aura_bits(a)
	if not bits.is_empty():
		lines.append([sentence("; ".join(bits)), 17, "dim"])
	if seconds_left >= 0.0:
		lines.append([("%s left" % AbilityText.secs(snappedf(seconds_left, 0.1))), 16, "accent"])
	return lines


## Text cut to a width with an ellipsis.
static func elide(font: Font, s: String, width: float, px: int) -> String:
	if font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x <= width:
		return s
	var lo: int = 0
	var hi: int = s.length()
	while lo < hi:
		var mid: int = (lo + hi + 1) / 2
		if font.get_string_size(s.substr(0, mid) + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, px).x <= width:
			lo = mid
		else:
			hi = mid - 1
	return s.substr(0, lo).strip_edges() + "…"


## First letter upper case, the rest as written.
static func sentence(s: String) -> String:
	return s.substr(0, 1).to_upper() + s.substr(1) if s != "" else s


static func height(font: Font, lines: Array, width: float = WIDTH) -> float:
	var h: float = PAD * 2.0
	for l: Array in lines:
		h += font.get_multiline_string_size(str(l[0]), HORIZONTAL_ALIGNMENT_LEFT, width - PAD * 2.0, int(l[1])).y + GAP
	return h - GAP


## Draw beside `near` (right of it, else left; above it when `above`), inside `bounds`.
static func draw(ci: CanvasItem, font: Font, colors: Dictionary, near: Rect2, lines: Array, bounds: Vector2,
		width: float = WIDTH, above: bool = false) -> Rect2:
	var h: float = height(font, lines, width)
	var pos: Vector2
	if above:
		pos = Vector2(near.get_center().x - width * 0.5, near.position.y - 12.0 - h)
	else:
		pos = Vector2(near.end.x + 16.0, near.position.y)
		if pos.x + width > bounds.x - 16.0:
			pos.x = near.position.x - 16.0 - width
	pos.x = clampf(pos.x, 16.0, bounds.x - width - 16.0)
	pos.y = clampf(pos.y, 16.0, bounds.y - h - 16.0)
	var box: Rect2 = Rect2(pos, Vector2(width, h))
	ci.draw_rect(box, colors.get("bg", Color(0.06, 0.05, 0.04, 0.97)))
	ci.draw_rect(box.grow(2.0), Color(0, 0, 0, 0.95), false, 3.0)
	ci.draw_rect(box.grow(-2.0), colors.get("border", Color(0.48, 0.39, 0.26)), false, 2.0)
	var y: float = box.position.y + PAD
	for l: Array in lines:
		var px: int = int(l[1])
		var col: Color = colors.get(str(l[2]), Color.WHITE)
		ci.draw_multiline_string(font, Vector2(box.position.x + PAD, y + font.get_ascent(px)), str(l[0]),
			HORIZONTAL_ALIGNMENT_LEFT, width - PAD * 2.0, px, -1, col)
		y += font.get_multiline_string_size(str(l[0]), HORIZONTAL_ALIGNMENT_LEFT, width - PAD * 2.0, px).y + GAP
	return box


## Tooltip colors from a menu style.
static func menu_colors(style: MenuStyle) -> Dictionary:
	return {"title": style.color("title"), "accent": style.color("accent"), "text": style.color("text"),
		"dim": style.color("text_dim"), "warn": style.color("defeat"), "bg": Color(style.color("panel_bg"), 0.98),
		"border": style.color("button_border")}
