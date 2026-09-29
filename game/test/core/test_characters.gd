extends GdUnitTestSuite
## Imported characters and weapons (backlog M1-18..M1-20): the standard skeleton, triangle
## budgets and generated levels of detail survive the import into Godot.

const BONES: Array[String] = ["root", "pelvis", "spine", "chest", "neck", "head", "clavicle_l", "upperarm_l",
	"forearm_l", "hand_l", "clavicle_r", "upperarm_r", "forearm_r", "hand_r", "thigh_l", "calf_l", "foot_l",
	"thigh_r", "calf_r", "foot_r"]
const CHARACTERS: Array[String] = ["res://assets/characters/char_warblade_carnage.glb"]
const WEAPONS: Array[String] = ["res://assets/weapons/weapon_greatsword.glb"]


func _triangles(root: Node) -> int:
	var total: int = 0
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (n as MeshInstance3D).mesh
		for i: int in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(i)
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			total += (idx.size() if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return total


func test_characters_have_the_standard_skeleton_and_budget() -> void:
	for path: String in CHARACTERS:
		assert_bool(ResourceLoader.exists(path)).override_failure_message("%s not built" % path).is_true()
		var root: Node = auto_free((load(path) as PackedScene).instantiate())
		var skeletons: Array = root.find_children("*", "Skeleton3D", true, false)
		assert_int(skeletons.size()).is_equal(1)
		var sk: Skeleton3D = skeletons[0]
		for b: String in BONES:
			assert_int(sk.find_bone(b)).override_failure_message("%s: no bone %s" % [path, b]).is_not_equal(-1)
		var tris: int = _triangles(root)
		assert_int(tris).override_failure_message("%s: %d triangles" % [path, tris]).is_between(15000, 25000)


func test_characters_get_levels_of_detail() -> void:
	# the backlog asks characters for two lower LODs; Godot's importer generates them
	# (DECISIONS.md). Weapons are about 1,200 triangles and need none.
	for path: String in CHARACTERS:
		var root: Node = auto_free((load(path) as PackedScene).instantiate())
		for n: Node in root.find_children("*", "MeshInstance3D", true, false):
			var surface: Dictionary = RenderingServer.mesh_get_surface((n as MeshInstance3D).mesh.get_rid(), 0)
			assert_int((surface.get("lods", []) as Array).size()).override_failure_message(
				"%s has too few LODs" % path).is_greater_equal(2)


func test_weapons_hold_at_the_grip() -> void:
	for path: String in WEAPONS:
		var root: Node = auto_free((load(path) as PackedScene).instantiate())
		var box: AABB = AABB()
		for n: Node in root.find_children("*", "MeshInstance3D", true, false):
			box = (n as MeshInstance3D).mesh.get_aabb()
		assert_bool(box.position.y < 0.0 and box.end.y > 0.0).override_failure_message("%s: grip is not at the origin" % path).is_true()
		assert_float(box.size.y).is_between(0.8, 2.2)
