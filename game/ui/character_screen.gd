class_name CharacterScreen
extends Control
## The character creator (backlog G-06; docs/DESIGN.md "Appearance and armor customization"):
## a turntable preview of the assembled character beside tabs of choices, each a row stepped with
## "<" and ">" (mouse or keyboard): Body (type, height, skin), Face (preset, eyes, scars and paint),
## Hair (style, colour, beard), Armor (one piece per slot from the class's armor type, or none
## where allowed) and Dyes (primary, secondary and metal colour per worn piece). Randomize, Reset,
## Save (per spec, Appearance.save) and Back. All options come from data/appearance and
## data/armor_sets; the screen only steps through them.
##
## Positions are logical pixels on the 1920x1080 canvas, like the main menu.

signal closed(spec_id: String)

const TABS: Array[String] = ["body", "face", "hair", "armor", "dyes"]
const PREVIEW_RECT: Rect2 = Rect2(80, 110, 820, 880)
const PANEL_RECT: Rect2 = Rect2(960, 110, 880, 880)

var style: MenuStyle
var spec_id: String
var look: Dictionary
var tab: String = "body"
var dye_slot: String = "chest"
var status: String = ""
var tab_buttons: Dictionary = {}
var buttons: Dictionary = {}
var rows_box: VBoxContainer
var row_values: Dictionary = {}  ## row key -> Label showing the current value
var viewport: SubViewport
var pivot: Node3D
var model: Node3D
var spin: float = 0.0
var auto_spin: bool = true


func _init(p_spec_id: String, menu_id: String = "main") -> void:
	style = MenuStyle.new(menu_id)
	spec_id = p_spec_id
	look = Appearance.load_saved(spec_id)
	name = "CharacterScreen"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_preview()
	_build_controls()
	show_tab("body")
	_rebuild_model()


# ------------------------------------------------------------------ choices (also used by tests)

## The rows of a tab: [key, label, options (Array of ids or values), current value].
func rows(t: String = tab) -> Array:
	var body: String = str(look["body"])
	match t:
		"body":
			var heights: Array = []
			for i: int in 9:
				heights.append(snappedf(Appearance.HEIGHT_MIN + 0.01 * i, 0.001))
			return [["body", style.text("creator_body"), Appearance.BODY_TYPES, look["body"]],
				["height", style.text("creator_height"), heights, snappedf(float(look["height"]), 0.001)],
				["skin", style.text("creator_skin"), Appearance.option_ids("skin_tones"), look["skin"]]]
		"face":
			return [["face", style.text("creator_face"), Appearance.option_ids("faces"), look["face"]],
				["eyes", style.text("creator_eyes"), Appearance.option_ids("eye_colors"), look["eyes"]],
				["marking", style.text("creator_marking"), Appearance.option_ids("markings"), look["marking"]],
				["paint", style.text("creator_paint"), Appearance.option_ids("dye_colors").map(func(id: String) -> String:
					return str(Appearance.option("dye_colors", id).get("color", "#2b3a52"))), look["paint"]]]
		"hair":
			var r: Array = [["hair", style.text("creator_hair"), Appearance.option_ids("hair", body), look["hair"]],
				["hair_color", style.text("creator_hair_color"), Appearance.option_ids("hair_colors"), look["hair_color"]]]
			if body == "male":
				r.append(["beard", style.text("creator_beard"), Appearance.option_ids("beards", "male"), look["beard"]])
			return r
		"armor":
			var out: Array = []
			for slot: String in Appearance.SLOTS:
				out.append(["piece:" + slot, style.text("slot_" + slot), piece_options(slot), look["pieces"][slot]])
			return out
		"dyes":
			var worn: Array = Appearance.SLOTS.filter(func(s: String) -> bool: return str(look["pieces"][s]) != "")
			var colours: Array = Appearance.option_ids("dye_colors").map(func(id: String) -> String:
				return str(Appearance.option("dye_colors", id).get("color", "#ffffff")))
			var out: Array = [["dye_slot", style.text("creator_dye_piece"), worn, dye_slot]]
			for ch: String in Appearance.DYE_CHANNELS:
				out.append(["dye:" + ch, style.text("dye_" + ch), colours, look["dyes"][dye_slot][ch]])
			return out
	return []


## The pieces a slot can show: every set of the class's armor type with that slot, and "" (none)
## where the slot may be hidden.
func piece_options(slot: String) -> Array:
	var kind: String = Appearance.armor_type(spec_id)
	var out: Array = [] if slot in Appearance.REQUIRED_SLOTS else [""]
	var ids: Array = Data.armor_sets.keys()
	ids.sort()
	for sid: String in ids:
		var s: Dictionary = Data.armor_sets[sid]
		if str(s.get("armor_type", "")) == kind and s.get("pieces", {}).has(slot):
			out.append("%s:%s" % [sid, slot])
	return out


## Step a row's value by `delta` (wrapping); returns the new value.
func step(key: String, delta: int) -> Variant:
	var row: Array = []
	for r: Array in rows():
		if r[0] == key:
			row = r
	if row.is_empty() or (row[2] as Array).is_empty():
		return null
	var opts: Array = row[2]
	var i: int = opts.find(row[3])
	var v: Variant = opts[posmod((i if i >= 0 else 0) + delta, opts.size())]
	_apply(key, v)
	return v


func _apply(key: String, v: Variant) -> void:
	if key.begins_with("piece:"):
		look["pieces"][key.trim_prefix("piece:")] = v
	elif key.begins_with("dye:"):
		look["dyes"][dye_slot][key.trim_prefix("dye:")] = v
	elif key == "dye_slot":
		dye_slot = str(v)
	else:
		look[key] = v
	look = Appearance.sanitize(look, spec_id)   # e.g. a female body drops the beard
	if not look["pieces"].has(dye_slot) or str(look["pieces"][dye_slot]) == "":
		dye_slot = "chest"
	status = ""
	_refresh_rows()
	if key != "dye_slot":
		_rebuild_model()


func randomize_look(seed_value: int = -1) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	if seed_value >= 0:
		rng.seed = seed_value
	else:
		rng.randomize()
	var keep_pieces: Dictionary = look["pieces"].duplicate()
	var keep_dyes: Dictionary = look["dyes"].duplicate(true)
	look = Appearance.random_for(spec_id, rng)
	look["pieces"] = keep_pieces   # randomize the person, not the armor
	look["dyes"] = keep_dyes
	look = Appearance.sanitize(look, spec_id)
	_refresh_rows()
	_rebuild_model()


func reset() -> void:
	look = Appearance.default_for(spec_id)
	dye_slot = "chest"
	_refresh_rows()
	_rebuild_model()


func save() -> void:
	Appearance.save(spec_id, look)
	status = style.text("creator_saved")
	queue_redraw()


func close() -> void:
	closed.emit(spec_id)


# ------------------------------------------------------------------ controls

func _build_controls() -> void:
	for t: String in TABS:
		var b: Button = style.button(style.text("creator_tab_" + t), Vector2(160, 46), 20)
		b.name = "Tab_%s" % t
		b.toggle_mode = true
		b.pressed.connect(show_tab.bind(t))
		add_child(b)
		tab_buttons[t] = b
	rows_box = VBoxContainer.new()
	rows_box.name = "Rows"
	rows_box.add_theme_constant_override("separation", 12)
	add_child(rows_box)
	for spec: Array in [["random", "creator_random", randomize_look.bind(-1)], ["reset", "creator_reset", reset],
			["save", "creator_save", save], ["back", "creator_back", close]]:
		var b: Button = style.button(style.text(spec[1]), Vector2(200, 50), 21)
		b.name = "Button_%s" % spec[0]
		b.pressed.connect(spec[2])
		add_child(b)
		buttons[spec[0]] = b
	resized.connect(_layout)


func show_tab(t: String) -> void:
	tab = t
	for k: String in tab_buttons:
		(tab_buttons[k] as Button).button_pressed = k == t
	_refresh_rows()


func _refresh_rows() -> void:
	for c: Node in rows_box.get_children():
		# left in the tree until freed (a row's own button may be the one being pressed)
		(c as Control).visible = false
		c.queue_free()
	row_values.clear()
	for r: Array in rows():
		var h: HBoxContainer = HBoxContainer.new()
		h.name = "Row_%s" % str(r[0]).replace(":", "_")
		h.add_theme_constant_override("separation", 10)
		var label: Label = _label(str(r[1]), 22, style.color("text_dim"))
		label.custom_minimum_size = Vector2(270, 50)
		h.add_child(label)
		var prev: Button = style.button("<", Vector2(56, 50), 24)
		prev.name = "Prev"
		prev.pressed.connect(func() -> void: step(str(r[0]), -1))
		h.add_child(prev)
		var value: Label = _label(_value_text(str(r[0]), r[3]), 22, style.color("text"))
		value.custom_minimum_size = Vector2(380, 50)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		h.add_child(value)
		var next: Button = style.button(">", Vector2(56, 50), 24)
		next.name = "Next"
		next.pressed.connect(func() -> void: step(str(r[0]), 1))
		h.add_child(next)
		rows_box.add_child(h)
		row_values[r[0]] = value
	queue_redraw()


func _value_text(key: String, v: Variant) -> String:
	match key:
		"body":
			return style.text("body_" + str(v))
		"height":
			return "%d%%" % roundi(float(v) * 100.0)
		"skin":
			return str(Appearance.option("skin_tones", str(v)).get("name", v))
		"face":
			return str(Appearance.option("faces", str(v)).get("name", v))
		"eyes":
			return str(Appearance.option("eye_colors", str(v)).get("name", v))
		"marking":
			return str(Appearance.option("markings", str(v)).get("name", v))
		"hair":
			return str(Appearance.option("hair", str(v)).get("name", v))
		"hair_color":
			return str(Appearance.option("hair_colors", str(v)).get("name", v))
		"beard":
			return str(Appearance.option("beards", str(v)).get("name", v))
		"dye_slot":
			return style.text("slot_" + str(v))
	if key.begins_with("piece:"):
		var p: String = str(v)
		if p == "":
			return style.text("creator_none")
		var parts: PackedStringArray = p.split(":")
		return str(Data.armor_sets.get(parts[0], {}).get("pieces", {}).get(parts[1], {}).get("name", p))
	if key.begins_with("dye:") or key == "paint":
		return _colour_name(str(v))
	return str(v)


func _colour_name(hex: String) -> String:
	for o: Dictionary in Data.appearance.get("dye_colors", {}).get("options", []):
		if str(o.get("color", "")).to_lower() == hex.to_lower():
			return str(o["name"])
	return hex


func _label(text: String, size: int, col: Color) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_override("font", style.font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _layout() -> void:
	var x: float = PANEL_RECT.position.x + 20
	for i: int in TABS.size():
		var b: Button = tab_buttons[TABS[i]]
		b.position = Vector2(x + i * 170, PANEL_RECT.position.y + 20)
	rows_box.position = Vector2(PANEL_RECT.position.x + 20, PANEL_RECT.position.y + 100)
	rows_box.size = Vector2(PANEL_RECT.size.x - 40, PANEL_RECT.size.y - 220)
	var keys: Array = ["random", "reset", "save", "back"]
	for i: int in keys.size():
		(buttons[keys[i]] as Button).position = Vector2(PANEL_RECT.position.x + 20 + i * 215, PANEL_RECT.end.y - 70)
	var container: Control = get_node_or_null("Preview") as Control
	if container:
		container.position = PREVIEW_RECT.position
		container.size = PREVIEW_RECT.size


func _ready() -> void:
	_layout()
	(tab_buttons["body"] as Button).grab_focus.call_deferred()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), style.color("background_bottom"))
	style.draw_text(self, Vector2(80, 80), style.text("creator_title", {"spec": str(Data.specs.get(spec_id, {}).get("name", spec_id))}),
		40, style.color("title"), HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	style.draw_panel(self, PANEL_RECT)
	style.draw_panel(self, PREVIEW_RECT)
	if Appearance.default_set(spec_id) == "":
		style.draw_text(self, Vector2(PREVIEW_RECT.position.x + 20, PREVIEW_RECT.end.y - 24), style.text("creator_no_set"), 19,
			style.color("text_dim"))
	if status != "":
		style.draw_text(self, Vector2(PANEL_RECT.position.x + 20, PANEL_RECT.end.y - 90), status, 20, style.color("accent"))


# ------------------------------------------------------------------ preview

func _build_preview() -> void:
	var container: SubViewportContainer = SubViewportContainer.new()
	container.name = "Preview"
	container.stretch = true
	container.position = PREVIEW_RECT.position
	container.size = PREVIEW_RECT.size
	add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(PREVIEW_RECT.size)
	viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(viewport)
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.085, 0.1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.52, 0.58)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	viewport.add_child(we)
	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 30, 0)
	key.light_energy = 1.5
	key.shadow_enabled = true
	viewport.add_child(key)
	var rim: DirectionalLight3D = DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-20, 200, 0)
	rim.light_energy = 0.9
	rim.light_color = Color(0.75, 0.82, 1.0)
	viewport.add_child(rim)
	var floor_mi: MeshInstance3D = MeshInstance3D.new()
	var disc: CylinderMesh = CylinderMesh.new()
	disc.top_radius = 1.1
	disc.bottom_radius = 1.1
	disc.height = 0.04
	floor_mi.mesh = disc
	var fm: StandardMaterial3D = StandardMaterial3D.new()
	fm.albedo_color = Color(0.17, 0.155, 0.14)
	floor_mi.material_override = fm
	floor_mi.position.y = -0.02
	viewport.add_child(floor_mi)
	pivot = Node3D.new()
	viewport.add_child(pivot)
	var cam: Camera3D = Camera3D.new()
	cam.fov = 30.0
	cam.position = Vector3(0, 1.2, 4.6)
	cam.look_at_from_position(cam.position, Vector3(0, 1.0, 0), Vector3.UP)
	viewport.add_child(cam)
	cam.current = true


func _rebuild_model() -> void:
	if model != null:
		model.queue_free()
		model = null
	model = CharacterAssembler.build(look, spec_id)
	if model == null:
		return
	pivot.add_child(model)
	var player: AnimationPlayer = CharacterRig.setup(CharacterAssembler.rig_asset(look, spec_id), model)
	if player != null and player.has_animation("idle"):
		player.play("idle")


func _process(delta: float) -> void:
	if auto_spin:
		spin += delta * 0.35
	pivot.rotation.y = spin


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 \
			and PREVIEW_RECT.has_point(event.position):
		auto_spin = false
		spin += event.relative.x * 0.01


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
