class_name LocalMatch
extends RefCounted
## An arena match run in-process for practice (backlog M1-23): the server's MatchRunner with bots
## for every unit but the player's, whose input is supplied each tick by the caller. The client
## side reads it only through view() (the world-view shape a network client also builds), so
## M1-28 can put NetClient in its place.
##
##   var m: LocalMatch = LocalMatch.new("gallows_courtyard", "warblade_carnage", ["oracle_grace"],
##       ["arcanist_rime", "oracle_grace"])
##   m.step(controller.next_input(m.dt(), m.view(), camera))

var runner: MatchRunner
var player: Unit
var brains: Dictionary = {}  ## unit id -> BotBrain, or the player's input source
var _source: PlayerInputSource


## Stands in for a bot brain in MatchRunner.bot_system, so the player's input is applied in the
## same seeded turn order as the bots' (see Sim.turn_order).
class PlayerInputSource:
	extends RefCounted
	var input: Dictionary = {}

	func next_input(_view: Dictionary) -> Dictionary:
		return input


func _init(map_id: String, player_spec: String, ally_specs: Array, enemy_specs: Array,
		bracket: String = "2v2", prep_s: float = 0.0, seed_value: int = 1) -> void:
	runner = MatchRunner.new(Data.maps[map_id], "arena", bracket, prep_s, seed_value)
	player = runner.add_unit(player_spec, 0)
	_source = PlayerInputSource.new()
	_source.input = {"move": Vector2.ZERO, "yaw": player.facing}
	brains[player.id] = _source
	for i: int in ally_specs.size():
		_add_bot(str(ally_specs[i]), 0, seed_value)
	for i: int in enemy_specs.size():
		_add_bot(str(enemy_specs[i]), 1, seed_value)
	runner.sim.add_system(runner.bot_system(brains))
	runner.sim.add_system(runner.system_combat_and_rules)


func _add_bot(spec_id: String, team: int, seed_value: int) -> void:
	var u: Unit = runner.add_unit(spec_id, team)
	brains[u.id] = BotBrain.new(spec_id, seed_value * 1000 + u.id, runner.geometry)


## Seconds per simulation tick.
func dt() -> float:
	return runner.sim.dt()


func tick_rate() -> int:
	return runner.sim.tick_rate


func geometry() -> ArenaGeometry:
	return runner.geometry


## Run one simulation tick with the player's input for it.
func step(player_input: Dictionary) -> void:
	_source.input = player_input
	runner.sim.step()
	runner.take_events()  # combat log for the HUD comes with M1-27; drop it so it cannot pile up


## The world as the player sees it.
func view() -> Dictionary:
	return runner.view_for(player)
