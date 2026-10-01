extends Node3D
## "Play 2v2 vs bots" (backlog M1-28): a real networked arena match started from the menu.
##
## LocalServer starts the authoritative server (60 Hz) and the bot clients as headless processes
## on this machine; this scene joins over ENet like any other player (NetClient, owns_tree off).
## The client side is the practice scene's, fed from the network instead of LocalMatch:
##
##   NetClient.render_view() -> WorldRenderer (characters, effects, sound), Hud, MatchFlow
##   NetClient events        -> WorldRenderer.push_events (animation, effects), Hud, MatchFlow
##   PlayerController.next_input() -> NetClient.input_source (sent to the server every tick)
##
## MatchFlow follows the server's match phase (loading, preparation, gates open, end, scoreboard)
## and MatchScreens draws each step. When the flow reaches MENU (Back to menu, Leave match) the
## scene leaves the server, stops every process it started and emits `exited` with the result;
## the owner (GameFlow) frees it and shows the main menu.
##
## Options (set `options` before adding to the tree; GameFlow fills them from the menu and the
## command line): spec, menu, prep (seconds, < 0 = the menu data's or the tuning's), settings,
## keybinds, kit/gi/lighting (arena art), hud, pilot (ScriptedPilot plays the player's controls),
## auto (ScriptedInput text), seed, port_min/port_max (override the menu's port range),
## lag_ms/jitter_ms/loss (simulated network conditions for this client).
##
## Recording and playback (screenshots): `record` writes every drawn tick (view, events, camera)
## to a compressed file; `playback` draws such a file through the same renderer, HUD, flow and
## screens without a server, one recorded tick per physics tick, or `playback_rate` ticks while
## fast-forwarding. The software renderer here takes seconds per frame,
## so a live client cannot hold a 60 Hz connection while drawing the arena; a recording of a real
## networked match can be drawn at any speed.

signal exited(result: Dictionary)

const DEFAULTS: Dictionary = {
	"spec": "", "menu": "main", "prep": -1.0, "settings": "default", "keybinds": "default",
	"kit": true, "gi": true, "lighting": true, "hud": true, "pilot": false, "auto": "", "seed": 0,
	"port_min": 0, "port_max": 0, "lag_ms": 0.0, "jitter_ms": 0.0, "loss": 0.0,
	"record": "", "playback": "", "talents": "", "preset": "play_bots",
}

var options: Dictionary = {}
var style: MenuStyle
var preset: Dictionary = {}  ## the menu's play_bots preset
var spec_id: String = ""
var flow: MatchFlow
var screens: MatchScreens
var local_server: LocalServer
var net: NetClient
var builder: MapBuilder
var renderer: WorldRenderer
var cam: ThirdPersonCamera
var controller: PlayerController
var hud: Hud
var scripted: ScriptedInput
var pilot: ScriptedPilot
var result: Dictionary = {}  ## what `exited` carried
## ticks: views drawn; stale_view_ticks: ticks without a newer snapshot; held_draw_ticks: ticks
## the renderer skipped (no new draw_tick); events: combat events received
var stats: Dictionary = {"ticks": 0, "stale_view_ticks": 0, "held_draw_ticks": 0, "events": 0}

var _pending_events: Array = []
var _map_built: bool = false
var _port: int = 0
var _synced: bool = false
var _gates_opened: bool = false
var _exited: bool = false
var _last_view_tick: int = -1
var _last_draw_tick: int = -1
var _input_time: float = 0.0
var _cursor_restore: Vector2 = Vector2.ZERO
var _settings: Dictionary = {}
var playback_rate: int = 1  ## recorded ticks drawn per physics tick (playback; > 1 fast-forwards)
var _record: FileAccess
var _playback: FileAccess
var _playback_ready: bool = false
var _playback_done: bool = false
var _cam_override: Array = []  ## [yaw, pitch] recorded with the tick being drawn (playback)


func _ready() -> void:
	var opts: Dictionary = DEFAULTS.duplicate()
	opts.merge(options, true)
	options = opts
	style = MenuStyle.new(str(options["menu"]))
	preset = style.menu.get(str(options["preset"]), {})
	spec_id = str(options["spec"]) if str(options["spec"]) != "" else str(style.menu["spec_picker"]["default"])
	var comp: Dictionary = preset["comps"][spec_id]
	if str(options["keybinds"]) == "default":
		Keybinds.load_user()  # the player's own binds (the keybinding screen), else the default
	else:
		Keybinds.load_profile(str(options["keybinds"]))
	_settings = Settings.values if str(options["settings"]) == "default" and not Settings.values.is_empty() \
		else Data.settings.get(str(options["settings"]), {})  # the player's own settings in a normal run
	Settings.bus.changed.connect(_on_setting)
	var enemies: Array = comp["enemies"]
	var allies: Array = comp["allies"]
	flow = MatchFlow.new(float(preset["end_banner_s"]), 1 + allies.size() + enemies.size())
	flow.state_changed.connect(_on_state_changed)

	renderer = WorldRenderer.new()
	renderer.name = "World"
	add_child(renderer)
	controller = PlayerController.new(_settings)
	cam = ThirdPersonCamera.new(_settings.get("camera", {}))
	cam.name = "PlayerCamera"
	add_child(cam)
	cam.camera.current = true
	if bool(options["hud"]):
		hud = Hud.new(_settings)
		hud.set_loadout(spec_id, str(options["talents"]))
		hud.set_profiles(HudLayouts.new(), spec_id)
		hud.visible = false
		add_child(hud)
		hud.bind(controller, cam.camera, renderer)
	scripted = ScriptedInput.new(str(options["auto"]))

	screens = MatchScreens.new(style, flow)
	var map: Dictionary = Data.maps.get(str(preset["map"]), {})
	screens.title = str(map.get("name", preset["map"]))
	var mine: Array = [spec_id] + allies
	screens.lineup = "%s   vs   %s" % [" & ".join(mine.map(func(s: String) -> String: return HudStyle.spec_label(s))),
		" & ".join(enemies.map(func(s: String) -> String: return HudStyle.spec_label(s)))]
	screens.back_pressed.connect(func() -> void: flow.continue_to_menu())
	screens.resume_pressed.connect(func() -> void: screens.show_pause(false))
	screens.leave_pressed.connect(leave)
	add_child(screens)
	if str(options["playback"]) == "":
		screens.pause_menu.set_spec(spec_id, func() -> bool: return flow.state != MatchFlow.State.PREP)
		screens.pause_menu.talents_chosen.connect(change_talents)

	if str(options["playback"]) != "":
		_playback = FileAccess.open_compressed(str(options["playback"]), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		if _playback == null:
			Log.error("match: cannot read the recording %s" % options["playback"])
			flow.fail("start")
		Log.info("match: playing back %s" % options["playback"])
		_build_arena.call_deferred()
		return
	if str(options["record"]) != "":
		_record = FileAccess.open_compressed(str(options["record"]), FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	local_server = LocalServer.new()
	local_server.name = "LocalServer"
	local_server.start_timeout_s = float(preset["server_start_timeout_s"])
	local_server.ready_to_connect.connect(_on_server_ready)
	local_server.failed.connect(func(_reason: String) -> void: flow.fail("start"))
	local_server.server_exited.connect(_on_server_exited)
	add_child(local_server)
	var bots: Array = []
	for i: int in allies.size():
		bots.append({"name": preset["bot_names"]["allies"][i], "spec": allies[i], "team": 0})
	for i: int in enemies.size():
		bots.append({"name": preset["bot_names"]["enemies"][i], "spec": enemies[i], "team": 1})
	var ports: Array = preset["port_range"]
	if int(options["port_min"]) > 0:
		ports = [int(options["port_min"]), int(options["port_max"]) if int(options["port_max"]) > 0 else int(options["port_min"]) + 99]
	var prep: float = float(options["prep"]) if float(options["prep"]) >= 0.0 else float(preset.get("prep_s", -1.0))
	local_server.start(str(preset["map"]), str(preset["bracket"]), str(preset["host_name"]), bots, prep, ports,
		int(options["seed"]))
	Log.info("match: %s %s as %s with %s vs %s" % [preset["map"], preset["bracket"], spec_id, ", ".join(allies), ", ".join(enemies)])
	_build_arena.call_deferred()  # after the loading screen has drawn once


func _build_arena() -> void:
	if flow.state != MatchFlow.State.LOADING:
		return
	var map: Dictionary = Data.maps[str(preset["map"])]
	builder = (load(map.get("scene", "res://scenes/maps/gallows_courtyard.tscn")) as PackedScene).instantiate()
	builder.map_id = str(preset["map"])
	builder.use_kit = bool(options["kit"])
	builder.bake_gi = bool(options["gi"])
	builder.build_lighting = bool(options["lighting"])
	add_child(builder)
	builder.set_gates_open(false, 0.0)
	cam.geometry = ArenaGeometry.from_map(map)
	_map_built = true
	if _playback != null:
		_playback_ready = true
		return
	if flow.state != MatchFlow.State.LOADING:
		return
	screens.status_key = "starting_server" if _port == 0 else "connecting"
	if _port != 0:
		_connect()


func _on_server_ready(port: int) -> void:
	_port = port
	if _map_built:
		_connect()
	else:
		screens.status_key = "loading_arena"


func _connect() -> void:
	if net != null or flow.state != MatchFlow.State.LOADING:
		return
	screens.status_key = "connecting"
	net = NetClient.new()
	net.name = "NetClient"
	net.owns_tree = false
	net.player_name = str(preset["host_name"])
	net.spec_id = spec_id
	net.talents = str(options["talents"])
	net.prefs = Settings.rule_prefs()
	net.server_silence_s = float(preset["server_silence_s"])
	net.input_source = _next_input
	add_child(net)
	# after _ready (which reads the command line): this match's own settings win
	net.player_name = str(preset["host_name"])
	net.spec_id = spec_id
	net.talents = str(options["talents"])
	if float(options["lag_ms"]) > 0.0 or float(options["jitter_ms"]) > 0.0 or float(options["loss"]) > 0.0:
		net.transport.configure_conditions(float(options["lag_ms"]), float(options["jitter_ms"]), float(options["loss"]), 7)
	net.welcomed.connect(_on_welcomed)
	net.finished.connect(_on_net_finished)
	net.talents_answered.connect(_on_talents_answered)
	net.events_received_signal.connect(func(evs: Array) -> void:
		_pending_events.append_array(evs)
		stats["events"] += evs.size())
	net.ticked.connect(_on_ticked)
	net.connect_to_server("127.0.0.1", _port)


func _on_welcomed(_unit_id: int) -> void:
	if bool(options["pilot"]):
		pilot = ScriptedPilot.new(controller, spec_id, net.geometry, hash(str(preset["host_name"])))


## The player's input for this network tick (NetClient.input_source).
func _next_input() -> Dictionary:
	var dt: float = 1.0 / Data.tick_rate()
	var v: Dictionary = net.render_view()
	if v.is_empty():
		return {"move": Vector2.ZERO, "yaw": controller.yaw}
	if not _synced:
		controller.reset_facing(float(v["me"]["facing"]))
		_synced = true
	if flow.state in [MatchFlow.State.PREP, MatchFlow.State.ACTIVE]:
		for ev: InputEvent in scripted.events_until(_input_time):
			controller.handle_event(ev)
		_input_time += dt
		if pilot != null:
			for ev: InputEvent in pilot.events_for(v):
				controller.handle_event(ev)
	return controller.next_input(dt, v, cam.camera, renderer.drawn_units(), net.geometry)


## One network tick has been sent: draw the newest state and hand out its events.
func _on_ticked() -> void:
	var v: Dictionary = net.render_view()
	if v.is_empty():
		return
	var evs: Array = _pending_events
	_pending_events = []
	_apply_tick(v, evs)
	if _record != null:
		_record.store_var([v, evs, controller.camera_yaw(), controller.pitch, controller.target_id])


## Draw one tick's world view and hand out its combat events (live and playback).
func _apply_tick(v: Dictionary, evs: Array) -> void:
	stats["ticks"] += 1
	if int(v["tick"]) == _last_view_tick:
		stats["stale_view_ticks"] += 1  # no newer snapshot this tick (remote units still move)
	if int(v.get("draw_tick", v["tick"])) == _last_draw_tick:
		stats["held_draw_ticks"] += 1  # the renderer skipped this tick
	_last_view_tick = int(v["tick"])
	_last_draw_tick = int(v.get("draw_tick", v["tick"]))
	renderer.push_view(v)
	renderer.push_events(evs)
	for ev: Dictionary in evs:
		if str(ev.get("type", "")) in ["twist_warning", "twist"] and str(ev.get("text", "")) != "":
			screens.announce(str(ev["text"]))
	if hud != null:
		hud.push(renderer.view, evs)
	flow.on_view(v)
	flow.on_events(evs)
	renderer.target_id = controller.target_id


## Playback: draw the next recorded ticks (flow time advances by recorded ticks).
func _physics_process(_delta: float) -> void:
	if not _playback_ready:
		return
	var dt: float = 1.0 / Data.tick_rate()
	var state_before: MatchFlow.State = flow.state
	for i: int in maxi(playback_rate, 1):
		if flow.state != state_before:
			playback_rate = 1  # a new step of the flow: let the owner decide how fast to go on
			break
		if not _playback_done and _playback.get_position() < _playback.get_length():
			var rec: Array = _playback.get_var()
			controller.target_id = int(rec[4])
			_cam_override = [float(rec[2]), float(rec[3])]
			_apply_tick(rec[0], rec[1])
		elif not _playback_done:
			_playback_done = true
			_on_server_exited()
		flow.advance(dt)
		if playback_rate > 1:
			# fast-forward: animations, effects and combat text keep recorded time
			if not renderer.view.is_empty():
				renderer.draw(1.0, dt)
			if hud != null:
				hud.update(dt)


func _process(delta: float) -> void:
	var fast: bool = _playback != null and playback_rate > 1
	if _playback == null:
		flow.advance(delta)
	if not renderer.view.is_empty():
		if not fast:
			renderer.draw(Engine.get_physics_interpolation_fraction(), delta)
		if builder != null:
			builder.set_pickups(int(renderer.view["match"].get("pickups", 0)))
			var m: Dictionary = renderer.view["match"]
			builder.set_match_time(float(int(renderer.view["tick"]) - int(m.get("start_tick", 0))) / Data.tick_rate(),
				int(m["phase"]) == ArenaMatch.Phase.PREP)
			if cam.geometry != null:
				cam.geometry.removed_tags = builder.removed_tags  # the camera no longer bumps into the wreck
		if not _gates_opened and int(renderer.view["match"]["phase"]) != ArenaMatch.Phase.PREP and builder != null:
			_gates_opened = true
			builder.set_gates_open(true, 0.0 if fast else 1.5)
		if controller.pending_zoom != 0:
			cam.zoom_steps(controller.pending_zoom)
			controller.pending_zoom = 0
		var me: int = int(renderer.view["me"]["id"])
		if renderer.units.has(me):
			var yaw: float = controller.camera_yaw() if _cam_override.is_empty() else float(_cam_override[0])
			var pitch: float = controller.pitch if _cam_override.is_empty() else float(_cam_override[1])
			cam.update(renderer.drawn_position(me), yaw, pitch, delta)
	if hud != null and not fast:
		hud.update(delta)
	screens.update(delta)


func _on_state_changed(_from: MatchFlow.State, to: MatchFlow.State) -> void:
	Log.info("match: %s" % MatchFlow.state_name(to))
	match to:
		MatchFlow.State.PREP, MatchFlow.State.ACTIVE:
			if hud != null:
				hud.visible = true
		MatchFlow.State.ENDED:
			_release_controls()
		MatchFlow.State.SCOREBOARD:
			screens.unit_names = unit_names()
			_release_controls()
			if hud != null:
				hud.visible = false
		MatchFlow.State.FAILED:
			Log.info("match: failed (%s)" % flow.failure)
			_release_controls()
			if hud != null:
				hud.visible = false
			_stop_network(0.5)  # nothing to wait for: stop the bots now
		MatchFlow.State.MENU:
			_finish.call_deferred()


## Ask the server for another loadout (the pause menu's talent screen, during preparation).
func change_talents(text: String) -> void:
	if net == null or text == net.talents:
		return
	if flow.state != MatchFlow.State.PREP:
		screens.pause_menu.set_status(style.text("talents_locked"))
		return
	screens.pause_menu.set_status(style.text("talents_sending"))
	net.send_talents(text)


func _on_talents_answered(text: String, error: String) -> void:
	if error != "":
		var why: String = style.text("talents_locked") if error == "talents_locked" else error
		screens.pause_menu.set_status(style.text("talents_refused", {"why": why}))
		return
	options["talents"] = text
	if hud != null:
		hud.set_loadout(spec_id, text)
	screens.pause_menu.set_status(style.text("talents_changed"))


## Names for the end screen: You, Partner, Enemy 1, Enemy 2 (by unit id within a team).
func unit_names() -> Dictionary:
	var out: Dictionary = {}
	var v: Dictionary = renderer.view
	if v.is_empty():
		return out
	var my_team: int = int(v["me"]["team"])
	var units: Array = (v["units"] as Array).duplicate()
	units.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	var n: int = 0
	for u: Dictionary in units:
		var id: int = int(u["id"])
		if id == int(v["me"]["id"]):
			out[id] = style.text("you")
		elif int(u["team"]) == my_team:
			out[id] = style.text("partner")
		else:
			n += 1
			out[id] = style.text("enemy", {"n": n})
	return out


func _on_net_finished(code: int, reason: String) -> void:
	if code != 0:
		flow.fail(reason)


func _on_server_exited() -> void:
	flow.fail("server_lost")  # no effect once the match has ended (the server exits after it)


## Leave the match now (the in-match menu's Leave): back to the menu.
func leave() -> void:
	flow.leave()


func _release_controls() -> void:
	if pilot != null:
		var evs: Array[InputEvent] = []
		pilot.release(evs)
		for ev: InputEvent in evs:
			controller.handle_event(ev)
	controller.release_all()
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Leave the server and stop every process LocalServer started (they get `grace_s` to exit by
## themselves: the server ends when its host leaves, the bots when the server goes).
func _stop_network(grace_s: float = LocalServer.STOP_GRACE_S) -> void:
	if net != null and not net.is_finished():
		net.leave()
	if local_server != null:
		local_server.stop(grace_s)
	if _record != null:
		_record.close()
		_record = null


func _finish() -> void:
	if _exited:
		return
	_exited = true
	_stop_network()
	result = flow.result()
	result["unit_names"] = unit_names()
	result["server_summary"] = local_server.summary() if local_server != null else {}
	result["pids_started"] = local_server.all_pids() if local_server != null else []
	result["pids_running"] = local_server.running_pids() if local_server != null else []
	result["client"] = net.stats() if net != null else {}
	result["scene"] = stats.duplicate()
	result["pilot"] = {"presses": pilot.presses, "unmapped": pilot.unmapped, "tabs": pilot.tabs,
		"frame_clicks": pilot.frame_clicks} if pilot != null else {}
	Log.info("match: back to the menu (%s)" % ", ".join(flow.history))
	exited.emit(result)


func _unhandled_input(event: InputEvent) -> void:
	var escape: bool = InputMap.has_action("clear_target") and event.is_action_pressed("clear_target")
	if screens.pause_visible():
		if escape:
			screens.show_pause(false)
			get_viewport().set_input_as_handled()
		return
	if not flow.state in [MatchFlow.State.PREP, MatchFlow.State.ACTIVE]:
		return
	if escape and controller.target_id == -1:
		screens.show_pause(true)
		_release_controls()
		get_viewport().set_input_as_handled()
		return
	if not controller.handle_event(event):
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


func _exit_tree() -> void:
	if not _exited:
		_stop_network()

## The player's graphics and gameplay settings on this match while it runs (M2-13).
func _on_setting(p: String, v: Variant) -> void:
	match p:
		"graphics.render_scale", "graphics.fsr":
			_apply_render_scale()
		"gameplay.spell_queue_ms", "gameplay.auto_self_cast":
			_send_prefs()


func _apply_render_scale() -> void:
	var rs: float = clampf(float(Settings.get_value("graphics.render_scale", 1.0)), 0.25, 1.0)
	var vp: Viewport = get_viewport()
	if vp == null or float(options.get("render_scale_override", 0.0)) > 0.0:
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if bool(Settings.get_value("graphics.fsr", true)) and rs < 1.0 \
		else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = rs


func _send_prefs() -> void:
	if net != null:
		net.send_prefs(Settings.rule_prefs())
