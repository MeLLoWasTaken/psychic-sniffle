class_name MatchTimer
extends Control
## Match timer and dampening (backlog M1-27): match time since the gates opened, a countdown to
## the gates during preparation, and the healing dampening percentage from the view's match
## info. The clock stops at the end of the match.

var style: HudStyle
var phase: int = ArenaMatch.Phase.ACTIVE
var seconds: float = 0.0  ## match time (negative: seconds until the gates open)
var dampening_pct: int = 0
var winner: int = -1
var _end_seconds: float = -1.0


func setup(p_style: HudStyle, element: Dictionary) -> void:
	style = p_style
	var sz: Array = element.get("size", [240, 60])
	size = Vector2(float(sz[0]), float(sz[1]))
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Read the match state from a view.
func set_view(v: Dictionary) -> void:
	if v.is_empty():
		return
	var m: Dictionary = v.get("match", {})
	phase = int(m.get("phase", ArenaMatch.Phase.ACTIVE))
	dampening_pct = int(m.get("dampening_pct", 0))
	winner = int(m.get("winner", -1))
	var now: float = float(int(v["tick"]) - int(m.get("start_tick", 0))) / float(v.get("tick_rate", 60))
	if phase == ArenaMatch.Phase.ENDED:
		if _end_seconds < 0.0:
			_end_seconds = now
		seconds = _end_seconds
	else:
		_end_seconds = -1.0
		seconds = now
	queue_redraw()


## The timer text: "3:42", or "0:45" counting down to the gates.
func time_text() -> String:
	var s: int = ceili(-seconds) if seconds < 0.0 else floori(seconds)
	return "%d:%02d" % [s / 60, s % 60]


func dampening_text() -> String:
	return "Dampening %d%%" % dampening_pct


func _draw() -> void:
	if style == null:
		return
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	style.panel(self, r)
	var top: Rect2 = Rect2(0, 0, size.x, size.y * 0.62)
	var bottom: Rect2 = Rect2(0, size.y * 0.56, size.x, size.y * 0.44)
	var sfs: int = style.fs("small")
	if phase == ArenaMatch.Phase.PREP:
		style.text_in(self, top, time_text(), style.fs("timer"), Color(1.0, 0.85, 0.45))
		style.text_in(self, bottom, "Gates open in", sfs, style.color("text_dim"))
		return
	style.text_in(self, top, time_text(), style.fs("timer"), style.color("text"))
	var damp_col: Color = style.color("text_dim") if dampening_pct == 0 else Color(1.0, 0.55 - dampening_pct * 0.004, 0.35)
	var label: String = dampening_text()
	if phase == ArenaMatch.Phase.ENDED:
		label = "Draw" if winner == -2 else "Match over"
		damp_col = Color(1.0, 0.85, 0.45)
	style.text_in(self, bottom, label, sfs, damp_col)
