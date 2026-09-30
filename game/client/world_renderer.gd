class_name WorldRenderer
extends Node3D
## Draws the units of a world "view" (backlog M1-23): the dictionary shape bots read, built by
## MatchRunner.view_for in-process or by NetClient.bot_view from snapshots. It never touches
## simulation objects, so the practice scene's in-process match can be swapped for the network
## client (M1-28) without changing this layer.
##
## Feed one view per simulation tick with push_view(); call draw(alpha) every frame with the
## fraction of the next tick that has elapsed: positions and facings are interpolated between
## the last two views. Characters are the built models (CharacterRig) or a team-colored capsule
## when a spec has none. Animation v1: idle, run, backpedal, strafes and death chosen from the
## movement between views (the locomotion blend is M1-24). A ring on the ground marks the target.

const MOVE_SPEED_MIN: float = 0.5  ## m/s below which a unit stands idle
const BLEND_S: float = 0.15
const RING_RADIUS: float = 0.8
const RING_COLORS: Dictionary = {"enemy": Color(0.95, 0.12, 0.08), "ally": Color(0.2, 0.95, 0.3)}
const CAPSULE_HEIGHT: float = 1.8

var tick_rate: int = 60
var view: Dictionary = {}  ## the newest view
var units: Dictionary = {}  ## unit id -> entry (see _entry)
var target_id: int = -1
var ring: MeshInstance3D
var _last_tick: int = -1


func _init() -> void:
	ring = _make_ring()
	ring.visible = false
	add_child(ring)


## Take the newest world view. Views with a tick already seen are ignored.
func push_view(v: Dictionary) -> void:
	if v.is_empty() or int(v["tick"]) == _last_tick:
		return
	_last_tick = int(v["tick"])
	tick_rate = int(v.get("tick_rate", tick_rate))
	view = v
	var seen: Dictionary = {}
	for u: Dictionary in v["units"]:
		var id: int = int(u["id"])
		seen[id] = true
		var e: Dictionary = units.get(id, {})
		if e.is_empty():
			e = _entry(u)
			units[id] = e
		e["prev_pos"] = e["cur_pos"]
		e["prev_facing"] = e["cur_facing"]
		e["cur_pos"] = u["position"]
		e["cur_facing"] = float(u["facing"])
		e["health"] = int(u["health"])
		e["team"] = int(u["team"])
	for id: int in units.keys():
		if not seen.has(id):
			(units[id]["root"] as Node3D).queue_free()
			units.erase(id)


## Place every unit for this frame, `alpha` (0..1) of the way from the previous view to the newest.
func draw(alpha: float) -> void:
	alpha = clampf(alpha, 0.0, 1.0)
	for id: int in units:
		var e: Dictionary = units[id]
		var root: Node3D = e["root"]
		var prev: Vector3 = e["prev_pos"]
		var cur: Vector3 = e["cur_pos"]
		root.position = prev.lerp(cur, alpha)
		root.rotation.y = lerp_angle(float(e["prev_facing"]), float(e["cur_facing"]), alpha)
		_animate(e, (cur - prev) * tick_rate)
	_draw_ring()


## The drawn position of a unit (interpolated), or INF when it is not in the view.
func drawn_position(id: int) -> Vector3:
	var e: Dictionary = units.get(id, {})
	return (e["root"] as Node3D).position if not e.is_empty() else Vector3(INF, INF, INF)


## The newest view's units at their drawn positions, for click picking.
func drawn_units() -> Array:
	var out: Array = []
	for u: Dictionary in view.get("units", []):
		var copy: Dictionary = u.duplicate()
		if units.has(int(u["id"])):
			copy["position"] = drawn_position(int(u["id"]))
		out.append(copy)
	return out


## Which clip a unit plays for a velocity in m/s: facing-relative direction picks run, backpedal
## or a strafe; dead units play death.
static func clip_for(velocity: Vector3, facing: float, alive: bool) -> String:
	if not alive:
		return "death"
	var flat: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var speed: float = flat.length()
	if speed < MOVE_SPEED_MIN:
		return "idle"
	var f: float = flat.dot(Movement.forward_of(facing)) / speed
	var r: float = flat.dot(Movement.right_of(facing)) / speed
	if f >= 0.5:
		return "run"
	if f <= -0.5:
		return "backpedal"
	return "strafe_right" if r > 0.0 else "strafe_left"


func _animate(e: Dictionary, velocity: Vector3) -> void:
	var player: AnimationPlayer = e["player"]
	if player == null:
		return
	var clip: String = clip_for(velocity, float(e["cur_facing"]), int(e["health"]) > 0)
	if clip == e["clip"] or not player.has_animation(clip):
		return
	e["clip"] = clip
	player.play(clip, BLEND_S)


func _draw_ring() -> void:
	var e: Dictionary = units.get(target_id, {})
	if e.is_empty() or view.is_empty():
		ring.visible = false
		return
	var hostile: bool = int(e["team"]) != int(view["me"]["team"])
	(ring.material_override as StandardMaterial3D).albedo_color = RING_COLORS["enemy" if hostile else "ally"]
	var p: Vector3 = (e["root"] as Node3D).position
	ring.position = Vector3(p.x, 0.04, p.z)  # stays on the ground under a jumping target
	ring.visible = true


func _entry(u: Dictionary) -> Dictionary:
	var root: Node3D = Node3D.new()
	root.name = "Unit%d" % int(u["id"])
	add_child(root)
	var player: AnimationPlayer = _add_character(root, str(u["spec"]), int(u["team"]))
	if player != null and player.has_animation("idle"):
		player.play("idle")
	return {"root": root, "player": player, "clip": "idle", "prev_pos": u["position"], "cur_pos": u["position"],
		"prev_facing": float(u["facing"]), "cur_facing": float(u["facing"]), "health": int(u["health"]),
		"team": int(u["team"])}


## The character asset for a spec (data/assets, kind "character"), or empty.
static func character_asset(spec_id: String) -> Dictionary:
	for a: Dictionary in Data.assets.values():
		if a.get("kind", "") == "character" and a.get("spec", "") == spec_id:
			return a
	return {}


## Adds the spec's built character under `root` (facing the game's forward like map_view does),
## or a capsule stand-in. Returns its AnimationPlayer, or null for a stand-in.
func _add_character(root: Node3D, spec_id: String, team: int) -> AnimationPlayer:
	var asset: Dictionary = character_asset(spec_id)
	var path: String = CharacterRig.res_path(asset) if not asset.is_empty() else ""
	if path != "" and ResourceLoader.exists(path):
		var model: Node3D = (load(path) as PackedScene).instantiate()
		model.rotation.y = PI  # models face +Z; the game's forward is -Z
		root.add_child(model)
		return CharacterRig.setup(asset, model)
	var body: CapsuleMesh = CapsuleMesh.new()
	body.radius = ArenaGeometry.UNIT_RADIUS
	body.height = CAPSULE_HEIGHT
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = MapBuilder.TEAM_COLORS[team].lightened(0.15)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = body
	mi.material_override = mat
	mi.position.y = CAPSULE_HEIGHT * 0.5
	root.add_child(mi)
	return null


static func _make_ring() -> MeshInstance3D:
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = RING_RADIUS - 0.1
	torus.outer_radius = RING_RADIUS + 0.1
	torus.rings = 48
	torus.ring_segments = 8
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = RING_COLORS["enemy"]
	mat.no_depth_test = false
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "TargetRing"
	mi.mesh = torus
	mi.material_override = mat
	mi.scale = Vector3(1.0, 0.25, 1.0)  # flattened onto the ground
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
