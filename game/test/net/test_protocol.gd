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
	var raw: Dictionary = {"seq": 42, "move": Vector2(0.3, -0.77), "yaw": 2.345, "jump": true, "tab": false}
	var q: Dictionary = Protocol.quantize_input(raw)
	var decoded: Dictionary = Protocol.decode(Protocol.input_packet([q]))["inputs"][0]
	assert_int(decoded["seq"]).is_equal(42)
	assert_vector(decoded["move"]).is_equal(q["move"])
	assert_float(decoded["yaw"]).is_equal(q["yaw"])
	assert_bool(decoded["jump"]).is_true()
	assert_bool(decoded["tab"]).is_false()


func test_snapshot_round_trip() -> void:
	var u: Unit = Unit.new(3, 1, "arcanist_rime")
	u.position = Vector3(1.5, 0.25, -7.0)
	u.velocity = Vector3(0, 8, 0)
	u.facing = 1.2
	u.health = 43210
	u.target_id = 5
	var snap: Dictionary = Protocol.decode(Protocol.snapshot(999, 77, [u]))
	assert_int(snap["tick"]).is_equal(999)
	assert_int(snap["ack_seq"]).is_equal(77)
	var d: Dictionary = snap["units"][0]
	assert_int(d["id"]).is_equal(3)
	assert_vector(d["position"]).is_equal(u.position)
	assert_int(d["health"]).is_equal(43210)
	assert_int(d["target_id"]).is_equal(5)


func test_snapshot_size_fits_bandwidth_budget() -> void:
	# 20 units at 60 Hz must stay under the 96 KB/s design budget even before delta compression.
	var units: Array = []
	for i: int in 20:
		units.append(Unit.new(i, i % 2))
	var bytes_per_second: int = Protocol.snapshot(1, 1, units).size() * 60
	assert_int(bytes_per_second).is_less(96 * 1024)
