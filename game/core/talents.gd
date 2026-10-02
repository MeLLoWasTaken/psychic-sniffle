class_name Talents
extends RefCounted
## Talent loadouts (docs/DESIGN.md "Talent trees", backlog M2-03): checking a loadout against its
## trees, turning it into one unit's numbers, and the short text form players share.
##
## A loadout is {"class": {node_id: rank}, "spec": {node_id: rank}, "pvp": [node_id, ...]}.
## A choice node's value is the option picked (1 or 2); it costs one point.
##
## A node can also grant an ability or a permanent aura (a passive such as extra armor).
## Talent effects patch the unit's own copies of abilities and auras, or the unit itself
## ("self.max_health", "self.stats.<stat>", "self.resource_max.<resource>"). Each effect either
## adds `per_rank` x rank to a number or sets a value (`set`). Nothing here knows any class.

const FORMAT_VERSION: int = 1
const PATH_DEFAULTS: Dictionary = {"pvp_modifier": 1.0}  ## fields an effect may add to when absent
const SELF_FIELDS: Array[String] = ["max_health", "stats", "resource_max"]


static func empty() -> Dictionary:
	return {"class": {}, "spec": {}, "pvp": []}


static func is_empty(loadout: Dictionary) -> bool:
	return loadout.get("class", {}).is_empty() and loadout.get("spec", {}).is_empty() and loadout.get("pvp", []).is_empty()


## The class, spec and PvP trees of a spec ({} for a layer the data does not have).
static func trees_for(spec_id: String, specs: Dictionary, classes: Dictionary, trees: Dictionary) -> Dictionary:
	var spec: Dictionary = specs.get(spec_id, {})
	var cls: Dictionary = classes.get(spec.get("class", ""), {})
	return {"class": trees.get(cls.get("class_tree", ""), {}), "spec": trees.get(spec.get("spec_tree", ""), {}),
		"pvp": trees.get(spec.get("pvp_talents", ""), {})}


static func node_of(tree: Dictionary, node_id: String) -> Dictionary:
	for n: Dictionary in tree.get("nodes", []):
		if n["id"] == node_id:
			return n
	return {}


static func max_rank(n: Dictionary) -> int:
	return 1 if n["type"] == "choice" else int(n.get("ranks", 1))


static func cost(n: Dictionary, value: int) -> int:
	return 1 if n["type"] == "choice" else value


## Points spent in a tree's picks.
static func spent(tree: Dictionary, picks: Dictionary) -> int:
	var total: int = 0
	for id: String in picks:
		var n: Dictionary = node_of(tree, id)
		if not n.is_empty():
			total += cost(n, int(picks[id]))
	return total


## True when a node may take points: its gate is reached (points spent on nodes behind a lower
## gate) and it is a root, or hangs off an ability, or a node connected above is fully ranked.
static func unlocked(tree: Dictionary, picks: Dictionary, n: Dictionary) -> bool:
	var gate: int = int(n.get("gate", 0))
	if gate > 0:
		var before: int = 0
		for id: String in picks:
			var o: Dictionary = node_of(tree, id)
			if not o.is_empty() and int(o.get("gate", 0)) < gate:
				before += cost(o, int(picks[id]))
		if before < gate:
			return false
	var reqs: Array = n.get("requires_any", [])
	if reqs.is_empty():
		return true
	for r: String in reqs:
		var rn: Dictionary = node_of(tree, r)
		if rn.is_empty():
			return true  # names an ability the spec has: the node hangs off the action bar
		if picks.has(r) and int(picks[r]) >= max_rank(rn):
			return true
	return false


## "" when the loadout is legal for these trees, otherwise the first problem found.
static func check(loadout: Dictionary, trees: Dictionary) -> String:
	for layer: String in ["class", "spec"]:
		var picks: Dictionary = loadout.get(layer, {})
		if picks.is_empty():
			continue
		var tree: Dictionary = trees.get(layer, {})
		if tree.is_empty():
			return "%s: this spec has no %s tree" % [layer, layer]
		for id: String in picks:
			var n: Dictionary = node_of(tree, id)
			if n.is_empty():
				return "%s: no node '%s'" % [layer, id]
			var v: int = int(picks[id])
			if n["type"] == "choice":
				if v < 1 or v > n["choices"].size():
					return "%s: '%s' has options 1 to %d, not %d" % [layer, id, n["choices"].size(), v]
			elif v < 1 or v > max_rank(n):
				return "%s: '%s' has %d ranks, not %d" % [layer, id, max_rank(n), v]
		var total: int = spent(tree, picks)
		if total > int(tree["points"]):
			return "%s: %d points spent, %d available" % [layer, total, int(tree["points"])]
		for id: String in picks:
			var n: Dictionary = node_of(tree, id)
			if not unlocked(tree, picks, n):
				return "%s: '%s' is locked (gate %d, needs one of %s)" % [layer, id, int(n.get("gate", 0)),
					", ".join(PackedStringArray(n.get("requires_any", [])))]
	var pvp: Array = loadout.get("pvp", [])
	if not pvp.is_empty():
		var tree: Dictionary = trees.get("pvp", {})
		if pvp.size() > int(tree.get("points", 0)):
			return "pvp: %d talents, %d slots" % [pvp.size(), int(tree.get("points", 0))]
		var seen: Dictionary = {}
		for id: String in pvp:
			if node_of(tree, id).is_empty():
				return "pvp: no talent '%s'" % id
			if seen.has(id):
				return "pvp: '%s' picked twice" % id
			seen[id] = true
	return ""


## A random legal loadout (balance simulations, M2-04), built the way players build: each tree
## aims for a random node behind its last gate (and half the time one behind an earlier gate),
## spends toward it first (the deepest open node on its route there), then places the rest of its
## points one rank at a time on random open nodes (a choice node takes a random option); then
## random PvP talents fill the slots. The same seed always gives the same loadout.
## A uniform random walk instead (M2-04b) spread the points over the open first rows: the roots
## were in every build and the capstones in almost none, unlike any player.
static func random_build(trees: Dictionary, seed_value: int) -> Dictionary:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var lo: Dictionary = {"class": {}, "spec": {}, "pvp": []}
	for layer: String in ["class", "spec"]:
		var tree: Dictionary = trees.get(layer, {})
		var picks: Dictionary = lo[layer]
		var want: Dictionary = _random_goal(tree, rng)
		var points: int = int(tree.get("points", 0))
		while spent(tree, picks) < points:
			var open: Array = []  # [id, value]
			for n: Dictionary in tree.get("nodes", []):
				var v: int = int(picks.get(n["id"], 0))
				if v >= max_rank(n) or not unlocked(tree, picks, n):
					continue
				open.append([n["id"], rng.randi_range(1, n["choices"].size()) if n["type"] == "choice" else v + 1])
			if open.is_empty():
				break
			var aim: Array = open.filter(func(o: Array) -> bool: return want.has(o[0]))
			if not aim.is_empty():
				var deepest: int = -1
				for o: Array in aim:
					deepest = maxi(deepest, int(node_of(tree, o[0])["pos"][1]))
				aim = aim.filter(func(o: Array) -> bool: return int(node_of(tree, o[0])["pos"][1]) == deepest)
			var pool_: Array = aim if not aim.is_empty() else open
			var o: Array = pool_[rng.randi() % pool_.size()]
			picks[o[0]] = o[1]
	var pool: Array = trees.get("pvp", {}).get("nodes", []).map(func(n: Dictionary) -> String: return n["id"])
	for i: int in mini(int(trees.get("pvp", {}).get("points", 0)), pool.size()):
		lo["pvp"].append(pool.pop_at(rng.randi() % pool.size()))
	return lo


## A random build's goals in `tree` and one route up to each (id -> true): one random node behind
## the last gate, and half the time one behind an earlier gate.
static func _random_goal(tree: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var gates: Array = tree.get("gates", [])
	var last: int = 0
	for g: Variant in gates:
		last = maxi(last, int(g))
	var deep: Array = []
	var mid: Array = []
	for n: Dictionary in tree.get("nodes", []):
		var g: int = int(n.get("gate", 0))
		if last > 0 and g == last:
			deep.append(n["id"])
		elif g > 0:
			mid.append(n["id"])
	var goals: Array = []
	if not deep.is_empty():
		goals.append(deep[rng.randi() % deep.size()])
	if not mid.is_empty() and rng.randf() < 0.5:
		goals.append(mid[rng.randi() % mid.size()])
	# one way up from each goal, through a random parent at each step, as a player picks a route
	# (every node above a goal counted instead, and the hubs most routes can pass were in nearly
	# every build)
	var want: Dictionary = {}
	for goal: String in goals:
		var id: String = goal
		while id != "":
			want[id] = true
			var parents: Array = node_of(tree, id).get("requires_any", []).filter(
				func(r: String) -> bool: return not node_of(tree, r).is_empty())
			id = parents[rng.randi() % parents.size()] if not parents.is_empty() else ""
	return want


## The node ids a loadout takes, with ranks ("id" or "id:2"; a choice as "id/option"), sorted.
static func picked_nodes(loadout: Dictionary, trees: Dictionary) -> Array:
	var out: Array = []
	for layer: String in ["class", "spec"]:
		for id: String in loadout.get(layer, {}):
			var n: Dictionary = node_of(trees.get(layer, {}), id)
			var v: int = int(loadout[layer][id])
			if n.get("type", "") == "choice":
				out.append("%s/%s" % [id, n["choices"][v - 1]["id"]])
			else:
				out.append(id if v == 1 else "%s:%d" % [id, v])
	for id: String in loadout.get("pvp", []):
		out.append("pvp:" + id)
	out.sort()
	return out


## What a legal loadout does to one unit: patched copies of the abilities and auras it changes,
## changes to the unit itself, and abilities it grants. Trees are walked in data order, so the
## result never depends on dictionary order.
static func resolve(loadout: Dictionary, trees: Dictionary, abilities: Dictionary, auras: Dictionary) -> Dictionary:
	var out: Dictionary = {"abilities": {}, "auras": {}, "self": [], "grants": [], "grant_auras": []}
	for layer: String in ["class", "spec", "pvp"]:
		var tree: Dictionary = trees.get(layer, {})
		var picks: Variant = loadout.get(layer, {} if layer != "pvp" else [])
		for n: Dictionary in tree.get("nodes", []):
			var rank: int
			if layer == "pvp":
				if not n["id"] in picks:
					continue
				rank = 1
			else:
				if not picks.has(n["id"]):
					continue
				rank = int(picks[n["id"]])
			var source: Dictionary = n
			if n["type"] == "choice":
				source = n["choices"][rank - 1]
				rank = 1
			var grant: String = str(source.get("grants_ability", ""))
			if grant != "" and not grant in out["grants"]:
				out["grants"].append(grant)
			var aura_grant: String = str(source.get("grants_aura", ""))
			if aura_grant != "" and not aura_grant in out["grant_auras"]:
				out["grant_auras"].append(aura_grant)
			for e: Dictionary in source.get("effects", []):
				_apply_effect(out, e, rank, abilities, auras)
	return out


static func _apply_effect(out: Dictionary, e: Dictionary, rank: int, abilities: Dictionary, auras: Dictionary) -> void:
	var parts: PackedStringArray = str(e["modify"]).split(".")
	var target: String = parts[0]
	var path: Array = Array(parts.slice(1))
	if target == "self":
		var change: Dictionary = {"path": path}
		if e.has("set"):
			change["set"] = e["set"]
		else:
			change["add"] = float(e.get("per_rank", 0.0)) * rank
		out["self"].append(change)
		return
	var bucket: String = "abilities" if abilities.has(target) else ("auras" if auras.has(target) else "")
	if bucket == "":
		return  # tools/validate_data.py rejects effects that name nothing
	var copies: Dictionary = out[bucket]
	if not copies.has(target):
		copies[target] = (abilities if bucket == "abilities" else auras)[target].duplicate(true)
	_patch(copies[target], path, e, rank)


static func _patch(data: Variant, path: Array, e: Dictionary, rank: int) -> void:
	var node: Variant = data
	for i: int in path.size() - 1:
		node = node[int(path[i])] if node is Array else node[path[i]]
	var key: Variant = int(path[-1]) if node is Array else path[-1]
	if e.has("set"):
		node[key] = e["set"]
	else:
		var was: float = float(node[key]) if (node is Array or node.has(key)) else float(PATH_DEFAULTS.get(key, 0.0))
		node[key] = was + float(e.get("per_rank", 0.0)) * rank


## Apply resolve()'s "self" changes to a unit.
static func apply_self(u: Unit, changes: Array) -> void:
	for c: Dictionary in changes:
		var path: Array = c["path"]
		match str(path[0]):
			"max_health":
				u.max_health = int(c["set"]) if c.has("set") else u.max_health + roundi(float(c["add"]))
			"stats", "resource_max":
				var d: Dictionary = u.stats if path[0] == "stats" else u.resource_max
				d[path[1]] = c["set"] if c.has("set") else float(d.get(path[1], 0.0)) + float(c["add"])


# ------------------------------------------------------------------ the shared text form

## A checksum of the trees' node ids, so a string saved against an older tree layout is refused
## rather than read as a different build.
static func layout_checksum(trees: Dictionary) -> int:
	var ids: PackedStringArray = []
	for layer: String in ["class", "spec", "pvp"]:
		ids.append(layer + ":" + str(trees.get(layer, {}).get("tree_id", "")))
		for n: Dictionary in trees.get(layer, {}).get("nodes", []):
			ids.append(n["id"])
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(",".join(ids).to_utf8_buffer())
	var h: PackedByteArray = ctx.finish()
	return (h[0] << 8) | h[1]


## Loadout -> short text: a version byte, the layout checksum, two bits per class and spec node
## in data order, then the PvP picks as node indices; base64 with URL-safe letters, no padding.
static func encode(loadout: Dictionary, trees: Dictionary) -> String:
	var cs: int = layout_checksum(trees)
	var bytes: PackedByteArray = PackedByteArray([FORMAT_VERSION, cs >> 8, cs & 0xFF])
	var values: Array[int] = []
	for layer: String in ["class", "spec"]:
		var picks: Dictionary = loadout.get(layer, {})
		for n: Dictionary in trees.get(layer, {}).get("nodes", []):
			values.append(clampi(int(picks.get(n["id"], 0)), 0, 3))
	for i: int in range(0, values.size(), 4):
		var byte: int = 0
		for j: int in 4:
			if i + j < values.size():
				byte |= values[i + j] << (j * 2)
		bytes.append(byte)
	var pvp_nodes: Array = trees.get("pvp", {}).get("nodes", [])
	var pvp: Array = loadout.get("pvp", [])
	bytes.append(pvp.size())
	for id: String in pvp:
		bytes.append(pvp_nodes.find(node_of(trees["pvp"], id)))
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").rstrip("=")


## Text -> {"loadout": Dictionary, "error": String}. An empty string is the empty loadout.
static func decode(text: String, trees: Dictionary) -> Dictionary:
	if text.strip_edges() == "":
		return {"loadout": empty(), "error": ""}
	var b64: String = text.strip_edges().replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var bytes: PackedByteArray = Marshalls.base64_to_raw(b64)
	if bytes.size() < 4 or bytes[0] != FORMAT_VERSION:
		return {"loadout": empty(), "error": "not a talent string"}
	if ((bytes[1] << 8) | bytes[2]) != layout_checksum(trees):
		return {"loadout": empty(), "error": "made for a different version of these talent trees"}
	var loadout: Dictionary = empty()
	var k: int = 0
	for layer: String in ["class", "spec"]:
		for n: Dictionary in trees.get(layer, {}).get("nodes", []):
			var at: int = 3 + k / 4
			if at >= bytes.size():
				return {"loadout": empty(), "error": "talent string is cut short"}
			var v: int = (bytes[at] >> ((k % 4) * 2)) & 3
			if v > 0:
				loadout[layer][n["id"]] = v
			k += 1
	var p: int = 3 + (k + 3) / 4
	if p >= bytes.size():
		return {"loadout": empty(), "error": "talent string is cut short"}
	var pvp_nodes: Array = trees.get("pvp", {}).get("nodes", [])
	for i: int in bytes[p]:
		var idx: int = bytes[p + 1 + i] if p + 1 + i < bytes.size() else 255
		if idx >= pvp_nodes.size():
			return {"loadout": empty(), "error": "talent string names a PvP talent that does not exist"}
		loadout["pvp"].append(pvp_nodes[idx]["id"])
	return {"loadout": loadout, "error": ""}
