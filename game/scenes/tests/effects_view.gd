extends Node3D
## Review views of the spell effects (backlog M1-25), on a neutral stone floor under the arena's
## lighting preset (fog, bloom, tonemapping and grade as in the game):
##
##   tools/screenshot.sh res://scenes/tests/effects_view.tscn previews/effects/schools.png 1600 900 40 \
##     --mode schools [--no-effects] [--layout <abs path.json>]
##   tools/screenshot.sh res://scenes/tests/effects_view.tscn previews/effects/grid_arcanist_rime.png 1600 900 40 \
##     --mode grid --spec arcanist_rime [--caster-team 1]
##
## "schools": one cell per school of the palette with the same four effects (hand glows, a
## projectile, an impact burst, a shield), labelled, so each school can be judged by color alone;
## --no-effects renders the same frame without them (the background for tools/effects_hues.py) and
## --layout writes each cell's screen rectangle. "grid": every ability of a spec (plus its class's
## shared abilities) previewed at once between a caster and a target stand-in (EffectsDirector.
## preview_ability); the caster is on --caster-team (1: enemy of the viewer, so ground circles get
## the red outline; 0: ally). Effects are frozen at a representative moment; particles keep moving.

const CELL_W: float = 3.6
const CELL_D: float = 4.8
const GRID_W: float = 5.2
const GRID_D: float = 4.6

var cells: Array[Dictionary] = []  ## {name, centre: Vector3, half: Vector3}
var director: EffectsDirector
var cam: Camera3D


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var mode: String = _arg(args, "--mode", "schools")
	var effects_on: bool = not ("--no-effects" in args)
	_stage(str(_arg(args, "--lighting", "dusk_grim")))
	if mode == "grid":
		_grid(_arg(args, "--spec", "warblade_carnage"), int(_arg(args, "--caster-team", "1")), effects_on)
	else:
		_schools(effects_on)
	var layout: String = _arg(args, "--layout", "")
	if layout != "":
		await get_tree().process_frame
		await get_tree().process_frame
		_write_layout(layout)


func _process(delta: float) -> void:
	if director != null:
		director.update(delta)


# ------------------------------------------------------------------ schools

func _schools(effects_on: bool) -> void:
	var schools: Array = EffectsData.schools()
	var cols: int = 5
	var rows: int = ceili(schools.size() / float(cols))
	for i: int in schools.size():
		var c: Vector3 = Vector3((i % cols - (cols - 1) * 0.5) * CELL_W, 0.0, (i / cols - (rows - 1) * 0.5) * CELL_D)
		var school: String = str(schools[i])
		cells.append({"name": school, "centre": c + Vector3(0, 1.2, 0), "half": Vector3(1.7, 1.2, 0.9)})
		_label(school.capitalize(), c + Vector3(0, 0.02, 1.25))
		if not effects_on:
			continue
		var glow: Vfx = EffectLibrary.cast_glow(school, "both", 1.2)
		add_child(glow)
		(glow.parts[0]["node"] as Node3D).position = c + Vector3(-1.05, 1.45, -0.2)
		(glow.parts[1]["node"] as Node3D).position = c + Vector3(-0.55, 1.45, -0.2)
		(glow.parts[2]["node"] as Node3D).position = c + Vector3(-0.8, 0.03, 0.0)  # feet ring
		glow.set_hold(0.5)
		var shield: Vfx = EffectLibrary.aura("shield", school, 0.8)
		add_child(shield)
		shield.position = c + Vector3(-0.8, 0.95, 0.0)
		shield.set_hold(1.0)
		var shot: Vfx = EffectLibrary.projectile("bolt", school, 1.2)
		add_child(shot)
		shot.position = c + Vector3(0.25, 1.35, 0.0)
		shot.look_at(shot.position + Vector3.RIGHT, Vector3.UP)
		shot.set_hold(0.2)
		var burst: Vfx = EffectLibrary.impact("burst", school, 0.9)
		add_child(burst)
		burst.position = c + Vector3(1.15, 1.35, 0.0)
		burst.set_hold(0.12)
	_camera(Vector3(0, 11.0, 13.5), Vector3(0, 0.7, 1.0), 44.0)


# ------------------------------------------------------------------ ability grid

func _grid(spec_id: String, caster_team: int, effects_on: bool) -> void:
	var spec: Dictionary = Data.specs.get(spec_id, {})
	var ids: Array = spec.get("abilities", []).duplicate()
	ids.append_array(Data.classes.get(spec.get("class", ""), {}).get("shared_abilities", []))
	var cols: int = 5
	var rows: int = ceili(ids.size() / float(cols))
	var units: Array = []
	var pairs: Array = []
	for i: int in ids.size():
		var c: Vector3 = Vector3((i % cols - (cols - 1) * 0.5) * GRID_W, 0.0, (i / cols - (rows - 1) * 0.5) * GRID_D)
		var id: String = str(ids[i])
		var caster: int = 100 + i * 2
		var target: int = caster + 1
		var ab: Dictionary = Data.abilities.get(id, {})
		var ally_target: bool = str(ab.get("target", "")) == "ally"
		units.append(_dummy_unit(caster, caster_team, c + Vector3(-1.2, 0, 0), -PI / 2))
		units.append(_dummy_unit(target, caster_team if ally_target else 1 - caster_team, c + Vector3(1.2, 0, 0), PI / 2))
		pairs.append([id, caster, target])
		cells.append({"name": id, "centre": c + Vector3(0, 1.2, 0), "half": Vector3(2.3, 1.2, 1.4)})
		_label("%s  (%s)" % [str(ab.get("name", id)), EffectsData.school_of(id)], c + Vector3(0, 0.02, 1.6))
		_capsule(c + Vector3(-1.2, 0, 0), caster_team)
		_capsule(c + Vector3(1.2, 0, 0), caster_team if ally_target else 1 - caster_team)
	var me: Dictionary = _dummy_unit(1, 0, Vector3(0, 0, 60), 0.0)
	units.append(me)
	if effects_on:
		director = EffectsDirector.new()
		add_child(director)
		director.push_view({"tick": 1, "tick_rate": 60, "me": me, "units": units})
		for p: Array in pairs:
			director.preview_ability(str(p[0]), int(p[1]), int(p[2]), 1.8)
	var depth: float = rows * GRID_D
	_camera(Vector3(0, depth * 1.05 + 2.0, depth * 0.62 + 2.5), Vector3(0, 0.0, 1.2), 52.0)
	for l: Node in find_children("*", "DirectionalLight3D", false, false):
		(l as DirectionalLight3D).shadow_enabled = false  # long dusk shadows clutter the grid


func _dummy_unit(id: int, team: int, pos: Vector3, facing: float) -> Dictionary:
	return {"id": id, "team": team, "spec": "", "position": pos, "facing": facing, "health": 1, "max_health": 1,
		"target_id": -1, "cast": {}, "auras": []}


## A team-tinted stand-in, 1.8 m tall, with a nose showing its facing.
func _capsule(pos: Vector3, team: int) -> void:
	var body: CapsuleMesh = CapsuleMesh.new()
	body.radius = 0.35
	body.height = 1.8
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.42, 0.44).lerp(MapBuilder.TEAM_COLORS[team], 0.35)
	mat.roughness = 0.8
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = body
	mi.material_override = mat
	mi.position = pos + Vector3(0, 0.9, 0)
	add_child(mi)


# ------------------------------------------------------------------ stage

## Neutral stone floor, the lighting preset's sky, sun, fill, fog and post-processing.
func _stage(preset_id: String) -> void:
	var preset: Dictionary = Data.lighting.get(preset_id, {})
	var floor_mesh: PlaneMesh = PlaneMesh.new()
	floor_mesh.size = Vector2(90, 90)
	var floor_mat: StandardMaterial3D = StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.34, 0.33, 0.32)  # flagstone grey, as the arena kit
	floor_mat.roughness = 0.92
	var floor_node: MeshInstance3D = MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	floor_node.material_override = floor_mat
	add_child(floor_node)
	if preset.is_empty():
		return
	var env: Environment = Environment.new()
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = MapBuilder._rgb(preset["sky"]["top"])
	sky_mat.sky_horizon_color = MapBuilder._rgb(preset["sky"]["horizon"])
	sky_mat.ground_horizon_color = MapBuilder._rgb(preset["sky"]["horizon"])
	sky_mat.ground_bottom_color = MapBuilder._rgb(preset["sky"]["ground"])
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = MapBuilder._rgb(preset["ambient"]["color"])
	env.ambient_light_energy = float(preset["ambient"]["energy"])
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var post: Dictionary = preset["post"]
	env.tonemap_exposure = float(post.get("exposure", 1.0))
	env.glow_enabled = true
	env.glow_intensity = float(post.get("glow_intensity", 0.5))
	env.glow_bloom = 0.05
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = float(preset["fog"]["density"])
	env.volumetric_fog_albedo = MapBuilder._rgb(preset["fog"]["albedo"])
	env.adjustment_enabled = true
	env.adjustment_saturation = float(post.get("saturation", 1.0))
	env.adjustment_contrast = float(post.get("contrast", 1.0))
	if preset.has("grade"):
		env.adjustment_color_correction = MapBuilder._grade_texture(preset["grade"])
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	add_child(we)
	for key: String in ["sun", "fill"]:
		if not preset.has(key):
			continue
		var cfg: Dictionary = preset[key]
		var l: DirectionalLight3D = DirectionalLight3D.new()
		l.light_color = MapBuilder._rgb(cfg["color"])
		l.light_energy = float(cfg["energy"])
		l.rotation_degrees = Vector3(float(cfg["pitch_deg"]), float(cfg["yaw_deg"]), 0)
		l.shadow_enabled = bool(cfg.get("shadows", false))
		add_child(l)


func _label(text: String, pos: Vector3) -> void:
	var l: Label3D = Label3D.new()
	l.text = text
	l.position = pos
	l.rotation_degrees = Vector3(-90, 0, 0)  # lying on the floor, readable from the camera
	l.font_size = 72
	l.pixel_size = 0.0045
	l.outline_size = 14
	l.modulate = Color(0.95, 0.94, 0.9)
	l.outline_modulate = Color(0.05, 0.05, 0.06)
	add_child(l)


func _camera(pos: Vector3, look: Vector3, fov: float) -> void:
	cam = Camera3D.new()
	add_child(cam)
	cam.fov = fov
	cam.position = pos
	cam.look_at(look)
	cam.current = true


## Screen rectangle of every cell (projected corners of its box), for the hue measurement.
func _write_layout(path: String) -> void:
	var out: Array = []
	for c: Dictionary in cells:
		var lo: Vector2 = Vector2(INF, INF)
		var hi: Vector2 = Vector2(-INF, -INF)
		var centre: Vector3 = c["centre"]
		var half: Vector3 = c["half"]
		for sx: int in [-1, 1]:
			for sy: int in [-1, 1]:
				for sz: int in [-1, 1]:
					var p: Vector2 = cam.unproject_position(centre + Vector3(sx * half.x, sy * half.y, sz * half.z))
					lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
					hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		out.append({"name": c["name"], "rect": [roundi(lo.x), roundi(lo.y), roundi(hi.x), roundi(hi.y)]})
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"viewport": [vp.x, vp.y], "cells": out}, "  "))
	f.close()
	Log.info("effects_view: wrote layout of %d cells to %s" % [out.size(), path])


static func _arg(args: PackedStringArray, name: String, default: String) -> String:
	var i: int = args.find(name)
	return args[i + 1] if i != -1 and i + 1 < args.size() else default
