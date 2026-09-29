extends NetClient
## Headless test bot: a network client whose inputs come from BotBrain.
##   godot --headless --path game -- --bot --name bot1 [--spec arcanist_rime] [--port 24600]
##     [--seconds 300] [--stats out.json]
## The brain reads the same view shape as the in-process batch simulator (tools/batch_sim.gd),
## built here from snapshots plus our own prediction.

var brain: BotBrain


func _ready() -> void:
	super._ready()
	quit_on_match_end = true
	welcomed.connect(_on_welcomed)
	input_source = _next_input
	connect_to_server()


func _on_welcomed(_id: int) -> void:
	brain = BotBrain.new(spec_id, hash(player_name), geometry)


func _next_input() -> Dictionary:
	var view: Dictionary = bot_view()
	if brain == null or view.is_empty():
		return {"move": Vector2.ZERO, "yaw": predicted.facing if predicted else 0.0}
	return brain.next_input(view)
