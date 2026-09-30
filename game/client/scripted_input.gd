class_name ScriptedInput
extends RefCounted
## Plays a fixed sequence of input actions in simulation time, as InputEventAction events that go
## through the same PlayerController path as real keys (backlog M1-23: headless checks and
## screenshots). Script text: comma-separated steps "action[:seconds]", played one after another;
## an action is held for its seconds (0 or none = a tap), "wait:<s>" holds nothing.
##   "move_forward:3,target_nearest_enemy,turn_left:0.5,wait:1"

var steps: Array[Dictionary] = []  ## {action, start, end, pressed, released}


func _init(text: String = "") -> void:
	var t: float = 0.0
	for part: String in text.split(",", false):
		var bits: PackedStringArray = part.strip_edges().split(":")
		var secs: float = maxf(float(bits[1]), 0.0) if bits.size() > 1 else 0.0
		steps.append({"action": bits[0].strip_edges(), "start": t, "end": t + secs, "pressed": false,
			"released": false})
		t += secs


## Total length of the script in seconds.
func length() -> float:
	return steps[-1]["end"] if not steps.is_empty() else 0.0


## Events due by simulation time `time` that have not been returned yet, in order.
func events_until(time: float) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	for s: Dictionary in steps:
		if not s["pressed"] and time + 1e-6 >= s["start"]:
			s["pressed"] = true
			if s["action"] != "wait":
				out.append(_event(s["action"], true))
		if s["pressed"] and not s["released"] and time + 1e-6 >= s["end"]:
			s["released"] = true
			if s["action"] != "wait":
				out.append(_event(s["action"], false))
	return out


static func _event(action: String, pressed: bool) -> InputEventAction:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	return ev
