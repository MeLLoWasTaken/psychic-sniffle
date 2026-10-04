extends GdUnitTestSuite
## Looks (backlog G-05): defaults and bot looks are valid, the server's sanitizing keeps only real
## options and armor of the class's type, and looks travel in the hello and the appearance message.


func test_every_spec_has_a_valid_default_look() -> void:
	for spec_id: String in Data.specs:
		var a: Dictionary = Appearance.default_for(spec_id)
		assert_dict(Appearance.sanitize(a, spec_id)).is_equal(a)
		assert_str(str(a["body"])).is_equal("male")


func test_looks_have_the_documented_shape() -> void:
	# data/schemas/appearance.schema.json describes the saved and sent look
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/schemas/appearance.schema.json"))
	var a: Dictionary = Appearance.default_for("oracle_grace")
	var keys: Array = a.keys()
	keys.sort()
	var required: Array = schema["required"].duplicate()
	required.sort()
	assert_array(keys).is_equal(required)
	for slot: String in schema["properties"]["pieces"]["required"]:
		assert_bool(a["pieces"].has(slot)).is_true()


func test_templar_default_wears_the_crusader_set() -> void:
	var a: Dictionary = Appearance.default_for("templar_vanguard")
	assert_str(str(a["pieces"]["head"])).is_equal("templar_crusader:head")
	assert_str(str(a["dyes"]["chest"]["primary"])).is_equal("#2c4a82")
	assert_array(Appearance.hidden(a)).contains(["hair", "beard"])


func test_sanitize_drops_unknown_options_and_foreign_armor() -> void:
	var a: Dictionary = Appearance.default_for("arcanist_rime")   # cloth
	a["face"] = "no_such_face"
	a["height"] = 3.0
	a["beard"] = "full"
	a["body"] = "female"
	a["pieces"]["chest"] = "templar_crusader:chest"           # plate on a cloth class
	a["pieces"]["legs"] = ""                                    # legs can not be hidden
	a["dyes"]["chest"] = {"primary": "red", "secondary": "#112233", "metal": "#445566"}
	var s: Dictionary = Appearance.sanitize(a, "arcanist_rime")
	assert_str(str(s["face"])).is_equal("neutral")
	assert_float(float(s["height"])).is_equal(Appearance.HEIGHT_MAX)
	assert_str(str(s["beard"])).is_equal("none")                # beards are for the male body
	assert_str(str(s["pieces"]["chest"])).is_not_equal("templar_crusader:chest")
	assert_str(str(s["pieces"]["legs"])).is_equal(str(Appearance.default_for("arcanist_rime")["pieces"]["legs"]))
	assert_str(str(s["dyes"]["chest"]["secondary"])).is_equal("#112233")
	assert_str(str(s["dyes"]["chest"]["primary"])).is_not_equal("red")


func test_bot_looks_vary_and_stay_valid() -> void:
	var seen: Dictionary = {}
	for i: int in 12:
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = i
		var a: Dictionary = Appearance.random_for("templar_zealot", rng)
		assert_dict(Appearance.sanitize(a, "templar_zealot")).is_equal(a)
		seen["%s/%s/%s" % [a["body"], a["face"], a["skin"]]] = true
	assert_int(seen.size()).is_greater(6)


func test_looks_travel_in_the_hello_and_the_appearance_message() -> void:
	var text: String = Appearance.to_text(Appearance.default_for("templar_radiance"))
	var hello: Dictionary = Protocol.decode(Protocol.hello("p", "templar_radiance", "", {}, text))
	assert_str(str(hello["appearance"])).is_equal(text)
	var msg: Dictionary = Protocol.decode(Protocol.appearance(7, text))
	assert_int(int(msg["unit_id"])).is_equal(7)
	assert_dict(JSON.parse_string(str(msg["text"]))).is_equal(JSON.parse_string(text))


func test_the_assembler_puts_every_piece_on_one_skeleton() -> void:
	var a: Dictionary = Appearance.default_for("templar_vanguard")
	var model: Node3D = CharacterAssembler.build(a, "templar_vanguard", 1)
	assert_object(model).is_not_null()
	var sk: Skeleton3D = CharacterRig.skeleton_of(model)
	assert_object(sk).is_not_null()
	var meshes: Array = sk.find_children("*", "MeshInstance3D", true, false)
	# the body, eight armor pieces and the shield; the helm hides hair and beard
	assert_int(meshes.size()).is_equal(10)
	for mi: MeshInstance3D in meshes:
		assert_object(mi.material_override).is_instanceof(ShaderMaterial)
		assert_str(str(mi.skeleton)).is_equal("..")
	model.free()
