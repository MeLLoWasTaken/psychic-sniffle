extends GdUnitTestSuite
## Frame statistics for playtests on real hardware (backlog P-01).


func test_average_one_percent_low_and_worst_frame() -> void:
	var fs: FrameStats = auto_free(FrameStats.new())
	for i: int in 30:
		fs.record(0.5)  # loading frames: skipped
	for i: int in 990:
		fs.record(1.0 / 100.0)
	for i: int in 10:
		fs.record(1.0 / 20.0)  # ten 50 ms hitches: the slowest 1%
	var s: Dictionary = fs.summary()
	assert_int(int(s["frames"])).is_equal(1000)
	assert_float(float(s["avg_fps"])).is_equal_approx(1000.0 / (990 * 10.0 + 10 * 50.0) * 1000.0, 0.2)
	assert_float(float(s["low1_fps"])).is_equal_approx(20.0, 0.1)
	assert_float(float(s["worst_ms"])).is_equal_approx(50.0, 0.1)
	assert_str(fs.log_line()).contains("1% low 20.0 fps")
	assert_str(fs.label.text).contains("fps")
	assert_str((auto_free(FrameStats.new()) as FrameStats).log_line()).is_equal("frame stats: no frames")
