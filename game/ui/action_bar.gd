class_name ActionBar
extends Control
## One action bar of up to 12 buttons (backlog M1-27), drawn in a single control: ability icon,
## cooldown sweep and seconds, GCD sweep, tinting (red out of range, blue short of resource, gray
## when unusable), a pulsing gold glow while a conditional ability (execute) is usable, a
## school-colored glow when a cooldown comes off (X-03), and the keybind label from the keybind
## profile. A left click on a button emits slot_pressed.
##
## Size, columns and spacing come from the layout element (data/hud_layouts); the slot's
## keybind action is <action_prefix><n>, or the ability's own action when the profile binds one
## (Break Free).

signal slot_pressed(index: int)

const FLASH_S: float = 0.18
const READY_GLOW_S: float = 0.7

var style: HudStyle
var element: Dictionary
var slots: Array[Dictionary] = []  ## {ability, action, label, state}
var button_px: float = 50.0
var spacing: float = 5.0
var columns: int = 12
var _flash: Dictionary = {}  ## slot index -> seconds left
var _ready_glow: Dictionary = {}  ## slot index -> seconds left of the off-cooldown glow
var _cooling: Dictionary = {}  ## slot index -> true while its own cooldown ran at the last refresh
var _time: float = 0.0  ## seconds, for the highlight pulse


func setup(p_style: HudStyle, p_element: Dictionary, abilities: Array) -> void:
	style = p_style
	element = p_element
	button_px = float(element.get("button_px", 50))
	spacing = float(element.get("spacing_px", 5))
	var n: int = int(element.get("buttons", 12))
	columns = clampi(int(element.get("columns", n)), 1, n)
	slots.clear()
	for i: int in n:
		var ability: String = str(abilities[i]) if i < abilities.size() else ""
		var action: String = "%s%d" % [element.get("action_prefix", "bar1_slot"), i + 1]
		if ability != "" and InputMap.has_action(ability) and not InputMap.action_get_events(ability).is_empty():
			action = ability  # an ability with a bind of its own (Break Free: Shift+R)
		slots.append({"ability": ability, "action": action, "label": style.short_key(Keybinds.label(action)),
			"state": {}})
	var rows: int = ceili(float(n) / columns)
	custom_minimum_size = Vector2(columns * button_px + (columns - 1) * spacing, rows * button_px + (rows - 1) * spacing)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP


## Keybind action -> ability for every filled slot (PlayerController.bar_actions).
func actions() -> Dictionary:
	var out: Dictionary = {}
	for s: Dictionary in slots:
		if s["ability"] != "":
			out[s["action"]] = s["ability"]
	return out


## Recompute every button from the view (`target` is the player's target unit, or {}).
func refresh(view: Dictionary, target: Dictionary, cd_starts: Dictionary) -> void:
	for i: int in slots.size():
		var s: Dictionary = slots[i]
		s["state"] = HudLogic.slot_state(s["ability"], view, target, cd_starts) if s["ability"] != "" else {}
		var cooling: bool = float((s["state"] as Dictionary).get("cd_left_s", 0.0)) > 0.0
		if bool(_cooling.get(i, false)) and not cooling:
			_ready_glow[i] = READY_GLOW_S  # the cooldown just came off
		_cooling[i] = cooling
	queue_redraw()


## Flash the button holding `ability` (a key press).
func flash(ability: String) -> void:
	for i: int in slots.size():
		if slots[i]["ability"] == ability:
			_flash[i] = FLASH_S


## Seconds left of slot `i`'s off-cooldown glow (0 when none).
func ready_glow(i: int) -> float:
	return float(_ready_glow.get(i, 0.0))


func tick_flash(delta: float) -> void:
	_time += delta
	for d: Dictionary in [_flash, _ready_glow]:
		for i: int in d.keys():
			d[i] = float(d[i]) - delta
			if float(d[i]) <= 0.0:
				d.erase(i)
	if not _ready_glow.is_empty():
		queue_redraw()


func slot_rect(i: int) -> Rect2:
	var col: int = i % columns
	var row: int = i / columns
	return Rect2(Vector2(col * (button_px + spacing), row * (button_px + spacing)), Vector2(button_px, button_px))


func slot_at(pos: Vector2) -> int:
	for i: int in slots.size():
		if slot_rect(i).has_point(pos):
			return i
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var i: int = slot_at(mb.position)
			if i != -1 and slots[i]["ability"] != "":
				_flash[i] = FLASH_S
				slot_pressed.emit(i)
			accept_event()


func _draw() -> void:
	if style == null:
		return
	for i: int in slots.size():
		_draw_slot(i, slots[i])


func _draw_slot(i: int, s: Dictionary) -> void:
	var r: Rect2 = slot_rect(i)
	draw_rect(r.grow(2.0), style.color("frame_border_dark"))
	draw_rect(r.grow(1.0), style.color("frame_border").darkened(0.3), false, 1.0)
	var ability: String = s["ability"]
	var st: Dictionary = s["state"]
	if ability == "":
		draw_rect(r, Color(0.06, 0.05, 0.045, 0.6))  # empty: no key label, less clutter
		return
	var ab: Dictionary = Data.abilities.get(ability, {})
	var tint: Color = Color.WHITE
	if not bool(st.get("usable", true)):
		tint = Color(0.42, 0.42, 0.42)
	elif not bool(st.get("resource_ok", true)):
		tint = Color(0.45, 0.55, 1.0).darkened(0.25)
	elif not bool(st.get("range", true)):
		tint = Color(1.0, 0.38, 0.32)
	style.icon(self, r, ab.get("icon", {}), str(ab.get("name", ability)), tint)
	if not bool(st.get("usable", true)):
		draw_rect(r, Color(0, 0, 0, 0.35))
	# cooldown sweep (own cooldown) or GCD sweep, whichever ends later
	var cd_left: float = float(st.get("cd_left_s", 0.0))
	if bool(st.get("on_gcd", false)):
		HudStyle.sweep(self, r.grow(-1.0), float(st["gcd_frac"]), Color(0, 0, 0, 0.62))
	elif cd_left > 0.0:
		HudStyle.sweep(self, r.grow(-1.0), float(st["cd_frac"]), Color(0, 0, 0, 0.7))
	if cd_left > 0.0 and cd_left > float(st.get("gcd_left_s", 0.0)):
		var fsz: int = style.fs("large") if cd_left < 100.0 else style.fs("normal")
		style.text_in(self, r, HudStyle.countdown(cd_left, 0.0), fsz, Color(1.0, 0.95, 0.75), HORIZONTAL_ALIGNMENT_CENTER,
			0.0, &"display")
	if bool(st.get("highlight", false)) and cd_left <= 0.0:
		# a usable conditional ability (execute): a gold border with a pulsing outer glow
		var pulse: float = 0.5 + 0.5 * sin(_time * TAU * 1.4)
		_glow(r, Color(1.0, 0.82, 0.3), 0.45 + 0.4 * pulse)
		draw_rect(r.grow(-1.0), Color(1.0, 0.85, 0.3), false, 3.0)
	if _ready_glow.has(i) and cd_left <= 0.0:
		# off cooldown: a bright school-colored glow that fades out and spreads
		var k: float = clampf(float(_ready_glow[i]) / READY_GLOW_S, 0.0, 1.0)
		var gc: Color = style.icon_base(ab.get("icon", {}), str(ab.get("name", ""))).lerp(Color.WHITE, 0.45)
		_glow(r.grow((1.0 - k) * 3.0), gc, k)
		draw_rect(r, Color(1, 1, 1, 0.22 * k * k))
	if _flash.has(i):
		draw_rect(r, Color(1, 1, 1, 0.35 * float(_flash[i]) / FLASH_S))
	_label(r, s, not bool(st.get("range", true)))


## A soft glow around `r`: rings fading outward, `strength` 0..1.
func _glow(r: Rect2, col: Color, strength: float) -> void:
	for j: int in 4:
		var c: Color = col
		c.a = strength * (0.85 - j * 0.2)
		draw_rect(r.grow(1.0 + j * 1.5), c, false, 2.0)


func _label(r: Rect2, s: Dictionary, out_of_range: bool) -> void:
	var label: String = s["label"]
	if label == "":
		return
	var col: Color = Color(1.0, 0.35, 0.3) if out_of_range else style.color("text")
	var fsz: int = style.fs("small")
	style.text(self, Vector2(r.position.x + 2.0, r.position.y + style.font.get_ascent(fsz) + 1.0), label, fsz, col,
		HORIZONTAL_ALIGNMENT_RIGHT, r.size.x - 5.0, 3)
