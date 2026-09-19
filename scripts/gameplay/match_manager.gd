class_name MatchManager
extends Node

## Local Multiplayer & Session Coordinator for RealBallPutting.
## Manages player rosters, turn rotations, scorecard tallying, and game states.
## Emits events for XR split-screen handedness re-alignment and HUD updates.

enum MatchState {
	SETUP,
	AWAITING_PLAYER,
	IN_STROKE,
	BALL_ROLLING,
	HOLE_SUMMARY,
	MATCH_OVER
}

signal match_state_changed(new_state: MatchState)
signal active_player_changed(player: PlayerProfile)
signal stroke_recorded(player: PlayerProfile, stroke_num: int, distance_m: float)
signal hole_completed(player: PlayerProfile, strokes: int)
signal match_completed(winner: PlayerProfile, leaderboard: Array[PlayerProfile])

@export var total_holes: int = 9

var players: Array[PlayerProfile] = []
var active_player_index: int = 0
var current_hole: int = 1
var current_state: MatchState = MatchState.SETUP

func _ready() -> void:
	# Initialize default solo player if roster is empty
	if players.is_empty():
		add_player("Player 1", "right", Color(0.15, 0.75, 1.0))

## Adds a new player to the match roster
func add_player(p_name: String, p_handedness: String = "right", p_color: Color = Color(0.15, 0.75, 1.0)) -> PlayerProfile:
	var next_id := players.size() + 1
	var new_p := PlayerProfile.new(next_id, p_name, p_handedness, p_color)
	players.append(new_p)
	print("[MatchManager] Added player: %s (%s-handed, ID: %d)" % [p_name, p_handedness, next_id])
	return new_p

## Removes a player by ID
func remove_player(player_id: int) -> void:
	for i in range(players.size()):
		if players[i].player_id == player_id:
			var removed = players[i]
			players.remove_at(i)
			print("[MatchManager] Removed player: %s" % removed.player_name)
			if active_player_index >= players.size():
				active_player_index = max(0, players.size() - 1)
			break

## Clears the roster
func clear_roster() -> void:
	players.clear()
	active_player_index = 0

## Returns the player whose turn it is
func get_active_player() -> PlayerProfile:
	if players.is_empty():
		return null
	return players[active_player_index]

## Starts the match
func start_match() -> void:
	if players.is_empty():
		add_player("Player 1", "right")
	
	active_player_index = 0
	current_hole = 1
	for p in players:
		p.reset_match()
	
	_set_state(MatchState.AWAITING_PLAYER)
	var active = get_active_player()
	active_player_changed.emit(active)
	print("[MatchManager] Match started with %d players. Current: %s" % [players.size(), active.player_name])

## Records a stroke for the active player
func record_stroke(intended_dist_m: float = 0.0) -> void:
	var active = get_active_player()
	if active == null:
		return
		
	active.record_stroke(intended_dist_m)
	_set_state(MatchState.BALL_ROLLING)
	stroke_recorded.emit(active, active.current_hole_strokes, intended_dist_m)
	print("[MatchManager] Stroke %d recorded for %s" % [active.current_hole_strokes, active.player_name])

## Called when the active player sinks the putt
func hole_out_current_player() -> void:
	var active = get_active_player()
	if active == null:
		return
		
	active.complete_hole()
	hole_completed.emit(active, active.current_hole_strokes)
	print("[MatchManager] %s completed hole %d in %d strokes!" % [active.player_name, current_hole, active.current_hole_strokes])
	advance_turn()

## Advances turn to the next player or triggers hole conclusion
func advance_turn() -> void:
	if players.is_empty():
		return
	
	# Check if all players have completed the current hole
	var all_hole_done := true
	for p in players:
		if not p.is_hole_complete:
			all_hole_done = false
			break
			
	if all_hole_done:
		_conclude_hole()
		return
		
	# Find next player who still needs to complete the hole
	var start_idx := active_player_index
	for i in range(1, players.size() + 1):
		var next_idx := (start_idx + i) % players.size()
		if not players[next_idx].is_hole_complete:
			active_player_index = next_idx
			break
			
	var active = get_active_player()
	_set_state(MatchState.AWAITING_PLAYER)
	active_player_changed.emit(active)
	print("[MatchManager] Next Turn: %s (%s-handed)" % [active.player_name, active.handedness.capitalize()])

func _conclude_hole() -> void:
	_set_state(MatchState.HOLE_SUMMARY)
	print("[MatchManager] Hole %d completed by all players." % current_hole)
	
	if current_hole >= total_holes:
		_conclude_match()
	else:
		current_hole += 1
		for p in players:
			p.reset_for_next_hole()
		active_player_index = 0
		_set_state(MatchState.AWAITING_PLAYER)
		active_player_changed.emit(get_active_player())

func _conclude_match() -> void:
	_set_state(MatchState.MATCH_OVER)
	var leaderboard := get_leaderboard()
	var winner = leaderboard[0] if leaderboard.size() > 0 else null
	match_completed.emit(winner, leaderboard)
	print("[MatchManager] MATCH OVER! Winner: %s with %d total strokes." % [
		winner.player_name if winner else "None",
		winner.total_strokes if winner else 0
	])

## Returns players sorted by lowest total strokes
func get_leaderboard() -> Array[PlayerProfile]:
	var sorted_roster := players.duplicate()
	sorted_roster.sort_custom(func(a: PlayerProfile, b: PlayerProfile):
		return a.total_strokes < b.total_strokes
	)
	return sorted_roster

func _set_state(new_state: MatchState) -> void:
	if current_state != new_state:
		current_state = new_state
		match_state_changed.emit(new_state)
