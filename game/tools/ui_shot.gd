extends SceneTree
## Screenshot of one menu screen without starting the game flow (talent screen, main menu), for
## checking layouts by eye:
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path game --rendering-driver vulkan \
##     -s res://tools/ui_shot.gd -- --screen talents --spec warblade_carnage --out /abs/shot.png \
##     [--slot 0] [--tab talents|spellbook] [--hover spec:<node id> | card:<ability id>] [--locked]
##
## A script started with -s is compiled before the project's autoloads (Data, Log) exist, so this
## waits one frame and then loads the work (ui_shot_main.gd) as an ordinary node.


func _initialize() -> void:
	await process_frame
	root.add_child(load("res://tools/ui_shot_main.gd").new())
