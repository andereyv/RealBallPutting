class_name PuttingController
extends Node3D

## Interactive Putting Gameplay Controller for "Golf Sim: Real Ball Putting".
## Handles aim rotation, dynamic power meter, ball striking, aim line projection,
## and HUD feedback.

signal putt_struck(power: float, distance_m: float)
signal ball_reset()

@export_group("Gameplay Nodes")
@export var golf_ball: GolfBallPhysics
@export var green_generator: GreenGenerator
@export var aim_line_mesh: MeshInstance3D

@export_group("Putting Settings")
@export var max_putt_distance_m: float = 18.0 # Up to 60 ft putts
@export var min_putt_distance_m: float = 0.5
@export var power_charge_speed: float = 1.1 # Full meter in ~0.9s
@export var aim_speed: float = 0.9 # Radians per sec

# Gameplay State
var aim_angle: float = 0.0 # Angle in XZ plane relative to cup
var stroke_power: float = 0.0 # 0.0 to 1.0
var is_charging: bool = false
var charge_direction: float = 1.0

var default_ball_pos: Vector2 = Vector2(0.0, 2.5)
var cup_pos: Vector2 = Vector2(0.2, -3.8)

# Aim guide projection
var _aim_immediate_mesh: ImmediateMesh

func _ready() -> void:
	call_deferred("_setup_controller")

func _setup_controller() -> void:
	if green_generator != null:
		cup_pos = green_generator.cup_position_xz

	# Calculate initial aim angle toward the cup
	var to_cup := cup_pos - default_ball_pos
	aim_angle = atan2(-to_cup.x, -to_cup.y)

	_init_aim_line()
	_update_aim_line()

func _init_aim_line() -> void:
	if aim_line_mesh == null:
		aim_line_mesh = MeshInstance3D.new()
		aim_line_mesh.name = "AimLineMesh"
		add_child(aim_line_mesh)

	_aim_immediate_mesh = ImmediateMesh.new()
	aim_line_mesh.mesh = _aim_immediate_mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	aim_line_mesh.material_override = mat

func _unhandled_input(event: InputEvent) -> void:
	# Quick reset with [R]
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		reset_ball()

	# Start charging stroke with Space bar (Mouse click disabled to prevent accidental hits)
	if event is InputEventKey and event.keycode == KEY_SPACE:
		if event.pressed and not event.echo:
			_start_charging()
		elif not event.pressed and is_charging:
			_release_stroke()

func _start_charging() -> void:
	if golf_ball == null or golf_ball.state != GolfBallPhysics.BallState.AT_REST:
		return
	is_charging = true
	stroke_power = 0.0
	charge_direction = 1.0

func _release_stroke() -> void:
	if not is_charging:
		return
	is_charging = false
	
	# Execute putt
	var intended_dist := lerpf(min_putt_distance_m, max_putt_distance_m, stroke_power)
	var stimp: float = golf_ball.stimp_rating if golf_ball != null else 11.0
	
	# v0 = sqrt(2 * mu_r * g * d)
	var mu_r := 0.56 / maxf(stimp, 6.0)
	var launch_speed := sqrt(2.0 * mu_r * 9.81 * intended_dist)
	
	# Launch vector in XZ plane
	var launch_dir := Vector2(-sin(aim_angle), -cos(aim_angle)).normalized()
	var launch_vel := launch_dir * launch_speed
	
	if golf_ball != null:
		golf_ball.strike(launch_vel)
	putt_struck.emit(stroke_power, intended_dist)
	
	stroke_power = 0.0
	_update_aim_line()

func reset_ball() -> void:
	is_charging = false
	stroke_power = 0.0
	if golf_ball != null:
		golf_ball.reset_to_position(default_ball_pos)
	ball_reset.emit()
	_update_aim_line()

func _process(delta: float) -> void:
	# Aim rotation with A / D or Left / Right arrow keys (when not in free-look fly mode)
	if golf_ball != null and golf_ball.state == GolfBallPhysics.BallState.AT_REST and not is_charging:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			var aim_input := 0.0
			if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
				aim_input += 1.0
			if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
				aim_input -= 1.0

			if absf(aim_input) > 0.01:
				aim_angle += aim_input * aim_speed * delta
				_update_aim_line()

	# Stroke power charge oscillation
	if is_charging:
		stroke_power += charge_direction * power_charge_speed * delta
		if stroke_power >= 1.0:
			stroke_power = 1.0
			charge_direction = -1.0
		elif stroke_power <= 0.0:
			stroke_power = 0.0
			charge_direction = 1.0

func _update_aim_line() -> void:
	if _aim_immediate_mesh == null or golf_ball == null or green_generator == null:
		return

	_aim_immediate_mesh.clear_surfaces()
	
	# Only display aim line when ball is at rest
	if golf_ball.state != GolfBallPhysics.BallState.AT_REST:
		return

	_aim_immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)

	var ball_pos_3d: Vector3 = golf_ball.position
	var aim_dir := Vector2(-sin(aim_angle), -cos(aim_angle)).normalized()
	
	var line_len := 2.2 # 2.2m aim line projected on terrain
	var steps := 24
	var step_size := line_len / float(steps)

	for i in range(steps):
		var d0 := float(i) * step_size + 0.06
		var d1 := float(i + 1) * step_size + 0.02
		
		# Dashed line
		if (i % 2) == 1:
			continue

		var p0_xz := Vector2(ball_pos_3d.x, ball_pos_3d.z) + aim_dir * d0
		var p1_xz := Vector2(ball_pos_3d.x, ball_pos_3d.z) + aim_dir * d1
		
		var y0: float = green_generator.get_surface_height(p0_xz.x, p0_xz.y) + 0.006
		var y1: float = green_generator.get_surface_height(p1_xz.x, p1_xz.y) + 0.006

		var alpha := 1.0 - (float(i) / float(steps)) * 0.7
		_aim_immediate_mesh.surface_set_color(Color(1.0, 1.0, 1.0, alpha))
		_aim_immediate_mesh.surface_add_vertex(Vector3(p0_xz.x, y0, p0_xz.y))
		_aim_immediate_mesh.surface_add_vertex(Vector3(p1_xz.x, y1, p1_xz.y))

	_aim_immediate_mesh.surface_end()
