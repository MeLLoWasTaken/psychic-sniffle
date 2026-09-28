extends Node
## Entry point. Starts the server scene when launched with `-- --server`, otherwise the client.
##   godot --headless --path game -- --server

const CLIENT_SCENE: String = "res://scenes/client_main.tscn"
const SERVER_SCENE: String = "res://scenes/server_main.tscn"


func _ready() -> void:
	var is_server: bool = "--server" in OS.get_cmdline_user_args()
	var scene: String = SERVER_SCENE if is_server else CLIENT_SCENE
	Log.info("boot: starting %s" % ("server" if is_server else "client"))
	get_tree().change_scene_to_file.call_deferred(scene)
