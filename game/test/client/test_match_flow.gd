extends GdUnitTestSuite
## Match flow (backlog M1-28): MatchFlow's states follow the server's match phase and never go
## back, the end banner gives way to the scoreboard, leave and fail paths end at the menu;
## MatchScoreboard counts the server's combat events; the end screen, main menu and pilot pieces
## behave. The networked paths (server lost, leaving mid-match) are in test_net_match.gd.

const PREP: int = ArenaMatch.Phase.PREP
const ACTIVE: int = ArenaMatch.Phase.ACTIVE
const ENDED: int = ArenaMatch.Phase.ENDED


static func _unit(id: int, team: int, spec: String, health: int = 60000) -> Dictionary:
	return {"id": id, "team": team, "spec": spec, "position": Vector3.ZERO, "facing": 0.0, "health": health,
		"max_health": 60000, "target_id": -1, "cast": {}, "auras": [], "resource": 0.0, "resource_max": 100.0}


## A world view as NetClient.render_view() builds it: me = unit 1 on team 0.
static func _view(tick: int, phase: int, start_tick: int = 600, winner: int = -1, units: int = 4) -> Dictionary:
	var all: Array = [_unit(1, 0, "warblade_carnage"), _unit(2, 1, "oracle_grace"), _unit(3, 0, "oracle_grace"),
		_unit(4, 1, "arcanist_rime")].slice(0, units)
	return {"tick": tick, "tick_rate": 60, "me": all[0], "units": all, "gcd_ready_tick": 0, "cooldowns": {},
		"school_locks": {}, "match": {"phase": phase, "start_tick": start_tick, "dampening_pct": 0, "winner": winner},
		"map": "gallows_courtyard"}


func test_flow_follows_the_match_to_the_scoreboard_and_menu() -> void:
	var f: MatchFlow = MatchFlow.new(3.0, 4)
	var seen: Array = []
	f.state_changed.connect(func(from: MatchFlow.State, to: MatchFlow.State) -> void: seen.append([from, to]))
	assert_int(f.state).is_equal(MatchFlow.State.LOADING)
	f.on_view(_view(10, PREP, 600, -1, 2))
	assert_int(f.state).is_equal(MatchFlow.State.PREP)
	assert_bool(f.waiting_for_players()).is_true()  # 2 of 4 joined
	f.on_view(_view(20, PREP, 3620))
	assert_bool(f.waiting_for_players()).is_false()
	assert_float(f.seconds_to_gates()).is_equal_approx(60.0, 1e-6)
	f.on_view(_view(3620, ACTIVE, 3620))
	assert_int(f.state).is_equal(MatchFlow.State.ACTIVE)
	f.on_view(_view(3621, PREP, 3620))  # a stale snapshot never takes the flow back
	assert_int(f.state).is_equal(MatchFlow.State.ACTIVE)
	assert_bool(f.continue_to_menu()).is_false()  # no Back to menu during the fight
	f.on_events([{"tick": 3620 + 60 * 90, "type": "match_end", "winner": 0, "reason": "team_eliminated"}])
	f.on_view(_view(3620 + 60 * 90, ENDED, 3620, 0))
	assert_int(f.state).is_equal(MatchFlow.State.ENDED)
	assert_str(f.outcome()).is_equal("victory")
	assert_str(f.end_reason).is_equal("team_eliminated")
	assert_float(f.match_seconds()).is_equal_approx(90.0, 1e-6)
	f.advance(2.9)
	assert_int(f.state).is_equal(MatchFlow.State.ENDED)  # the banner shows for end_banner_s
	f.advance(0.2)
	assert_int(f.state).is_equal(MatchFlow.State.SCOREBOARD)
	f.on_view(_view(3620 + 60 * 95, ENDED, 3620, 0))
	assert_float(f.match_seconds()).is_equal_approx(90.0, 1e-6)  # the clock stopped at the end
	assert_bool(f.continue_to_menu()).is_true()
	assert_int(f.state).is_equal(MatchFlow.State.MENU)
	assert_array(f.history).is_equal(["loading", "prep", "active", "ended", "scoreboard", "menu"])
	assert_int(seen.size()).is_equal(5)
	assert_bool(f.left).is_false()
	assert_str(f.failure).is_empty()


func test_outcome_for_either_team_and_draw() -> void:
	var f: MatchFlow = MatchFlow.new(0.0)
	f.on_view(_view(700, ENDED, 600, 1))
	assert_str(f.outcome()).is_equal("defeat")
	var d: MatchFlow = MatchFlow.new(0.0)
	d.on_view(_view(700, ENDED, 600, -2))
	assert_str(d.outcome()).is_equal("draw")
	assert_int(d.state).is_equal(MatchFlow.State.ENDED)  # straight from loading (joined late)
	assert_str(MatchFlow.new().outcome()).is_empty()


func test_leaving_goes_straight_to_the_menu() -> void:
	var f: MatchFlow = MatchFlow.new()
	f.on_view(_view(10, PREP))
	f.on_view(_view(700, ACTIVE))
	f.leave()
	assert_int(f.state).is_equal(MatchFlow.State.MENU)
	assert_bool(f.left).is_true()
	f.on_view(_view(800, ENDED, 600, 0))  # nothing moves it once at the menu
	f.fail("server_lost")
	assert_int(f.state).is_equal(MatchFlow.State.MENU)
	assert_array(f.history).is_equal(["loading", "prep", "active", "menu"])


func test_failure_paths_end_at_the_menu() -> void:
	# server lost during preparation: FAILED, whose only way on is the menu
	var f: MatchFlow = MatchFlow.new()
	f.on_view(_view(10, PREP))
	f.fail("server_lost")
	assert_int(f.state).is_equal(MatchFlow.State.FAILED)
	assert_str(f.failure).is_equal("server_lost")
	f.on_view(_view(700, ACTIVE))  # late snapshots do not revive it
	f.advance(10.0)
	assert_int(f.state).is_equal(MatchFlow.State.FAILED)
	assert_bool(f.continue_to_menu()).is_true()
	assert_array(f.history).is_equal(["loading", "prep", "failed", "menu"])
	# the server failing to start (still loading)
	var s: MatchFlow = MatchFlow.new()
	s.fail("start")
	assert_int(s.state).is_equal(MatchFlow.State.FAILED)
	# the server closing after the match ended is not a failure
	var e: MatchFlow = MatchFlow.new(3.0)
	e.on_view(_view(700, ENDED, 600, 0))
	e.fail("server_lost")
	assert_int(e.state).is_equal(MatchFlow.State.ENDED)
	e.advance(3.0)
	assert_int(e.state).is_equal(MatchFlow.State.SCOREBOARD)


func test_scoreboard_counts_damage_healing_kills_and_interrupts() -> void:
	var b: MatchScoreboard = MatchScoreboard.new()
	b.add_units(_view(1, ACTIVE))
	b.add_events([
		{"type": "damage", "source": 1, "target": 2, "amount": 5000, "absorbed": 1200, "killed": false},
		{"type": "damage", "source": 1, "target": 2, "amount": 3000, "absorbed": 0, "killed": false},
		{"type": "damage", "source": 4, "target": 1, "amount": 7000, "absorbed": 0, "killed": false},
		{"type": "heal", "source": 3, "target": 1, "amount": 4000, "overheal": 900},
		{"type": "heal", "source": 2, "target": 2, "amount": 2500, "overheal": 0},
		{"type": "interrupt", "source": 1, "target": 4, "ability": "x"},
		{"type": "damage", "source": 1, "target": 4, "amount": 900, "absorbed": 0, "killed": true},
		{"type": "damage", "source": -1, "target": 3, "amount": 100, "absorbed": 0, "killed": false},
		{"type": "cast_success", "source": 1, "target": 2, "ability": "x"},
	])
	assert_int(b.row(1)["damage"]).is_equal(5000 + 1200 + 3000 + 900)  # absorbed damage counts
	assert_int(b.row(3)["healing"]).is_equal(4000)  # overhealing does not
	assert_int(b.row(2)["healing"]).is_equal(2500)
	assert_int(b.row(4)["damage"]).is_equal(7000)
	assert_int(b.row(1)["interrupts"]).is_equal(1)
	assert_int(b.row(1)["kills"]).is_equal(1)
	assert_int(b.row(4)["deaths"]).is_equal(1)
	assert_bool(b.row(4)["alive"]).is_false()
	assert_int(b.events_counted).is_equal(8)
	var mine: Array = b.rows_for_team(0)
	assert_array(mine.map(func(r: Dictionary) -> int: return int(r["id"]))).is_equal([1, 3])  # most damage first
	assert_str(str(mine[0]["spec"])).is_equal("warblade_carnage")
	var t: Dictionary = b.team_totals(1)
	assert_int(t["damage"]).is_equal(7000)
	assert_int(t["healing"]).is_equal(2500)
	assert_int(t["deaths"]).is_equal(1)
	assert_int(b.row(99)["damage"]).is_equal(0)  # never seen: zeros


func test_flow_stops_counting_once_the_scoreboard_shows() -> void:
	var f: MatchFlow = MatchFlow.new(0.0)
	f.on_view(_view(700, ENDED, 600, 0))
	f.advance(0.1)
	assert_int(f.state).is_equal(MatchFlow.State.SCOREBOARD)
	f.on_events([{"type": "damage", "source": 1, "target": 2, "amount": 100, "absorbed": 0, "killed": false}])
	assert_int(f.scoreboard.row(1)["damage"]).is_equal(0)
	var r: Dictionary = f.result()
	assert_str(str(r["outcome"])).is_equal("victory")
	assert_int((r["teams"]["mine"] as Array).size()).is_equal(2)
	assert_int((r["teams"]["enemy"] as Array).size()).is_equal(2)


func test_end_screen_shows_back_to_menu_only_when_it_may_be_used() -> void:
	var style: MenuStyle = MenuStyle.new("main")
	var f: MatchFlow = MatchFlow.new(0.0)
	var screens: MatchScreens = auto_free(MatchScreens.new(style, f))
	add_child(screens)
	var backs: Array = [0]
	screens.back_pressed.connect(func() -> void: backs[0] += 1)
	f.on_view(_view(10, PREP))
	assert_bool(screens.back_button.visible).is_false()
	f.on_view(_view(700, ENDED, 600, 1))
	assert_bool(screens.back_button.visible).is_false()
	f.advance(0.1)
	assert_int(f.state).is_equal(MatchFlow.State.SCOREBOARD)
	assert_bool(screens.back_button.visible).is_true()
	assert_str(screens.back_button.text).is_equal(style.text("back_to_menu"))
	screens.back_button.pressed.emit()
	assert_int(backs[0]).is_equal(1)
	screens.update(0.016)
	await await_idle_frame()  # draws without errors
	assert_str(screens._reason_text()).is_equal("")  # no match_end event seen: no reason line
	f.end_reason = "team_eliminated"
	assert_str(screens._reason_text()).is_equal(style.text("reason_team_eliminated"))  # we lost
	assert_str(screens.failure_text("server_lost")).is_equal(style.text("failed_server_lost"))
	assert_str(screens.failure_text("rejected: not in the roster")).is_equal(style.text("failed_rejected"))
	assert_str(screens.failure_text("start")).is_equal(style.text("failed_start"))
	assert_str(MatchScreens.number(1234567)).is_equal("1,234,567")
	assert_str(MatchScreens.number(999)).is_equal("999")
	assert_str(MatchScreens.number(0)).is_equal("0")


func test_menu_is_built_from_data_and_emits_the_chosen_action() -> void:
	var m: MainMenu = auto_free(MainMenu.new("main"))
	add_child(m)
	var data: Dictionary = Data.menus["main"]
	assert_int(m.buttons.size()).is_equal((data["buttons"] as Array).size())
	assert_int(m.cards.size()).is_equal((data["spec_picker"]["specs"] as Array).size())
	assert_str(m.spec).is_equal(str(data["spec_picker"]["default"]))
	assert_str((m.buttons["play_bots"] as Button).text).is_equal("Play 2v2 vs bots")
	var got: Array = []
	m.action_chosen.connect(func(a: String, s: String) -> void: got.append([a, s]))
	m.select_spec("arcanist_rime")
	(m.buttons["play_bots"] as Button).pressed.emit()
	assert_array(got).is_equal([["play_bots", "arcanist_rime"]])
	m.select_spec("no_such_spec")  # ignored
	assert_str(m.spec).is_equal("arcanist_rime")
	# fonts come from the data, like the HUD's
	assert_object(m.style.display_font).is_not_same(ThemeDB.fallback_font)
	assert_object(m.style.font).is_not_same(ThemeDB.fallback_font)
	var ss: SettingsScreen = m.show_settings()
	assert_object(m.settings_screen).is_not_null()
	ss.press("done")
	await await_idle_frame()
	assert_object(m.settings_screen).is_null()


func test_settings_screen_shows_the_profile_values() -> void:
	Settings.use_data()
	var s: SettingsScreen = auto_free(SettingsScreen.new())
	s.show_page("graphics")
	for rc: Dictionary in s.row_controls:
		if rc["row"].get("path", "") == "camera.fov_deg":
			assert_float((rc["control"] as HSlider).value).is_equal(float(Data.settings["default"]["camera"]["fov_deg"]))


func test_game_flow_routes_practice_and_back_to_the_menu() -> void:
	var errors_before: int = Log.error_count
	var gf: Control = auto_free((load("res://scenes/client_main.tscn") as PackedScene).instantiate())
	gf.extra_options = {"kit": false, "gi": false, "lighting": false}
	add_child(gf)
	assert_bool(gf.menu.visible).is_true()
	gf.menu.select_spec("oracle_grace")
	(gf.menu.buttons["practice"] as Button).pressed.emit()
	assert_object(gf.practice).is_not_null()
	assert_bool(gf.menu.visible).is_false()
	assert_str(str(gf.practice.options["spec"])).is_equal("oracle_grace")
	await await_idle_frame()
	# Escape with no target opens the in-match menu; its Leave returns to the main menu
	var esc: InputEventAction = InputEventAction.new()
	esc.action = "clear_target"
	esc.pressed = true
	gf.practice.controller.target_id = -1
	gf._input(esc)
	assert_bool(gf.practice_menu.visible).is_true()
	gf.practice_menu.leave_button.pressed.emit()
	assert_object(gf.practice).is_null()
	assert_bool(gf.menu.visible).is_true()
	assert_int(int(gf.report["menu_returns"])).is_equal(1)
	# Settings opens the panel over the menu
	(gf.menu.buttons["settings"] as Button).pressed.emit()
	assert_object(gf.menu.settings_screen).is_not_null()
	await await_idle_frame()
	assert_int(Log.error_count - errors_before).is_equal(0)


func test_pilot_drives_the_controls_with_input_events() -> void:
	Keybinds.load_profile("default")
	var controller: PlayerController = PlayerController.new(Data.settings["default"])
	controller.bar_actions = {"bar1_slot1": "grim_hack", "bar1_slot2": "wide_hew"}
	var geo: ArenaGeometry = ArenaGeometry.from_map(Data.maps["gallows_courtyard"])
	var pilot: ScriptedPilot = ScriptedPilot.new(controller, "warblade_carnage", geo)
	var v: Dictionary = _view(700, ACTIVE)
	(v["units"][1] as Dictionary)["position"] = Vector3(0, 0, -20)  # an enemy straight ahead
	(v["units"][3] as Dictionary)["position"] = Vector3(15, 0, -20)
	var evs: Array[InputEvent] = pilot.events_for(v)
	for ev: InputEvent in evs:
		controller.handle_event(ev)
	assert_bool(controller.steering).is_true()  # the right button is held to steer
	var inp: Dictionary = controller.next_input(1.0 / 60.0, v)
	assert_float((inp["move"] as Vector2).y).is_equal(1.0)  # walking toward the enemy
	assert_bool(controller.target_id in [2, 4] or pilot.tabs > 0).is_true()
	# the match ending lets go of everything
	var end: Array[InputEvent] = pilot.events_for(_view(800, ENDED, 600, 0))
	for ev: InputEvent in end:
		controller.handle_event(ev)
	assert_bool(controller.steering).is_false()
	assert_bool(controller.held["move_forward"]).is_false()


func test_the_menu_offers_a_1v1_against_a_bot() -> void:
	var m: MainMenu = auto_free(MainMenu.new())
	add_child(m)
	m.size = Vector2(1920, 1080)
	m._layout()
	var got: Array = []
	m.action_chosen.connect(func(a: String, s: String) -> void: got.append([a, s]))
	assert_str((m.buttons["play_1v1"] as Button).text).is_equal("Play 1v1 vs a bot")
	(m.buttons["play_1v1"] as Button).pressed.emit()
	assert_array(got).is_equal([["play_1v1", m.spec]])
	var last: Button = m.buttons.values()[-1]
	assert_float(last.position.y + last.size.y).is_less_equal(MainMenu.BUTTONS_BOTTOM + 0.5)
	var preset: Dictionary = Data.menus["main"]["play_1v1"]
	assert_str(str(preset["bracket"])).is_equal("1v1")
	for sid: String in preset["comps"]:
		assert_int((preset["comps"][sid]["allies"] as Array).size()).is_equal(0)
		assert_int((preset["comps"][sid]["enemies"] as Array).size()).is_equal(1)
