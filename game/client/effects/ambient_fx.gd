class_name AmbientFx
extends Node3D
## A looping effect on a map fixture (backlog F-05): fire in a brazier, built from its data in
## data/ambient_effects/<id>.json (schema ambient_effect.schema.json). Generic parts, no per-map
## code: animated flame tongues (shaders/ambient_flame.gdshader), rising embers and smoke
## (GPU particles, a dozen or two each), and a warm light whose energy flickers.
##
## The flicker is a sum of three sines at unrelated frequencies plus a slow drift, from a
## per-instance seed, so neighbouring braziers never pulse together. advance() runs it without
## the scene tree (tests).

const FLAME_SHADER: Shader = preload("res://client/effects/shaders/ambient_flame.gdshader")

var effect_id: String = ""
var light: OmniLight3D = null
var flames: Array[MeshInstance3D] = []
var emitters: Array[GPUParticles3D] = []
var base_energy: float = 0.0
var flicker_amount: float = 0.0
var flicker_hz: float = 6.0
var age: float = 0.0
var _phases: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _light_home: Vector3 = Vector3.ZERO


## Build the effect `id` from Data.ambient_effects; null when there is no such effect.
static func create(id: String, seed_value: int = 0) -> AmbientFx:
	var def: Dictionary = Data.ambient_effects.get(id, {})
	if def.is_empty():
		Log.warn("ambient_fx: unknown effect %s" % id)
		return null
	var fx: AmbientFx = AmbientFx.new()
	fx.name = "Fx_%s" % id
	fx.effect_id = id
	fx._build(def, seed_value)
	return fx


func _build(def: Dictionary, seed_value: int) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	for i: int in _phases.size():
		_phases[i] = rng.randf() * TAU
	position = _vec3(def.get("offset", [0, 0, 0]))
	if def.has("flame"):
		_build_flames(def["flame"], rng)
	if def.has("embers"):
		_build_particles("Embers", def["embers"], true)
	if def.has("smoke"):
		_build_particles("Smoke", def["smoke"], false)
	if def.has("light"):
		var l: Dictionary = def["light"]
		light = OmniLight3D.new()
		light.name = "Light"
		light.light_color = _rgb(l.get("color", [1.0, 0.56, 0.24]))
		base_energy = float(l.get("energy", 2.0))
		light.light_energy = base_energy
		light.omni_range = float(l.get("range_m", 9.0))
		light.omni_attenuation = float(l.get("attenuation", 1.4))
		light.light_volumetric_fog_energy = float(l.get("fog_energy", 0.6))
		light.position = Vector3(0, float(l.get("y_m", 0.25)), 0)
		_light_home = light.position
		var fl: Dictionary = l.get("flicker", {})
		flicker_amount = float(fl.get("amount", 0.0))
		flicker_hz = float(fl.get("speed_hz", 6.0))
		add_child(light)


func _build_flames(f: Dictionary, rng: RandomNumberGenerator) -> void:
	var colors: Dictionary = f.get("colors", {})
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = FLAME_SHADER
	mat.set_shader_parameter("core_color", _rgb(colors.get("core", [1.0, 0.86, 0.5])))
	mat.set_shader_parameter("outer_color", _rgb(colors.get("outer", [1.0, 0.36, 0.07])))
	mat.set_shader_parameter("intensity", float(f.get("intensity", 2.0)))
	mat.set_shader_parameter("speed", float(f.get("speed", 1.0)))
	var h: float = float(f.get("height_m", 0.9))
	var w: float = float(f.get("width_m", 0.7))
	var n: int = int(f.get("tongues", 3))
	var spread: float = float(f.get("spread_m", 0.14))
	for i: int in n:
		var k: float = 1.0 if i == 0 else rng.randf_range(0.55, 0.8)
		var quad: QuadMesh = QuadMesh.new()
		quad.size = Vector2(w * (1.0 if i == 0 else 0.7), h * k)
		quad.center_offset = Vector3(0, h * k * 0.5, 0)
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "Flame%d" % i
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var a: float = TAU * i / maxf(1.0, n - 1.0) + rng.randf() * 0.5
		mi.position = Vector3.ZERO if i == 0 else Vector3(cos(a), 0, sin(a)) * spread
		mi.set_instance_shader_parameter("phase", rng.randf() * 20.0)
		add_child(mi)
		flames.append(mi)


func _build_particles(node_name: String, cfg: Dictionary, additive: bool) -> void:
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = float(cfg.get("radius_m", 0.2))
	pm.direction = Vector3.UP
	pm.spread = float(cfg.get("spread_deg", 20.0))
	var rise: Array = cfg.get("rise_mps", [0.6, 1.2])
	pm.initial_velocity_min = float(rise[0])
	pm.initial_velocity_max = float(rise[1])
	pm.gravity = Vector3(0, float(cfg.get("buoyancy", 0.2)), 0)
	pm.damping_min = float(cfg.get("damping", 0.2))
	pm.damping_max = float(cfg.get("damping", 0.2)) * 1.5
	pm.scale_min = 0.6
	pm.scale_max = 1.2
	var grow: float = float(cfg.get("grow", 1.0))
	var curve: Curve = Curve.new()
	curve.add_point(Vector2(0.0, 1.0 if grow <= 1.0 else 1.0 / grow))
	curve.add_point(Vector2(1.0, 0.25 if grow <= 1.0 else 1.0))
	var ct: CurveTexture = CurveTexture.new()
	ct.curve = curve
	pm.scale_curve = ct
	var col: Array = cfg.get("color", [1, 1, 1, 1])
	pm.color = Color(float(col[0]), float(col[1]), float(col[2]), float(col[3]) if col.size() > 3 else 1.0)
	var g: Gradient = Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.15, 0.6, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0)])
	var ramp: GradientTexture1D = GradientTexture1D.new()
	ramp.gradient = g
	pm.color_ramp = ramp
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _dot_texture()
	mat.disable_fog = additive
	var quad: QuadMesh = QuadMesh.new()
	var s: float = float(cfg.get("size_m", 0.1))
	quad.size = Vector2(s, s)
	quad.material = mat
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = node_name
	p.process_material = pm
	p.draw_pass_1 = quad
	p.amount = maxi(1, int(cfg.get("count", 12)))
	p.lifetime = float(cfg.get("lifetime_s", 1.5))
	p.preprocess = p.lifetime  # already burning when the map appears
	p.randomness = 0.4
	p.fixed_fps = 30
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	p.visibility_aabb = AABB(Vector3(-1.5, -0.5, -1.5), Vector3(3, 6, 3))
	add_child(p)
	emitters.append(p)


func _process(delta: float) -> void:
	advance(delta)


## Advance the flicker by `delta` seconds (the flames and particles animate on their own).
func advance(delta: float) -> void:
	age += delta
	if light == null:
		return
	light.light_energy = base_energy * (1.0 + flicker_amount * flicker(age))
	var j: float = flicker_amount * 0.12
	light.position = _light_home + Vector3(sin(age * 7.3 + _phases[1]), 0.0, cos(age * 6.1 + _phases[2])) * j


## Flicker signal in about [-1, 1] at time `t`.
func flicker(t: float) -> float:
	var w: float = TAU * flicker_hz
	return 0.45 * sin(t * w + _phases[0]) + 0.3 * sin(t * w * 1.73 + _phases[1]) \
		+ 0.15 * sin(t * w * 3.11 + _phases[2]) + 0.1 * sin(t * 0.9 + _phases[3])


static func _dot_texture() -> GradientTexture2D:
	var g: Gradient = Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.5), Color(1, 1, 1, 0)])
	var t: GradientTexture2D = GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	return t


static func _rgb(a: Array) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


static func _vec3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
