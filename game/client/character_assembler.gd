class_name CharacterAssembler
extends RefCounted
## Builds an overhaul character from a look (backlog G-05): the body of its type with the face's
## blend shape, hair and beard unless a helm hides them, one armor piece per slot and an off-hand
## piece, all skinned to the body's one skeleton, recoloured by the character shaders.
## Usage: var model: Node3D = CharacterAssembler.build(look, spec_id, team)
##        var player: AnimationPlayer = CharacterRig.setup(CharacterAssembler.rig_asset(look, spec_id), model)

const SKIN_SHADER: Shader = preload("res://assets/shaders/character_skin.gdshader")
const PIECE_SHADER: Shader = preload("res://assets/shaders/character_piece.gdshader")
## The neutral colours the assets were baked in (tools/blender: build_body palette, build_piece MATERIALS,
## the hair specs' palette); dyes and tones are applied as ratios to these.
const NEUTRAL_SKIN: Color = Color("#b08a70")
const NEUTRAL_HAIR: Color = Color("#b4aa9e")
const NEUTRAL_DYE: Dictionary = {"primary": "#cfc8bc", "secondary": "#d2c4a0", "metal": "#a9adb3"}
const MARKS: Array[String] = ["brow_scar", "cheek_scar", "lip_scar", "stripes", "eye_band", "jaw_lines"]
## Team colours on the cape and the chest's primary dye in matches (docs/DESIGN.md).
const TEAM_DYE: Array[String] = ["#8e2424", "#3c5a86"]

static var _scenes: Dictionary = {}


## The asset-shaped dictionary CharacterRig.setup reads: the body build and the spec's weapon.
static func rig_asset(look: Dictionary, spec_id: String) -> Dictionary:
	var char_asset: Dictionary = WorldRenderer.character_asset(spec_id)
	return {"id": "look_%s" % spec_id, "body_build": str(look.get("body", "male")),
		"params": {"weapon": str(char_asset.get("params", {}).get("weapon", ""))}}


static func build(look: Dictionary, spec_id: String, team: int = -1) -> Node3D:
	var body_type: String = str(look.get("body", "male"))
	var body_asset: Dictionary = Data.assets.get("body_%s" % body_type, {})
	var model: Node3D = _instance(CharacterRig.res_path(body_asset))
	if model == null:
		return null
	model.name = "Look"
	var sk: Skeleton3D = CharacterRig.skeleton_of(model)
	if sk == null:
		return model
	var body_mesh: MeshInstance3D = _first_mesh(sk)
	if body_mesh:
		body_mesh.material_override = _skin_material(body_mesh, look, body_type)
		var hair_col: Color = Color(str(Appearance.option("hair_colors", str(look.get("hair_color", ""))).get("color", "#5e3d26")))
		(body_mesh.material_override as ShaderMaterial).set_shader_parameter("brow_color", hair_col.darkened(0.45))
		_set_face(body_mesh, str(look.get("face", "neutral")))
	var hidden: Array[String] = Appearance.hidden(look)
	var hair_tint: Color = Color(str(Appearance.option("hair_colors", str(look.get("hair_color", ""))).get("color", "#5e3d26")))
	if "hair" not in hidden and str(look.get("hair", "none")) != "none":
		_attach(sk, "hair_%s_%s" % [look["hair"], body_type], {"tint": hair_tint}, look)
	if "beard" not in hidden and body_type == "male" and str(look.get("beard", "none")) != "none":
		_attach(sk, "beard_%s_male" % look["beard"], {"tint": hair_tint}, look)
	for slot: String in Appearance.SLOTS:
		var asset_id: String = Appearance.piece_asset(str(look.get("pieces", {}).get(slot, "")), body_type)
		if asset_id == "":
			continue
		var dyes: Dictionary = (look.get("dyes", {}).get(slot, {}) as Dictionary).duplicate()
		if team >= 0 and slot in ["back", "chest"]:
			dyes["primary"] = TEAM_DYE[team % TEAM_DYE.size()]
		_attach(sk, asset_id, {"dyes": dyes}, look)
	var offhand: String = str(WorldRenderer.character_asset(spec_id).get("params", {}).get("offhand", ""))
	if offhand != "" and Data.assets.has("%s_%s" % [offhand, body_type]):
		_attach(sk, "%s_%s" % [offhand, body_type], {"dyes": look.get("dyes", {}).get("chest", {})}, look)
	model.scale = Vector3.ONE * clampf(float(look.get("height", 1.0)), Appearance.HEIGHT_MIN, Appearance.HEIGHT_MAX)
	return model


static func _instance(path: String) -> Node3D:
	if path == "" or not ResourceLoader.exists(path):
		Log.warn("character_assembler: missing %s" % path)
		return null
	if not _scenes.has(path):
		_scenes[path] = load(path)
	return (_scenes[path] as PackedScene).instantiate()


static func _first_mesh(n: Node) -> MeshInstance3D:
	for c: Node in n.find_children("*", "MeshInstance3D", true, false):
		return c as MeshInstance3D
	return null


## Moves a piece's meshes onto the body's skeleton (skins bind by bone name) with its material.
static func _attach(sk: Skeleton3D, asset_id: String, colours: Dictionary, look: Dictionary) -> void:
	var asset: Dictionary = Data.assets.get(asset_id, {})
	var scene: Node3D = _instance(CharacterRig.res_path(asset))
	if scene == null:
		return
	for mi: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		var xf: Transform3D = mi.transform
		mi.get_parent().remove_child(mi)
		mi.owner = null   # it leaves the piece's scene, which is freed below
		mi.name = asset_id
		sk.add_child(mi)
		mi.transform = xf
		mi.skeleton = NodePath("..")
		mi.material_override = _piece_material(mi, asset_id, colours)
		_set_face(mi, str(look.get("face", "neutral")))   # beards follow the face presets
	scene.free()


static func _textures(mi: MeshInstance3D) -> Dictionary:
	var m: StandardMaterial3D = mi.get_active_material(0) as StandardMaterial3D
	if m == null:
		return {}
	return {"albedo": m.albedo_texture, "normal": m.normal_texture, "orm": m.roughness_texture}


static func _skin_material(mi: MeshInstance3D, look: Dictionary, body_type: String) -> ShaderMaterial:
	var t: Dictionary = _textures(mi)
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = SKIN_SHADER
	mat.set_shader_parameter("albedo_tex", t.get("albedo"))
	mat.set_shader_parameter("normal_tex", t.get("normal"))
	mat.set_shader_parameter("orm_tex", t.get("orm"))
	for pair: Array in [["mask_tex", "mask"], ["marks_a_tex", "marks_a"], ["marks_b_tex", "marks_b"], ["face_tex", "face"]]:
		var path: String = "res://assets/characters/body_%s_%s.png" % [body_type, pair[1]]
		if ResourceLoader.exists(path):
			mat.set_shader_parameter(pair[0], load(path))
	var tone: Color = Color(str(Appearance.option("skin_tones", str(look.get("skin", ""))).get("color", "#d3a27d")))
	mat.set_shader_parameter("skin_ratio", _ratio(tone, NEUTRAL_SKIN))
	var iris: Color = Color(str(Appearance.option("eye_colors", str(look.get("eyes", ""))).get("color", "#4a2c18")))
	mat.set_shader_parameter("iris_color", iris)
	var wa: Vector3 = Vector3.ZERO
	var wb: Vector3 = Vector3.ZERO
	var mark: String = str(look.get("marking", "none"))
	var idx: int = MARKS.find(mark)
	if idx >= 0:
		var v: Vector3 = Vector3.ZERO
		v[idx % 3] = 0.9
		if idx < 3:
			wa = v
		else:
			wb = v
		var opt: Dictionary = Appearance.option("markings", mark)
		mat.set_shader_parameter("mark_color", Color(str(opt.get("color", look.get("paint", "#2b3a52")))))
	mat.set_shader_parameter("mark_weights_a", wa)
	mat.set_shader_parameter("mark_weights_b", wb)
	return mat


static func _piece_material(mi: MeshInstance3D, asset_id: String, colours: Dictionary) -> ShaderMaterial:
	var t: Dictionary = _textures(mi)
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = PIECE_SHADER
	mat.set_shader_parameter("albedo_tex", t.get("albedo"))
	mat.set_shader_parameter("normal_tex", t.get("normal"))
	mat.set_shader_parameter("orm_tex", t.get("orm"))
	var dye_path: String = "res://assets/armor/%s_dye.png" % asset_id
	var dyed: bool = colours.has("dyes") and ResourceLoader.exists(dye_path)
	mat.set_shader_parameter("use_dye", dyed)
	if dyed:
		mat.set_shader_parameter("dye_tex", load(dye_path))
		var dyes: Dictionary = colours["dyes"]
		for ch: String in NEUTRAL_DYE:
			var c: Color = Color(str(dyes.get(ch, NEUTRAL_DYE[ch])))
			mat.set_shader_parameter("%s_ratio" % ch, _ratio(c, Color(str(NEUTRAL_DYE[ch]))))
	var glow_path: String = "res://assets/armor/%s_glow.png" % asset_id
	mat.set_shader_parameter("use_glow", ResourceLoader.exists(glow_path))
	if ResourceLoader.exists(glow_path):
		mat.set_shader_parameter("glow_tex", load(glow_path))
	if colours.has("tint"):
		mat.set_shader_parameter("tint_ratio", _ratio(colours["tint"], NEUTRAL_HAIR))
	return mat


static func _set_face(mi: MeshInstance3D, face: String) -> void:
	if mi.mesh == null:
		return
	for i: int in mi.mesh.get_blend_shape_count():
		var bs: String = str(mi.mesh.get_blend_shape_name(i))
		mi.set_blend_shape_value(i, 1.0 if bs == "face_%s" % face else 0.0)


## Linear-space ratio of a colour to the neutral it replaces (the shaders multiply by it).
static func _ratio(c: Color, neutral: Color) -> Vector3:
	var a: Color = c.srgb_to_linear()
	var n: Color = neutral.srgb_to_linear()
	return Vector3(a.r / maxf(n.r, 0.001), a.g / maxf(n.g, 0.001), a.b / maxf(n.b, 0.001))
