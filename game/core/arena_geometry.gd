class_name ArenaGeometry
extends RefCounted
## Static arena blockers from map data (circles and boxes on the ground plane) plus the square
## bounds. Pure math, no physics engine, so server, client prediction and tests agree exactly.
## Ground-plane coordinates: x and z; y is up.

const UNIT_RADIUS: float = 0.45  ## collision radius of a player

var bounds_half: float = 20.0
var circles: Array[Dictionary] = []  ## {center: Vector2, home: Vector2, radius, height, los, tag, moving}
var boxes: Array[Dictionary] = []  ## {min: Vector2, max: Vector2, height: float, los: bool, gate: bool}
var gates_open: bool = true  ## gate boxes block only while closed (arena preparation phase)
var removed_tags: Dictionary = {}  ## collider tags a twist has taken away (ArenaTwists); they block nothing
var flood: Dictionary = {}  ## a flood twist in effect: {"slow", "dry": Array[Rect2]} (ArenaTwists), or {}

const WADE_HEIGHT: float = 0.3  ## a unit higher than this (mid-jump) is above the water


## The map's twists as of `seconds` of match time: what collapses took away, any flood, and where
## rotating colliders have turned to (they are "moving" once their twist has started).
func apply_twists(twists: Array, seconds: float) -> void:
	removed_tags = ArenaTwists.removed_tags(twists, seconds)
	flood = ArenaTwists.active_flood(twists, seconds)
	for t: Dictionary in twists:
		if str(t.get("type", "")) != "rotate":
			continue
		var tags: Array = t.get("tags", [])
		var moving: bool = ArenaTwists.stage(t, seconds) == ArenaTwists.Stage.DONE
		for c: Dictionary in circles:
			if c["tag"] in tags:
				c["center"] = ArenaTwists.rotated(t, c["home"], seconds)
				c["moving"] = moving


## Movement speed multiplier of the ground at `pos`: a flood's slow in the water, else 1.
func ground_speed(pos: Vector3) -> float:
	if flood.is_empty() or pos.y > WADE_HEIGHT:
		return 1.0
	var p: Vector2 = Vector2(pos.x, pos.z)
	for r: Rect2 in flood["dry"]:
		if r.has_point(p):
			return 1.0
	return float(flood["slow"])


static func from_map(map: Dictionary) -> ArenaGeometry:
	var g: ArenaGeometry = ArenaGeometry.new()
	g.bounds_half = float(map.get("bounds_half_m", 20.0))
	for c: Dictionary in map.get("colliders", []):
		var h: float = float(c.get("height", 4.0))
		var los: bool = bool(c.get("blocks_los", true))
		if c["type"] == "circle":
			var at: Vector2 = Vector2(c["center"][0], c["center"][1])
			g.circles.append({"center": at, "home": at, "radius": float(c["radius"]), "height": h, "los": los,
				"tag": str(c.get("tag", "")), "moving": false})
		else:
			g.boxes.append({"min": Vector2(c["min"][0], c["min"][1]),
				"max": Vector2(c["max"][0], c["max"][1]), "height": h, "los": los,
				"gate": bool(c.get("gate", false)), "tag": str(c.get("tag", ""))})
	return g


## True while a circle or box blocks anything: not taken away by a twist, and not an open gate.
func stands(c: Dictionary) -> bool:
	return not removed_tags.has(c.get("tag", "")) and not (bool(c.get("gate", false)) and gates_open)


## The tag of a turning collider that has moved into a unit standing at `pos` (it will push the
## unit out on its next move), or "" when none overlaps it by more than 1 cm.
func moving_overlap(pos: Vector3) -> String:
	var p: Vector2 = Vector2(pos.x, pos.z)
	for c: Dictionary in circles:
		if not bool(c["moving"]) or pos.y >= c["height"] or removed_tags.has(c["tag"]):
			continue
		var min_dist: float = c["radius"] + UNIT_RADIUS - 0.01
		if (p - c["center"]).length_squared() < min_dist * min_dist:
			return str(c["tag"])
	return ""


## Push a unit position out of every blocker and back inside the bounds.
func resolve(pos: Vector3) -> Vector3:
	var p: Vector2 = Vector2(pos.x, pos.z)
	for c: Dictionary in circles:
		if pos.y >= c["height"] or removed_tags.has(c["tag"]):
			continue
		var d: Vector2 = p - c["center"]
		var min_dist: float = c["radius"] + UNIT_RADIUS
		if d.length_squared() < min_dist * min_dist:
			p = c["center"] + (d.normalized() if d.length_squared() > 1e-12 else Vector2.RIGHT) * min_dist
	for b: Dictionary in boxes:
		if pos.y >= b["height"] or (b["gate"] and gates_open) or removed_tags.has(b["tag"]):
			continue
		var lo: Vector2 = b["min"] - Vector2.ONE * UNIT_RADIUS
		var hi: Vector2 = b["max"] + Vector2.ONE * UNIT_RADIUS
		if p.x > lo.x and p.x < hi.x and p.y > lo.y and p.y < hi.y:
			# push out along the axis of least penetration
			var push: Array[float] = [p.x - lo.x, hi.x - p.x, p.y - lo.y, hi.y - p.y]
			var i: int = push.find(push.min())
			match i:
				0: p.x = lo.x
				1: p.x = hi.x
				2: p.y = lo.y
				3: p.y = hi.y
	var lim: float = bounds_half - UNIT_RADIUS
	p.x = clampf(p.x, -lim, lim)
	p.y = clampf(p.y, -lim, lim)
	return Vector3(p.x, pos.y, p.y)


## True when nothing that blocks line of sight lies between two eye/chest points.
## Tested on the ground plane against blockers taller than the lower of the two points.
func has_line_of_sight(from: Vector3, to: Vector3) -> bool:
	var a: Vector2 = Vector2(from.x, from.z)
	var b: Vector2 = Vector2(to.x, to.z)
	var low: float = minf(from.y, to.y)
	for c: Dictionary in circles:
		if c["los"] and c["height"] > low and not removed_tags.has(c["tag"]) and _segment_hits_circle(a, b, c["center"], c["radius"]):
			return false
	for bx: Dictionary in boxes:
		if (bx["gate"] and gates_open) or removed_tags.has(bx["tag"]):
			continue
		if bx["los"] and bx["height"] > low and _segment_hits_box(a, b, bx["min"], bx["max"]):
			return false
	return true


static func _segment_hits_circle(a: Vector2, b: Vector2, center: Vector2, radius: float) -> bool:
	var ab: Vector2 = b - a
	var t: float = 0.0
	if ab.length_squared() > 1e-12:
		t = clampf((center - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return (a + ab * t).distance_squared_to(center) < radius * radius


static func _segment_hits_box(a: Vector2, b: Vector2, lo: Vector2, hi: Vector2) -> bool:
	# Liang-Barsky clipping of the segment against the box
	var t0: float = 0.0
	var t1: float = 1.0
	var d: Vector2 = b - a
	for axis: int in 2:
		var p0: float = a[axis]
		var dv: float = d[axis]
		if absf(dv) < 1e-12:
			if p0 < lo[axis] or p0 > hi[axis]:
				return false
			continue
		var ta: float = (lo[axis] - p0) / dv
		var tb: float = (hi[axis] - p0) / dv
		if ta > tb:
			var tmp: float = ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return false
	return true
