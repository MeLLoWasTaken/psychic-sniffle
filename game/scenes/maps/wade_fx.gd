class_name WadeFx
extends Node3D
## Ripples and splashes where units wade through a flood (M2-09). MapBuilder owns one when its map
## has a flood twist and feeds it the drawn unit positions every frame; it asks the builder where
## the water stands (MapBuilder.is_wet), so the effect follows the same flood as the server's slow.
##
## A moving unit leaves a ripple ring and a few droplets every STEP_M of travel through water;
## a unit standing in water sends out a faint ring every IDLE_S. Rings are pooled (MAX_RIPPLES),
## so a crowded flood never grows the scene.

const STEP_M: float = 0.95  ## travel between splashes (about one stride)
const IDLE_S: float = 1.7  ## time between rings around a unit standing still
const MOVING_MPS: float = 0.5  ## below this a unit counts as standing
const TELEPORT_MPS: float = 20.0  ## faster than this is a blink or a correction, not wading
const RIPPLE_S: float = 0.95  ## a ring's life
const RIPPLE_SIZE: Vector2 = Vector2(0.3, 1.4)  ## a ring's diameter at birth and at the end, metres
const MAX_RIPPLES: int = 24
const SPLASH_POOL: int = 8
const RING_SHADER: Shader = preload("res://scenes/maps/ripple.gdshader")

var builder: MapBuilder
var ripples: Array[MeshInstance3D] = []  ## the ring pool; each carries its age in metadata "age"
var splashes: Array[GPUParticles3D] = []
var splashes_started: int = 0  ## (tests)
var rings_started: int = 0  ## (tests)
var _units: Dictionary = {}  ## unit id -> {pos, acc (metres since the last splash), idle (seconds)}
var _next_splash: int = 0
var _ring_mesh: QuadMesh
var _ring_mat: ShaderMaterial


func _init(b: MapBuilder) -> void:
	builder = b
	name = "WadeFx"
	_ring_mesh = QuadMesh.new()
	_ring_mesh.size = Vector2.ONE
	_ring_mesh.orientation = PlaneMesh.FACE_Y
	_ring_mat = ShaderMaterial.new()
	_ring_mat.shader = RING_SHADER


## Advance with the newest drawn units: Arrays of view unit dictionaries ("id", "position",
## "health"). Units that are dead, airborne or out of the water make no splashes.
func update(units: Array, delta: float) -> void:
	var seen: Dictionary = {}
	for u: Dictionary in units:
		var id: int = int(u["id"])
		var pos: Vector3 = u["position"]
		seen[id] = true
		var e: Dictionary = _units.get(id, {})
		if e.is_empty():
			_units[id] = {"pos": pos, "acc": 0.0, "idle": IDLE_S * 0.5}
			continue
		var prev: Vector3 = e["pos"]
		e["pos"] = pos
		if int(u.get("health", 1)) <= 0 or not builder.is_wet(pos):
			e["acc"] = STEP_M * 0.6  # the first step into the water splashes soon
			e["idle"] = IDLE_S * 0.5
			continue
		var d: float = Vector2(pos.x - prev.x, pos.z - prev.z).length()
		var speed: float = d / delta if delta > 0.0 else 0.0
		if speed >= TELEPORT_MPS:
			continue
		if speed >= MOVING_MPS:
			e["idle"] = 0.0
			e["acc"] = float(e["acc"]) + d
			if float(e["acc"]) >= STEP_M:
				e["acc"] = fmod(float(e["acc"]), STEP_M)
				var ahead: Vector3 = Vector3(pos.x - prev.x, 0.0, pos.z - prev.z).normalized() * 0.25
				_ring(pos + ahead, 1.0)
				_splash(pos + ahead)
		elif delta > 0.0:
			e["idle"] = float(e["idle"]) + delta
			if float(e["idle"]) >= IDLE_S:
				e["idle"] = 0.0
				_ring(pos, 0.45)
	for id: int in _units.keys():
		if not seen.has(id):
			_units.erase(id)
	_age(delta)


## Live rings (tests, screenshots).
func live_ripples() -> int:
	return ripples.filter(func(r: MeshInstance3D) -> bool: return r.visible).size()


func _ring(pos: Vector3, strength: float) -> void:
	var r: MeshInstance3D = null
	for c: MeshInstance3D in ripples:
		if not c.visible:
			r = c
			break
	if r == null:
		if ripples.size() < MAX_RIPPLES:
			r = MeshInstance3D.new()
			r.name = "Ripple%d" % ripples.size()
			r.mesh = _ring_mesh
			r.material_override = _ring_mat
			r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(r)
			ripples.append(r)
		else:  # every ring is in use: reuse the oldest
			r = ripples[0]
			for c: MeshInstance3D in ripples:
				if float(c.get_meta("age", 0.0)) > float(r.get_meta("age", 0.0)):
					r = c
	r.visible = true
	r.set_meta("age", 0.0)
	r.set_meta("strength", strength)
	r.position = Vector3(pos.x, builder.water_surface_y() + 0.01, pos.z)
	_shape_ring(r)
	rings_started += 1


func _age(delta: float) -> void:
	for r: MeshInstance3D in ripples:
		if not r.visible:
			continue
		var age: float = float(r.get_meta("age", 0.0)) + delta
		r.set_meta("age", age)
		if age >= RIPPLE_S:
			r.visible = false
			continue
		r.position.y = builder.water_surface_y() + 0.01
		_shape_ring(r)


func _shape_ring(r: MeshInstance3D) -> void:
	var t: float = clampf(float(r.get_meta("age", 0.0)) / RIPPLE_S, 0.0, 1.0)
	var grow: float = 1.0 - pow(1.0 - t, 2.2)  # fast at first, slowing as it spreads
	var s: float = lerpf(RIPPLE_SIZE.x, RIPPLE_SIZE.y, grow) * lerpf(0.75, 1.0, float(r.get_meta("strength", 1.0)))
	r.scale = Vector3(s, 1.0, s)
	r.set_instance_shader_parameter("fade", (1.0 - t) * float(r.get_meta("strength", 1.0)))
	r.set_instance_shader_parameter("width", lerpf(0.16, 0.05, t))


func _splash(pos: Vector3) -> void:
	var p: GPUParticles3D
	if splashes.size() < SPLASH_POOL:
		p = _make_splash()
		add_child(p)
		splashes.append(p)
	else:
		p = splashes[_next_splash % SPLASH_POOL]
	_next_splash += 1
	p.position = Vector3(pos.x, builder.water_surface_y(), pos.z)
	p.restart()
	p.emitting = true
	splashes_started += 1


## A few droplets thrown up and falling back as short streaks, lit like the water (no glow).
func _make_splash() -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "Splash%d" % splashes.size()
	p.amount = 16
	p.lifetime = 0.55
	p.one_shot = true
	p.explosiveness = 0.9
	p.randomness = 0.5
	p.emitting = false
	p.local_coords = false
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 0.16
	pm.emission_ring_inner_radius = 0.06
	pm.emission_ring_height = 0.02
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 22.0
	pm.particle_flag_align_y = true  # each drop a short streak along its flight
	pm.initial_velocity_min = 1.4
	pm.initial_velocity_max = 2.8
	pm.gravity = Vector3(0, -9.8, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	var fade: Gradient = Gradient.new()
	fade.set_color(0, Color(0.74, 0.8, 0.84, 0.6))
	fade.set_color(1, Color(0.5, 0.58, 0.6, 0.0))
	var ramp: GradientTexture1D = GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	p.process_material = pm
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.035, 0.13)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y  # with align_y: stretched along velocity, facing the camera
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.1
	mat.metallic_specular = 0.8
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
	return p
