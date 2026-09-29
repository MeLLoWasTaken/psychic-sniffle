class_name NavGrid
extends RefCounted
## Navigation for bots (and later, click-to-move): a grid over the arena with cells blocked by
## colliders (inflated by the player radius), and A* paths with line-of-sight smoothing.

const CELL: float = 0.5

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


## Re-mark blocked cells (call when gates open or close).
func rebuild() -> void:
	for x: int in size:
		for z: int in size:
			var p: Vector3 = cell_center(Vector2i(x, z))
			_astar.set_point_solid(Vector2i(x, z), _blocked_at(p))


func _blocked_at(p: Vector3) -> bool:
	var r: float = ArenaGeometry.UNIT_RADIUS + 0.1
	var lim: float = geometry.bounds_half - r
	if absf(p.x) > lim or absf(p.z) > lim:
		return true
	var q: Vector2 = Vector2(p.x, p.z)
	for c: Dictionary in geometry.circles:
		if q.distance_to(c["center"]) < float(c["radius"]) + r:
			return true
	for b: Dictionary in geometry.boxes:
		if b["gate"] and geometry.gates_open:
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
	if _clear(from, to):
		out.append(to)
		return out
	var a: Vector2i = _nearest_open(cell_of(from))
	var b: Vector2i = _nearest_open(cell_of(to))
	var cells: Array[Vector2i] = _astar.get_id_path(a, b)
	if cells.is_empty():
		out.append(to)
		return out
	# string-pulling: keep only the waypoints needed to go around obstacles
	var anchor: Vector3 = from
	var i: int = 0
	while i < cells.size():
		var j: int = cells.size() - 1
		while j > i and not _clear(anchor, cell_center(cells[j])):
			j -= 1
		anchor = cell_center(cells[j])
		out.append(anchor)
		i = j + 1
	out[-1] = to if _clear(out[-1], to) else out[-1]
	return out


func _clear(a: Vector3, b: Vector3) -> bool:
	var d: float = Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
	var steps: int = maxi(1, int(d / (CELL * 0.5)))
	for s: int in steps + 1:
		var p: Vector3 = a.lerp(b, float(s) / steps)
		if _astar.is_point_solid(cell_of(p)):
			return false
	return true


func _nearest_open(c: Vector2i) -> Vector2i:
	if not _astar.is_point_solid(c):
		return c
	for r: int in range(1, 8):
		for dx: int in range(-r, r + 1):
			for dz: int in range(-r, r + 1):
				var n: Vector2i = Vector2i(clampi(c.x + dx, 0, size - 1), clampi(c.y + dz, 0, size - 1))
				if not _astar.is_point_solid(n):
					return n
	return c
