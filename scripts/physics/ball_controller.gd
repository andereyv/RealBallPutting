class_name GolfBallPhysics
extends Node3D

## High-precision golf ball physics for authentic putting green simulation.
## Implements championship Stimp rolling resistance, gravity slope breaks,
## true rolling rotation, and regulation cup capture & lip-out physics.

signal ball_stopped(final_position: Vector3)
signal ball_holed()
signal ball_lipped_out()
signal ball_started_rolling()

enum BallState {
	AT_REST,
	ROLLING,
	DROPPING_IN_CUP,
	IN_CUP
}
const State = BallState

@export_group("Ball Dimensions")
@export var ball_radius: float = 0.021335 # Regulation 1.68" diameter (42.67mm)
@export var ball_mass: float = 0.0459 # 45.9 grams

@export_group("Green Speed (Stimpmeter)")
@export var stimp_rating: float = 14.5 # 14.5=Indoor Putting Mat (Fast Felt), 11=Championship, 12=Augusta
@export var ignore_slope_gravity: bool = false ## When true, simulates pure flat level rolling friction ignoring slopes

@export_group("Cup Specifications")
@export var cup_center_xz: Vector2 = Vector2(0.0, 0.0)
@export var cup_radius: float = 0.054 # Regulation 4.25" cup (54mm radius)
@export var cup_depth: float = 0.12 # 12cm deep
@export var max_capture_speed: float = 1.45 # m/s (~3.2 mph maximum capture speed)

@export_group("Physics State")
@export var state: BallState = BallState.AT_REST
@export var render_visible: bool = true
var velocity: Vector2 = Vector2.ZERO # Horizontal velocity (x, z) in m/s
var green_generator: Node3D = null

@onready var ball_mesh: MeshInstance3D = $BallMesh

func is_at_rest() -> bool:
	return state == State.AT_REST

func is_rolling() -> bool:
	return state == State.ROLLING or state == State.DROPPING_IN_CUP or state == State.IN_CUP

func _ready() -> void:
	visible = false # Always start hidden while on tee

func init_with_green(green: Node3D) -> void:
	green_generator = green
	if green_generator != null:
		var cup_local: Vector2 = green_generator.get("cup_position_xz") if green_generator.get("cup_position_xz") != null else Vector2.ZERO
		var cup_world_3d := green_generator.to_global(Vector3(cup_local.x, 0.0, cup_local.y))
		cup_center_xz = Vector2(cup_world_3d.x, cup_world_3d.z)

## Strikes the ball with a given velocity vector (m/s) in XZ plane
func strike(launch_velocity: Vector2) -> void:
	if state == State.IN_CUP or state == State.DROPPING_IN_CUP:
		return
	velocity = launch_velocity
	state = State.ROLLING
	visible = true # Virtual ball emerges on the green
	ball_started_rolling.emit()
	print("[BallPhysics] >>> BALL STRUCK! launch_vel=(%.2f, %.2f), speed=%.2f m/s, start_pos=(%.3f, %.3f, %.3f) <<<" % [
		launch_velocity.x, launch_velocity.y, launch_velocity.length(),
		global_position.x, global_position.y, global_position.z
	])

func reset_to_position(pos_xz: Vector2, is_world_coords: bool = false) -> void:
	velocity = Vector2.ZERO
	state = State.AT_REST
	var world_pos := Vector3.ZERO
	if green_generator != null:
		if is_world_coords:
			var local_pt: Vector3 = green_generator.to_local(Vector3(pos_xz.x, 0.0, pos_xz.y))
			var local_y: float = green_generator.call("get_surface_height", local_pt.x, local_pt.z)
			world_pos = green_generator.to_global(Vector3(local_pt.x, local_y, local_pt.z))
		else:
			# pos_xz is in local green terrain space (e.g. default ball pos (0, 2.4))
			var local_y: float = green_generator.call("get_surface_height", pos_xz.x, pos_xz.y)
			world_pos = green_generator.to_global(Vector3(pos_xz.x, local_y, pos_xz.y))
	else:
		world_pos = Vector3(pos_xz.x, 0.002, pos_xz.y)
	
	global_position = Vector3(world_pos.x, world_pos.y + ball_radius, world_pos.z)
	if ball_mesh != null:
		ball_mesh.rotation = Vector3.ZERO

func _physics_process(delta: float) -> void:
	match state:
		State.AT_REST:
			pass
		State.ROLLING:
			_process_rolling(delta)
		State.DROPPING_IN_CUP:
			_process_drop_in_cup(delta)
		State.IN_CUP:
			pass

func _process_rolling(delta: float) -> void:
	var current_xz := Vector2(global_position.x, global_position.z)
	var speed := velocity.length()

	# 1. Check Cup Interaction
	var to_cup := current_xz - cup_center_xz
	var dist_to_cup := to_cup.length()

	if dist_to_cup < (cup_radius - ball_radius * 0.4):
		if speed <= max_capture_speed:
			# Ball drops into the hole!
			state = State.DROPPING_IN_CUP
			print("[BallPhysics] >>> BALL HOLED! Speed at cup: %.2f m/s <<<" % speed)
			ball_holed.emit()
			return
		else:
			# Lip-out deflection: speed too high, deflected by far cup lip
			print("[BallPhysics] Lip-out! speed=%.2f m/s" % speed)
			ball_lipped_out.emit()
			var normal_out := to_cup.normalized()
			velocity = velocity.bounce(normal_out) * 0.65 # Loses speed on lip impact
			speed = velocity.length()

	# 2. Gravity Slope Break
	var slope_accel := Vector2.ZERO
	var g := 9.81
	if not ignore_slope_gravity and green_generator != null:
		var local_pt := green_generator.to_local(Vector3(current_xz.x, 0.0, current_xz.y))
		var local_norm: Vector3 = green_generator.call("get_surface_normal", local_pt.x, local_pt.z)
		var world_norm: Vector3 = green_generator.global_transform.basis * local_norm
		# Surface normal downhill acceleration direction in world XZ
		slope_accel = Vector2(world_norm.x, world_norm.z) * g

	# 3. Stimpmeter Rolling Friction (decelerates opposite to motion)
	var mu_r := 0.56 / maxf(stimp_rating, 6.0)
	var friction_decel := mu_r * g

	# 4. Integrate Velocity
	var friction_accel := -velocity.normalized() * friction_decel
	var total_accel := slope_accel + friction_accel
	velocity += total_accel * delta

	# Check if stopped
	var new_speed := velocity.length()
	var static_friction_threshold := friction_decel * 0.8
	if new_speed < 0.015:
		if slope_accel.length() < static_friction_threshold:
			velocity = Vector2.ZERO
			state = State.AT_REST
			print("[BallPhysics] >>> BALL STOPPED at (%.3f, %.3f, %.3f)! dist_to_cup=%.2fm (%.1fft) <<<" % [
				global_position.x, global_position.y, global_position.z,
				dist_to_cup, dist_to_cup * 3.28084
			])
			ball_stopped.emit(global_position)
			return
		else:
			# Too steep to stop, ball rolls with slope
			velocity = slope_accel.normalized() * 0.02

	# 5. Integrate Position
	current_xz += velocity * delta
	var surface_y := 0.002
	if green_generator != null:
		var local_pt := green_generator.to_local(Vector3(current_xz.x, 0.0, current_xz.y))
		var local_y: float = green_generator.call("get_surface_height", local_pt.x, local_pt.z)
		surface_y = green_generator.to_global(Vector3(local_pt.x, local_y, local_pt.z)).y
	global_position = Vector3(current_xz.x, surface_y + ball_radius, current_xz.y)
	visible = render_visible

	# 6. Physical Ball Mesh Rolling Rotation
	if ball_mesh != null and speed > 0.001:
		var roll_dist := speed * delta
		var roll_angle := roll_dist / ball_radius
		# Axis of rotation is perpendicular to velocity in XZ plane
		var roll_axis := Vector3(-velocity.y, 0.0, velocity.x).normalized()
		if roll_axis.length_squared() > 0.01:
			ball_mesh.rotate(roll_axis, roll_angle)

func _process_drop_in_cup(delta: float) -> void:
	# Pull towards center and down to cup bottom
	var target_y := 0.0
	if green_generator != null:
		target_y = green_generator.call("get_surface_height", cup_center_xz.x, cup_center_xz.y) - (cup_depth - ball_radius * 1.5)
	
	global_position.x = lerpf(global_position.x, cup_center_xz.x, delta * 12.0)
	global_position.z = lerpf(global_position.z, cup_center_xz.y, delta * 12.0)
	global_position.y = lerpf(global_position.y, target_y, delta * 14.0)

	if absf(global_position.y - target_y) < 0.005:
		global_position.y = target_y
		state = State.IN_CUP
		velocity = Vector2.ZERO
