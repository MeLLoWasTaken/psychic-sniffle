class_name Vfx
extends Node3D
## One live spell effect (backlog M1-25): a cast glow, projectile, impact, ground circle, swing,
## displacement or aura visual, built by EffectLibrary and driven by EffectsDirector.
##
## Generic animation only, set up by the builder: parts that follow anchor points on a unit,
## meshes whose scale or shader "progress" runs over time, spinners, and a shared alpha
## (instance shader parameter "alpha") that fades in, and out after stop(). Particle emitters stop
## emitting on stop() and the node is finished once they have faded (advance() returns false).

enum Kind { CAST, PROJECTILE, IMPACT, GROUND, MELEE, DISPLACEMENT, AURA }

var kind: int = Kind.IMPACT
var ability: String = ""
var aura: String = ""
var style: String = ""
var school: String = "physical"
var source: int = -1  ## unit whose action made it
var unit: int = -1  ## unit it follows, or -1 when fixed in the world
var anchor: String = "feet"  ## anchor point on `unit` (EffectsDirector.anchor_position)
var follow_yaw: bool = false  ## turn with the unit (swings)
var priority: int = 1  ## higher survives the budget
var hostile: bool = false  ## cast by an enemy of the local player
var cc: bool = false  ## crowd-control aura
var lifetime: float = -1.0  ## seconds until stop(); < 0 runs until stopped
var linger: float = 0.35  ## after stop(): fade time, and time for particles to die out
var fade_in: float = 0.08
var age: float = 0.0
var stopping: bool = false
var hold: bool = false  ## preview: the clock is frozen at `age`, emitters loop
var amount: int = 0  ## particles this effect can have alive (budget)
var data: Dictionary = {}  ## per-kind state (projectile target and speed...)

var parts: Array[Dictionary] = []  ## {node: Node3D, anchor: String} placed at anchors of `unit`
var emitters: Array[GPUParticles3D] = []
var faders: Array[GeometryInstance3D] = []  ## get the shared alpha
var scalers: Array[Dictionary] = []  ## {node, from: Vector3, to: Vector3, duration, ease}
var progressers: Array[Dictionary] = []  ## {node, duration, to: float}
var spinners: Array[Dictionary] = []  ## {node, axis: Vector3, speed: float}
var _stop_age: float = 0.0


## Adds an emitter child and counts its particles.
func add_emitter(p: GPUParticles3D, parent: Node3D = null) -> GPUParticles3D:
	(parent if parent != null else self).add_child(p)
	emitters.append(p)
	amount += p.amount
	return p


func add_fader(g: GeometryInstance3D, parent: Node3D = null) -> GeometryInstance3D:
	if g.get_parent() == null:
		(parent if parent != null else self).add_child(g)
	faders.append(g)
	return g


## Scale `node` from `from` to `to` over `duration` s (ease "out" decelerates, "pop" overshoots).
func add_scaler(node: Node3D, from: Vector3, to: Vector3, duration: float, ease_kind: String = "out") -> void:
	node.scale = from
	scalers.append({"node": node, "from": from, "to": to, "duration": maxf(duration, 0.001), "ease": ease_kind})


## Run the instance shader parameter "progress" of `node` from 0 to `to` over `duration` s.
func add_progress(node: GeometryInstance3D, duration: float, to: float = 1.0) -> void:
	node.set_instance_shader_parameter("progress", 0.0)
	progressers.append({"node": node, "duration": maxf(duration, 0.001), "to": to})


func add_spinner(node: Node3D, speed: float, axis: Vector3 = Vector3.UP) -> void:
	spinners.append({"node": node, "axis": axis, "speed": speed})


func add_part(node: Node3D, anchor_name: String) -> void:
	add_child(node)
	parts.append({"node": node, "anchor": anchor_name})


## Stop emitting and fade out; the effect finishes `linger` seconds later.
func stop() -> void:
	if stopping:
		return
	stopping = true
	_stop_age = age
	for p: GPUParticles3D in emitters:
		if not p.one_shot:
			p.emitting = false


## Freeze at `t` seconds for previews: emitters loop so bursts stay visible.
func set_hold(t: float) -> void:
	hold = true
	age = 0.0
	_apply(t)
	age = t
	for p: GPUParticles3D in emitters:
		p.one_shot = false
		p.emitting = true


## Advance `delta` seconds. Returns false once the effect is finished and can be freed.
func advance(delta: float) -> bool:
	if hold:
		_spin(delta)
		return true
	var t: float = age + delta
	if lifetime >= 0.0 and t >= lifetime and not stopping:
		age = t
		stop()
	_apply(t)
	_spin(delta)
	age = t
	return not (stopping and age - _stop_age >= linger)


## The shared alpha now (fade in, then out over `linger` after stop()).
func current_alpha() -> float:
	var a: float = clampf(age / fade_in, 0.0, 1.0) if fade_in > 0.0 else 1.0
	if stopping and not hold:
		a *= clampf(1.0 - (age - _stop_age) / maxf(linger, 0.001), 0.0, 1.0)
	return a


func _apply(t: float) -> void:
	for s: Dictionary in scalers:
		var k: float = clampf(t / float(s["duration"]), 0.0, 1.0)
		match str(s["ease"]):
			"out":
				k = 1.0 - (1.0 - k) * (1.0 - k)
			"pop":
				k = 1.0 + 2.70158 * pow(k - 1.0, 3.0) + 1.70158 * pow(k - 1.0, 2.0)
		(s["node"] as Node3D).scale = (s["from"] as Vector3).lerp(s["to"], k)
	for p: Dictionary in progressers:
		(p["node"] as GeometryInstance3D).set_instance_shader_parameter("progress",
			clampf(t / float(p["duration"]), 0.0, 1.0) * float(p["to"]))
	var saved: float = age
	age = t
	var a: float = current_alpha()
	age = saved
	for g: GeometryInstance3D in faders:
		g.set_instance_shader_parameter("alpha", a)


func _spin(delta: float) -> void:
	for s: Dictionary in spinners:
		(s["node"] as Node3D).rotate_object_local(s["axis"], float(s["speed"]) * delta)
