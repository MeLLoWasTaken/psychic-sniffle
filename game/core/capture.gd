extends Node
## Screenshot capture for automated visual review (backlog M0-04).
## Any scene can be captured:
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path game res://scenes/tests/lit_test.tscn \
##     -- --screenshot /abs/path/out.png --frames 60
## Waits the given number of rendered frames (so lighting, fog and bloom settle), saves the
## viewport to PNG and quits. Does nothing when --screenshot is not passed.

var _path: String = ""
var _frames_left: int = 60


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = args.find("--screenshot")
	if i == -1 or i + 1 >= args.size():
		set_process(false)
		return
	_path = args[i + 1]
	var f: int = args.find("--frames")
	if f != -1 and f + 1 < args.size():
		_frames_left = int(args[f + 1])
	Log.info("capture: will save %s after %d frames" % [_path, _frames_left])


func _process(_delta: float) -> void:
	_frames_left -= 1
	if _frames_left > 0:
		return
	set_process(false)
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var err: Error = img.save_png(_path)
	if err != OK:
		Log.error("capture: could not save %s (error %d)" % [_path, err])
		get_tree().quit(1)
		return
	Log.info("capture: saved %s (%dx%d)" % [_path, img.get_width(), img.get_height()])
	get_tree().quit(0)
