class_name PlayerProfile
extends Resource

## Data model for an individual golfer in a local multiplayer or solo session.
## Tracks identity, stance, real-time strokes, scorecard history, and putting stats.

@export var player_id: int = 1
@export var player_name: String = "Player 1"
@export_enum("right", "left") var handedness: String = "right"
@export var avatar_color: Color = Color(0.15, 0.75, 1.0) ## Identifying accent color
@export var ball_marker_color: Color = Color(1.0, 1.0, 1.0)

# Match Scorecard
var current_hole_strokes: int = 0
var total_strokes: int = 0
var hole_scores: Array[int] = []
var is_hole_complete: bool = false

# Telemetry & Stats History
var putt_history: Array[Dictionary] = []

func _init(p_id: int = 1, p_name: String = "Player 1", p_handedness: String = "right", p_color: Color = Color(0.15, 0.75, 1.0)) -> void:
	player_id = p_id
	player_name = p_name
	handedness = p_handedness
	avatar_color = p_color

## Records a stroke on the current hole
func record_stroke(intended_dist_m: float = 0.0) -> void:
	current_hole_strokes += 1
	total_strokes += 1
	putt_history.append({
		"stroke": current_hole_strokes,
		"intended_dist_m": intended_dist_m,
		"timestamp": Time.get_unix_time_from_system()
	})

## Concludes the active hole for this player and logs strokes to hole_scores
func complete_hole() -> void:
	is_hole_complete = true
	hole_scores.append(current_hole_strokes)

## Resets current hole stroke counter for the next hole
func reset_for_next_hole() -> void:
	current_hole_strokes = 0
	is_hole_complete = false

## Resets all match data for a fresh game
func reset_match() -> void:
	current_hole_strokes = 0
	total_strokes = 0
	hole_scores.clear()
	putt_history.clear()
	is_hole_complete = false

## Returns formatted summary text
func get_summary() -> String:
	return "%s (%s-handed) | Hole: %d strokes | Total: %d strokes" % [
		player_name,
		handedness.capitalize(),
		current_hole_strokes,
		total_strokes
	]
