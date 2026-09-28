extends Node
## Structured logging to stdout and user://logs/<role>.log.
## Warnings and errors also go through push_warning/push_error, so Godot reports them and
## automated checks (which fail on any warning or error in the logs) catch them.

enum Level { DEBUG, INFO, WARN, ERROR }

var min_level: Level = Level.INFO
var role: String = "client"
var _file: FileAccess


func _ready() -> void:
	if "--server" in OS.get_cmdline_user_args():
		role = "server"
	DirAccess.make_dir_recursive_absolute("user://logs")
	_file = FileAccess.open("user://logs/%s.log" % role, FileAccess.WRITE)


func debug(msg: String) -> void:
	_write(Level.DEBUG, msg)


func info(msg: String) -> void:
	_write(Level.INFO, msg)


func warn(msg: String) -> void:
	_write(Level.WARN, msg)
	push_warning(msg)


func error(msg: String) -> void:
	_write(Level.ERROR, msg)
	push_error(msg)


func _write(level: Level, msg: String) -> void:
	if level < min_level:
		return
	var line: String = "%.3f %s [%s] %s" % [
		Time.get_ticks_msec() / 1000.0, Level.keys()[level], role, msg]
	print(line)
	if _file:
		_file.store_line(line)
		_file.flush()
