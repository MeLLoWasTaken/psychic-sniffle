class_name CastBar
extends Control
## A cast bar (backlog M1-27): the unit's cast or channel from the view, with the spell's name
## and the seconds left. Interruptible casts fill in amber, channels in green and drain, and
## casts that cannot be interrupted are steel gray with a lock mark, so the difference reads
## without color too (DESIGN.md: "interruptible casts and uninterruptible casts look different").
## After an interrupt or failure the bar holds a moment with the reason in red.
## UnitFrame draws the same bar through draw_cast().

const HOLD_S: float = 0.7  ## how long "Interrupted" stays on the bar

var style: HudStyle
var unit: Dictionary = {}
var view: Dictionary = {}
var failure: Dictionary = {}  ## {text, until_s} from the HUD's event tracking
var clock: float = 0.0


func setup(p_style: HudStyle, element: Dictionary) -> void:
	style = p_style
	var sz: Array = element.get("size", [300, 22])
	size = Vector2(float(sz[0]), float(sz[1]))
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_unit(p_unit: Dictionary, p_view: Dictionary, p_failure: Dictionary, p_clock: float) -> void:
	unit = p_unit
	view = p_view
	failure = p_failure
	clock = p_clock
	visible = has_content(unit, failure, clock)
	queue_redraw()


func _draw() -> void:
	if style != null:
		draw_cast(self, style, Rect2(Vector2.ZERO, size), unit, view, failure, clock)


## True when there is something to show: a cast, or a failure still held.
static func has_content(u: Dictionary, fail: Dictionary, now: float) -> bool:
	return not (u.get("cast", {}) as Dictionary).is_empty() or (not fail.is_empty() and now < float(fail["until_s"]))


## Draw a unit's cast bar in `r`. Nothing when the unit is not casting and no failure is held.
static func draw_cast(ci: CanvasItem, st: HudStyle, r: Rect2, u: Dictionary, v: Dictionary, fail: Dictionary,
		now: float) -> void:
	var cast: Dictionary = u.get("cast", {})
	var fsz: int = st.fs("small")
	if cast.is_empty():
		if not fail.is_empty() and now < float(fail["until_s"]):
			st.panel(ci, r.grow(1.0), Color(0.08, 0.02, 0.02, 0.9))
			ci.draw_rect(r, st.color("cast_failed").darkened(0.35))
			st.text_in(ci, r, str(fail["text"]), fsz, Color(1.0, 0.85, 0.8))
		return
	var ab: Dictionary = Data.abilities.get(str(cast.get("ability", "")), {})
	var rate: float = float(v.get("tick_rate", 60))
	var tick: int = int(v.get("tick", 0))
	var start: int = int(cast.get("start_tick", tick))
	var end: int = int(cast.get("end_tick", tick + 1))
	var frac: float = clampf(float(tick - start) / maxf(1.0, end - start), 0.0, 1.0)
	var channel: bool = bool(cast.get("channel", false))
	var locked: bool = not bool(ab.get("interruptible", true))
	var fill: Color = st.color("cast_uninterruptible") if locked else (st.color("cast_channel") if channel else st.color("cast_interruptible"))
	st.panel(ci, r.grow(1.0), Color(0.04, 0.03, 0.02, 0.92))
	var icon_r: Rect2 = Rect2(r.position, Vector2(r.size.y, r.size.y))
	st.icon(ci, icon_r, ab.get("icon", {}), str(ab.get("name", "")), Color.WHITE, false)
	var bar_r: Rect2 = Rect2(r.position + Vector2(r.size.y + 2.0, 0.0), Vector2(r.size.x - r.size.y - 2.0, r.size.y))
	st.bar(ci, bar_r, 1.0 - frac if channel else frac, fill, Color(0.1, 0.08, 0.06))
	if locked:
		# uninterruptible: a lock plate on the icon and a light border
		ci.draw_rect(bar_r, Color(0.85, 0.85, 0.9), false, 2.0)
		var lk: Rect2 = Rect2(icon_r.position + icon_r.size * Vector2(0.25, 0.45), icon_r.size * Vector2(0.5, 0.42))
		ci.draw_rect(lk, Color(0.85, 0.85, 0.9))
		ci.draw_arc(icon_r.position + icon_r.size * Vector2(0.5, 0.45), icon_r.size.x * 0.17, PI, TAU, 10, Color(0.85, 0.85, 0.9), 2.0)
	var left: float = maxf(0.0, (end - tick) / rate)
	var name: String = str(ab.get("name", cast.get("ability", "")))
	var time_txt: String = "%.1f" % left
	var tw: float = st.text_width(time_txt, fsz) + 6.0
	var text_r: Rect2 = Rect2(bar_r.position + Vector2(4.0, 0.0), Vector2(bar_r.size.x - tw - 6.0, bar_r.size.y))
	st.text_in(ci, text_r, _fit(st, name, fsz, text_r.size.x), fsz, st.color("text"), HORIZONTAL_ALIGNMENT_LEFT)
	st.text_in(ci, Rect2(bar_r.end.x - tw - 2.0, bar_r.position.y, tw, bar_r.size.y), time_txt, fsz, st.color("text"),
		HORIZONTAL_ALIGNMENT_RIGHT)


## `s` cut with "…" to fit `width` at font size `fsz`.
static func _fit(st: HudStyle, s: String, fsz: int, width: float) -> String:
	if st.text_width(s, fsz) <= width:
		return s
	while s.length() > 1 and st.text_width(s + "…", fsz) > width:
		s = s.substr(0, s.length() - 1)
	return s + "…"
