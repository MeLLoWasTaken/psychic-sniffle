extends GdUnitTestSuite
## Practice scene (backlog M1-23): an in-process 2v2 on Gallows Courtyard with the player's unit
## under PlayerController and three bots runs 10 simulated seconds of scripted input without
## errors; the player's unit moves and the renderer follows the world view.

const SCRIPT: String = "move_forward:3,target_nearest_enemy,turn_left:0.25,move_forward:2,camera_zoom_out,strafe_right:1,move_back:1,jump,wait:2.75"


func test_practice_runs_ten_seconds_with_scripted_input() -> void:
	var errors_before: int = Log.error_count
	var scene: Node3D = auto_free((load("res://scenes/game/practice.tscn") as PackedScene).instantiate())
	scene.options = {"manual": true, "kit": false, "gi": false, "lighting": false, "auto": SCRIPT}
	add_child(scene)
	var start: Vector3 = scene.world.player.position
	var tick_rate: int = scene.world.tick_rate()
	var travelled: float = 0.0
	var last: Vector3 = start
	for i: int in 10 * tick_rate:
		scene.run_ticks(1)
		var p: Vector3 = scene.world.player.position
		travelled += Vector2(p.x - last.x, p.z - last.z).length()
		last = p
	assert_float(scene.sim_time).is_equal_approx(10.0, 1e-6)
	assert_int(Log.error_count - errors_before).is_equal(0)
	# 6 s of walking at 7 m/s (backpedal slower), less any time blocked by the gallows
	assert_float(travelled).is_greater(20.0)
	assert_float(scene.player_travel()).is_greater(10.0)
	# the renderer draws every unit of the view where the simulation has it (one tick behind at most)
	var r: WorldRenderer = scene.renderer
	assert_int(r.units.size()).is_equal(4)
	var drawn: Vector3 = r.drawn_position(scene.world.player.id)
	assert_float(drawn.distance_to(scene.world.player.position)).is_less(0.2)
	# the camera looks at the player from behind and is not inside a blocker
	var cam_pos: Vector3 = scene.cam.camera.global_position
	assert_float(cam_pos.distance_to(drawn + Vector3.UP * scene.cam.pivot_height)).is_less_equal(scene.cam.zoom_target + 0.01)
	assert_float(ArenaRay.cast(scene.world.geometry(), cam_pos, Vector3.UP, 0.0)).is_equal(0.0)
	var pivot: Vector3 = drawn + Vector3.UP * scene.cam.pivot_height
	var to_cam: Vector3 = cam_pos - pivot
	assert_float(ArenaRay.cast(scene.world.geometry(), pivot, to_cam.normalized(), to_cam.length())).is_equal_approx(to_cam.length(), 1e-3)
	# the ring marks the target when there is one
	assert_bool(r.ring.visible).is_equal(scene.controller.target_id != -1 and r.units.has(scene.controller.target_id))
	# the gates opened with the match
	assert_bool(scene.builder.gates_open).is_true()


func test_renderer_picks_clips_from_movement() -> void:
	assert_str(WorldRenderer.clip_for(Vector3.ZERO, 0.0, true)).is_equal("idle")
	assert_str(WorldRenderer.clip_for(Movement.forward_of(0.7) * 7.0, 0.7, true)).is_equal("run")
	assert_str(WorldRenderer.clip_for(-Movement.forward_of(0.7) * 4.2, 0.7, true)).is_equal("backpedal")
	assert_str(WorldRenderer.clip_for(Movement.right_of(0.7) * 7.0, 0.7, true)).is_equal("strafe_right")
	assert_str(WorldRenderer.clip_for(-Movement.right_of(0.7) * 7.0, 0.7, true)).is_equal("strafe_left")
	assert_str(WorldRenderer.clip_for(Vector3.ZERO, 0.0, false)).is_equal("death")


func test_renderer_interpolates_between_views() -> void:
	var r: WorldRenderer = auto_free(WorldRenderer.new())
	add_child(r)
	var u: Dictionary = {"id": 3, "team": 1, "spec": "no_such_spec", "position": Vector3(0, 0, 0), "facing": 0.0, "health": 1}
	var me: Dictionary = {"id": 1, "team": 0, "spec": "no_such_spec", "position": Vector3(5, 0, 0), "facing": 0.0, "health": 1}
	r.push_view({"tick": 1, "tick_rate": 60, "me": me, "units": [me, u]})
	var u2: Dictionary = u.duplicate()
	u2["position"] = Vector3(0, 0, -0.2)
	u2["facing"] = 0.4
	r.push_view({"tick": 2, "tick_rate": 60, "me": me, "units": [me, u2]})
	r.target_id = 3
	r.draw(0.5)
	assert_vector(r.drawn_position(3)).is_equal_approx(Vector3(0, 0, -0.1), Vector3.ONE * 1e-5)
	assert_float((r.units[3]["root"] as Node3D).rotation.y).is_equal_approx(0.2, 1e-5)
	assert_bool(r.ring.visible).is_true()
	assert_vector(Vector3(r.ring.position.x, 0, r.ring.position.z)).is_equal_approx(Vector3(0, 0, -0.1), Vector3.ONE * 1e-5)
	assert_that((r.ring.material_override as StandardMaterial3D).albedo_color).is_equal(WorldRenderer.RING_COLORS["enemy"])
	r.target_id = 1
	r.draw(1.0)
	assert_that((r.ring.material_override as StandardMaterial3D).albedo_color).is_equal(WorldRenderer.RING_COLORS["ally"])
	# a unit that leaves the view is removed
	r.push_view({"tick": 3, "tick_rate": 60, "me": me, "units": [me]})
	assert_bool(r.units.has(3)).is_false()


func test_clear_target_input_stops_the_server_target() -> void:
	var m: LocalMatch = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"])
	var enemy: int = -1
	for u: Dictionary in m.view()["units"]:
		if int(u["team"]) == 1:
			enemy = int(u["id"])
			break
	m.step({"move": Vector2.ZERO, "yaw": m.player.facing, "target": enemy})
	assert_int(m.player.target_id).is_equal(enemy)
	m.step({"move": Vector2.ZERO, "yaw": m.player.facing, "target": -1, "clear_target": true})
	assert_int(m.player.target_id).is_equal(-1)
	# the flag survives the wire
	var q: Dictionary = Protocol.quantize_input({"clear_target": true, "yaw": 0.0})
	var decoded: Dictionary = Protocol.decode(Protocol.input_packet([q]))
	assert_bool(decoded["inputs"][0]["clear_target"]).is_true()
