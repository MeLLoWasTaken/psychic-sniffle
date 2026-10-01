class_name EffectsDirector
extends Node3D
## Spell effects in the world (backlog M1-25): turns the world view and combat events into the
## effect stages of data/effects (cast glow, projectile, impact, ground circle, melee swing,
## displacement, aura visuals), built by EffectLibrary in the colors of the palette's schools.
## No per-class or per-ability code: everything an ability shows is its effect entry.
##
## WorldRenderer owns one and forwards push_view(), push_events() and update(delta); without a
## renderer (tests, previews) unit positions come from the views. The view is the truth for
## lasting visuals (cast glows follow each unit's "cast", aura visuals its "auras"), so a lost
## event never leaves a glow behind; events start one-shot stages and make lasting ones appear
## without waiting for the next view.
##
## Budget (data/effect_palettes: budget): at most max_effects live effects and max_particles
## particles; a new effect that does not fit replaces the lowest-priority live one below it, or is
## dropped. Crowd-control auras and enemy ground effects have the highest priority. Finished
## effects are freed.

const ANCHOR_HEIGHTS: Dictionary = {"feet": 0.03, "body": 1.0, "chest": 1.3, "overhead": 2.35}
## Hand fallbacks (unit space, -Z forward) when a unit has no skeleton (capsule stand-ins).
const HAND_OFFSETS: Dictionary = {"hand_r": Vector3(0.38, 1.2, -0.3), "hand_l": Vector3(-0.38, 1.2, -0.3)}

var my_id: int = -1  ## the local player (settings: others' effect opacity)
var renderer: WorldRenderer  ## may be null: positions then come from the views
var view: Dictionary = {}
var my_team: int = 0
var tick_rate: int = 60
var active: Array[Vfx] = []
var spawned: int = 0  ## effects created (stats)
var dropped: int = 0  ## effects refused by the budget (stats)
var particles_live: int = 0  ## sum of live effects' particle amounts
var budget: Dictionary = {}
var defaults: Dictionary = {}

var _positions: Dictionary = {}  ## unit id -> Vector3 in the newest view
var _prev_positions: Dictionary = {}  ## unit id -> Vector3 in the view before
var _facings: Dictionary = {}
var _teams: Dictionary = {}
var _casts: Dictionary = {}  ## source id -> cast glow Vfx
var _auras: Dictionary = {}  ## "unit:aura" -> Vfx
var _skeletons: Dictionary = {}  ## unit id -> {sk, bones: {hand_r: idx, hand_l: idx}} or {}
var _swing_count: Dictionary = {}  ## unit id -> swings, to alternate arc sides
var _impacts_this_batch: int = 0
## (source unit, ability) -> seconds until that unit's swing strikes, 0 for none (WorldRenderer sets
## it): a melee hit's impact at the target waits for the blade; the swing trail does not
var strike_delay: Callable = Callable()
var _defer_s: float = 0.0  ## while handling one event: how long its impacts at a target wait
var _deferred: Array = []  ## [seconds left, impact, ability, school, source, target]
var _recent: Array = []  ## [source, ability] of recent cast_success events, newest last

static var _live_directors: int = 0


func _init(r: WorldRenderer = null) -> void:
	renderer = r
	name = "Effects"
	budget = EffectsData.budget()
	defaults = EffectsData.defaults()


func _enter_tree() -> void:
	_live_directors += 1


func _exit_tree() -> void:
	_live_directors -= 1
	if _live_directors <= 0:
		EffectLibrary.clear_cache()  # shared meshes and materials go with the last director


## Take the newest world view: positions, relations, and the cast glows and aura visuals it implies.
func push_view(v: Dictionary) -> void:
	if v.is_empty():
		return
	view = v
	tick_rate = int(v.get("tick_rate", tick_rate))
	my_team = int(v.get("me", {}).get("team", my_team))
	my_id = int(v.get("me", {}).get("id", my_id))
	_prev_positions = _positions
	_positions = {}
	var seen: Dictionary = {}
	for u: Dictionary in v.get("units", []):
		var id: int = int(u["id"])
		seen[id] = true
		_positions[id] = u["position"]
		_facings[id] = float(u.get("facing", 0.0))
		_teams[id] = int(u.get("team", 0))
	for id: int in _prev_positions:
		if not _positions.has(id):
			_prev_positions.erase(id)
	for u: Dictionary in v.get("units", []):
		_sync_unit(u)
	for vfx: Vfx in active.duplicate():  # units that left the view take their effects along
		if vfx.unit != -1 and not seen.has(vfx.unit) and not vfx.stopping:
			_stop(vfx)


## Combat events (MatchRunner.take_events shape), oldest first.
func push_events(evs: Array) -> void:
	_impacts_this_batch = 0
	for ev: Dictionary in evs:
		var type: String = str(ev.get("type", ""))
		var src: int = int(ev.get("source", -1))
		var ability: String = str(ev.get("ability", ""))
		_defer_s = 0.0
		if type in ["cast_success", "damage", "heal"] and strike_delay.is_valid():
			_defer_s = float(strike_delay.call(src, ability))
		match type:
			"cast_start":
				_start_cast(src, ability, float(int(ev.get("end_tick", 0)) - int(ev.get("tick", 0))) / tick_rate)
			"cast_success":
				_end_cast(src)
				_recent.append([src, ability])
				if _recent.size() > 32:
					_recent.pop_front()
				var e: Dictionary = EffectsData.entry(ability)
				if not e.is_empty() and str(e.get("trigger", "cast_success")) == "cast_success":
					_release(e, ability, src, int(ev.get("target", -1)))
			"cast_failed", "cast_interrupted", "channel_end":
				_end_cast(src)
			"damage", "heal":
				_hit(ability, src, int(ev.get("target", -1)), bool(ev.get("crit", false)))
			"aura_applied", "aura_refreshed":
				_add_aura(int(ev.get("target", -1)), str(ev.get("aura", "")), src)
			"aura_removed", "dispel":
				_remove_aura(int(ev.get("target", -1)), str(ev.get("aura", "")))
			"charge", "teleport":
				_displace(src, src if type == "charge" else int(ev.get("target", src)))


## Advance every effect by `delta` seconds and keep attached ones on their units.
func update(delta: float) -> void:
	_defer_s = 0.0
	if not _deferred.is_empty():
		var keep: Array = []
		for d: Array in _deferred:
			d[0] = float(d[0]) - delta
			if float(d[0]) <= 0.0:
				_impact(d[1], d[2], d[3], d[4], d[5])
			else:
				keep.append(d)
		_deferred = keep
	for vfx: Vfx in active.duplicate():  # arrivals may add impacts or evict effects meanwhile
		if vfx.is_queued_for_deletion():
			continue
		if not vfx.hold:
			_follow(vfx, delta)
		if not vfx.advance(delta):
			_free_at(active.find(vfx))


## Live effects of a kind (Vfx.Kind), for checks.
func effects_of(kind: int) -> Array[Vfx]:
	var out: Array[Vfx] = []
	for v: Vfx in active:
		if v.kind == kind:
			out.append(v)
	return out


## The aura visual on a unit, or null.
func aura_vfx(unit_id: int, aura_id: String) -> Vfx:
	return _auras.get("%d:%s" % [unit_id, aura_id], null)


## The cast glow of a unit, or null.
func cast_vfx(unit_id: int) -> Vfx:
	return _casts.get(unit_id, null)


## World position of an anchor point on a unit: feet, body, chest, overhead, hand_r, hand_l.
func anchor_position(unit_id: int, anchor: String) -> Vector3:
	var root: Node3D = _root_of(unit_id)
	var base: Vector3
	var basis: Basis
	if root != null:
		base = root.global_position if root.is_inside_tree() else root.position
		basis = root.global_basis if root.is_inside_tree() else root.basis
	else:
		base = _positions.get(unit_id, Vector3.ZERO)
		basis = Basis(Vector3.UP, float(_facings.get(unit_id, 0.0)))
	if HAND_OFFSETS.has(anchor):
		var hand: Vector3 = _hand_position(unit_id, anchor, root)
		return hand if hand != Vector3.INF else base + basis * HAND_OFFSETS[anchor]
	return base + Vector3.UP * float(ANCHOR_HEIGHTS.get(anchor, 1.0))


## True when `unit_id` is on the other team from the local player.
func is_hostile(unit_id: int) -> bool:
	return int(_teams.get(unit_id, my_team)) != my_team


# ================================================================ stages from events

func _start_cast(src: int, ability: String, length_s: float) -> void:
	var e: Dictionary = EffectsData.entry(ability)
	if e.is_empty() or not e.has("cast") or src < 0:
		return
	var old: Vfx = _casts.get(src, null)
	if old != null and old.ability == ability and not old.stopping:
		return
	_end_cast(src)
	var school: String = EffectsData.school_of(ability)
	var vfx: Vfx = EffectLibrary.cast_glow(school, str(e["cast"].get("hands", "both")), float(e["cast"].get("size", 1.0)))
	vfx.ability = ability
	vfx.source = src
	vfx.unit = src
	vfx.lifetime = maxf(length_s, 0.1) + 1.0  # safety: the cast's end event or view stops it first
	if _admit(vfx):
		_casts[src] = vfx


func _end_cast(src: int) -> void:
	var vfx: Vfx = _casts.get(src, null)
	if vfx == null:
		return
	_casts.erase(src)
	_stop(vfx)


## The release of an ability: projectile, impact at the target or self, ground circle, swing.
func _release(e: Dictionary, ability: String, src: int, tgt: int) -> void:
	var school: String = EffectsData.school_of(ability)
	var imp: Dictionary = e.get("impact", {})
	var at: String = str(imp.get("at", "target"))
	if e.has("projectile") and tgt >= 0 and tgt != src and _known(src) and _known(tgt):
		_launch(e, ability, school, src, tgt)
	elif not imp.is_empty() and at == "target" and tgt >= 0 and _known(tgt):
		_impact(imp, ability, school, src, tgt)
	if not imp.is_empty() and at == "self" and _known(src):
		_impact(imp, ability, school, src, src)
	if e.has("ground"):
		var g: Dictionary = e["ground"]
		var centre: int = tgt if str(g.get("center", "caster")) == "target" and tgt >= 0 else src
		if _known(centre):
			var vfx: Vfx = EffectLibrary.ground(str(g["style"]), school, maxf(EffectsData.radius_of(ability), 0.5),
				is_hostile(src), float(g.get("lifetime_s", defaults.get("ground_lifetime_s", 0.9))))
			vfx.ability = ability
			vfx.source = src
			if _admit(vfx):
				var p: Vector3 = anchor_position(centre, "feet")
				vfx.global_position = Vector3(p.x, 0.0, p.z)  # arena floors are flat at y = 0 (jumps lift units)
	if e.has("melee") and _known(src):
		var m: Dictionary = e["melee"]
		var n: int = int(_swing_count.get(src, 0))
		_swing_count[src] = n + 1
		var vfx: Vfx = EffectLibrary.melee(str(m["style"]), school, float(m.get("size", 1.0)), n % 2 == 1)
		vfx.ability = ability
		vfx.source = src
		vfx.unit = src
		vfx.anchor = "feet"
		if _admit(vfx):
			_follow(vfx, 0.0)


func _hit(ability: String, src: int, tgt: int, crit: bool) -> void:
	var e: Dictionary = EffectsData.entry(ability)
	if e.is_empty():
		return
	if str(e.get("trigger", "cast_success")) == "damage":
		_release(e, ability, src, tgt)
	var imp: Dictionary = e.get("impact", {})
	if imp.is_empty() or str(imp.get("at", "target")) != "hits" or tgt < 0 or not _known(tgt):
		return
	var big: Dictionary = imp.duplicate()
	if crit:
		big["size"] = float(imp.get("size", 1.0)) * 1.35
	_impact(big, ability, EffectsData.school_of(ability), src, tgt)


func _impact(imp: Dictionary, ability: String, school: String, src: int, tgt: int) -> Vfx:
	if _defer_s > 0.0 and tgt != src:
		_deferred.append([_defer_s, imp, ability, school, src, tgt])
		return null
	if _impacts_this_batch >= int(budget.get("max_impacts_per_tick", 24)):
		dropped += 1
		return null
	_impacts_this_batch += 1
	var style: String = str(imp["style"])
	var vfx: Vfx = EffectLibrary.impact(style, school, float(imp.get("size", 1.0)))
	vfx.ability = ability
	vfx.source = src
	if not _admit(vfx):
		return null
	var anchor: String = "feet" if style in ["rays", "hail"] else ("body" if style == "flash" else "chest")
	vfx.global_position = anchor_position(tgt, anchor)
	return vfx


func _launch(e: Dictionary, ability: String, school: String, src: int, tgt: int) -> void:
	var p: Dictionary = e["projectile"]
	var vfx: Vfx = EffectLibrary.projectile(str(p["style"]), school, float(p.get("size", 1.0)))
	vfx.ability = ability
	vfx.source = src
	var hands: String = str(e.get("cast", {}).get("hands", "right"))
	var from: Vector3 = anchor_position(src, "hand_l" if hands == "left" else "hand_r")
	var dist: float = from.distance_to(anchor_position(tgt, "chest"))
	var speed: float = maxf(float(p.get("speed_mps", defaults.get("projectile_speed_mps", 40.0))),
		dist / float(defaults.get("max_flight_s", 0.45)))
	vfx.data = {"target": tgt, "speed": speed, "impact": e.get("impact", {}), "flying": true}
	vfx.lifetime = -1.0
	if _admit(vfx):
		vfx.global_position = from
		_aim(vfx, anchor_position(tgt, "chest"))


## A charge (the caster moved) or teleport (the target moved, often the caster itself).
func _displace(src: int, mover: int) -> void:
	var ability: String = _last_release_of(src)
	var e: Dictionary = EffectsData.entry(ability)
	if e.is_empty() or not e.has("displacement"):
		return
	if not _positions.has(mover):
		return
	var to: Vector3 = _positions[mover]
	var from: Vector3 = _prev_positions.get(mover, to)
	var vfx: Vfx = EffectLibrary.displacement(str(e["displacement"]["style"]), EffectsData.school_of(ability), from, to)
	vfx.ability = ability
	vfx.source = src
	var pos: Vector3 = vfx.position
	var rot: Vector3 = vfx.rotation
	if _admit(vfx):
		vfx.global_position = pos
		vfx.global_rotation = rot


# ================================================================ lasting visuals from the view

## Cast glow and aura visuals of one unit from its view entry.
func _sync_unit(u: Dictionary) -> void:
	var id: int = int(u["id"])
	var cast: Dictionary = u.get("cast", {})
	if cast.is_empty():
		_end_cast(id)
	else:
		var length: float = float(int(cast.get("end_tick", 0)) - int(view.get("tick", 0))) / tick_rate
		_start_cast(id, str(cast.get("ability", "")), length)
	var have: Dictionary = {}
	for inst: Dictionary in u.get("auras", []):
		have[str(inst["id"])] = int(inst.get("source", -1))
	var prefix: String = "%d:" % id
	for key: String in _auras.keys():
		if key.begins_with(prefix) and not have.has(key.substr(prefix.length())):
			_remove_aura(id, key.substr(prefix.length()))
	for aura_id: String in have:
		if not _auras.has(prefix + aura_id):
			_add_aura(id, aura_id, int(have[aura_id]))


func _add_aura(unit_id: int, aura_id: String, src: int) -> void:
	if unit_id < 0 or aura_id == "" or _auras.has("%d:%s" % [unit_id, aura_id]):
		return
	var vis: Dictionary = EffectsData.aura_visual(aura_id)
	if vis.is_empty() or not _known(unit_id):
		return
	var cc: bool = EffectsData.is_cc(aura_id)
	var mine: Array[Vfx] = []
	var prefix: String = "%d:" % unit_id
	for key: String in _auras:
		if key.begins_with(prefix):
			mine.append(_auras[key])
	if mine.size() >= int(budget.get("max_auras_per_unit", 4)):
		var drop: Vfx = null  # the oldest non-CC visual makes room for crowd control
		for v: Vfx in mine:
			if not v.cc and (drop == null or v.age > drop.age):
				drop = v
		if not cc or drop == null:
			return  # over the cap; the view retries every tick, so this is not counted as a drop
		_remove_aura(unit_id, drop.aura)
	var vfx: Vfx = EffectLibrary.aura(str(vis["style"]), str(vis["school"]), float(vis.get("size", 1.0)))
	vfx.ability = str(vis["ability"])
	vfx.aura = aura_id
	vfx.source = src
	vfx.unit = unit_id
	vfx.cc = cc
	vfx.priority = 6 if cc else 4
	if _admit(vfx):
		_auras["%d:%s" % [unit_id, aura_id]] = vfx
		_follow(vfx, 0.0)


func _remove_aura(unit_id: int, aura_id: String) -> void:
	var key: String = "%d:%s" % [unit_id, aura_id]
	var vfx: Vfx = _auras.get(key, null)
	if vfx == null:
		return
	_auras.erase(key)
	_stop(vfx)


# ================================================================ previews

## Every stage of an ability at once, frozen at a representative moment, between two units of
## the current view (effects review scene; a spellbook later). Ground circles are drawn at most
## `ground_cap` m wide (0: the ability's radius) so a grid of previews does not overlap.
func preview_ability(ability: String, src: int, tgt: int, ground_cap: float = 0.0) -> Array[Vfx]:
	var out: Array[Vfx] = []
	var e: Dictionary = EffectsData.entry(ability)
	var ab: Dictionary = Data.abilities.get(ability, {})
	if e.is_empty() or ab.is_empty():
		return out
	var school: String = EffectsData.school_of(ability)
	budget = {"max_effects": 100000, "max_particles": 10000000, "max_auras_per_unit": 8, "max_impacts_per_tick": 100000}  # previews are never dropped
	if e.has("cast"):
		_start_cast(src, ability, 10.0)
		_hold(_casts.get(src, null), 0.5, out)
	var imp: Dictionary = e.get("impact", {})
	if e.has("projectile"):
		_launch(e, ability, school, src, tgt)
		var shot: Vfx = active.back()
		var a: Vector3 = shot.global_position
		var b: Vector3 = anchor_position(tgt, "chest")
		shot.data["flying"] = false
		shot.global_position = a.lerp(b, 0.55)
		_aim(shot, b)
		_hold(shot, 0.2, out)
	if not imp.is_empty():
		var who: int = src if str(imp.get("at", "target")) == "self" or tgt < 0 else tgt
		_hold(_impact(imp, ability, school, src, who), {"spark": 0.06, "rays": 0.2, "hail": 0.2}.get(str(imp["style"]), 0.12), out)
	if e.has("ground"):
		var g: Dictionary = e["ground"]
		var r: float = maxf(EffectsData.radius_of(ability), 0.5)
		var vfx: Vfx = EffectLibrary.ground(str(g["style"]), school, minf(r, ground_cap) if ground_cap > 0.0 else r,
			is_hostile(src), 1.0)
		vfx.ability = ability
		vfx.source = src
		_admit(vfx)
		var centre: int = tgt if str(g.get("center", "caster")) == "target" and tgt >= 0 else src
		var p: Vector3 = anchor_position(centre, "feet")
		vfx.global_position = Vector3(p.x, 0.0, p.z)
		_hold(vfx, 0.4, out)
	if e.has("melee"):
		_release({"melee": e["melee"]}, ability, src, tgt)
		_hold(active.back(), 0.11, out)
	if e.has("displacement"):
		var to: Vector3 = anchor_position(src, "feet")
		var from: Vector3 = to - Movement.forward_of(float(_facings.get(src, 0.0))) * 2.5
		var vfx: Vfx = EffectLibrary.displacement(str(e["displacement"]["style"]), school, from, to)
		var pos: Vector3 = vfx.position
		var rot: Vector3 = vfx.rotation
		_admit(vfx)
		vfx.global_position = pos
		vfx.global_rotation = rot
		_hold(vfx, 0.15, out)
	for eff: Dictionary in ab.get("effects", []):
		if eff["type"] != "apply_aura":
			continue
		var on_self: bool = ab["target"] == "self" and str(eff.get("affects", "target")) in ["target", "self"]
		var who: int = src if on_self or tgt < 0 else tgt
		_add_aura(who, str(eff["aura"]), src)
		_hold(aura_vfx(who, str(eff["aura"])), 1.0, out)
	return out


func _hold(vfx: Vfx, t: float, out: Array[Vfx]) -> void:
	if vfx == null:
		return
	_follow(vfx, 0.0)
	vfx.set_hold(t)
	out.append(vfx)


# ================================================================ bookkeeping

## The player's graphics and accessibility settings on a new effect (M2-13): fewer particles at
## lower density, other players' effects fainter, flashes softer when flashing is reduced.
func _apply_settings(vfx: Vfx) -> void:
	var density: float = clampf(float(Settings.get_value("graphics.particle_density", 1.0)), 0.1, 1.0)
	if density < 1.0:
		vfx.amount = 0
		for p: GPUParticles3D in vfx.emitters:
			p.amount = maxi(1, roundi(p.amount * density))
			vfx.amount += p.amount
	if vfx.source != my_id and my_id >= 0:
		vfx.opacity *= clampf(float(Settings.get_value("graphics.others_effect_opacity", 1.0)), 0.0, 1.0)
	if vfx.style == "flash" and bool(Settings.get_value("accessibility.reduce_flashing", false)):
		vfx.opacity *= 0.4


## Add an effect if the budget allows (replacing a lower-priority one if needed).
func _admit(vfx: Vfx) -> bool:
	_apply_settings(vfx)
	var max_effects: int = int(budget.get("max_effects", 200))
	var max_particles: int = int(budget.get("max_particles", 4000))
	while active.size() >= max_effects or particles_live + vfx.amount > max_particles:
		var victim: int = -1
		for i: int in active.size():
			var a: Vfx = active[i]
			if a.priority < vfx.priority and (victim == -1 or a.priority < active[victim].priority
					or (a.priority == active[victim].priority and a.age > active[victim].age)):
				victim = i
		if victim == -1:
			dropped += 1
			vfx.free()
			return false
		_free_at(victim)
	add_child(vfx)
	active.append(vfx)
	particles_live += vfx.amount
	spawned += 1
	return true


func _stop(vfx: Vfx) -> void:
	vfx.stop()


func _free_at(i: int) -> void:
	var vfx: Vfx = active[i]
	active.remove_at(i)
	particles_live -= vfx.amount
	if _casts.get(vfx.source, null) == vfx:
		_casts.erase(vfx.source)
	if vfx.aura != "" and _auras.get("%d:%s" % [vfx.unit, vfx.aura], null) == vfx:
		_auras.erase("%d:%s" % [vfx.unit, vfx.aura])
	vfx.queue_free()


## Keep an effect on its unit (and fly projectiles).
func _follow(vfx: Vfx, delta: float) -> void:
	if vfx.kind == Vfx.Kind.PROJECTILE:
		_fly(vfx, delta)
		return
	if vfx.unit < 0 or not _known(vfx.unit):
		return
	vfx.global_position = anchor_position(vfx.unit, vfx.anchor)
	if vfx.follow_yaw:
		var root: Node3D = _root_of(vfx.unit)
		vfx.global_rotation = Vector3(0.0, root.global_rotation.y if root != null and root.is_inside_tree()
			else float(_facings.get(vfx.unit, 0.0)), 0.0)
	for part: Dictionary in vfx.parts:
		(part["node"] as Node3D).global_position = anchor_position(vfx.unit, str(part["anchor"]))


func _fly(vfx: Vfx, delta: float) -> void:
	if not bool(vfx.data.get("flying", false)):
		return
	var tgt: int = int(vfx.data["target"])
	if not _known(tgt):
		vfx.data["flying"] = false
		vfx.stop()
		return
	var aim: Vector3 = anchor_position(tgt, "chest")
	var to: Vector3 = aim - vfx.global_position
	var step: float = float(vfx.data["speed"]) * delta
	if to.length() <= maxf(step, 0.05):
		vfx.global_position = aim
		vfx.data["flying"] = false
		vfx.data["arrived"] = true
		vfx.stop()
		for g: GeometryInstance3D in vfx.faders:
			g.visible = false  # the core vanishes at once; the trail lingers
		var imp: Dictionary = vfx.data.get("impact", {})
		if not imp.is_empty() and str(imp.get("at", "target")) == "target":
			_impact(imp, vfx.ability, vfx.school, vfx.source, tgt)
		return
	vfx.global_position += to.normalized() * step
	_aim(vfx, aim)


func _aim(vfx: Vfx, at: Vector3) -> void:
	var d: Vector3 = at - vfx.global_position
	if d.length() > 0.01 and absf(d.normalized().dot(Vector3.UP)) < 0.999:
		vfx.look_at(at, Vector3.UP)


func _known(unit_id: int) -> bool:
	return _positions.has(unit_id) or _root_of(unit_id) != null


func _root_of(unit_id: int) -> Node3D:
	if renderer == null:
		return null
	var e: Dictionary = renderer.units.get(unit_id, {})
	return e.get("root", null) if not e.is_empty() else null


## Hand bone position of a unit's character, or INF (no skeleton).
func _hand_position(unit_id: int, hand: String, root: Node3D) -> Vector3:
	if root == null or not root.is_inside_tree():
		return Vector3.INF
	if not _skeletons.has(unit_id):
		var sk: Skeleton3D = CharacterRig.skeleton_of(root)
		_skeletons[unit_id] = {} if sk == null else {"sk": sk, "hand_r": sk.find_bone("hand_r"), "hand_l": sk.find_bone("hand_l")}
	var s: Dictionary = _skeletons[unit_id]
	if s.is_empty() or int(s[hand]) < 0 or not is_instance_valid(s["sk"]):
		return Vector3.INF
	var sk: Skeleton3D = s["sk"]
	var t: Transform3D = sk.global_transform * sk.get_bone_global_pose(int(s[hand]))
	return t.origin + t.basis.y.normalized() * 0.09  # palm, a little past the wrist


## The ability a unit last released (charge and teleport events do not name it).
func _last_release_of(src: int) -> String:
	for i: int in range(_recent.size() - 1, -1, -1):
		if int(_recent[i][0]) == src:
			return str(_recent[i][1])
	return ""
