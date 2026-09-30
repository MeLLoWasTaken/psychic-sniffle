extends Control
## Contact sheet of the ability and aura icons and the HUD typefaces (backlog X-03), drawn with the
## HUD's own HudStyle so it shows exactly what the game shows:
##
##   tools/screenshot.sh res://scenes/tests/icon_sheet.tscn previews/icons/sheet.png 1920 1080 10
##
## One row per spec (its bar abilities), then the class-shared abilities and every aura; each
## icon at the action-bar size (50 px) and the aura size (26 px), then the button states
## (ready, cooldown sweep, out of range, short of resource, unusable, execute highlight, the
## off-cooldown glow), a school strip and a specimen of both faces at the layout's sizes.

const BIG: float = 50.0
const SMALL: float = 26.0
const CELL: float = 96.0

var style: HudStyle
var bar: ActionBar


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	style = HudStyle.new(Data.hud_layouts["default"])
	queue_redraw()


func _rows() -> Array:
	var rows: Array = []
	var seen: Dictionary = {}
	for spec_id: String in Data.specs:
		var ids: Array = []
		for aid: String in Data.specs[spec_id].get("abilities", []):
			if Data.abilities.has(aid) and str(Data.abilities[aid].get("cast_type", "")) != "passive":
				ids.append(aid)
				seen[aid] = true
		rows.append([HudStyle.spec_label(spec_id), ids, "ability"])
	var rest: Array = []
	for aid: String in Data.abilities:
		if not seen.has(aid):
			rest.append(aid)
	rows.append(["Shared", rest, "ability"])
	var auras: Array = Data.auras.keys()
	rows.append(["Auras", auras.slice(0, 12), "aura"])
	rows.append(["", auras.slice(12), "aura"])
	return rows


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.13, 0.11, 0.095))
	var y: float = 14.0
	style.text(self, Vector2(16, y + 26), "Ability icons", 28, style.color("text"), HORIZONTAL_ALIGNMENT_LEFT, -1, -1, &"display")
	y += 44.0
	for row: Array in _rows():
		style.text(self, Vector2(16, y + 30), str(row[0]), style.fs("normal"), style.color("text_dim"), HORIZONTAL_ALIGNMENT_LEFT,
			-1, -1, &"display")
		var x: float = 190.0
		for id: String in row[1]:
			var d: Dictionary = Data.abilities.get(id, {}) if row[2] == "ability" else Data.auras.get(id, {})
			var nm: String = str(d.get("name", id))
			style.icon(self, Rect2(Vector2(x, y), Vector2(BIG, BIG)), d.get("icon", {}), nm)
			style.icon(self, Rect2(Vector2(x + BIG + 6.0, y + BIG - SMALL), Vector2(SMALL, SMALL)), d.get("icon", {}), nm,
				Color.WHITE, false)
			style.text(self, Vector2(x, y + BIG + 16.0), CastBar._fit(style, nm, style.fs("small"), CELL - 6.0),
				style.fs("small"), style.color("text"))
			x += CELL
		y += BIG + 30.0
	y += 6.0
	_states(Vector2(190.0, y))
	_schools(Vector2(190.0 + 8 * CELL, y))
	y += BIG + 44.0
	_specimen(Vector2(16.0, y))


func _states(at: Vector2) -> void:
	var ab: Dictionary = Data.abilities.get("rime_bolt", {})
	var ex: Dictionary = Data.abilities.get("headsmans_verdict", {})
	var names: Array = ["Ready", "Cooldown", "Out of range", "No resource", "Unusable", "Execute", "Ready glow"]
	var tints: Array = [Color.WHITE, Color.WHITE, Color(1.0, 0.38, 0.32), Color(0.45, 0.55, 1.0).darkened(0.25),
		Color(0.42, 0.42, 0.42), Color.WHITE, Color.WHITE]
	style.text(self, Vector2(16, at.y + 30), "Button states", style.fs("normal"), style.color("text_dim"),
		HORIZONTAL_ALIGNMENT_LEFT, -1, -1, &"display")
	for i: int in names.size():
		var r: Rect2 = Rect2(at + Vector2(i * CELL, 0.0), Vector2(BIG, BIG))
		var d: Dictionary = ex if i == 5 else ab
		draw_rect(r.grow(2.0), style.color("frame_border_dark"))
		style.icon(self, r, d.get("icon", {}), str(d.get("name", "")), tints[i])
		if i == 1:
			HudStyle.sweep(self, r.grow(-1.0), 0.35, Color(0, 0, 0, 0.7))
			style.text_in(self, r, "13", style.fs("large"), Color(1.0, 0.95, 0.75), HORIZONTAL_ALIGNMENT_CENTER, 0.0, &"display")
		if i == 4:
			draw_rect(r, Color(0, 0, 0, 0.35))
		if i == 5:
			for j: int in 4:
				draw_rect(r.grow(1.0 + j * 1.5), Color(1.0, 0.82, 0.3, 0.8 * (0.85 - j * 0.2)), false, 2.0)
			draw_rect(r.grow(-1.0), Color(1.0, 0.85, 0.3), false, 3.0)
		if i == 6:
			var gc: Color = style.icon_base(ab.get("icon", {})).lerp(Color.WHITE, 0.45)
			for j: int in 4:
				draw_rect(r.grow(2.0 + j * 1.5), Color(gc, 0.85 - j * 0.2), false, 2.0)
			draw_rect(r, Color(1, 1, 1, 0.15))
		style.text(self, r.position + Vector2(0, BIG + 16.0), str(names[i]), style.fs("small"), style.color("text"))


func _schools(at: Vector2) -> void:
	var i: int = 0
	for school: String in ["physical", "frost", "holy", "shadow", "fire", "nature", "storm", "blood", "fel", "time"]:
		var r: Rect2 = Rect2(at + Vector2(i * 62.0, 0.0), Vector2(BIG, BIG))
		style.icon(self, r, {"symbol": "orb", "school": school, "image": "lorc/magic-swirl"}, school)
		style.text(self, r.position + Vector2(0, BIG + 16.0), school, style.fs("small"), style.color("text"))
		i += 1


func _specimen(at: Vector2) -> void:
	var y: float = at.y
	for sz: String in ["alert", "timer", "large", "normal"]:
		var fsz: int = style.fs(sz)
		style.text(self, Vector2(at.x, y + fsz), "Feared 4.2  0:35  Carnage Warblade  Rime Arcanist  -12,480  (%s %d)" % [sz, fsz],
			fsz, style.color("text"), HORIZONTAL_ALIGNMENT_LEFT, -1, -1, &"display")
		y += fsz + 12.0
	for sz: String in ["large", "normal", "small"]:
		var fsz: int = style.fs(sz)
		style.text(self, Vector2(at.x, y + fsz), "Swift Benediction 0.3   56.1k 94%%   Gates open in   Dampening 12%%   S1 S2 SR   (%s %d)" % [sz, fsz],
			fsz, style.color("text"))
		y += fsz + 10.0
