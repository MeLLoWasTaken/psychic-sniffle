extends GdUnitTestSuite
## Review pass 3: bot target choice must not depend on unit id order. With every enemy at full
## health the first unit in id order used to be chosen, so how a team was listed decided whether
## its plate or its cloth member took the focus (one matchup went from 12% to 92%).


func _u(id: int, spec: String, health: float, pos: Vector3) -> Dictionary:
	return {"id": id, "spec": spec, "health": health, "max_health": 60000.0, "position": pos}


func test_ties_prefer_lighter_armor_in_any_order() -> void:
	var plate: Dictionary = _u(1, "warblade_carnage", 60000, Vector3(0, 0, 5))
	var cloth: Dictionary = _u(2, "arcanist_rime", 60000, Vector3(0, 0, 9))
	var me: Dictionary = _u(9, "warblade_carnage", 60000, Vector3.ZERO)
	assert_int(int(BotBrain._lowest([plate, cloth], me)["id"])).is_equal(2)
	assert_int(int(BotBrain._lowest([cloth, plate], me)["id"])).is_equal(2)


func test_ties_in_the_same_armor_go_to_the_nearer_unit() -> void:
	var far: Dictionary = _u(1, "oracle_grace", 60000, Vector3(0, 0, 20))
	var near: Dictionary = _u(2, "arcanist_rime", 60000, Vector3(0, 0, 4))
	var me: Dictionary = _u(9, "warblade_carnage", 60000, Vector3.ZERO)
	assert_int(int(BotBrain._lowest([far, near], me)["id"])).is_equal(2)
	assert_int(int(BotBrain._lowest([near, far], me)["id"])).is_equal(2)


func test_a_clearly_lower_unit_still_wins() -> void:
	var plate_low: Dictionary = _u(1, "warblade_carnage", 30000, Vector3(0, 0, 20))
	var cloth_full: Dictionary = _u(2, "arcanist_rime", 60000, Vector3(0, 0, 3))
	var me: Dictionary = _u(9, "oracle_grace", 60000, Vector3.ZERO)
	assert_int(int(BotBrain._lowest([cloth_full, plate_low], me)["id"])).is_equal(1)
	# within the tie band (3 points) armor decides: plate at 98% loses the pick to cloth at 100%
	var plate_98: Dictionary = _u(1, "warblade_carnage", 58800, Vector3(0, 0, 3))
	assert_int(int(BotBrain._lowest([plate_98, cloth_full], me)["id"])).is_equal(2)
