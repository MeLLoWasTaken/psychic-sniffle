extends Node3D
## Review views of an arena for screenshots (backlog M1-14):
##   tools/screenshot.sh res://scenes/tests/map_view.tscn previews/maps/top.png -- \
##     (arguments after the scene: --map gallows_courtyard --view top|overview|player --gates open|closed)
## Places team-colored stand-in players (1.8 m capsules) at the spawns and in the courtyard so
## scale reads in every view.

const PLAYER_HEIGHT: float = 1.8

var builder: MapBuilder


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var map_id: String = _arg(args, "--map", "gallows_courtyard")
	var view: String = _arg(args, "--view", "overview")
	var map: Dictionary = Data.maps.get(map_id, {})
	var scene: PackedScene = load(map.get("scene", "res://scenes/maps/gallows_courtyard.tscn"))
	builder = scene.instantiate()
	builder.map_id = map_id
	add_child(builder)
	builder.set_gates_open(_arg(args, "--gates", "open" if view == "player" else "closed") == "open", 0.0)
	for team: int in 2:
		for sp: Array in map["spawns"]["team_a" if team == 0 else "team_b"]:
			_stand_in(Vector3(sp[0], 0, sp[2]), team, -PI / 2 if team == 0 else PI / 2)
	# a skirmish in the courtyard
	_stand_in(Vector3(-4.5, 0, 9.5), 0, -2.2)
	_stand_in(Vector3(-3.2, 0, 10.8), 1, 0.9)
	_stand_in(Vector3(9.5, 0, -2.0), 1, 1.8)
	_stand_in(Vector3(-15.5, 0, 0.6), 0, -PI / 2)  # the player in the player view
	_camera(view)


func _stand_in(pos: Vector3, team: int, yaw: float) -> void:
	var root: Node3D = Node3D.new()
	root.position = pos
	root.rotation.y = yaw
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
		_:
			cam.fov = 55.0
			cam.position = Vector3(-31, 29, 31)
			cam.look_at(Vector3(0, 0, 0))
	cam.current = true


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
