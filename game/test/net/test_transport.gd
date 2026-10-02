extends GdUnitTestSuite
## NetTransport (ENet with an optional lag simulator).


## Poll both ends until `want` sees an event of `kind` (or `seconds` pass).
func _pump(a: NetTransport, b: NetTransport, want: NetTransport, kind: String, seconds: float) -> bool:
	var end: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		for t: NetTransport in [a, b]:
			if t == null:
				continue
			for ev: Dictionary in t.poll():
				if t == want and ev["type"] == kind:
					return true
		OS.delay_msec(5)
	return false


func test_leaving_with_a_reliable_packet_in_flight_still_disconnects_at_once() -> void:
	# found in the in-match "Leave": the client asked to disconnect after its queued reliable
	# packets (peer_disconnect_later) and closed its host at once, so with a packet still waiting
	# for its acknowledgement the disconnect was never sent and the server only noticed the silence
	var server: NetTransport = NetTransport.new()
	var client: NetTransport = NetTransport.new()
	assert_int(server.start_server(25480)).is_equal(OK)
	var peer: ENetPacketPeer = client.start_client("127.0.0.1", 25480)
	assert_bool(_pump(server, client, server, "connect", 3.0)).is_true()
	var end: int = Time.get_ticks_msec() + 3000
	while peer.get_state() != ENetPacketPeer.STATE_CONNECTED and Time.get_ticks_msec() < end:
		server.poll()
		client.poll()
		OS.delay_msec(5)
	assert_int(peer.get_state()).is_equal(ENetPacketPeer.STATE_CONNECTED)
	client.send(peer, Protocol.CH_RELIABLE, PackedByteArray([1, 2, 3]), true)
	peer.peer_disconnect_later()
	client.poll()  # the packet goes out; its acknowledgement will never be read
	client.close()
	assert_bool(_pump(server, null, server, "disconnect", 1.0)).override_failure_message(
		"the server did not see the client leave within 1 s").is_true()
	server.close()
