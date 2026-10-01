extends Node3D
## Practice arena (backlog M1-23): a 2v2 on Gallows Courtyard run in-process, the player's unit
## under PlayerController, the other three played by bots, drawn by WorldRenderer through the
## third-person camera.
##
## Layers: LocalMatch (simulation; M1-28 swaps in the network client) -> world view dictionary
## -> WorldRenderer (characters, target ring) and PlayerController (input dict back into the
## simulation). The simulation runs at the tuning's tick rate; drawing interpolates between ticks.
##
##   godot --path game res://scenes/game/practice.tscn -- [--spec warblade_carnage]
##     [--ally oracle_grace] [--enemies arcanist_rime,oracle_grace] [--map gallows_courtyard]
##     [--prep 0] [--seed 1] [--settings default] [--keybinds default]
##     [--auto "move_forward:3,target_nearest_enemy"]   scripted input, in simulation time
##     [--fast-forward 3] [--pause]   run the first seconds at once (then hold still: screenshots)
##     [--seconds 10]                 quit after this much simulation time (headless checks)
##     [--player-bot]                 the player's unit is played by its bot (a real fight to watch)
##     [--follow arcanist_rime] [--cam-yaw 90] [--cam-pitch 10] [--cam-zoom -2]
##                                    camera framing for screenshots: follow another unit (looking
##                                    along its facing), orbit by degrees, pitch, wheel notches
##     [--no-kit] [--no-gi] [--no-hud]
## Tests set `options` before adding the scene to the tree and step it with run_ticks().

## Defaults for every option; the command line (or a test) overrides them.
const DEFAULTS: Dictionary = {
	"spec": "warblade_carnage", "ally": "oracle_grace", "enemies": "arcanist_rime,oracle_grace",
	"map": "gallows_courtyard", "prep": 0.0, "seed": 1, "settings": "default", "keybinds": "default",
	"auto": "", "fast_forward": 0.0, "pause": false, "seconds": 0.0, "kit": true, "gi": true,
	"lighting": true, "manual": false, "player_bot": false, "talents": "", "follow": "", "cam_yaw": 0.0, "cam_pitch": "",
	"cam_zoom": 0, "hud": true,
}
const MAX_FRAME_S: float = 0.25  ## longer frames are clamped, so a stall never runs away

var options: Dictionary = {}
var world: LocalMatch
var builder: MapBuilder
var renderer: WorldRenderer
var cam: ThirdPersonCamera
var controller: PlayerController
var scripted: ScriptedInput
var hud: Hud  ## the HUD (M1-27), fed the same views and events as the renderer; null with --no-hud
var sim_time: float = 0.0
var paused: bool = false
var start_position: Vector3

var _accum: float = 0.0
var _gates_opened: bool = false
var _synced: bool = false
var _cursor_restore: Vector2 = Vector2.ZERO


func _ready() -> void:
	var opts: Dictionary = DEFAULTS.duplicate()
	opts.merge(options if not options.is_empty() else _options_from_args(), true)
	options = opts
	if str(options["keybinds"]) == "default":
		Keybinds.load_user()  # the player's own binds (the keybinding screen), else the default
	else:
		Keybinds.load_profile(str(options["keybinds"]))
	var settings: Dictionary = Data.settings.get(str(options["settings"]), {})
	if settings.is_empty():
		Log.error("practice: no settings profile '%s'" % options["settings"])
	var enemies: PackedStringArray = str(options["enemies"]).split(",", false)
	var allies: PackedStringArray = str(options["ally"]).split(",", false)
	world = LocalMatch.new(str(options["map"]), str(options["spec"]), Array(allies), Array(enemies),
		"%dv%d" % [allies.size() + 1, enemies.size()], float(options["prep"]), int(options["seed"]),
		bool(options["player_bot"]), str(options["talents"]))
	start_position = world.player.position

	var map: Dictionary = Data.maps[str(options["map"])]
	builder = (load(map.get("scene", "res://scenes/maps/gallows_courtyard.tscn")) as PackedScene).instantiate()
	builder.map_id = str(options["map"])
	builder.use_kit = bool(options["kit"])
	builder.bake_gi = bool(options["gi"])
	builder.build_lighting = bool(options["lighting"])
	add_child(builder)
	builder.set_gates_open(false, 0.0)

	renderer = WorldRenderer.new()
	renderer.name = "World"
	add_child(renderer)
	controller = PlayerController.new(settings)
	cam = ThirdPersonCamera.new(settings.get("camera", {}))
	cam.name = "PlayerCamera"
	cam.geometry = world.geometry()
	add_child(cam)
	cam.camera.current = true
	cam.zoom_steps(int(options["cam_zoom"]))
	if str(options["cam_pitch"]) != "":
		controller.pitch = clampf(deg_to_rad(float(options["cam_pitch"])), controller.pitch_min, controller.pitch_max)
	scripted = ScriptedInput.new(str(options["auto"]))
	if bool(options["hud"]):
		hud = Hud.new(settings)
		hud.set_loadout(str(options["spec"]), str(options["talents"]))
		add_child(hud)
		hud.bind(controller, cam.camera, renderer)

	renderer.push_view(world.view())
	var ff_ticks: int = roundi(float(options["fast_forward"]) * world.tick_rate())
	if ff_ticks > 0:
		run_ticks(ff_ticks)
		paused = bool(options["pause"])
	_draw_frame(0.0, true)
	Log.info("practice: %s as %s with %s vs %s" % [options["map"], options["spec"], options["ally"], options["enemies"]])


func _options_from_args() -> Dictionary:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var out: Dictionary = {}
	for key: String in ["spec", "ally", "enemies", "map", "settings", "keybinds", "auto", "follow", "cam_pitch"]:
		var v: String = _arg(args, "--" + key.replace("_", "-"), "")
		if v != "":
			out[key] = v
	for key: String in ["prep", "fast_forward", "seconds", "cam_yaw", "cam_zoom"]:
		var v: String = _arg(args, "--" + key.replace("_", "-"), "")
		if v != "":
			out[key] = float(v)
	var seed_arg: String = _arg(args, "--seed", "")
	if seed_arg != "":
		out["seed"] = int(seed_arg)
	out["pause"] = "--pause" in args
	out["player_bot"] = "--player-bot" in args
	out["kit"] = not ("--no-kit" in args)
	out["gi"] = not ("--no-gi" in args)
	out["hud"] = not ("--no-hud" in args)
	return out


func _process(delta: float) -> void:
	if bool(options["manual"]):
		return
	if not paused:
		_accum += minf(delta, MAX_FRAME_S)
		while _accum >= world.dt():
			_accum -= world.dt()
			_tick()
	_draw_frame(delta)


## Run whole simulation ticks at once (fast-forward, tests), drawing once at the end.
func run_ticks(n: int) -> void:
	for i: int in n:
		_tick()
		_draw_frame(world.dt())


func _tick() -> void:
	for ev: InputEvent in scripted.events_until(sim_time):
		controller.handle_event(ev)
	var v: Dictionary = world.view()
	if not _synced:
		controller.reset_facing(float(v["me"]["facing"]))
		_synced = true
	var inp: Dictionary = controller.next_input(world.dt(), v, cam.camera, renderer.drawn_units(), world.geometry())
	world.step(inp)
	sim_time += world.dt()
	renderer.push_view(world.view())
	var events: Array = world.take_events()
	renderer.push_events(events)
	if hud != null:
		hud.push(renderer.view, events)
	renderer.target_id = controller.target_id
	var quit_after: float = float(options["seconds"])
	if quit_after > 0.0 and sim_time + 1e-6 >= quit_after and not bool(options["manual"]):
		_finish()


func _draw_frame(delta: float, instant: bool = false) -> void:
	renderer.draw(_accum / world.dt(), 0.0 if paused or instant else delta)  # paused: poses hold
	if hud != null:
		hud.update(0.0 if paused or instant else delta)
	var v: Dictionary = renderer.view
	if not v.is_empty() and builder != null:
		builder.set_pickups(int(v["match"].get("pickups", 0)))
	if not _gates_opened and not v.is_empty() and int(v["match"]["phase"]) != ArenaMatch.Phase.PREP:
		_gates_opened = true
		builder.set_gates_open(true, 0.0 if instant or float(options["fast_forward"]) > 0.0 else 1.5)
	if controller.pending_zoom != 0:
		cam.zoom_steps(controller.pending_zoom)
		controller.pending_zoom = 0
	var watched: int = _followed_id()
	# the player's camera follows the controller; a watched unit (or a bot-played player) its facing
	var own_camera: bool = watched == world.player.id and not bool(options["player_bot"])
	var yaw: float = controller.camera_yaw() if own_camera or not renderer.units.has(watched) \
		else float((renderer.units[watched] as Dictionary)["cur_facing"])
	cam.update(renderer.drawn_position(watched), yaw + deg_to_rad(float(options["cam_yaw"])), controller.pitch,
		delta if not instant else 10.0)


## The unit the camera follows: the player's, or the first unit of the `follow` spec.
func _followed_id() -> int:
	var spec: String = str(options["follow"])
	if spec != "":
		for u: Dictionary in renderer.view.get("units", []):
			if str(u["spec"]) == spec and renderer.units.has(int(u["id"])):
				return int(u["id"])
	return world.player.id


func _unhandled_input(event: InputEvent) -> void:
	if controller == null or not controller.handle_event(event):
		return
	get_viewport().set_input_as_handled()
	# hide and lock the cursor while dragging the camera; put it back where the drag began
	var captured: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if controller.is_dragging() and not captured:
		_cursor_restore = get_viewport().get_mouse_position()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif not controller.is_dragging() and captured and not (controller.steering or controller.orbiting):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.warp_mouse(_cursor_restore)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and controller != null:
		controller.release_all()


## Distance the player's unit has moved from its spawn (flat), for checks.
func player_travel() -> float:
	var p: Vector3 = world.player.position
	return Vector2(p.x - start_position.x, p.z - start_position.z).length()


func _finish() -> void:
	set_process(false)
	Log.info("practice: %.1f s simulated; player moved %.1f m; target %d; %d errors" % [
		sim_time, player_travel(), controller.target_id, Log.error_count])
	get_tree().quit(1 if Log.error_count > 0 else 0)


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
