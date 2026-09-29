extends Node
## Entry point. Starts the server scene when launched with `-- --server`, otherwise the client.
##   godot --headless --path game -- --server

const CLIENT_SCENE: String = "res://scenes/client_main.tscn"
const SERVER_SCENE: String = "res://scenes/server_main.tscn"
const BOT_SCENE: String = "res://scenes/bot_main.tscn"


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var scene: String = CLIENT_SCENE
	var role: String = "client"
	if "--server" in args:
		scene = SERVER_SCENE
		role = "server"
	elif "--bot" in args:
		scene = BOT_SCENE
		role = "bot"
	Log.info("boot: starting %s" % role)
	get_tree().change_scene_to_file.call_deferred(scene)
