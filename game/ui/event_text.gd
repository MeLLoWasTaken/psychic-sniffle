class_name EventText
extends Control
## Subtitle-style event text (backlog M2-13, accessibility): the events that matter most, written
## as short lines under the match timer for a few seconds each, for players who miss sounds or
## effects. Shown when the accessibility setting is on; the HUD feeds it (Hud.push).

const LIFE_S: float = 4.0
const MAX_LINES: int = 4

var style: HudStyle
var lines: Array[Dictionary] = []  ## {text, color, age}


func setup(p_style: HudStyle) -> void:
	style = p_style
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(760, 120)
	size = custom_minimum_size


func add(text: String, col: Color) -> void:
	lines.append({"text": text, "color": col, "age": 0.0})
	while lines.size() > MAX_LINES:
		lines.pop_front()
	queue_redraw()


func advance(delta: float) -> void:
	if lines.is_empty():
		return
	for l: Dictionary in lines:
		l["age"] = float(l["age"]) + delta
	lines = lines.filter(func(l: Dictionary) -> bool: return float(l["age"]) < LIFE_S)
	queue_redraw()


## The line for one event as the player `me_id` sees it, or "" when it is not worth a line.
static func line_for(ev: Dictionary, view: Dictionary) -> String:
	var me: Dictionary = view.get("me", {})
	var me_id: int = int(me.get("id", -1))
	var src: int = int(ev.get("source", -1))
	var tgt: int = int(ev.get("target", -1))
	var ab_name: String = str(Data.abilities.get(str(ev.get("ability", "")), {}).get("name", ""))
	var who: Callable = func(id: int) -> String:
		if id == me_id:
			return "you"
		for u: Dictionary in view.get("units", []):
			if int(u["id"]) == id:
				return ("your partner %s" if int(u["team"]) == int(me.get("team", -1)) else "%s") % HudStyle.spec_label(str(u["spec"]))
		return "someone"
	match str(ev.get("type", "")):
		"aura_applied":
			var cc: String = str(ev.get("cc", "none"))
			var mine: bool = tgt == me_id
			var ally: bool = not mine and who.call(tgt).begins_with("your partner")
			if cc != "none" and cc != "knockback" and (mine or ally):
				var aura: String = str(Data.auras.get(str(ev.get("aura", "")), {}).get("name", cc))
				return "%s %s %s (%s)" % [Tooltip.sentence(who.call(tgt)), "are" if mine else "is", cc.replace("_", " "), aura]
		"cast_start":
			if tgt == me_id and src != me_id and ab_name != "":
				return "%s is casting %s at you" % [Tooltip.sentence(who.call(src)), ab_name]
		"interrupt":
			var lost: String = str(Data.abilities.get(str(ev.get("interrupted", "")), {}).get("name", ""))
			if tgt == me_id:
				return "Your %s was interrupted" % lost
			if src == me_id:
				return "You interrupted %s" % lost
		"gates_open":
			return "The gates are open"
		"pickup_spawned":
			return "Healing and mana pickups have appeared"
		"twist_warning", "twist":
			return str(ev.get("text", ""))
	return ""


func _draw() -> void:
	if style == null:
		return
	var y: float = 0.0
	for l: Dictionary in lines:
		var a: float = clampf((LIFE_S - float(l["age"])) / 0.6, 0.0, 1.0)
		var col: Color = l["color"]
		col.a *= a
		y += 26.0
		style.text(self, Vector2(0, y), str(l["text"]), 20, col, HORIZONTAL_ALIGNMENT_CENTER, size.x, 4)
