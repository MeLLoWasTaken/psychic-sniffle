class_name WorldRenderer
extends Node3D
## Draws the units of a world "view" (backlog M1-23): the dictionary shape bots read, built by
## MatchRunner.view_for in-process or by NetClient.bot_view from snapshots. It never touches
## simulation objects, so the practice scene's in-process match can be swapped for the network
## client (M1-28) without changing this layer.
##
## Feed one view per simulation tick with push_view() and its events with push_events(); call
## draw(alpha, delta) every frame with the fraction of the next tick that has elapsed (positions
## and facings are interpolated between the last two views) and the frame time. Characters are the built models (CharacterRig) or a team-colored capsule
## when a spec has none. Each character is animated by a CharacterAnimator (M1-24) from its view
## entry (movement, cast, auras, health, match result) and the combat events fed with
## push_events(). A ring on the ground marks the target.

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
		e["unit"] = u
	for id: int in units.keys():
		if not seen.has(id):
			(units[id]["root"] as Node3D).queue_free()
			units.erase(id)


## Combat events since the last call (MatchRunner.take_events or the client's event stream):
## each goes to the animators of the units it names (cast releases, swings, hit reactions).
func push_events(evs: Array) -> void:
	for ev: Dictionary in evs:
		var ids: Array[int] = [int(ev.get("source", -1))]
		if int(ev.get("target", -1)) != ids[0]:
			ids.append(int(ev.get("target", -1)))
		for id: int in ids:
			var e: Dictionary = units.get(id, {})
			if not e.is_empty() and e["animator"] != null:
				(e["animator"] as CharacterAnimator).push_event(ev)


## Place every unit for this frame, `alpha` (0..1) of the way from the previous view to the newest,
## and advance their animation by `delta` seconds (0 holds every pose, e.g. while paused).
func draw(alpha: float, delta: float = 0.0) -> void:
	alpha = clampf(alpha, 0.0, 1.0)
	for id: int in units:
		var e: Dictionary = units[id]
		var root: Node3D = e["root"]
		var prev: Vector3 = e["prev_pos"]
		var cur: Vector3 = e["cur_pos"]
		root.position = prev.lerp(cur, alpha)
		root.rotation.y = lerp_angle(float(e["prev_facing"]), float(e["cur_facing"]), alpha)
		if e["animator"] != null:
			(e["animator"] as CharacterAnimator).update(e["unit"], view, (cur - prev) * tick_rate, delta)
	_draw_ring()


## The animator of a unit, or null (not in the view, or a capsule stand-in).
func animator_of(id: int) -> CharacterAnimator:
	return units.get(id, {}).get("animator", null)


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
	var asset: Dictionary = character_asset(str(u["spec"]))
	var player: AnimationPlayer = _add_character(root, str(u["spec"]), int(u["team"]))
	var animator: CharacterAnimator = null
	if player != null:
		var set_id: String = str(CharacterRig.animation_set(str(asset.get("body_build", ""))).get("id", "humanoid"))
		animator = CharacterAnimator.create(player, int(u["id"]), int(u["team"]), set_id)
	return {"root": root, "player": player, "animator": animator, "unit": u, "prev_pos": u["position"],
		"cur_pos": u["position"], "prev_facing": float(u["facing"]), "cur_facing": float(u["facing"]),
		"health": int(u["health"]), "team": int(u["team"])}


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
