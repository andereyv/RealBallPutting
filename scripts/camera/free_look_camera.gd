class_name FreeLookCamera
extends Camera3D

## Desktop inspection and green-reading camera for "Golf Sim: Real Ball Putting".
## Supports right-click mouse-look, smooth WASD fly navigation, and instant/smooth
## camera view presets (Golfer Address, Low-angle Crouch, Bird's-Eye View).

@export_group("Movement Speeds")
@export var move_speed: float = 4.0
@export var sprint_multiplier: float = 2.5
@export var slow_multiplier: float = 0.35
@export var mouse_sensitivity: float = 0.003
@export var smooth_acceleration: float = 12.0
@export var preset_transition_speed: float = 6.0

@export_group("Inspection Targets")
@export var ball_position: Vector3 = Vector3(0.0, 0.04, 2.5)
@export var cup_position: Vector3 = Vector3(0.0, 0.0, -3.5)

@export var golf_ball: GolfBallPhysics

# Camera rotation tracking
var _yaw: float = 0.0
var _pitch: float = 0.0
var _velocity: Vector3 = Vector3.ZERO
var _is_right_mouse_down: bool = false
var _current_preset: PresetView = PresetView.ADDRESS

# Preset animation state
var _is_transitioning: bool = false
var _target_position: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _target_pitch: float = 0.0

# Presets definitions (Position, Yaw in radians, Pitch in radians)
enum PresetView {
	ADDRESS = 1,
	CROUCH = 2,
	OVERHEAD = 3
}

func _ready() -> void:
	if golf_ball == null and get_parent() != null:
		golf_ball = get_parent().get_node_or_null("GolfBall") as GolfBallPhysics
	if golf_ball != null:
		ball_position = golf_ball.global_position
		
	# Initialize rotation angles from initial transform
	_yaw = rotation.y
	_pitch = rotation.x
	# Default to golfer's address position
	set_preset(PresetView.ADDRESS, false)

func _unhandled_input(event: InputEvent) -> void:
	# Right-click drag to look around
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_is_right_mouse_down = event.pressed
			if _is_right_mouse_down:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_is_transitioning = false
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

		# Mouse wheel zoom/dolly
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			global_position += -global_transform.basis.z * 0.4
			_is_transitioning = false
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			global_position += global_transform.basis.z * 0.4
			_is_transitioning = false

	# Mouse motion
	elif event is InputEventMouseMotion and _is_right_mouse_down:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, -deg_to_rad(89.0), deg_to_rad(89.0))
		_is_transitioning = false

	# Key presets (1, 2, 3)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				set_preset(PresetView.ADDRESS, true)
			KEY_2:
				set_preset(PresetView.CROUCH, true)
			KEY_3:
				set_preset(PresetView.OVERHEAD, true)

func _process(delta: float) -> void:
	# Keep ball position synchronized
	if golf_ball != null:
		ball_position = golf_ball.global_position
		
		# Dynamic follow camera when ball is rolling
		var ball_state: int = golf_ball.state if golf_ball != null else 0
		if ball_state != 0 and not _is_right_mouse_down and _current_preset == PresetView.ADDRESS:
			var follow_target_pos := ball_position + Vector3(-0.25, 0.90, 1.65)
			var follow_look_target := Vector3(
				lerpf(ball_position.x, cup_position.x, 0.45),
				0.12,
				lerpf(ball_position.z, cup_position.z, 0.45)
			)
			_calculate_look_angles(follow_target_pos, follow_look_target)
			global_position = global_position.lerp(follow_target_pos, delta * 7.0)
			_yaw = lerp_angle(_yaw, _target_yaw, delta * 7.0)
			_pitch = lerpf(_pitch, _target_pitch, delta * 7.0)
			rotation = Vector3(_pitch, _yaw, 0.0)
			return

	if _is_transitioning:
		# Smooth interpolation towards preset target
		global_position = global_position.lerp(_target_position, delta * preset_transition_speed)
		_yaw = lerp_angle(_yaw, _target_yaw, delta * preset_transition_speed)
		_pitch = lerpf(_pitch, _target_pitch, delta * preset_transition_speed)
		rotation = Vector3(_pitch, _yaw, 0.0)

		if global_position.distance_to(_target_position) < 0.01 and absf(_yaw - _target_yaw) < 0.005:
			global_position = _target_position
			_yaw = _target_yaw
			_pitch = _target_pitch
			rotation = Vector3(_pitch, _yaw, 0.0)
			_is_transitioning = false
		return

	# Standard free-fly WASD movement (only when user actively presses keys or drags)
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1.0
	if Input.is_key_pressed(KEY_E):
		input_dir.y += 1.0
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_CTRL):
		input_dir.y -= 1.0

	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= sprint_multiplier
	elif Input.is_key_pressed(KEY_ALT):
		speed *= slow_multiplier

	# Orient movement relative to camera yaw
	var cam_basis := Basis(Vector3.UP, _yaw)
	var move_vec := (cam_basis * Vector3(input_dir.x, 0.0, input_dir.z)).normalized()
	move_vec.y = input_dir.y

	var target_vel := move_vec * speed
	_velocity = _velocity.lerp(target_vel, delta * smooth_acceleration)
	global_position += _velocity * delta

	# Apply rotation
	rotation = Vector3(_pitch, _yaw, 0.0)

func set_preset(preset: PresetView, smooth: bool = true) -> void:
	_current_preset = preset
	match preset:
		PresetView.ADDRESS:
			# Behind-the-ball golfer perspective: ball prominent in lower frame, pin visible ahead
			_target_position = ball_position + Vector3(-0.25, 0.90, 1.65)
			var look_target := Vector3(
				lerpf(ball_position.x, cup_position.x, 0.45),
				0.12,
				lerpf(ball_position.z, cup_position.z, 0.45)
			)
			_calculate_look_angles(_target_position, look_target)

		PresetView.CROUCH:
			# Low-angle green-reading crouch behind the ball looking directly at the cup
			_target_position = ball_position + Vector3(0.0, 0.22, 1.35)
			_calculate_look_angles(_target_position, Vector3(cup_position.x, 0.04, cup_position.z))

		PresetView.OVERHEAD:
			# Bird's-eye elevated view of the green complex and undulations
			var center_pos := (ball_position + cup_position) * 0.5
			_target_position = center_pos + Vector3(0.0, 10.0, 2.5)
			_calculate_look_angles(_target_position, center_pos)

	if smooth:
		_is_transitioning = true
	else:
		global_position = _target_position
		_yaw = _target_yaw
		_pitch = _target_pitch
		rotation = Vector3(_pitch, _yaw, 0.0)
		_is_transitioning = false

func _calculate_look_angles(from_pos: Vector3, to_pos: Vector3) -> void:
	var dir := (to_pos - from_pos).normalized()
	_target_yaw = atan2(-dir.x, -dir.z)
	_target_pitch = asin(clampf(dir.y, -0.999, 0.999))
