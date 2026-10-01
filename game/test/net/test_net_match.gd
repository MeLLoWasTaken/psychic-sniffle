extends GdUnitTestSuite
## "Play 2v2 vs bots" over the network (backlog M1-28), with real processes: LocalServer starts
## the server and three bots, the match scene joins. Failure paths end at the menu cleanly: the
## server dying mid-match shows the failure screen and Back to menu leaves no process behind;
## leaving from the in-match menu ends the server; a server that cannot start fails the launcher.
## The full match (menu to scoreboard and back) is tools/match_flow_e2e.py.
## Ports 25450-25499 (other network checks use 246xx and 247xx).

const NET_MATCH: String = "res://scenes/game/net_match.tscn"


func _start_match(port: int, prep: float) -> Node:
	var scene: Node = (load(NET_MATCH) as PackedScene).instantiate()
	scene.options = {"kit": false, "gi": false, "lighting": false, "hud": true, "port_min": port,
		"port_max": port + 9, "prep": prep, "seed": 3}
	add_child(scene)
	return scene


## A bot build's talent text for a spec whose talents grant at least one ability.
func _build_with_granted_ability(spec_id: String) -> String:
	for b: Dictionary in Data.bots[spec_id].get("builds", []):
		var text: String = str(BotBrain.build_talents(spec_id, str(b["name"]))["talents"])
		if not TalentLoadouts.granted_abilities(spec_id, text).is_empty():
			return text
	return ""


## Wait (in real time) until `cond` holds or `timeout_s` passes; true when it held.
func _wait_for(cond: Callable, timeout_s: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().process_frame
	return true


func test_server_lost_mid_match_goes_back_to_the_menu_cleanly() -> void:
	var errors_before: int = Log.error_count
	var scene: Node = _start_match(25450, 30.0)
	var flow: MatchFlow = scene.flow
	var exited: Array = []
	scene.exited.connect(func(r: Dictionary) -> void: exited.append(r))
	var joined: bool = await _wait_for(func() -> bool: return flow.state == MatchFlow.State.PREP and not flow.waiting_for_players(), 45.0)
	assert_bool(joined).override_failure_message("never reached preparation with the full roster: %s" % [flow.history]).is_true()
	var ls: LocalServer = scene.local_server
	assert_int(ls.running_pids().size()).is_equal(4)  # the server and three bots
	assert_bool(scene.hud.visible).is_true()
	assert_int(scene.renderer.units.size()).is_equal(4)
	# M2-05b: a new loadout during preparation reaches the server and moves its ability onto the bars
	var text: String = _build_with_granted_ability(str(scene.spec_id))
	var granted: Array = TalentLoadouts.granted_abilities(str(scene.spec_id), text)
	assert_array(granted).override_failure_message("no bot build grants an ability").is_not_empty()
	var answers: Array = []
	scene.net.talents_answered.connect(func(t: String, e: String) -> void: answers.append([t, e]))
	assert_bool(scene.screens.pause_menu.talents_button.visible).is_true()
	scene.screens.pause_menu.talents_chosen.emit(text)
	var answered: bool = await _wait_for(func() -> bool: return not answers.is_empty(), 10.0)
	assert_bool(answered).override_failure_message("no answer to the talent change in preparation").is_true()
	if answered:
		assert_array(answers[0]).override_failure_message("answer %s" % [answers[0]]).is_equal([text, ""])
	assert_str(scene.net.talents).is_equal(text)
	var on_bars: Array = []
	for b: ActionBar in scene.hud.bars.values():
		for sl: Dictionary in b.slots:
			on_bars.append(str(sl["ability"]))
	assert_array(on_bars).contains(granted)
	assert_str(scene.screens.pause_menu.status).is_equal(scene.style.text("talents_changed"))
	# the server dies (killed from outside, like a crash)
	OS.execute("kill", ["-9", str(ls.server_pid)])
	var failed: bool = await _wait_for(func() -> bool: return flow.state == MatchFlow.State.FAILED, 10.0)
	assert_bool(failed).is_true()
	assert_str(flow.failure).is_equal("server_lost")
	assert_bool(scene.screens.back_button.visible).is_true()
	assert_bool(scene.hud.visible).is_false()
	assert_bool(scene.net.is_finished()).is_true()  # the client stopped with the failure
	scene.screens.back_button.pressed.emit()
	var left: bool = await _wait_for(func() -> bool: return not exited.is_empty(), 10.0)
	assert_bool(left).is_true()
	var r: Dictionary = exited[0]
	assert_array(r["history"]).is_equal(["loading", "prep", "failed", "menu"])
	assert_array(r["pids_running"]).is_empty()  # the bots were stopped and every process reaped
	for pid: int in r["pids_started"]:
		assert_bool(DirAccess.dir_exists_absolute("/proc/%d" % pid)).override_failure_message(
			"process %d is still there (running or not reaped)" % pid).is_false()
	assert_int(Log.error_count - errors_before).override_failure_message("errors logged, the last: %s" % Log.last_error).is_equal(0)
	scene.queue_free()


func test_leaving_from_the_match_menu_ends_the_server() -> void:
	var errors_before: int = Log.error_count
	var scene: Node = _start_match(25460, 2.0)
	var flow: MatchFlow = scene.flow
	var exited: Array = []
	scene.exited.connect(func(r: Dictionary) -> void: exited.append(r))
	var active: bool = await _wait_for(func() -> bool: return flow.state == MatchFlow.State.ACTIVE, 45.0)
	assert_bool(active).override_failure_message("gates never opened: %s" % [flow.history]).is_true()
	assert_int(Log.error_count - errors_before).override_failure_message("errors before the talent check, the last: %s" % Log.last_error).is_equal(0)
	# M2-05b: once the gates are open the server refuses a talent change, and the menu's screen is read-only
	var answers: Array = []
	scene.net.talents_answered.connect(func(t: String, e: String) -> void: answers.append([t, e]))
	scene.net.send_talents(_build_with_granted_ability(str(scene.spec_id)))
	var answered: bool = await _wait_for(func() -> bool: return not answers.is_empty(), 10.0)
	assert_bool(answered).override_failure_message("no answer to the talent change after the gates").is_true()
	if answered:
		assert_array(answers[0]).override_failure_message("answer %s" % [answers[0]]).is_equal(["", "talents_locked"])
	assert_str(scene.net.talents).is_equal("")
	var ts: TalentScreen = scene.screens.pause_menu.open_talents(TalentLoadouts.new("user://test_net_match_talents.json"))
	assert_bool(ts.locked).override_failure_message("the talent screen is editable after the gates").is_true()
	ts.close()
	await get_tree().process_frame
	# Escape with no target opens the in-match menu; Leave match ends it
	var esc: InputEventAction = InputEventAction.new()
	esc.action = "clear_target"
	esc.pressed = true
	scene.controller.target_id = -1
	scene._unhandled_input(esc)
	assert_bool(scene.screens.pause_visible()).is_true()
	scene.screens.pause_menu.leave_button.pressed.emit()
	var left: bool = await _wait_for(func() -> bool: return not exited.is_empty(), 15.0)
	assert_bool(left).override_failure_message("did not leave: %s" % [flow.history]).is_true()
	if not left:
		return
	var r: Dictionary = exited[0]
	assert_bool(r["left"]).is_true()
	assert_array(r["history"]).is_equal(["loading", "prep", "active", "menu"])
	assert_array(r["pids_running"]).is_empty()
	assert_str(str(r["server_summary"].get("end_reason", ""))).is_equal("host_left")  # the server finished by itself
	assert_int(Log.error_count - errors_before).override_failure_message("errors logged, the last: %s" % Log.last_error).is_equal(0)
	scene.queue_free()


func test_a_server_that_cannot_start_fails_the_launcher() -> void:
	var ls: LocalServer = auto_free(LocalServer.new())
	add_child(ls)
	var reasons: Array = []
	ls.failed.connect(func(why: String) -> void: reasons.append(why))
	assert_int(ls.start("no_such_map", "2v2", "player", [], -1.0, [25470, 25479])).is_equal(OK)
	var failed: bool = await _wait_for(func() -> bool: return not reasons.is_empty(), 20.0)
	assert_bool(failed).is_true()
	assert_int(ls.phase).is_equal(LocalServer.Phase.FAILED)
	assert_array(ls.running_pids()).is_empty()
	ls.stop()
	assert_int(ls.phase).is_equal(LocalServer.Phase.STOPPED)


func test_free_port_probe_skips_a_port_in_use() -> void:
	var busy: PacketPeerUDP = PacketPeerUDP.new()
	assert_int(busy.bind(25480, "127.0.0.1")).is_equal(OK)
	assert_int(LocalServer.find_free_port(25480, 25481)).is_equal(25481)
	busy.close()
	assert_int(LocalServer.find_free_port(25480, 25481)).is_equal(25480)
