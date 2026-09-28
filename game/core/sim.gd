class_name Sim
extends RefCounted
## Fixed-step simulation shared by server and client prediction.
##
## The world advances in whole ticks at `tick_rate` Hz (60 by default, from tuning.json),
## independent of the rendering frame rate. The same seed and the same inputs always give the
## same state, which the replay test (M1-29) and client prediction depend on.

var tick_rate: int
var tick: int = 0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var units: Dictionary = {}  ## unit id -> Unit

var _accumulator: float = 0.0
var _systems: Array[Callable] = []  ## called every tick with (sim, inputs)


func _init(seed_value: int, p_tick_rate: int = 60) -> void:
	tick_rate = p_tick_rate
	rng.seed = seed_value


## Seconds per tick.
func dt() -> float:
	return 1.0 / tick_rate


## Simulated time in seconds.
func time_s() -> float:
	return float(tick) / tick_rate


func add_unit(unit: Unit) -> void:
	units[unit.id] = unit


## Register a system: a callable taking (sim: Sim, inputs: Dictionary). Systems run in the
## order they were added, once per tick.
func add_system(system: Callable) -> void:
	_systems.append(system)


## Feed real elapsed time; runs as many whole ticks as have accumulated. Returns ticks run.
## `inputs_provider` is called once per tick and returns that tick's inputs.
func advance(delta: float, inputs_provider: Callable = Callable()) -> int:
	_accumulator += delta
	var steps: int = 0
	var step_len: float = dt()
	while _accumulator >= step_len - 1e-9:
		_accumulator -= step_len
		var inputs: Dictionary = inputs_provider.call() if inputs_provider.is_valid() else {}
		step(inputs)
		steps += 1
	return steps


## Run exactly one tick. `inputs` maps unit id -> that unit's input for this tick.
func step(inputs: Dictionary = {}) -> void:
	for system: Callable in _systems:
		system.call(self, inputs)
	tick += 1


## SHA-256 of the full world state in a fixed order.
func state_hash() -> String:
	var ids: Array = units.keys()
	ids.sort()
	var parts: PackedStringArray = ["tick=%d" % tick, "rng=%d" % rng.state]
	for uid: int in ids:
		parts.append((units[uid] as Unit).snapshot_string())
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(parts).to_utf8_buffer())
	return ctx.finish().hex_encode()
