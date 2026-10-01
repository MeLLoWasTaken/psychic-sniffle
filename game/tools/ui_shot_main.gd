extends Node
## Screenshot of one menu screen without starting the game flow (talent screen, main menu), for
## checking layouts by eye:
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path game --rendering-driver vulkan \
##     -s res://tools/ui_shot.gd -- --screen talents --spec warblade_carnage --out /abs/shot.png \
##     [--slot 0] [--hover spec:<node id>] [--locked]
##
## The work of tools/ui_shot.gd (the launcher waits for the autoloads, then loads this node).


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var out: String = _arg(args, "--out", "")
	var screen: Control
	match _arg(args, "--screen", "talents"):
		"talents":
			var store: TalentLoadouts = TalentLoadouts.new("user://ui_shot_talents.json")
			var ts: TalentScreen = TalentScreen.new(_arg(args, "--spec", "warblade_carnage"), store,
				"--locked" in args)
			ts.select_slot(int(_arg(args, "--slot", "0")))
			ts.show_tab(_arg(args, "--tab", "talents"))
			var hover: PackedStringArray = _arg(args, "--hover", "").split(":")
			if hover.size() == 2:
				ts.hovered = {"card": hover[1]} if hover[0] == "card" else {"layer": hover[0], "id": hover[1], "side": 1}
			screen = ts
		"menu":
			screen = MainMenu.new()
	get_tree().root.add_child(screen)
	screen.size = Vector2(1920, 1080)
	for i: int in 4:
		await get_tree().process_frame
	if out != "":
		get_tree().root.get_texture().get_image().save_png(out)
		print("ui_shot: saved %s" % out)
	get_tree().quit(0)


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
