class_name ScriptedPilot
extends RefCounted
## Plays the player's unit through the player's own controls, for automated runs of the real
## match flow (backlog M1-28: the end-to-end test and the screenshots). Each tick it decides like
## a bot (a BotBrain reading the same world view the HUD draws) and turns that decision into what
## a person would do with keyboard and mouse:
##
## - movement: W held while the bot walks, released when it stops;
## - facing: the right mouse button held (steering) and mouse motion that turns the character to
##   the bot's facing, exactly as a right-drag does;
## - target: Tab when there is no enemy target; a click on the unit's frame (the HUD's frame click,
##   PlayerController.set_target) when the bot wants a particular unit, allies included;
## - abilities: the action bar key of the chosen ability (the HUD's bar assignment, read back
##   from PlayerController.bar_actions).
##
## Nothing bypasses PlayerController: events go through handle_event() and the tick's input is
## still PlayerController.next_input(), so the server receives what a person's keys would send.
##
##   var pilot: ScriptedPilot = ScriptedPilot.new(controller, spec_id, geometry)
##   for ev: InputEvent in pilot.events_for(view): controller.handle_event(ev)

var controller: PlayerController
var brain: BotBrain
var sensitivity: float = deg_to_rad(0.25)
var presses: int = 0  ## bar keys pressed
var unmapped: int = 0  ## abilities the bot wanted that have no bar key
var tabs: int = 0  ## Tab presses
var frame_clicks: int = 0  ## unit frame clicks (targets chosen for the bot's press)
var _walking: bool = false
var _steering: bool = false


func _init(p_controller: PlayerController, spec_id: String, geometry: ArenaGeometry, seed_value: int = 1) -> void:
	controller = p_controller
	sensitivity = controller.sensitivity
	brain = BotBrain.new(spec_id, seed_value, geometry)


## The input events for this tick (the caller feeds them to the controller before next_input()).
## Target changes made by clicking a unit frame are applied to the controller directly, as the
## HUD's frame click does.
func events_for(view: Dictionary) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	if view.is_empty():
		return out
	var me: Dictionary = view["me"]
	var active: bool = int(view["match"].get("phase", ArenaMatch.Phase.PREP)) == ArenaMatch.Phase.ACTIVE
	if not active or int(me["health"]) <= 0:
		release(out)
		return out
	var d: Dictionary = brain.next_input(view)
	# hold the right button once: from then on mouse motion steers the character
	if not _steering:
		out.append(_action("camera_steer", true))
		_steering = true
	var turn: float = wrapf(controller.yaw - float(d["yaw"]), -PI, PI)
	if absf(turn) > 1e-4:
		var mm: InputEventMouseMotion = InputEventMouseMotion.new()
		mm.relative = Vector2(turn / sensitivity, 0.0)
		out.append(mm)
	var walk: bool = (d["move"] as Vector2).y > 0.5
	if walk != _walking:
		out.append(_action("move_forward", walk))
		_walking = walk
	# target: the unit the bot presses on, else the one it attacks
	var want: int = int(d.get("target", -1))
	var ability: String = str(d.get("ability", ""))
	var action: String = _action_for(ability) if ability != "" else ""
	if ability != "" and action == "":
		unmapped += 1
	if want >= 0 and want != controller.target_id:
		if action == "" and controller.target_id < 0 and not _is_ally(view, want):
			# nothing targeted: Tab picks the enemy in front (the bot faces its target)
			out.append(_action("target_nearest_enemy", true))
			out.append(_action("target_nearest_enemy", false))
			tabs += 1
		else:
			controller.set_target(want)
			frame_clicks += 1
	if action != "":
		out.append(_action(action, true))
		out.append(_action(action, false))
		presses += 1
	return out


## Let go of every key and button the pilot holds (the match ended, the unit died).
func release(out: Array[InputEvent]) -> void:
	if _walking:
		out.append(_action("move_forward", false))
		_walking = false
	if _steering:
		out.append(_action("camera_steer", false))
		_steering = false


func _action_for(ability: String) -> String:
	for action: String in controller.bar_actions:
		if str(controller.bar_actions[action]) == ability:
			return action
	return ""


static func _is_ally(view: Dictionary, id: int) -> bool:
	for u: Dictionary in view["units"]:
		if int(u["id"]) == id:
			return int(u["team"]) == int(view["me"]["team"])
	return false


static func _action(action: String, pressed: bool) -> InputEventAction:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	return ev
