class_name CombatText
extends Control
## Floating combat text (backlog M1-27; DESIGN.md "floating combat numbers for damage and
## healing, with larger text for critical hits"): numbers anchored to the unit in the world,
## projected through the camera each frame, rising and fading. Critical hits are larger and pop.
## Crowd control applied shows its label ("Stunned"). The count is bounded: past max_live the
## oldest text goes. Also shows the player's error messages ("Out of range") under the timer.

var style: HudStyle
var max_live: int = 40
var lifetime: float = 1.3
var rise: float = 70.0
var height: float = 2.3
var camera: Camera3D
var position_of: Callable  ## unit id -> Vector3 world position (feet), or INF when gone
var entries: Array[Dictionary] = []  ## {text, color, size, unit, age, x (start offset), crit}
var errors: Array[Dictionary] = []  ## {text, age}
var spawned: int = 0  ## texts ever spawned (tests)
var ui_scale: float = 1.0  ## the HUD scale; this control covers the screen unscaled
var error_y: float = 120.0  ## baseline of the first error line (the HUD puts it under the timer)
var _stagger: Dictionary = {}  ## unit id -> next stagger index

## Start offsets (x, y) of successive texts on one unit, so texts of the same moment do not overlap.
const STAGGER: Array[Vector2] = [Vector2(0, 0), Vector2(-54, 26), Vector2(54, 26), Vector2(-28, 52), Vector2(28, 52)]
const ERROR_S: float = 1.6
const MAX_ERRORS: int = 2


func setup(p_style: HudStyle, element: Dictionary) -> void:
	style = p_style
	max_live = int(element.get("max_live", 40))
	lifetime = float(element.get("lifetime_s", 1.3))
	rise = float(element.get("rise_px", 70.0))
	height = float(element.get("height_m", 2.3))
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Add a text over a unit. `size_name` is a style font size ("combat_text", "combat_text_crit").
func spawn(unit_id: int, text: String, col: Color, size_name: String = "combat_text", crit: bool = false) -> void:
	var k: int = int(_stagger.get(unit_id, 0))
	_stagger[unit_id] = (k + 1) % STAGGER.size()
	entries.append({"text": text, "color": col, "size": style.fs(size_name), "unit": unit_id, "age": 0.0,
		"x": STAGGER[k], "crit": crit})
	spawned += 1
	while entries.size() > max_live:
		entries.pop_front()


func error(text: String) -> void:
	for e: Dictionary in errors:
		if e["text"] == text:
			e["age"] = 0.0
			return
	errors.append({"text": text, "age": 0.0})
	while errors.size() > MAX_ERRORS:
		errors.pop_front()


## Age every text by `delta` seconds and drop the finished ones.
func advance(delta: float) -> void:
	for e: Dictionary in entries:
		e["age"] = float(e["age"]) + delta
	entries = entries.filter(func(e: Dictionary) -> bool: return float(e["age"]) < lifetime)
	for e: Dictionary in errors:
		e["age"] = float(e["age"]) + delta
	errors = errors.filter(func(e: Dictionary) -> bool: return float(e["age"]) < ERROR_S)
	queue_redraw()


## Where a text is on screen now, or null when its unit is off camera or gone.
func screen_position(e: Dictionary) -> Variant:
	if camera == null or not position_of.is_valid():
		return null
	var p: Vector3 = position_of.call(int(e["unit"]))
	if not p.is_finite():
		return null
	var wp: Vector3 = p + Vector3.UP * height
	if camera.is_position_behind(wp):
		return null
	var t: float = float(e["age"]) / lifetime
	return camera.unproject_position(wp) + ((e["x"] as Vector2) + Vector2(0.0, -rise * t)) * ui_scale


func _draw() -> void:
	if style == null:
		return
	var placed: Array[Rect2] = []  # texts already drawn this frame: newer ones step up past them
	for i: int in range(entries.size() - 1, -1, -1):
		var e: Dictionary = entries[i]
		var sp: Variant = screen_position(e)
		if sp == null:
			continue
		var t: float = float(e["age"]) / lifetime
		var col: Color = e["color"]
		col.a = 1.0 if t < 0.6 else clampf((1.0 - t) / 0.4, 0.0, 1.0)
		var fsz: int = roundi(int(e["size"]) * ui_scale)
		if bool(e["crit"]) and float(e["age"]) < 0.15:
			fsz = roundi(fsz * lerpf(1.35, 1.0, float(e["age"]) / 0.15))
		var w: float = style.text_width(str(e["text"]), fsz, &"display")
		var pos: Vector2 = (sp as Vector2) - Vector2(w * 0.5, 0.0)
		pos = _free_spot(pos, Vector2(w, fsz), placed)
		style.text(self, pos, str(e["text"]), fsz, col, HORIZONTAL_ALIGNMENT_LEFT, -1.0, maxi(4, fsz / 6), &"display")
	var y: float = error_y
	for e: Dictionary in errors:
		var a: float = clampf((ERROR_S - float(e["age"])) / 0.4, 0.0, 1.0)
		var fsz: int = roundi(style.fs("large") * ui_scale)
		style.text(self, Vector2(0.0, y), str(e["text"]), fsz, Color(1.0, 0.3, 0.25, a), HORIZONTAL_ALIGNMENT_CENTER, size.x)
		y += fsz + 6.0


## The first spot at or above `pos` (a baseline start) where a text of `sz` overlaps none of the
## `placed` rectangles (units close together on screen), recording it; gives up after 6 steps.
static func _free_spot(pos: Vector2, sz: Vector2, placed: Array[Rect2]) -> Vector2:
	for step: int in 7:
		var r: Rect2 = Rect2(pos - Vector2(0.0, sz.y * 0.8), sz)
		var hit: bool = false
		for q: Rect2 in placed:
			if q.intersects(r):
				hit = true
				pos.y = q.position.y - 2.0 + sz.y * 0.8 - sz.y  # just above the text in the way
				break
		if not hit or step == 6:
			placed.append(Rect2(pos - Vector2(0.0, sz.y * 0.8), sz))
			return pos
	return pos
