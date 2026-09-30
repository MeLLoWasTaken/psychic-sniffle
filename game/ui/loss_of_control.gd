class_name LossOfControlAlert
extends Control
## The loss-of-control alert in the screen centre (backlog M1-27; DESIGN.md "a loss-of-control
## alert in the screen center"): while the local player is under crowd control of a category the
## layout lists (stun, fear, silence...), a large icon with the category's glyph, its label
## ("Stunned"), the effect's name, the seconds left and a draining bar. Hidden otherwise.

var style: HudStyle
var categories: Array = []
var current: Dictionary = {}  ## HudLogic.active_cc result, or {}


func setup(p_style: HudStyle, element: Dictionary) -> void:
	style = p_style
	categories = style.layout.get("loss_of_control", [])
	var sz: Array = element.get("size", [380, 96])
	size = Vector2(float(sz[0]), float(sz[1]))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


## Update from the local player's unit in the view.
func set_view(v: Dictionary) -> void:
	var me: Dictionary = v.get("me", {})
	current = {} if me.is_empty() or int(me.get("health", 0)) <= 0 else HudLogic.active_cc(me, v, categories, style.cc)
	visible = not current.is_empty()
	queue_redraw()


## The label of the current alert ("Stunned"), or "".
func label() -> String:
	return "" if current.is_empty() else str(style.cc.get(current["category"], {}).get("label", current["category"]))


func _draw() -> void:
	if style == null or current.is_empty():
		return
	var cat: String = current["category"]
	var c: Color = style.cc.get(cat, {}).get("color", Color.WHITE)
	var h: float = size.y
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0.0, 0.0, 0.0, 0.55))
	draw_rect(Rect2(0, 0, size.x, 3), c)
	draw_rect(Rect2(0, h - 3, size.x, 3), c)
	var ir: Rect2 = Rect2(Vector2(8, 8), Vector2(h - 16, h - 16))
	style.cc_icon(self, ir, cat, true)
	var x0: float = h + 4.0
	var tw: float = size.x - x0 - 12.0
	var rem: float = float(current["remaining_s"])
	style.text_in(self, Rect2(x0, 6, tw, h * 0.45), label(), style.fs("alert"), c.lightened(0.3), HORIZONTAL_ALIGNMENT_LEFT)
	if rem != INF:
		style.text_in(self, Rect2(x0, 6, tw, h * 0.45), "%.1f" % rem, style.fs("alert"), Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
	style.text_in(self, Rect2(x0, h * 0.46, tw, h * 0.26), str(current["name"]), style.fs("normal"), style.color("text"),
		HORIZONTAL_ALIGNMENT_LEFT)
	var dur: float = maxf(0.01, float(current["duration_s"]))
	if rem != INF:
		style.bar(self, Rect2(x0, h * 0.76, tw, maxf(6.0, h * 0.1)), rem / dur, c)
