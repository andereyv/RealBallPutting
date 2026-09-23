class_name XRHandVisualizer
extends Node3D

## High-Performance Procedural OpenXR Hand Visualizer & Gesture Feedback for Quest 3.
## Renders 26 joints and 22 connecting bones via MultiMesh (2 draw calls total).
## Provides live pinch distance detection, dynamic pinch gauge ring, release burst animation,
## and aiming laser guide directly from the pinch midpoint.

enum HandSide {
	LEFT = 0,
	RIGHT = 1
}

@export var hand_side: HandSide = HandSide.RIGHT
@export var show_skeleton: bool = true
@export var joint_base_color: Color = Color(0.15, 0.75, 1.0, 0.65)
@export var bone_base_color: Color = Color(0.1, 0.55, 0.95, 0.45)
@export var pinch_locked_color: Color = Color(0.1, 1.0, 0.4, 0.95)
@export var pinch_warn_color: Color = Color(1.0, 0.82, 0.2, 0.85)

# OpenXR Joint Constants
const JOINT_PALM = 0
const JOINT_WRIST = 1
const JOINT_THUMB_METACARPAL = 2
const JOINT_THUMB_PROXIMAL = 3
const JOINT_THUMB_DISTAL = 4
const JOINT_THUMB_TIP = 5
const JOINT_INDEX_METACARPAL = 6
const JOINT_INDEX_PROXIMAL = 7
const JOINT_INDEX_INTERMEDIATE = 8
const JOINT_INDEX_DISTAL = 9
const JOINT_INDEX_TIP = 10
const JOINT_MIDDLE_METACARPAL = 11
const JOINT_MIDDLE_PROXIMAL = 12
const JOINT_MIDDLE_INTERMEDIATE = 13
const JOINT_MIDDLE_DISTAL = 14
const JOINT_MIDDLE_TIP = 15
const JOINT_RING_METACARPAL = 16
const JOINT_RING_PROXIMAL = 17
const JOINT_RING_INTERMEDIATE = 18
const JOINT_RING_DISTAL = 19
const JOINT_RING_TIP = 20
const JOINT_LITTLE_METACARPAL = 21
const JOINT_LITTLE_PROXIMAL = 22
const JOINT_LITTLE_INTERMEDIATE = 23
const JOINT_LITTLE_DISTAL = 24
const JOINT_LITTLE_TIP = 25
const JOINT_COUNT = 26

# 22 Bone Connections (from_joint, to_joint)
const BONE_CONNECTIONS = [
	[1, 0],   # Wrist -> Palm
	[1, 2], [2, 3], [3, 4], [4, 5],       # Thumb
	[0, 6], [6, 7], [7, 8], [8, 9], [9, 10],   # Index
	[0, 11], [11, 12], [12, 13], [13, 14], [14, 15], # Middle
	[0, 16], [16, 17], [17, 18], [18, 19], [19, 20], # Ring
	[0, 21], [21, 22], [22, 23], [23, 24], [24, 25]  # Little
]

@export var is_hands_enabled: bool = true

# Shader & Material References
var _quest_shader: Shader = preload("res://shaders/quest_outlined_hand.gdshader")
var _oxr: OpenXRInterface = null
var _mm_joints: MultiMeshInstance3D = null
var _mm_bones: MultiMeshInstance3D = null
var _hand_shader_mat: ShaderMaterial = null

# Pinch Visual Elements
var _pinch_ring: MeshInstance3D = null
var _pinch_ring_mat: StandardMaterial3D = null
var _release_pulse_timer: float = 0.0

# Live Tracking State
var is_hand_tracked: bool = false
var is_pinched: bool = false
var pinch_distance_m: float = 0.10
var pinch_midpoint: Vector3 = Vector3.ZERO
var pinch_aim_direction: Vector3 = Vector3.FORWARD
var wrist_position: Vector3 = Vector3.ZERO
var wrist_rotation: Quaternion = Quaternion.IDENTITY

# Joint Caches in World Space
var _joint_world_positions: Array[Vector3] = []
var _joint_valid: Array[bool] = []

func _ready() -> void:
	_joint_world_positions.resize(JOINT_COUNT)
	_joint_valid.resize(JOINT_COUNT)
	for i in range(JOINT_COUNT):
		_joint_world_positions[i] = Vector3.ZERO
		_joint_valid[i] = false
		
	_setup_materials()
	_setup_joint_multimesh()
	_setup_bone_multimesh()
	_setup_pinch_ring()

func set_hands_enabled(enabled: bool) -> void:
	is_hands_enabled = enabled
	if not is_hands_enabled:
		_set_visible(false)
		if _pinch_ring != null:
			_pinch_ring.visible = false
		is_hand_tracked = false
		is_pinched = false

func _setup_materials() -> void:
	_hand_shader_mat = ShaderMaterial.new()
	_hand_shader_mat.shader = _quest_shader
	_hand_shader_mat.set_shader_parameter("outline_color", Color(0.35, 0.85, 1.0, 0.95))
	_hand_shader_mat.set_shader_parameter("fill_color", Color(0.04, 0.10, 0.18, 0.18))
	_hand_shader_mat.set_shader_parameter("rim_power", 2.2)
	_hand_shader_mat.set_shader_parameter("rim_boost", 2.0)
	_hand_shader_mat.set_shader_parameter("pinch_intensity", 0.0)
	_hand_shader_mat.set_shader_parameter("pinch_color", Color(0.1, 1.0, 0.5, 1.0))
	
	_pinch_ring_mat = StandardMaterial3D.new()
	_pinch_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pinch_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pinch_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_pinch_ring_mat.albedo_color = Color(0.35, 0.85, 1.0, 0.90)

func _setup_joint_multimesh() -> void:
	_mm_joints = MultiMeshInstance3D.new()
	_mm_joints.name = "JointMesh"
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = JOINT_COUNT
	
	var sphere = SphereMesh.new()
	sphere.radius = 0.0065
	sphere.height = 0.013
	sphere.radial_segments = 14
	sphere.rings = 7
	mm.mesh = sphere
	
	_mm_joints.multimesh = mm
	_mm_joints.material_override = _hand_shader_mat
	add_child(_mm_joints)

func _setup_bone_multimesh() -> void:
	_mm_bones = MultiMeshInstance3D.new()
	_mm_bones.name = "BoneMesh"
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = BONE_CONNECTIONS.size()
	
	var capsule = CapsuleMesh.new()
	capsule.radius = 0.0036
	capsule.height = 1.0 # scaled dynamically
	capsule.radial_segments = 10
	capsule.rings = 4
	mm.mesh = capsule
	
	_mm_bones.multimesh = mm
	_mm_bones.material_override = _hand_shader_mat
	add_child(_mm_bones)

func _setup_pinch_ring() -> void:
	_pinch_ring = MeshInstance3D.new()
	_pinch_ring.name = "PinchRing"
	var ring_mesh = TorusMesh.new()
	ring_mesh.inner_radius = 0.006
	ring_mesh.outer_radius = 0.0095
	ring_mesh.rings = 16
	ring_mesh.ring_segments = 8
	_pinch_ring.mesh = ring_mesh
	_pinch_ring.material_override = _pinch_ring_mat
	_pinch_ring.visible = false
	add_child(_pinch_ring)

func update_hand_tracking(oxr: OpenXRInterface, origin_transform: Transform3D, camera_pos: Vector3) -> void:
	_oxr = oxr
	if not is_hands_enabled or _oxr == null:
		_set_visible(false)
		if _pinch_ring != null:
			_pinch_ring.visible = false
		is_hand_tracked = false
		is_pinched = false
		return
		
	var h_idx = OpenXRInterface.HAND_RIGHT if hand_side == HandSide.RIGHT else OpenXRInterface.HAND_LEFT
	
	# Check whether hand tracking is currently supplying data
	var valid_count = 0
	for i in range(JOINT_COUNT):
		var flags = _oxr.get_hand_joint_flags(h_idx, i)
		if (flags & 4) != 0: # HAND_JOINT_POSITION_VALID = 4
			_joint_valid[i] = true
			var local_pos = _oxr.get_hand_joint_position(h_idx, i)
			_joint_world_positions[i] = origin_transform * local_pos
			valid_count += 1
		else:
			_joint_valid[i] = false
			
	if valid_count < 8:
		# Hand lost or obscured
		_set_visible(false)
		if _pinch_ring != null:
			_pinch_ring.visible = false
		is_hand_tracked = false
		is_pinched = false
		return
		
	is_hand_tracked = true
	_set_visible(show_skeleton)
	
	# Update wrist state
	if _joint_valid[JOINT_WRIST]:
		wrist_position = _joint_world_positions[JOINT_WRIST]
		wrist_rotation = _oxr.get_hand_joint_rotation(h_idx, JOINT_WRIST)
		
	# Update joint multimesh
	for i in range(JOINT_COUNT):
		if _joint_valid[i]:
			var r_scale = 0.007
			if i == JOINT_PALM: r_scale = 0.012
			elif i == JOINT_WRIST: r_scale = 0.010
			elif i == JOINT_INDEX_TIP or i == JOINT_THUMB_TIP: r_scale = 0.0085
			
			var pt = _joint_world_positions[i]
			var t = Transform3D(Basis().scaled(Vector3.ONE * (r_scale / 0.007)), pt)
			_mm_joints.multimesh.set_instance_transform(i, t)
		else:
			# Hide non-valid joints below floor
			_mm_joints.multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -100, 0)))
			
	# Update bone multimesh
	for b_idx in range(BONE_CONNECTIONS.size()):
		var j_from: int = BONE_CONNECTIONS[b_idx][0]
		var j_to: int = BONE_CONNECTIONS[b_idx][1]
		if _joint_valid[j_from] and _joint_valid[j_to]:
			var p_from = _joint_world_positions[j_from]
			var p_to = _joint_world_positions[j_to]
			var center = (p_from + p_to) * 0.5
			var dir = p_to - p_from
			var length = dir.length()
			if length > 0.002:
				var up = dir.normalized()
				var t = _align_cylinder_transform(center, up, length, 1.0)
				_mm_bones.multimesh.set_instance_transform(b_idx, t)
			else:
				_mm_bones.multimesh.set_instance_transform(b_idx, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -100, 0)))
		else:
			_mm_bones.multimesh.set_instance_transform(b_idx, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -100, 0)))

	# Evaluate Pinch Gesture between Index Tip and Thumb Tip
	if _joint_valid[JOINT_THUMB_TIP] and _joint_valid[JOINT_INDEX_TIP]:
		var thumb_pt = _joint_world_positions[JOINT_THUMB_TIP]
		var index_pt = _joint_world_positions[JOINT_INDEX_TIP]
		pinch_distance_m = thumb_pt.distance_to(index_pt)
		pinch_midpoint = (thumb_pt + index_pt) * 0.5
		
		# Compute aiming direction: from eye/palm through pinch midpoint
		var aim_origin = camera_pos
		if _joint_valid[JOINT_PALM]:
			aim_origin = _joint_world_positions[JOINT_PALM]
		var aim_vec = pinch_midpoint - aim_origin
		pinch_aim_direction = aim_vec.normalized() if aim_vec.length_squared() > 0.001 else Vector3.DOWN
		
		_update_pinch_indicator(camera_pos)
	else:
		_pinch_ring.visible = false

func _update_pinch_indicator(camera_pos: Vector3) -> void:
	if _pinch_ring == null:
		return
		
	# Pinch gauge visibility threshold (within 7.5 cm)
	if pinch_distance_m < 0.075:
		_pinch_ring.visible = true
		_pinch_ring.global_position = pinch_midpoint
		
		# Face camera
		if camera_pos.distance_squared_to(pinch_midpoint) > 0.01:
			_pinch_ring.look_at(camera_pos, Vector3.UP)
			
		# Normalized factor: 0.0 = fully pinched (3.2cm), 1.0 = approaching (7.5cm)
		var t = clamp((pinch_distance_m - 0.032) / (0.075 - 0.032), 0.0, 1.0)
		
		# Scale down as fingers close
		var ring_scale = lerp(0.7, 1.3, t)
		_pinch_ring.scale = Vector3.ONE * ring_scale
		
		# Dynamic Color: Cyan (relaxed) -> Amber (approaching) -> Emerald Green (locked)
		var cur_color = pinch_locked_color
		if t > 0.35:
			var sub_t = (t - 0.35) / 0.65
			cur_color = pinch_warn_color.lerp(joint_base_color, sub_t)
		else:
			var sub_t = t / 0.35
			cur_color = pinch_locked_color.lerp(pinch_warn_color, sub_t)
			
		if is_pinched:
			cur_color = pinch_locked_color
			# Pulsate slightly
			var pulse = 1.0 + 0.08 * sin(Time.get_ticks_msec() * 0.02)
			_pinch_ring.scale = Vector3.ONE * ring_scale * pulse
			
		_pinch_ring_mat.albedo_color = cur_color
		if _hand_shader_mat != null:
			_hand_shader_mat.set_shader_parameter("pinch_intensity", clamp(1.0 - t, 0.0, 1.0))
	else:
		_pinch_ring.visible = false
		if _hand_shader_mat != null:
			_hand_shader_mat.set_shader_parameter("pinch_intensity", 0.0)

func trigger_release_pulse() -> void:
	_release_pulse_timer = 0.22 # flash for 220ms
	if _pinch_ring != null:
		_pinch_ring.visible = true
		_pinch_ring_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
		_pinch_ring.scale = Vector3.ONE * 1.8

func process_effects(delta: float) -> void:
	if _release_pulse_timer > 0.0:
		_release_pulse_timer -= delta
		if _pinch_ring != null and _release_pulse_timer > 0.0:
			var frac = _release_pulse_timer / 0.22
			_pinch_ring.scale = Vector3.ONE * lerp(1.8, 2.5, 1.0 - frac)
			_pinch_ring_mat.albedo_color = Color(0.2, 1.0, 0.7, frac)
		elif _release_pulse_timer <= 0.0 and pinch_distance_m >= 0.075:
			_pinch_ring.visible = false

func set_highlight_color(col: Color) -> void:
	if _hand_shader_mat != null:
		_hand_shader_mat.set_shader_parameter("outline_color", col)

func reset_highlight_color() -> void:
	if _hand_shader_mat != null:
		_hand_shader_mat.set_shader_parameter("outline_color", Color(0.35, 0.85, 1.0, 0.95))

func _set_visible(vis: bool) -> void:
	if _mm_joints != null: _mm_joints.visible = vis
	if _mm_bones != null: _mm_bones.visible = vis

func _align_cylinder_transform(pos: Vector3, up: Vector3, length: float, radius: float) -> Transform3D:
	var rot_axis = Vector3.UP.cross(up)
	var basis = Basis()
	if rot_axis.length_squared() > 0.0001:
		rot_axis = rot_axis.normalized()
		var angle = Vector3.UP.angle_to(up)
		basis = Basis(rot_axis, angle)
	elif up.y < -0.99:
		basis = Basis(Vector3.RIGHT, PI)
	basis = basis.scaled(Vector3(radius, length, radius))
	return Transform3D(basis, pos)

## World position of an OpenXR hand joint (JOINT_* constants); only meaningful when joint_ok(i).
func joint(i: int) -> Vector3:
	return _joint_world_positions[i] if i >= 0 and i < _joint_world_positions.size() else Vector3.ZERO

func joint_ok(i: int) -> bool:
	return is_hand_tracked and i >= 0 and i < _joint_valid.size() and _joint_valid[i]

## Unit normal pointing OUT OF THE PALM (world), from wrist + index/little metacarpals; ZERO if not tracked.
func palm_normal() -> Vector3:
	if not (joint_ok(JOINT_WRIST) and joint_ok(JOINT_INDEX_METACARPAL) and joint_ok(JOINT_LITTLE_METACARPAL)):
		return Vector3.ZERO
	var w := joint(JOINT_WRIST)
	var v1 := joint(JOINT_INDEX_METACARPAL) - w
	var v2 := joint(JOINT_LITTLE_METACARPAL) - w
	var n := v1.cross(v2) if hand_side == HandSide.RIGHT else v2.cross(v1)
	return n.normalized() if n.length_squared() > 1e-8 else Vector3.ZERO
