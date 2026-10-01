class_name MatchScreens
extends CanvasLayer
## The match flow's screens over the arena and the HUD (backlog M1-28), drawn from the MatchFlow
## state with the menu's style and text (data/menus/<id>.json):
##
## - LOADING: an opaque loading screen (map name, the line-up, what is happening now).
## - PREP: a banner under the match timer: "Preparation", then the countdown to the gates, or
##   "Waiting for players 3 / 4" while the roster joins.
## - ACTIVE: "The gates are open" for a moment after they open.
## - ENDED: Victory / Defeat / Draw with the reason, over the arena.
## - SCOREBOARD: the end screen: outcome, reason, match time, a table per team (the menu data's
##   columns: damage, healing, kills, interrupts) with team totals, and "Back to menu".
## - FAILED: what went wrong and "Back to menu".
## The in-match menu (Escape) is a PauseMenu child.
##
## Positions are logical pixels on the 1920x1080 canvas (the project's canvas_items stretch), so
## everything keeps its proportions at 1280x720; the smallest text is 17 px (11 px at 720p).

signal back_pressed()
signal resume_pressed()
signal leave_pressed()

const PANEL_W: float = 1240.0
const ROW_H: float = 58.0
const PLAYER_COL_W: float = 470.0

var style: MenuStyle
var flow: MatchFlow
var root: Control
var back_button: Button
var pause_menu: PauseMenu
var status_key: String = "starting_server"  ## the loading screen's current step (text key)
var title: String = ""  ## loading screen title (the map's name)
var lineup: String = ""  ## loading screen line-up ("Carnage Warblade & Grace Oracle  vs  ...")
var unit_names: Dictionary = {}  ## unit id -> "You", "Partner", "Enemy 1"...
var gates_banner_s: float = 2.5
var result: Dictionary = {}  ## MatchFlow.result() once the scoreboard shows
var _time: float = 0.0
var announcement: String = ""  ## a map event's line (a twist), shown as a banner for ANNOUNCE_S
var _announced_at: float = -100.0

const ANNOUNCE_S: float = 3.5


func _init(p_style: MenuStyle, p_flow: MatchFlow) -> void:
	style = p_style
	flow = p_flow
	layer = 20
	name = "MatchScreens"
	gates_banner_s = float(style.menu.get("play_bots", {}).get("gates_banner_s", 2.5))
	root = Control.new()
	root.name = "ScreensRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.draw.connect(_draw_screen)
	add_child(root)
	back_button = style.button(style.text("back_to_menu"), Vector2(320, 58), 24)
	back_button.name = "BackToMenu"
	back_button.visible = false
	back_button.pressed.connect(func() -> void: back_pressed.emit())
	root.add_child(back_button)
	pause_menu = PauseMenu.new(style, style.text("leave_match"), style.text("leave_note"))
	pause_menu.visible = false
	pause_menu.resume_pressed.connect(func() -> void: resume_pressed.emit())
	pause_menu.leave_pressed.connect(func() -> void: leave_pressed.emit())
	root.add_child(pause_menu)
	flow.state_changed.connect(_on_state_changed)


func _on_state_changed(_from: MatchFlow.State, to: MatchFlow.State) -> void:
	if to == MatchFlow.State.SCOREBOARD:
		result = flow.result()
	back_button.visible = to in [MatchFlow.State.SCOREBOARD, MatchFlow.State.FAILED]
	root.mouse_filter = Control.MOUSE_FILTER_STOP if back_button.visible else Control.MOUSE_FILTER_IGNORE
	if to in [MatchFlow.State.ENDED, MatchFlow.State.SCOREBOARD, MatchFlow.State.FAILED, MatchFlow.State.MENU]:
		pause_menu.visible = false
	if back_button.visible:
		_place_back_button()
		back_button.grab_focus.call_deferred()
	root.queue_redraw()


## Advance animations and redraw (every frame).
func update(delta: float) -> void:
	_time += delta
	pause_menu.position = (root.size - pause_menu.size) * 0.5
	if back_button.visible:
		_place_back_button()
	root.queue_redraw()


## Show a line about the arena (a twist's warning or moment) as a banner under the timer.
func announce(text: String) -> void:
	announcement = text
	_announced_at = _time


func show_pause(on: bool) -> void:
	pause_menu.visible = on
	if on:
		pause_menu.focus_first()


func pause_visible() -> bool:
	return pause_menu.visible


func _place_back_button() -> void:
	var c: Vector2 = root.size * 0.5
	if flow.state == MatchFlow.State.FAILED:
		back_button.position = Vector2(c.x - back_button.size.x * 0.5, c.y + 70)
	else:
		back_button.position = Vector2(c.x - back_button.size.x * 0.5, _board_rect().end.y - 84)


# ------------------------------------------------------------------ drawing

func _draw_screen() -> void:
	match flow.state:
		MatchFlow.State.LOADING:
			_draw_loading()
		MatchFlow.State.PREP:
			_draw_prep()
		MatchFlow.State.ACTIVE:
			if flow.time_in_state() < gates_banner_s:
				var a: float = clampf((gates_banner_s - flow.time_in_state()) / 0.6, 0.0, 1.0)
				_draw_band(96.0, 116.0, a)
				_centered(168.0, style.text("gates_open"), 52, Color(style.color("title"), a), &"display")
			elif announcement != "" and _time - _announced_at < ANNOUNCE_S:
				var a: float = clampf((ANNOUNCE_S - (_time - _announced_at)) / 0.6, 0.0, 1.0)
				_draw_band(104.0, 96.0, a)
				_centered(164.0, announcement, 40, Color(style.color("title"), a), &"display")
		MatchFlow.State.ENDED:
			_draw_outcome_banner()
		MatchFlow.State.SCOREBOARD:
			_draw_scoreboard()
		MatchFlow.State.FAILED:
			_draw_failed()


func _draw_loading() -> void:
	var w: float = root.size.x
	var h: float = root.size.y
	var top: Color = style.color("background_top")
	var bottom: Color = style.color("background_bottom")
	root.draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h), Vector2(0, h)]),
		PackedColorArray([top, top, bottom, bottom]))
	var cy: float = h * 0.5
	_centered(cy - 30.0, title, 68, style.color("title"), &"display")
	style.draw_rule(root, Vector2(w * 0.5, cy + 4.0), 260.0)
	if lineup != "":
		_centered(cy + 58.0, lineup, 24, style.color("text_dim"))
	var dots: String = ".".repeat(1 + int(_time * 2.0) % 3)
	var status: String = style.text(status_key)
	var sw: float = style.text_width(status, 28)
	style.draw_text(root, Vector2((w - sw) * 0.5, cy + 130.0), status + dots, 28, style.color("text"))
	# a turning diamond so a slow step still looks alive
	var c: Vector2 = Vector2(w * 0.5, cy + 200.0)
	var pts: PackedVector2Array = []
	for i: int in 4:
		var a: float = _time * 2.0 + i * PI * 0.5
		pts.append(c + Vector2(cos(a), sin(a) * 0.6) * 14.0)
	root.draw_colored_polygon(pts, Color(style.color("accent"), 0.8))


func _draw_prep() -> void:
	_draw_band(96.0, 132.0, 1.0)
	_centered(158.0, style.text("preparation"), 46, style.color("title"), &"display")
	var line: String
	if flow.waiting_for_players():
		line = style.text("waiting", {"joined": flow.units_joined, "total": flow.roster_size})
	else:
		line = style.text("gates_in", {"time": MenuStyle.countdown(flow.seconds_to_gates())})
	_centered(208.0, line, 30, style.color("text"))


func _draw_outcome_banner() -> void:
	var a: float = clampf(flow.time_in_state() / 0.35, 0.0, 1.0)
	var c: Color = _outcome_color()
	_draw_band(318.0, 220.0, a)
	_centered(452.0, _outcome_text().to_upper(), 118, Color(c, a), &"display")
	_centered(506.0, _reason_text(), 28, Color(style.color("text"), a))


func _draw_failed() -> void:
	_dim()
	var c: Vector2 = root.size * 0.5
	var r: Rect2 = Rect2(c.x - 430.0, c.y - 190.0, 860.0, 360.0)
	style.draw_panel(root, r)
	_centered(r.position.y + 88.0, style.text("failed"), 44, style.color("defeat"), &"display")
	style.draw_rule(root, Vector2(c.x, r.position.y + 120.0), 300.0)
	_centered(r.position.y + 180.0, failure_text(flow.failure), 26, style.color("text"))


func _board_rect() -> Rect2:
	var h: float = 760.0
	return Rect2((root.size.x - PANEL_W) * 0.5, (root.size.y - h) * 0.5, PANEL_W, h)


func _draw_scoreboard() -> void:
	_dim()
	var r: Rect2 = _board_rect()
	style.draw_panel(root, r)
	var x: float = r.position.x
	var y: float = r.position.y
	_centered(y + 104.0, _outcome_text().to_upper(), 80, _outcome_color(), &"display")
	var sub: String = "%s   ·   %s" % [_reason_text(), style.text("match_time", {"time": MenuStyle.clock(flow.match_seconds())})]
	_centered(y + 152.0, sub, 24, style.color("text_dim"))
	style.draw_rule(root, Vector2(r.get_center().x, y + 182.0), 420.0)
	var teams: Dictionary = result.get("teams", {})
	var totals: Dictionary = result.get("totals", {})
	var ty: float = y + 206.0
	ty = _draw_team(x + 60.0, ty, style.text("your_team"), teams.get("mine", []), totals.get("mine", {}), true)
	_draw_team(x + 60.0, ty + 26.0, style.text("enemy_team"), teams.get("enemy", []), totals.get("enemy", {}), false)


## One team's table from (x, y); returns the y below it.
func _draw_team(x: float, y: float, label: String, rows: Array, totals: Dictionary, mine: bool) -> float:
	var cols: Array = style.menu.get("scoreboard_columns", [])
	var inner_w: float = PANEL_W - 120.0
	var col_w: float = (inner_w - PLAYER_COL_W) / maxf(cols.size(), 1)
	var head_col: Color = style.color("victory") if mine else style.color("defeat")
	style.draw_text(root, Vector2(x, y + 30.0), label.to_upper(), 24, head_col, HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	for i: int in cols.size():
		var right: float = x + PLAYER_COL_W + (i + 1) * col_w
		style.draw_text(root, Vector2(right - col_w, y + 30.0), str(cols[i]["label"]), 18, style.color("text_dim"),
			HORIZONTAL_ALIGNMENT_RIGHT, col_w)
	root.draw_line(Vector2(x, y + 42.0), Vector2(x + inner_w, y + 42.0), Color(style.color("button_border"), 0.7), 1.0)
	var ry: float = y + 46.0
	var n: int = 0
	for row: Dictionary in rows:
		var rr: Rect2 = Rect2(x - 8.0, ry, inner_w + 16.0, ROW_H - 4.0)
		var is_me: bool = int(row["id"]) == int(result.get("my_id", -1))
		if is_me:
			root.draw_rect(rr, style.color("row_self"))
		elif n % 2 == 1:
			root.draw_rect(rr, style.color("row_alt"))
		var spec: String = str(row["spec"])
		var alive: bool = bool(row.get("alive", true))
		root.draw_rect(Rect2(x, ry + 7.0, 6.0, ROW_H - 18.0), HudStyle.class_color(spec) if alive else style.color("dead"))
		var name_col: Color = (style.color("title") if is_me else style.color("text")) if alive else style.color("dead")
		var unit_name: String = str(unit_names.get(int(row["id"]), ""))
		style.draw_text(root, Vector2(x + 22.0, ry + 25.0), unit_name, 24, name_col)
		style.draw_text(root, Vector2(x + 22.0, ry + 47.0), HudStyle.spec_label(spec), 17,
			HudStyle.class_color(spec).lerp(style.color("text_dim"), 0.35))
		for i: int in cols.size():
			var right: float = x + PLAYER_COL_W + (i + 1) * col_w
			style.draw_text(root, Vector2(right - col_w, ry + 36.0), number(int(row.get(str(cols[i]["id"]), 0))), 26,
				style.color("text") if alive else style.color("dead"), HORIZONTAL_ALIGNMENT_RIGHT, col_w)
		ry += ROW_H
		n += 1
	root.draw_line(Vector2(x, ry + 2.0), Vector2(x + inner_w, ry + 2.0), Color(style.color("button_border"), 0.4), 1.0)
	style.draw_text(root, Vector2(x + 22.0, ry + 32.0), style.text("total"), 19, style.color("text_dim"))
	for i: int in cols.size():
		var right: float = x + PLAYER_COL_W + (i + 1) * col_w
		style.draw_text(root, Vector2(right - col_w, ry + 32.0), number(int(totals.get(str(cols[i]["id"]), 0))), 21,
			style.color("text_dim"), HORIZONTAL_ALIGNMENT_RIGHT, col_w)
	return ry + 44.0


## A dark band across the screen, fading out toward both sides (banners over the arena).
func _draw_band(y: float, h: float, alpha: float) -> void:
	var w: float = root.size.x
	var dark: Color = Color(0, 0, 0, 0.62 * alpha)
	var clear: Color = Color(0, 0, 0, 0.0)
	var mid_l: float = w * 0.3
	var mid_r: float = w * 0.7
	root.draw_polygon(PackedVector2Array([Vector2(0, y), Vector2(mid_l, y), Vector2(mid_l, y + h), Vector2(0, y + h)]),
		PackedColorArray([clear, dark, dark, clear]))
	root.draw_rect(Rect2(mid_l, y, mid_r - mid_l, h), dark)
	root.draw_polygon(PackedVector2Array([Vector2(mid_r, y), Vector2(w, y), Vector2(w, y + h), Vector2(mid_r, y + h)]),
		PackedColorArray([dark, clear, clear, dark]))
	var edge: Color = Color(style.color("accent"), 0.45 * alpha)
	for ey: float in [y, y + h]:
		root.draw_polygon(PackedVector2Array([Vector2(w * 0.2, ey), Vector2(w * 0.5, ey - 1), Vector2(w * 0.8, ey),
			Vector2(w * 0.5, ey + 1)]), PackedColorArray([Color(edge, 0.0), edge, Color(edge, 0.0), edge]))


func _dim() -> void:
	root.draw_rect(Rect2(Vector2.ZERO, root.size), style.color("dim"))


func _centered(baseline: float, s: String, size: int, col: Color, face_name: StringName = &"text") -> void:
	style.draw_text(root, Vector2(0, baseline), s, size, col, HORIZONTAL_ALIGNMENT_CENTER, root.size.x, face_name)


func _outcome_text() -> String:
	var o: String = flow.outcome()
	return style.text(o) if o != "" else ""


func _outcome_color() -> Color:
	var o: String = flow.outcome()
	return style.color(o) if o != "" else style.color("text")


func _reason_text() -> String:
	match flow.end_reason:
		"time_limit":
			return style.text("reason_time_limit")
		"team_eliminated":
			match flow.outcome():
				"victory":
					return style.text("reason_enemy_eliminated")
				"defeat":
					return style.text("reason_team_eliminated")
				_:
					return style.text("reason_both_eliminated")
	return ""


## The failure screen's explanation for a MatchFlow failure reason.
func failure_text(reason: String) -> String:
	if reason.begins_with("rejected"):
		return style.text("failed_rejected")
	match reason:
		"server_lost":
			return style.text("failed_server_lost")
		"server_silent":
			return style.text("failed_silent")
		"start":
			return style.text("failed_start")
	return style.text("failed_disconnected")


## 1234567 -> "1,234,567".
static func number(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
