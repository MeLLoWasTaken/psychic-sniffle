extends Node
## Screenshot capture for automated visual review (backlog M0-04).
## Any scene can be captured:
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path game res://scenes/tests/lit_test.tscn \
##     -- --screenshot /abs/path/out.png --frames 60
## Waits the given number of rendered frames (so lighting, fog and bloom settle), saves the
## viewport to PNG and quits. Does nothing when --screenshot is not passed.
## With --frame-report /abs/out.json it also records every frame after the first 10 (warm-up):
## wall-clock frame time, script process and physics time, draw calls, primitives and memory,
## and writes averages and percentiles next to the screenshot (backlog M1-31: a relative client
## baseline on the software renderer; absolute fps needs a GPU machine).

var _path: String = ""
var _frames_left: int = 60
var _report_path: String = ""
var _samples: Dictionary = {"frame_ms": [], "process_ms": [], "physics_ms": [], "draw_calls": [], "primitives": []}
var _seen: int = 0
var _last_usec: int = 0


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
	var r: int = args.find("--frame-report")
	if r != -1 and r + 1 < args.size():
		_report_path = args[r + 1]
	Log.info("capture: will save %s after %d frames" % [_path, _frames_left])


func _process(_delta: float) -> void:
	_frames_left -= 1
	if _report_path != "":
		_sample()
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
	if _report_path != "":
		_write_report(img.get_size())
	get_tree().quit(0)


func _sample() -> void:
	var now: int = Time.get_ticks_usec()
	_seen += 1
	if _seen > 10 and _last_usec > 0:
		_samples["frame_ms"].append((now - _last_usec) / 1000.0)
		_samples["process_ms"].append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		_samples["physics_ms"].append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		_samples["draw_calls"].append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_samples["primitives"].append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_last_usec = now


static func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {}
	var v: Array = values.duplicate()
	v.sort()
	var total: float = 0.0
	for x: float in v:
		total += x
	return {"avg": total / v.size(), "p50": v[v.size() / 2], "p95": v[mini(v.size() - 1, int(v.size() * 0.95))],
		"max": v[-1], "count": v.size()}


func _write_report(size: Vector2i) -> void:
	var out: Dictionary = {"resolution": [size.x, size.y], "renderer": RenderingServer.get_video_adapter_name(),
		"static_memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT)}
	for k: String in _samples:
		out[k] = _stats(_samples[k])
	var f: FileAccess = FileAccess.open(_report_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	Log.info("capture: frame report %s" % _report_path)
