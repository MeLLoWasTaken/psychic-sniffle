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
const GATE_OPEN_DEPTH: float = 5.2  ## greybox gates sink into the floor this far when they open
const GATE_OPEN_RISE: float = 4.6  ## kit portcullises rise this far when they open
const KIT_TILE_M: float = 4.0  ## floor tiles and wall segments are 4 m wide
const KIT_WALL_HEIGHT_M: float = 6.0  ## wall and corner pieces are built 6 m tall
const KIT_PILLAR_RADIUS_M: float = 1.2
const KIT_PILLAR_HEIGHT_M: float = 6.0
const KIT_GALLOWS_SIZE_M: float = 5.0
const KIT_GATE_SIZE: Vector2 = Vector2(8.0, 5.0)  ## portcullis width and height
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
@export var use_kit: bool = true  ## dress the colliders with the map's art kit when it has one
@export var bake_gi: bool = true  ## bake bounced light (VoxelGI) when the map is built

var map: Dictionary = {}
var gates: Array[Node3D] = []
var gates_open: bool = false
var _materials: Dictionary = {}
var _kit: String = ""
var _kit_scenes: Dictionary = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


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
	_kit = str(map.get("kit", "")) if use_kit else ""
	if _kit != "" and _kit_piece("floor_tile") == null:
		Log.warn("map: kit %s is not built; using greybox" % _kit)
		_kit = ""
	if build_lighting:
		_build_lighting(Data.lighting.get(map.get("lighting_preset", ""), {}))
	_build_floor()
	_build_perimeter()
	for c: Dictionary in map["colliders"]:
		_build_collider(c)
	if _kit == "":
		_build_starting_rooms()
	else:
		_dress_with_kit()
	if build_lighting and bake_gi:
		_bake_gi()


## Triangles of every visible mesh in the arena (multimesh copies counted), for the budget
## check (docs/DESIGN.md: under 1.5 million visible triangles per arena).
func visible_triangles() -> int:
	var total: int = 0
	for n: Node in find_children("*", "GeometryInstance3D", true, false):
		var g: GeometryInstance3D = n
		if not g.is_visible_in_tree():
			continue
		if g is MeshInstance3D and (g as MeshInstance3D).mesh:
			total += _mesh_triangles((g as MeshInstance3D).mesh)
		elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh:
			var mm: MultiMesh = (g as MultiMeshInstance3D).multimesh
			total += _mesh_triangles(mm.mesh) * mm.instance_count
	return total


static func _mesh_triangles(mesh: Mesh) -> int:
	var t: int = 0
	for i: int in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(i)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		t += (idx.size() if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return t


## True when the map is dressed with its art kit rather than greybox shapes.
func has_kit() -> bool:
	return _kit != ""


## Open or close the gates. Open gates sink into the floor over `seconds` and stop blocking.
func set_gates_open(open: bool, seconds: float = 1.5) -> void:
	gates_open = open
	for g: Node3D in gates:
		var target_y: float = (GATE_OPEN_RISE if _kit != "" else -GATE_OPEN_DEPTH) if open else 0.0
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
		node.set_meta("collider", c)
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
	mi.set_meta("greybox", true)  # hidden when the map is dressed with its art kit
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


# ------------------------------------------------------------------ art kit

## Replace the greybox look with kit pieces. Collision stays on the greybox bodies, which match
## the server's colliders exactly; only their meshes are hidden.
func _dress_with_kit() -> void:
	_rng.seed = hash(map_id)
	for mi: Node in find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta("greybox"):
			(mi as MeshInstance3D).visible = false
	var kit_root: Node3D = Node3D.new()
	kit_root.name = "Kit"
	add_child(kit_root)
	var tiles: Array[Transform3D] = []
	var walls: Array[Transform3D] = []
	var corners: Array[Transform3D] = []
	var tile_top: float = _piece_aabb("floor_tile").end.y
	var half: float = float(map["bounds_half_m"])
	# courtyard and room floors: 4 m tiles, randomly turned, skipped where a wall fills them
	var n_tiles: int = int(ceil(half * 2.0 / KIT_TILE_M))
	for ix: int in n_tiles:
		for iz: int in n_tiles:
			var cx: float = -half + KIT_TILE_M * (ix + 0.5)
			var cz: float = -half + KIT_TILE_M * (iz + 0.5)
			if _tile_buried(Vector2(cx, cz)):
				continue
			var basis: Basis = Basis(Vector3.UP, _rng.randi_range(0, 3) * PI / 2)
			tiles.append(Transform3D(basis, Vector3(cx, -tile_top, cz)))
	for c: Dictionary in map["colliders"]:
		var tag: String = c.get("tag", "")
		if c["type"] == "box" and tag == "wall":
			_kit_wall_box(c, walls, corners, tiles, tile_top)
		elif c["type"] == "box" and tag == "gallows":
			_kit_place(kit_root, "gallows", _box_centre(c), 0.0, Vector3(_box_size(c).x / KIT_GALLOWS_SIZE_M, 1.0,
				_box_size(c).y / KIT_GALLOWS_SIZE_M))
		elif c["type"] == "circle":
			var r: float = float(c["radius"]) / KIT_PILLAR_RADIUS_M
			_kit_place(kit_root, "pillar", Vector3(c["center"][0], 0, c["center"][1]), _rng.randf() * TAU,
				Vector3(r, float(c.get("height", 6.0)) / KIT_PILLAR_HEIGHT_M, r))
	_kit_bounds_walls(walls)
	_kit_gates(kit_root)
	_kit_decor(kit_root)
	_multimesh(kit_root, "Tiles", "floor_tile", tiles)
	_multimesh(kit_root, "Walls", "wall", walls)
	_multimesh(kit_root, "Corners", "corner", corners)


## Facades on every open side of a wall block, quoins on its open corners, and a paved top.
func _kit_wall_box(c: Dictionary, walls: Array[Transform3D], corners: Array[Transform3D],
		tiles: Array[Transform3D], tile_top: float) -> void:
	var lo: Vector2 = Vector2(c["min"][0], c["min"][1])
	var hi: Vector2 = Vector2(c["max"][0], c["max"][1])
	var h: float = float(c.get("height", KIT_WALL_HEIGHT_M))
	var sides: Array = [  # [start, end, outward normal]
		[Vector2(lo.x, lo.y), Vector2(hi.x, lo.y), Vector2(0, -1)],
		[Vector2(hi.x, lo.y), Vector2(hi.x, hi.y), Vector2(1, 0)],
		[Vector2(hi.x, hi.y), Vector2(lo.x, hi.y), Vector2(0, 1)],
		[Vector2(lo.x, hi.y), Vector2(lo.x, lo.y), Vector2(-1, 0)],
	]
	for side: Array in sides:
		_facade_run(side[0], side[1], side[2], h, walls)
	for corner: Vector2 in [lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)]:
		var out: Vector2 = Vector2(signf(corner.x - (lo.x + hi.x) * 0.5), signf(corner.y - (lo.y + hi.y) * 0.5))
		if _open_at(corner + out * 0.8) and _open_at(corner + Vector2(out.x, 0) * 0.8) and _open_at(corner + Vector2(0, out.y) * 0.8):
			corners.append(Transform3D(Basis.from_scale(Vector3(1, h / KIT_WALL_HEIGHT_M, 1)), Vector3(corner.x, 0, corner.y)))
	# paved top, tiles stretched to fit the block exactly
	var size: Vector2 = hi - lo
	var nx: int = maxi(1, int(ceil(size.x / KIT_TILE_M - 0.01)))
	var nz: int = maxi(1, int(ceil(size.y / KIT_TILE_M - 0.01)))
	var sx: float = size.x / nx / KIT_TILE_M
	var sz: float = size.y / nz / KIT_TILE_M
	for ix: int in nx:
		for iz: int in nz:
			var p: Vector3 = Vector3(lo.x + (ix + 0.5) * size.x / nx, h - tile_top, lo.y + (iz + 0.5) * size.y / nz)
			tiles.append(Transform3D(Basis.from_scale(Vector3(sx, 1, sz)), p))


## Wall segments along a line, only where the ground beyond the line is open.
func _facade_run(a: Vector2, b: Vector2, n: Vector2, h: float, walls: Array[Transform3D]) -> void:
	var length: float = a.distance_to(b)
	var count: int = maxi(1, int(ceil(length / KIT_TILE_M - 0.01)))
	var seg: float = length / count
	var yaw: float = atan2(n.x, n.y)
	for i: int in count:
		var mid: Vector2 = a.lerp(b, (i + 0.5) / count)
		if not _open_at(mid + n * 0.8):
			continue
		var basis: Basis = Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(seg / KIT_TILE_M, h / KIT_WALL_HEIGHT_M, 1))
		walls.append(Transform3D(basis, Vector3(mid.x, 0, mid.y)))


## The arena bounds get facades too wherever open ground reaches them (the back of each room).
func _kit_bounds_walls(walls: Array[Transform3D]) -> void:
	var b: float = float(map["bounds_half_m"])
	var runs: Array = [
		[Vector2(-b, -b), Vector2(b, -b), Vector2(0, 1)], [Vector2(b, -b), Vector2(b, b), Vector2(-1, 0)],
		[Vector2(b, b), Vector2(-b, b), Vector2(0, -1)], [Vector2(-b, b), Vector2(-b, -b), Vector2(1, 0)],
	]
	for r: Array in runs:
		_facade_run(r[0], r[1], r[2], KIT_WALL_HEIGHT_M, walls)


## Portcullis in each gate (it moves with the gate node) and a stone lintel above it.
func _kit_gates(kit_root: Node3D) -> void:
	for g: Node3D in gates:
		var c: Dictionary = g.get_meta("collider")
		var size: Vector2 = _box_size(c)
		var along_z: bool = size.y > size.x
		var width: float = size.y if along_z else size.x
		var h: float = float(c.get("height", 5.0))
		var toward_centre: Vector2 = Vector2(-signf(g.position.x), 0) if along_z else Vector2(0, -signf(g.position.z))
		var yaw: float = atan2(toward_centre.x, toward_centre.y)
		var port: Node3D = _kit_instance("gate")
		port.rotation.y = yaw
		port.scale = Vector3(width / KIT_GATE_SIZE.x, h / KIT_GATE_SIZE.y, 1)
		g.add_child(port)
		var lintel: Node3D = _kit_instance("gate_lintel")
		lintel.rotation.y = yaw
		lintel.scale = Vector3((width + 1.0) / (KIT_GATE_SIZE.x + 1.0), 1, 1)
		lintel.position = g.position + Vector3(0, h, 0) - Vector3(toward_centre.x, 0, toward_centre.y) * 0.5
		kit_root.add_child(lintel)


func _kit_decor(kit_root: Node3D) -> void:
	for d: Dictionary in map.get("decor", []):
		var pos: Vector3 = Vector3(d["pos"][0], float(d.get("y", 0.0)), d["pos"][1])
		var node: Node3D = _kit_place(kit_root, str(d["piece"]), pos, deg_to_rad(float(d.get("yaw_deg", 0.0))), Vector3.ONE)
		if node and d.get("light", false):
			var light: OmniLight3D = OmniLight3D.new()
			light.name = "Fire"
			light.light_color = Color(1.0, 0.56, 0.24)
			light.light_energy = 2.2
			light.omni_range = 9.0
			light.omni_attenuation = 1.4
			light.light_volumetric_fog_energy = 0.6
			light.position = Vector3(0, 1.45, 0)
			node.add_child(light)


func _kit_place(parent: Node3D, piece: String, pos: Vector3, yaw: float, scl: Vector3) -> Node3D:
	var node: Node3D = _kit_instance(piece)
	if node == null:
		return null
	node.position = pos
	node.rotation.y = yaw
	node.scale = scl
	parent.add_child(node)
	return node


func _kit_piece(piece: String) -> PackedScene:
	if not _kit_scenes.has(piece):
		var path: String = "res://assets/kits/%s/%s_%s.glb" % [_kit, _kit, piece]
		_kit_scenes[piece] = load(path) if ResourceLoader.exists(path) else null
		if _kit_scenes[piece] == null:
			Log.warn("map: missing kit piece %s" % path)
	return _kit_scenes[piece]


func _kit_instance(piece: String) -> Node3D:
	var scene: PackedScene = _kit_piece(piece)
	return scene.instantiate() as Node3D if scene else null


## Bounds of a piece's meshes, in the piece's own space.
func _piece_aabb(piece: String) -> AABB:
	var node: Node3D = _kit_instance(piece)
	var box: AABB = AABB()
	var first: bool = true
	for mi: Node in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		var b: AABB = m.transform * m.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	node.free()
	return box


## Draw many copies of a piece in one batch.
func _multimesh(parent: Node3D, node_name: String, piece: String, transforms: Array[Transform3D]) -> void:
	var node: Node3D = _kit_instance(piece)
	if node == null or transforms.is_empty():
		if node:
			node.free()
		return
	for mi: Node in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m.mesh
		mm.instance_count = transforms.size()
		for i: int in transforms.size():
			mm.set_instance_transform(i, transforms[i] * m.transform)
		var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		mmi.name = node_name
		mmi.multimesh = mm
		parent.add_child(mmi)
	node.free()


func _open_at(p: Vector2) -> bool:
	var b: float = float(map["bounds_half_m"]) - 0.05
	if absf(p.x) > b or absf(p.y) > b:
		return false
	for c: Dictionary in map["colliders"]:
		if c.get("gate", false):
			continue
		if c["type"] == "circle":
			if p.distance_to(Vector2(c["center"][0], c["center"][1])) < float(c["radius"]):
				return false
		elif p.x > c["min"][0] and p.x < c["max"][0] and p.y > c["min"][1] and p.y < c["max"][1]:
			return false
	return true


## A floor tile is skipped when a wall block covers all of it.
func _tile_buried(centre: Vector2) -> bool:
	var h: float = KIT_TILE_M * 0.5
	for c: Dictionary in map["colliders"]:
		if c["type"] != "box" or c.get("gate", false) or c.get("tag", "") != "wall":
			continue
		if centre.x - h >= c["min"][0] and centre.x + h <= c["max"][0] and centre.y - h >= c["min"][1] and centre.y + h <= c["max"][1]:
			return true
	return false


static func _box_centre(c: Dictionary) -> Vector3:
	return Vector3((float(c["min"][0]) + float(c["max"][0])) * 0.5, 0, (float(c["min"][1]) + float(c["max"][1])) * 0.5)


static func _box_size(c: Dictionary) -> Vector2:
	return Vector2(float(c["max"][0]) - float(c["min"][0]), float(c["max"][1]) - float(c["min"][1]))


# ------------------------------------------------------------------ lighting

## Bounced light: a VoxelGI volume over the whole arena, baked from the static geometry and the
## sun and fire lights when the map is built (about a second). Light bouncing off the lit walls
## fills shadowed corners, which the flat ambient color cannot do.
func _bake_gi() -> void:
	var half: float = float(map["bounds_half_m"])
	var gi: VoxelGI = VoxelGI.new()
	gi.name = "BouncedLight"
	gi.size = Vector3(half * 2.0 + 2.0, 16.0, half * 2.0 + 2.0)
	gi.position = Vector3(0, 7.0, 0)
	gi.subdiv = VoxelGI.SUBDIV_128
	add_child(gi)
	var t0: int = Time.get_ticks_msec()
	gi.bake(self)
	if gi.data:
		gi.data.energy = 1.0
		gi.data.propagation = 0.7
	Log.info("map: baked bounced light in %d ms" % (Time.get_ticks_msec() - t0))


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
	if preset.has("grade"):
		env.adjustment_color_correction = _grade_texture(preset["grade"])
	var we: WorldEnvironment = WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)
	add_child(_light("Sun", preset["sun"]))
	if preset.has("fill"):
		add_child(_light("Fill", preset["fill"]))


## Split-tone color grade as per-channel curves: shadows lean toward one color, highlights
## toward another, midtones stay neutral.
static func _grade_texture(grade: Dictionary) -> GradientTexture1D:
	var g: Gradient = Gradient.new()
	var sh: Color = _rgb(grade["shadows"])
	var hi: Color = _rgb(grade["highlights"])
	g.set_offset(0, 0.0)
	g.set_color(0, sh)
	g.set_offset(1, 1.0)
	g.set_color(1, hi)
	g.add_point(0.5, Color(0.5, 0.5, 0.5))
	var tex: GradientTexture1D = GradientTexture1D.new()
	tex.gradient = g
	tex.width = 256
	return tex


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
