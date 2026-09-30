class_name LocalServer
extends Node
## Starts a match on this machine for "Play 2v2 vs bots" (backlog M1-28): the authoritative
## server and the bot clients each run as a separate headless Godot process, exactly as a
## dedicated server and remote players would (tools/sim/run_match.py does the same), and the
## game client joins over ENet on localhost like any other player.
##
##   var ls: LocalServer = LocalServer.new()
##   add_child(ls)
##   ls.ready_to_connect.connect(func(port: int) -> void: net.connect_to_server("127.0.0.1", port))
##   ls.start("gallows_courtyard", "2v2", "player", bots)   # bots: [{name, spec, team}]
##   ...
##   ls.stop()   # also on leaving the tree: no process outlives the scene that started it
##
## The server gets the roster (who may join, on which team), holds preparation until all have
## joined, and exits when the host (this client) leaves or goes silent; bots exit when the match
## ends or the server goes away. stop() waits briefly for all of them to exit by themselves and
## kills whatever is left, then reaps them (no zombie or orphan processes).

signal ready_to_connect(port: int)
signal failed(reason: String)
## The server process exited after it was running (normal a few seconds after the match ends;
## a failure before that: the match scene decides).
signal server_exited()

enum Phase { IDLE, STARTING, RUNNING, STOPPED, FAILED }

const STOP_GRACE_S: float = 2.0

var phase: Phase = Phase.IDLE
var port: int = 0
var server_pid: int = -1
var bot_pids: Array[int] = []
var session_dir: String = ""  ## absolute folder for the server's ready file and summary
var summary_path: String = ""
var start_timeout_s: float = 30.0
var extra_server_args: PackedStringArray = []
var input_log_path: String = ""  ## the match's input log, written by the server when it finishes
var _bots: Array = []
var _ready_file: String = ""
var _started_usec: int = 0
var _server_gone: bool = false
var _ended: Dictionary = {}  ## pids known to have ended (never queried again: Godot errors on reaped pids)


## Start the server now; the bots start (and ready_to_connect fires) once it listens.
## `bots` = [{name, spec, team}], `host_name` joins on team 0. `prep_s` < 0 uses the tuning.
func start(map_id: String, bracket: String, host_name: String, bots: Array, prep_s: float = -1.0,
		port_range: Array = [24700, 24799], seed_value: int = 0) -> Error:
	if phase != Phase.IDLE:
		return ERR_ALREADY_IN_USE
	port = find_free_port(int(port_range[0]), int(port_range[1]))
	if port == 0:
		_fail("no free port in %d-%d" % [port_range[0], port_range[1]])
		return ERR_CANT_CREATE
	session_dir = ProjectSettings.globalize_path("user://sessions/%d" % port)
	DirAccess.make_dir_recursive_absolute(session_dir)
	_ready_file = session_dir.path_join("ready")
	summary_path = session_dir.path_join("summary.json")
	input_log_path = session_dir.path_join("match.inputlog")  # every match records its inputs (M1-29)
	for f: String in [_ready_file, summary_path, input_log_path]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
	_bots = bots
	var roster: PackedStringArray = ["%s:0" % host_name]
	for b: Dictionary in bots:
		roster.append("%s:%d" % [b["name"], int(b["team"])])
	var args: PackedStringArray = ["--server", "--mode", "arena", "--bracket", bracket, "--map", map_id,
		"--port", str(port), "--roster", ",".join(roster), "--host", host_name,
		"--ready-file", _ready_file, "--summary", summary_path, "--input-log", input_log_path,
		"--seed", str(seed_value if seed_value > 0 else randi_range(1, 1_000_000))]
	if prep_s >= 0.0:
		args.append_array(["--prep-seconds", str(prep_s)])
	args.append_array(extra_server_args)
	server_pid = _spawn(args)
	if server_pid <= 0:
		_fail("could not start the server process")
		return ERR_CANT_CREATE
	Log.info("local server: started server pid %d on port %d" % [server_pid, port])
	phase = Phase.STARTING
	_started_usec = Time.get_ticks_usec()
	return OK


func _process(_delta: float) -> void:
	match phase:
		Phase.STARTING:
			if FileAccess.file_exists(_ready_file):
				_start_bots()
				phase = Phase.RUNNING
				ready_to_connect.emit(port)
			elif not is_running(server_pid):
				server_pid = -1
				_fail("the server exited while starting")
			elif (Time.get_ticks_usec() - _started_usec) / 1e6 > start_timeout_s:
				_fail("the server did not start within %.0f s" % start_timeout_s)
		Phase.RUNNING:
			if not _server_gone and not server_running():
				_server_gone = true
				Log.info("local server: the server process exited")
				server_exited.emit()


func _start_bots() -> void:
	for b: Dictionary in _bots:
		var pid: int = _spawn(["--bot", "--name", str(b["name"]), "--spec", str(b["spec"]), "--port", str(port),
			"--server-silence", "10"])
		if pid > 0:
			bot_pids.append(pid)
			Log.info("local server: started bot %s (%s) pid %d" % [b["name"], b["spec"], pid])
		else:
			Log.error("local server: could not start bot %s" % b["name"])


## True while a process this launcher started is running. Once it has ended (exited by itself
## and reaped, or killed here) it is remembered and not asked about again.
func is_running(pid: int) -> bool:
	if pid <= 0 or _ended.has(pid):
		return false
	if OS.is_process_running(pid):
		return true
	_ended[pid] = true
	return false


func _kill(pid: int) -> void:
	OS.kill(pid)  # also reaps it
	_ended[pid] = true


## The server's end-of-match summary (NetServer._finish), or {} before it has written one.
func summary() -> Dictionary:
	if summary_path == "" or not FileAccess.file_exists(summary_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(summary_path))
	return parsed if parsed is Dictionary else {}


## True while the server process is alive.
func server_running() -> bool:
	return server_pid > 0 and is_running(server_pid)


## Process ids started by this launcher that are still running.
func running_pids() -> Array[int]:
	var out: Array[int] = []
	for pid: int in all_pids():
		if is_running(pid):
			out.append(pid)
	return out


## Every process id this launcher started (running or not).
func all_pids() -> Array[int]:
	var out: Array[int] = []
	if server_pid > 0:
		out.append(server_pid)
	out.append_array(bot_pids)
	return out


## Stop everything: give the processes `grace_s` to exit on their own (the server finishes when
## its host leaves, bots when the server goes), then kill the rest and reap them. Blocks at most
## about grace_s + 1 s. Safe to call more than once.
func stop(grace_s: float = STOP_GRACE_S) -> void:
	if phase == Phase.IDLE or phase == Phase.STOPPED:
		phase = Phase.STOPPED
		return
	var deadline: int = Time.get_ticks_msec() + int(grace_s * 1000.0)
	while not running_pids().is_empty() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(50)
	var killed: Array[int] = running_pids()
	for pid: int in killed:
		_kill(pid)
	var reap_deadline: int = Time.get_ticks_msec() + 1000
	while not running_pids().is_empty() and Time.get_ticks_msec() < reap_deadline:
		OS.delay_msec(20)
	if not killed.is_empty():
		Log.info("local server: killed %d process(es) that had not exited: %s" % [killed.size(), killed])
	var left: Array[int] = running_pids()
	if not left.is_empty():
		Log.error("local server: processes still running after stop: %s" % [left])
	phase = Phase.STOPPED


func _exit_tree() -> void:
	stop(0.5)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and phase in [Phase.STARTING, Phase.RUNNING]:
		stop(0.0)


func _fail(reason: String) -> void:
	Log.warn("local server: %s" % reason)
	phase = Phase.FAILED
	for pid: int in running_pids():
		_kill(pid)
	failed.emit(reason)


## Launch this same Godot binary headless on this project with `user_args` after `--`.
func _spawn(user_args: PackedStringArray) -> int:
	var args: PackedStringArray = ["--headless"]
	if not OS.has_feature("template"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append("--")
	args.append_array(user_args)
	return OS.create_process(OS.get_executable_path(), args)


## The first port in [lo, hi] a UDP socket can bind on localhost, or 0. (A plain UDP probe:
## a failed ENet bind would log an engine error.)
static func find_free_port(lo: int, hi: int) -> int:
	for p: int in range(lo, hi + 1):
		var probe: PacketPeerUDP = PacketPeerUDP.new()
		if probe.bind(p, "127.0.0.1") == OK:
			probe.close()
			return p
	return 0
