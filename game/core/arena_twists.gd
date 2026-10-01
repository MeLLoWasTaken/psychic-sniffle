class_name ArenaTwists
extends RefCounted
## Arena twists (docs/DESIGN.md "Arena maps": each map has one twist), from the map's "twists"
## data. A twist happens at a fixed time of match time (seconds since the gates opened), after a
## warning, so its state is a pure function of match time: the server, the client's prediction,
## replays and the map's visuals all derive it from the same number and always agree.
##
## Types:
##   collapse   at_s, tags: the colliders with those tags are gone from then on (movement and
##              line of sight), and the map shows the wreck (the gallows block falling, M2-16).
##
##   {"id": "gallows_collapse", "type": "collapse", "at_s": 300, "warn_s": 10, "tags": ["gallows"],
##    "warn_text": "The gallows groan...", "text": "The gallows collapse!"}

enum Stage { WAITING, WARNED, DONE }


## A twist's stage at `seconds` of match time (negative during preparation: always WAITING).
static func stage(twist: Dictionary, seconds: float) -> Stage:
	var at: float = float(twist.get("at_s", INF))
	if seconds >= at:
		return Stage.DONE
	if seconds >= at - float(twist.get("warn_s", 0.0)):
		return Stage.WARNED
	return Stage.WAITING


## Collider tags no longer standing at `seconds`: tag -> true.
static func removed_tags(twists: Array, seconds: float) -> Dictionary:
	var out: Dictionary = {}
	for t: Dictionary in twists:
		if str(t.get("type", "")) == "collapse" and stage(t, seconds) == Stage.DONE:
			for tag: String in t.get("tags", []):
				out[tag] = true
	return out


## Where a twist happens on the ground plane: the middle of the colliders it changes (sounds,
## effects), or the arena centre.
static func center(twist: Dictionary, map: Dictionary) -> Vector3:
	var sum: Vector2 = Vector2.ZERO
	var n: int = 0
	for c: Dictionary in map.get("colliders", []):
		if str(c.get("tag", "")) in twist.get("tags", []):
			sum += Vector2(c["center"][0], c["center"][1]) if c["type"] == "circle" \
				else (Vector2(c["min"][0], c["min"][1]) + Vector2(c["max"][0], c["max"][1])) * 0.5
			n += 1
	return Vector3(sum.x / n, 0.0, sum.y / n) if n > 0 else Vector3.ZERO
