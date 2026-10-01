extends GdUnitTestSuite
## M0-10: wire format round trips, and quantized inputs survive encoding unchanged
## (client prediction relies on predicting with exactly what the server decodes).


func test_hello_and_welcome_round_trip() -> void:
	var h: Dictionary = Protocol.decode(Protocol.hello("bot1", "warblade_carnage"))
	assert_int(h["type"]).is_equal(Protocol.Msg.HELLO)
	assert_int(h["version"]).is_equal(Protocol.VERSION)
	assert_str(h["name"]).is_equal("bot1")
	var w: Dictionary = Protocol.decode(Protocol.welcome(7, 12345, 60, "gallows_courtyard"))
	assert_int(w["unit_id"]).is_equal(7)
	assert_int(w["tick"]).is_equal(12345)
	assert_str(w["map"]).is_equal("gallows_courtyard")


func test_quantized_input_survives_encoding_exactly() -> void:
	var raw: Dictionary = {"seq": 42, "move": Vector2(0.3, -0.77), "yaw": 2.345, "jump": true, "tab": false,
		"ability": "ruin_strike", "target": 7}
	var q: Dictionary = Protocol.quantize_input(raw)
	var decoded: Dictionary = Protocol.decode(Protocol.input_packet([q]))["inputs"][0]
	assert_int(decoded["seq"]).is_equal(42)
	assert_vector(decoded["move"]).is_equal(q["move"])
	assert_float(decoded["yaw"]).is_equal(q["yaw"])
	assert_bool(decoded["jump"]).is_true()
	assert_bool(decoded["tab"]).is_false()
	assert_str(decoded["ability"]).is_equal("ruin_strike")
	assert_int(decoded["target"]).is_equal(7)


func test_snapshot_round_trip() -> void:
	var u: Unit = Unit.new(3, 1, "arcanist_rime")
	u.position = Vector3(1.5, 0.25, -7.0)
	u.velocity = Vector3(0, 8, 0)
	u.facing = 1.2
	u.health = 43210
	u.target_id = 5
	u.primary_resource = "mana"
	u.resources = {"mana": 1234.0}
	u.resource_max = {"mana": 50000.0}
	u.cast = {"ability": "ruin_strike", "start_tick": 990, "end_tick": 1110}
	u.auras.append({"id": "ruin_bleed", "source": 1, "expires_tick": 1500, "stacks": 2})
	u.auras.append({"id": "crippled", "source": 1, "expires_tick": 999, "stacks": 1})  # expires this tick
	u.auras.append({"id": "chilled", "source": 1, "expires_tick": 0, "stacks": 1})  # permanent
	u.dr = {"stun": {"count": 2, "reset_tick": 1300}}
	u.school_locks = {"holy": 1100}
	u.cooldowns = {"ruin_strike": 1200}
	u.gcd_ready_tick = 1050
	u.displaced_tick = 980
	var snap: Dictionary = Protocol.decode(Protocol.snapshot(999, 77, [u],
		{"phase": 1, "start_tick": 600, "dampening_pct": 4, "winner": -1}, u))
	assert_int(snap["tick"]).is_equal(999)
	assert_int(snap["ack_seq"]).is_equal(77)
	var d: Dictionary = snap["units"][0]
	assert_int(d["id"]).is_equal(3)
	assert_vector(d["position"]).is_equal(u.position)
	assert_int(d["health"]).is_equal(43210)
	assert_int(d["target_id"]).is_equal(5)
	assert_float(d["resource"]).is_equal(1234.0)
	assert_str(d["cast"]["ability"]).is_equal("ruin_strike")
	assert_int(d["cast"]["end_tick"]).is_equal(1110)
	assert_str(d["auras"][0]["id"]).is_equal("ruin_bleed")
	assert_int(d["auras"][0]["stacks"]).is_equal(2)
	assert_int(d["auras"][0]["expires_tick"]).is_equal(1500)
	assert_int(d["auras"][1]["expires_tick"]).is_equal(999)
	assert_int(d["auras"][2]["expires_tick"]).is_equal(0)
	assert_int(d["dr"]["stun"]["count"]).is_equal(2)
	assert_int(d["dr"]["stun"]["reset_tick"]).is_equal(1300)
	assert_int(snap["own"]["school_locks"]["holy"]).is_equal(1100)
	assert_int(snap["match"]["dampening_pct"]).is_equal(4)
	assert_int(snap["own"]["gcd_ready_tick"]).is_equal(1050)
	assert_int(snap["own"]["displaced_tick"]).is_equal(980)
	assert_int(snap["own"]["cooldowns"]["ruin_strike"]).is_equal(1200)


func test_snapshot_size_fits_bandwidth_budget() -> void:
	# 20 units, each with 4 auras, at 60 Hz must stay under the 96 KB/s design budget even
	# before delta compression.
	var units: Array = []
	for i: int in 20:
		var u: Unit = Unit.new(i, i % 2)
		for k: int in 4:
			u.auras.append({"id": "ruin_bleed", "source": 1, "expires_tick": 100, "stacks": 1})
		units.append(u)
	var bytes_per_second: int = Protocol.snapshot(1, 1, units).size() * 60
	assert_int(bytes_per_second).is_less(96 * 1024)


func test_snapshots_carry_the_active_pickups() -> void:
	var data: PackedByteArray = Protocol.snapshot(100, 3, [], {"phase": 1, "start_tick": 60, "dampening_pct": 0, "winner": -1, "pickups": 2})
	assert_int(int(Protocol.decode(data)["match"]["pickups"])).is_equal(2)


func test_a_hosted_server_gives_its_host_time_to_load_before_calling_it_silent() -> void:
	assert_str(NetServer.host_problem(false, false, 30.0, 0.0)).is_empty()
	assert_str(NetServer.host_problem(false, false, 61.0, 0.0)).is_equal("host_never_joined")
	# joined but still loading the map: a long stall on a slow machine is allowed
	assert_str(NetServer.host_problem(true, false, 40.0, 20.0)).is_empty()
	assert_str(NetServer.host_problem(true, false, 90.0, 61.0)).is_equal("host_silent")
	# playing: silence ends the match sooner
	assert_str(NetServer.host_problem(true, true, 90.0, 16.0)).is_equal("host_silent")
	assert_str(NetServer.host_problem(true, true, 90.0, 2.0)).is_empty()


func test_talent_change_messages_round_trip() -> void:
	var ask: Dictionary = Protocol.decode(Protocol.talents("AQIDBA"))
	assert_int(int(ask["type"])).is_equal(Protocol.Msg.TALENTS)
	assert_str(str(ask["talents"])).is_equal("AQIDBA")
	assert_str(str(ask["error"])).is_empty()
	var no: Dictionary = Protocol.decode(Protocol.talents("", "talents_locked"))
	assert_str(str(no["talents"])).is_empty()
	assert_str(str(no["error"])).is_equal("talents_locked")
