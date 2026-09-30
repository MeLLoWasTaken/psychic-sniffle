extends GdUnitTestSuite
## Spell effects v1 (backlog M1-25): EffectsDirector turns world views and combat events into the
## effect stages of data/effects, colored by the palette's schools, within a budget, and frees
## what finishes. Deterministic: the director is advanced by hand, without a renderer (positions
## come from the views), except in the practice-fight test.

const DT: float = 1.0 / 60.0
const ME: int = 1  ## the local player (team 0)
const ALLY: int = 2
const ENEMY: int = 3  ## team 1
const ENEMY_2: int = 4


func _unit(id: int, team: int, pos: Vector3, auras: Array = [], cast: Dictionary = {}) -> Dictionary:
	return {"id": id, "team": team, "spec": "warblade_carnage", "position": pos, "facing": 0.0, "health": 60000,
		"max_health": 60000, "target_id": -1, "cast": cast, "auras": auras}


## Me at the origin, an ally beside me, two enemies 20 m north (-Z).
func _view(tick: int = 1, extra: Dictionary = {}) -> Dictionary:
	var units: Array = [_unit(ME, 0, Vector3.ZERO), _unit(ALLY, 0, Vector3(3, 0, 0)),
		_unit(ENEMY, 1, Vector3(0, 0, -20)), _unit(ENEMY_2, 1, Vector3(4, 0, -20))]
	for i: int in units.size():
		var id: int = int(units[i]["id"])
		if extra.has(id):
			units[i].merge(extra[id], true)
	return {"tick": tick, "tick_rate": 60, "me": units[0], "units": units}


func _director() -> EffectsDirector:
	var d: EffectsDirector = auto_free(EffectsDirector.new())
	add_child(d)
	d.push_view(_view())
	return d


func _run(d: EffectsDirector, seconds: float) -> void:
	for i: int in roundi(seconds / DT):
		d.update(DT)


func _ev(type: String, src: int, tgt: int, ability: String = "", extra: Dictionary = {}) -> Dictionary:
	var ev: Dictionary = {"type": type, "source": src, "target": tgt, "ability": ability, "tick": 1}
	ev.merge(extra, true)
	return ev


func _outline(v: Vfx) -> Color:
	var disc: MeshInstance3D = v.data["disc"]
	return (disc.material_override as ShaderMaterial).get_shader_parameter("outline_color")


# ------------------------------------------------------------------ data

func test_every_kit_ability_has_an_effect_entry() -> void:
	var checked: int = 0
	for spec: Dictionary in Data.specs.values():
		if spec.get("kit_status", "") != "complete":
			continue
		var ids: Array = spec["abilities"].duplicate()
		ids.append_array(Data.classes[spec["class"]].get("shared_abilities", []))
		for id: String in ids:
			var e: Dictionary = Data.effects.get(id, {})
			assert_bool(e.is_empty()).override_failure_message("no effect entry for '%s'" % id).is_false()
			var stages: int = 0
			for s: String in ["cast", "projectile", "impact", "ground", "melee", "displacement", "auras"]:
				stages += 1 if e.has(s) else 0
			assert_bool(bool(e.get("none", false)) or stages > 0).override_failure_message("'%s' has no stages" % id).is_true()
			for aura_id: String in e.get("auras", {}):
				assert_bool(Data.auras.has(aura_id)).override_failure_message("'%s' names unknown aura %s" % [id, aura_id]).is_true()
			checked += 1
	assert_int(checked).is_greater_equal(44)
	# every school has colors, and the relation outlines differ
	for school: String in ["physical", "fire", "frost", "shadow", "holy", "nature", "storm", "blood", "fel", "time"]:
		assert_bool(EffectsData.palette()["schools"].has(school)).override_failure_message(school).is_true()
	assert_bool(EffectsData.outline_color(true) == EffectsData.outline_color(false)).is_false()


func test_every_ability_plays_all_its_stages_and_cleans_up() -> void:
	var errors_before: int = Log.error_count
	for id: String in Data.effects:
		var ab: Dictionary = Data.abilities[id]
		var d: EffectsDirector = _director()
		var tgt: int = ME if ab["target"] == "self" else (ALLY if ab["target"] == "ally" else ENEMY)
		if ab["cast_type"] in ["cast", "channel"]:
			d.push_events([_ev("cast_start", ME, tgt, id, {"end_tick": 91})])
		d.push_events([_ev("channel_end" if ab["cast_type"] == "channel" else "cast_success", ME, tgt, id)])
		var hits: Array = [_ev("damage", ME, tgt, id, {"amount": 1000, "crit": true})]
		for eff: Dictionary in ab["effects"]:
			if eff["type"] == "heal":
				hits.append(_ev("heal", ME, tgt, id, {"amount": 1000}))
			if eff["type"] == "apply_aura":
				hits.append(_ev("aura_applied", ME, tgt, "", {"aura": eff["aura"]}))
			if eff["type"] in ["charge", "teleport"]:
				d.push_view(_view(2, {ME: {"position": Vector3(0, 0, -8)}}))
				hits.append(_ev(eff["type"], ME, ME if eff["type"] == "teleport" else tgt))
		d.push_events(hits)
		assert_int(d.spawned).override_failure_message("'%s' showed nothing" % id).is_greater(0)
		_run(d, 2.0)
		for eff: Dictionary in ab["effects"]:
			if eff["type"] == "apply_aura":
				d.push_events([_ev("aura_removed", -1, tgt, "", {"aura": eff["aura"]})])
		_run(d, 1.0)
		assert_int(d.active.size()).override_failure_message("'%s' left %d effects: %s" % [id, d.active.size(),
			d.active.map(func(v: Vfx) -> String: return v.name)]).is_equal(0)
		assert_int(d.particles_live).is_equal(0)
		d.queue_free()
	assert_int(Log.error_count - errors_before).is_equal(0)


# ------------------------------------------------------------------ stages

func test_cast_event_spawns_a_hand_glow_that_is_freed_after_the_cast() -> void:
	var d: EffectsDirector = _director()
	d.push_events([_ev("cast_start", ME, ENEMY, "rime_bolt", {"end_tick": 109})])
	var glow: Vfx = d.cast_vfx(ME)
	assert_object(glow).is_not_null()
	assert_int(glow.kind).is_equal(Vfx.Kind.CAST)
	assert_str(glow.school).is_equal("frost")
	assert_int(glow.emitters.size()).is_greater(0)
	_run(d, 1.0)  # still casting: the glow stays and follows the right hand
	assert_bool(glow.stopping).is_false()
	var hand: Vector3 = d.anchor_position(ME, "hand_r")
	assert_float((glow.parts[0]["node"] as Node3D).global_position.distance_to(hand)).is_less(0.01)
	d.push_events([_ev("cast_success", ME, ENEMY, "rime_bolt")])
	assert_object(d.cast_vfx(ME)).is_null()
	assert_bool(glow.stopping).is_true()
	_run(d, 0.5)
	assert_bool(d.active.has(glow)).is_false()
	assert_bool(glow.is_queued_for_deletion()).is_true()


func test_view_without_a_cast_ends_the_glow() -> void:
	# a lost cast_failed event must not leave a glow behind: the view is the truth
	var d: EffectsDirector = _director()
	var cast: Dictionary = {"ability": "mending_light", "target": ALLY, "start_tick": 1, "end_tick": 121, "channel": false}
	d.push_view(_view(2, {ME: {"cast": cast}}))
	assert_object(d.cast_vfx(ME)).is_not_null()
	var anchors: Array = d.cast_vfx(ME).parts.map(func(part: Dictionary) -> String: return part["anchor"])
	assert_array(anchors).contains_exactly(["hand_r", "hand_l", "feet"])  # both hands and a ring at the feet
	d.push_view(_view(3))
	assert_object(d.cast_vfx(ME)).is_null()
	_run(d, 0.5)
	assert_int(d.effects_of(Vfx.Kind.CAST).size()).is_equal(0)


func test_projectile_flies_from_caster_to_target_and_triggers_the_impact() -> void:
	var d: EffectsDirector = _director()
	d.push_events([_ev("cast_success", ME, ENEMY, "rime_bolt")])
	var shots: Array[Vfx] = d.effects_of(Vfx.Kind.PROJECTILE)
	assert_int(shots.size()).is_equal(1)
	var shot: Vfx = shots[0]
	var start: Vector3 = shot.global_position
	assert_float(start.distance_to(d.anchor_position(ME, "hand_r"))).is_less(0.01)
	assert_int(d.effects_of(Vfx.Kind.IMPACT).size()).is_equal(0)  # not before it arrives
	var aim: Vector3 = d.anchor_position(ENEMY, "chest")
	var last: float = start.distance_to(aim)
	var steps: int = 0
	while bool(shot.data.get("flying", false)) and steps < 120:
		d.update(DT)
		var dist: float = shot.global_position.distance_to(aim)
		assert_float(dist).is_less(last)
		last = dist
		steps += 1
	assert_bool(shot.data.get("arrived", false)).is_true()
	# 20 m at 38 m/s, capped at 0.45 s of flight
	assert_float(steps * DT).is_between(0.4, 0.6)
	var impacts: Array[Vfx] = d.effects_of(Vfx.Kind.IMPACT)
	assert_int(impacts.size()).is_equal(1)
	assert_str(impacts[0].style).is_equal("shards")
	assert_float(impacts[0].global_position.distance_to(aim)).is_less(0.01)
	_run(d, 1.5)
	assert_int(d.active.size()).is_equal(0)


func test_enemy_ground_effects_have_a_red_outline_and_allied_ones_do_not() -> void:
	var d: EffectsDirector = _director()
	d.push_events([_ev("cast_success", ENEMY, -1, "rimebind"), _ev("cast_success", ME, -1, "rimebind"),
		_ev("cast_success", ALLY, -1, "psalm_of_dread"), _ev("cast_success", ENEMY_2, -1, "psalm_of_dread")])
	var rings: Array[Vfx] = d.effects_of(Vfx.Kind.GROUND)
	assert_int(rings.size()).is_equal(4)
	for v: Vfx in rings:
		var c: Color = _outline(v)
		var red: bool = c.r > 0.8 and c.g < 0.3 and c.b < 0.3
		assert_bool(v.hostile).is_equal(v.source in [ENEMY, ENEMY_2])
		assert_bool(red).override_failure_message("source %d outline %s" % [v.source, c]).is_equal(v.hostile)
		# radius from the ability data, centred on the caster, on the ground
		assert_float(v.data["radius"]).is_equal_approx(EffectsData.radius_of(v.ability), 1e-4)
		var at: Vector3 = d.anchor_position(v.source, "feet")
		assert_float(Vector2(v.global_position.x - at.x, v.global_position.z - at.z).length()).is_less(0.01)
		assert_float(v.global_position.y).is_equal_approx(0.0, 1e-4)
	# enemy ground effects outrank allied ones in the budget
	assert_int(rings.filter(func(v: Vfx) -> bool: return v.hostile)[0].priority).is_greater(
		rings.filter(func(v: Vfx) -> bool: return not v.hostile)[0].priority)
	_run(d, 2.0)
	assert_int(d.effects_of(Vfx.Kind.GROUND).size()).is_equal(0)


func test_ground_zone_centres_on_the_target() -> void:
	var d: EffectsDirector = _director()
	d.push_events([_ev("cast_success", ME, ALLY, "chorus_of_mending")])
	var zone: Vfx = d.effects_of(Vfx.Kind.GROUND)[0]
	assert_float(zone.global_position.distance_to(Vector3(3, 0, 0))).is_less(0.01)
	assert_bool(zone.hostile).is_false()


func test_aura_visuals_follow_applied_and_removed_events() -> void:
	var d: EffectsDirector = _director()
	d.push_events([_ev("aura_applied", ME, ENEMY, "", {"aura": "heartfrozen", "cc": "stun"})])
	var stun: Vfx = d.aura_vfx(ENEMY, "heartfrozen")
	assert_object(stun).is_not_null()
	assert_bool(stun.cc).is_true()
	assert_str(stun.style).is_equal("stun")
	assert_str(stun.school).is_equal("frost")
	d.update(DT)
	assert_float(stun.global_position.distance_to(d.anchor_position(ENEMY, "overhead"))).is_less(0.01)
	d.push_events([_ev("aura_applied", ENEMY, ME, "", {"aura": "psalm_dread"})])
	assert_str(d.aura_vfx(ME, "psalm_dread").style).is_equal("disorient")
	assert_str(d.aura_vfx(ME, "psalm_dread").school).is_equal("shadow")
	d.push_events([_ev("aura_removed", -1, ENEMY, "", {"aura": "heartfrozen"})])
	assert_object(d.aura_vfx(ENEMY, "heartfrozen")).is_null()
	assert_bool(stun.stopping).is_true()
	_run(d, 0.5)
	assert_bool(d.active.has(stun)).is_false()
	assert_bool(stun.is_queued_for_deletion()).is_true()
	assert_object(d.aura_vfx(ME, "psalm_dread")).is_not_null()  # untouched


func test_aura_visuals_follow_the_view() -> void:
	var d: EffectsDirector = _director()
	d.push_view(_view(2, {ALLY: {"auras": [{"id": "veil_of_faith", "source": ME}, {"id": "lingering_grace", "source": ME}]}}))
	assert_str(d.aura_vfx(ALLY, "veil_of_faith").style).is_equal("shield")
	assert_str(d.aura_vfx(ALLY, "lingering_grace").style).is_equal("hot")
	d.push_view(_view(3, {ALLY: {"auras": [{"id": "lingering_grace", "source": ME}]}}))
	assert_object(d.aura_vfx(ALLY, "veil_of_faith")).is_null()
	assert_object(d.aura_vfx(ALLY, "lingering_grace")).is_not_null()
	d.push_view(_view(4, {ALLY: {"auras": [{"id": "not_drawn_aura", "source": ME}]}}))
	_run(d, 0.5)
	assert_int(d.active.size()).is_equal(0)


func test_crowd_control_always_shows_within_the_aura_cap() -> void:
	var d: EffectsDirector = _director()
	for aura_id: String in ["chilled", "frostbitten", "gashed", "ruin_bleed", "crippled"]:
		d.push_events([_ev("aura_applied", ME, ENEMY, "", {"aura": aura_id})])
	var cap: int = int(EffectsData.budget()["max_auras_per_unit"])
	var shown: int = 0
	for key: String in d._auras:
		shown += 1 if key.begins_with("%d:" % ENEMY) else 0
	assert_int(shown).is_equal(cap)
	d.push_events([_ev("aura_applied", ME, ENEMY, "", {"aura": "rimebound"})])
	assert_object(d.aura_vfx(ENEMY, "rimebound")).is_not_null()
	assert_str(d.aura_vfx(ENEMY, "rimebound").style).is_equal("root")


func test_melee_swing_and_hit_spark_for_weapon_abilities() -> void:
	var d: EffectsDirector = _director()
	d.push_view(_view(2, {ENEMY: {"position": Vector3(0, 0, -2)}}))
	# auto attacks log no cast: the damage event swings
	d.push_events([_ev("damage", ME, ENEMY, "auto_attack", {"amount": 1200})])
	var swings: Array[Vfx] = d.effects_of(Vfx.Kind.MELEE)
	assert_int(swings.size()).is_equal(1)
	assert_str(swings[0].school).is_equal("physical")
	assert_int(d.effects_of(Vfx.Kind.IMPACT).size()).is_equal(1)
	assert_str(d.effects_of(Vfx.Kind.IMPACT)[0].style).is_equal("spark")
	# abilities swing on release and spark on each hit; consecutive swings alternate sides
	d.push_events([_ev("cast_success", ME, ENEMY, "grim_hack"), _ev("damage", ME, ENEMY, "grim_hack", {"amount": 5000})])
	swings = d.effects_of(Vfx.Kind.MELEE)
	assert_int(swings.size()).is_equal(2)
	var arc_a: Node3D = swings[0].get_node("Arc")
	var arc_b: Node3D = swings[1].get_node("Arc")
	assert_bool(signf(arc_a.scale.x) != signf(arc_b.scale.x)).is_true()
	assert_int(d.effects_of(Vfx.Kind.IMPACT).size()).is_equal(2)
	_run(d, 1.0)
	assert_int(d.active.size()).is_equal(0)


func test_charge_leaves_dust_along_the_path() -> void:
	var d: EffectsDirector = _director()
	d.push_view(_view(2, {ME: {"position": Vector3(0, 0, -18.5)}}))
	d.push_events([_ev("cast_success", ME, ENEMY, "warpath_charge"), _ev("charge", ME, ENEMY)])
	var dust: Array[Vfx] = d.effects_of(Vfx.Kind.DISPLACEMENT)
	assert_int(dust.size()).is_equal(1)
	assert_str(dust[0].style).is_equal("dust")
	# centred on the path from the old position to the new one
	assert_float(dust[0].global_position.distance_to(Vector3(0, 0, -9.25))).is_less(0.01)


func test_budget_bounds_effects_and_particles() -> void:
	var d: EffectsDirector = _director()
	var b: Dictionary = EffectsData.budget()
	for i: int in 400:
		d.push_events([_ev("cast_success", ME, ENEMY, "rime_bolt"), _ev("damage", ME, ENEMY, "rime_fan"),
			_ev("damage", ENEMY, ME, "auto_attack")])
		assert_int(d.active.size()).is_less_equal(int(b["max_effects"]))
		assert_int(d.particles_live).is_less_equal(int(b["max_particles"]))
	assert_int(d.dropped).is_greater(0)
	# crowd control still gets in when the budget is full
	d.push_events([_ev("aura_applied", ME, ENEMY, "", {"aura": "effigy_encased"})])
	assert_object(d.aura_vfx(ENEMY, "effigy_encased")).is_not_null()
	assert_int(d.get_children().filter(func(n: Node) -> bool: return not n.is_queued_for_deletion()).size()).is_equal(d.active.size())


# ------------------------------------------------------------------ practice fight

func test_effects_stay_bounded_in_a_thirty_second_practice_fight() -> void:
	var errors_before: int = Log.error_count
	var scene: Node3D = auto_free((load("res://scenes/game/practice.tscn") as PackedScene).instantiate())
	scene.options = {"manual": true, "kit": false, "gi": false, "lighting": false, "player_bot": true}
	add_child(scene)
	var fx: EffectsDirector = scene.renderer.effects
	var b: Dictionary = EffectsData.budget()
	var kinds: Dictionary = {}
	var peak: int = 0
	var nodes_at_10: int = 0
	for i: int in 30 * scene.world.tick_rate():
		scene.run_ticks(1)
		peak = maxi(peak, fx.active.size())
		assert_int(fx.active.size()).is_less_equal(int(b["max_effects"]))
		assert_int(fx.particles_live).is_less_equal(int(b["max_particles"]))
		for v: Vfx in fx.active:
			kinds[v.kind] = true
		if i % 60 == 59:
			await get_tree().process_frame  # let freed effects go
			if i == 10 * 60 - 1:
				nodes_at_10 = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	await get_tree().process_frame
	assert_int(Log.error_count - errors_before).is_equal(0)
	assert_int(fx.spawned).is_greater(50)
	for k: int in [Vfx.Kind.CAST, Vfx.Kind.IMPACT, Vfx.Kind.AURA]:
		assert_bool(kinds.has(k)).override_failure_message("never saw %s; saw %s" % [Vfx.Kind.keys()[k],
			kinds.keys().map(func(x: int) -> String: return Vfx.Kind.keys()[x])]).is_true()
	# no leaks: every child is a live, tracked effect; live effects are explained by the units'
	# casts and auras plus a few short-lived ones; the node count does not creep
	assert_int(fx.get_child_count()).is_equal(fx.active.size())
	var units: int = scene.renderer.units.size()
	assert_int(fx.active.size()).is_less_equal(units * (1 + int(b["max_auras_per_unit"])) + 20)
	var nodes_now: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	assert_int(nodes_now - nodes_at_10).override_failure_message("node count %d -> %d" % [nodes_at_10, nodes_now]).is_less(300)
	# when every unit leaves, every effect ends
	fx.push_view({"tick": 999999, "tick_rate": 60, "me": {"team": 0}, "units": []})
	for i: int in 180:
		fx.update(DT)
	assert_int(fx.active.size()).is_equal(0)
	Log.info("effects: practice fight spawned %d effects, peak %d live, %d dropped" % [fx.spawned, peak, fx.dropped])
