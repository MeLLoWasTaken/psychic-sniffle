extends Node
## Replays a recorded input log and compares the final state hash (backlog M1-29).


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var path: String = ""
	for i: int in args.size():
		if args[i] == "--log" and i + 1 < args.size():
			path = args[i + 1]
	var log: InputLog = InputLog.load_file(path)
	if log == null:
		print(JSON.stringify({"ok": false, "error": "cannot read input log %s" % path}))
		get_tree().quit(2)
		return
	var t0: int = Time.get_ticks_msec()
	var result: Dictionary = Replay.run(log)
	result["seconds"] = (Time.get_ticks_msec() - t0) / 1000.0
	print("REPLAY " + JSON.stringify(result))
	get_tree().quit(0 if result.get("ok", false) else 1)
