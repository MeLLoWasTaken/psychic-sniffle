class_name TalentScreen
extends Control
## The talent screen (docs/DESIGN.md "Talent trees", backlog M2-05), drawn entirely from the talent
## data: the class tree, the spec tree and the PvP row, with node positions, connecting lines, gate
## lines, icons, ranks, point counters and tooltips. Left click adds a rank (on a choice node, the
## half clicked picks the option), right click removes one; a change that would break the
## loadout's rules (Talents.check) is refused with the reason. Loadouts: up to 10 per spec,
## selected on the right; Save, New, Delete, Export (copies the text) and Import (pastes it).
## In a match the screen is read-only (`locked`).
##
## Positions are logical pixels on the 1920x1080 canvas, like the main menu.

signal closed(spec_id: String, talents: String)

const NODE_PX: float = 52.0
const CHOICE_PX: float = 34.0
const COL_PX: float = 92.0
const ROW_PX: float = 74.0
const TREES_Y: float = 196.0
const CLASS_X: float = 70.0
const SPEC_X: float = 790.0
const PVP_RECT: Rect2 = Rect2(1520, 150, 340, 420)
const SLOTS_Y: float = 640.0

var style: MenuStyle
var hud: HudStyle
var spec_id: String
var trees: Dictionary
var loadouts: TalentLoadouts
var loadout: Dictionary = Talents.empty()
var slot: int = 0
var locked: bool = false
var message: String = ""  ## last refusal or status line
var hovered: Dictionary = {}  ## {"layer", "id", "side"} under the mouse
var name_edit: LineEdit
var code_edit: LineEdit
var buttons: Dictionary = {}
var slot_buttons: Array[Button] = []


func _init(p_spec_id: String, p_loadouts: TalentLoadouts = null, p_locked: bool = false, menu_id: String = "main") -> void:
	style = MenuStyle.new(menu_id)
	hud = HudStyle.new(Data.hud_layouts.get("default", {}))
	spec_id = p_spec_id
	trees = Talents.trees_for(spec_id, Data.specs, Data.classes, Data.talents)
	loadouts = p_loadouts if p_loadouts != null else TalentLoadouts.new()
	locked = p_locked
	name = "TalentScreen"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_controls()
	select_slot(loadouts.active_index(spec_id))


# ------------------------------------------------------------------ the rules (also used by tests)

func spent(layer: String) -> int:
	if layer == "pvp":
		return loadout["pvp"].size()
	return Talents.spent(trees[layer], loadout[layer])


func points(layer: String) -> int:
	return int(trees.get(layer, {}).get("points", 0))


func rank_of(layer: String, node_id: String) -> int:
	if layer == "pvp":
		return 1 if node_id in loadout["pvp"] else 0
	return int(loadout[layer].get(node_id, 0))


## What a change would do: "" when allowed, else why not.
func _try(change: Callable) -> String:
	if locked:
		return style.text("talents_locked")
	var next: Dictionary = loadout.duplicate(true)
	change.call(next)
	var err: String = Talents.check(next, trees)
	if err == "":
		loadout = next
		message = ""
		queue_redraw()
	return err


## Add a rank (or pick option `side` of a choice node, or take a PvP talent).
func add(layer: String, node_id: String, side: int = 1) -> String:
	var n: Dictionary = Talents.node_of(trees.get(layer, {}), node_id)
	if n.is_empty():
		return "no node"
	var err: String = _try(func(lo: Dictionary) -> void:
		if layer == "pvp":
			if not node_id in lo["pvp"]:
				lo["pvp"].append(node_id)
		elif n["type"] == "choice":
			lo[layer][node_id] = side
		else:
			lo[layer][node_id] = int(lo[layer].get(node_id, 0)) + 1)
	if err != "":
		message = _explain(layer, n, err, true)
		queue_redraw()
	return err


## Remove a rank (or the choice, or the PvP talent).
func remove(layer: String, node_id: String) -> String:
	if rank_of(layer, node_id) == 0:
		return "not taken"
	var n: Dictionary = Talents.node_of(trees.get(layer, {}), node_id)
	var err: String = _try(func(lo: Dictionary) -> void:
		if layer == "pvp":
			lo["pvp"].erase(node_id)
		else:
			var r: int = int(lo[layer][node_id]) - 1
			if r <= 0 or n["type"] == "choice":
				lo[layer].erase(node_id)
			else:
				lo[layer][node_id] = r)
	if err != "":
		message = _explain(layer, n, err, false)
		queue_redraw()
	return err


func _explain(layer: String, n: Dictionary, err: String, adding: bool) -> String:
	if locked:
		return style.text("talents_locked")
	if not adding:
		return style.text("talents_needed_by_others", {"name": n["name"]})
	if "points spent" in err or "slots" in err:
		return style.text("talents_no_points")
	if "ranks" in err:
		return style.text("talents_maxed", {"name": n["name"]})
	if "locked" in err:
		var gate: int = int(n.get("gate", 0))
		if gate > 0 and not _gate_open(layer, gate):
			return style.text("talents_gate", {"points": gate})
		return style.text("talents_requires", {"names": _req_names(layer, n)})
	return err


func _gate_open(layer: String, gate: int) -> bool:
	var before: int = 0
	for id: String in loadout[layer]:
		var o: Dictionary = Talents.node_of(trees[layer], id)
		if int(o.get("gate", 0)) < gate:
			before += Talents.cost(o, int(loadout[layer][id]))
	return before >= gate


func _req_names(layer: String, n: Dictionary) -> String:
	var names: PackedStringArray = []
	for r: String in n.get("requires_any", []):
		var rn: Dictionary = Talents.node_of(trees[layer], r)
		names.append(str(rn.get("name", Data.abilities.get(r, {}).get("name", r))))
	return " or ".join(names)


## True when the node could take a point now (drawn bright).
func available(layer: String, n: Dictionary) -> bool:
	if layer == "pvp":
		return true
	return Talents.unlocked(trees[layer], loadout[layer], n)


func reset() -> void:
	if not locked:
		loadout = Talents.empty()
		message = ""
		queue_redraw()


func export_text() -> String:
	return Talents.encode(loadout, trees)


## Load a loadout from its text; "" or why it could not.
func import_text(text: String) -> String:
	if locked:
		return style.text("talents_locked")
	var d: Dictionary = Talents.decode(text, trees)
	var err: String = d["error"] if d["error"] != "" else Talents.check(d["loadout"], trees)
	if err != "":
		message = style.text("talents_import_failed", {"why": err})
	else:
		loadout = d["loadout"]
		message = style.text("talents_imported")
	queue_redraw()
	return err


## Show a saved loadout (and make it the active one).
func select_slot(i: int) -> void:
	var all: Array = loadouts.list(spec_id)
	slot = clampi(i, 0, maxi(all.size() - 1, 0))
	loadout = Talents.empty()
	if not all.is_empty():
		var d: Dictionary = Talents.decode(str(all[slot]["talents"]), trees)
		loadout = d["loadout"] if d["error"] == "" else Talents.empty()
		message = "" if d["error"] == "" else style.text("talents_outdated")
		loadouts.set_active(spec_id, slot)
	_refresh_controls()


## Save the shown loadout into the selected slot.
func save() -> int:
	var used: int = loadouts.put(spec_id, slot, name_edit.text if name_edit else "", export_text())
	if used >= 0:
		loadouts.set_active(spec_id, used)
		loadouts.save_file()
		message = style.text("talents_saved")
	_refresh_controls()
	return used


## Save the shown loadout as a new slot.
func save_new() -> int:
	var all: Array = loadouts.list(spec_id)
	if all.size() >= TalentLoadouts.MAX_PER_SPEC:
		message = style.text("talents_full", {"n": TalentLoadouts.MAX_PER_SPEC})
		queue_redraw()
		return -1
	var used: int = loadouts.put(spec_id, all.size(), style.text("talents_new_name", {"n": all.size() + 1}), export_text())
	if used >= 0:
		slot = used
		loadouts.set_active(spec_id, used)
		loadouts.save_file()
	_refresh_controls()
	return used


func delete_slot() -> void:
	loadouts.remove(spec_id, slot)
	loadouts.save_file()
	select_slot(mini(slot, loadouts.list(spec_id).size() - 1))


func close() -> void:
	loadouts.save_file()
	closed.emit(spec_id, loadouts.active_text(spec_id))


# ------------------------------------------------------------------ controls

func _build_controls() -> void:
	for spec: Array in [["save", "talents_save", save], ["new", "talents_new", save_new], ["delete", "talents_delete", delete_slot],
			["reset", "talents_reset", reset], ["export", "talents_export", _on_export], ["import", "talents_import", _on_import],
			["done", "talents_done", close]]:
		var b: Button = style.button(style.text(spec[1]), Vector2(150, 46), 20)
		b.name = "Button_%s" % spec[0]
		b.pressed.connect(spec[2])
		add_child(b)
		buttons[spec[0]] = b
	name_edit = _line_edit("talents_name_hint")
	name_edit.name = "LoadoutName"
	name_edit.max_length = 32
	code_edit = _line_edit("talents_code_hint")
	code_edit.name = "LoadoutCode"
	for i: int in TalentLoadouts.MAX_PER_SPEC:
		var sb: Button = style.button("", Vector2(PVP_RECT.size.x, 34), 18)
		sb.name = "Slot_%d" % i
		sb.toggle_mode = true
		sb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		sb.pressed.connect(select_slot.bind(i))
		add_child(sb)
		slot_buttons.append(sb)
	resized.connect(_layout)


func _line_edit(hint_key: String) -> LineEdit:
	var e: LineEdit = LineEdit.new()
	e.placeholder_text = style.text(hint_key)
	e.add_theme_font_override("font", style.font)
	e.add_theme_font_size_override("font_size", 20)
	e.add_theme_color_override("font_color", style.color("text"))
	e.add_theme_color_override("font_placeholder_color", style.color("text_dim"))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = style.color("button_bg")
	sb.border_color = style.color("button_border")
	sb.set_border_width_all(2)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	e.add_theme_stylebox_override("normal", sb)
	var focus: StyleBoxFlat = sb.duplicate()
	focus.border_color = style.color("button_border_hover")
	e.add_theme_stylebox_override("focus", focus)
	add_child(e)
	return e


func _refresh_controls() -> void:
	var all: Array = loadouts.list(spec_id)
	for i: int in slot_buttons.size():
		var b: Button = slot_buttons[i]
		b.visible = i < all.size()
		if b.visible:
			b.text = "%d   %s" % [i + 1, str(all[i]["name"])]
			b.set_pressed_no_signal(i == slot)
	if name_edit:
		name_edit.text = str(all[slot]["name"]) if slot < all.size() else ""
	for k: String in ["save", "new", "delete", "reset", "import"]:
		if buttons.has(k):
			(buttons[k] as Button).disabled = locked
	if buttons.has("new"):
		(buttons["new"] as Button).disabled = locked or all.size() >= TalentLoadouts.MAX_PER_SPEC
	queue_redraw()


func _on_export() -> void:
	var text: String = export_text()
	code_edit.text = text
	DisplayServer.clipboard_set(text)
	message = style.text("talents_exported")
	queue_redraw()


func _on_import() -> void:
	var text: String = code_edit.text.strip_edges()
	if text == "":
		text = DisplayServer.clipboard_get().strip_edges()
	import_text(text)


func _layout() -> void:
	var y: float = size.y - 92.0
	name_edit.position = Vector2(CLASS_X, y)
	name_edit.size = Vector2(300, 46)
	var x: float = CLASS_X + 316.0
	for k: String in ["save", "new", "delete", "reset"]:
		var b: Button = buttons[k]
		b.position = Vector2(x, y)
		x += b.size.x + 12.0
	code_edit.position = Vector2(x + 24.0, y)
	code_edit.size = Vector2(420, 46)
	x += 24.0 + 432.0
	for k: String in ["export", "import"]:
		var b: Button = buttons[k]
		b.position = Vector2(x, y)
		x += b.size.x + 12.0
	buttons["done"].position = Vector2(size.x - 60.0 - buttons["done"].size.x, 44.0)
	for i: int in slot_buttons.size():
		slot_buttons[i].position = Vector2(PVP_RECT.position.x, SLOTS_Y + i * 38.0)
	queue_redraw()


# ------------------------------------------------------------------ geometry and input

func tree_origin(layer: String) -> Vector2:
	return Vector2(CLASS_X if layer == "class" else SPEC_X, TREES_Y)


func node_rect(layer: String, n: Dictionary) -> Rect2:
	if layer == "pvp":
		var i: int = trees["pvp"]["nodes"].find(n)
		var cell: Vector2 = Vector2(PVP_RECT.position.x + 30.0 + (i % 4) * 76.0, PVP_RECT.position.y + 170.0 + (i / 4) * 76.0)
		return Rect2(cell, Vector2(NODE_PX, NODE_PX))
	var pos: Array = n.get("pos", [0, 0])
	var px: float = NODE_PX * (1.18 if n["type"] == "capstone" else 1.0)
	if n["type"] == "choice":
		px = CHOICE_PX * 2.0 + 6.0
	var center: Vector2 = tree_origin(layer) + Vector2(float(pos[0]) * COL_PX + NODE_PX * 0.5, float(pos[1]) * ROW_PX + NODE_PX * 0.5)
	return Rect2(center - Vector2(px, NODE_PX if n["type"] != "capstone" else px) * 0.5,
		Vector2(px, NODE_PX if n["type"] != "capstone" else px))


## The node under a point: {"layer", "id", "side"} (side 1 or 2 on a choice node), or {}.
func node_at(p: Vector2) -> Dictionary:
	for layer: String in ["class", "spec", "pvp"]:
		for n: Dictionary in trees.get(layer, {}).get("nodes", []):
			var r: Rect2 = node_rect(layer, n)
			if r.has_point(p):
				return {"layer": layer, "id": n["id"], "side": 1 if p.x < r.get_center().x else 2}
	return {}


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var h: Dictionary = node_at(event.position)
		if h != hovered:
			hovered = h
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		var h: Dictionary = node_at(event.position)
		if h.is_empty():
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			add(h["layer"], h["id"], int(h["side"]))
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			remove(h["layer"], h["id"])
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var top: Color = style.color("background_top")
	var bottom: Color = style.color("background_bottom")
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, h), Vector2(0, h)]),
		PackedColorArray([top, top, bottom, bottom]))
	var s: Dictionary = Data.specs.get(spec_id, {})
	var cls: Dictionary = Data.classes.get(str(s.get("class", "")), {})
	style.draw_text(self, Vector2(CLASS_X, 84), style.text("talents_title").to_upper(), 46, style.color("title"),
		HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	style.draw_text(self, Vector2(CLASS_X, 120), "%s  ·  %s" % [s.get("name", spec_id), cls.get("name", "")], 24,
		HudStyle.class_color(spec_id).lerp(Color.WHITE, 0.3))
	if locked:
		style.draw_text(self, Vector2(0, 84), style.text("talents_locked"), 24, style.color("defeat"), HORIZONTAL_ALIGNMENT_RIGHT, w - 70.0)
	for layer: String in ["class", "spec"]:
		_draw_tree(layer)
	_draw_pvp()
	style.draw_text(self, Vector2(PVP_RECT.position.x, SLOTS_Y - 18.0), style.text("talents_loadouts").to_upper(), 20,
		style.color("accent"), HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	if message != "":
		style.draw_text(self, Vector2(CLASS_X, h - 112.0), message, 20, style.color("subtitle"))
	if not hovered.is_empty():
		_draw_tooltip(hovered)


func _draw_tree(layer: String) -> void:
	var tree: Dictionary = trees.get(layer, {})
	if tree.is_empty():
		return
	var o: Vector2 = tree_origin(layer)
	var width: float = 6.0 * COL_PX + NODE_PX
	var label: String = style.text("talents_class_tree" if layer == "class" else "talents_spec_tree", {"name": _tree_owner_name(layer)})
	style.draw_text(self, o + Vector2(0, -44), label.to_upper(), 22, style.color("accent"), HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	var counter: String = "%d / %d" % [spent(layer), points(layer)]
	var full: bool = spent(layer) >= points(layer)
	style.draw_text(self, o + Vector2(0, -44), counter, 24, style.color("title") if full else style.color("text"),
		HORIZONTAL_ALIGNMENT_RIGHT, width, &"display")
	# gate lines above the first row holding nodes behind each gate
	for gate: int in tree.get("gates", []):
		var row: int = 99
		for n: Dictionary in tree["nodes"]:
			if int(n.get("gate", 0)) == gate:
				row = mini(row, int(n["pos"][1]))
		if row == 99:
			continue
		var y: float = o.y + row * ROW_PX - (ROW_PX - NODE_PX) * 0.5
		var open: bool = _gate_open(layer, gate)
		var col: Color = Color(style.color("accent"), 0.7) if open else Color(style.color("text_dim"), 0.5)
		draw_dashed_line(Vector2(o.x - 10.0, y), Vector2(o.x + width + 10.0, y), col, 2.0, 10.0)
		# a numbered badge at the line's left end, clear of the nodes (the tooltip explains it)
		var badge: Rect2 = Rect2(Vector2(o.x - 52.0, y - 14.0), Vector2(36, 28))
		draw_rect(badge, Color(0, 0, 0, 0.85))
		draw_rect(badge, col, false, 2.0)
		style.draw_text_in(self, badge, str(gate), 18, style.color("title") if open else style.color("text_dim"), HORIZONTAL_ALIGNMENT_CENTER, &"display")
	# connections, then nodes on top
	for n: Dictionary in tree["nodes"]:
		var r: Rect2 = node_rect(layer, n)
		for req: String in n.get("requires_any", []):
			var rn: Dictionary = Talents.node_of(tree, req)
			if rn.is_empty():
				continue
			var rr: Rect2 = node_rect(layer, rn)
			var lit: bool = rank_of(layer, req) >= Talents.max_rank(rn)
			var col: Color = style.color("accent") if lit else Color(style.color("button_border"), 0.45)
			draw_line(rr.get_center() + Vector2(0, rr.size.y * 0.5), r.get_center() - Vector2(0, r.size.y * 0.5), col, 3.0 if lit else 2.0)
	for n: Dictionary in tree["nodes"]:
		_draw_node(layer, n)


func _tree_owner_name(layer: String) -> String:
	var s: Dictionary = Data.specs.get(spec_id, {})
	if layer == "class":
		return str(Data.classes.get(str(s.get("class", "")), {}).get("name", ""))
	return str(s.get("name", ""))


func _draw_node(layer: String, n: Dictionary) -> void:
	var r: Rect2 = node_rect(layer, n)
	var rank: int = rank_of(layer, n["id"])
	var top: int = 1 if layer == "pvp" else Talents.max_rank(n)
	var open: bool = rank > 0 or available(layer, n)
	var tint: Color = Color.WHITE if rank > 0 else (Color(0.78, 0.78, 0.78) if open else Color(0.32, 0.32, 0.32))
	if n["type"] == "choice":
		draw_rect(r.grow(3.0), Color(0, 0, 0, 0.85))
		for i: int in 2:
			var c: Dictionary = n["choices"][i]
			var cr: Rect2 = Rect2(r.position + Vector2(i * (CHOICE_PX + 6.0), (NODE_PX - CHOICE_PX) * 0.5), Vector2(CHOICE_PX, CHOICE_PX))
			var picked: bool = rank == i + 1
			hud.icon(self, cr, c.get("icon", n.get("icon", {})), str(c["name"]), Color.WHITE if picked else tint * (0.55 if rank > 0 else 1.0), false)
			if picked:
				draw_rect(cr.grow(2.0), style.color("title"), false, 2.0)
	else:
		hud.icon(self, r, n.get("icon", {}), str(n["name"]), tint, false)
	var border: Color = style.color("title") if rank >= top else (style.color("accent") if rank > 0 else
		(style.color("button_border") if open else Color(style.color("button_border"), 0.35)))
	draw_rect(r.grow(2.0), border, false, 3.0 if rank > 0 else 2.0)
	if n["type"] == "capstone":
		draw_rect(r.grow(6.0), Color(border, 0.6), false, 1.5)
	if layer != "pvp" and n["type"] != "choice":
		var txt: String = "%d/%d" % [rank, top]
		var box: Rect2 = Rect2(r.end - Vector2(30, 16), Vector2(34, 20))
		draw_rect(box, Color(0, 0, 0, 0.85))
		style.draw_text_in(self, box, txt, 15, style.color("title") if rank >= top else style.color("text"))
	if not hovered.is_empty() and hovered["layer"] == layer and hovered["id"] == n["id"]:
		draw_rect(r.grow(5.0), Color(1, 1, 1, 0.5), false, 1.0)


func _draw_pvp() -> void:
	var r: Rect2 = PVP_RECT
	style.draw_panel(self, r)
	style.draw_text(self, r.position + Vector2(22, 44), style.text("talents_pvp").to_upper(), 22, style.color("accent"),
		HORIZONTAL_ALIGNMENT_LEFT, -1, &"display")
	style.draw_text(self, r.position + Vector2(22, 44), "%d / %d" % [spent("pvp"), points("pvp")], 24, style.color("text"),
		HORIZONTAL_ALIGNMENT_RIGHT, r.size.x - 44.0, &"display")
	# the three slots, filled in pick order
	for i: int in points("pvp"):
		var sr: Rect2 = Rect2(r.position + Vector2(30.0 + i * 100.0, 72.0), Vector2(NODE_PX + 12.0, NODE_PX + 12.0))
		draw_rect(sr, Color(0, 0, 0, 0.6))
		draw_rect(sr, style.color("button_border"), false, 2.0)
		if i < loadout["pvp"].size():
			var n: Dictionary = Talents.node_of(trees["pvp"], loadout["pvp"][i])
			hud.icon(self, sr.grow(-6.0), n.get("icon", {}), str(n.get("name", "")), Color.WHITE, false)
	draw_line(r.position + Vector2(20, 154), r.position + Vector2(r.size.x - 20, 154), Color(style.color("button_border"), 0.5), 1.0)
	for n: Dictionary in trees.get("pvp", {}).get("nodes", []):
		_draw_node("pvp", n)


func _draw_tooltip(h: Dictionary) -> void:
	var layer: String = h["layer"]
	var n: Dictionary = Talents.node_of(trees[layer], h["id"])
	if n.is_empty():
		return
	var lines: Array = []  # [text, size, color]
	var rank: int = rank_of(layer, n["id"])
	if n["type"] == "choice":
		lines.append([style.text("talents_choice"), 16, style.color("accent")])
		for c: Dictionary in n["choices"]:
			lines.append([str(c["name"]), 22, style.color("title")])
			lines.append([str(c.get("description", "")), 18, style.color("text")])
	else:
		lines.append([str(n["name"]), 24, style.color("title")])
		var kind: String = style.text("talents_type_" + str(n["type"]))
		if layer != "pvp":
			kind += "  ·  " + style.text("talents_rank", {"rank": rank, "max": Talents.max_rank(n)})
		lines.append([kind, 16, style.color("accent")])
		lines.append([str(n.get("description", "")), 18, style.color("text")])
	if layer != "pvp" and rank == 0 and not available(layer, n):
		var gate: int = int(n.get("gate", 0))
		var why: String = style.text("talents_gate", {"points": gate}) if gate > 0 and not _gate_open(layer, gate) \
			else style.text("talents_requires", {"names": _req_names(layer, n)})
		lines.append([why, 17, style.color("defeat")])
	elif not locked:
		lines.append([style.text("talents_hint_remove") if rank > 0 else style.text("talents_hint_add"), 16, style.color("text_dim")])
	var tw: float = 400.0
	var hgt: float = 24.0
	for l: Array in lines:
		hgt += _wrapped_height(str(l[0]), int(l[1]), tw - 32.0) + 6.0
	var nr: Rect2 = node_rect(layer, n)
	var pos: Vector2 = Vector2(nr.end.x + 16.0, nr.position.y)
	if pos.x + tw > size.x - 20.0:
		pos.x = nr.position.x - 16.0 - tw
	pos.y = clampf(pos.y, 20.0, size.y - hgt - 20.0)
	var box: Rect2 = Rect2(pos, Vector2(tw, hgt))
	style.draw_panel(self, box, Color(style.color("panel_bg"), 0.98))
	var y: float = box.position.y + 16.0
	for l: Array in lines:
		var fsz: int = int(l[1])
		y += style.font.get_ascent(fsz)
		draw_multiline_string(style.font, Vector2(box.position.x + 16.0, y), str(l[0]), HORIZONTAL_ALIGNMENT_LEFT,
			tw - 32.0, fsz, -1, l[2])
		y += _wrapped_height(str(l[0]), fsz, tw - 32.0) - style.font.get_ascent(fsz) + 6.0


func _wrapped_height(s: String, fsz: int, width: float) -> float:
	return style.font.get_multiline_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, width, fsz).y
