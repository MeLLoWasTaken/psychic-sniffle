class_name UnitFrame
extends Control
## A unit frame (backlog M1-27): portrait, name and spec, health (class color, with absorbs),
## resource, optional cast bar, and the unit's auras with seconds left, crowd control first and
## larger. While the unit is crowd-controlled the portrait becomes a big CC icon (category glyph,
## short label, seconds), so a controlled ally or enemy reads at a glance and never by color
## alone. Arena frames add a Break Free cooldown box and a diminishing-returns tracker.
## A click on the frame emits clicked with the unit's id (select it as target); the pointer over
## it emits hovered, so a mouseover cast can land on a frame as well as on the unit in the world.

signal clicked(unit_id: int)
## The pointer entered (the unit's id) or left (-1) the frame: mouseover casts use it (M2-14).
signal hovered(unit_id: int)

var style: HudStyle
var element: Dictionary
var unit: Dictionary = {}
var view: Dictionary = {}
var prefix: String = ""  ## "1", "2" on arena frames
var hostile: bool = false
var selected: bool = false  ## the player's current target
var failure: Dictionary = {}  ## cast bar failure {text, until_s}
var clock: float = 0.0
var break_free: Dictionary = {}  ## {ready_tick, total_ticks} for the arena frame box
var aura_px: float = 26.0
var aura_scale: float = 1.0  ## settings: buff and debuff size (M2-13)
var drawn_auras: Array = []  ## the auras drawn last, in order (for tests): {id, size_px, cc}
var portrait_glyph: bool = false  ## the last portrait drew the spec's glyph (not initials)


func setup(p_style: HudStyle, p_element: Dictionary) -> void:
	style = p_style
	element = p_element
	var sz: Array = element.get("size", [260, 64])
	size = Vector2(float(sz[0]), float(sz[1]))
	aura_px = roundf(size.y * 0.4)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(func() -> void: hovered.emit(unit_id()))
	mouse_exited.connect(func() -> void: hovered.emit(-1))


func set_unit(p_unit: Dictionary, p_view: Dictionary, p_hostile: bool, p_selected: bool,
		p_failure: Dictionary, p_clock: float, p_break_free: Dictionary = {}) -> void:
	unit = p_unit
	view = p_view
	hostile = p_hostile
	selected = p_selected
	failure = p_failure
	clock = p_clock
	break_free = p_break_free
	visible = not unit.is_empty()
	queue_redraw()


## Everything the frame may draw, in its own coordinates: the frame, auras above or below, the
## cast bar, and the arena Break Free box and DR tracker to the left (layout checks).
func extent() -> Rect2:
	var h: float = size.y
	var top: float = 0.0
	var bottom: float = h
	var biggest: float = roundf(aura_px * float(HudLogic.AURA_SIZE["cc"]))
	if bool(element.get("cast_bar", false)):
		bottom += 5.0 + roundf(h * 0.32)
	if int(element.get("max_auras", 0)) > 0:
		if str(element.get("aura_side", "below")) == "above":
			top = -biggest - 5.0
		else:
			bottom += 5.0 + biggest
	var left: float = 0.0
	if bool(element.get("break_free", false)):
		left = -roundf(h * 0.62) - 8.0
	if bool(element.get("dr_tracker", false)):
		var n: int = (style.layout.get("dr_categories", []) as Array).size()
		left = minf(left, -8.0 - n * (roundf(h * 0.36) + 3.0))
	return Rect2(left, top, size.x - left, bottom - top)


func unit_id() -> int:
	return int(unit.get("id", -1))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and not unit.is_empty():
			clicked.emit(unit_id())
			accept_event()


## The aura drawn at a point (frame coordinates), or {}.
func aura_at(p: Vector2) -> Dictionary:
	for a: Dictionary in drawn_auras:
		if (a["rect"] as Rect2).has_point(p):
			return a
	return {}


func _draw() -> void:
	drawn_auras.clear()
	if style == null or unit.is_empty():
		return
	var w: float = size.x
	var h: float = size.y
	var dead: bool = int(unit.get("health", 0)) <= 0
	var body: Rect2 = Rect2(Vector2.ZERO, size)
	style.panel(self, body, Color(), Color(1.0, 0.85, 0.35) if selected else Color())
	if selected:
		draw_rect(body.grow(3.0), Color(1.0, 0.85, 0.35, 0.9), false, 2.0)
	# portrait: the spec's icon, or the crowd control holding the unit
	var pr: Rect2 = Rect2(Vector2(2, 2), Vector2(h - 4, h - 4))
	var cc: Dictionary = HudLogic.active_cc(unit, view, style.cc.keys(), style.cc)
	if not cc.is_empty() and not dead:
		style.cc_icon(self, pr, cc["category"], false)
		var rem: float = float(cc["remaining_s"])
		if rem != INF:
			style.text_in(self, Rect2(pr.position, Vector2(pr.size.x, pr.size.y * 0.62)), HudStyle.countdown(rem, 10.0),
				style.fs("large"), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, 0.0, &"display")
		style.text_in(self, Rect2(pr.position + Vector2(0, pr.size.y * 0.6), Vector2(pr.size.x, pr.size.y * 0.4)),
			str(style.cc[cc["category"]]["short"]), style.fs("small"), Color.WHITE)
	else:
		_spec_portrait(pr, dead)
	# name, health, resource
	var x0: float = h + 2.0
	var inner_w: float = w - x0 - 4.0
	var name_h: float = roundf(h * 0.3)
	var hp_h: float = roundf(h * 0.4)
	var res_h: float = h - name_h - hp_h - 8.0
	var name_col: Color = style.color("hostile_name") if hostile else style.color("text")
	var label: String = HudStyle.spec_label(str(unit.get("spec", "")))
	if prefix != "":
		label = "%s  %s" % [prefix, label]
	var nfs: int = style.fs("normal") if h >= 64.0 else style.fs("small")
	# names in the display face; on small frames the text face, whose lowercase stays legible at 720p
	var nface: StringName = &"display" if nfs >= style.fs("normal") else &"text"
	style.text_in(self, Rect2(x0 + 2.0, 2.0, inner_w, name_h), CastBar._fit(style, label, nfs, inner_w - 4.0, nface),
		nfs, name_col, HORIZONTAL_ALIGNMENT_LEFT, 0.0, nface)
	var hp_r: Rect2 = Rect2(x0, 2.0 + name_h, inner_w, hp_h)
	var hp: float = float(unit.get("health", 0))
	var hp_max: float = maxf(1.0, float(unit.get("max_health", 1)))
	var cls: Color = HudStyle.class_color(str(unit.get("spec", "")))
	style.bar(self, hp_r, hp / hp_max, _bar_color(cls) if not dead else Color(0.3, 0.3, 0.3), style.color("health_missing"))
	var absorb: float = 0.0
	for a: Dictionary in unit.get("auras", []):
		absorb += float(a.get("absorb_left", 0.0))
	if absorb > 0.0 and not dead:
		var ax: float = hp_r.position.x + hp_r.size.x * hp / hp_max
		var aw: float = minf(hp_r.size.x * absorb / hp_max, hp_r.end.x - ax)
		if aw > 0.5:
			draw_rect(Rect2(ax, hp_r.position.y, aw, hp_r.size.y), Color(1, 1, 1, 0.45))
	var sfs: int = style.fs("small")
	if dead:
		style.text_in(self, hp_r, "Dead", sfs, style.color("text_dim"))
	else:
		style.text_in(self, hp_r, _short_number(hp), sfs, style.color("text"), HORIZONTAL_ALIGNMENT_LEFT, 5.0)
		style.text_in(self, hp_r, "%d%%" % roundi(hp * 100.0 / hp_max), sfs, style.color("text"), HORIZONTAL_ALIGNMENT_RIGHT, 5.0)
	var res_r: Rect2 = Rect2(x0, hp_r.end.y + 3.0, inner_w, maxf(4.0, res_h))
	var res_max: float = float(unit.get("resource_max", 0.0))
	var res_kind: String = str(Data.specs.get(str(unit.get("spec", "")), {}).get("primary_resource", ""))
	if res_max > 0.0:
		style.bar(self, res_r, float(unit.get("resource", 0.0)) / res_max, style.resource_colors.get(res_kind, Color.GRAY))
	# cast bar below the frame, auras above the frame or below the cast bar
	var below: float = h + 5.0
	if bool(element.get("cast_bar", false)):
		var cb: Rect2 = Rect2(Vector2(0, below), Vector2(w, roundf(h * 0.32)))
		CastBar.draw_cast(self, style, cb, unit, view, failure, clock)
		below += cb.size.y + 5.0
	_draw_auras(below)
	if bool(element.get("break_free", false)):
		_draw_break_free()
	if bool(element.get("dr_tracker", false)):
		_draw_dr()


func _spec_portrait(r: Rect2, dead: bool) -> void:
	var spec_id: String = str(unit.get("spec", ""))
	var c: Color = HudStyle.class_color(spec_id)
	if dead:
		c = Color(0.3, 0.3, 0.3)
	var p: Vector2 = r.position
	var s: Vector2 = r.size
	draw_polygon(PackedVector2Array([p, p + Vector2(s.x, 0), p + s, p + Vector2(0, s.y)]),
		PackedColorArray([c.darkened(0.2), c.darkened(0.35), c.darkened(0.8), c.darkened(0.7)]))
	var spec: Dictionary = Data.specs.get(spec_id, {})
	var glyph: Texture2D = style.icon_texture(spec.get("icon", {}))
	if glyph != null:
		# the spec's glyph in warm bone over the class color (the same art as the ability icons)
		draw_texture_rect(glyph, r, false, Color(1.0, 0.96, 0.88, 0.25 if dead else 0.95))
	else:
		style.text_in(self, r, HudStyle.initials(str(spec.get("name", spec_id))), style.fs("large"), Color(1, 1, 1, 0.95),
			HORIZONTAL_ALIGNMENT_CENTER, 0.0, &"display")
	portrait_glyph = glyph != null
	var role: String = str(spec.get("role", ""))
	var role_txt: String = {"healer": "HEAL", "tank": "TANK"}.get(role, "")
	if role_txt != "":
		style.text_in(self, Rect2(p + Vector2(0, s.y * 0.66), Vector2(s.x, s.y * 0.34)), role_txt, style.fs("small"),
			Color(0.8, 1.0, 0.8))
	draw_rect(r, Color(0, 0, 0, 0.9), false, 2.0)


func _draw_auras(below_y: float) -> void:
	var max_n: int = int(element.get("max_auras", 6))
	if max_n <= 0:
		return
	var list: Array = HudLogic.sorted_auras(unit, view)
	var above: bool = str(element.get("aura_side", "below")) == "above"
	var x: float = 0.0
	var gap: float = 3.0
	var sfs: int = style.fs("small")
	for e: Dictionary in list.slice(0, max_n):
		var px: float = roundf(aura_px * aura_scale * float(e["size"]))
		if x + px > size.x:  # the row never wraps or runs past the frame
			break
		var y: float = -px - 5.0 if above else below_y
		var r: Rect2 = Rect2(Vector2(x, y), Vector2(px, px))
		var data: Dictionary = e["aura"]
		if e["cc"] and style.cc.has(e["category"]):
			style.cc_icon(self, r, e["category"], false)
			var gr: Rect2 = r.grow(-px * 0.12)
			style.icon(self, Rect2(gr.position, gr.size * 0.5), data.get("icon", {}), "", Color.WHITE, false)
		else:
			style.icon(self, r, data.get("icon", {}), str(data.get("name", "")), Color.WHITE, false)
		var border: Color = style.color("debuff_border") if e["kind"] == "debuff" else style.color("buff_border")
		if e["cc"]:
			border = style.cc.get(e["category"], {}).get("color", border)
		draw_rect(r, border, false, 2.0)
		if float(e["remaining_s"]) >= 0.0:
			style.text_in(self, Rect2(r.position + Vector2(0, px * 0.45), Vector2(px, px * 0.55)),
				HudStyle.countdown_short(float(e["remaining_s"])), sfs, Color(1.0, 0.95, 0.8))
		if int(e["stacks"]) > 1:
			style.text(self, r.position + Vector2(px - 2.0, style.font.get_ascent(sfs)), str(e["stacks"]), sfs,
				Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, 0.0)
		drawn_auras.append({"id": e["id"], "size_px": px, "cc": e["cc"], "rect": r, "remaining_s": float(e["remaining_s"]),
			"stacks": int(e["stacks"]), "source": int(e["source"])})
		x += px + gap


func _draw_break_free() -> void:
	var bs: float = roundf(size.y * 0.62)
	var r: Rect2 = Rect2(Vector2(-bs - 8.0, 0.0), Vector2(bs, bs))
	var ab: Dictionary = Data.abilities.get("break_free", {})
	style.icon(self, r, ab.get("icon", {"symbol": "broken_chain"}), "", Color.WHITE, false)
	var tick: int = int(view.get("tick", 0))
	var ready: int = int(break_free.get("ready_tick", 0))
	if ready > tick:
		var total: float = maxf(1.0, float(break_free.get("total_ticks", 1)))
		HudStyle.sweep(self, r, 1.0 - (ready - tick) / total, Color(0, 0, 0, 0.72))
		style.text_in(self, r, HudStyle.countdown_short((ready - tick) / float(view.get("tick_rate", 60))),
			style.fs("small"), Color(1.0, 0.95, 0.75))
	else:
		draw_rect(r.grow(1.0), Color(0.95, 0.85, 0.4), false, 2.0)  # ready: gold border


func _draw_dr() -> void:
	var tick: int = int(view.get("tick", 0))
	var dr: Dictionary = unit.get("dr", {})
	var s: float = roundf(size.y * 0.36)
	var x: float = -8.0
	var y: float = size.y - s
	var mults: Array = Data.tuning.get("crowd_control", {}).get("dr_multipliers", [1.0, 0.5, 0.25, 0.0])
	for cat: String in style.layout.get("dr_categories", []):
		var d: Dictionary = dr.get(cat, {})
		var count: int = int(d.get("count", 0))
		if count <= 0 or int(d.get("reset_tick", 0)) <= tick:
			continue
		x -= s + 3.0
		var r: Rect2 = Rect2(Vector2(x, y), Vector2(s, s))
		style.cc_icon(self, r, cat, false)
		var next: float = float(mults[mini(count, mults.size() - 1)])
		var txt: String = "IMM" if next <= 0.0 else ("½" if next >= 0.5 else "¼")
		var col: Color = Color(1.0, 0.3, 0.25) if next <= 0.0 else (Color(1.0, 0.9, 0.3) if next >= 0.5 else Color(1.0, 0.6, 0.2))
		style.text_in(self, r, txt, style.fs("small"), col)


## Class colors as health fills, darkened until white text on them keeps its contrast.
static func _bar_color(c: Color) -> Color:
	var out: Color = c.darkened(0.12)
	while out.get_luminance() > 0.42:
		out = out.darkened(0.08)
	return out


static func _short_number(v: float) -> String:
	if v >= 1000.0:
		return "%.1fk" % (v / 1000.0)
	return "%d" % roundi(v)
