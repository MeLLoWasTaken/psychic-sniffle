class_name MatchFlow
extends RefCounted
## The client's match flow (backlog M1-28), as a state machine with no drawing or networking so
## tests drive it directly:
##
##   LOADING -> PREP -> ACTIVE -> ENDED -> SCOREBOARD -> MENU
##
## LOADING: the local server starts, the arena is built and the client joins. PREP: the
## preparation room behind closed gates (waiting for the roster, then the countdown). ACTIVE:
## the gates are open. ENDED: a team was eliminated or time ran out; the Victory/Defeat banner
## shows over the arena for `end_banner_s`. SCOREBOARD: the end screen. MENU: back to the main
## menu (the scene leaves). leave() goes to MENU from anywhere; fail() (server lost, rejected)
## goes to FAILED, whose only way on is MENU.
##
## Feed it the world views (on_view) and combat events (on_events) the network client produces;
## it follows the server's match phase (never going backwards) and counts the scoreboard.

enum State { LOADING, PREP, ACTIVE, ENDED, SCOREBOARD, MENU, FAILED }

signal state_changed(from: State, to: State)

var state: State = State.LOADING
var history: Array[String] = ["loading"]  ## every state entered, in order (tests, reports)
var scoreboard: MatchScoreboard = MatchScoreboard.new()
var end_banner_s: float = 3.0
var my_id: int = -1
var my_team: int = -1
var roster_size: int = 4  ## units expected in the match (the countdown holds until all are in)
var units_joined: int = 0
var winner: int = -1  ## team, -2 draw, -1 not decided
var end_reason: String = ""  ## team_eliminated, time_limit (the server's match_end reason)
var start_tick: int = 0  ## tick the gates opened (or will open)
var end_tick: int = -1
var tick_rate: int = 60
var last_tick: int = -1
var failure: String = ""  ## why the flow failed
var left: bool = false  ## the player left before the end
var _state_time: float = 0.0


func _init(p_end_banner_s: float = 3.0, p_roster_size: int = 4) -> void:
	end_banner_s = p_end_banner_s
	roster_size = p_roster_size


## Seconds spent in the current state (advance() counts them).
func time_in_state() -> float:
	return _state_time


## Read one world view: the match phase moves the flow forward, units fill the scoreboard.
func on_view(v: Dictionary) -> void:
	if v.is_empty() or state in [State.MENU, State.FAILED]:
		return
	my_id = int(v["me"]["id"])
	my_team = int(v["me"]["team"])
	tick_rate = int(v.get("tick_rate", tick_rate))
	last_tick = int(v["tick"])
	units_joined = (v["units"] as Array).size()
	scoreboard.add_units(v)
	var m: Dictionary = v.get("match", {})
	start_tick = int(m.get("start_tick", start_tick))
	match int(m.get("phase", ArenaMatch.Phase.PREP)):
		ArenaMatch.Phase.PREP:
			if state == State.LOADING:
				_go(State.PREP)
		ArenaMatch.Phase.ACTIVE:
			if state in [State.LOADING, State.PREP]:
				_go(State.ACTIVE)
		ArenaMatch.Phase.ENDED:
			if winner == -1:
				winner = int(m.get("winner", -1))
			if state in [State.LOADING, State.PREP, State.ACTIVE]:
				end_tick = last_tick
				_go(State.ENDED)


## Read one batch of combat events (scoreboard, and the match_end reason).
func on_events(evs: Array) -> void:
	if state in [State.MENU, State.FAILED, State.SCOREBOARD]:
		return
	scoreboard.add_events(evs)
	for ev: Dictionary in evs:
		if str(ev.get("type", "")) == "match_end":
			winner = int(ev.get("winner", winner))
			end_reason = str(ev.get("reason", ""))
			end_tick = int(ev.get("tick", end_tick))


## Advance time: the end banner gives way to the scoreboard after `end_banner_s`.
func advance(delta: float) -> void:
	_state_time += delta
	if state == State.ENDED and _state_time >= end_banner_s:
		_go(State.SCOREBOARD)


## The player pressed "Back to menu" on the end screen (or on the failure message).
func continue_to_menu() -> bool:
	if state in [State.SCOREBOARD, State.FAILED]:
		_go(State.MENU)
		return true
	return false


## The player left the match (Escape menu) or quit: straight to the menu from any state.
func leave() -> void:
	if state == State.MENU:
		return
	left = state in [State.LOADING, State.PREP, State.ACTIVE]
	_go(State.MENU)


## Something went wrong before the match ended (server lost, rejected, failed to start).
func fail(reason: String) -> void:
	if state in [State.LOADING, State.PREP, State.ACTIVE]:
		failure = reason
		_go(State.FAILED)


## True while waiting in preparation for the rest of the roster to join.
func waiting_for_players() -> bool:
	return state in [State.LOADING, State.PREP] and units_joined < roster_size


## Seconds until the gates open (preparation), from the newest view.
func seconds_to_gates() -> float:
	return maxf(0.0, float(start_tick - last_tick) / tick_rate)


## Match time in seconds since the gates opened (frozen at the end).
func match_seconds() -> float:
	var t: int = end_tick if end_tick >= 0 else last_tick
	return maxf(0.0, float(t - start_tick) / tick_rate)


## "victory", "defeat" or "draw" once the match has ended; "" before.
func outcome() -> String:
	if winner == -1:
		return ""
	if winner == -2:
		return "draw"
	return "victory" if winner == my_team else "defeat"


## Everything the end screen shows, as plain data.
func result() -> Dictionary:
	var enemy_team: int = 1 - my_team if my_team >= 0 else 1
	return {"outcome": outcome(), "winner": winner, "reason": end_reason, "my_team": my_team,
		"my_id": my_id, "match_seconds": match_seconds(),
		"teams": {"mine": scoreboard.rows_for_team(my_team), "enemy": scoreboard.rows_for_team(enemy_team)},
		"totals": {"mine": scoreboard.team_totals(my_team), "enemy": scoreboard.team_totals(enemy_team)},
		"scoreboard": scoreboard.to_dict(), "history": history.duplicate(), "failure": failure, "left": left}


static func state_name(s: State) -> String:
	return (State.keys()[s] as String).to_lower()


func _go(to: State) -> void:
	if to == state:
		return
	var from: State = state
	state = to
	_state_time = 0.0
	history.append(state_name(to))
	state_changed.emit(from, to)
