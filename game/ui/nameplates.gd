class_name Nameplates
extends Control
## Nameplates (backlog M2-14): a small plate over every other unit in the world, projected through
## the camera each frame like the combat text. Each plate shows the unit's name in its team color,
## a health bar in its class color (with absorbs), its cast bar (amber when it can be interrupted,
## gray with a lock when not, green for channels: CastBar.draw_cast) and its important auras:
## crowd control, major defensives and offensives, and the debuffs the player applied. The
## player's target gets a gold border and a slightly larger plate. Plates that would cover each
## other step upward. The interface settings turn plates, their cast bars and their auras on or off.
##
## Covers the whole screen unscaled (Hud.relayout); sizes are logical pixels times ui_scale.

var style: HudStyle
var camera: Camera3D
var position_of: Callable  ## unit id -> Vector3 world position (feet), or a non-finite vector when gone
var view: Dictionary = {}
var target_id: int = -1
var failures: Dictionary = {}  ## unit id -> {text, until_s} (the HUD's cast failure tracking)
var clock: float = 0.0
var ui_scale: float = 1.0
var show_cast_bars: bool = true
var show_auras: bool = true
var height_m: float = 2.55
var width_px: float = 132.0
var health_px: float = 11.0
var cast_px: float = 16.0
var aura_px: float = 22.0
var max_auras: int = 4
var max_distance_m: float = 45.0
var friendly: bool = true
var placed: Array = []  ## the plates drawn last (tests): {id, rect, auras, cast, target}

const TARGET_GROW: float = 1.15
const GAP: float = 2.0


func setup(p_style: HudStyle, element: Dictionary) -> void:
	style = p_style
	height_m = float(element.get("height_m", height_m))
	width_px = float(element.get("width_px", width_px))
	health_px = float(element.get("health_px", health_px))
	cast_px = float(element.get("cast_px", cast_px))
	aura_px = float(element.get("aura_px", aura_px))
	max_auras = int(element.get("max_auras", max_auras))
	max_distance_m = float(element.get("max_distance_m", max_distance_m))
	friendly = bool(element.get("friendly", friendly))
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_view(p_view: Dictionary, p_target: int, p_failures: Dictionary, p_clock: float) -> void:
	view = p_view
	target_id = p_target
	failures = p_failures
	clock = p_clock
	queue_redraw()


## The auras a plate shows for `unit`, most important first: crowd control, major defensives
## and offensives (on anyone), then debuffs the player `me_id` applied. At most `max_n`.
static func plate_auras(unit: Dictionary, p_view: Dictionary, me_id: int, max_n: int) -> Array:
	var out: Array = []
	for e: Dictionary in HudLogic.sorted_auras(unit, p_view):
		var important: bool = e["group"] != "normal"
		var mine: bool = e["kind"] == "debuff" and int(e["source"]) == me_id
		if important or mine:
			out.append(e)
		if out.size() >= max_n:
			break
	return out


## Plates that would overlap step upward past the ones already placed (nearest units first, so
## the closest plate keeps its place). `rects` in drawing order; returns the moved rectangles.
static func unstack(rects: Array) -> Array:
	var out: Array = []
	for r: Rect2 in rects:
		var moved: Rect2 = r
		for _try: int in 6:
			var hit: bool = false
			for p: Rect2 in out:
				if p.intersects(moved):
					moved.position.y = p.position.y - moved.size.y - GAP
					hit = true
			if not hit:
				break
		out.append(moved)
	return out


## Where a unit's plate anchors on screen (its bottom center), or null when the unit is behind
## the camera, gone, or farther than max_distance_m.
func anchor_of(id: int) -> Variant:
	if camera == null or not position_of.is_valid():
		return null
	var p: Vector3 = position_of.call(id)
	if not p.is_finite():
		return null
	var wp: Vector3 = p + Vector3.UP * height_m
	if camera.is_position_behind(wp) or camera.global_position.distance_to(wp) > max_distance_m:
		return null
	return camera.unproject_position(wp)


func _draw() -> void:
	placed.clear()
	if style == null or view.is_empty():
		return
	var me: Dictionary = view.get("me", {})
	var me_id: int = int(me.get("id", -1))
	var my_team: int = int(me.get("team", -1))
	var plates: Array = []  # {unit, anchor, dist, k}
	for u: Dictionary in view.get("units", []):
		var id: int = int(u["id"])
		if id == me_id or int(u.get("health", 0)) <= 0:
			continue
		var ally: bool = int(u["team"]) == my_team
		if ally and not friendly:
			continue
		var a: Variant = anchor_of(id)
		if a == null:
			continue
		var dist: float = camera.global_position.distance_to(position_of.call(id))
		var k: float = ui_scale * (TARGET_GROW if id == target_id else 1.0)
		var auras: Array = plate_auras(u, view, me_id, max_auras) if show_auras and max_auras > 0 else []
		var sizes: Array = auras.map(func(e: Dictionary) -> float: return roundf(aura_px * k * (1.2 if e["cc"] else 1.0)))
		var aura_h: float = (sizes.max() + GAP) if not sizes.is_empty() else 0.0
		plates.append({"unit": u, "anchor": a, "dist": dist, "ally": ally, "k": k, "auras": auras, "sizes": sizes, "aura_h": aura_h})
	plates.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["dist"]) < float(y["dist"]))
	var rects: Array = []
	for pl: Dictionary in plates:
		var k: float = pl["k"]
		var w: float = roundf(width_px * k)
		var h: float = _plate_height(pl["unit"], k) + float(pl["aura_h"])  # the aura row is part of the plate
		var a: Vector2 = pl["anchor"]
		rects.append(Rect2(Vector2(roundf(a.x - w * 0.5), roundf(a.y - h)), Vector2(w, h)))
	rects = unstack(rects)
	# farthest first, so nearer plates draw on top
	for i: int in range(plates.size() - 1, -1, -1):
		_draw_plate(plates[i], rects[i], me_id)


## A plate's height without its aura row: name, health and (when casting) the cast bar.
func _plate_height(u: Dictionary, k: float) -> float:
	var h: float = style.fs("small") * k + 2.0 + health_px * k
	if show_cast_bars and CastBar.has_content(u, failures.get(int(u["id"]), {}), clock):
		h += GAP + cast_px * k
	return roundf(h)


func _draw_plate(pl: Dictionary, r: Rect2, me_id: int) -> void:
	var u: Dictionary = pl["unit"]
	var id: int = int(u["id"])
	var k: float = pl["k"]
	var fsz: int = roundi(style.fs("small") * k)
	var is_target: bool = id == target_id
	var top: float = r.position.y + float(pl["aura_h"])  # the aura row sits above the name
	# name
	var name_col: Color = style.color("friendly_name") if pl["ally"] else style.color("hostile_name")
	var name: String = HudStyle.spec_label(str(u.get("spec", "")))
	style.text(self, Vector2(r.position.x, top + fsz), name, fsz, name_col, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 3)
	# health in class color, absorbs as a light overlay
	var hr: Rect2 = Rect2(Vector2(r.position.x, top + fsz + 2.0), Vector2(r.size.x, roundf(health_px * k)))
	var max_hp: float = maxf(1.0, float(u.get("max_health", 1)))
	var frac: float = clampf(float(u.get("health", 0)) / max_hp, 0.0, 1.0)
	draw_rect(hr.grow(1.0), Color(0, 0, 0, 0.85))
	style.bar(self, hr, frac, UnitFrame._bar_color(HudStyle.class_color(str(u.get("spec", "")))), style.color("health_missing"))
	var absorb: float = 0.0
	for au: Dictionary in u.get("auras", []):
		absorb += float(au.get("absorb_left", 0.0))
	if absorb > 0.0:
		var aw: float = minf(1.0 - frac, absorb / max_hp) * hr.size.x
		if aw > 0.0:
			draw_rect(Rect2(hr.position + Vector2(frac * hr.size.x, 0.0), Vector2(aw, hr.size.y)), Color(1, 1, 1, 0.45))
	if is_target:
		draw_rect(hr.grow(2.0), Color(1.0, 0.85, 0.35, 0.95), false, 2.0)
	var cast: bool = false
	if show_cast_bars and CastBar.has_content(u, failures.get(id, {}), clock):
		var cr: Rect2 = Rect2(Vector2(r.position.x, hr.end.y + GAP + 1.0), Vector2(r.size.x, roundf(cast_px * k)))
		CastBar.draw_cast(self, style, cr, u, view, failures.get(id, {}), clock)
		cast = true
	# auras in a row above the name, centered
	var shown: Array = []
	var list: Array = pl["auras"]
	var sizes: Array = pl["sizes"]
	if not list.is_empty():
		var total: float = 0.0
		for s: float in sizes:
			total += s + GAP
		var x: float = r.position.x + (r.size.x - total + GAP) * 0.5
		for j: int in list.size():
			var e: Dictionary = list[j]
			var px: float = sizes[j]
			var ar: Rect2 = Rect2(Vector2(x, top - GAP - px), Vector2(px, px))
			var data: Dictionary = e["aura"]
			if e["cc"] and style.cc.has(e["category"]):
				style.cc_icon(self, ar, e["category"], false)
			else:
				style.icon(self, ar, data.get("icon", {}), str(data.get("name", "")), Color.WHITE, false)
			var border: Color = style.color("debuff_border") if e["kind"] == "debuff" else style.color("buff_border")
			if e["cc"]:
				border = style.cc.get(e["category"], {}).get("color", border)
			draw_rect(ar, border, false, 2.0)
			if float(e["remaining_s"]) >= 0.0:
				style.text_in(self, Rect2(ar.position + Vector2(0, px * 0.45), Vector2(px, px * 0.55)),
					HudStyle.countdown_short(float(e["remaining_s"])), maxi(10, roundi(fsz * 0.9)), Color(1.0, 0.95, 0.8))
			shown.append(str(e["id"]))
			x += px + GAP
	placed.append({"id": id, "rect": r, "auras": shown, "cast": cast, "target": is_target})
