class_name MapBuilder
extends Node3D
## Builds an arena from its data file (data/maps/<id>.json), so what players see always
## matches the colliders the server uses for movement and line of sight.
##
## Greybox stage (backlog M1-14): every collider becomes a plain shape with a 1 m grid; the art
## kit (M1-15) swaps in Blender-built pieces by collider tag. Also builds the floor, perimeter
## walls, team-colored starting rooms, lighting from data/lighting/<preset>.json, and static
## collision on named physics layers for the camera and spell effects.

const LAYER_WORLD: int = 1  ## physics layer 1, "world": anything solid
const LAYER_LOS: int = 2  ## physics layer 2, "los_blocker": blocks line of sight
const PERIMETER_HEIGHT: float = 7.0
const GATE_OPEN_DEPTH: float = 5.2  ## gates sink into the floor this far when they open
const TEAM_COLORS: Array[Color] = [Color(0.62, 0.09, 0.08), Color(0.2, 0.36, 0.6)]  ## crimson, steel blue

const SURFACE_COLORS: Dictionary = {
	"floor": Color(0.2, 0.198, 0.195),
	"wall": Color(0.31, 0.31, 0.305),
	"pillar": Color(0.38, 0.375, 0.365),
	"gallows": Color(0.4, 0.3, 0.21),
	"gate": Color(0.13, 0.13, 0.14),
	"prop": Color(0.3, 0.28, 0.26),
}

@export var map_id: String = "gallows_courtyard"
@export var build_lighting: bool = true

var map: Dictionary = {}
var gates: Array[Node3D] = []
var gates_open: bool = false
var _materials: Dictionary = {}


func _ready() -> void:
	build()


func build() -> void:
	map = Data.maps.get(map_id, {})
	if map.is_empty():
		Log.error("map: unknown map %s" % map_id)
		return
	for child: Node in get_children():
		child.queue_free()
	gates.clear()
	if build_lighting:
		_build_lighting(Data.lighting.get(map.get("lighting_preset", ""), {}))
	_build_floor()
	_build_perimeter()
	for c: Dictionary in map["colliders"]:
		_build_collider(c)
	_build_starting_rooms()


## Open or close the gates. Open gates sink into the floor over `seconds` and stop blocking.
func set_gates_open(open: bool, seconds: float = 1.5) -> void:
	gates_open = open
	for g: Node3D in gates:
		var target_y: float = -GATE_OPEN_DEPTH if open else 0.0
		if seconds <= 0.0 or not is_inside_tree():
			g.position.y = target_y
		else:
			create_tween().tween_property(g, "position:y", target_y, seconds).set_trans(Tween.TRANS_QUAD)
		var body: StaticBody3D = g.get_node_or_null("Mesh/Body")
		if body:
			body.collision_layer = 0 if open else (1 << (LAYER_WORLD - 1)) | (1 << (LAYER_LOS - 1))


# ------------------------------------------------------------------ geometry

func _build_floor() -> void:
	var size: float = float(map["bounds_half_m"]) * 2.0 + 4.0
	var floor_mesh: BoxMesh = BoxMesh.new()
	floor_mesh.size = Vector3(size, 0.4, size)
	var mi: MeshInstance3D = _mesh("Floor", floor_mesh, _material("floor"))
	mi.position = Vector3(0, -0.2, 0)
	add_child(mi)
	_add_body(mi, BoxShape3D.new(), floor_mesh.size, false)


func _build_perimeter() -> void:
	var h: float = float(map["bounds_half_m"])
	var thick: float = 1.0
	var span: float = h * 2.0 + thick * 2.0
	for side: int in 4:
		var mesh: BoxMesh = BoxMesh.new()
		var along_x: bool = side < 2
		mesh.size = Vector3(span if along_x else thick, PERIMETER_HEIGHT, thick if along_x else span)
		var mi: MeshInstance3D = _mesh("Perimeter%d" % side, mesh, _material("wall"))
		var off: float = h + thick * 0.5
		mi.position = Vector3(0, PERIMETER_HEIGHT * 0.5, off if side == 0 else -off) if along_x \
			else Vector3(off if side == 2 else -off, PERIMETER_HEIGHT * 0.5, 0)
		add_child(mi)
		_add_body(mi, BoxShape3D.new(), mesh.size, true)


func _build_collider(c: Dictionary) -> void:
	var tag: String = c.get("tag", "wall" if c["type"] == "box" else "pillar")
	var height: float = float(c.get("height", 4.0))
	var node: Node3D = Node3D.new()
	node.name = "%s_%d" % [tag.capitalize(), get_child_count()]
	add_child(node)
	var mesh: Mesh
	var shape: Shape3D
	var size: Vector3
	if c["type"] == "circle":
		var cyl: CylinderMesh = CylinderMesh.new()
		cyl.top_radius = float(c["radius"])
		cyl.bottom_radius = float(c["radius"]) * 1.08  # slight taper reads as stone
		cyl.height = height
		cyl.radial_segments = 24
		mesh = cyl
		var cs: CylinderShape3D = CylinderShape3D.new()
		cs.radius = float(c["radius"])
		cs.height = height
		shape = cs
		node.position = Vector3(c["center"][0], 0, c["center"][1])
	else:
		var lo: Vector2 = Vector2(c["min"][0], c["min"][1])
		var hi: Vector2 = Vector2(c["max"][0], c["max"][1])
		size = Vector3(hi.x - lo.x, height, hi.y - lo.y)
		var box: BoxMesh = BoxMesh.new()
		box.size = size
		mesh = box
		shape = BoxShape3D.new()
		node.position = Vector3((lo.x + hi.x) * 0.5, 0, (lo.y + hi.y) * 0.5)
	var mi: MeshInstance3D = _mesh("Mesh", mesh, _material(tag))
	mi.position.y = height * 0.5
	node.add_child(mi)
	_add_body(mi, shape, size, bool(c["blocks_los"]))
	if c.get("gate", false):
		gates.append(node)  # its mesh and collision move with it when it opens
		_add_gate_trim(node, size, height)
		node.set_meta("team", 0 if node.position.x < 0 else 1)


## A team-colored band across the gate so each side's gate reads at a glance.
func _add_gate_trim(gate: Node3D, size: Vector3, height: float) -> void:
	var team: int = 0 if gate.position.x < 0 else 1
	var band: BoxMesh = BoxMesh.new()
	band.size = Vector3(size.x + 0.06, 0.35, size.z + 0.06)
	var mat: ShaderMaterial = _material("gate").duplicate()
	mat.set_shader_parameter("base_color", TEAM_COLORS[team])
	mat.set_shader_parameter("emission_color", TEAM_COLORS[team] * 0.25)
	for y: float in [height * 0.35, height * 0.8]:
		var mi: MeshInstance3D = _mesh("Trim", band, mat)
		mi.position.y = y
		gate.add_child(mi)


## Team-colored floor inside each starting room (the area behind that team's gate).
func _build_starting_rooms() -> void:
	for team: int in 2:
		var spawns: Array = map["spawns"]["team_a" if team == 0 else "team_b"]
		var centre: Vector3 = Vector3.ZERO
		for sp: Array in spawns:
			centre += Vector3(sp[0], 0, sp[2])
		centre /= spawns.size()
		var pad: BoxMesh = BoxMesh.new()
		pad.size = Vector3(3.2, 0.04, 7.2)
		var mat: ShaderMaterial = _material("floor").duplicate()
		mat.set_shader_parameter("base_color", TEAM_COLORS[team].darkened(0.35))
		mat.set_shader_parameter("emission_color", TEAM_COLORS[team] * 0.08)
		var mi: MeshInstance3D = _mesh("Room%d" % team, pad, mat)
		mi.position = centre + Vector3(0, 0.02, 0)
		add_child(mi)
		for sp: Array in spawns:
			var disc: CylinderMesh = CylinderMesh.new()
			disc.top_radius = 0.5
			disc.bottom_radius = 0.5
			disc.height = 0.03
			var dmat: ShaderMaterial = mat.duplicate()
			dmat.set_shader_parameter("base_color", TEAM_COLORS[team])
			dmat.set_shader_parameter("emission_color", TEAM_COLORS[team] * 0.3)
			var d: MeshInstance3D = _mesh("Spawn", disc, dmat)
			d.position = Vector3(sp[0], 0.05, sp[2])
			add_child(d)


func _mesh(node_name: String, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	return mi


## Static collision matching a mesh: world layer always, line-of-sight layer when it blocks.
func _add_body(mi: MeshInstance3D, shape: Shape3D, size: Vector3, blocks_los: bool) -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = (1 << (LAYER_WORLD - 1)) | ((1 << (LAYER_LOS - 1)) if blocks_los else 0)
	body.collision_mask = 0
	if shape is BoxShape3D:
		(shape as BoxShape3D).size = size
	var cs: CollisionShape3D = CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	mi.add_child(body)
	return body


func _material(surface: String) -> ShaderMaterial:
	if _materials.has(surface):
		return _materials[surface]
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = preload("res://assets/shaders/greybox.gdshader")
	mat.set_shader_parameter("base_color", SURFACE_COLORS.get(surface, SURFACE_COLORS["wall"]))
	if surface == "floor":
		mat.set_shader_parameter("minor_strength", 0.3)
	_materials[surface] = mat
	return mat


# ------------------------------------------------------------------ lighting

func _build_lighting(preset: Dictionary) -> void:
	if preset.is_empty():
		Log.warn("map: no lighting preset for %s" % map_id)
		return
	var env: Environment = Environment.new()
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = _rgb(preset["sky"]["top"])
	sky_mat.sky_horizon_color = _rgb(preset["sky"]["horizon"])
	sky_mat.ground_horizon_color = _rgb(preset["sky"]["horizon"])
	sky_mat.ground_bottom_color = _rgb(preset["sky"]["ground"])
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _rgb(preset["ambient"]["color"])
	env.ambient_light_energy = float(preset["ambient"]["energy"])
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var post: Dictionary = preset["post"]
	env.tonemap_exposure = float(post.get("exposure", 1.0))
	env.ssao_enabled = bool(post.get("ssao", true))
	env.glow_enabled = true
	env.glow_intensity = float(post.get("glow_intensity", 0.5))
	env.glow_bloom = 0.05
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = float(preset["fog"]["density"])
	env.volumetric_fog_albedo = _rgb(preset["fog"]["albedo"])
	env.volumetric_fog_emission = _rgb(preset["fog"].get("emission", [0, 0, 0]))
	env.adjustment_enabled = true
	env.adjustment_saturation = float(post.get("saturation", 1.0))
	env.adjustment_contrast = float(post.get("contrast", 1.0))
	var we: WorldEnvironment = WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)
	add_child(_light("Sun", preset["sun"]))
	if preset.has("fill"):
		add_child(_light("Fill", preset["fill"]))


func _light(node_name: String, cfg: Dictionary) -> DirectionalLight3D:
	var l: DirectionalLight3D = DirectionalLight3D.new()
	l.name = node_name
	l.light_color = _rgb(cfg["color"])
	l.light_energy = float(cfg["energy"])
	l.rotation_degrees = Vector3(float(cfg["pitch_deg"]), float(cfg["yaw_deg"]), 0)
	l.shadow_enabled = bool(cfg.get("shadows", false))
	l.directional_shadow_max_distance = 70.0
	l.light_volumetric_fog_energy = 1.0 if l.shadow_enabled else 0.0
	return l


static func _rgb(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))
