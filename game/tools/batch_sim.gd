extends SceneTree
## Launcher for the batch arena simulator (the work is in batch_sim_main.gd).
## A script started with -s is compiled before the project's autoloads (Data, Log) exist, so
## this waits one frame and then loads the simulator as an ordinary node.
##
##   godot --headless --path game -s res://tools/batch_sim.gd -- --matches 100 \
##     --comp warblade_carnage+oracle_grace:arcanist_rime+oracle_grace --out /abs/report.json


func _initialize() -> void:
	await process_frame
	root.add_child(load("res://tools/batch_sim_main.gd").new())
