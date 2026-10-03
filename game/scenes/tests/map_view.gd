extends Node3D
## Review views of an arena for screenshots (backlog M1-14):
##   tools/screenshot.sh res://scenes/tests/map_view.tscn previews/maps/top.png -- \
##     (arguments after the scene: --map gallows_courtyard --view top|overview|player|room_a|room_b|lineup|character --gates open|closed --anim run --anim-time 0.18)
## Places players at the spawns and in the courtyard so scale reads in every view: the built
## character model when one exists (the Warblade for now), otherwise a team-colored capsule.
## View "character" frames the player's character up close. Characters are animated and hold
## their weapons through CharacterRig; --anim <clip> --anim-time <s> freezes every character on
## that frame (default: idle at 0 s).

const PLAYER_HEIGHT: float = 1.8
## Specs shown at each team's spawns, in order.
var lineup: Array[String] = ["warblade_carnage", "arcanist_rime", "oracle_grace"]

var builder: MapBuilder
var anim_clip: String = "idle"
var anim_time: float = 0.0


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var map_id: String = _arg(args, "--map", "gallows_courtyard")
	var view: String = _arg(args, "--view", "overview")
	anim_clip = _arg(args, "--anim", "idle")
	anim_time = float(_arg(args, "--anim-time", "0"))
	for a: Dictionary in Data.assets.values():  # every spec with a built character joins the lineup
		if a.get("kind", "") == "character" and not str(a.get("spec", "")) in lineup:
			lineup.append(str(a["spec"]))
	var map: Dictionary = Data.maps.get(map_id, {})
	var scene: PackedScene = load(map.get("scene", "res://scenes/maps/gallows_courtyard.tscn"))
	builder = scene.instantiate()
	builder.map_id = map_id
	add_child(builder)
	builder.set_gates_open(_arg(args, "--gates", "open" if view in ["player", "room_a", "room_b"] else "closed") == "open", 0.0)
	for team: int in 2:
		var spawns: Array = map["spawns"]["team_a" if team == 0 else "team_b"]
		for i: int in spawns.size():
			var sp: Array = spawns[i]
			_stand_in(Vector3(sp[0], 0, sp[2]), team, -PI / 2 if team == 0 else PI / 2, lineup[i % lineup.size()])
	if view == "lineup":  # the classes side by side, facing the camera (east)
		for i: int in lineup.size():
			_stand_in(Vector3(-15.5, 0, (i - (lineup.size() - 1) * 0.5) * 1.6), 0, -PI / 2, lineup[i])
	else:  # a skirmish in the courtyard, and the player for the player view
		_stand_in(Vector3(-4.5, 0, 9.5), 0, -2.2, "warblade_carnage")
		_stand_in(Vector3(-3.2, 0, 10.8), 1, 0.9, "oracle_grace")
		_stand_in(Vector3(9.5, 0, -2.0), 1, 1.8, "arcanist_rime")
		_stand_in(Vector3(-15.5, 0, 0.6), 0, -PI / 2, "warblade_carnage")
	_camera(view)


## The character asset for a spec (data/assets, kind "character"), or empty.
static func _character_asset(spec_id: String) -> Dictionary:
	for a: Dictionary in Data.assets.values():
		if a.get("kind", "") == "character" and a.get("spec", "") == spec_id:
			return a
	return {}


static func _res(asset: Dictionary) -> String:
	return CharacterRig.res_path(asset)


func _stand_in(pos: Vector3, team: int, yaw: float, spec_id: String = "") -> void:
	var root: Node3D = Node3D.new()
	root.position = pos
	root.rotation.y = yaw
	var asset: Dictionary = _character_asset(spec_id)
	var model_path: String = _res(asset) if not asset.is_empty() else ""
	if model_path != "" and ResourceLoader.exists(model_path):
		var model: Node3D = (load(model_path) as PackedScene).instantiate()
		model.rotation.y = PI  # models face +Z; the game's forward is -Z
		root.add_child(model)
		add_child(root)
		var player: AnimationPlayer = CharacterRig.setup(asset, model)
		if player != null:
			if not player.has_animation(anim_clip):
				Log.error("map_view: no animation '%s'" % anim_clip)
				return
			player.play(anim_clip)
			player.seek(anim_time, true)
			player.pause()
		return
	var body: CapsuleMesh = CapsuleMesh.new()
	body.radius = ArenaGeometry.UNIT_RADIUS
	body.height = PLAYER_HEIGHT
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = MapBuilder.TEAM_COLORS[team].lightened(0.15)
	mat.roughness = 0.7
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = body
	mi.material_override = mat
	mi.position.y = PLAYER_HEIGHT * 0.5
	root.add_child(mi)
	var nose: BoxMesh = BoxMesh.new()  # shows which way the stand-in faces (-Z is forward)
	nose.size = Vector3(0.2, 0.12, 0.3)
	var nm: MeshInstance3D = MeshInstance3D.new()
	nm.mesh = nose
	nm.material_override = mat
	nm.position = Vector3(0, 1.55, -0.45)
	root.add_child(nm)
	add_child(root)


func _camera(view: String) -> void:
	var cam: Camera3D = Camera3D.new()
	add_child(cam)
	match view:
		"top":
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.size = 54.0
			cam.position = Vector3(0, 60, 0)
			cam.rotation_degrees = Vector3(-90, 0, 0)
			cam.far = 200.0
		"player":
			# third-person camera 5.7 m behind and 2.9 m up from the player at (-15.5, 0, 0.6), facing +x
			cam.fov = 70.0
			cam.position = Vector3(-21.2, 2.9, 0.6)
			cam.look_at(Vector3(0, 1.4, 0.3))
		"room_a", "room_b":
			# from the back of a starting room, through the open gate into the courtyard
			var s: float = -1.0 if view == "room_a" else 1.0
			cam.fov = 70.0
			cam.position = Vector3(s * 24.6, 2.6, 0.4)
			cam.look_at(Vector3(s * 6.0, 2.2, 0.0))
		"lineup":
			cam.fov = 38.0
			cam.position = Vector3(-10.2, 1.6, 0.0)
			cam.look_at(Vector3(-15.5, 1.05, 0.0))
		"character":
			cam.fov = 40.0
			cam.position = Vector3(-12.6, 1.9, 3.4)
			cam.look_at(Vector3(-15.5, 1.1, 0.6))
		_:
			cam.fov = 55.0
			cam.position = Vector3(-31, 29, 31)
			cam.look_at(Vector3(0, 0, 0))
	cam.current = true


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
