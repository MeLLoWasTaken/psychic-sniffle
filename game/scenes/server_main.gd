extends Node
## Dedicated server entry. Networking and the simulation loop arrive in M0-09 and M0-10.


func _ready() -> void:
	Log.info("server: ready, tick rate %d Hz" % Data.tick_rate())
