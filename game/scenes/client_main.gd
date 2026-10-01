extends Control
## Client entry (GameFlow, backlog M1-28): the main menu, and what its buttons start.
##
##   Play 2v2 vs bots -> scenes/game/net_match.tscn (local server, bots, preparation, fight, end
##                       screen); when it exits, back to the menu
##   Practice         -> scenes/game/practice.tscn (offline); Escape with no target opens the
##                       in-match menu, whose Leave returns here
##   Settings         -> the menu's settings panel;  Quit -> quits
##
## Command line (after `--`), for automated runs and screenshots:
##   --spec <id>            preselect a spec           --prep <s>      preparation length
##   --open-settings        open the settings panel at start (screenshots)
##   --no-kit --no-gi --no-hud   lighter arena art     --port-min <n>  local server port range start
##   --pilot                ScriptedPilot plays the player's controls (decides like a bot)
##   --auto <script>        ScriptedInput steps for the player's controls
##   --auto-flow play       click Play (--play play_1v1 for the duel), play the match, click Back to menu on the end screen, then
##                          write --flow-report <abs path> (JSON) and quit (exit 1 on any failure)
##   --scoreboard-s <s>     seconds the end screen stays before the click (default 2)
##   --flow-timeout <s>     give up after this long (default 900)
##   --shot-when <state>    with tools/screenshot.sh's --screenshot: save it when the flow reaches
##                          menu | prep | fight | ended | scoreboard (--shot-delay <s> in that state)
##                          and quit, instead of after a frame count
##   --also-shot prep=<abs>,fight@25=<abs>   extra screenshots on the way (same states; @s sets
##                          the seconds in that state)
##   --render-scale <0.25-1>  draw the 3D scene at this share of the resolution (FSR upscaled; the
##                          HUD stays sharp): reference videos on the software renderer
##   --record <abs>         write the match as drawn (views, events, camera) to a compressed file
##   --playback <abs>       draw such a recording instead of joining a server; with shots pending
##                          it fast-forwards at a tenth of the 3D resolution and slows to real ticks before
##                          each shot (the software renderer takes seconds per frame)

const NET_MATCH: String = "res://scenes/game/net_match.tscn"
const PRACTICE: String = "res://scenes/game/practice.tscn"
const SHOT_DELAYS: Dictionary = {"menu": 1.0, "prep": 3.0, "fight": 15.0, "ended": 1.0, "scoreboard": 1.5}

var menu: MainMenu
var match_scene: Node  ## the running NetMatch, or null
var practice: Node  ## the running practice scene, or null
var talent_screen: TalentScreen  ## the open talent screen, or null
var practice_menu: PauseMenu
var args: PackedStringArray
var last_result: Dictionary = {}
var report: Dictionary = {"clicks": [], "menu_returns": 0}
var extra_options: Dictionary = {}  ## merged into the match and practice options (tests)

var _auto_flow: String = ""
var _clock: float = 0.0
var _auto_step: String = ""
var _step_time: float = 0.0
var _shots: Dictionary = {}  ## flow state -> absolute PNG path still to save
var _shot_delays: Dictionary = {}  ## flow state -> seconds in that state before its shot
var _final_shot: String = ""  ## the state whose shot quits
var _shooting: bool = false


func _ready() -> void:
	args = OS.get_cmdline_user_args()
	var render_scale: float = float(_arg("--render-scale", "1"))
	if render_scale < 1.0:
		get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		get_viewport().scaling_3d_scale = clampf(render_scale, 0.25, 1.0)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # clicks on the arena reach the player controls
	Keybinds.load_user()  # the player's own binds, or the default; the settings panel lists the keys
	if not ("--playback" in args or "--auto-flow" in args):
		Settings.load_user()  # the player's settings (an automated run keeps the data profile)
		var rs: float = float(Settings.get_value("graphics.render_scale", 1.0))
		if _arg("--render-scale", "") == "" and rs < 1.0:  # the command line wins (reference videos)
			get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if bool(Settings.get_value("graphics.fsr", true)) \
				else Viewport.SCALING_3D_MODE_BILINEAR
			get_viewport().scaling_3d_scale = clampf(rs, 0.25, 1.0)
	else:
		Settings.use_data()
	menu = MainMenu.new()
	menu.action_chosen.connect(_on_action)
	add_child(menu)
	var spec: String = _arg("--spec", "")
	if spec != "":
		menu.select_spec(spec)
	practice_menu = PauseMenu.new(menu.style, menu.style.text("leave_practice"))
	practice_menu.visible = false
	practice_menu.resume_pressed.connect(func() -> void: practice_menu.visible = false)
	practice_menu.leave_pressed.connect(_leave_practice)
	add_child(practice_menu)
	if "--open-settings" in args:  # screenshots of the settings panel
		menu.show_settings()
	_auto_flow = _arg("--auto-flow", "")
	if _auto_flow != "":
		_auto_step = "menu"
	_setup_shots()
	Log.info("client: main menu ready")


func _setup_shots() -> void:
	var when: String = _arg("--shot-when", "")
	var main_path: String = _arg("--screenshot", "")
	if when == "" or main_path == "":
		return
	Capture.set_process(false)  # this scene saves the screenshot when the flow gets there
	_final_shot = when
	_shots[when] = main_path
	_shot_delays[when] = float(_arg("--shot-delay", str(SHOT_DELAYS.get(when, 1.0))))
	for part: String in _arg("--also-shot", "").split(",", false):
		var kv: PackedStringArray = part.split("=")
		if kv.size() == 2:
			var st: PackedStringArray = kv[0].split("@")
			_shots[st[0]] = kv[1]
			_shot_delays[st[0]] = float(st[1]) if st.size() > 1 else float(SHOT_DELAYS.get(st[0], 1.0))


func _process(delta: float) -> void:
	_clock += delta
	_step_time += delta
	practice_menu.position = (size - practice_menu.size) * 0.5
	_pace_playback()
	_check_shots()
	if _auto_flow != "":
		_drive(delta)


# ------------------------------------------------------------------ routing

func _on_action(action: String, spec: String) -> void:
	Log.info("client: menu action %s (%s)" % [action, spec])
	match action:
		"play_bots":
			start_match(spec)
		"play_1v1", "play_3v3":
			start_match(spec, action)
		"practice":
			start_practice(spec)
		"settings":
			menu.show_settings()
		"talents":
			show_talents(spec)
		"quit":
			get_tree().quit(0)


## Start a match against bots with a spec and a menu preset ("play_bots" is the 2v2,
## "play_1v1" the duel): the menu hides, the match scene takes over.
func start_match(spec: String, preset: String = "play_bots") -> Node:
	if match_scene != null or practice != null:
		return null
	match_scene = (load(NET_MATCH) as PackedScene).instantiate()
	match_scene.options = _match_options(spec)
	match_scene.options["preset"] = preset
	match_scene.exited.connect(_on_match_exited)
	menu.visible = false
	add_child(match_scene)
	return match_scene


func _match_options(spec: String) -> Dictionary:
	var o: Dictionary = {"spec": spec, "kit": not ("--no-kit" in args), "gi": not ("--no-gi" in args),
		"hud": not ("--no-hud" in args), "pilot": "--pilot" in args, "auto": _arg("--auto", "")}
	if _arg("--prep", "") != "":
		o["prep"] = float(_arg("--prep", ""))
	if _arg("--port-min", "") != "":
		o["port_min"] = int(_arg("--port-min", ""))
	if _arg("--seed", "") != "":
		o["seed"] = int(_arg("--seed", ""))
	o["talents"] = _arg("--talents", TalentLoadouts.new().active_text(spec))
	o["record"] = _arg("--record", "")
	o["playback"] = _arg("--playback", "")
	o.merge(extra_options, true)
	return o


func _on_match_exited(result: Dictionary) -> void:
	last_result = result
	match_scene.queue_free()
	match_scene = null
	_show_menu()


## The talent screen for a spec, over the menu; closing it returns to the menu.
func show_talents(spec: String) -> TalentScreen:
	if talent_screen != null:
		return talent_screen
	talent_screen = TalentScreen.new(spec)
	talent_screen.closed.connect(func(_spec: String, _text: String) -> void:
		talent_screen.queue_free()
		talent_screen = null
		menu.visible = true
		menu.focus_default())
	menu.visible = false
	add_child(talent_screen)
	return talent_screen


func start_practice(spec: String) -> void:
	if match_scene != null or practice != null:
		return
	practice = (load(PRACTICE) as PackedScene).instantiate()
	var o: Dictionary = {"spec": spec, "talents": _arg("--talents", TalentLoadouts.new().active_text(spec)),
		"hud": not ("--no-hud" in args), "kit": not ("--no-kit" in args),
		"gi": not ("--no-gi" in args)}
	o.merge(extra_options, true)
	practice.options = o
	menu.visible = false
	add_child(practice)
	move_child(practice_menu, -1)


func _leave_practice() -> void:
	practice_menu.visible = false
	if practice != null:
		practice.queue_free()
		practice = null
	_show_menu()


func _show_menu() -> void:
	menu.visible = true
	menu.focus_default()
	report["menu_returns"] = int(report["menu_returns"]) + 1
	Log.info("client: main menu ready")


func _input(event: InputEvent) -> void:
	# practice: Escape with no target opens the in-match menu (the practice controller would only
	# clear the target); a second Escape closes it
	if practice == null or not InputMap.has_action("clear_target") or not event.is_action_pressed("clear_target"):
		return
	if practice_menu.visible:
		practice_menu.visible = false
	elif practice.controller.target_id == -1:
		practice_menu.visible = true
		practice.controller.release_all()
		practice_menu.focus_first()
	else:
		return
	get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ automation

## Click a control the way a person would: a left-button press and release at its centre.
## Returns true when the click reached it (a Button emitted `pressed`).
func click(target: Control, label: String) -> bool:
	var hit: Array = [false]
	var on_press: Callable = func() -> void: hit[0] = true
	var b: BaseButton = target as BaseButton
	if b != null:
		b.pressed.connect(on_press)
	var at: Vector2 = target.get_global_transform_with_canvas() * (target.size * 0.5)
	for pressed: bool in [true, false]:
		var ev: InputEventMouseButton = InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		get_viewport().push_input(ev, true)
	if b != null and b.pressed.is_connected(on_press):
		b.pressed.disconnect(on_press)
	(report["clicks"] as Array).append({"control": label, "at": [at.x, at.y], "hit": hit[0]})
	if not hit[0]:
		Log.error("client: automated click on %s at %s did not reach it" % [label, at])
	return hit[0]


func _drive(_delta: float) -> void:
	if _clock > float(_arg("--flow-timeout", "900")):
		_fail_auto("timed out in step '%s'" % _auto_step)
		return
	match _auto_step:
		"menu":
			if _step_time < 0.5:
				return
			var spec: String = _arg("--spec", menu.spec)
			if menu.cards.has(spec) and spec != menu.spec:
				click(menu.cards[spec], "spec card %s" % spec)
			var play: String = _arg("--play", "play_bots")  # the button to press: play_bots (2v2) or play_1v1
			if not menu.buttons.has(play) or not click(menu.buttons[play], play):
				_fail_auto("the Play button did not take the click")
				return
			_go_step("match")
		"match":
			if match_scene == null:
				_fail_auto("the match scene did not start")
				return
			var flow: MatchFlow = match_scene.flow
			if flow.state == MatchFlow.State.FAILED:
				_fail_auto("the match failed: %s" % flow.failure)
				return
			if flow.state == MatchFlow.State.SCOREBOARD and flow.time_in_state() >= float(_arg("--scoreboard-s", "2")):
				report["scoreboard_seen"] = true
				click(match_scene.screens.back_button, "Back to menu")
				_go_step("returning")
		"returning":
			if match_scene == null and menu.visible:
				_go_step("menu_again")
			elif _step_time > 30.0:
				_fail_auto("did not get back to the menu")
		"menu_again":
			if _step_time >= 0.5:
				_write_report(true, "")


func _go_step(step: String) -> void:
	Log.info("client: auto flow step %s" % step)
	_auto_step = step
	_step_time = 0.0


func _fail_auto(why: String) -> void:
	Log.error("client: auto flow failed: %s" % why)
	if match_scene != null:
		match_scene.leave()
		last_result = match_scene.result
	_write_report(false, why)


func _write_report(ok: bool, why: String) -> void:
	_auto_flow = ""
	report["ok"] = ok and Log.error_count == 0
	report["failure"] = why
	report["menu_visible"] = menu.visible
	report["result"] = last_result
	report["log_errors"] = Log.error_count
	report["log_warnings"] = Log.warn_count
	report["seconds"] = _clock
	var path: String = _arg("--flow-report", "")
	if path != "":
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	Log.info("client: auto flow %s after %.0f s%s" % ["passed" if report["ok"] else "FAILED", _clock,
		"" if why == "" else " (%s)" % why])
	get_tree().quit(0 if report["ok"] else 1)


# ------------------------------------------------------------------ screenshots

func _current_shot_state() -> String:
	if match_scene == null:
		return "menu" if menu.visible else ""
	var flow: MatchFlow = match_scene.flow
	match flow.state:
		MatchFlow.State.PREP:
			return "prep" if not flow.waiting_for_players() else ""
		MatchFlow.State.ACTIVE:
			return "fight"
		MatchFlow.State.ENDED:
			return "ended"
		MatchFlow.State.SCOREBOARD:
			return "scoreboard"
	return ""


## Playback with screenshots pending: fast-forward (low 3D resolution) until a shot is a second away.
func _pace_playback() -> void:
	if match_scene == null or str(match_scene.options.get("playback", "")) == "" or _shots.is_empty() or _shooting:
		return
	var st: String = _current_shot_state()
	var slow: bool = false
	if _shots.has(st):
		slow = _shot_delay(st) - match_scene.flow.time_in_state() < 1.0
	match_scene.playback_rate = 1 if slow else 30
	get_viewport().scaling_3d_scale = 1.0 if slow else 0.1  # a cheap 3D frame while fast-forwarding


func _shot_delay(st: String) -> float:
	return float(_shot_delays.get(st, SHOT_DELAYS.get(st, 1.0)))


func _check_shots() -> void:
	if _shots.is_empty() or _shooting:
		return
	var st: String = _current_shot_state()
	if st == "" or not _shots.has(st):
		return
	var in_state: float = match_scene.flow.time_in_state() if match_scene != null else _clock
	if in_state < _shot_delay(st):
		return
	_save_shot(st)


func _save_shot(st: String) -> void:
	_shooting = true
	var path: String = _shots[st]
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	_shots.erase(st)
	var err: Error = img.save_png(path)
	if err != OK:
		Log.error("client: could not save %s (error %d)" % [path, err])
	else:
		Log.info("client: saved %s screenshot %s (%dx%d)" % [st, path, img.get_width(), img.get_height()])
	_shooting = false
	if st == _final_shot:
		get_tree().quit(0 if err == OK else 1)


func _arg(name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		Settings.focus_changed(what == NOTIFICATION_APPLICATION_FOCUS_IN)  # mute when unfocused, if set
