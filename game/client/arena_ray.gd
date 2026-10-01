class_name ArenaRay
extends RefCounted
## Ray and sphere casts against an arena's blockers in 3D (backlog M1-23): the camera pulls in
## in front of walls and pillars, and a click cannot select a unit through a wall.
## Uses the same map colliders as the server (ArenaGeometry: pillars as upright cylinders, walls,
## gallows and closed gates as boxes, each with its height) plus the floor and the perimeter walls
## MapBuilder puts around the bounds. Pure math like ArenaGeometry, so it needs no physics
## frame and gives the same answer in tests and in game.

const NO_HIT: float = INF
const DEPTH_M: float = 1000.0  ## blockers reach this far below the floor (a floor-level ray still hits)


## Distance along `dir` (normalized) from `origin` to the first blocker a sphere of `radius`
## would touch, or `max_dist` when nothing is closer. With `with_floor` the ground plane (y = 0)
## counts too. Starting inside a blocker returns 0.
static func cast(geometry: ArenaGeometry, origin: Vector3, dir: Vector3, max_dist: float,
		radius: float = 0.0, with_floor: bool = true) -> float:
	var best: float = max_dist
	if with_floor and dir.y < -1e-9:
		var tf: float = (radius - origin.y) / dir.y
		best = minf(best, maxf(tf, 0.0))
	if geometry == null:
		return best
	for c: Dictionary in geometry.circles:
		if not geometry.stands(c):
			continue
		var center: Vector2 = c["center"]
		best = minf(best, _cylinder(origin, dir, center, float(c["radius"]) + radius, float(c["height"]) + radius))
	for b: Dictionary in geometry.boxes:
		if not geometry.stands(b):
			continue
		var lo: Vector2 = b["min"]
		var hi: Vector2 = b["max"]
		best = minf(best, _box(origin, dir, Vector3(lo.x - radius, -DEPTH_M, lo.y - radius),
			Vector3(hi.x + radius, float(b["height"]) + radius, hi.y + radius)))
	# the perimeter walls MapBuilder builds just outside the bounds (1 m thick)
	var h: float = geometry.bounds_half
	var top: float = MapBuilder.PERIMETER_HEIGHT + radius
	var outer: float = h + 1.0 + radius
	var inner: float = h - radius
	best = minf(best, _box(origin, dir, Vector3(inner, -DEPTH_M, -outer), Vector3(outer, top, outer)))
	best = minf(best, _box(origin, dir, Vector3(-outer, -DEPTH_M, -outer), Vector3(-inner, top, outer)))
	best = minf(best, _box(origin, dir, Vector3(-outer, -DEPTH_M, inner), Vector3(outer, top, outer)))
	best = minf(best, _box(origin, dir, Vector3(-outer, -DEPTH_M, -outer), Vector3(outer, top, -inner)))
	return best


## Entry distance of a ray into an upright cylinder (from far below the floor up to `top`), or
## NO_HIT. 0 when the origin is inside.
static func _cylinder(o: Vector3, d: Vector3, center: Vector2, r: float, top: float) -> float:
	var ox: float = o.x - center.x
	var oz: float = o.z - center.y
	var inside_xz: bool = ox * ox + oz * oz <= r * r
	if inside_xz and o.y <= top:
		return 0.0
	var best: float = NO_HIT
	# side wall
	var a: float = d.x * d.x + d.z * d.z
	if a > 1e-12 and not inside_xz:
		var b: float = 2.0 * (ox * d.x + oz * d.z)
		var c: float = ox * ox + oz * oz - r * r
		var disc: float = b * b - 4.0 * a * c
		if disc >= 0.0:
			var t: float = (-b - sqrt(disc)) / (2.0 * a)
			if t >= 0.0 and o.y + d.y * t <= top:
				best = t
	# top cap, entered from above
	if o.y > top and d.y < -1e-9:
		var tc: float = (top - o.y) / d.y
		var px: float = ox + d.x * tc
		var pz: float = oz + d.z * tc
		if px * px + pz * pz <= r * r:
			best = minf(best, tc)
	return best


## Entry distance of a ray into an axis-aligned box (slab method), or NO_HIT; 0 when inside.
static func _box(o: Vector3, d: Vector3, lo: Vector3, hi: Vector3) -> float:
	var t0: float = -INF
	var t1: float = INF
	for axis: int in 3:
		if absf(d[axis]) < 1e-12:
			if o[axis] < lo[axis] or o[axis] > hi[axis]:
				return NO_HIT
			continue
		var ta: float = (lo[axis] - o[axis]) / d[axis]
		var tb: float = (hi[axis] - o[axis]) / d[axis]
		if ta > tb:
			var tmp: float = ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return NO_HIT
	if t1 < 0.0:
		return NO_HIT
	return maxf(t0, 0.0)


## Distance along the ray to an upright capsule standing at `base` (feet), or NO_HIT.
static func capsule(o: Vector3, d: Vector3, base: Vector3, height: float, r: float) -> float:
	var y0: float = base.y + r
	var y1: float = base.y + maxf(height - r, r)
	var best: float = NO_HIT
	var ox: float = o.x - base.x
	var oz: float = o.z - base.z
	var a: float = d.x * d.x + d.z * d.z
	if a > 1e-12:
		var b: float = 2.0 * (ox * d.x + oz * d.z)
		var c: float = ox * ox + oz * oz - r * r
		var disc: float = b * b - 4.0 * a * c
		if disc >= 0.0:
			var t: float = (-b - sqrt(disc)) / (2.0 * a)
			var y: float = o.y + d.y * t
			if t >= 0.0 and y >= y0 and y <= y1:
				best = t
	for cy: float in [y0, y1]:
		best = minf(best, _sphere(o, d, Vector3(base.x, cy, base.z), r))
	return best


static func _sphere(o: Vector3, d: Vector3, center: Vector3, r: float) -> float:
	var oc: Vector3 = o - center
	var b: float = oc.dot(d)
	var c: float = oc.length_squared() - r * r
	var disc: float = b * b - c
	if disc < 0.0:
		return NO_HIT
	var t: float = -b - sqrt(disc)
	return t if t >= 0.0 else NO_HIT
