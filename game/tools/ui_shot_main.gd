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
		"hudedit":
			var bg: ColorRect = ColorRect.new()
			bg.color = Color(0.16, 0.15, 0.14)
			bg.size = Vector2(1920, 1080)
			get_tree().root.add_child(bg)
			var hud: Hud = Hud.new(Data.settings["default"])
			get_tree().root.add_child(hud)
			var m: LocalMatch = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"], ["arcanist_rime", "oracle_grace"])
			hud.push(m.view())
			hud.update(0.0)
			hud.toggle_edit_mode()
			hud.editor.selected = "player_frame"
			hud.editor._refresh()
			screen = Control.new()
		"settings":
			Settings.use_data()
			var ss: SettingsScreen = SettingsScreen.new()
			ss.show_page(_arg(args, "--tab", "interface"))
			screen = ss
		"pause":
			var bg: ColorRect = ColorRect.new()
			bg.color = Color(0.16, 0.15, 0.14)
			bg.size = Vector2(1920, 1080)
			get_tree().root.add_child(bg)
			var pm: PauseMenu = PauseMenu.new(MenuStyle.new("main"), "Leave match", "Leaving ends the match for everyone.")
			pm.set_spec("warblade_carnage", func() -> bool: return false)
			pm.set_status(MenuStyle.new("main").text("talents_changed"))
			pm.position = (Vector2(1920, 1080) - pm.size) * 0.5
			get_tree().root.add_child(pm)
			screen = Control.new()
			screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
		"nameplates":
			screen = _nameplate_scene()
		"keybinds":
			var ks: KeybindScreen = KeybindScreen.new("default", "user://ui_shot_keybinds.json")
			Keybinds.rebind(ks.profile, "bar1_slot2", "KEY_1", [])  # show a conflict
			Keybinds.set_target_mode(ks.profile, "bar1_slot4", "focus")
			ks.refresh()
			screen = ks
	get_tree().root.add_child(screen)
	screen.size = Vector2(1920, 1080)
	for i: int in 4:
		await get_tree().process_frame
	if out != "":
		get_tree().root.get_texture().get_image().save_png(out)
		print("ui_shot: saved %s" % out)
	get_tree().quit(0)


## Six stand-in figures in a lit room with the HUD over them: nameplates with a cast, crowd
## control, a defensive, the player's own debuff and a marked target (M2-14).
func _nameplate_scene() -> Control:
	var root: Node3D = Node3D.new()
	get_tree().root.add_child(root)
	var env: WorldEnvironment = WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.2, 0.19, 0.18)
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	root.add_child(env)
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var ground: MeshInstance3D = MeshInstance3D.new()
	var pm: PlaneMesh = PlaneMesh.new()
	pm.size = Vector2(60, 60)
	ground.mesh = pm
	root.add_child(ground)
	var cam: Camera3D = Camera3D.new()
	cam.position = Vector3(0, 4.5, 15)
	root.add_child(cam)
	cam.look_at(Vector3(0, 1.5, 0))
	cam.current = true
	var m: LocalMatch = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["arcanist_rime", "oracle_grace"],
		["warblade_carnage", "arcanist_rime", "oracle_grace"], "3v3")
	var v: Dictionary = m.view().duplicate(true)
	var me: int = int(v["me"]["id"])
	var tick: int = int(v["tick"])
	var spots: Dictionary = {}
	var places: Array = [Vector3(-7, 0, 2), Vector3(-3.5, 0, -2), Vector3(0.5, 0, -4), Vector3(1.2, 0, -4.6), Vector3(5, 0, -1), Vector3(8, 0, 3)]
	var k: int = 0
	var enemies: Array = []
	for u: Dictionary in v["units"]:
		if int(u["id"]) == me:
			spots[me] = Vector3(0, 0, 9)
			continue
		spots[int(u["id"])] = places[k]
		k += 1
		if int(u["team"]) != int(v["me"]["team"]):
			enemies.append(u)
		var body: MeshInstance3D = MeshInstance3D.new()
		var cm: CapsuleMesh = CapsuleMesh.new()
		cm.radius = 0.45
		cm.height = 1.9
		body.mesh = cm
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = HudStyle.class_color(str(u["spec"]))
		body.material_override = mat
		body.position = spots[int(u["id"])] + Vector3(0, 0.95, 0)
		root.add_child(body)
	enemies[0]["cast"] = {"ability": "rime_bolt", "target": me, "start_tick": tick - 40, "end_tick": tick + 68, "channel": false}
	enemies[0]["health"] = int(float(enemies[0]["max_health"]) * 0.55)
	enemies[0]["auras"] = [{"id": "pommel_cracked", "source": me, "applied_tick": tick, "expires_tick": tick + 150, "stacks": 1}]
	enemies[1]["auras"] = [{"id": "glacier_shield", "source": int(enemies[1]["id"]), "applied_tick": tick, "expires_tick": tick + 420, "stacks": 1}]
	enemies[2]["health"] = int(float(enemies[2]["max_health"]) * 0.3)
	var ctl: PlayerController = PlayerController.new(Data.settings["default"])
	ctl.set_target(int(enemies[0]["id"]))
	var hud: Hud = Hud.new(Data.settings["default"])
	get_tree().root.add_child(hud)
	hud.bind(ctl, cam)
	(hud.elements["nameplates"] as Nameplates).position_of = func(id: int) -> Vector3: return spots.get(id, Vector3(INF, INF, INF))
	hud.push(v)
	hud.update(0.0)
	var c: Control = Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
