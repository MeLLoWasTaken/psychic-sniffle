class_name Hud
extends CanvasLayer
## The basic arena HUD (backlog M1-27), built from a HUD layout (data/hud_layouts/<id>.json,
## picked by the settings profile's interface.hud_layout): two action bars, a player cast bar,
## player, target, focus, party and arena enemy frames, the match timer with dampening, the
## loss-of-control alert and floating combat text. Every element's type, anchor, offset, scale,
## opacity and size is data, so the M2 edit mode moves things by editing a copy of the layout.
##
## Reads only the world view and combat events (the shapes MatchRunner.view_for / take_events
## and the network client produce), plus the PlayerController for the target, focus and ability
## presses, so it works the same in practice and online.
##
##   var hud: Hud = Hud.new(settings)       # settings: a data/settings profile
##   add_child(hud)
##   hud.bind(controller, camera, renderer) # renderer: positions for combat text, audio for clicks
##   hud.push(view, events)                 # once per simulation tick
##   hud.update(delta)                      # every frame
##
## Scaling: positions and sizes are logical pixels on the layout's base resolution (1920x1080,
## the project's canvas_items stretch base), so the HUD keeps its proportions at 1280x720,
## 1920x1080 and 2560x1440. On top, the whole HUD scales by the interface ui_scale setting, and
## grows further when its smallest text would fall below min_text_px screen pixels.

const ANCHORS: Dictionary = {
	"top_left": Vector2(0, 0), "top_center": Vector2(0.5, 0), "top_right": Vector2(1, 0),
	"center_left": Vector2(0, 0.5), "center": Vector2(0.5, 0.5), "center_right": Vector2(1, 0.5),
	"bottom_left": Vector2(0, 1), "bottom_center": Vector2(0.5, 1), "bottom_right": Vector2(1, 1),
}
const PHYSICAL_TEXT: Color = Color(1.0, 0.95, 0.82)

var layout: Dictionary = {}
var interface: Dictionary = {}
var style: HudStyle
var root: Control
var elements: Dictionary = {}  ## element id -> Control, or Array of UnitFrame for party/arena
var bars: Dictionary = {}  ## action bar element id -> ActionBar
var controller: PlayerController
var renderer: WorldRenderer
var view: Dictionary = {}
var spec_id: String = ""
var clock: float = 0.0  ## seconds of HUD time (holds for failures)
var cd_starts: Dictionary = {}
var break_free: Dictionary = {}  ## unit id -> {ready_tick, total_ticks}
var failures: Dictionary = {}  ## unit id -> {text, until_s}
var stretch_override: float = 0.0  ## tests: screen pixels per logical pixel (0 = from the window)
var scale_used: float = 1.0  ## the HUD scale the last layout used
var clicks: int = 0  ## interface clicks played (tests)
var _laid_out_size: Vector2 = Vector2.ZERO
var _laid_out_stretch: float = 0.0


func _init(settings: Dictionary = {}, layout_id: String = "") -> void:
	layer = 10
	interface = settings.get("interface", {"hud_layout": "default", "ui_scale": 1.0, "min_text_px": 11, "combat_text": true})
	var lid: String = layout_id if layout_id != "" else str(interface.get("hud_layout", "default"))
	layout = Data.hud_layouts.get(lid, {})
	if layout.is_empty():
		Log.error("hud: no layout '%s'" % lid)
		return
	style = HudStyle.new(layout)
	root = Control.new()
	root.name = "HudRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_build()


func _build() -> void:
	var els: Dictionary = layout.get("elements", {})
	for id: String in els:
		var e: Dictionary = els[id]
		var ctrl: Variant = null
		match str(e["type"]):
			"action_bar":
				var b: ActionBar = ActionBar.new()
				b.setup(style, e, [])
				b.slot_pressed.connect(_on_slot_pressed.bind(id))
				bars[id] = b
				ctrl = b
			"unit_frame":
				var frames: Array = []
				for i: int in int(e.get("count", 1)):
					var f: UnitFrame = UnitFrame.new()
					f.setup(style, e)
					f.clicked.connect(_on_frame_clicked)
					f.visible = false
					frames.append(f)
				ctrl = frames
			"cast_bar":
				var cb: CastBar = CastBar.new()
				cb.setup(style, e)
				cb.visible = false
				ctrl = cb
			"match_timer":
				var mt: MatchTimer = MatchTimer.new()
				mt.setup(style, e)
				ctrl = mt
			"loss_of_control":
				var lc: LossOfControlAlert = LossOfControlAlert.new()
				lc.setup(style, e)
				ctrl = lc
			"combat_text":
				var ct: CombatText = CombatText.new()
				ct.setup(style, e)
				ct.visible = bool(interface.get("combat_text", true))
				ctrl = ct
		if ctrl == null:
			continue
		elements[id] = ctrl
		for c: Control in (ctrl if ctrl is Array else [ctrl]):
			c.name = id if not ctrl is Array else "%s_%d" % [id, (ctrl as Array).find(c) + 1]
			c.modulate.a = float(e.get("opacity", 1.0))
			if not bool(e.get("visible", true)):
				c.visible = false
			root.add_child(c)
	# combat text sits behind the frames
	for c: Control in _all_of_type("combat_text"):
		root.move_child(c, 0)


## Connect the player's controller (target, focus, presses), the camera the player sees through
## and the world renderer (drawn unit positions for combat text, audio director for clicks).
func bind(p_controller: PlayerController, camera: Camera3D = null, p_renderer: WorldRenderer = null) -> void:
	controller = p_controller
	renderer = p_renderer
	if controller and not controller.ability_pressed.is_connected(_on_ability_pressed):
		controller.ability_pressed.connect(_on_ability_pressed)
	for ct: CombatText in _all_of_type("combat_text"):
		ct.camera = camera
		if renderer != null:
			ct.position_of = renderer.drawn_position
	_sync_bar_actions()


## Take one tick's world view and its combat events.
func push(v: Dictionary, events: Array = []) -> void:
	if v.is_empty() or style == null:
		return
	view = v
	var me: Dictionary = v["me"]
	if str(me.get("spec", "")) != spec_id:
		_assign_bars(str(me["spec"]))
	HudLogic.update_cooldown_starts(v, cd_starts)
	for ev: Dictionary in events:
		_on_event(ev)


## Redraw everything for this frame; `delta` is the frame time.
func update(delta: float) -> void:
	if style == null:
		return
	clock += delta
	if root.size != _laid_out_size or _stretch() != _laid_out_stretch:
		relayout()
	for ct: CombatText in _all_of_type("combat_text"):
		ct.advance(delta)
	for b: ActionBar in bars.values():
		b.tick_flash(delta)
	if view.is_empty():
		return
	var me: Dictionary = view["me"]
	var target: Dictionary = unit_by_id(target_id())
	for b: ActionBar in bars.values():
		b.refresh(view, target, cd_starts)
	var els: Dictionary = layout["elements"]
	for id: String in elements:
		var e: Dictionary = els[id]
		match str(e["type"]):
			"unit_frame":
				_update_frames(id, e)
			"cast_bar":
				var u: Dictionary = me if str(e.get("unit", "player")) == "player" else unit_by_id(target_id())
				(elements[id] as CastBar).set_unit(u, view, failures.get(int(u.get("id", -1)), {}), clock)
				if not bool(e.get("visible", true)):
					(elements[id] as CastBar).visible = false
			"match_timer":
				(elements[id] as MatchTimer).set_view(view)
			"loss_of_control":
				(elements[id] as LossOfControlAlert).set_view(view)


## The player's target: the controller's, else the server's (a bot-played player unit).
func target_id() -> int:
	if controller != null and controller.target_id >= 0:
		return controller.target_id
	return int(view.get("me", {}).get("target_id", -1))


func focus_id() -> int:
	return controller.focus_id if controller else -1


## A unit of the newest view by id, or {}.
func unit_by_id(id: int) -> Dictionary:
	if id < 0:
		return {}
	for u: Dictionary in view.get("units", []):
		if int(u["id"]) == id:
			return u
	return {}


## The units each frame group shows: "party" (allies but the player) or "arena" (enemies), by id.
func group_units(kind: String) -> Array:
	if view.is_empty():
		return []
	var my_team: int = int(view["me"]["team"])
	var my_id: int = int(view["me"]["id"])
	var out: Array = []
	for u: Dictionary in view.get("units", []):
		var ally: bool = int(u["team"]) == my_team
		if (kind == "party" and ally and int(u["id"]) != my_id) or (kind == "arena" and not ally):
			out.append(u)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	return out


func _update_frames(id: String, e: Dictionary) -> void:
	var frames: Array = elements[id]
	var kind: String = str(e.get("unit", "player"))
	var units: Array = []
	match kind:
		"player":
			units = [view["me"]]
		"target":
			units = [unit_by_id(target_id())]
		"focus":
			units = [unit_by_id(focus_id())]
		_:
			units = group_units(kind)
	var my_team: int = int(view["me"]["team"])
	for i: int in frames.size():
		var f: UnitFrame = frames[i]
		var u: Dictionary = units[i] if i < units.size() else {}
		if kind == "arena":
			f.prefix = str(i + 1)
		var uid: int = int(u.get("id", -1))
		var sel: bool = kind in ["party", "arena"] and uid != -1 and uid == target_id()
		f.set_unit(u, view, not u.is_empty() and int(u["team"]) != my_team, sel, failures.get(uid, {}), clock,
			break_free.get(uid, {}))
		if not bool(e.get("visible", true)):
			f.visible = false


# ------------------------------------------------------------------ action bars and presses

func _assign_bars(p_spec: String) -> void:
	spec_id = p_spec
	var assignment: Dictionary = HudLogic.bar_assignment(layout, spec_id)
	for id: String in bars:
		var b: ActionBar = bars[id]
		b.setup(style, layout["elements"][id], assignment.get(id, []))
	_sync_bar_actions()
	_laid_out_size = Vector2.ZERO  # sizes may change: lay out again


func _sync_bar_actions() -> void:
	if controller == null:
		return
	var map: Dictionary = {}
	for id: String in layout.get("action_bars", {}).get("fill_order", bars.keys()):
		if bars.has(id):
			map.merge((bars[id] as ActionBar).actions())
	controller.bar_actions = map


func _on_slot_pressed(index: int, bar_id: String) -> void:
	var b: ActionBar = bars[bar_id]
	var slot: Dictionary = b.slots[index]
	if controller != null:
		controller.press_ability(str(slot["ability"]), str(slot["action"]))
	_play_click()


func _on_ability_pressed(ability_id: String, _action: String) -> void:
	for b: ActionBar in bars.values():
		b.flash(ability_id)


func _on_frame_clicked(unit_id: int) -> void:
	if controller != null and unit_id >= 0:
		controller.set_target(unit_id)
		_play_click()


func _play_click() -> void:
	clicks += 1
	if renderer != null and renderer.audio != null:
		var id: String = str(renderer.audio.bank.map.get("interface", {}).get("click", "ui_click"))
		renderer.audio.play_ui(id)


# ------------------------------------------------------------------ events

func _on_event(ev: Dictionary) -> void:
	var me_id: int = int(view["me"]["id"])
	var my_team: int = int(view["me"]["team"])
	var src: int = int(ev.get("source", -1))
	var tgt: int = int(ev.get("target", -1))
	var rate: float = float(view.get("tick_rate", 60))
	match str(ev.get("type", "")):
		"damage":
			var amount: int = int(ev.get("amount", 0))
			var absorbed: int = int(ev.get("absorbed", 0))
			var crit: bool = bool(ev.get("crit", false))
			if src == me_id and tgt != me_id:
				var col: Color = PHYSICAL_TEXT if str(ev.get("school", "physical")) == "physical" \
					else HudStyle.school_color(str(ev.get("school", ""))).lightened(0.35)
				if amount > 0:
					_combat_text(tgt, _number(amount) + ("!" if crit else ""), col, crit)
				elif absorbed > 0:
					_combat_text(tgt, "Absorbed", style.color("text_dim"), false)
			elif tgt == me_id and amount > 0:
				_combat_text(me_id, "-" + _number(amount), style.color("damage_taken_text"), crit)
		"heal":
			var amount: int = int(ev.get("amount", 0))
			if amount > 0 and (src == me_id or tgt == me_id):
				_combat_text(tgt, "+" + _number(amount), style.color("heal_text"), bool(ev.get("crit", false)))
		"aura_applied":
			var cat: String = str(ev.get("cc", "none"))
			if style.cc.has(cat) and (src == me_id or tgt == me_id or _team_of(tgt) == my_team):
				_combat_text(tgt, str(style.cc[cat]["label"]), style.cc[cat]["color"], false)
		"immune":
			if src == me_id:
				_combat_text(tgt, "Immune", style.color("text_dim"), false)
		"interrupt":
			failures[tgt] = {"text": "Interrupted", "until_s": clock + CastBar.HOLD_S}
			if src == me_id or tgt == me_id:
				_combat_text(tgt, "Interrupted", Color(1.0, 0.8, 0.3), false)
		"cast_interrupted":
			failures[src] = {"text": "Interrupted", "until_s": clock + CastBar.HOLD_S}
		"cast_failed":
			var reason: String = str(ev.get("reason", ""))
			if src == me_id:
				var msg: String = str(layout.get("error_messages", {}).get(reason, ""))
				if msg != "":
					for ct: CombatText in _all_of_type("combat_text"):
						ct.error(msg)
		"cast_success":
			if str(ev.get("ability", "")) == "break_free":
				var cd: float = float(Data.abilities.get("break_free", {}).get("cooldown_s", 90.0))
				break_free[src] = {"ready_tick": int(ev.get("tick", view["tick"])) + roundi(cd * rate),
					"total_ticks": roundi(cd * rate)}


func _combat_text(unit_id: int, text: String, col: Color, crit: bool) -> void:
	for ct: CombatText in _all_of_type("combat_text"):
		ct.spawn(unit_id, text, col, "combat_text_crit" if crit else "combat_text", crit)


func _team_of(id: int) -> int:
	return int(unit_by_id(id).get("team", -99))


static func _number(v: int) -> String:
	var s: String = str(absi(v))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


# ------------------------------------------------------------------ layout and scaling

## Screen pixels per logical pixel (1920x1080 base under the project's canvas_items stretch).
func _stretch() -> float:
	if stretch_override > 0.0:
		return stretch_override
	if not is_inside_tree():
		return 1.0
	var logical: Vector2 = root.get_viewport_rect().size
	var physical: Vector2 = Vector2(get_viewport().get_window().size) if get_viewport() is Window else logical
	if logical.x <= 0.0 or physical.x <= 0.0:
		return 1.0
	return minf(physical.x / logical.x, physical.y / logical.y)


## The HUD scale: ui_scale, grown so the smallest text reaches min_text_px on screen.
func hud_scale() -> float:
	var ui: float = float(interface.get("ui_scale", 1.0))
	var min_px: float = float(interface.get("min_text_px", 0.0))
	var smallest_on_screen: float = style.smallest_font() * ui * _stretch()
	return ui * maxf(1.0, min_px / maxf(smallest_on_screen, 0.01))


## Place every element for the current screen size and scale.
func relayout() -> void:
	var screen: Vector2 = root.size
	if screen.x <= 0.0 or screen.y <= 0.0:
		screen = Vector2(layout.get("base_resolution", [1920, 1080])[0], layout.get("base_resolution", [1920, 1080])[1])
	var s: float = hud_scale()
	scale_used = s
	var els: Dictionary = layout["elements"]
	for id: String in elements:
		var e: Dictionary = els[id]
		if str(e["type"]) == "combat_text":
			var ct: CombatText = elements[id]
			ct.position = Vector2.ZERO
			ct.size = screen
			ct.ui_scale = s
			continue
		var k: float = s * float(e.get("scale", 1.0))
		var a: Vector2 = ANCHORS.get(str(e["anchor"]), Vector2.ZERO)
		var off: Vector2 = Vector2(float(e["offset"][0]), float(e["offset"][1])) * s
		var ctrls: Array = elements[id] if elements[id] is Array else [elements[id]]
		for i: int in ctrls.size():
			var c: Control = ctrls[i]
			c.scale = Vector2(k, k)
			var step: Vector2 = Vector2(0.0, (c.size.y + float(e.get("spacing_px", 0.0))) * k * i)
			c.position = (screen * a + off - c.size * k * a + step).round()
	# the combat text layer is placed after the timer it sits under
	for id: String in elements:
		if str(els[id]["type"]) == "combat_text":
			var ct: CombatText = elements[id]
			var timer_bottom: float = 0.0
			for mt: MatchTimer in _all_of_type("match_timer"):
				timer_bottom = maxf(timer_bottom, mt.position.y + mt.size.y * mt.scale.y)
			ct.error_y = timer_bottom + style.fs("large") * s + 12.0 * s
	_laid_out_size = root.size
	_laid_out_stretch = _stretch()


## Screen rectangles of every element, with everything it may draw around it (edit mode
## outlines, overlap tests).
func element_rects() -> Dictionary:
	var out: Dictionary = {}
	for id: String in elements:
		var ctrls: Array = elements[id] if elements[id] is Array else [elements[id]]
		for i: int in ctrls.size():
			var c: Control = ctrls[i]
			if c is CombatText:
				continue
			var ext: Rect2 = (c as UnitFrame).extent() if c is UnitFrame else Rect2(Vector2.ZERO, c.size)
			out["%s_%d" % [id, i + 1] if elements[id] is Array else id] = Rect2(c.position + ext.position * c.scale,
				ext.size * c.scale)
	return out


func _all_of_type(kind: String) -> Array:
	var out: Array = []
	for id: String in elements:
		if str(layout["elements"][id]["type"]) == kind:
			out.append(elements[id])
	return out
