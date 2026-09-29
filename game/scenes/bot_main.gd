extends NetClient
## Headless test bot: a network client whose inputs come from BotBrain.
##   godot --headless --path game -- --bot --name bot1 [--port 24600] [--seconds 300] [--stats out.json]

var brain: BotBrain


func _ready() -> void:
	super._ready()
	brain = BotBrain.new(self, hash(player_name))
	input_source = brain.next_input
	connect_to_server()
