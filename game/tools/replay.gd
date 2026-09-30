extends SceneTree
## Launcher for the replay check (the work is in replay_main.gd; see batch_sim.gd for why).
##
##   godot --headless --path game -s res://tools/replay.gd -- --log /abs/match.inputlog
## Prints the result as JSON; exits 0 when the replay reaches the recorded final state hash.


func _initialize() -> void:
	await process_frame
	root.add_child(load("res://tools/replay_main.gd").new())
