class_name NavGrid
extends RefCounted
## Navigation for bots (and later, click-to-move): a grid over the arena with cells blocked by
## colliders (inflated by the player radius), and A* paths with line-of-sight smoothing.

const CELL: float = 0.5
const BLOCK_MARGIN: float = 0.1  ## cells this close to a collider (beyond the unit radius) are blocked
const WALK_SLACK: float = 0.02  ## straight moves may pass this close to a collider without counting as blocked

var geometry: ArenaGeometry
var size: int
var origin: float
var blocked: PackedByteArray
var _astar: AStarGrid2D


func _init(p_geometry: ArenaGeometry) -> void:
	geometry = p_geometry
	origin = -geometry.bounds_half
	size = int(ceil(geometry.bounds_half * 2.0 / CELL))
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, size, size)
	_astar.cell_size = Vector2(CELL, CELL)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	rebuild()


## Re-mark blocked cells (call when gates open or close, or a twist changes the arena). Flooded
## cells cost more to cross by the inverse of the wading speed, so paths keep to dry ground when
## it is not much longer (M2-09).
func rebuild() -> void:
	for x: int in size:
		for z: int in size:
			var p: Vector3 = cell_center(Vector2i(x, z))
			_astar.set_point_solid(Vector2i(x, z), _blocked_at(p))
			_astar.set_point_weight_scale(Vector2i(x, z), 1.0 / maxf(geometry.ground_speed(p), 0.05))


## A key for what the grid was last built from (gates, twists); bots rebuild when it changes.
func state_key() -> String:
	return "%s|%s|%s" % [geometry.gates_open, geometry.removed_tags.keys(), not geometry.flood.is_empty()]


func _blocked_at(p: Vector3) -> bool:
	var r: float = ArenaGeometry.UNIT_RADIUS + BLOCK_MARGIN
	var lim: float = geometry.bounds_half - r
	if absf(p.x) > lim or absf(p.z) > lim:
		return true
	var q: Vector2 = Vector2(p.x, p.z)
	for c: Dictionary in geometry.circles:
		if geometry.stands(c) and q.distance_to(c["center"]) < float(c["radius"]) + r:
			return true
	for b: Dictionary in geometry.boxes:
		if not geometry.stands(b):
			continue
		if q.x > b["min"].x - r and q.x < b["max"].x + r and q.y > b["min"].y - r and q.y < b["max"].y + r:
			return true
	return false


func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(clampi(int((p.x - origin) / CELL), 0, size - 1), clampi(int((p.z - origin) / CELL), 0, size - 1))


func cell_center(c: Vector2i) -> Vector3:
	return Vector3(origin + (c.x + 0.5) * CELL, 0.0, origin + (c.y + 0.5) * CELL)


## Waypoints from `from` to `to` (excluding the start). Straight line when nothing is in the way.
func path(from: Vector3, to: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if walkable(from, to):
		out.append(to)
		return out
	var a: Vector2i = _nearest_open(from)
	var b: Vector2i = _nearest_open(to)
	var cells: Array[Vector2i] = _astar.get_id_path(a, b)
	if cells.is_empty():
		out.append(to)
		return out
	# string-pulling: keep only the waypoints needed to go around obstacles
	var anchor: Vector3 = from
	var i: int = 0
	while i < cells.size():
		var j: int = cells.size() - 1
		while j > i and not walkable(anchor, cell_center(cells[j])):
			j -= 1
		anchor = cell_center(cells[j])
		out.append(anchor)
		i = j + 1
	if walkable(out[-1], to):
		out.append(to)
	return out


## True when a unit can walk the straight line from `a` to `b` without touching a collider:
## an exact test against the map shapes grown by the unit's radius, not a grid lookup, so
## shortcuts never clip a corner.
func walkable(a: Vector3, b: Vector3) -> bool:
	var grow: float = ArenaGeometry.UNIT_RADIUS - WALK_SLACK
	var lim: float = geometry.bounds_half - grow
	if absf(b.x) > lim or absf(b.z) > lim:
		return false
	var pa: Vector2 = Vector2(a.x, a.z)
	var pb: Vector2 = Vector2(b.x, b.z)
	for c: Dictionary in geometry.circles:
		if geometry.stands(c) and ArenaGeometry._segment_hits_circle(pa, pb, c["center"], float(c["radius"]) + grow):
			return false
	for bx: Dictionary in geometry.boxes:
		if not geometry.stands(bx):
			continue
		if ArenaGeometry._segment_hits_box(pa, pb, bx["min"] - Vector2.ONE * grow, bx["max"] + Vector2.ONE * grow):
			return false
	return true


## The open cell nearest to a point by straight-line distance (searching square rings outward,
## so the result is the nearest to within one cell).
func _nearest_open(p: Vector3) -> Vector2i:
	var c: Vector2i = cell_of(p)
	if not _astar.is_point_solid(c):
		return c
	var best: Vector2i = c
	var best_d: float = INF
	for r: int in range(1, 8):
		for dx: int in range(-r, r + 1):
			for dz: int in range(-r, r + 1):
				var n: Vector2i = Vector2i(clampi(c.x + dx, 0, size - 1), clampi(c.y + dz, 0, size - 1))
				if _astar.is_point_solid(n):
					continue
				var d: float = cell_center(n).distance_squared_to(Vector3(p.x, 0, p.z))
				if d < best_d:
					best_d = d
					best = n
		if best_d < INF:
			return best
	return c
