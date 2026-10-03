extends GdUnitTestSuite
## Match recordings are written in compressed chunks so a long match does not hold the whole
## recording in memory (a 9-minute playtest-style match was killed at 5.5 GB), and older
## single-stream recordings still play back.

const PATH: String = "user://test_recording.bin"


func after_test() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func _tick(i: int) -> Array:
	var units: Array = []
	for u: int in 6:
		units.append({"id": u, "pos": Vector3(i * 0.1, 0, u), "health": 50000 - i, "auras": ["a%d" % (i % 7)]})
	return [{"tick": i, "units": units}, [{"type": "damage", "amount": i}], 0.5, -0.2, 3]


func test_records_round_trip_across_chunks() -> void:
	var w: RecordingFile = RecordingFile.create(PATH)
	w.store({"map": "gallows_courtyard", "bracket": "2v2"})
	var n: int = RecordingFile.CHUNK_TICKS * 3 + 17  # a partial last chunk
	for i: int in n:
		w.store(_tick(i))
	w.close()
	var r: RecordingFile = RecordingFile.open(PATH)
	assert_bool(r.has_next()).is_true()
	assert_str(str((r.next() as Dictionary)["map"])).is_equal("gallows_courtyard")
	var read: int = 0
	while r.has_next():
		var rec: Array = r.next()
		assert_int(int((rec[0] as Dictionary)["tick"])).is_equal(read)
		assert_int(int((rec[1] as Array)[0]["amount"])).is_equal(read)
		read += 1
	assert_int(read).is_equal(n)
	r.close()


func test_memory_stays_flat_while_recording() -> void:
	var w: RecordingFile = RecordingFile.create(PATH)
	var big: Array = []
	for k: int in 3000:
		big.append({"k": k, "v": "unit state %d" % k})
	w.store(big)  # warm up the allocator
	var before: int = OS.get_static_memory_usage()
	for i: int in 600:  # ten seconds of 60 Hz ticks, each about 100 KB before compression
		w.store(big)
	var grown_mb: float = float(OS.get_static_memory_usage() - before) / 1048576.0
	w.close()
	assert_float(grown_mb).override_failure_message("recording grew memory by %.1f MB" % grown_mb).is_less(20.0)


func test_older_single_stream_recordings_still_read() -> void:
	var f: FileAccess = FileAccess.open_compressed(PATH, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	f.store_var({"map": "flooded_crypt"})
	f.store_var(_tick(0))
	f.store_var(_tick(1))
	f.close()
	var r: RecordingFile = RecordingFile.open(PATH)
	assert_str(str((r.next() as Dictionary)["map"])).is_equal("flooded_crypt")
	assert_int(int((r.next() as Array)[0]["tick"])).is_equal(0)
	assert_int(int((r.next() as Array)[0]["tick"])).is_equal(1)
	assert_bool(r.has_next()).is_false()
