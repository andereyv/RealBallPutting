class_name InspectionHUD
extends CanvasLayer

## Comprehensive golf putting simulator HUD.
## Displays live distance, slope/elevation break, power bar, and stroke results.

@onready var panel: PanelContainer = $HUDPanel
@onready var title_label: Label = $HUDPanel/VBox/Title
@onready var fps_label: Label = $HUDPanel/VBox.get_node_or_null("FPSLabel")
@onready var distance_label: Label = $HUDPanel/VBox/DistanceLabel
@onready var break_label: Label = $HUDPanel/VBox/BreakLabel
@onready var status_label: Label = $HUDPanel/VBox/StatusLabel
@onready var power_bar: ProgressBar = $HUDPanel/VBox/PowerBar
@onready var controls_label: Label = $HUDPanel/VBox/Controls

var putting_controller: PuttingController = null
var golf_ball: GolfBallPhysics = null
var green_generator: GreenGenerator = null
var _fps_update_timer: float = 0.0

func _ready() -> void:
	if get_viewport().use_xr:
		panel.visible = false
	call_deferred("_connect_nodes")

func _connect_nodes() -> void:
	var root := get_parent()
	if root != null:
		golf_ball = root.get_node_or_null("GolfBall") as GolfBallPhysics
		green_generator = root.get_node_or_null("GreenSurface") as GreenGenerator
		putting_controller = root.get_node_or_null("PuttingController") as PuttingController

		if golf_ball != null:
			golf_ball.ball_holed.connect(_on_ball_holed)
			golf_ball.ball_stopped.connect(_on_ball_stopped)
			golf_ball.ball_started_rolling.connect(_on_ball_rolling)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_H:
		panel.visible = not panel.visible

func _process(delta: float) -> void:
	if not panel.visible:
		return

	# Update live FPS & Frame Time
	_fps_update_timer += delta
	if _fps_update_timer >= 0.1:
		_fps_update_timer = 0.0
		var fps := Engine.get_frames_per_second()
		var frame_ms := 1000.0 / maxf(1.0, float(fps))
		var target_fps := 90
		if fps_label != null:
			fps_label.text = "PERFORMANCE: %d FPS (%.1f ms)  •  Target: %d Hz" % [fps, frame_ms, target_fps]
			if fps >= target_fps - 2:
				fps_label.modulate = Color(0.35, 1.0, 0.45) # Emerald Green
			elif fps >= 72:
				fps_label.modulate = Color(1.0, 0.85, 0.25) # Amber/Yellow
			else:
				fps_label.modulate = Color(1.0, 0.35, 0.35) # Red (VRC Failure risk)

	# Update distance & elevation
	if golf_ball != null and green_generator != null:
		var ball_pos: Vector3 = golf_ball.position
		var cup_xz: Vector2 = green_generator.cup_position_xz
		var cup_y: float = green_generator.get_surface_height(cup_xz.x, cup_xz.y)

		var dist_m := Vector2(ball_pos.x - cup_xz.x, ball_pos.z - cup_xz.y).length()
		var dist_ft := dist_m * 3.28084
		var elev_cm := (cup_y - (ball_pos.y - 0.0213)) * 100.0
		var elev_in := elev_cm / 2.54

		var elev_text := ""
		if elev_cm > 0.5:
			elev_text = "+%.1f in Uphill" % elev_in
		elif elev_cm < -0.5:
			elev_text = "%.1f in Downhill" % absf(elev_in)
		else:
			elev_text = "Level"

		if distance_label != null:
			distance_label.text = "Distance to Pin: %.1f m  (%.1f ft)  •  %s" % [dist_m, dist_ft, elev_text]

		# Break slope check
		if break_label != null:
			var norm: Vector3 = green_generator.get_surface_normal(ball_pos.x, ball_pos.z)
			var slope_pct := sqrt(norm.x * norm.x + norm.z * norm.z) * 100.0
			var side_break := "Left to Right" if norm.x > 0.01 else ("Right to Left" if norm.x < -0.01 else "Straight")
			break_label.text = "Break at Ball: %s (%.1f%% slope)" % [side_break, slope_pct]

	# Update power bar
	if putting_controller != null and power_bar != null:
		var is_charging: bool = putting_controller.is_charging
		var power: float = putting_controller.stroke_power
		power_bar.value = power * 100.0
		if is_charging:
			var target_m: float = lerpf(0.5, 18.0, power)
			var target_ft: float = target_m * 3.28084
			status_label.text = "STROKING... Target: %.1f m (%.1f ft)" % [target_m, target_ft]
			status_label.modulate = Color(1.0, 0.85, 0.3)

func _on_ball_rolling() -> void:
	if status_label != null:
		status_label.text = "BALL ROLLING... Watching the break"
		status_label.modulate = Color(0.5, 0.85, 1.0)

func _on_ball_holed() -> void:
	if status_label != null:
		status_label.text = "⛳ IN THE HOLE! PERFECT PUTT!"
		status_label.modulate = Color(0.4, 1.0, 0.4)

func _on_ball_stopped(final_pos: Vector3) -> void:
	if status_label != null and green_generator != null:
		var cup_xz: Vector2 = green_generator.cup_position_xz
		var rem_m := Vector2(final_pos.x - cup_xz.x, final_pos.z - cup_xz.y).length()
		var rem_ft := rem_m * 3.28084
		status_label.text = "Ball Stopped: %.2f m (%.1f ft) remaining (Press [R] to Re-spot)" % [rem_m, rem_ft]
		status_label.modulate = Color(0.9, 0.9, 0.9)
