class_name RecordingFile
extends RefCounted
## Match recordings (playtest feedback and screenshot playback), written in zstd-compressed chunks.
##
## Godot's compressed FileAccess keeps the whole uncompressed stream in memory until it is closed:
## a client recording every drawn tick grew by about 16 MB a second and a 9-minute match was killed
## for memory. Here each record is buffered with a length prefix and every CHUNK_TICKS records are
## compressed and written as one chunk, so memory stays flat. Reading also accepts the older
## format (one compressed stream of store_var records).
##
## Format: "ARCR", then chunks of [u32 raw size, u32 compressed size, compressed bytes]; the raw
## bytes are records of [u32 size, var_to_bytes(record)].

const MAGIC: String = "ARCR"
const CHUNK_TICKS: int = 120

var _file: FileAccess
var _writing: bool = false
var _legacy: bool = false
var _buf: PackedByteArray = PackedByteArray()
var _count: int = 0
var _chunk: PackedByteArray = PackedByteArray()
var _pos: int = 0


## A new recording at `path`, or null if the file cannot be created.
static func create(path: String) -> RecordingFile:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return null
	f.store_buffer(MAGIC.to_ascii_buffer())
	var r: RecordingFile = RecordingFile.new()
	r._file = f
	r._writing = true
	return r


## An existing recording (either format), or null if it cannot be read.
static func open(path: String) -> RecordingFile:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var r: RecordingFile = RecordingFile.new()
	if f.get_length() >= 4 and f.get_buffer(4).get_string_from_ascii() == MAGIC:
		r._file = f
		return r
	f.close()
	var c: FileAccess = FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if c == null:
		return null
	r._file = c
	r._legacy = true
	return r


func store(record: Variant) -> void:
	var bytes: PackedByteArray = var_to_bytes(record)
	var head: PackedByteArray = PackedByteArray()
	head.resize(4)
	head.encode_u32(0, bytes.size())
	_buf.append_array(head)
	_buf.append_array(bytes)
	_count += 1
	if _count >= CHUNK_TICKS:
		_flush()


func has_next() -> bool:
	if _file == null:
		return false
	if _legacy:
		return _file.get_position() < _file.get_length()
	return _pos < _chunk.size() or _file.get_position() + 8 <= _file.get_length()


func next() -> Variant:
	if _legacy:
		return _file.get_var()
	if _pos >= _chunk.size():
		var raw: int = _file.get_32()
		var size: int = _file.get_32()
		_chunk = _file.get_buffer(size).decompress(raw, FileAccess.COMPRESSION_ZSTD)
		_pos = 0
	var n: int = _chunk.decode_u32(_pos)
	var v: Variant = bytes_to_var(_chunk.slice(_pos + 4, _pos + 4 + n))
	_pos += 4 + n
	return v


func close() -> void:
	if _file == null:
		return
	if _writing:
		_flush()
	_file.close()
	_file = null


func _flush() -> void:
	if _buf.is_empty():
		return
	var packed: PackedByteArray = _buf.compress(FileAccess.COMPRESSION_ZSTD)
	_file.store_32(_buf.size())
	_file.store_32(packed.size())
	_file.store_buffer(packed)
	_buf = PackedByteArray()
	_count = 0
