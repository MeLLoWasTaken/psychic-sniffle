class_name EffectLibrary
extends RefCounted
## Builders for every effect style named in data/effects (backlog M1-25): generic shapes colored
## by school, never per ability. Stylized and sparse on purpose (docs/DESIGN.md "readable
## chaos"): a few bright shapes (fresnel shells, orbs, rings, crescents, ground circles) carry each
## effect, and small GPU particle counts add motion. Meshes, shader materials and particle
## process materials are cached and shared, so building an effect only creates nodes; per-effect
## values (alpha, progress, outline width) are instance shader parameters.
##
## Everything returned is a Vfx positioned at its own origin; EffectsDirector places it.

const SHADER_DIR: String = "res://client/effects/shaders/"

static var _cache: Dictionary = {}


## Drop every cached resource (tests; palette edits).
static func clear_cache() -> void:
	_cache = {}


# ============================================================ stages

## Glow on the hands while casting: an orb and inward-drawn sparks per hand.
static func cast_glow(school: String, hands: String, size: float) -> Vfx:
	var v: Vfx = _vfx(Vfx.Kind.CAST, school, "hand_glow")
	v.priority = 4
	v.linger = 0.3
	var names: Array[String] = ["hand_r", "hand_l"]
	if hands != "both":
		names = ["hand_" + hands.substr(0, 1)]
	for n: String in names:
		var part: Node3D = Node3D.new()
		part.name = n
		v.add_part(part, n)
		var orb: MeshInstance3D = _mesh(_sphere(), _glow(school, "orb"))
		orb.scale = Vector3.ONE * 0.26 * size
		v.add_fader(orb, part)
		var halo: MeshInstance3D = _mesh(_sphere(), _glow(school, "shell"))
		halo.scale = Vector3.ONE * 0.5 * size
		v.add_fader(halo, part)
		v.add_spinner(halo, 3.0)
		var pm: ParticleProcessMaterial = _process("cast:%s" % school, {"shape": "sphere_surface", "radius": 0.3 * size,
			"velocity": [0.0, 0.1], "radial_accel": [-3.0, -2.0], "gravity": Vector3(0, 0.5, 0), "scale": [0.5, 1.0],
			"color": _col(school, "primary", "glow"), "ramp": "in_out"})
		v.add_emitter(_emitter(pm, _quad(0.11, true), 12, 0.45, false, 0.0, true), part)
	# a turning ring at the feet says "casting" from any angle, even when the hands are hidden
	var feet: Node3D = Node3D.new()
	feet.name = "feet"
	v.add_part(feet, "feet")
	var ring: MeshInstance3D = _mesh(_torus(), _glow(school, "marker"))
	ring.scale = Vector3(1.5, 0.5, 1.5) * size
	v.add_fader(ring, feet)
	v.add_spinner(feet, 1.5)
	var sigil: MeshInstance3D = _mesh(_torus(), _glow(school, "shell"))
	sigil.scale = Vector3(1.1, 0.3, 1.1) * size
	v.add_fader(sigil, feet)
	return v


## A projectile core with a trail; EffectsDirector flies it.
static func projectile(style: String, school: String, size_scale: float) -> Vfx:
	var size: float = size_scale * 1.4
	var v: Vfx = _vfx(Vfx.Kind.PROJECTILE, school, style)
	v.priority = 3
	v.linger = 0.35
	var core: MeshInstance3D
	match style:
		"shard":
			core = _mesh(_crystal(), _glow(school, "orb"))
			core.scale = Vector3(0.14, 0.14, 0.6) * size
		"orb":
			core = _mesh(_sphere(), _glow(school, "orb"))
			core.scale = Vector3.ONE * 0.3 * size
		"streak":
			core = _mesh(_sphere(), _glow(school, "orb"))
			core.scale = Vector3(0.08, 0.08, 0.9) * size
		_:  # bolt
			core = _mesh(_sphere(), _glow(school, "orb"))
			core.scale = Vector3(0.2, 0.2, 0.55) * size
	core.name = "Core"
	v.add_fader(core)
	var halo: MeshInstance3D = _mesh(_sphere(), _glow(school, "shell"))
	halo.scale = core.scale * 1.9
	v.add_fader(halo)
	var pm: ParticleProcessMaterial = _process("trail:%s" % school, {"shape": "sphere", "radius": 0.06 * size,
		"velocity": [0.1, 0.4], "spread": 180.0, "scale": [0.6, 1.0], "scale_curve": "shrink",
		"color": _col(school, "primary", "glow"), "ramp": "fade"})
	v.add_emitter(_emitter(pm, _quad(0.18 * size, true), 28, 0.3, false, 0.0, false))
	if style == "shard" or style == "bolt":
		var mist: ParticleProcessMaterial = _process("trailmist:%s" % school, {"shape": "sphere", "radius": 0.1 * size,
			"velocity": [0.05, 0.2], "spread": 180.0, "scale": [0.7, 1.2], "scale_curve": "grow",
			"color": _col(school, "secondary", "glow", 0.5), "ramp": "fade"})
		v.add_emitter(_emitter(mist, _quad(0.35 * size, false), 10, 0.45, false, 0.0, false))
	return v


## A one-shot hit: burst, shards, rays, spark, hail, ring or flash.
static func impact(style: String, school: String, size: float) -> Vfx:
	var v: Vfx = _vfx(Vfx.Kind.IMPACT, school, style)
	v.priority = 1 if style == "spark" else 2
	v.fade_in = 0.0
	match style:
		"shards":
			v.lifetime = 0.35
			v.linger = 0.4
			_shell(v, school, "shell", 0.2 * size, 1.1 * size, 0.22)
			var pm: ParticleProcessMaterial = _process("shards:%s" % school, {"shape": "sphere", "radius": 0.15,
				"direction": Vector3.UP, "spread": 70.0, "velocity": [3.0, 5.5], "gravity": Vector3(0, -12, 0),
				"scale": [0.6, 1.2], "spin": true, "color": _col(school, "primary", "glow"), "ramp": "fade_late"})
			v.add_emitter(_emitter(pm, _crystal_particle(0.16 * size), 12, 0.6, true, 1.0, false))
			_sparks(v, school, "secondary", 12, 3.0 * size, 0.35)
		"rays":
			v.lifetime = 0.5
			v.linger = 0.35
			var beam: MeshInstance3D = _mesh(_cylinder(), _glow(school, "beam"))
			beam.position.y = 1.5 * size
			v.add_fader(beam)
			v.add_scaler(beam, Vector3(0.1, 3.0, 0.1) * size, Vector3(0.9, 3.0, 0.9) * size, 0.15, "pop")
			var ring: MeshInstance3D = _mesh(_torus(), _glow(school, "marker"))
			ring.position.y = 0.05
			v.add_fader(ring)
			v.add_scaler(ring, Vector3(0.3, 0.3, 0.3) * size, Vector3(1.4, 0.6, 1.4) * size, 0.35)
			var pm: ParticleProcessMaterial = _process("motes:%s" % school, {"shape": "ring", "radius": 0.5 * size,
				"direction": Vector3.UP, "spread": 10.0, "velocity": [1.5, 3.0], "scale": [0.6, 1.0],
				"color": _col(school, "primary", "glow"), "ramp": "in_out"})
			v.add_emitter(_emitter(pm, _quad(0.12 * size, true), 16, 0.8, true, 0.7, false))
		"spark":
			v.lifetime = 0.12
			v.linger = 0.25
			_shell(v, school, "orb", 0.12 * size, 0.5 * size, 0.1)
			_sparks(v, school, "secondary", 10, 5.0 * size, 0.25)
		"hail":
			v.lifetime = 0.4
			v.linger = 0.45
			var pm: ParticleProcessMaterial = _process("hail:%s" % school, {"shape": "box", "box": Vector3(0.8, 0.1, 0.8) * size,
				"direction": Vector3.DOWN, "spread": 6.0, "velocity": [9.0, 11.0], "gravity": Vector3(0, -10, 0),
				"scale": [0.7, 1.3], "spin": true, "color": _col(school, "primary", "glow"), "ramp": "fade_late"})
			var fall: GPUParticles3D = _emitter(pm, _crystal_particle(0.2 * size), 14, 0.38, true, 0.6, false)
			fall.position.y = 4.0
			v.add_emitter(fall)
			var puff: MeshInstance3D = _mesh(_torus(), _glow(school, "marker"))
			puff.position.y = 0.05
			v.add_fader(puff)
			v.add_scaler(puff, Vector3(0.2, 0.2, 0.2), Vector3(1.2, 0.5, 1.2) * size, 0.4)
		"ring":
			v.lifetime = 0.25
			v.linger = 0.25
			var ring: MeshInstance3D = _mesh(_torus(), _glow(school, "marker"))
			v.add_fader(ring)
			v.add_scaler(ring, Vector3(0.2, 0.4, 0.2), Vector3(1.6, 0.6, 1.6) * size, 0.3)
			var pm: ParticleProcessMaterial = _process("ringspark:%s" % school, {"shape": "ring", "radius": 0.2,
				"direction": Vector3.RIGHT, "spread": 180.0, "flatness": 1.0, "velocity": [3.0, 5.0], "damping": [4.0, 6.0],
				"scale": [0.5, 1.0], "color": _col(school, "primary", "glow"), "ramp": "fade"})
			v.add_emitter(_emitter(pm, _quad(0.12 * size, true), 16, 0.4, true, 1.0, false))
		"flash":
			v.lifetime = 0.3
			v.linger = 0.3
			_shell(v, school, "shell", 0.4 * size, 1.8 * size, 0.3)
			_sparks(v, school, "primary", 16, 4.0 * size, 0.45)
		_:  # burst
			v.lifetime = 0.25
			v.linger = 0.35
			_shell(v, school, "shell", 0.2 * size, 1.3 * size, 0.25)
			_shell(v, school, "orb", 0.15 * size, 0.6 * size, 0.12)
			_sparks(v, school, "primary", 20, 4.5 * size, 0.45)
	return v


## A circle on the ground of `radius` m; `hostile` gives it the enemy (red-tinted) outline.
static func ground(style: String, school: String, radius: float, hostile: bool, lifetime: float) -> Vfx:
	var v: Vfx = _vfx(Vfx.Kind.GROUND, school, style)
	v.hostile = hostile
	v.priority = 5 if hostile else 3
	v.lifetime = lifetime
	v.linger = 0.35
	v.fade_in = 0.06
	var disc: MeshInstance3D = _mesh(_plane(), _ground_material(school, hostile))
	disc.name = "Disc"
	disc.position.y = 0.04
	disc.scale = Vector3(radius, 1.0, radius)
	disc.set_instance_shader_parameter("outline_frac", clampf(EffectsData.outline_width_m() / maxf(radius, 0.1), 0.01, 0.5))
	v.add_fader(disc)
	v.data["disc"] = disc
	v.data["radius"] = radius
	if style == "nova":
		v.add_progress(disc, 0.3)
		var pm: ParticleProcessMaterial = _process("nova:%s:%d" % [school, roundi(radius)], {"shape": "ring", "radius": 0.4,
			"direction": Vector3.RIGHT, "spread": 180.0, "flatness": 1.0, "velocity": [radius * 2.2, radius * 2.8],
			"damping": [radius * 3.0, radius * 3.6], "gravity": Vector3(0, 0.6, 0), "scale": [0.8, 1.4],
			"color": _col(school, "primary", "glow"), "ramp": "fade"})
		var p: GPUParticles3D = _emitter(pm, _quad(0.35, true), mini(48, 16 + roundi(radius * 3.0)), 0.6, true, 1.0, false)
		p.position.y = 0.25
		p.visibility_aabb = AABB(Vector3(-radius - 1, -1, -radius - 1), Vector3(radius * 2 + 2, 4, radius * 2 + 2))
		v.add_emitter(p)
	else:
		disc.set_instance_shader_parameter("progress", 1.0)
		var pm: ParticleProcessMaterial = _process("zone:%s:%d" % [school, roundi(radius)], {"shape": "ring",
			"radius": radius * 0.8, "inner": 0.0, "direction": Vector3.UP, "spread": 5.0, "velocity": [0.8, 1.6],
			"scale": [0.6, 1.0], "color": _col(school, "primary", "glow"), "ramp": "in_out"})
		var p: GPUParticles3D = _emitter(pm, _quad(0.2, true), mini(40, 10 + roundi(radius * 2.0)), 0.9, false, 0.0, false)
		p.visibility_aabb = AABB(Vector3(-radius - 1, -1, -radius - 1), Vector3(radius * 2 + 2, 5, radius * 2 + 2))
		v.add_emitter(p)
	return v


## A weapon swing trail in front of the attacker (the Vfx turns with the attacker).
static func melee(style: String, school: String, size: float, mirrored: bool) -> Vfx:
	var v: Vfx = _vfx(Vfx.Kind.MELEE, school, style)
	v.priority = 1
	v.follow_yaw = true
	v.fade_in = 0.0
	v.lifetime = 0.2
	v.linger = 0.12
	var mesh: ArrayMesh
	var arc: MeshInstance3D
	match style:
		"overhead":
			mesh = _crescent(-80.0, 80.0, 0.5, 1.5)
			arc = _mesh(mesh, _arc_material(school))
			arc.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0 + (12.0 if mirrored else -12.0)))
			arc.position = Vector3(0.0, 1.3, -0.35)
		"thrust":
			mesh = _crescent(-9.0, 9.0, 0.3, 2.0)
			arc = _mesh(mesh, _arc_material(school))
			arc.position = Vector3(0.0, 1.25, 0.0)
		_:
			mesh = _crescent(-75.0, 75.0, 0.65, 1.55)
			arc = _mesh(mesh, _arc_material(school))
			arc.rotation = Vector3(deg_to_rad(-14.0 if mirrored else 14.0), 0.0, 0.0)
			arc.position = Vector3(0.0, 1.15, 0.0)
	arc.name = "Arc"
	arc.scale = Vector3.ONE * size * (Vector3(-1, 1, 1) if mirrored else Vector3.ONE)
	v.add_fader(arc)
	v.add_progress(arc, 0.2, 1.45)
	return v


## Dust along a charge path or a blink between two points (world positions).
static func displacement(style: String, school: String, from: Vector3, to: Vector3) -> Vfx:
	var v: Vfx = _vfx(Vfx.Kind.DISPLACEMENT, school, style)
	v.priority = 2
	v.fade_in = 0.0
	var flat: Vector3 = Vector3(to.x - from.x, 0.0, to.z - from.z)
	var length: float = maxf(flat.length(), 0.5)
	v.position = Vector3((from.x + to.x) * 0.5, minf(from.y, to.y), (from.z + to.z) * 0.5)
	if flat.length() > 0.01:
		v.rotation.y = atan2(-flat.x, -flat.z)
	if style == "blink":
		v.lifetime = 0.3
		v.linger = 0.35
		for end: float in [-0.5, 0.5]:
			var s: MeshInstance3D = _mesh(_sphere(), _glow(school, "shell"))
			s.position = Vector3(0.0, 1.0, end * length)
			v.add_fader(s)
			v.add_scaler(s, Vector3(0.3, 0.6, 0.3), Vector3(0.9, 1.9, 0.9), 0.3)
		var streak: MeshInstance3D = _mesh(_cylinder(), _glow(school, "beam"))
		streak.rotation.x = PI / 2
		streak.position.y = 1.0
		streak.scale = Vector3(0.15, length, 0.15)
		v.add_fader(streak)
		_sparks(v, school, "secondary", 14, 3.0, 0.4)
		return v
	v.lifetime = 0.5
	v.linger = 1.0
	var pm: ParticleProcessMaterial = _process("dust", {"shape": "box", "box": Vector3(0.45, 0.05, 0.5),
		"direction": Vector3.UP, "spread": 60.0, "velocity": [0.4, 1.2], "gravity": Vector3(0, -0.6, 0),
		"damping": [0.5, 1.0], "scale": [0.7, 1.4], "scale_curve": "grow",
		"color": Color(EffectsData.dust_color(), 0.55), "ramp": "fade"})
	var trail: GPUParticles3D = _emitter(pm, _quad(0.9, false), mini(40, 12 + roundi(length * 1.5)), 1.1, true, 0.75, false)
	trail.scale = Vector3(1.0, 1.0, length)  # the box stretches along the path
	trail.visibility_aabb = AABB(Vector3(-2, -1, -1), Vector3(4, 4, 2))
	v.add_emitter(trail)
	var puff_pm: ParticleProcessMaterial = _process("dustpuff", {"shape": "ring", "radius": 0.3,
		"direction": Vector3.RIGHT, "spread": 180.0, "flatness": 0.8, "velocity": [1.5, 3.0], "damping": [2.0, 3.0],
		"scale": [0.8, 1.5], "scale_curve": "grow", "color": Color(EffectsData.dust_color(), 0.6), "ramp": "fade"})
	var puff: GPUParticles3D = _emitter(puff_pm, _quad(1.0, false), 14, 0.9, true, 1.0, false)
	puff.position = Vector3(0.0, 0.2, -0.5 * length)
	v.add_emitter(puff)
	return v


## A lasting visual on a unit while an aura is on it. Crowd control is loud on purpose.
static func aura(style: String, school: String, size: float) -> Vfx:
	var v: Vfx = _vfx(Vfx.Kind.AURA, school, style)
	v.priority = 4
	v.fade_in = 0.12
	v.linger = 0.3
	match style:
		"shield":
			v.anchor = "body"
			var bubble: MeshInstance3D = _mesh(_sphere(), _glow(school, "shield"))
			bubble.scale = Vector3(1.05, 2.1, 1.05) * size
			v.add_fader(bubble)
			v.add_scaler(bubble, bubble.scale * 0.6, bubble.scale, 0.2, "pop")
		"ice_block":
			v.anchor = "feet"
			var block: MeshInstance3D = _mesh(_prism(), _ice_material(school))
			block.position.y = 1.1 * size
			block.scale = Vector3(1.25, 2.3, 1.25) * size
			v.add_fader(block)
			v.add_scaler(block, Vector3(1.25, 0.2, 1.25) * size, block.scale, 0.18, "out")
			for i: int in 6:
				var a: float = TAU * i / 6.0 + 0.4
				var spike: MeshInstance3D = _mesh(_crystal(), _glow(school, "orb"))
				spike.position = Vector3(cos(a) * 0.7, 0.2, sin(a) * 0.7) * size
				spike.rotation = Vector3(sin(a) * 0.5, a, cos(a) * 0.5)
				spike.scale = Vector3(0.12, 0.45, 0.12) * size
				v.add_fader(spike)
		"stun":
			v.anchor = "overhead"
			var spin: Node3D = Node3D.new()
			v.add_child(spin)
			v.add_spinner(spin, 4.5)
			var ring: MeshInstance3D = _mesh(_thick_torus(), _glow(school, "marker"))
			ring.scale = Vector3(0.85, 1.0, 0.85) * size
			v.add_fader(ring, spin)
			for i: int in 4:
				var a: float = TAU * i / 4.0
				var star: MeshInstance3D = _mesh(_crystal(), _glow(school, "orb"))
				star.position = Vector3(cos(a) * 0.44, 0.08 * sin(a * 2.0), sin(a) * 0.44) * size
				star.scale = Vector3(0.22, 0.34, 0.22) * size
				v.add_fader(star, spin)
				v.add_spinner(star, -7.0)
			v.cc = true
		"disorient":
			v.anchor = "overhead"
			var spin: Node3D = Node3D.new()
			v.add_child(spin)
			v.add_spinner(spin, -3.0)
			var ring: MeshInstance3D = _mesh(_thick_torus(), _glow(school, "marker"))
			ring.scale = Vector3(0.75, 1.0, 0.75) * size
			ring.rotation.x = 0.35
			v.add_fader(ring, spin)
			var pm: ParticleProcessMaterial = _process("swirl:%s" % school, {"shape": "ring", "radius": 0.35 * size,
				"direction": Vector3.UP, "spread": 20.0, "velocity": [0.1, 0.3], "scale": [0.8, 1.3],
				"scale_curve": "grow", "color": _col(school, "secondary", "", 0.85), "ramp": "in_out"})
			v.add_emitter(_emitter(pm, _quad(0.28 * size, false), 14, 0.9, false, 0.0, true), spin)
			var pm2: ParticleProcessMaterial = _process("swirlglow:%s" % school, {"shape": "ring", "radius": 0.4 * size,
				"direction": Vector3.UP, "spread": 20.0, "velocity": [0.2, 0.4], "scale": [0.6, 1.0],
				"color": _col(school, "primary", "glow"), "ramp": "in_out"})
			v.add_emitter(_emitter(pm2, _quad(0.12 * size, true), 10, 0.7, false, 0.0, true), spin)
			v.cc = true
		"root":
			v.anchor = "feet"
			var ring: MeshInstance3D = _mesh(_thick_torus(), _glow(school, "marker"))
			ring.scale = Vector3(1.4, 0.5, 1.4) * size
			ring.position.y = 0.05
			v.add_fader(ring)
			for i: int in 7:
				var a: float = TAU * i / 7.0
				var spike: MeshInstance3D = _mesh(_cone(), _glow(school, "orb"))
				spike.position = Vector3(cos(a) * 0.62, 0.25, sin(a) * 0.62) * size
				spike.rotation = Vector3(sin(a) * 0.45, 0.0, -cos(a) * 0.45)
				v.add_fader(spike)
				v.add_scaler(spike, Vector3(0.16, 0.05, 0.16) * size, Vector3(0.16, 1.0, 0.16) * size, 0.15, "pop")
			v.cc = true
		"silence":
			v.anchor = "overhead"
			var halo: MeshInstance3D = _mesh(_thick_torus(), _glow(school, "marker"))
			halo.scale = Vector3(0.8, 1.0, 0.8) * size
			v.add_fader(halo)
			var bar: MeshInstance3D = _mesh(_box(), _glow(school, "orb"))
			bar.scale = Vector3(1.05, 0.09, 0.09) * size
			bar.rotation = Vector3(0.0, 0.0, 0.6)
			v.add_fader(bar)
			var bar2: MeshInstance3D = _mesh(_box(), _glow(school, "orb"))
			bar2.scale = Vector3(0.09, 0.09, 1.05) * size
			bar2.rotation = Vector3(0.6, 0.0, 0.0)
			v.add_fader(bar2)
			v.cc = true
		"hot":
			v.anchor = "feet"
			var pm: ParticleProcessMaterial = _process("hot:%s" % school, {"shape": "ring", "radius": 0.45 * size,
				"direction": Vector3.UP, "spread": 8.0, "velocity": [0.7, 1.3], "scale": [0.6, 1.0],
				"color": _col(school, "primary", "glow"), "ramp": "in_out"})
			v.add_emitter(_emitter(pm, _quad(0.12 * size, true), 14, 1.4, false, 0.0, true))
		"dot":
			v.anchor = "chest"
			var pm: ParticleProcessMaterial = _process("dot:%s" % school, {"shape": "sphere", "radius": 0.28 * size,
				"direction": Vector3.DOWN, "spread": 15.0, "velocity": [0.1, 0.4], "gravity": Vector3(0, -5, 0),
				"scale": [0.6, 1.0], "color": _col(school, "secondary", "glow"), "ramp": "fade_late"})
			v.add_emitter(_emitter(pm, _quad(0.1 * size, true), 8, 0.55, false, 0.0, false))
		"slow":
			v.anchor = "feet"
			var pm: ParticleProcessMaterial = _process("slow:%s" % school, {"shape": "ring", "radius": 0.45 * size,
				"direction": Vector3.UP, "spread": 60.0, "velocity": [0.05, 0.25], "scale": [0.8, 1.3],
				"scale_curve": "grow", "color": _col(school, "primary", "glow", 0.45), "ramp": "in_out"})
			v.add_emitter(_emitter(pm, _quad(0.55 * size, true), 10, 1.2, false, 0.0, false))
		"empower":
			v.anchor = "body"
			var glow: MeshInstance3D = _mesh(_capsule(), _glow(school, "body"))
			glow.scale = Vector3(1.0, 1.0, 1.0) * size
			v.add_fader(glow)
			var pm: ParticleProcessMaterial = _process("empower:%s" % school, {"shape": "sphere", "radius": 0.5 * size,
				"direction": Vector3.UP, "spread": 25.0, "velocity": [0.4, 0.9], "scale": [0.5, 1.0],
				"color": _col(school, "primary", "glow"), "ramp": "in_out"})
			var p: GPUParticles3D = _emitter(pm, _quad(0.1 * size, true), 10, 1.0, false, 0.0, false)
			v.add_emitter(p)
		"speed":
			v.anchor = "feet"
			var pm: ParticleProcessMaterial = _process("speed:%s" % school, {"shape": "ring", "radius": 0.35 * size,
				"direction": Vector3.UP, "spread": 30.0, "velocity": [0.2, 0.6], "scale": [0.6, 1.0],
				"scale_curve": "shrink", "color": _col(school, "primary", "glow"), "ramp": "fade"})
			var p: GPUParticles3D = _emitter(pm, _quad(0.16 * size, true), 14, 0.5, false, 0.0, false)
			p.position.y = 0.15
			v.add_emitter(p)
			var ring: MeshInstance3D = _mesh(_torus(), _glow(school, "shell"))
			ring.scale = Vector3(1.1, 0.4, 1.1) * size
			ring.position.y = 0.06
			v.add_fader(ring)
			v.add_spinner(ring, 6.0)
	return v


# ============================================================ helpers for stages

static func _vfx(kind: int, school: String, style: String) -> Vfx:
	var v: Vfx = Vfx.new()
	v.kind = kind
	v.school = school
	v.style = style
	v.name = "%s_%s" % [Vfx.Kind.keys()[kind].to_lower(), style]
	return v


## An expanding, fading shell.
static func _shell(v: Vfx, school: String, variant: String, from: float, to: float, duration: float) -> void:
	var s: MeshInstance3D = _mesh(_sphere(), _glow(school, variant))
	v.add_fader(s)
	v.add_scaler(s, Vector3.ONE * from, Vector3.ONE * to, duration)


static func _sparks(v: Vfx, school: String, slot: String, count: int, speed: float, life: float) -> void:
	var pm: ParticleProcessMaterial = _process("sparks:%s:%s:%d" % [school, slot, roundi(speed * 10.0)], {"shape": "sphere",
		"radius": 0.1, "spread": 180.0, "velocity": [speed * 0.6, speed], "gravity": Vector3(0, -6, 0),
		"damping": [speed * 0.8, speed * 1.2], "scale": [0.5, 1.0], "scale_curve": "shrink", "align": true,
		"color": _col(school, slot, "glow"), "ramp": "fade_late"})
	v.add_emitter(_emitter(pm, _streak_quad(), count, life, true, 1.0, false))


static func _col(school: String, slot: String, boost: String = "glow", alpha: float = 1.0) -> Color:
	var c: Color = EffectsData.colors(school)[slot]
	var k: float = EffectsData.intensity(boost) if boost != "" else 1.0
	return Color(c.r * k, c.g * k, c.b * k, alpha)


static func _mesh(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


## A GPU particle emitter. `local` keeps particles in the emitter's space (they move with it).
static func _emitter(pm: ParticleProcessMaterial, draw: Mesh, count: int, life: float, one_shot: bool,
		explosiveness: float, local: bool) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.process_material = pm
	p.draw_pass_1 = draw
	p.amount = maxi(1, count)
	p.lifetime = life
	p.one_shot = one_shot
	p.explosiveness = explosiveness
	p.randomness = 0.3
	p.local_coords = local
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	p.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 7, 6))
	p.fixed_fps = 30
	p.emitting = true
	return p


# ============================================================ cached resources

static func _cached(key: String, make: Callable) -> Variant:
	if not _cache.has(key):
		_cache[key] = make.call()
	return _cache[key]


static func _shader(file: String) -> Shader:
	return _cached("shader:" + file, func() -> Shader: return load(SHADER_DIR + file) as Shader)


## Glow materials per school: orb (bright centre), shell (bright rim), shield (rim with bands and
## a pulse), beam (soft rim), marker (solid bright: CC rings and stars), body (faint rim).
static func _glow(school: String, variant: String) -> ShaderMaterial:
	return _cached("glow:%s:%s" % [school, variant], func() -> ShaderMaterial:
		var c: Dictionary = EffectsData.colors(school)
		var m: ShaderMaterial = ShaderMaterial.new()
		m.shader = _shader("fresnel_glow.gdshader")
		m.set_shader_parameter("color", c["primary"])
		m.set_shader_parameter("core_color", c["core"])
		var cfg: Dictionary = {
			"orb": {"invert": true, "power": 1.2, "intensity": EffectsData.intensity("core"), "base_alpha": 0.25},
			"shell": {"power": 1.6, "intensity": EffectsData.intensity("glow"), "base_alpha": 0.1},
			"shield": {"power": 2.4, "intensity": EffectsData.intensity("glow"), "base_alpha": 0.06, "pulse": 0.1, "bands": 0.35},
			"beam": {"power": 0.8, "intensity": EffectsData.intensity("glow"), "base_alpha": 0.05, "bands": 0.4},
			"marker": {"invert": true, "power": 0.4, "intensity": EffectsData.intensity("core"), "base_alpha": 0.5},
			"body": {"power": 2.2, "intensity": EffectsData.intensity("glow"), "base_alpha": 0.0, "pulse": 0.15},
		}.get(variant, {})
		for k: String in cfg:
			m.set_shader_parameter(k, cfg[k])
		return m)


static func _ice_material(school: String) -> ShaderMaterial:
	return _cached("ice:" + school, func() -> ShaderMaterial:
		var c: Dictionary = EffectsData.colors(school)
		var m: ShaderMaterial = ShaderMaterial.new()
		m.shader = _shader("ice_solid.gdshader")
		m.set_shader_parameter("color", c["primary"])
		m.set_shader_parameter("core_color", c["core"])
		return m)


## Ground circle material per school and relation (the outline color is the relation's).
static func _ground_material(school: String, hostile: bool) -> ShaderMaterial:
	return _cached("ground:%s:%s" % [school, "enemy" if hostile else "ally"], func() -> ShaderMaterial:
		var m: ShaderMaterial = ShaderMaterial.new()
		m.shader = _shader("ground_ring.gdshader")
		m.set_shader_parameter("fill_color", EffectsData.colors(school)["primary"])
		m.set_shader_parameter("outline_color", EffectsData.outline_color(hostile))
		m.set_shader_parameter("intensity", EffectsData.intensity("fill") * 1.4)
		m.set_shader_parameter("fill_alpha", 0.13)  # the outline carries the area; the fill only tints
		return m)


static func _arc_material(school: String) -> ShaderMaterial:
	return _cached("arc:" + school, func() -> ShaderMaterial:
		var c: Dictionary = EffectsData.colors(school)
		var m: ShaderMaterial = ShaderMaterial.new()
		m.shader = _shader("swing_arc.gdshader")
		m.set_shader_parameter("color", c["primary"])
		m.set_shader_parameter("core_color", c["core"])
		m.set_shader_parameter("intensity", EffectsData.intensity("glow"))
		return m)


## Particle process material; `cfg` keys: shape (point, sphere, sphere_surface, ring, box), radius,
## inner, box, direction, spread, flatness, velocity [min, max], gravity, radial_accel, damping,
## scale [min, max], scale_curve (grow, shrink), spin, align, color, ramp (fade, fade_late, in_out).
static func _process(key: String, cfg: Dictionary) -> ParticleProcessMaterial:
	return _cached("pm:" + key, func() -> ParticleProcessMaterial:
		var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
		match str(cfg.get("shape", "point")):
			"sphere":
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
				pm.emission_sphere_radius = float(cfg.get("radius", 0.1))
			"sphere_surface":
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
				pm.emission_sphere_radius = float(cfg.get("radius", 0.1))
			"ring":
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
				pm.emission_ring_axis = Vector3.UP
				pm.emission_ring_radius = float(cfg.get("radius", 0.5))
				pm.emission_ring_inner_radius = float(cfg.get("inner", float(cfg.get("radius", 0.5)) * 0.85))
				pm.emission_ring_height = 0.05
			"box":
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
				pm.emission_box_extents = cfg.get("box", Vector3.ONE * 0.2)
		pm.direction = cfg.get("direction", Vector3.UP)
		pm.spread = float(cfg.get("spread", 45.0))
		pm.flatness = float(cfg.get("flatness", 0.0))
		var vel: Array = cfg.get("velocity", [0.5, 1.0])
		pm.initial_velocity_min = float(vel[0])
		pm.initial_velocity_max = float(vel[1])
		pm.gravity = cfg.get("gravity", Vector3.ZERO)
		if cfg.has("radial_accel"):
			pm.radial_accel_min = float(cfg["radial_accel"][0])
			pm.radial_accel_max = float(cfg["radial_accel"][1])
		if cfg.has("damping"):
			pm.damping_min = float(cfg["damping"][0])
			pm.damping_max = float(cfg["damping"][1])
		var sc: Array = cfg.get("scale", [1.0, 1.0])
		pm.scale_min = float(sc[0])
		pm.scale_max = float(sc[1])
		if cfg.has("scale_curve"):
			pm.scale_curve = _curve(str(cfg["scale_curve"]))
		if bool(cfg.get("spin", false)):
			pm.angle_min = -180.0
			pm.angle_max = 180.0
			pm.angular_velocity_min = -360.0
			pm.angular_velocity_max = 360.0
		pm.particle_flag_align_y = bool(cfg.get("align", false))
		pm.color = cfg.get("color", Color.WHITE)
		pm.color_ramp = _ramp(str(cfg.get("ramp", "fade")))
		return pm)


static func _ramp(kind: String) -> GradientTexture1D:
	return _cached("ramp:" + kind, func() -> GradientTexture1D:
		var g: Gradient = Gradient.new()
		match kind:
			"in_out":
				g.offsets = PackedFloat32Array([0.0, 0.2, 0.7, 1.0])
				g.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)])
			"fade_late":
				g.offsets = PackedFloat32Array([0.0, 0.6, 1.0])
				g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0)])
			_:
				g.offsets = PackedFloat32Array([0.0, 1.0])
				g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
		var t: GradientTexture1D = GradientTexture1D.new()
		t.gradient = g
		t.width = 64
		return t)


static func _curve(kind: String) -> CurveTexture:
	return _cached("curve:" + kind, func() -> CurveTexture:
		var c: Curve = Curve.new()
		if kind == "grow":
			c.add_point(Vector2(0.0, 0.4))
			c.add_point(Vector2(1.0, 1.0))
		else:
			c.add_point(Vector2(0.0, 1.0))
			c.add_point(Vector2(1.0, 0.1))
		var t: CurveTexture = CurveTexture.new()
		t.curve = c
		return t)


## Soft round dot for billboard particles.
static func _dot_texture() -> GradientTexture2D:
	return _cached("tex:dot", func() -> GradientTexture2D:
		var g: Gradient = Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
		var t: GradientTexture2D = GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 64
		t.height = 64
		return t)


static func _particle_material(additive: bool, billboard: int) -> StandardMaterial3D:
	return _cached("pmat:%s:%d" % [additive, billboard], func() -> StandardMaterial3D:
		var m: StandardMaterial3D = StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		m.billboard_mode = billboard
		m.billboard_keep_scale = true
		m.vertex_color_use_as_albedo = true
		m.disable_fog = true
		m.albedo_texture = _dot_texture() if billboard == BaseMaterial3D.BILLBOARD_PARTICLES else null
		return m)


## Billboard quad of `size` m for particles; additive for light, mixed for smoke and dust.
static func _quad(size: float, additive: bool) -> QuadMesh:
	var s: float = snappedf(size, 0.01)
	return _cached("quad:%.2f:%s" % [s, additive], func() -> QuadMesh:
		var q: QuadMesh = QuadMesh.new()
		q.size = Vector2(s, s)
		q.material = _particle_material(additive, BaseMaterial3D.BILLBOARD_PARTICLES)
		return q)


## Thin quad stretched along the velocity (particle_flag_align_y) for sparks.
static func _streak_quad() -> QuadMesh:
	return _cached("quad:streak", func() -> QuadMesh:
		var q: QuadMesh = QuadMesh.new()
		q.size = Vector2(0.035, 0.28)
		var m: StandardMaterial3D = _particle_material(true, BaseMaterial3D.BILLBOARD_FIXED_Y).duplicate()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
		m.albedo_texture = _dot_texture()
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		q.material = m
		return q)


## Crystal pieces for shard particles.
static func _crystal_particle(size: float) -> Mesh:
	var s: float = snappedf(size, 0.01)
	return _cached("crystalp:%.2f" % s, func() -> Mesh:
		var m: ArrayMesh = _octahedron(Vector3(0.45, 1.0, 0.45) * s)
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.disable_fog = true
		m.surface_set_material(0, mat)
		return m)


static func _sphere() -> SphereMesh:
	return _cached("mesh:sphere", func() -> SphereMesh:
		var m: SphereMesh = SphereMesh.new()
		m.radius = 0.5
		m.height = 1.0
		m.radial_segments = 20
		m.rings = 10
		return m)


static func _capsule() -> CapsuleMesh:
	return _cached("mesh:capsule", func() -> CapsuleMesh:
		var m: CapsuleMesh = CapsuleMesh.new()
		m.radius = 0.55
		m.height = 2.2
		m.radial_segments = 16
		m.rings = 6
		return m)


static func _torus() -> TorusMesh:
	return _cached("mesh:torus", func() -> TorusMesh:
		var m: TorusMesh = TorusMesh.new()
		m.inner_radius = 0.42
		m.outer_radius = 0.5
		m.rings = 32
		m.ring_segments = 6
		return m)


## Chunkier ring for crowd-control markers (readable at 30 m).
static func _thick_torus() -> TorusMesh:
	return _cached("mesh:thick_torus", func() -> TorusMesh:
		var m: TorusMesh = TorusMesh.new()
		m.inner_radius = 0.36
		m.outer_radius = 0.5
		m.rings = 32
		m.ring_segments = 8
		return m)


static func _cylinder() -> CylinderMesh:
	return _cached("mesh:cylinder", func() -> CylinderMesh:
		var m: CylinderMesh = CylinderMesh.new()
		m.top_radius = 0.5
		m.bottom_radius = 0.5
		m.height = 1.0
		m.radial_segments = 16
		m.rings = 1
		m.cap_top = false
		m.cap_bottom = false
		return m)


static func _cone() -> CylinderMesh:
	return _cached("mesh:cone", func() -> CylinderMesh:
		var m: CylinderMesh = CylinderMesh.new()
		m.top_radius = 0.0
		m.bottom_radius = 0.5
		m.height = 1.0
		m.radial_segments = 5
		m.rings = 1
		return m)


static func _prism() -> CylinderMesh:
	return _cached("mesh:prism", func() -> CylinderMesh:
		var m: CylinderMesh = CylinderMesh.new()
		m.top_radius = 0.42
		m.bottom_radius = 0.5
		m.height = 1.0
		m.radial_segments = 6
		m.rings = 1
		return m)


static func _box() -> BoxMesh:
	return _cached("mesh:box", func() -> BoxMesh:
		var m: BoxMesh = BoxMesh.new()
		m.size = Vector3.ONE
		return m)


static func _plane() -> PlaneMesh:
	return _cached("mesh:plane", func() -> PlaneMesh:
		var m: PlaneMesh = PlaneMesh.new()
		m.size = Vector2(2.0, 2.0)
		return m)


static func _crystal() -> ArrayMesh:
	return _cached("mesh:crystal", func() -> ArrayMesh: return _octahedron(Vector3(0.5, 0.5, 0.5)))


## Six-point double pyramid (crystals, stun stars) with outward normals and UVs.
static func _octahedron(half: Vector3) -> ArrayMesh:
	var pts: Array[Vector3] = [Vector3(half.x, 0, 0), Vector3(0, 0, half.z), Vector3(-half.x, 0, 0), Vector3(0, 0, -half.z)]
	var top: Vector3 = Vector3(0, half.y, 0)
	var bottom: Vector3 = Vector3(0, -half.y, 0)
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in 4:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % 4]
		for tri: Array in [[top, b, a], [bottom, a, b]]:
			var n: Vector3 = ((tri[1] as Vector3) - (tri[0] as Vector3)).cross((tri[2] as Vector3) - (tri[0] as Vector3)).normalized()
			for k: int in 3:
				st.set_normal(n)
				st.set_color(Color.WHITE)
				st.set_uv(Vector2(float(i) / 4.0, 0.0 if tri[k] == top else (1.0 if tri[k] == bottom else 0.5)))
				st.add_vertex(tri[k])
	return st.commit()


## Crescent in the XZ plane in front of the origin (-Z), from `a0` to `a1` degrees (left to
## right), between radii r0 and r1; UV.x runs along the swing, UV.y from inner to outer edge.
static func _crescent(a0: float, a1: float, r0: float, r1: float) -> ArrayMesh:
	return _cached("mesh:crescent:%d:%d:%.2f:%.2f" % [roundi(a0), roundi(a1), r0, r1], func() -> ArrayMesh:
		var st: SurfaceTool = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var n: int = 24
		for i: int in n:
			var quad: Array[Vector3] = []
			var uvs: Array[Vector2] = []
			for k: int in [i, i + 1]:
				var t: float = float(k) / n
				var a: float = deg_to_rad(lerpf(a0, a1, t))
				# the blade edge is thinner at both ends of the swing
				var w: float = sin(t * PI) * 0.7 + 0.3
				var inner: float = lerpf(r1, r0, w)
				quad.append(Vector3(sin(a) * inner, 0.0, -cos(a) * inner))
				quad.append(Vector3(sin(a) * r1, 0.0, -cos(a) * r1))
				uvs.append(Vector2(t, 0.0))
				uvs.append(Vector2(t, 1.0))
			for idx: int in [0, 1, 2, 2, 1, 3]:
				st.set_normal(Vector3.UP)
				st.set_uv(uvs[idx])
				st.add_vertex(quad[idx])
		return st.commit())
