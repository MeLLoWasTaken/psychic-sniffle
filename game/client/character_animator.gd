class_name CharacterAnimator
extends Node
## Drives one character's animation from the world view and combat events (backlog M1-24).
## The clips come from the character's AnimationPlayer (CharacterRig.setup: the body build's
## library with hold variants); which clip plays when, and the fade times, come from
## data/anim_states/<set>.json. No code branches per class or ability: abilities are sorted
## into actions (cast, channel, release, melee, ranged, none) by the data's rules.
##
## The AnimationTree, built in code (bottom to top):
##   loco        BlendSpace2D on facing-relative velocity (x right, y forward, 1 = full speed):
##               "stand" (BlendSpace1D idle <-> combat idle) at the centre, run, backpedal and
##               strafes around it
##   loco_speed  TimeScale: moving clips play at ground speed / full speed, within limits
##   jump        OneShot fired on take-off
##   upper       Blend2 filtered to spine and above: the action layer (act_upper) while moving
##   lower       Blend2 filtered to pelvis and legs: the same action (act_lower) when standing,
##               so casts and swings are full-body at rest and upper-body on the run
##   override    Blend2 over everything: stunned, feared run, death, victory (ov)
## act_upper and act_lower are Transitions with the same inputs, always requested together, so
## they stay in step.
##
## The tree is advanced manually by update(), so a paused scene holds its pose and headless
## tests are deterministic.
##   var anim: CharacterAnimator = CharacterAnimator.create(player, unit_id, team)
##   anim.push_event(ev)                       # combat events (cast_success, damage)
##   anim.update(unit_view, view, velocity, delta)

const TREE_NAME: String = "AnimationTree"

var states: Dictionary = {}  ## data/anim_states/<set>.json
var player: AnimationPlayer
var tree: AnimationTree
var unit_id: int = -1
var team: int = -1

## Logical state (tests, debugging). `state()` is the clip that dominates the pose.
var locomotion: String = ""  ## stand clip, moving clip nearest the blend position, or the jump clip
var action: String = ""  ## clip of the action layer, "" for locomotion only
var action_kind: String = ""  ## cast, channel, release, melee, ranged, hit
var override: String = ""  ## crowd control, death or victory clip, or ""
var blend_position: Vector2 = Vector2.ZERO  ## smoothed locomotion blend position
var blend_target: Vector2 = Vector2.ZERO
var time_scale: float = 1.0  ## playback speed of the moving clips
var in_combat: bool = false
var airborne: bool = false
var state_changes: int = 0  ## how often the visible state changed (see _key)
var seen_states: Dictionary = {}  ## every clip state() has returned (checks)

var stand_blend: float = 0.0  ## 0 idle .. 1 combat idle
var upper_weight: float = 0.0
var lower_weight: float = 0.0
var override_weight: float = 0.0

var _fades: Dictionary = {}
var _clock: float = 0.0
var _events: Array = []
var _action_started: float = 0.0
var _action_length: float = INF
var _action_priority: int = 0
var _action_min: float = 0.0
var _melee_index: int = 0
var _last_melee: float = -INF
var _last_hit: float = -INF
var _last_damage: float = -INF
var _max_health: float = 1.0
var _last_velocity: Vector3 = Vector3.ZERO
var _melee_m: float = 5.0
var _run_speed: float = 7.0
var _backpedal_mult: float = 0.6
var _act_upper: AnimationNodeTransition
var _act_lower: AnimationNodeTransition
var _ov: AnimationNodeTransition
var _action_inputs: PackedStringArray = []
var _override_inputs: PackedStringArray = []


## Adds an animator (and its AnimationTree) next to `p_player` under the same model. `set_id`
## names data/anim_states/<set>.json (the animation set's id). Returns null without data.
static func create(p_player: AnimationPlayer, p_unit_id: int, p_team: int, set_id: String = "humanoid") -> CharacterAnimator:
	if p_player == null or not Data.anim_states.has(set_id):
		Log.error("character_animator: no animation states '%s'" % set_id)
		return null
	var a: CharacterAnimator = CharacterAnimator.new()
	a.name = "CharacterAnimator"
	a.unit_id = p_unit_id
	a.team = p_team
	a.states = Data.anim_states[set_id]
	a.player = p_player
	p_player.get_parent().add_child(a)
	a._build()
	return a


## The action an ability plays (cast, channel, release, melee, ranged or none): its override,
## else the first rule of the states data whose conditions all hold.
static func ability_action(st: Dictionary, ab: Dictionary, melee_m: float) -> String:
	if ab.is_empty():
		return "none"
	var overrides: Dictionary = st.get("ability_overrides", {})
	if overrides.has(ab.get("id", "")):
		return str(overrides[ab["id"]])
	for rule: Dictionary in st.get("ability_rules", []):
		if _rule_matches(rule["when"], ab, melee_m):
			return str(rule["action"])
	return "none"


static func _rule_matches(when: Dictionary, ab: Dictionary, melee_m: float) -> bool:
	for key: String in ["cast_type", "school", "target"]:
		if when.has(key) and not str(ab.get(key, "")) in when[key]:
			return false
	if when.has("effect"):
		var found: bool = false
		for e: Dictionary in ab.get("effects", []):
			found = found or str(e.get("type", "")) in when["effect"]
		if not found:
			return false
	if when.has("range"):
		var r: float = float(ab.get("range_m", 0.0))
		var ok: bool = (r > 0.0 and r <= melee_m) if when["range"] == "melee" else r > melee_m
		if not ok:
			return false
	return true


## The clip that dominates the pose now: the override, else the action, else locomotion.
func state() -> String:
	if override != "":
		return override
	return action if action != "" else locomotion


## The release clip for a school: "<release>_<school>" when the library has it (by_school).
func release_clip(school: String) -> String:
	var rel: Dictionary = states["actions"]["release"]
	var own: String = "%s_%s" % [rel["clip"], school]
	return own if bool(rel.get("by_school", false)) and player.has_animation(own) else str(rel["clip"])


## Queue a combat event (MatchRunner.take_events / the client's event stream); applied at the
## next update(). Events about other units are ignored.
func push_event(ev: Dictionary) -> void:
	if int(ev.get("source", -1)) == unit_id or int(ev.get("target", -1)) == unit_id:
		_events.append(ev)


## Advance by `delta` seconds: `u` is this unit's entry of the world view, `view` the whole view
## (targets, match state), `velocity` the unit's ground velocity in m/s.
func update(u: Dictionary, view: Dictionary, velocity: Vector3, delta: float) -> void:
	_clock += delta
	_max_health = maxf(1.0, float(u.get("max_health", _max_health)))
	var before: String = _key()
	_update_override(u, view)
	for ev: Dictionary in _events:
		_on_event(ev)
	_events.clear()
	in_combat = _in_combat(u, view)
	_update_locomotion(u, velocity, delta)
	if override == "":
		_update_cast(u)
		if action != "" and _clock - _action_started >= _action_length:
			_stop_action()
	_apply(delta)
	if _key() != before:
		state_changes += 1
	seen_states[state()] = true
	tree.advance(delta)


## What counts as a state change: the override while one applies (whatever runs beneath it),
## else the action and locomotion.
func _key() -> String:
	return "!" + override if override != "" else "%s|%s" % [action, locomotion]


# ================================================================== state logic

func _update_override(u: Dictionary, view: Dictionary) -> void:
	var clip: String = ""
	var m: Dictionary = view.get("match", {})
	if int(u.get("health", 1)) <= 0:
		clip = str(states["death"])
	elif int(m.get("phase", -1)) == ArenaMatch.Phase.ENDED and int(m.get("winner", -1)) == team:
		clip = str(states["victory"])
	else:
		var cc: Dictionary = states["crowd_control"]
		var cats: Dictionary = {}
		for a: Dictionary in u.get("auras", []):
			cats[str(Data.auras.get(str(a.get("id", "")), {}).get("cc_category", "none"))] = true
		for cat: String in cc:  # data order decides when several apply (stun before fear)
			if cats.has(cat):
				clip = str(cc[cat])
				break
	if clip != "" and not player.has_animation(clip):
		clip = ""
	if clip == override:
		return
	override = clip
	if clip == "":
		return
	_stop_action()
	_ov.xfade_time = 0.0 if override_weight < 0.01 else float(_fades["override_xfade_s"])
	tree.set("parameters/ov/transition_request", clip)


func _on_event(ev: Dictionary) -> void:
	var t: String = str(ev.get("type", ""))
	var mine: bool = int(ev.get("source", -1)) == unit_id
	if t == "damage":
		_last_damage = _clock
		if mine and str(ev.get("ability", "")) == "auto_attack":
			_play_kind(str(states["auto_attack"]), {})
		elif not mine and int(ev.get("target", -1)) == unit_id:
			var hit: Dictionary = states["actions"]["hit"]
			var big: bool = float(ev.get("amount", 0)) + float(ev.get("absorbed", 0)) >= _max_health * float(hit["min_damage_pct"]) / 100.0
			if big and _clock - _last_hit >= float(hit["cooldown_s"]) and override == "":
				if _try_start("hit", str(hit["clip"]), hit):
					_last_hit = _clock
	elif t == "cast_success" and mine:
		var ab: Dictionary = Data.abilities.get(str(ev.get("ability", "")), {})
		var kind: String = ability_action(states, ab, _melee_m)
		if kind == "cast":
			kind = "release"  # the cast bar finished: its release plays
		_play_kind(kind, ab)


## Start the action for an ability's kind (release, melee, ranged); casts and channels are
## driven by the view's cast instead.
func _play_kind(kind: String, ab: Dictionary) -> void:
	if override != "":
		return
	var acts: Dictionary = states["actions"]
	match kind:
		"release":
			_try_start("release", release_clip(str(ab.get("school", ""))), acts["release"])
		"ranged":
			_try_start("ranged", str(acts["ranged"]["clip"]), acts["ranged"])
		"melee":
			var melee: Dictionary = acts["melee"]
			var cycle: Array = melee["cycle"]
			if _clock - _last_melee > float(melee["reset_s"]):
				_melee_index = 0
			if _try_start("melee", str(cycle[_melee_index % cycle.size()]), melee):
				_melee_index += 1
				_last_melee = _clock


func _update_cast(u: Dictionary) -> void:
	var cast: Dictionary = u.get("cast", {})
	var acts: Dictionary = states["actions"]
	if cast.is_empty():
		if action_kind in ["cast", "channel"]:
			_stop_action()  # ended without a release: interrupted, failed, moved, channel done
		return
	if bool(cast.get("channel", false)):
		if action_kind != "channel":
			_try_start("channel", str(acts["channel"]["loop"]), acts["channel"])
		return
	var c: Dictionary = acts["cast"]
	if action_kind != "cast":
		_try_start("cast", str(c["start"]), c)
	elif action == str(c["start"]) and _clock - _action_started >= _action_length:
		_play_action("cast", str(c["loop"]), c)  # the start pose flows into the held loop


func _update_locomotion(u: Dictionary, velocity: Vector3, delta: float) -> void:
	var loco: Dictionary = states["locomotion"]
	var flat: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() > float(loco["teleport_min_mps"]):
		flat = _last_velocity  # a blink or correction, not running
	_last_velocity = flat
	var speed: float = flat.length()
	var facing: float = float(u.get("facing", 0.0))
	blend_target = Vector2.ZERO
	var ratio: float = 1.0
	if speed >= float(loco["moving_min_mps"]):
		blend_target = Vector2(flat.dot(Movement.right_of(facing)), flat.dot(Movement.forward_of(facing))) / speed
		var full: float = _run_speed * (_backpedal_mult if blend_target.y < -0.2 else 1.0)
		ratio = speed / full
	var tau: float = float(_fades["blend_smoothing_s"])
	var keep: float = exp(-delta / tau) if tau > 0.0 else 0.0
	blend_position = blend_target + (blend_position - blend_target) * keep
	time_scale = clampf(ratio, float(loco["speed_scale"]["min"]), float(loco["speed_scale"]["max"]))
	var pos: Vector3 = u.get("position", Vector3.ZERO)
	var was_airborne: bool = airborne
	airborne = pos.y > float(loco["airborne_min_height_m"])
	if airborne and not was_airborne and player.has_animation(str(loco["jump"])):
		tree.set("parameters/jump/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	if airborne:
		locomotion = str(loco["jump"])
	elif blend_target == Vector2.ZERO:
		locomotion = str(loco["combat_stand"] if in_combat else loco["stand"])
	else:
		var best: float = -INF
		for clip: String in loco["directions"]:
			var d: Array = loco["directions"][clip]
			var dot: float = Vector2(float(d[0]), float(d[1])).normalized().dot(blend_target)
			if dot > best:
				best = dot
				locomotion = clip


## In combat (combat idle): casting, damage dealt or taken within recent_damage_s, or a living
## hostile target within hostile_target_within_m.
func _in_combat(u: Dictionary, view: Dictionary) -> bool:
	var c: Dictionary = states["combat"]
	if not (u.get("cast", {}) as Dictionary).is_empty() or _clock - _last_damage <= float(c["recent_damage_s"]):
		return true
	var tid: int = int(u.get("target_id", -1))
	if tid < 0:
		return false
	for other: Dictionary in view.get("units", []):
		if int(other["id"]) == tid:
			var p: Vector3 = other["position"]
			var me: Vector3 = u.get("position", Vector3.ZERO)
			return int(other["team"]) != team and int(other.get("health", 0)) > 0 \
				and Vector2(p.x - me.x, p.z - me.z).length() <= float(c["hostile_target_within_m"])
	return false


## Start an action unless a stronger one is playing, or an equal one has played less than its
## min_s. Returns whether it started.
func _try_start(kind: String, clip: String, spec: Dictionary) -> bool:
	if not clip in _action_inputs:
		return false
	var prio: int = int(spec.get("priority", 0))
	if action != "" and (prio < _action_priority or (prio == _action_priority and _clock - _action_started < _action_min)):
		return false
	_play_action(kind, clip, spec)
	return true


func _play_action(kind: String, clip: String, spec: Dictionary) -> void:
	var xfade: float = 0.0 if maxf(upper_weight, lower_weight) < 0.01 else float(_fades["action_xfade_s"])
	_act_upper.xfade_time = xfade
	_act_lower.xfade_time = xfade
	tree.set("parameters/act_upper/transition_request", clip)
	tree.set("parameters/act_lower/transition_request", clip)
	action = clip
	action_kind = kind
	_action_started = _clock
	var anim: Animation = player.get_animation(clip)
	_action_length = INF if anim.loop_mode != Animation.LOOP_NONE else anim.length
	_action_priority = int(spec.get("priority", 0))
	_action_min = float(spec.get("min_s", 0.0))


func _stop_action() -> void:
	action = ""
	action_kind = ""
	_action_priority = 0
	_action_length = INF


# ================================================================== tree

func _apply(delta: float) -> void:
	var has_action: bool = action != "" and override == ""
	var moving: bool = blend_target != Vector2.ZERO or blend_position.length() > 0.1 or airborne
	var f: Dictionary = _fades
	var up_target: float = 1.0 if has_action else 0.0
	upper_weight = _approach(upper_weight, up_target, delta,
		float(f["action_in_s"]) if up_target > upper_weight else float(f["action_out_s"]))
	var low_target: float = up_target if not moving else 0.0
	lower_weight = _approach(lower_weight, low_target, delta,
		float(f["full_body_s"]) if has_action else float(f["action_out_s"]))
	var ov_target: float = 1.0 if override != "" else 0.0
	override_weight = _approach(override_weight, ov_target, delta,
		float(f["override_in_s"]) if ov_target > override_weight else float(f["override_out_s"]))
	stand_blend = _approach(stand_blend, 1.0 if in_combat else 0.0, delta, float(f["stand_s"]))
	var moving_amount: float = clampf(blend_position.length(), 0.0, 1.0)
	tree.set("parameters/loco/blend_position", blend_position)
	tree.set("parameters/loco/stand/blend_position", stand_blend)
	tree.set("parameters/loco_speed/scale", lerpf(1.0, time_scale, moving_amount))
	tree.set("parameters/upper/blend_amount", upper_weight)
	tree.set("parameters/lower/blend_amount", lower_weight)
	tree.set("parameters/override/blend_amount", override_weight)


static func _approach(cur: float, target: float, delta: float, secs: float) -> float:
	if secs <= 0.0:
		return target
	return move_toward(cur, target, delta / secs)


func _build() -> void:
	_fades = states["fades"]
	_melee_m = float(Data.tuning.get("ranges", {}).get("melee_m", _melee_m))
	var mv: Dictionary = Data.tuning.get("movement", {})
	_run_speed = float(mv.get("run_speed_mps", _run_speed))
	_backpedal_mult = float(mv.get("backpedal_speed_mult", _backpedal_mult))
	var loco: Dictionary = states["locomotion"]
	var acts: Dictionary = states["actions"]
	var bt: AnimationNodeBlendTree = AnimationNodeBlendTree.new()

	var stand: AnimationNodeBlendSpace1D = AnimationNodeBlendSpace1D.new()
	stand.add_blend_point(_clip_node(str(loco["stand"])), 0.0, -1, &"idle")
	stand.add_blend_point(_clip_node(str(loco["combat_stand"])), 1.0, -1, &"combat")
	var space: AnimationNodeBlendSpace2D = AnimationNodeBlendSpace2D.new()
	space.add_blend_point(stand, Vector2.ZERO, -1, &"stand")
	for clip: String in loco["directions"]:
		var d: Array = loco["directions"][clip]
		space.add_blend_point(_clip_node(clip), Vector2(float(d[0]), float(d[1])), -1, StringName(clip))
	bt.add_node("loco", space)
	bt.add_node("loco_speed", AnimationNodeTimeScale.new())
	bt.connect_node("loco_speed", 0, "loco")

	var jump: AnimationNodeOneShot = AnimationNodeOneShot.new()
	jump.fadein_time = float(_fades["jump_in_s"])
	jump.fadeout_time = float(_fades["jump_out_s"])
	bt.add_node("jump", jump)
	bt.add_node("jump_clip", _clip_node(str(loco["jump"])))
	bt.connect_node("jump", 0, "loco_speed")
	bt.connect_node("jump", 1, "jump_clip")

	# action clips: every clip an action can name, plus the library's per-school releases
	var clips: Array[String] = [str(acts["cast"]["start"]), str(acts["cast"]["loop"]), str(acts["channel"]["loop"]),
		str(acts["release"]["clip"]), str(acts["ranged"]["clip"]), str(acts["hit"]["clip"])]
	for c: Variant in acts["melee"]["cycle"]:
		clips.append(str(c))
	for n: StringName in player.get_animation_list():
		if str(n).begins_with(str(acts["release"]["clip"]) + "_"):
			clips.append(str(n))
	for c: String in clips:
		if player.has_animation(c) and not c in _action_inputs:
			_action_inputs.append(c)
	_act_upper = _transition(bt, "act_upper", "u_", _action_inputs)
	_act_lower = _transition(bt, "act_lower", "l_", _action_inputs)
	var split: Dictionary = states["body_split"]
	bt.add_node("upper", _filtered_blend(split["upper"]))
	bt.connect_node("upper", 0, "jump")
	bt.connect_node("upper", 1, "act_upper")
	bt.add_node("lower", _filtered_blend(split["lower"]))
	bt.connect_node("lower", 0, "upper")
	bt.connect_node("lower", 1, "act_lower")

	for c: Variant in states["crowd_control"].values() + [states["death"], states["victory"]]:
		if player.has_animation(str(c)) and not str(c) in _override_inputs:
			_override_inputs.append(str(c))
	_ov = _transition(bt, "ov", "o_", _override_inputs)
	bt.add_node("override", AnimationNodeBlend2.new())
	bt.connect_node("override", 0, "lower")
	bt.connect_node("override", 1, "ov")
	bt.connect_node("output", 0, "override")

	player.stop()
	tree = AnimationTree.new()
	tree.name = TREE_NAME
	player.get_parent().add_child(tree)
	tree.anim_player = tree.get_path_to(player)  # the player's library and skeleton root
	tree.tree_root = bt
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	tree.active = true
	locomotion = str(loco["stand"])
	_apply(0.0)
	tree.advance(0.0)


func _clip_node(clip: String) -> AnimationNodeAnimation:
	var n: AnimationNodeAnimation = AnimationNodeAnimation.new()
	n.animation = clip
	return n


func _transition(bt: AnimationNodeBlendTree, node_name: String, prefix: String, inputs: PackedStringArray) -> AnimationNodeTransition:
	var tr: AnimationNodeTransition = AnimationNodeTransition.new()
	tr.allow_transition_to_self = true  # a second hit reaction restarts the clip
	for i: int in inputs.size():
		tr.add_input(inputs[i])
		tr.set_input_reset(i, true)
	bt.add_node(node_name, tr)
	for i: int in inputs.size():
		bt.add_node(prefix + inputs[i], _clip_node(inputs[i]))
		bt.connect_node(node_name, i, prefix + inputs[i])
	return tr


func _filtered_blend(bones: Array) -> AnimationNodeBlend2:
	var b: AnimationNodeBlend2 = AnimationNodeBlend2.new()
	b.filter_enabled = true
	for bone: Variant in bones:
		b.set_filter_path(NodePath(".:" + str(bone)), true)
	return b
