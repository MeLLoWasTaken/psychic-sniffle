class_name MapBuilder
extends Node3D
## Builds an arena from its data file (data/maps/<id>.json), so what players see always
## matches the colliders the server uses for movement and line of sight.
##
## Greybox stage (backlog M1-14): every collider becomes a plain shape with a 1 m grid; the art
## kit (M1-15) swaps in Blender-built pieces by collider tag. Also builds the floor, perimeter
## walls, team-colored starting rooms, lighting from data/lighting/<preset>.json, and static
## collision on named physics layers for the camera and spell effects.
## Dressing (backlog F-05, map data "dressing"): wall walks and ramparts, outer facades,
## gatehouses, piece variants, floor grime and puddle decals, and a skyline beyond the walls;
## decor pieces can carry looping effects (AmbientFx). None of it adds collision.

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
var pickups: Array[Node3D] = []  ## one per map pickup spot (M2-07), shown while it can be taken
var environment: Environment = null  ## the lighting preset's environment (settings toggle parts of it)
var _preset_shadows: Dictionary = {}  ## light name -> whether the preset gives it shadows
var _ssao_preset: Variant = null  ## whether the preset uses ambient occlusion
var _materials: Dictionary = {}
var _kit: String = ""
var _kit_scenes: Dictionary = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _dressing: Dictionary = {}  ## map data "dressing" (backlog F-05)
var _placements: Dictionary = {}  ## kit piece -> Array[Transform3D], drawn as one multimesh each
var _tag_nodes: Dictionary = {}  ## collider tag -> the nodes showing it (greybox and kit), for twists
var removed_tags: Dictionary = {}  ## tags a twist has taken away: their nodes are hidden, a wreck shown
var wrecks: Array[Node3D] = []  ## the wrecks left by collapses (tests, screenshots)
var water: MeshInstance3D = null  ## a flood's water surface, built when the water starts to rise
var water_level: float = 0.0  ## 0 (dry) to 1 (full): how high the flood stands (ArenaTwists.flood_level)

const WATER_LOW_Y: float = -0.08  ## the water surface just under the floor before it rises
const WATER_FULL_Y: float = 0.24  ## and at full flood: over the ankles
const WATER_SHADER: Shader = preload("res://scenes/maps/water.gdshader")
var skyline_placements: Dictionary = {}  ## skyline piece -> Array[Transform3D] (kept for tests)
var _grime_runs: Array = []  ## [a, b, outward normal] of every facade run: wall bases for grime decals
var _aabbs: Dictionary = {}  ## kit piece -> AABB
var _textures: Dictionary = {}  ## generated decal textures


func _ready() -> void:
	build()
	Settings.bus.changed.connect(_on_setting)


func build() -> void:
	map = Data.maps.get(map_id, {})
	if map.is_empty():
		Log.error("map: unknown map %s" % map_id)
		return
	for child: Node in get_children():
		child.queue_free()
	gates.clear()
	pickups.clear()
	_tag_nodes.clear()
	removed_tags.clear()
	wrecks.clear()
	water = null
	water_level = 0.0
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
	_build_pickups()
	if environment != null:
		_ssao_preset = environment.ssao_enabled
	apply_graphics()
	if build_lighting and bake_gi:
		_bake_gi()


## The regeneration pickups: the tuning's ambient effect at each spot, hidden until set_pickups.
func _build_pickups() -> void:
	var fx_id: String = str(Data.tuning.get("arena", {}).get("pickup_effect", ""))
	var spots: Array = map.get("pickups", [])
	for i: int in spots.size():
		var holder: Node3D = Node3D.new()
		holder.name = "Pickup_%d" % i
		holder.position = Vector3(spots[i][0], spots[i][1], spots[i][2])
		holder.visible = false
		var fx: AmbientFx = AmbientFx.create(fx_id, hash(map_id) + 100 + i) if fx_id != "" else null
		if fx:
			holder.add_child(fx)
		add_child(holder)
		pickups.append(holder)


func _tag_node(tag: String, node: Node3D) -> void:
	if tag != "" and node != null:
		if not _tag_nodes.has(tag):
			_tag_nodes[tag] = []
		(_tag_nodes[tag] as Array).append(node)


## The map's twists at this point of the match (M2-16): a collapse hides what it took away and
## leaves a wreck. `seconds` is match time; nothing happens during preparation. Idempotent, so
## the match scenes call it every frame and a late joiner sees the same arena.
func set_match_time(seconds: float, preparing: bool) -> void:
	if preparing:
		return
	for t: Dictionary in map.get("twists", []):
		if str(t.get("type", "")) == "flood":
			_set_flood(t, ArenaTwists.flood_level(t, seconds))
	var gone: Dictionary = ArenaTwists.removed_tags(map.get("twists", []), seconds)
	for tag: String in gone:
		if removed_tags.has(tag):
			continue
		removed_tags[tag] = true
		for n: Node3D in _tag_nodes.get(tag, []):
			n.visible = false
			for body: Node in n.find_children("*", "StaticBody3D", true, false):
				(body as StaticBody3D).collision_layer = 0  # the camera and spells pass through now
		_add_wreck(tag)


## A flood's water at `level` (0 to 1): a surface over the arena floor outside the dry rectangles,
## rising from just under the floor to over the ankles.
func _set_flood(twist: Dictionary, level: float) -> void:
	water_level = level
	if level <= 0.0:
		if water != null:
			water.visible = false
		return
	if water == null:
		water = _build_water(twist)
		add_child(water)
	water.visible = true
	water.position.y = lerpf(WATER_LOW_Y, WATER_FULL_Y, level)


## The water surface: half-metre cells over the arena interior (inside the walls) that are not dry.
func _build_water(twist: Dictionary) -> MeshInstance3D:
	var dry: Array[Rect2] = []
	for r: Array in twist.get("dry", []):
		dry.append(Rect2(Vector2(r[0][0], r[0][1]), Vector2(r[1][0] - r[0][0], r[1][1] - r[0][1])))
	var inner: Rect2 = _interior_rect()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	var cell: float = 0.5  # half-metre cells, so dry edges on the half metre fall between cells
	for ix: int in range(floori(inner.position.x / cell), ceili(inner.end.x / cell)):
		for iz: int in range(floori(inner.position.y / cell), ceili(inner.end.y / cell)):
			var c: Vector2 = Vector2(ix + 0.5, iz + 0.5) * cell
			if not inner.has_point(c) or dry.any(func(r: Rect2) -> bool: return r.has_point(c)):
				continue
			var a: Vector3 = Vector3(ix, 0, iz) * cell
			var b: Vector3 = Vector3(ix + 1, 0, iz) * cell
			var d: Vector3 = Vector3(ix, 0, iz + 1) * cell
			var e: Vector3 = Vector3(ix + 1, 0, iz + 1) * cell
			for v: Vector3 in [a, d, b, b, d, e]:
				st.add_vertex(v)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "FloodWater"
	mi.mesh = st.commit()
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = WATER_SHADER
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## The open floor inside the outer walls (the colliders tagged "wall"), as a ground rectangle.
func _interior_rect() -> Rect2:
	var half: float = float(map.get("bounds_half_m", 20.0))
	var lo: Vector2 = Vector2(-half, -half)
	var hi: Vector2 = Vector2(half, half)
	for c: Dictionary in map.get("colliders", []):
		if c["type"] != "box" or str(c.get("tag", "")) != "wall":
			continue
		var bmin: Vector2 = Vector2(c["min"][0], c["min"][1])
		var bmax: Vector2 = Vector2(c["max"][0], c["max"][1])
		# a wall spanning most of the width bounds the floor on that side
		if bmax.x - bmin.x > half:
			if bmin.y > 0.0:
				hi.y = minf(hi.y, bmin.y)
			else:
				lo.y = maxf(lo.y, bmax.y)
		elif bmax.y - bmin.y > half * 0.5:
			if bmin.x > 0.0:
				hi.x = minf(hi.x, bmin.x)
			else:
				lo.x = maxf(lo.x, bmax.x)
	return Rect2(lo, hi - lo)


## What a collapse leaves where `tag` stood: broken beams and planks lying low across its
## footprint (they block nothing, like the server's open ground) and a burst of dust.
func _add_wreck(tag: String) -> void:
	var foot: Rect2 = Rect2()
	var first: bool = true
	for c: Dictionary in map.get("colliders", []):
		if str(c.get("tag", "")) != tag:
			continue
		var r: Rect2 = Rect2(Vector2(c["center"][0], c["center"][1]) - Vector2.ONE * float(c["radius"]),
			Vector2.ONE * float(c["radius"]) * 2.0) if c["type"] == "circle" \
			else Rect2(Vector2(c["min"][0], c["min"][1]), Vector2(c["max"][0] - c["min"][0], c["max"][1] - c["min"][1]))
		foot = r if first else foot.merge(r)
		first = false
	if first:
		return
	var wreck: Node3D = Node3D.new()
	wreck.name = "Wreck_%s" % tag
	wreck.position = Vector3(foot.get_center().x, 0.0, foot.get_center().y)
	add_child(wreck)
	wrecks.append(wreck)
	var mat: Material = _wreck_material(tag)
	var stone: Material = _wreck_material("pillar")  # the plinth breaks into the arena's stone
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(map_id + tag)
	var span: float = maxf(foot.size.x, foot.size.y)
	for i: int in 30:
		var kind: int = 0 if i < 6 else (1 if i < 20 else 2)  # beams, planks, stones
		var box: BoxMesh = BoxMesh.new()
		match kind:
			0: box.size = Vector3(rng.randf_range(0.45, 0.8) * span, 0.3, 0.3)
			1: box.size = Vector3(rng.randf_range(0.9, 2.0), 0.07, rng.randf_range(0.22, 0.32))
			2:
				var st: float = rng.randf_range(0.25, 0.55)
				box.size = Vector3(st * rng.randf_range(1.0, 1.6), st * 0.7, st)
		var piece: MeshInstance3D = _mesh("Debris_%d" % i, box, stone if kind == 2 else mat)
		var x: float = rng.randf_range(-0.6, 0.6) * foot.size.x
		var z: float = rng.randf_range(-0.6, 0.6) * foot.size.y
		piece.position = Vector3(x, box.size.y * 0.5 + (rng.randf_range(0.0, 0.3) if kind == 1 else 0.0), z)
		piece.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.15, 0.15))
		piece.remove_meta("greybox")  # the wreck shows with the art kit too
		wreck.add_child(piece)
	wreck.add_child(_dust_burst(span, rng.randi()))


## The collapsed piece's own surface when the art kit has one (its first mesh's material), so the
## beams match what fell; the greybox color otherwise.
func _wreck_material(tag: String) -> Material:
	for n: Node3D in _tag_nodes.get(tag, []):
		for mi: Node in n.find_children("*", "MeshInstance3D", true, false):
			var m: MeshInstance3D = mi
			if m.has_meta("greybox") or m.mesh == null or m.mesh.get_surface_count() == 0:
				continue
			var mat: Material = m.get_active_material(0)
			if mat != null:
				return mat
	return _material(tag)


## A one-shot cloud of dust rising from a collapse and settling.
func _dust_burst(span: float, seed_value: int) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Dust"
	p.amount = 48
	p.lifetime = 2.6
	p.one_shot = true
	p.explosiveness = 0.85
	p.randomness = 0.4
	p.seed = seed_value
	p.use_fixed_seed = true
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(span * 0.5, 0.3, span * 0.5)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 70.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 3.2
	pm.gravity = Vector3(0, -0.6, 0)
	pm.damping_min = 1.5
	pm.damping_max = 2.5
	pm.scale_min = 2.0
	pm.scale_max = 3.6
	var fade: Gradient = Gradient.new()
	fade.set_color(0, Color(0.36, 0.31, 0.26, 0.4))  # dusk-lit grit, not bright smoke
	fade.set_color(1, Color(0.3, 0.27, 0.24, 0.0))
	var ramp: GradientTexture1D = GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	p.process_material = pm
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	var tex: GradientTexture2D = GradientTexture2D.new()
	var g: Gradient = Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	mat.albedo_texture = tex
	quad.material = mat
	p.draw_pass_1 = quad
	p.position.y = 0.6
	p.emitting = true
	return p


## Show the pickups whose bit is set in `mask` (the match state's "pickups").
func set_pickups(mask: int) -> void:
	for i: int in pickups.size():
		pickups[i].visible = mask & (1 << i) != 0


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
	_tag_node(str(c.get("tag", "")), node)
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
## the server's colliders exactly; only their meshes are hidden. Everything the kit adds (walls,
## ramparts, gatehouses, decor, the skyline, floor decals) is visual only: no collision bodies.
## Repeated pieces are drawn as one multimesh per piece to keep draw calls low.
func _dress_with_kit() -> void:
	_rng.seed = hash(map_id)
	_placements = {}
	_grime_runs = []
	_dressing = map.get("dressing", {})
	for mi: Node in find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta("greybox"):
			(mi as MeshInstance3D).visible = false
	var kit_root: Node3D = Node3D.new()
	kit_root.name = "Kit"
	add_child(kit_root)
	var tile_top: float = _piece_aabb("floor_tile").end.y
	var half: float = float(map["bounds_half_m"])
	# courtyard and room floors: 4 m tiles, stretched a little so the grid ends exactly at the
	# bounds (nothing pokes out past the outer walls), randomly turned, skipped where a wall fills them
	var n_tiles: int = maxi(1, roundi(half * 2.0 / KIT_TILE_M))
	var step: float = half * 2.0 / n_tiles
	var tile_scale: Basis = Basis.from_scale(Vector3(step / KIT_TILE_M, 1, step / KIT_TILE_M))
	for ix: int in n_tiles:
		for iz: int in n_tiles:
			var cx: float = -half + step * (ix + 0.5)
			var cz: float = -half + step * (iz + 0.5)
			if _tile_buried(Vector2(cx, cz), step * 0.5):
				continue
			var basis: Basis = Basis(Vector3.UP, _rng.randi_range(0, 3) * PI / 2) * tile_scale
			_place("floor_tile", Transform3D(basis, Vector3(cx, -tile_top, cz)))
	for c: Dictionary in map["colliders"]:
		var tag: String = c.get("tag", "")
		if c["type"] == "box" and tag == "wall":
			_kit_wall_box(c)
		elif c["type"] == "box" and tag == "gallows":
			_tag_node(tag, _kit_place(kit_root, "gallows", _box_centre(c), 0.0, Vector3(_box_size(c).x / KIT_GALLOWS_SIZE_M, 1.0,
				_box_size(c).y / KIT_GALLOWS_SIZE_M)))
		elif c["type"] == "box" and tag == "tomb":
			# built with its long side along x (length_m x width_m, height_m tall); turned to the box
			var sz: Vector2 = _box_size(c)
			var th: float = _kit_param("tomb", "height_m", 3.2)
			_tag_node(tag, _kit_place(kit_root, "tomb", _box_centre(c), 0.0 if sz.x >= sz.y else PI / 2, Vector3(
				maxf(sz.x, sz.y) / _kit_param("tomb", "length_m", 6.4), float(c.get("height", th)) / th,
				minf(sz.x, sz.y) / _kit_param("tomb", "width_m", 2.8))))
		elif c["type"] == "circle":
			# each kit's pillar is built for its spec's radius_m and height_m (gallows 1.2 m, crypt 1.0 m)
			var r: float = float(c["radius"]) / _kit_param("pillar", "radius_m", KIT_PILLAR_RADIUS_M)
			_kit_place(kit_root, "pillar", Vector3(c["center"][0], 0, c["center"][1]), _rng.randf() * TAU,
				Vector3(r, float(c.get("height", 6.0)) / _kit_param("pillar", "height_m", KIT_PILLAR_HEIGHT_M), r))
	_kit_bounds_walls()
	if bool(_wall_top().get("outer_facades", false)):
		_kit_outer_walls()
	_kit_gates(kit_root)
	_kit_decor(kit_root)
	for piece: String in _placements:
		_multimesh(kit_root, piece.to_pascal_case(), piece, _placements[piece])
	_kit_floor_dressing(kit_root)
	_kit_skyline()


## Queue a copy of a kit piece. With `variants`, the piece may be swapped for one of its variants
## (map data dressing.variants: {piece: {variant: weight}}), when that variant is built.
func _place(piece: String, xf: Transform3D, variants: bool = true) -> void:
	var chosen: String = piece
	var table: Dictionary = _dressing.get("variants", {}).get(piece, {}) if variants else {}
	if not table.is_empty():
		var total: float = 0.0
		for v: String in table:
			total += float(table[v]) if _kit_piece(v) != null else 0.0
		var pick: float = _rng.randf() * total
		for v: String in table:
			if _kit_piece(v) == null:
				continue
			pick -= float(table[v])
			if pick <= 0.0:
				chosen = v
				break
	if not _placements.has(chosen):
		_placements[chosen] = [] as Array[Transform3D]
	(_placements[chosen] as Array[Transform3D]).append(xf)


func _wall_top() -> Dictionary:
	return _dressing.get("wall_top", {})


## Facades on every open side of a wall block, quoins on its open corners, and its top: a wall
## walk (dressing.wall_top.walk) or, without one, floor tiles.
func _kit_wall_box(c: Dictionary) -> void:
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
		_facade_run(side[0], side[1], side[2], h)
	for corner: Vector2 in [lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)]:
		var out: Vector2 = Vector2(signf(corner.x - (lo.x + hi.x) * 0.5), signf(corner.y - (lo.y + hi.y) * 0.5))
		if _open_at(corner + out * 0.8) and _open_at(corner + Vector2(out.x, 0) * 0.8) and _open_at(corner + Vector2(0, out.y) * 0.8):
			_place("corner", Transform3D(Basis.from_scale(Vector3(1, h / KIT_WALL_HEIGHT_M, 1)), Vector3(corner.x, 0, corner.y)))
	# the top, pieces stretched to fit the block exactly
	var walk: String = str(_wall_top().get("walk", "floor_tile"))
	if _kit_piece(walk) == null:
		walk = "floor_tile"
	var walk_top: float = _piece_aabb(walk).end.y
	var size: Vector2 = hi - lo
	var nx: int = maxi(1, int(ceil(size.x / KIT_TILE_M - 0.01)))
	var nz: int = maxi(1, int(ceil(size.y / KIT_TILE_M - 0.01)))
	var sx: float = size.x / nx / KIT_TILE_M
	var sz: float = size.y / nz / KIT_TILE_M
	for ix: int in nx:
		for iz: int in nz:
			var p: Vector3 = Vector3(lo.x + (ix + 0.5) * size.x / nx, h - walk_top, lo.y + (iz + 0.5) * size.y / nz)
			_place(walk, Transform3D(Basis.from_scale(Vector3(sx, 1, sz)), p))


## Wall segments along a line wherever the ground beyond it is open, each open stretch tiled on
## its own so facades start and end where the open ground does. With dressing.wall_top.parapet,
## each segment is crowned with a rampart; each also gets grime along its base (floor dressing).
func _facade_run(a: Vector2, b: Vector2, n: Vector2, h: float) -> void:
	var yaw: float = atan2(n.x, n.y)
	var parapet: String = str(_wall_top().get("parapet", ""))
	var length: float = a.distance_to(b)
	for iv: Array in _intervals(a, b, func(p: Vector2) -> bool: return _open_at(p + n * 0.8)):
		if not iv[2]:
			continue
		var a2: Vector2 = a.lerp(b, iv[0])
		var b2: Vector2 = a.lerp(b, iv[1])
		var run: float = (float(iv[1]) - float(iv[0])) * length
		if run < 0.3:
			continue
		var count: int = maxi(1, int(ceil(run / KIT_TILE_M - 0.01)))
		var seg: float = run / count
		for i: int in count:
			var mid: Vector2 = a2.lerp(b2, (i + 0.5) / count)
			var basis: Basis = Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(seg / KIT_TILE_M, h / KIT_WALL_HEIGHT_M, 1))
			_place("wall", Transform3D(basis, Vector3(mid.x, 0, mid.y)))
			if parapet != "":
				_place(parapet, Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(seg / KIT_TILE_M, 1, 1)),
					Vector3(mid.x, h, mid.y)))
		_grime_runs.append([a2, b2, n])


## Split the line a..b into stretches where probe(point) is the same: [[t0, t1, state], ...].
static func _intervals(a: Vector2, b: Vector2, probe: Callable, step_m: float = 0.25) -> Array:
	var steps: int = maxi(1, int(ceil(a.distance_to(b) / step_m)))
	var out: Array = []
	var start: float = 0.0
	var state: bool = probe.call(a.lerp(b, 0.5 / steps))
	for i: int in range(1, steps):
		var s: bool = probe.call(a.lerp(b, (i + 0.5) / steps))
		if s != state:
			out.append([start, float(i) / steps, state])
			start = float(i) / steps
			state = s
	out.append([start, 1.0, state])
	return out


## The arena bounds get facades too wherever open ground reaches them (the back of each room).
func _kit_bounds_walls() -> void:
	var b: float = float(map["bounds_half_m"])
	var runs: Array = [
		[Vector2(-b, -b), Vector2(b, -b), Vector2(0, 1)], [Vector2(b, -b), Vector2(b, b), Vector2(-1, 0)],
		[Vector2(b, b), Vector2(-b, b), Vector2(0, -1)], [Vector2(-b, b), Vector2(-b, -b), Vector2(1, 0)],
	]
	for r: Array in runs:
		_facade_run(r[0], r[1], r[2], KIT_WALL_HEIGHT_M)


## The outside of the arena walls, seen from high cameras: facades facing out along the bounds,
## crowned with ramparts, and quoins on the four outer corners. Where a room reaches the bounds
## its wall is only a facade thick, so the outer facade stands just behind that facade.
func _kit_outer_walls() -> void:
	var b: float = float(map["bounds_half_m"])
	var facade: String = str(_wall_top().get("outer_wall", "wall"))  # a cheaper facade suits faces seen from afar
	if _kit_piece(facade) == null:
		facade = "wall"
	var depth: float = -_piece_aabb(facade).position.z  # the wall piece reaches this far back
	var parapet: String = str(_wall_top().get("parapet", ""))
	var runs: Array = [
		[Vector2(-b, -b), Vector2(b, -b), Vector2(0, -1)], [Vector2(b, -b), Vector2(b, b), Vector2(1, 0)],
		[Vector2(b, b), Vector2(-b, b), Vector2(0, 1)], [Vector2(-b, b), Vector2(-b, -b), Vector2(-1, 0)],
	]
	for r: Array in runs:
		var a: Vector2 = r[0]
		var e: Vector2 = r[1]
		var n: Vector2 = r[2]
		var yaw: float = atan2(n.x, n.y)
		var length: float = a.distance_to(e)
		for iv: Array in _intervals(a, e, func(p: Vector2) -> bool: return _open_at(p - n * 0.8)):
			var room: bool = iv[2]  # open ground just inside: a room's thin back wall
			var run: float = (float(iv[1]) - float(iv[0])) * length
			var count: int = maxi(1, int(ceil(run / KIT_TILE_M - 0.01)))
			var seg: float = run / count
			for i: int in count:
				var mid: Vector2 = a.lerp(e, lerpf(iv[0], iv[1], (i + 0.5) / count)) + (n * depth if room else Vector2.ZERO)
				var hs: float = 1.01 if room else 1.0  # its coping sits just above the room facade's
				var basis: Basis = Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(seg / KIT_TILE_M, hs, 1))
				_place(facade, Transform3D(basis, Vector3(mid.x, 0, mid.y)), false)
				if parapet != "" and not room:
					_place(parapet, Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(seg / KIT_TILE_M, 1, 1)),
						Vector3(mid.x, KIT_WALL_HEIGHT_M, mid.y)))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_place("corner", Transform3D(Basis(), Vector3(sx * b, 0, sz * b)))


## Portcullis in each gate (it moves with the gate node), a stone lintel above it and, with
## dressing.gatehouse, a gatehouse on the wall top that hides the raised portcullis.
func _kit_gates(kit_root: Node3D) -> void:
	var gh: Dictionary = _dressing.get("gatehouse", {})
	for g: Node3D in gates:
		var c: Dictionary = g.get_meta("collider")
		var size: Vector2 = _box_size(c)
		var along_z: bool = size.y > size.x
		var width: float = size.y if along_z else size.x
		var thick: float = size.x if along_z else size.y
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
		if gh.is_empty():
			continue
		# the gatehouse's front (front_m ahead of its origin) lines up with the gate's courtyard face
		var away: Vector3 = -Vector3(toward_centre.x, 0, toward_centre.y)
		var pos: Vector3 = Vector3(g.position.x, h, g.position.z) - away * thick * 0.5 + away * float(gh.get("front_m", 1.7))
		var house: Node3D = _kit_place(kit_root, str(gh.get("piece", "gatehouse")), pos, yaw,
			Vector3(width / float(gh.get("gate_width_m", KIT_GATE_SIZE.x)), 1, 1))
		if house:
			house.name = "Gatehouse%d" % gates.find(g)


## Decor pieces from the map data (no collision), batched per piece; a decor entry with an
## "effect" gets that looping effect (data/ambient_effects) at its place.
func _kit_decor(kit_root: Node3D) -> void:
	var i: int = 0
	for d: Dictionary in map.get("decor", []):
		var piece: String = str(d["piece"])
		var pos: Vector3 = Vector3(d["pos"][0], float(d.get("y", 0.0)), d["pos"][1])
		var basis: Basis = Basis(Vector3.UP, deg_to_rad(float(d.get("yaw_deg", 0.0)))).scaled(Vector3.ONE * float(d.get("scale", 1.0)))
		var xf: Transform3D = Transform3D(basis, pos)
		if _kit_piece(piece) != null:
			_place(piece, xf, false)
		if d.has("effect") or d.get("light", false):
			var anchor: Node3D = Node3D.new()
			anchor.name = "Decor%d_%s" % [i, piece]
			anchor.transform = xf
			kit_root.add_child(anchor)
			if d.has("effect"):
				var fx: AmbientFx = AmbientFx.create(str(d["effect"]), hash(map_id) + i)
				if fx:
					anchor.add_child(fx)
			else:
				var light: OmniLight3D = OmniLight3D.new()
				light.name = "Fire"
				light.light_color = Color(1.0, 0.56, 0.24)
				light.light_energy = 2.2
				light.omni_range = 9.0
				light.omni_attenuation = 1.4
				light.light_volumetric_fog_energy = 0.6
				light.position = Vector3(0, 1.45, 0)
				anchor.add_child(light)
		i += 1


## Silhouettes beyond the walls (dressing.skyline): towers, rooftops and a keep against the dusk
## sky, on a plain ground plane. No collision, no shadows and no bounced light: cheap backdrop.
func _kit_skyline() -> void:
	var sky: Dictionary = _dressing.get("skyline", {})
	if sky.is_empty():
		return
	var root: Node3D = Node3D.new()
	root.name = "Skyline"
	add_child(root)
	if sky.has("ground"):
		var g: Dictionary = sky["ground"]
		var plane: PlaneMesh = PlaneMesh.new()
		plane.size = Vector2.ONE * float(g.get("size_m", 240.0))
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = _rgb(g.get("color", [0.1, 0.1, 0.1]))
		mat.roughness = 1.0
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "Ground"
		mi.mesh = plane
		mi.material_override = mat
		mi.position.y = float(g.get("y", -0.3))  # below the floor tiles' mortar bed
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		root.add_child(mi)
	var by_piece: Dictionary = skyline_placements
	by_piece.clear()
	for s: Dictionary in sky.get("pieces", []):
		var piece: String = str(s["piece"])
		var basis: Basis = Basis(Vector3.UP, deg_to_rad(float(s.get("yaw_deg", 0.0)))).scaled(Vector3.ONE * float(s.get("scale", 1.0)))
		if not by_piece.has(piece):
			by_piece[piece] = [] as Array[Transform3D]
		(by_piece[piece] as Array[Transform3D]).append(Transform3D(basis, Vector3(s["pos"][0], float(s.get("y", 0.0)), s["pos"][1])))
	for piece: String in by_piece:
		_multimesh(root, piece.to_pascal_case(), piece, by_piece[piece], false)


## Floor dressing (dressing.floor): soft grime decals along every wall base and around pillars
## and the gallows, faint stains across the open floor, and puddle decals (dark, glossy). Textures are generated here from broad,
## smooth shapes (no fine noise, per the art bible).
func _kit_floor_dressing(kit_root: Node3D) -> void:
	var fd: Dictionary = _dressing.get("floor", {})
	if fd.is_empty():
		return
	var root: Node3D = Node3D.new()
	root.name = "FloorDressing"
	kit_root.add_child(root)
	var grime: Dictionary = fd.get("grime", {})
	if not grime.is_empty():
		var col: Color = _rgb(grime.get("color", [0.05, 0.045, 0.04]))
		var alpha: float = float(grime.get("alpha", 0.6))
		var reach: Array = grime.get("width_m", [1.6, 2.6])
		for run: Array in _grime_runs:
			var a: Vector2 = run[0]
			var b: Vector2 = run[1]
			var n: Vector2 = run[2]
			var length: float = a.distance_to(b)
			var t: float = 0.0
			while t < length - 0.01:  # overlapping patches of varied length, width and strength
				var l: float = minf(_rng.randf_range(3.0, 5.5), length - t + 0.8)
				var mid: Vector2 = a + (b - a).normalized() * (t + l * 0.5)
				var w: float = _rng.randf_range(float(reach[0]), float(reach[1]))
				_decal(root, "Grime", _grime_texture(_rng.randi_range(0, 3)), mid, n, Vector2(l + 0.8, w * 2.0),
					col, alpha * _rng.randf_range(0.7, 1.0))
				t += l * 0.8
		for c: Dictionary in map["colliders"]:
			if c["type"] == "circle":
				var r: float = float(c["radius"]) + float(reach[1])
				_decal(root, "Grime", _blob_texture(7), Vector2(c["center"][0], c["center"][1]), Vector2(0, 1),
					Vector2(r * 2.0, r * 2.0), col, alpha * 0.8, _rng.randf() * TAU)
			elif c.get("tag", "") in ["gallows", "tomb"]:
				var sz: Vector2 = _box_size(c) + Vector2.ONE * float(reach[1]) * 1.4
				var ctr: Vector3 = _box_centre(c)
				_decal(root, "Grime", _blob_texture(3), Vector2(ctr.x, ctr.z), Vector2(0, 1), sz, col, alpha * 0.8)
	var stain_col: Color = _rgb(fd.get("stain_color", [0.05, 0.045, 0.04]))
	for p: Dictionary in fd.get("stains", []):  # broad, faint patches that break up the open floor
		var sz: Array = p.get("size_m", [4.0, 3.0])
		_decal(root, "Stain", _blob_texture(int(p.get("seed", 0)) + 20), Vector2(p["pos"][0], p["pos"][1]), Vector2(0, 1),
			Vector2(float(sz[0]), float(sz[1])), stain_col, float(p.get("alpha", 0.45)), deg_to_rad(float(p.get("yaw_deg", 0.0))))
	var i: int = 0
	for p: Dictionary in fd.get("puddles", []):
		var sz: Array = p.get("size_m", [2.0, 1.4])
		var d: Decal = _decal(root, "Puddle", _puddle_texture(int(p.get("seed", i))), Vector2(p["pos"][0], p["pos"][1]),
			Vector2(0, 1), Vector2(float(sz[0]), float(sz[1])), _rgb(fd.get("puddle_color", [0.03, 0.034, 0.04])),
			float(fd.get("puddle_alpha", 0.7)), deg_to_rad(float(p.get("yaw_deg", 0.0))))
		d.texture_orm = _puddle_orm()
		i += 1


## A decal lying on the floor, centred at `centre`, its local z along `n`, size (along, across).
func _decal(parent: Node3D, node_name: String, tex: Texture2D, centre: Vector2, n: Vector2, size: Vector2,
		color: Color, alpha: float, extra_yaw: float = 0.0) -> Decal:
	var d: Decal = Decal.new()
	d.name = node_name
	d.texture_albedo = tex
	d.modulate = Color(color.r, color.g, color.b, alpha)
	d.size = Vector3(size.x, 1.2, size.y)
	d.upper_fade = 0.6
	d.lower_fade = 0.2
	d.normal_fade = 0.0  # also darkens the foot of the walls (rising damp)
	d.cull_mask = 1
	d.position = Vector3(centre.x, 0.0, centre.y)
	d.rotation.y = atan2(n.x, n.y) + extra_yaw
	parent.add_child(d)
	return d


## Grime along a wall: full strength near the centre line (placed on the wall face, so half of it
## lies under the wall), fading out over a width that swells and narrows gently along its length.
func _grime_texture(variant: int) -> ImageTexture:
	return _cached_texture("grime%d" % variant, func() -> Image:
		var w: int = 256
		var h: int = 128
		var img: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
		var ph: float = variant * 1.7
		for x: int in w:
			var u: float = (x + 0.5) / w
			var ends: float = smoothstep(0.0, 0.2, u) * smoothstep(1.0, 0.8, u)
			var reach: float = 0.6 + 0.4 * (0.5 + 0.5 * sin(u * TAU * 1.3 + ph)) * (0.5 + 0.5 * sin(u * TAU * 0.6 + 2.3 + ph))
			for y: int in h:
				var d: float = absf((y + 0.5) / h - 0.5) * 2.0
				var a: float = 1.0 - smoothstep(reach * 0.35, reach, d)
				img.set_pixel(x, y, Color(1, 1, 1, clampf(a * ends, 0.0, 1.0)))
		return img)


## A soft blob of overlapping round shapes (grime around pillars and the gallows block).
func _blob_texture(seed_value: int) -> ImageTexture:
	return _cached_texture("blob%d" % seed_value, func() -> Image:
		return _field_image(seed_value, 128, 5, Vector2(0.3, 0.42), 0.08, 0.02, 0.3))


## A puddle: a few overlapping round shapes with a soft rim.
func _puddle_texture(seed_value: int) -> ImageTexture:
	return _cached_texture("puddle%d" % seed_value, func() -> Image:
		return _field_image(seed_value + 100, 128, 4, Vector2(0.2, 0.32), 0.16, 0.2, 0.45))


## Glossy (low roughness) where the puddle is; decals mask it with the albedo alpha.
func _puddle_orm() -> ImageTexture:
	return _cached_texture("puddle_orm", func() -> Image:
		var img: Image = Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color(1.0, 0.06, 0.0, 1.0))
		return img)


## Alpha from a sum of `blobs` smooth round bumps (radii in `radii`, centres up to `offset` from the
## middle, in texture units) inside a circle, remapped from lo..hi.
static func _field_image(seed_value: int, size: int, blobs: int, radii: Vector2, offset: float, lo: float,
		hi: float) -> Image:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var centres: Array[Vector3] = []  # x, y, radius in 0..1 texture units
	for i: int in blobs:
		var a: float = rng.randf() * TAU
		var d: float = rng.randf_range(0.0, offset) if i > 0 else 0.0
		centres.append(Vector3(0.5 + cos(a) * d, 0.5 + sin(a) * d, rng.randf_range(radii.x, radii.y)))
	var img: Image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	for x: int in size:
		for y: int in size:
			var p: Vector2 = Vector2((x + 0.5) / size, (y + 0.5) / size)
			var f: float = 0.0
			for c: Vector3 in centres:
				var k: float = maxf(0.0, 1.0 - p.distance_squared_to(Vector2(c.x, c.y)) / (c.z * c.z))
				f += k * k
			var edge: float = 1.0 - smoothstep(0.38, 0.5, p.distance_to(Vector2(0.5, 0.5)))
			var a: float = smoothstep(lo, hi, f)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a * edge, 0.0, 1.0)))
	return img


func _cached_texture(key: String, make: Callable) -> ImageTexture:
	if not _textures.has(key):
		var img: Image = make.call()
		img.generate_mipmaps()
		_textures[key] = ImageTexture.create_from_image(img)
	return _textures[key]


func _kit_place(parent: Node3D, piece: String, pos: Vector3, yaw: float, scl: Vector3) -> Node3D:
	var node: Node3D = _kit_instance(piece)
	if node == null:
		return null
	node.position = pos
	node.rotation.y = yaw
	node.scale = scl
	parent.add_child(node)
	return node


## A number from a kit piece's asset spec params (data/assets/<kit>_<piece>.json), e.g. the pillar's
## radius_m, or `fallback` when the spec does not give it.
func _kit_param(piece: String, key: String, fallback: float) -> float:
	var spec: Dictionary = Data.assets.get("%s_%s" % [_kit, piece], {})
	return float(spec.get("params", {}).get(key, fallback))


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
	if _aabbs.has(piece):
		return _aabbs[piece]
	var node: Node3D = _kit_instance(piece)
	var box: AABB = AABB()
	var first: bool = true
	for mi: Node in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		var b: AABB = m.transform * m.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	node.free()
	_aabbs[piece] = box
	return box


## Draw many copies of a piece in one batch (one multimesh per mesh of the piece).
func _multimesh(parent: Node3D, node_name: String, piece: String, transforms: Array[Transform3D],
		shadows: bool = true) -> void:
	var node: Node3D = _kit_instance(piece)
	if node == null or transforms.is_empty():
		if node:
			node.free()
		return
	var k: int = 0
	for mi: Node in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m.mesh
		mm.instance_count = transforms.size()
		for i: int in transforms.size():
			mm.set_instance_transform(i, transforms[i] * m.transform)
		var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		mmi.name = node_name if k == 0 else "%s_%d" % [node_name, k]  # unique among siblings
		k += 1
		mmi.multimesh = mm
		if not shadows:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
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


## A floor tile (half-size `h`) is skipped when a wall block covers all of it.
func _tile_buried(centre: Vector2, h: float = KIT_TILE_M * 0.5) -> bool:
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
	environment = env
	_preset_shadows = {}
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
	_preset_shadows[node_name] = l.shadow_enabled
	return l


## The player's graphics settings on the lighting (M2-13): glow, ambient occlusion, fog and
## shadows (off; low = shorter shadow distance; high = the preset's). Applied at build and live.
func apply_graphics() -> void:
	if environment != null:
		environment.glow_enabled = bool(Settings.get_value("graphics.glow", true))
		var preset_ssao: bool = bool(_ssao_preset) if _ssao_preset != null else true
		environment.ssao_enabled = preset_ssao and bool(Settings.get_value("graphics.ssao", true))
		environment.volumetric_fog_enabled = bool(Settings.get_value("graphics.fog", true))
	var shadows: String = str(Settings.get_value("graphics.shadows", "high"))
	for n: Node in get_children():
		if n is DirectionalLight3D:
			var l: DirectionalLight3D = n
			l.shadow_enabled = bool(_preset_shadows.get(str(l.name), false)) and shadows != "off"
			l.directional_shadow_max_distance = 35.0 if shadows == "low" else 70.0


func _on_setting(p: String, _v: Variant) -> void:
	if p.begins_with("graphics"):
		apply_graphics()


static func _rgb(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))
