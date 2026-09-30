class_name InputLog
extends RefCounted
## Everything that changes a match from outside the simulation (backlog M1-29): every applied
## input and every world edit (a unit joining or leaving, the preparation hold, a respawn), each
## with the tick it happened on and whether it happened during that tick's step or before it.
## Together with the header (map, mode, bracket, seed, preparation length) this is enough to
## rebuild the match exactly: Replay.run(log) must reach the recorded final state hash.
##
## Saved with FileAccess.store_var (Godot's binary format), which keeps floats and vectors exact;
## JSON would round them and the replay would drift.

const VERSION: int = 1

var header: Dictionary = {}
## [tick, during_step, kind, payload]; kind: "in" [unit_id, input], "add" [spec, team],
## "hold" null, "leave" unit_id, "respawn" [unit_id, position]
var entries: Array = []
var final_tick: int = -1
var final_hash: String = ""


func add(tick: int, during_step: bool, kind: String, payload: Variant) -> void:
	entries.append([tick, during_step, kind, payload])


func finish(sim: Sim) -> void:
	final_tick = sim.tick
	final_hash = sim.state_hash()


func to_dict() -> Dictionary:
	return {"version": VERSION, "header": header, "entries": entries, "final_tick": final_tick,
		"final_hash": final_hash}


func save(path: String) -> Error:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(to_dict())
	f.close()
	return OK


static func load_file(path: String) -> InputLog:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var d: Variant = f.get_var()
	f.close()
	if not (d is Dictionary) or int((d as Dictionary).get("version", 0)) != VERSION:
		return null
	var log: InputLog = InputLog.new()
	log.header = d["header"]
	log.entries = d["entries"]
	log.final_tick = int(d["final_tick"])
	log.final_hash = str(d["final_hash"])
	return log
