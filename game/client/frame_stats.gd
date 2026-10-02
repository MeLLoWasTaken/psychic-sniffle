class_name FrameStats
extends CanvasLayer
## Frame-time statistics for playtests on real hardware (backlog P-01, F-02): every rendered frame's
## duration is kept, a small corner readout shows the frame rate when the interface setting
## "Show frame rate" is on, and summary() gives the numbers the match scenes write to the client
## log when a match ends (the graphics adapter, average frame rate, the 1% low, the worst frame).

const WINDOW_S: float = 0.5  ## the readout averages this much time
const MAX_SAMPLES: int = 216000  ## an hour at 60 fps; older frames are dropped

var frame_ms: PackedFloat32Array = PackedFloat32Array()
var label: Label
var _acc_s: float = 0.0
var _acc_n: int = 0


func _init() -> void:
	name = "FrameStats"
	layer = 120
	label = Label.new()
	label.name = "Readout"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.86, 0.84, 0.78))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("outline_size", 4)
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.offset_left = -190.0
	label.offset_right = -10.0
	label.offset_top = 6.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


func _ready() -> void:
	label.visible = bool(Settings.get_value("interface.show_fps", false))
	Settings.bus.changed.connect(_on_setting)


func _process(delta: float) -> void:
	record(delta)


## Count one frame of `delta` seconds and update the readout.
func record(delta: float) -> void:
	if frame_ms.size() >= MAX_SAMPLES:
		frame_ms = frame_ms.slice(MAX_SAMPLES / 2)
	frame_ms.append(delta * 1000.0)
	_acc_s += delta
	_acc_n += 1
	if _acc_s >= WINDOW_S:
		label.text = "%d fps  ·  %.1f ms" % [roundi(_acc_n / _acc_s), _acc_s * 1000.0 / _acc_n]
		_acc_s = 0.0
		_acc_n = 0


## {"frames", "avg_fps", "low1_fps" (the average of the slowest 1% of frames), "worst_ms",
## "adapter", "window"} over the frames counted so far (the first 30 frames, loading, are skipped).
func summary() -> Dictionary:
	var ms: Array = Array(frame_ms).slice(mini(30, frame_ms.size()))
	if ms.is_empty():
		return {"frames": 0}
	var total: float = 0.0
	for m: float in ms:
		total += m
	ms.sort()
	var slow: Array = ms.slice(ms.size() - maxi(1, ms.size() / 100))
	var slow_total: float = 0.0
	for m: float in slow:
		slow_total += m
	return {"frames": ms.size(), "avg_fps": snappedf(1000.0 * ms.size() / total, 0.1),
		"low1_fps": snappedf(1000.0 * slow.size() / slow_total, 0.1), "worst_ms": snappedf(float(ms[-1]), 0.1),
		"adapter": "%s (%s)" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor()],
		"window": "%dx%d" % [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y]}


## One line for the client log.
func log_line() -> String:
	var s: Dictionary = summary()
	if int(s.get("frames", 0)) == 0:
		return "frame stats: no frames"
	return "frame stats: %s, %s, %d frames, average %.1f fps, 1%% low %.1f fps, worst frame %.1f ms" % [
		s["adapter"], s["window"], s["frames"], s["avg_fps"], s["low1_fps"], s["worst_ms"]]


func _on_setting(p: String, v: Variant) -> void:
	if p == "interface.show_fps":
		label.visible = bool(v)
