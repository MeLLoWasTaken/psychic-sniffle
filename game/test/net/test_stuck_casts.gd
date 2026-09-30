extends GdUnitTestSuite
## Backlog M1-30: the client's stuck-cast detector and end-of-match record (the network test
## counts on both; a real match that reports zero stuck casts only means something if the
## detector fires on one).


func _snap(tick: int, cast: Dictionary, phase: int = ArenaMatch.Phase.ACTIVE) -> Dictionary:
	return {"tick": tick, "match": {"phase": phase, "winner": -1},
		"units": [{"id": 3, "health": 41000, "cast": cast}, {"id": 4, "health": 0, "cast": {}}]}


func test_a_cast_shown_past_its_end_is_reported_once() -> void:
	var c: NetClient = auto_free(NetClient.new())
	var cast: Dictionary = {"ability": "rime_bolt", "start_tick": 100, "end_tick": 190}
	c._check_casts(_snap(150, cast))
	c._check_casts(_snap(190 + NetClient.STUCK_CAST_TICKS, cast))
	assert_int(c._stuck_casts.size()).is_equal(0)  # within the grace period
	c._check_casts(_snap(191 + NetClient.STUCK_CAST_TICKS, cast))
	c._check_casts(_snap(260, cast))
	assert_int(c._stuck_casts.size()).is_equal(1)
	assert_str(str(c._stuck_casts.values()[0]["ability"])).is_equal("rime_bolt")


func test_the_first_ended_snapshot_is_kept_as_the_end_view() -> void:
	var c: NetClient = auto_free(NetClient.new())
	c._on_snapshot(_snap(500, {}, ArenaMatch.Phase.ENDED))
	c._on_snapshot(_snap(501, {}, ArenaMatch.Phase.ENDED))
	assert_int(int(c._end_view["tick"])).is_equal(500)
	assert_dict(c._end_view["health"]).is_equal({"3": 41000, "4": 0})
