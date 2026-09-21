class_name XRController
extends XROrigin3D

## XR & Quest 3 Passthrough Controller for RealBallPutting.
## Initializes OpenXR, manages Quest 3 Color Passthrough (Mixed Reality),
## provides a true stereoscopic 3D Split-Screen (VR Green on target/left side, Real Room Passthrough on back/right side for right-handed golfers)
## with ZERO binocular rivalry / eye dizziness, tracks Quest controllers / hands, and coordinates with putting environment.

signal xr_state_changed(active: bool, passthrough: bool)
signal split_mode_changed(mode_name: String, split_offset: float)
signal ball_reset_requested()
signal grid_toggle_requested()

enum SplitMode {
	SPLIT_SCREEN = 0,     ## Half VR / Half Passthrough
	FULL_PASSTHROUGH = 1, ## 100% Passthrough (real physical room)
	FULL_VR = 2           ## 100% Virtual Reality (championship golf course)
}

enum SplitOrientation {
	ACROSS_TARGET_LINE = 0, ## Perpendicular to target line: Left (-Z towards hole) is VR, Right (+Z behind ball) is Passthrough
	ALONG_TARGET_LINE = 1,  ## Parallel to target line: Green is VR, Golfer stance is Passthrough
	HEAD_GAZE_ALIGNED = 2   ## 3D vertical plane turning with head gaze
}

@export_group("Stereoscopic 3D Split Screen")
@export var current_mode: SplitMode = SplitMode.SPLIT_SCREEN
@export var split_orientation: SplitOrientation = SplitOrientation.ACROSS_TARGET_LINE
@export var world_split_offset_z: float = 0.45 ## Distance (m) ahead of tee box where virtual green begins
@export var world_split_offset_x: float = 0.2 ## In meters between stance and ball
@export var divider_width_m: float = 0.018 ## 1.8 cm glowing 3D laser boundary on the turf
@export var invert_split: bool = false ## Invert split side if needed
@export var stick_adjust_speed: float = 0.8 ## meters per second

@export_group("Putting Dynamics & Force")
@export var putt_force_multiplier: float = 1.0 ## Calibrated 1:1 physical mat roll scaling factor (1.0 = direct measured velocity)
@export var use_speed_v2: bool = true ## Speed v2: floor-plane reconstruction + least-squares fit (falls back to photocell gate if invalid)
@export var auto_record_sessions: bool = true ## DEV: start a session recording automatically when the app starts (stops when the headset is taken off / after 5 min)
@export var use_camera_intrinsics: bool = true ## Replace camera_hfov/vfov/tilt with the factory lens calibration reported by the camera (logged at startup)
@export var physical_mat_stimp: float = 12.8 ## Effective Stimp of the PHYSICAL mat, fitted 2026-09-20 to 11 putts with measured roll (rms 5%)

@export_group("Golfer Profile")
@export var golfer_handedness: String = "right" ## "right" = Right-handed golfer; "left" = Left-handed golfer
@export var has_completed_welcome: bool = false ## True once player has confirmed their stance on the welcome screen

@export_group("XR Settings")
@export var play_area_mode: XRInterface.PlayAreaMode = XRInterface.XR_PLAY_AREA_STAGE

@export_group("Scene Node References")
@export var desktop_camera: Camera3D
@export var test_green_controller: Node3D
@export var golf_ball: Node3D
@export var game_menu: Node3D

@export_group("Headset Optical Calibration")
@export var camera_optical_tilt_deg: float = 13.0 ## Calibrated Quest 3 optical downward tilt (removes vertical bias)
@export var camera_hfov_deg: float = 96.0 ## Calibrated Quest 3 tracking camera Horizontal FOV (640x480 4:3 sensor)
@export var camera_vfov_deg: float = 72.0 ## Calibrated Quest 3 tracking camera Vertical FOV (4:3 sensor ratio)
@export var camera_x_offset_m: float = -0.0322 ## Hardware Left RGB baseline (-32.2 mm)
@export var camera_y_offset_m: float = -0.0179 ## Hardware sensor Y offset (-17.9 mm)
@export var camera_z_offset_m: float = -0.0627 ## Hardware sensor forward offset (-62.7 mm)

@export_group("Ball Tracking Mode")
@export var clamp_to_floor: bool = true ## When true, locks marker to floor plane. When false, tracks freely in 3D (sofa, coffee table, in hand)

@export_group("Mini Tee Box (Bullseye Hitting Zone)")
@export var enable_tee_box: bool = true ## When enabled, projects camera ROI around hitting zone
@export var tee_box_pos: Vector3 = Vector3(0.0, 0.002, 1.2) ## 3D World position of the Mini-Tee Bullseye
@export var tee_box_rotation_deg: float = 0.0 ## Putting direction angle in degrees (0 = along -Z towards hole)
@export var tee_bullseye_radius_m: float = 0.06 ## 12 cm circular bullseye ring (6 cm radius)
@export var is_tee_confirmed: bool = false ## When false, putting course is hidden and full passthrough + outlined hands are active for calibration

@onready var xr_camera: XRCamera3D = $XRCamera3D
@onready var left_controller: XRController3D = $LeftController
@onready var right_controller: XRController3D = $RightController
@onready var left_hand_vis = get_node_or_null("LeftHandVisualizer")
@onready var right_hand_vis = get_node_or_null("RightHandVisualizer")

var xr_interface: XRInterface = null
var is_xr_active: bool = false
var is_passthrough_active: bool = false
var _split_materials: Array[ShaderMaterial] = []
var _active_cam_texture: CameraTexture = null
var _cam_poll_timer: float = 0.0
var _ball_tracker_marker: MeshInstance3D = null
var _tee_box_marker: Node3D = null
var _laser_guide: MeshInstance3D = null
var _laser_mat: StandardMaterial3D = null
var _ground_reticle: MeshInstance3D = null
var _ground_reticle_mat: StandardMaterial3D = null
var _smoothed_floor_aim: Vector3 = Vector3.ZERO
var _floor_aim_valid: bool = false
enum TeeDragState {
	NONE,
	MOVE,
	ROTATE_LEFT,
	ROTATE_RIGHT
}

var _tee_drag_state: TeeDragState = TeeDragState.NONE
var _tee_rot_handle_l: MeshInstance3D = null
var _tee_rot_handle_r: MeshInstance3D = null
var _tee_confirm_btn: Node3D = null
var _tee_confirm_mesh: MeshInstance3D = null
var _tee_confirm_mat: StandardMaterial3D = null
var _tee_confirm_label: Label3D = null
var _tee_realign_btn: Node3D = null
var _tee_realign_mesh: MeshInstance3D = null
var _tee_realign_mat: StandardMaterial3D = null
var _tee_realign_label: Label3D = null
var _tee_sim_btn: Node3D = null
# Extra floor buttons (hand-pinch friendly): session recorder + green speed
var _tee_rec_btn: Node3D = null
var _tee_rec_mat: StandardMaterial3D = null
var _tee_rec_label: Label3D = null
var _tee_green_btn: Node3D = null
var _tee_green_mat: StandardMaterial3D = null
var _tee_green_label: Label3D = null
var _rec_active := false
var _rec_dir := ""
var _rec_started_s := 0.0
var _rec_poll_timer := 0.0
var _rec_manual_stop := false # set when YOU stop a recording; blocks the automatic restart
var _rec_autostart_timer := 5.0
var _record_session_requested := false # set from the menu's RECORD SESSION toggle; starts at stance selection
var _rec_hands_tick := 0
var _pinch_released := true # a pinch must be released before it can press another floor button (was re-triggering REC/SIM/GREEN)
var _tee_sim_mesh: MeshInstance3D = null
var _tee_sim_mat: StandardMaterial3D = null
var _tee_sim_label: Label3D = null
var _tee_handle_mat: StandardMaterial3D = null
var _tee_frame_mat: StandardMaterial3D = null
var _tee_glass_mat: StandardMaterial3D = null
var _tee_arc_mat: StandardMaterial3D = null
var _tee_calibration_root: Node3D = null
var _tee_ball_spot_root: Node3D = null
var _tee_ball_spot_mat: StandardMaterial3D = null
var _tee_front_label: Label3D = null
var _tee_degree_label: Label3D = null
var _grab_initial_offset: Vector3 = Vector3.ZERO
var _grab_initial_angle_offset: float = 0.0

var _drag_source: String = ""
var _pinch_hold_time: float = 0.0
var _diag_timer: float = 0.0

# In-VR Debug HUD & Interaction States
var _tee_hud_label: Label3D = null
var _wrist_hud_label: Label3D = null
var _headset_fps_chip: Label3D = null
var _hud_update_timer: float = 0.0
## --- Aim-ray hygiene (2026-09-20) ---------------------------------------------------------------
## A hand ray that only grazes the floor threw the hit point metres away: 22% of the rays the old gate
## accepted landed >3 m from the tee (median 12 deg below horizontal, median reach 4.9 m), and one bad
## frame dragged the tee 42 cm. Tightening the gate keeps 100% of the near-tee rays in the recordings.
const AIM_RAY_MIN_DOWN := -0.30 ## ray must point >= 17 deg below horizontal (was -0.04 = 2.3 deg)
const AIM_RAY_MAX_REACH_M := 4.0 ## floor hit must be within 4 m of the hand (was 12 m)
const AIM_JUMP_MAX_M := 0.35 ## one frame may not move the aim further than this...
const AIM_JUMP_HOLD_S := 0.25 ## ...unless it keeps moving that fast for this long (real fast sweep)
const HOVER_STABLE_S := 0.12 ## hover target must hold this long before a grab registers (was 0: flickered)
## --- Aim from behind ----------------------------------------------------------------------------
## Stand behind the ball looking down your line and pinch-hold: the putting direction is taken from the
## head->tee vector. At ~1.5 m back the head pose is ~20x steadier than a hand ray on the 0.38 m handle.
const AIM_BEHIND_MIN_M := 0.9 ## how far behind the tee you must stand
const AIM_BEHIND_FACING := 0.80 ## dot(head forward, head->tee) must exceed this
const AIM_BEHIND_HOLD_S := 0.6 ## pinch-and-hold time to commit (also averages out head sway)
var _last_raw_floor: Vector3 = Vector3.ZERO
var _aim_reject_t: float = 0.0
var _hover_prev: String = "NONE"
var _hover_stable_t: float = 0.0
var _aim_behind_t: float = 0.0
var _aim_behind_vec: Vector2 = Vector2.ZERO
var _aim_behind_armed: bool = false
var _aim_behind_active: bool = false ## the aim-from-behind prompt owns the beam + degree label this frame
var _grab_cooldown: float = 0.0
var _total_running_time: float = 0.0
var _last_event_str: String = "IDLE (Ready)"
var _last_event_time: float = 0.0
var _last_haptic_str: String = "None"
var _last_haptic_time: float = 0.0
var _last_hover_target: String = "NONE"
var _prev_cam_basis: Basis = Basis.IDENTITY
var _prev_cam_pos: Vector3 = Vector3.ZERO
var _head_angular_speed: float = 0.0
var _head_linear_vel: Vector3 = Vector3.ZERO
var _head_pos_history: Array[Dictionary] = [] # Rolling buffer of {"time": float, "pos": Vector2}
const PuttSpeedEstimator = preload("res://scripts/physics/putt_speed_estimator.gd")
var _cam_pose_history: Array[Dictionary] = [] # Speed v2: {"t": float (ticks sec), "xf": Transform3D} last ~1 s
var _last_speed_v2: Dictionary = {}
var green_speed_mode: String = "mat" ## Green speed preset: mat / slow / normal / fast (see CourseManager)
var _cam_calib: PackedFloat32Array = PackedFloat32Array() # [valid, fx, fy, cx, cy, activeW, activeH, streamW, streamH, tx, ty, tz, qx, qy, qz, qw, tsSource]
var _cam_calib_applied := false
var _cam_calib_poll_timer := 0.0
var _candidate_stroke_pos: Vector2 = Vector2.ZERO
var _candidate_stroke_time: float = 0.0
var _candidate_stroke_count: int = 0
var _last_processed_yolo_seq: float = -1.0
var _sim_speed_index: int = 0
const SIM_SPEEDS := [1.0, 1.5, 1.73]

# Game Flow State Machine
enum GameFlowState {
	MAIN_MENU,
	HANDEDNESS_SELECT,
	TEE_CALIBRATION,
	PUTTING_GAMEPLAY
}
var current_flow_state: GameFlowState = GameFlowState.MAIN_MENU

# Multi-Page 3D Game Menu Panel
var _welcome_panel: Node3D = null
var _welcome_screen_visible: bool = false
var _menu_page_main: Node3D = null
var _menu_page_stance: Node3D = null
var _menu_btn_play: MeshInstance3D = null
var _menu_btn_play_mat: StandardMaterial3D = null
var _welcome_btn_r: MeshInstance3D = null
var _welcome_btn_l: MeshInstance3D = null
var _welcome_btn_r_mat: StandardMaterial3D = null
var _welcome_btn_l_mat: StandardMaterial3D = null
var _welcome_hovered_btn: String = "NONE"

# Input Re-arming: prevents stuck hands by requiring full button release (< 0.15) before next grab
var _right_trigger_armed: bool = true
var _right_grip_armed: bool = true
var _left_trigger_armed: bool = true
var _left_grip_armed: bool = true
var _is_ball_on_tee: bool = false
var _tee_ring_mat: StandardMaterial3D = null
var _tee_spot_mat: StandardMaterial3D = null
var _tee_arrow_mat: StandardMaterial3D = null
var _tee_marker_alpha: float = 1.0
var _ball_teed_timer: float = 0.0
var _marker_fade_timer: float = 0.0
var _filtered_ball_pos: Vector3 = Vector3.ZERO
var _has_filtered_ball: bool = false
var _lost_ball_timer: float = 0.0
var _last_left_norm_x: float = 0.0
var _last_left_norm_y: float = 0.0
var _last_right_norm_x: float = 0.0
var _last_right_norm_y: float = 0.0
var _last_has_stereo: bool = false

# Ball Tracking State Machine
enum BallTrackingState {
	SEARCHING,          ## Camera scanning ROI around tee spot
	APPROACHING_TEE,    ## Ball detected in room, moving toward tee spot
	LOCKED_ON_TEE,      ## Ball stationary inside tee circle (< 8 cm from center)
	STROKE_DETECTED,    ## Putter impact: ball departed P0 rapidly
	BALL_ROLLING        ## Ball rolling towards green
}
var ball_tracking_state: BallTrackingState = BallTrackingState.SEARCHING

# Lock & Fade Sequence & Velocity Tracking State
var _tee_spot_opacity: float = 1.0
var _tee_spot_locked_flash_timer: float = 0.0
var _tee_lock_settle_timer: float = 0.0
var _locked_ball_pos_2d: Vector2 = Vector2.ZERO
var _locked_ball_time: float = 0.0
var _prev_ball_pos_2d: Vector2 = Vector2.ZERO
var _prev_ball_time: float = 0.0
var _instant_ball_vel_2d: Vector2 = Vector2.ZERO
var _ball_rolling_timer: float = 0.0
var _ball_at_tee_recover_timer: float = 0.0
var _launch_speed: float = 0.0
var _launch_direction: Vector2 = Vector2.ZERO
var _launch_angle_deg: float = 0.0
var _hit_timestamp: float = 0.0
var _stroke_travel_dist: float = 0.0
var _last_putt_result: String = ""
var _has_played_lock_sound: bool = false
var _ball_missing_at_tee_timer: float = 0.0
var _ball_seen_recently_timer: float = 0.0
var _stroke_samples: Array[Dictionary] = []
var _stroke_measuring_timer: float = 0.0
var _is_high_speed_telemetry_putt: bool = false
var _tee_timeout_timer: float = 30.0
var _tee_telemetry_label: Label3D = null
var _replay_card: Sprite3D = null
var _replay_card_timer: float = 0.0

# Audio Feedback
var _audio_player: AudioStreamPlayer = null
var _lock_chime_sound: AudioStreamWAV = null

func _ready() -> void:
	_ensure_hand_visualizers()
	_init_xr_subsystem()
	_load_tee_box_settings()
	call_deferred("_apply_green_speed", green_speed_mode, false)
	if auto_record_sessions:
		get_tree().create_timer(3.0).timeout.connect(_auto_start_recording)
	_init_audio()
	_connect_multiplayer_signals()
	call_deferred("_setup_split_screen")
	call_deferred("_init_headset_camera")
	call_deferred("_connect_ball_signals")
	call_deferred("_connect_menu_signals")
	call_deferred("_show_main_menu")

func _init_audio() -> void:
	if _audio_player == null:
		_audio_player = AudioStreamPlayer.new()
		_audio_player.name = "FeedbackAudio"
		add_child(_audio_player)
		_lock_chime_sound = _generate_chime_sound()

func _generate_chime_sound() -> AudioStreamWAV:
	var sample_rate: int = 22050
	var duration: float = 0.35
	var total_samples: int = int(sample_rate * duration)
	var byte_array := PackedByteArray()
	byte_array.resize(total_samples * 2)
	
	for i in range(total_samples):
		var t := float(i) / float(sample_rate)
		# Dual harmonic chime: C6 (1046.5 Hz) + G6 (1567.98 Hz) with soft bell decay envelope
		var decay := exp(-t * 11.0)
		var s := (sin(TAU * 1046.5 * t) * 0.70 + sin(TAU * 1567.98 * t) * 0.30) * decay
		var val := int(clamp(s * 28000.0, -32768.0, 32767.0))
		byte_array.encode_s16(i * 2, val)
		
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.data = byte_array
	return stream

func _play_lock_chime() -> void:
	if _audio_player != null and _lock_chime_sound != null:
		_audio_player.stream = _lock_chime_sound
		_audio_player.volume_db = -4.0
		_audio_player.play()

func _is_looking_at_ball_area() -> bool:
	return is_tee_in_camera_view()

var _bridge_class = null

func _get_bridge_class():
	if _bridge_class != null:
		return _bridge_class
	if Engine.has_singleton("JavaClassWrapper"):
		var jcw = Engine.get_singleton("JavaClassWrapper")
		_bridge_class = jcw.wrap("com.godot.game.HeadsetCameraBridge")
	elif OS.has_feature("android"):
		_bridge_class = JavaClassWrapper.wrap("com.godot.game.HeadsetCameraBridge")
	return _bridge_class

## Uses exact pinhole camera projection to determine if the physical tee is inside
## the Quest 3 tracking camera's optical view frame.
func is_tee_in_camera_view() -> bool:
	if xr_camera == null:
		return true
	var cam_pos = xr_camera.global_position
	var cam_basis = xr_camera.global_transform.basis
	var cam_origin = cam_pos + cam_basis * Vector3(camera_x_offset_m, camera_y_offset_m, camera_z_offset_m)
	var cam_phys_basis = cam_basis * Basis(Vector3.RIGHT, deg_to_rad(-camera_optical_tilt_deg))
	var cam_phys_transform = Transform3D(cam_phys_basis, cam_origin)
	var cam_inv = cam_phys_transform.affine_inverse()

	var tee_pos := _tee_box_marker.global_position if _tee_box_marker != null else tee_box_pos
	var tee_local: Vector3 = cam_inv * tee_pos
	if tee_local.z >= -0.25: # Behind the camera lens
		return false

	var tan_h = tan(deg_to_rad(camera_hfov_deg * 0.5))
	var tan_v = tan(deg_to_rad(camera_vfov_deg * 0.5))
	var tnx = 0.5 + (tee_local.x / (-tee_local.z * 2.0 * tan_h))
	var tny = 0.5 - (tee_local.y / (-tee_local.z * 2.0 * tan_v))

	# Tee spot must be comfortably within the camera view frame (reject peripheral edges during head turns)
	return (tnx >= 0.15 and tnx <= 0.85 and tny >= 0.05 and tny <= 0.95)

func _ball_tracking_state_to_str() -> String:
	match ball_tracking_state:
		BallTrackingState.SEARCHING:
			return "SEARCHING (Place ball on spot)"
		BallTrackingState.APPROACHING_TEE:
			return "BALL DETECTED (Move into circle)"
		BallTrackingState.LOCKED_ON_TEE:
			return "LOCKED ON TEE (Ready to Putt!)"
		BallTrackingState.STROKE_DETECTED:
			return "MEASURING CORRIDOR (Speed: %.2f m/s, Angle: %+.1f°)" % [_launch_speed, _launch_angle_deg]
		BallTrackingState.BALL_ROLLING:
			return "STROKE RECORDED: %.2f m/s (%+.1f°)" % [_launch_speed, _launch_angle_deg]
		_:
			return "IDLE"

func _connect_multiplayer_signals() -> void:
	var match_mgr = get_node_or_null("../MatchManager")
	if match_mgr == null and test_green_controller != null:
		match_mgr = test_green_controller.get_node_or_null("MatchManager")
	if match_mgr != null and match_mgr.has_signal("active_player_changed"):
		if not match_mgr.is_connected("active_player_changed", _on_active_player_changed):
			match_mgr.connect("active_player_changed", _on_active_player_changed)

func _on_active_player_changed(player) -> void:
	if player != null and player.get("handedness") != null:
		var h: String = player.get("handedness")
		set_golfer_handedness(h)
		print("[XRController] Local Multiplayer turn: %s (%s-handed). MR split adapted." % [player.get("player_name"), h.capitalize()])

func _connect_ball_signals() -> void:
	if golf_ball == null:
		if test_green_controller != null:
			golf_ball = test_green_controller.get_node_or_null("GolfBall")
		if golf_ball == null:
			golf_ball = get_node_or_null("../GolfBall")
	
	if golf_ball != null:
		if golf_ball.has_signal("ball_stopped") and not golf_ball.is_connected("ball_stopped", _on_virtual_ball_stopped):
			golf_ball.connect("ball_stopped", _on_virtual_ball_stopped)
		if golf_ball.has_signal("ball_holed") and not golf_ball.is_connected("ball_holed", _on_virtual_ball_holed):
			golf_ball.connect("ball_holed", _on_virtual_ball_holed)

func _on_virtual_ball_stopped(final_pos: Vector3) -> void:
	# End image recording now that the ball has come to a rest!
	var bridge = _get_bridge_class()
	if bridge != null:
		bridge.stopPuttRecording()

	var cup_world := Vector3.ZERO
	if test_green_controller != null and test_green_controller.get("flag_assembly") != null:
		cup_world = test_green_controller.get("flag_assembly").global_position
	var dist_to_cup := Vector2(final_pos.x - cup_world.x, final_pos.z - cup_world.z).length()
	var dist_str := "%.2fm (%.1f ft)" % [dist_to_cup, dist_to_cup * 3.28084]
	
	# Total roll distance from the tee spot
	var total_roll := Vector2(final_pos.x - tee_box_pos.x, final_pos.z - tee_box_pos.z).length()
	var roll_cm := total_roll * 100.0
	var roll_ft := total_roll * 3.28084
	
	_last_putt_result = "Speed: %.2f m/s | Angle: %+.1f° | Roll: %.2fm (%.0f cm)" % [
		_launch_speed, _launch_angle_deg, total_roll, roll_cm
	]
	print("[PUTT] >>> 4. BALL AT REST: total_roll=%.2fm (%.1f cm / %.1fft), speed=%.2f m/s (%.1f mph), angle=%+.1f°, dist_to_flag=%s <<<" % [
		total_roll, roll_cm, roll_ft, _launch_speed, _launch_speed * 2.23694, _launch_angle_deg, dist_str
	])
	_record_event("STOPPED: roll=%.2fm (%.0fcm), to_cup=%s" % [total_roll, roll_cm, dist_str])
	
	if _tee_telemetry_label != null:
		_tee_telemetry_label.text = "SPEED: %.2f m/s (%.1f mph)\nANGLE: %+.1f°\nTOTAL ROLL: %.2fm (%.0f cm)" % [
			_launch_speed, _launch_speed * 2.23694, _launch_angle_deg, total_roll, roll_cm
		]
		_tee_telemetry_label.modulate = Color(0.2, 0.9, 1.0, 0.98)
		
	if ball_tracking_state == BallTrackingState.BALL_ROLLING:
		# 0.5 second cooldown so player can quickly address and putt again
		get_tree().create_timer(0.5).timeout.connect(func():
			if ball_tracking_state == BallTrackingState.BALL_ROLLING:
				reset_putting_ball()
				_record_event("READY FOR NEXT PUTT")
		)

func _on_virtual_ball_holed() -> void:
	var bridge = _get_bridge_class()
	if bridge != null:
		bridge.stopPuttRecording()

	var cup_world := Vector3.ZERO
	if test_green_controller != null and test_green_controller.get("flag_assembly") != null:
		cup_world = test_green_controller.get("flag_assembly").global_position
	var total_roll := Vector2(cup_world.x - tee_box_pos.x, cup_world.z - tee_box_pos.z).length()
	var roll_cm := total_roll * 100.0

	_last_putt_result = "HOLED! Speed: %.2f m/s | Angle: %+.1f° | Roll: %.2fm" % [_launch_speed, _launch_angle_deg, total_roll]
	print("[PUTT] >>> 4. BALL HOLED IN CUP! Putt sunk! total_roll=%.2fm (%.0f cm), speed=%.2f m/s (%.1f mph), angle=%+.1f° <<<" % [
		total_roll, roll_cm, _launch_speed, _launch_speed * 2.23694, _launch_angle_deg
	])
	_record_event("BALL HOLED! Roll: %.2fm" % total_roll)
	_play_lock_chime()
	var lead_ctrl = right_controller if golfer_handedness == "right" else left_controller
	_pulse_haptic(lead_ctrl, golfer_handedness, 1.0, 0.35, "BALL_HOLED")
	
	if _tee_telemetry_label != null:
		_tee_telemetry_label.text = "HOLED IN ONE!\nSPEED: %.2f m/s\nROLL: %.2fm (%.0f cm)" % [
			_launch_speed, total_roll, roll_cm
		]
		_tee_telemetry_label.modulate = Color(0.1, 1.0, 0.4, 0.98)
	
	var match_mgr = get_node_or_null("../MatchManager")
	if match_mgr == null and test_green_controller != null:
		match_mgr = test_green_controller.get_node_or_null("MatchManager")
	if match_mgr != null and match_mgr.has_method("hole_out_current_player"):
		match_mgr.call("hole_out_current_player")
	
	get_tree().create_timer(2.5).timeout.connect(func():
		reset_putting_ball()
	)

func _record_match_stroke(launch_speed: float) -> void:
	var match_mgr = get_node_or_null("../MatchManager")
	if match_mgr == null and test_green_controller != null:
		match_mgr = test_green_controller.get_node_or_null("MatchManager")
	if match_mgr != null and match_mgr.has_method("record_stroke"):
		match_mgr.call("record_stroke", launch_speed)

func reset_putting_ball() -> void:
	ball_tracking_state = BallTrackingState.SEARCHING
	_is_ball_on_tee = false
	_has_played_lock_sound = false
	_ball_missing_at_tee_timer = 0.0
	_ball_seen_recently_timer = 0.0
	_tee_spot_opacity = 1.0
	_tee_spot_locked_flash_timer = 0.0
	_tee_lock_settle_timer = 0.8
	_tee_timeout_timer = 30.0
	_ball_rolling_timer = 0.0
	_ball_at_tee_recover_timer = 0.0
	_locked_ball_pos_2d = Vector2.ZERO
	_prev_ball_pos_2d = Vector2.ZERO
	_instant_ball_vel_2d = Vector2.ZERO
	_candidate_stroke_count = 0
	_candidate_stroke_pos = Vector2.ZERO
	_candidate_stroke_time = 0.0
	_stroke_samples.clear()
	_stroke_measuring_timer = 0.0
	_replay_card_timer = 0.0
	if _replay_card != null:
		_replay_card.visible = false
	
	if _tee_ball_spot_root != null:
		_tee_ball_spot_root.visible = true
	if _tee_ball_spot_mat != null:
		_tee_ball_spot_mat.albedo_color = Color(0.2, 0.85, 1.0, 0.85)
		
	if golf_ball != null:
		if golf_ball.has_method("reset_to_position"):
			golf_ball.call("reset_to_position", Vector2(tee_box_pos.x, tee_box_pos.z), true)
		golf_ball.visible = false # Strictly hidden while at rest on tee
	
	var bridge = _get_bridge_class()
	if bridge != null:
		bridge.disarmHighSpeedCorridor()
		bridge.resumeYoloInference()
		bridge.setExposureLock(false)
	
	_record_event("BALL RESET TO TEE")
	print("[XRController] Putting ball reset: state=SEARCHING, YOLO resumed, tee_spot visible.")

func _connect_menu_signals() -> void:
	if game_menu == null and test_green_controller != null:
		game_menu = test_green_controller.get_node_or_null("GameMenu")
	if game_menu == null:
		game_menu = get_node_or_null("../GameMenu")
	
	if game_menu != null:
		if game_menu.has_signal("play_pressed") and not game_menu.is_connected("play_pressed", _on_game_menu_play_pressed):
			game_menu.connect("play_pressed", _on_game_menu_play_pressed)
		if game_menu.has_signal("handedness_selected") and not game_menu.is_connected("handedness_selected", _on_game_menu_handedness_selected):
			game_menu.connect("handedness_selected", _on_game_menu_handedness_selected)
		if game_menu.has_signal("record_session_toggled") and not game_menu.is_connected("record_session_toggled", _on_record_session_toggled):
			game_menu.connect("record_session_toggled", _on_record_session_toggled)
		if game_menu.has_signal("green_speed_selected") and not game_menu.is_connected("green_speed_selected", _on_green_speed_selected):
			game_menu.connect("green_speed_selected", _on_green_speed_selected)
		if game_menu.has_method("setup_green_speed_selector"):
			game_menu.call("setup_green_speed_selector", CourseManager.GREEN_SPEED_PRESETS, green_speed_mode, physical_mat_stimp)
		print("[XRController] Connected to GameMenu signals.")

# ------------------------------------------------------------------ Green speed presets
func _get_course_manager():
	if test_green_controller != null:
		var cm = test_green_controller.get("course_manager")
		if cm != null:
			return cm
	return null

func _apply_green_speed(mode: String, announce: bool = true) -> void:
	green_speed_mode = mode
	var stimp := physical_mat_stimp
	var cm = _get_course_manager()
	if cm != null:
		stimp = cm.set_green_speed(mode, physical_mat_stimp)
	elif golf_ball != null:
		for p in CourseManager.GREEN_SPEED_PRESETS:
			if p["id"] == mode and float(p["stimp"]) > 0.0:
				stimp = float(p["stimp"])
		golf_ball.set("stimp_rating", stimp)
	if game_menu != null and game_menu.has_method("set_selected_green_speed"):
		game_menu.call("set_selected_green_speed", mode)
	_update_green_button_label()
	if announce:
		var label := mode.to_upper()
		for p in CourseManager.GREEN_SPEED_PRESETS:
			if p["id"] == mode:
				label = str(p["label"])
		_record_event("GREEN SPEED: %s (Stimp %.1f)" % [label, stimp])
		if _tee_telemetry_label != null:
			_tee_telemetry_label.text = "GREEN SPEED: %s\nStimp %.1f" % [label, stimp]
		_save_tee_box_settings()

func _on_green_speed_selected(mode: String) -> void:
	_apply_green_speed(mode, true)

func cycle_green_speed() -> void:
	var ids := []
	for p in CourseManager.GREEN_SPEED_PRESETS:
		ids.append(p["id"])
	var idx := ids.find(green_speed_mode)
	_apply_green_speed(ids[(idx + 1) % ids.size()], true)

func _on_game_menu_play_pressed() -> void:
	current_flow_state = GameFlowState.HANDEDNESS_SELECT
	var dom_c = right_controller if golfer_handedness == "right" else left_controller
	var dom_h = "right" if golfer_handedness == "right" else "left"
	_pulse_haptic(dom_c, dom_h, 0.5, 0.05, "Show Stance Select")
	print("[XRController] GameMenu: Play pressed -> Stance selection.")

func _on_game_menu_handedness_selected(h: String) -> void:
	print("[XRController] GameMenu: Handedness selected: ", h)
	_select_handedness(h)

func _ensure_hand_visualizers() -> void:
	if left_hand_vis == null:
		left_hand_vis = get_node_or_null("LeftHandVisualizer")
		if left_hand_vis == null:
			var lvis = XRHandVisualizer.new()
			lvis.name = "LeftHandVisualizer"
			lvis.hand_side = XRHandVisualizer.HandSide.LEFT
			add_child(lvis)
			left_hand_vis = lvis
	if right_hand_vis == null:
		right_hand_vis = get_node_or_null("RightHandVisualizer")
		if right_hand_vis == null:
			var rvis = XRHandVisualizer.new()
			rvis.name = "RightHandVisualizer"
			rvis.hand_side = XRHandVisualizer.HandSide.RIGHT
			add_child(rvis)
			right_hand_vis = rvis

func _set_hand_visualizers_enabled(enabled: bool) -> void:
	if left_hand_vis != null:
		if left_hand_vis.has_method("set_hands_enabled"):
			left_hand_vis.call("set_hands_enabled", enabled)
		else:
			left_hand_vis.visible = enabled
	if right_hand_vis != null:
		if right_hand_vis.has_method("set_hands_enabled"):
			right_hand_vis.call("set_hands_enabled", enabled)
		else:
			right_hand_vis.visible = enabled
func _init_headset_camera() -> void:
	if OS.has_feature("android"):
		print("[XRController] Requesting Android CAMERA & HEADSET_CAMERA permissions...")
		OS.request_permissions()
	
	# Camera feeds detected on headset:
	CameraServer.set_monitoring_feeds(true)
	var feeds = CameraServer.feeds()
	print("[XRController] CameraServer monitoring enabled. Total feeds found: ", feeds.size())
	for i in range(feeds.size()):
		var f: CameraFeed = feeds[i]
		print("[XRController] Camera Feed [%d]: name='%s', id=%d, active=%s, datatype=%d" % [
			i, f.get_name(), f.get_id(), f.is_active(), f.get_datatype()
		])
	
	print("[XRController] Headset camera stream managed by HeadsetCameraBridge. Starting detection loop.")

func _init_xr_subsystem() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("[XRController] OpenXR interface successfully detected and initialized!")
		is_xr_active = true
		
		# Optimize display settings for VR headset
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_viewport().use_xr = true
		
		# Set play area if supported
		if xr_interface.supports_play_area_mode(play_area_mode):
			xr_interface.set_play_area_mode(play_area_mode)
		
		# Disable desktop inspection camera to avoid viewport competition
		if desktop_camera != null:
			desktop_camera.current = false
		if xr_camera != null:
			xr_camera.current = true

		# Connect session lifecycle to ensure passthrough is applied once session begins and gains focus
		if xr_interface.has_signal("session_begun"):
			xr_interface.session_begun.connect(_on_session_begun)
		if xr_interface.has_signal("session_focussed"):
			xr_interface.session_focussed.connect(_on_session_focussed)
		if xr_interface.has_signal("session_stopping"):
			xr_interface.session_stopping.connect(func(): _stop_recording_if_active("XR session stopping"))
		if xr_interface.has_signal("session_visible"):
			# FOCUSED -> VISIBLE happens when the headset is taken off (or a system overlay takes focus)
			xr_interface.session_visible.connect(func(): _stop_recording_if_active("headset focus lost"))

		# Query and configure OpenXR display refresh rate (Meta Quest Store target: 90 Hz / baseline 72 Hz)
		var oxr = xr_interface as OpenXRInterface if xr_interface is OpenXRInterface else null
		if oxr != null:
			var avail_rates = oxr.get_available_display_refresh_rates()
			var cur_rate = oxr.get_display_refresh_rate()
			print("[XRController] OpenXR display refresh rates: %s (active: %.1f Hz)" % [avail_rates, cur_rate])
			if 90.0 in avail_rates and cur_rate != 90.0:
				oxr.set_display_refresh_rate(90.0)
				print("[XRController] Configured OpenXR display refresh rate to 90.0 Hz.")

		_setup_headset_fps_chip()
		_log_passthrough_status()
		_connect_controller_signals()
	else:
		print("[XRController] OpenXR not active or running in desktop preview. Falling back to desktop camera.")
		is_xr_active = false
		if desktop_camera != null:
			desktop_camera.current = true

func _setup_split_screen() -> void:
	_collect_split_materials()
	_apply_initial_tee_state()

func _process(delta: float) -> void:
	# Track headset angular and linear velocity to reject stroke detections during head turns
	# and compensate for head ego-motion (head sway) during the putting stroke
	if xr_camera != null:
		var cur_basis = xr_camera.global_transform.basis
		var cur_pos = xr_camera.global_position
		if delta > 0.001:
			if _prev_cam_basis != Basis.IDENTITY:
				var q_diff = cur_basis.get_rotation_quaternion() * _prev_cam_basis.get_rotation_quaternion().inverse()
				_head_angular_speed = q_diff.get_angle() / delta
			if _prev_cam_pos != Vector3.ZERO:
				_head_linear_vel = (cur_pos - _prev_cam_pos) / delta
		_prev_cam_basis = cur_basis
		_prev_cam_pos = cur_pos

		# Maintain 0.6s of head position history for ego-motion compensation during stroke interval dt
		var cur_head_pos_2d := Vector2(cur_pos.x, cur_pos.z)
		_head_pos_history.append({"time": _total_running_time, "pos": cur_head_pos_2d})
		while _head_pos_history.size() > 1 and (_total_running_time - _head_pos_history[0]["time"]) > 0.60:
			_head_pos_history.pop_front()

		# Speed v2: full head pose history (wall-clock ticks) to unproject camera samples at their exposure time
		var now_s := Time.get_ticks_usec() / 1_000_000.0
		_cam_pose_history.append({"t": now_s, "xf": xr_camera.global_transform})
		while _cam_pose_history.size() > 2 and now_s - float(_cam_pose_history[0]["t"]) > 1.2:
			_cam_pose_history.pop_front()

		# Session recorder: stream head pose (position + quaternion) and keep the REC label up to date
		if _rec_active:
			var rb = _get_bridge_class()
			if rb != null:
				var q: Quaternion = cur_basis.get_rotation_quaternion()
				rb.recordHeadPose(cur_pos.x, cur_pos.y, cur_pos.z, q.x, q.y, q.z, q.w)
				_rec_hands_tick += 1
				if _rec_hands_tick % 2 == 0:
					rb.recordEvent(_hands_state_json())
				_rec_poll_timer -= delta
				if _rec_poll_timer <= 0.0:
					_rec_poll_timer = 0.5
					if not rb.isSessionRecording():
						_on_recording_stopped("time limit reached")
					elif _tee_rec_label != null:
						var secs := int(Time.get_ticks_msec() / 1000.0 - _rec_started_s)
						_tee_rec_label.text = "■ STOP  %d:%02d" % [secs / 60, secs % 60]

		# Auto-record: if a recording stopped for any reason (app pause, headset off, focus loss), start a new one
		if auto_record_sessions and not _rec_active and not _rec_manual_stop:
			_rec_autostart_timer -= delta
			if _rec_autostart_timer <= 0.0:
				_rec_autostart_timer = 5.0
				_auto_start_recording()

		# Pick up the camera's factory lens calibration once it is available
		if not _cam_calib_applied:
			_cam_calib_poll_timer -= delta
			if _cam_calib_poll_timer <= 0.0:
				_cam_calib_poll_timer = 1.0
				_try_apply_camera_calibration()

		# Feed live head pose to HeadsetCameraBridge for streaming HUD
		var bridge = _get_bridge_class()
		if bridge != null:
			var rot = cur_basis.get_euler()
			bridge.updateHeadPose(cur_pos.x, cur_pos.y, cur_pos.z, rad_to_deg(rot.x), rad_to_deg(rot.y), rad_to_deg(rot.z))

	# Read primary thumbstick on controllers to adjust split screen position
	var stick := Vector2.ZERO
	if right_controller != null and right_controller.get_is_active():
		var v: Vector2 = right_controller.get_vector2("primary")
		if v.length() > 0.15:
			stick = v
	if stick == Vector2.ZERO and left_controller != null and left_controller.get_is_active():
		var v: Vector2 = left_controller.get_vector2("primary")
		if v.length() > 0.15:
			stick = v

	if stick != Vector2.ZERO and current_mode == SplitMode.SPLIT_SCREEN:
		if split_orientation == SplitOrientation.ACROSS_TARGET_LINE:
			# Push stick forward (negative Y) or backward to move divider along Z
			var stick_delta = (-stick.y if abs(stick.y) > abs(stick.x) else -stick.x)
			world_split_offset_z = clamp(world_split_offset_z + stick_delta * delta * stick_adjust_speed, -1.0, 5.0)
		elif split_orientation == SplitOrientation.ALONG_TARGET_LINE:
			world_split_offset_x = clamp(world_split_offset_x + stick.x * delta * stick_adjust_speed, -2.5, 2.5)
		_apply_active_plane()

	# If in HEAD_GAZE_ALIGNED mode, update plane every frame to track head rotation with stereoscopic convergence
	if current_mode == SplitMode.SPLIT_SCREEN and split_orientation == SplitOrientation.HEAD_GAZE_ALIGNED:
		_apply_active_plane()
	
	# Update OpenXR Hand Visualizers
	# Hands are visible ONLY during menus or calibration; completely hidden when putting!
	var hands_active: bool = (current_flow_state != GameFlowState.PUTTING_GAMEPLAY)
	_set_hand_visualizers_enabled(hands_active)
	var eye_pos = xr_camera.global_position if xr_camera != null else global_position + Vector3(0, 1.65, 0)
	var oxr = xr_interface as OpenXRInterface if xr_interface is OpenXRInterface else null
	if left_hand_vis != null and left_hand_vis.has_method("update_hand_tracking"):
		left_hand_vis.call("update_hand_tracking", oxr, global_transform, eye_pos)
		left_hand_vis.call("process_effects", delta)
	if right_hand_vis != null and right_hand_vis.has_method("update_hand_tracking"):
		right_hand_vis.call("update_hand_tracking", oxr, global_transform, eye_pos)
		right_hand_vis.call("process_effects", delta)

	# Update Mini Tee Box (Bullseye Hitting Zone) or Welcome Screen
	if _welcome_screen_visible:
		_process_welcome_screen(delta)
		if _tee_box_marker != null:
			_tee_box_marker.visible = false
	elif enable_tee_box:
		_ensure_tee_box_marker()
		if _tee_box_marker != null:
			# Track running time and decrement cooldown
			_total_running_time += delta
			if _grab_cooldown > 0.0:
				_grab_cooldown = max(0.0, _grab_cooldown - delta)
			
			var r_ctrl_active: bool = (right_controller != null and right_controller.get_is_active())
			var l_ctrl_active: bool = (left_controller != null and left_controller.get_is_active())
			var r_hand_active: bool = (right_hand_vis != null and right_hand_vis.is_hand_tracked)
			var l_hand_active: bool = (left_hand_vis != null and left_hand_vis.is_hand_tracked)
			
			var rt: float = right_controller.get_float("trigger") if r_ctrl_active else 0.0
			var rg: float = right_controller.get_float("grip") if r_ctrl_active else 0.0
			var lt: float = left_controller.get_float("trigger") if l_ctrl_active else 0.0
			var lg: float = left_controller.get_float("grip") if l_ctrl_active else 0.0
			var r_pinch_dist: float = right_hand_vis.pinch_distance_m if r_hand_active else 1.0
			var l_pinch_dist: float = left_hand_vis.pinch_distance_m if l_hand_active else 1.0
			
			# Floor intersection for Right hand/controller
			var r_has_aim: bool = false
			var r_aim_origin: Vector3 = Vector3.ZERO
			var r_aim_dir: Vector3 = Vector3.ZERO
			if r_hand_active:
				r_aim_origin = right_hand_vis.pinch_midpoint
				r_aim_dir = right_hand_vis.pinch_aim_direction
				r_has_aim = true
			elif r_ctrl_active:
				r_aim_origin = right_controller.global_position
				r_aim_dir = -right_controller.global_transform.basis.z
				r_has_aim = true
			
			var r_floor_pt = Vector3.ZERO
			var r_floor_valid = false
			if r_has_aim and r_aim_dir.y < AIM_RAY_MIN_DOWN:
				var t = (0.002 - r_aim_origin.y) / r_aim_dir.y
				if t > 0.05 and t < AIM_RAY_MAX_REACH_M:
					r_floor_pt = r_aim_origin + r_aim_dir * t
					r_floor_pt.y = 0.002
					r_floor_valid = true
			
			# Floor intersection for Left hand/controller
			var l_has_aim: bool = false
			var l_aim_origin: Vector3 = Vector3.ZERO
			var l_aim_dir: Vector3 = Vector3.ZERO
			if l_hand_active:
				l_aim_origin = left_hand_vis.pinch_midpoint
				l_aim_dir = left_hand_vis.pinch_aim_direction
				l_has_aim = true
			elif l_ctrl_active:
				l_aim_origin = left_controller.global_position
				l_aim_dir = -left_controller.global_transform.basis.z
				l_has_aim = true
			
			var l_floor_pt = Vector3.ZERO
			var l_floor_valid = false
			if l_has_aim and l_aim_dir.y < AIM_RAY_MIN_DOWN:
				var t = (0.002 - l_aim_origin.y) / l_aim_dir.y
				if t > 0.05 and t < AIM_RAY_MAX_REACH_M:
					l_floor_pt = l_aim_origin + l_aim_dir * t
					l_floor_pt.y = 0.002
					l_floor_valid = true
			
			# Determine active aiming controller (seamless ambidextrous control)
			var active_aim_ctrl: XRController3D = null
			var active_aim_origin: Vector3 = Vector3.ZERO
			var active_raw_floor: Vector3 = Vector3.ZERO
			var active_aim_hand: String = ""
			var active_grip: float = 0.0
			var active_trig: float = 0.0
			var active_pinch: float = 1.0
			var active_is_hand: bool = false
			
			if _tee_drag_state != TeeDragState.NONE:
				if _drag_source.begins_with("right"):
					active_aim_ctrl = right_controller
					active_aim_origin = r_aim_origin
					active_raw_floor = r_floor_pt
					active_aim_hand = "right"
					active_grip = rg
					active_trig = rt
					active_pinch = r_pinch_dist
					active_is_hand = r_hand_active
					_floor_aim_valid = r_floor_valid
				else:
					active_aim_ctrl = left_controller
					active_aim_origin = l_aim_origin
					active_raw_floor = l_floor_pt
					active_aim_hand = "left"
					active_grip = lg
					active_trig = lt
					active_pinch = l_pinch_dist
					active_is_hand = l_hand_active
					_floor_aim_valid = l_floor_valid
			else:
				var r_gripping = (rg >= 0.25 or (r_hand_active and r_pinch_dist < 0.038))
				var l_gripping = (lg >= 0.25 or (l_hand_active and l_pinch_dist < 0.038))
				
				if r_gripping and r_floor_valid:
					active_aim_hand = "right"
				elif l_gripping and l_floor_valid:
					active_aim_hand = "left"
				elif r_floor_valid and not l_floor_valid:
					active_aim_hand = "right"
				elif l_floor_valid and not r_floor_valid:
					active_aim_hand = "left"
				elif r_floor_valid and l_floor_valid:
					var rd = r_floor_pt.distance_to(tee_box_pos)
					var ld = l_floor_pt.distance_to(tee_box_pos)
					active_aim_hand = "right" if rd <= ld else "left"
				elif golfer_handedness == "right" and r_has_aim:
					active_aim_hand = "right"
				elif golfer_handedness == "left" and l_has_aim:
					active_aim_hand = "left"
				elif r_has_aim:
					active_aim_hand = "right"
				elif l_has_aim:
					active_aim_hand = "left"
				
				if active_aim_hand == "right":
					active_aim_ctrl = right_controller
					active_aim_origin = r_aim_origin
					active_raw_floor = r_floor_pt
					active_grip = rg
					active_trig = rt
					active_pinch = r_pinch_dist
					active_is_hand = r_hand_active
					_floor_aim_valid = r_floor_valid
				elif active_aim_hand == "left":
					active_aim_ctrl = left_controller
					active_aim_origin = l_aim_origin
					active_raw_floor = l_floor_pt
					active_grip = lg
					active_trig = lt
					active_pinch = l_pinch_dist
					active_is_hand = l_hand_active
					_floor_aim_valid = l_floor_valid
				else:
					_floor_aim_valid = false
			
			if _floor_aim_valid:
				# Reject ray blow-ups: hold the previous aim rather than teleporting the tee with it.
				var jump: float = 0.0 if _last_raw_floor == Vector3.ZERO else active_raw_floor.distance_to(_last_raw_floor)
				if jump > AIM_JUMP_MAX_M and _aim_reject_t < AIM_JUMP_HOLD_S:
					_aim_reject_t += delta
				else:
					_aim_reject_t = 0.0
					_last_raw_floor = active_raw_floor
					if _smoothed_floor_aim == Vector3.ZERO:
						_smoothed_floor_aim = active_raw_floor
					else:
						_smoothed_floor_aim = _smoothed_floor_aim.lerp(active_raw_floor, clamp(delta * 24.0, 0.0, 1.0))
					_smoothed_floor_aim.y = 0.002
			else:
				_last_raw_floor = Vector3.ZERO
				_aim_reject_t = 0.0
			
			var hover_target: String = "NONE"
			
			# 1. Check active dragging state and test for release
			if _tee_drag_state != TeeDragState.NONE:
				var is_still_holding: bool = false
				if _drag_source.ends_with("_pinch"):
					is_still_holding = active_is_hand and active_pinch <= 0.046
				elif _drag_source.ends_with("_grip"):
					is_still_holding = active_grip >= 0.20
				elif _drag_source.ends_with("_trigger"):
					is_still_holding = active_trig >= 0.20
				
				if is_still_holding and _floor_aim_valid:
					var handle_l_local = Vector3(0.38 * sin(deg_to_rad(-75.0)), 0.012, 0.38 * cos(deg_to_rad(-75.0)))
					var handle_r_local = Vector3(0.38 * sin(deg_to_rad(75.0)), 0.012, 0.38 * cos(deg_to_rad(75.0)))
					
					if _tee_drag_state == TeeDragState.MOVE:
						var target_pos = _smoothed_floor_aim + _grab_initial_offset
						target_pos.y = 0.002
						tee_box_pos = tee_box_pos.lerp(target_pos, clamp(delta * 22.0, 0.0, 1.0))
						_update_laser_guide(active_aim_origin, tee_box_pos, Color(1.0, 0.85, 0.2, 0.95), 0.07)
					elif _tee_drag_state == TeeDragState.ROTATE_LEFT or _tee_drag_state == TeeDragState.ROTATE_RIGHT:
						var hand_angle = rad_to_deg(atan2(-(_smoothed_floor_aim.x - tee_box_pos.x), -(_smoothed_floor_aim.z - tee_box_pos.z)))
						var target_rot = hand_angle + _grab_initial_angle_offset
						var cur_rad = deg_to_rad(tee_box_rotation_deg)
						var tgt_rad = deg_to_rad(target_rot)
						tee_box_rotation_deg = rad_to_deg(lerp_angle(cur_rad, tgt_rad, clamp(delta * 20.0, 0.0, 1.0)))
						
						var active_handle_pos = handle_l_local if _tee_drag_state == TeeDragState.ROTATE_LEFT else handle_r_local
						var active_handle_world = _tee_box_marker.global_transform * active_handle_pos
						_update_laser_guide(active_aim_origin, active_handle_world, Color(0.1, 0.7, 1.0, 0.95), 0.06)
						if _tee_degree_label != null:
							_tee_degree_label.visible = true
							_tee_degree_label.text = "AIM: %.1f°" % tee_box_rotation_deg
				else:
					# Clean drop & auto-save
					_tee_drag_state = TeeDragState.NONE
					_drag_source = ""
					_grab_cooldown = 0.20
					_save_tee_box_settings()
					if _tee_degree_label != null:
						_tee_degree_label.visible = false
					_pulse_haptic(active_aim_ctrl, active_aim_hand, 0.55, 0.05, "Drop Tee")
					_record_event("Mini-Tee Released & Saved")
			
			# 2. When NOT dragging: Magnetic Snap, Grab Initiation, and Idle Aim Reticle
			else:
				var hover_spot: Vector3 = _smoothed_floor_aim
				
				if not is_tee_confirmed and _floor_aim_valid:
					var tee_inv = _tee_box_marker.global_transform.affine_inverse()
					var loc = tee_inv * _smoothed_floor_aim
					var handle_l_local = Vector3(0.38 * sin(deg_to_rad(-75.0)), 0.012, 0.38 * cos(deg_to_rad(-75.0)))
					var handle_r_local = Vector3(0.38 * sin(deg_to_rad(75.0)), 0.012, 0.38 * cos(deg_to_rad(75.0)))
					var confirm_btn_local = Vector3(0.0, 0.08, -0.34)
					
					# 0. Prioritize Confirmation Button (during setup)
					if loc.distance_to(Vector3(0.0, 0.0, -0.34)) < 0.22:
						hover_target = "CONFIRM_BTN"
						hover_spot = _tee_box_marker.global_transform * confirm_btn_local
					# 1. Prioritize rotation handles: generous 0.22m detection zone around each anchor
					elif loc.distance_to(handle_l_local) < 0.22:
						hover_target = "HANDLE_L"
						hover_spot = _tee_box_marker.global_transform * handle_l_local
					elif loc.distance_to(handle_r_local) < 0.22:
						hover_target = "HANDLE_R"
						hover_spot = _tee_box_marker.global_transform * handle_r_local
					else:
						# 2. Only check center mat snap if not aiming near rotation handles
						var tee_2d = Vector2(tee_box_pos.x, tee_box_pos.z)
						var aim_2d = Vector2(_smoothed_floor_aim.x, _smoothed_floor_aim.z)
						var dist_to_tee = aim_2d.distance_to(tee_2d)
						var snap_radius = 0.38 if (_last_hover_target == "MAT") else 0.28
						if dist_to_tee < snap_radius:
							hover_target = "MAT"
							hover_spot = tee_box_pos
				elif is_tee_confirmed and _floor_aim_valid:
					var tee_inv = _tee_box_marker.global_transform.affine_inverse()
					var loc = tee_inv * _smoothed_floor_aim
					var realign_btn_local = Vector3(-0.13, 0.05, 0.38)
					var sim_btn_local = Vector3(0.13, 0.05, 0.38)
					if loc.distance_to(realign_btn_local) < 0.16:
						hover_target = "REALIGN_BTN"
						hover_spot = _tee_box_marker.global_transform * realign_btn_local
					elif loc.distance_to(sim_btn_local) < 0.16:
						hover_target = "SIM_BTN"
						hover_spot = _tee_box_marker.global_transform * sim_btn_local
					elif loc.distance_to(Vector3(0.39, 0.05, 0.38)) < 0.13:
						hover_target = "REC_BTN"
						hover_spot = _tee_box_marker.global_transform * Vector3(0.39, 0.05, 0.38)
					elif loc.distance_to(Vector3(-0.39, 0.05, 0.38)) < 0.13:
						hover_target = "GREEN_BTN"
						hover_spot = _tee_box_marker.global_transform * Vector3(-0.39, 0.05, 0.38)
					else:
						hover_target = "NONE"
				else:
					hover_target = "NONE"
				
				# Hover hysteresis: HANDLE_R/MAT/NONE used to flicker frame to frame, so a grab landed on
				# whatever happened to be under the ray. Require the target to hold still first.
				if hover_target == _hover_prev:
					_hover_stable_t += delta
				else:
					_hover_prev = hover_target
					_hover_stable_t = 0.0
				
				# Grab Initiation on active controller:
				if not active_is_hand or active_pinch > 0.055:
					_pinch_released = true
				if hover_target != "NONE" and _grab_cooldown <= 0.0 and _hover_stable_t >= HOVER_STABLE_S:
					var grab_triggered = false
					var grab_src = ""
					if active_is_hand and active_pinch < 0.038 and _pinch_released:
						_pinch_released = false
						grab_triggered = true
						grab_src = active_aim_hand + "_pinch"
					elif not active_is_hand:
						if active_grip >= 0.28: # Grip grab (natural VR gesture)
							grab_triggered = true
							grab_src = active_aim_hand + "_grip"
						elif active_trig >= 0.35: # Trigger grab
							grab_triggered = true
							grab_src = active_aim_hand + "_trigger"
					
					if grab_triggered:
						if hover_target == "CONFIRM_BTN":
							confirm_tee_placement()
							_grab_cooldown = 0.40
						elif hover_target == "REALIGN_BTN":
							realign_tee()
							_grab_cooldown = 0.40
						elif hover_target == "SIM_BTN":
							simulate_putt()
							_grab_cooldown = 0.40
						elif hover_target == "REC_BTN":
							toggle_session_recording()
							_grab_cooldown = 0.80
						elif hover_target == "GREEN_BTN":
							cycle_green_speed()
							_grab_cooldown = 0.60
						else:
							_drag_source = grab_src
							_grab_initial_offset = tee_box_pos - _smoothed_floor_aim
							_grab_initial_offset.y = 0.0
							if hover_target == "HANDLE_L":
								_tee_drag_state = TeeDragState.ROTATE_LEFT
								var hand_angle = rad_to_deg(atan2(-(_smoothed_floor_aim.x - tee_box_pos.x), -(_smoothed_floor_aim.z - tee_box_pos.z)))
								_grab_initial_angle_offset = tee_box_rotation_deg - hand_angle
							elif hover_target == "HANDLE_R":
								_tee_drag_state = TeeDragState.ROTATE_RIGHT
								var hand_angle = rad_to_deg(atan2(-(_smoothed_floor_aim.x - tee_box_pos.x), -(_smoothed_floor_aim.z - tee_box_pos.z)))
								_grab_initial_angle_offset = tee_box_rotation_deg - hand_angle
							else:
								_tee_drag_state = TeeDragState.MOVE
							
							_pulse_haptic(active_aim_ctrl, active_aim_hand, 0.65, 0.06, "Grab " + _tee_drag_state_to_str(_tee_drag_state))
							_record_event("Grabbed %s via %s" % [_tee_drag_state_to_str(_tee_drag_state), grab_src])
				
				# Always-on Laser Guide & Ground Reticle Visuals
				if hover_target != "NONE":
					# Magnetically locked on tee: bright emerald beam & larger reticle
					_update_laser_guide(active_aim_origin, hover_spot, Color(0.2, 0.95, 0.45, 0.88), 0.075)
				elif _floor_aim_valid and not is_tee_confirmed:
					# Pointing at floor: soft clear guide beam & ground targeting circle
					_update_laser_guide(active_aim_origin, _smoothed_floor_aim, Color(0.3, 0.75, 1.0, 0.45), 0.045)
				else:
					_hide_laser_guide()
				
				# Aim from behind: hands down, standing back from the tee and looking at it -> pinch & hold.
				# Runs after the laser visuals so it owns the beam while the gesture is available.
				if not is_tee_confirmed and hover_target == "NONE" and xr_camera != null:
					var head_p: Vector3 = xr_camera.global_position
					var to_tee := Vector2(tee_box_pos.x - head_p.x, tee_box_pos.z - head_p.z)
					var behind_d: float = to_tee.length()
					var hf3: Vector3 = -xr_camera.global_transform.basis.z
					var hf := Vector2(hf3.x, hf3.z)
					var facing: float = 0.0
					# looking almost straight down gives a meaningless yaw, so ignore those frames
					if behind_d > 0.05 and hf.length() > 0.25:
						facing = hf.normalized().dot(to_tee / behind_d)
					if behind_d >= AIM_BEHIND_MIN_M and facing >= AIM_BEHIND_FACING:
						_aim_behind_active = true
						var dirv := to_tee / behind_d
						var holding: bool = (active_is_hand and active_pinch < 0.038) or active_grip >= 0.28 or active_trig >= 0.35
						if holding:
							if _aim_behind_armed and _aim_behind_t >= 0.0:
								_aim_behind_t += delta
								_aim_behind_vec += dirv
						else:
							_aim_behind_armed = true # a hand closed on the putter must open once before this arms
							_aim_behind_t = 0.0
							_aim_behind_vec = Vector2.ZERO
						var cand: float = rad_to_deg(atan2(-dirv.x, -dirv.y))
						var beam_col := Color(0.35, 0.8, 1.0, 0.45)
						var lbl: String = ("PINCH & HOLD TO AIM: %.1f\u00b0" % cand) if _aim_behind_armed else "OPEN YOUR HAND, THEN PINCH TO AIM"
						if _aim_behind_t < 0.0:
							beam_col = Color(0.2, 1.0, 0.5, 0.95)
							lbl = "AIM SET: %.1f\u00b0" % tee_box_rotation_deg
						elif _aim_behind_t > 0.0:
							beam_col = Color(1.0, 0.85, 0.2, 0.95)
							lbl = "HOLD... %.1f\u00b0" % cand
						_update_laser_guide(head_p, tee_box_pos + Vector3(dirv.x, 0.0, dirv.y) * 0.9, beam_col, 0.05)
						if _tee_degree_label != null:
							_tee_degree_label.visible = true
							_tee_degree_label.text = lbl
						if _aim_behind_t >= AIM_BEHIND_HOLD_S:
							var v := _aim_behind_vec.normalized() # circular mean over the hold: averages head sway
							tee_box_rotation_deg = rad_to_deg(atan2(-v.x, -v.y))
							_save_tee_box_settings()
							_notify_course_alignment()
							_record_event("AIM SET FROM BEHIND: %.2f deg, stood %.2f m back" % [tee_box_rotation_deg, behind_d])
							_pulse_haptic(active_aim_ctrl, active_aim_hand, 0.8, 0.10, "Aim set from behind")
							_aim_behind_t = -1.0 # latched: release the pinch to arm it again
							_aim_behind_vec = Vector2.ZERO
							_aim_behind_armed = false
					else:
						_aim_behind_active = false
						_aim_behind_t = 0.0
						_aim_behind_vec = Vector2.ZERO
						_aim_behind_armed = false
				else:
					_aim_behind_active = false
				if not _aim_behind_active and (_aim_behind_t != 0.0 or _aim_behind_armed):
					_aim_behind_t = 0.0
					_aim_behind_vec = Vector2.ZERO
					_aim_behind_armed = false
				
				# Visual highlights on rotation handles and buttons
				var is_hl = (hover_target == "HANDLE_L")
				var is_hr = (hover_target == "HANDLE_R")
				var is_hconf = (hover_target == "CONFIRM_BTN")
				var is_hreal = (hover_target == "REALIGN_BTN")
				var is_hsim = (hover_target == "SIM_BTN")
				if _tee_rec_btn != null:
					_tee_rec_btn.scale = Vector3(1.15, 1.15, 1.15) if hover_target == "REC_BTN" else Vector3.ONE
				if _tee_green_btn != null:
					_tee_green_btn.scale = Vector3(1.15, 1.15, 1.15) if hover_target == "GREEN_BTN" else Vector3.ONE
				
				if _tee_rot_handle_l != null:
					_tee_rot_handle_l.scale = Vector3(1.35, 1.35, 1.35) if is_hl else Vector3(1.0, 1.0, 1.0)
				if _tee_rot_handle_r != null:
					_tee_rot_handle_r.scale = Vector3(1.35, 1.35, 1.35) if is_hr else Vector3(1.0, 1.0, 1.0)
				if _tee_handle_mat != null:
					_tee_handle_mat.albedo_color = Color(0.2, 0.8, 1.0, 0.95) if (is_hl or is_hr) else Color(0.08, 0.45, 1.0, 0.95)
				
				if _tee_confirm_mesh != null:
					_tee_confirm_mesh.scale = Vector3(1.15, 1.15, 1.15) if is_hconf else Vector3(1.0, 1.0, 1.0)
				if _tee_confirm_mat != null:
					_tee_confirm_mat.albedo_color = Color(0.25, 1.0, 0.55, 1.0) if is_hconf else Color(0.1, 0.75, 0.45, 0.95)
				
				if _tee_realign_mesh != null:
					_tee_realign_mesh.scale = Vector3(1.15, 1.15, 1.15) if is_hreal else Vector3(1.0, 1.0, 1.0)
				if _tee_realign_mat != null:
					_tee_realign_mat.albedo_color = Color(0.25, 0.7, 1.0, 1.0) if is_hreal else Color(0.12, 0.35, 0.65, 0.85)
				
				if _tee_sim_mesh != null:
					_tee_sim_mesh.scale = Vector3(1.15, 1.15, 1.15) if is_hsim else Vector3(1.0, 1.0, 1.0)
				if _tee_sim_mat != null:
					_tee_sim_mat.albedo_color = Color(0.3, 1.0, 0.75, 1.0) if is_hsim else Color(0.1, 0.40, 0.45, 0.85)
				
				# Haptic click on magnetic snap transitions
				if hover_target != _last_hover_target:
					if hover_target != "NONE":
						_pulse_haptic(active_aim_ctrl, active_aim_hand, 0.35, 0.025, "Snap " + hover_target)
					_last_hover_target = hover_target
			
			# Thumbstick Floor Navigation from EITHER controller
			var joy_r = right_controller.get_vector2("primary") if r_ctrl_active else Vector2.ZERO
			var joy_l = left_controller.get_vector2("primary") if l_ctrl_active else Vector2.ZERO
			var joy = joy_r if joy_r.length_squared() > joy_l.length_squared() else joy_l
			var joy_grip = rg if joy_r.length_squared() > joy_l.length_squared() else lg
			
			if _tee_drag_state == TeeDragState.NONE and (abs(joy.x) > 0.12 or abs(joy.y) > 0.12):
				if joy_grip >= 0.25:
					# Holding Grip + Thumbstick X rotates aim angle
					tee_box_rotation_deg -= joy.x * delta * 90.0
					if tee_box_rotation_deg > 180.0: tee_box_rotation_deg -= 360.0
					elif tee_box_rotation_deg < -180.0: tee_box_rotation_deg += 360.0
					if _tee_degree_label != null:
						_tee_degree_label.visible = true
						_tee_degree_label.text = "AIM: %.1f°" % tee_box_rotation_deg
				else:
					# Thumbstick slides tee smoothly across the floor relative to camera
					var cam_fwd = Vector3.FORWARD
					var cam_rt = Vector3.RIGHT
					if xr_camera != null:
						cam_fwd = -xr_camera.global_transform.basis.z
						cam_fwd.y = 0.0
						if cam_fwd.length_squared() > 0.001: cam_fwd = cam_fwd.normalized()
						cam_rt = xr_camera.global_transform.basis.x
						cam_rt.y = 0.0
						if cam_rt.length_squared() > 0.001: cam_rt = cam_rt.normalized()
					
					var slide_step = (cam_fwd * joy.y + cam_rt * joy.x) * (delta * 0.95)
					tee_box_pos += Vector3(slide_step.x, 0.0, slide_step.z)
					tee_box_pos.y = 0.002
					_save_tee_box_settings()
					_notify_course_alignment()
			else:
				if _tee_degree_label != null and _tee_drag_state == TeeDragState.NONE and not _aim_behind_active:
					_tee_degree_label.visible = false
			
			# Update position and rotation in scene
			_tee_box_marker.global_position = tee_box_pos
			_tee_box_marker.rotation.y = deg_to_rad(tee_box_rotation_deg)
			if is_tee_confirmed:
				if _tee_calibration_root != null:
					_tee_calibration_root.visible = false
				if _tee_confirm_btn != null:
					_tee_confirm_btn.visible = false
				if _tee_realign_btn != null:
					_tee_realign_btn.visible = true
				if _tee_sim_btn != null:
					_tee_sim_btn.visible = true; _set_extra_floor_btns_visible(true)
				
				if _tee_lock_settle_timer > 0.0:
					_tee_lock_settle_timer -= delta
				
				# Safety timeout for BALL_ROLLING (prevent limbo land if physics never stops)
				if ball_tracking_state == BallTrackingState.BALL_ROLLING:
					_ball_rolling_timer += delta
					if _ball_rolling_timer >= 9.0:
						print("[XRController] BALL_ROLLING 9.0s safety timeout reached. Resetting to SEARCHING.")
						reset_putting_ball()
				
				# In-Headset Instant Replay Card timer & fade:
				if _replay_card != null and _replay_card_timer > 0.0:
					_replay_card_timer -= delta
					if _replay_card_timer < 1.0:
						_replay_card.modulate.a = maxf(0.0, _replay_card_timer)
					if _replay_card_timer <= 0.0:
						_replay_card.visible = false

				# Ball tracking circle lock & fade sequence
				if ball_tracking_state == BallTrackingState.LOCKED_ON_TEE:
					_replay_card_timer = 0.0
					if _replay_card != null:
						_replay_card.visible = false
					
					# 30-second address timeout: if no stroke calculated within 30s, reset and search again
					_tee_timeout_timer -= delta
					if _tee_timeout_timer <= 0.0:
						print("[XRController] 30s timeout reached on tee without stroke. Resuming YOLO to search.")
						reset_putting_ball()
						return

					# Keep high-speed CV putting corridor armed & check telemetry every VR frame (60-90 Hz)
					var bridge = _get_bridge_class()
					if bridge != null:
						_arm_high_speed_corridor()
						var rot_rad := deg_to_rad(tee_box_rotation_deg)
						var forward_dir_2d := Vector2(-sin(rot_rad), -cos(rot_rad)).normalized()
						if _check_and_process_high_speed_putt(bridge, forward_dir_2d):
							return


					if _tee_spot_locked_flash_timer > 0.0:
						_tee_spot_locked_flash_timer -= delta
						_tee_spot_opacity = 1.0
						if _tee_ball_spot_mat != null:
							_tee_ball_spot_mat.albedo_color = Color(0.1, 1.0, 0.45, 1.0) # Solid bright emerald flash
						if _tee_ball_spot_root != null:
							_tee_ball_spot_root.visible = true
					else:
						# Smooth fade-out after confirmation flash for ultra-clean, realistic MR putting
						_tee_spot_opacity = max(0.0, _tee_spot_opacity - delta * 1.6)
						if _tee_spot_opacity <= 0.01:
							if _tee_ball_spot_root != null:
								_tee_ball_spot_root.visible = false
						else:
							if _tee_ball_spot_root != null:
								_tee_ball_spot_root.visible = true
							if _tee_ball_spot_mat != null:
								_tee_ball_spot_mat.albedo_color = Color(0.1, 1.0, 0.45, _tee_spot_opacity)
				elif ball_tracking_state == BallTrackingState.STROKE_DETECTED:
					_tee_spot_opacity = 0.0
					if _tee_ball_spot_root != null:
						_tee_ball_spot_root.visible = false
					
					# High-speed CV check during active stroke measurement
					var bridge = _get_bridge_class()
					if bridge != null:
						var rot_rad := deg_to_rad(tee_box_rotation_deg)
						var forward_dir_2d := Vector2(-sin(rot_rad), -cos(rot_rad)).normalized()
						if _check_and_process_high_speed_putt(bridge, forward_dir_2d):
							return

					_stroke_measuring_timer += delta
					if _stroke_measuring_timer >= 1.10:
						if _stroke_samples.size() >= 2:
							var first_s: Dictionary = _stroke_samples[0]
							var last_s: Dictionary = _stroke_samples[_stroke_samples.size() - 1]
							var dt: float = float(last_s["time"]) - float(first_s["time"])
							var delta_vec: Vector2 = (last_s["pos"] as Vector2) - (first_s["pos"] as Vector2)
							var fwd_travel: float = float(last_s["fwd"]) - float(first_s["fwd"])
							if fwd_travel >= 0.10 and dt > 0.04:
								var measured_speed := delta_vec.length() / dt
								if measured_speed >= 0.25:
									var rot_rad := deg_to_rad(tee_box_rotation_deg)
									var forward_dir_2d := Vector2(-sin(rot_rad), -cos(rot_rad)).normalized()
									_hit_timestamp = float(first_s["time"])
									_launch_speed = clampf(measured_speed, 0.30, 3.5)
									_launch_direction = delta_vec.normalized()
									_launch_angle_deg = rad_to_deg(forward_dir_2d.angle_to(_launch_direction))
									print("[CORRIDOR] >>> TIMEOUT CONFIRMED! speed=%.2f m/s, angle=%+.1f°, dt=%.3fs, travel=%.2fm <<<" % [
										_launch_speed, _launch_angle_deg, dt, delta_vec.length()
									])
									_record_event("HIT: speed=%.2f m/s, angle=%+.1f° (%d-point corridor)" % [_launch_speed, _launch_angle_deg, _stroke_samples.size()])
									bridge = _get_bridge_class()
									if bridge != null:
										bridge.saveCorridorSnippet(_stroke_samples.size(), _last_left_norm_x, _last_left_norm_y, _launch_speed, _launch_angle_deg)
									var fwd_disp: float = float(last_s["fwd"])
									_handoff_to_virtual_ball(fwd_disp, forward_dir_2d)
									return
						print("[CORRIDOR] Timeout waiting for stroke samples (%d recorded). Discarding and resetting to tee." % _stroke_samples.size())
						_stroke_samples.clear()
						ball_tracking_state = BallTrackingState.LOCKED_ON_TEE
						_stroke_measuring_timer = 0.0
				elif ball_tracking_state == BallTrackingState.BALL_ROLLING:
					_tee_spot_opacity = 0.0
					if _tee_ball_spot_root != null:
						_tee_ball_spot_root.visible = false
				else: # SEARCHING or APPROACHING_TEE
					_tee_spot_opacity = min(1.0, _tee_spot_opacity + delta * 2.5)
					if _tee_ball_spot_root != null:
						_tee_ball_spot_root.visible = true
					if _tee_ball_spot_mat != null:
						var pulse = (0.70 + 0.25 * sin(_total_running_time * 3.5)) * _tee_spot_opacity
						_tee_ball_spot_mat.albedo_color = Color(0.2, 0.85, 1.0, pulse)
				# Update 3D floating telemetry label on tee marker
				if _tee_telemetry_label != null:
					_tee_telemetry_label.visible = true
					match ball_tracking_state:
						BallTrackingState.SEARCHING:
							var last_str = ("\n[Last: " + _last_putt_result + "]") if _last_putt_result != "" else ""
							_tee_telemetry_label.text = "PLACE BALL IN CIRCLE" + last_str
							_tee_telemetry_label.modulate = Color(0.2, 0.9, 1.0, 0.95)
						BallTrackingState.APPROACHING_TEE:
							_tee_telemetry_label.text = "MOVE BALL TO SPOT..."
							_tee_telemetry_label.modulate = Color(0.3, 0.9, 0.8, 0.95)
						BallTrackingState.LOCKED_ON_TEE:
							_tee_telemetry_label.text = "READY TO PUTT\n(Aim & Strike)"
							_tee_telemetry_label.modulate = Color(0.1, 1.0, 0.45, 1.0)
						BallTrackingState.STROKE_DETECTED:
							_tee_telemetry_label.text = "MEASURING... (%.1f m/s)" % _launch_speed
							_tee_telemetry_label.modulate = Color(1.0, 0.85, 0.2, 1.0)
						BallTrackingState.BALL_ROLLING:
							_tee_telemetry_label.text = "SPEED: %.2f m/s (%.1f mph)\nANGLE: %+.1f°" % [_launch_speed, _launch_speed * 2.23694, _launch_angle_deg]
							_tee_telemetry_label.modulate = Color(0.1, 1.0, 0.5, 1.0)
				
				# Keep tee box marker visible so the ball tracking circle can render
				_tee_box_marker.visible = true
			else:
				if _tee_calibration_root != null:
					_tee_calibration_root.visible = true
				if _tee_ball_spot_root != null:
					_tee_ball_spot_root.visible = true
				if _tee_confirm_btn != null:
					_tee_confirm_btn.visible = true
				if _tee_realign_btn != null:
					_tee_realign_btn.visible = false
				if _tee_sim_btn != null:
					_tee_sim_btn.visible = false; _set_extra_floor_btns_visible(false)
				if _tee_ball_spot_mat != null:
					_tee_ball_spot_mat.albedo_color = Color(0.2, 0.85, 1.0, 0.85)
				
				# Material Dynamic Color & Fade Logic
				if _tee_frame_mat != null:
					if _tee_drag_state == TeeDragState.MOVE:
						_tee_frame_mat.albedo_color = Color(1.0, 0.85, 0.2, 0.95) # Gold while moving
					else:
						_tee_frame_mat.albedo_color = Color(0.0, 0.85, 1.0, 0.85) # Neon cyan
				
				_tee_marker_alpha = 1.0
				_tee_box_marker.visible = true
				
				# Modulate all alphas
				if _tee_frame_mat != null: _tee_frame_mat.albedo_color.a = 0.85 * _tee_marker_alpha
				if _tee_glass_mat != null: _tee_glass_mat.albedo_color.a = 0.40 * _tee_marker_alpha
				if _tee_ring_mat != null: _tee_ring_mat.albedo_color.a = 0.90 * _tee_marker_alpha
				if _tee_arrow_mat != null: _tee_arrow_mat.albedo_color.a = 0.95 * _tee_marker_alpha
				if _tee_arc_mat != null: _tee_arc_mat.albedo_color.a = 0.60 * _tee_marker_alpha
				if _tee_handle_mat != null: _tee_handle_mat.albedo_color.a = 0.95 * _tee_marker_alpha
				if _tee_front_label != null: _tee_front_label.modulate.a = 0.85 * _tee_marker_alpha
				if _tee_degree_label != null and _tee_drag_state == TeeDragState.NONE and not _aim_behind_active:
					_tee_degree_label.visible = false
			
			# Real-time In-VR Debug HUD (runs continuously during calibration & gameplay)
			var r_h_str = hover_target if active_aim_hand == "right" else "NONE"
			var l_h_str = hover_target if active_aim_hand == "left" else "NONE"
			_update_debug_hud(delta, rt, rg, lt, lg, r_h_str, l_h_str, r_hand_active, r_pinch_dist, l_hand_active, l_pinch_dist)
	elif _tee_box_marker != null:
		_tee_box_marker.visible = false
	
	if _lost_ball_timer > 0.0:
		_lost_ball_timer -= delta
		if _lost_ball_timer <= 0.0:
			_has_filtered_ball = false
	
	if _marker_fade_timer > 0.0:
		_marker_fade_timer -= delta
		if _marker_fade_timer <= 0.0 and _lost_ball_timer <= 0.0 and _ball_tracker_marker != null:
			_ball_tracker_marker.visible = false

	_cam_poll_timer += delta
	if _cam_poll_timer >= 0.08:
		_cam_poll_timer = 0.0
		# Query CameraBridge for real ball detection
		var bridge_class = _get_bridge_class()
		
		if bridge_class != null:
			# Strict Head Orientation Gate: When looking away at the flag or room,
			# do NOT poll detections from the room! The ball remains safely locked on the tee.
			if enable_tee_box and not _is_looking_at_ball_area() and ball_tracking_state != BallTrackingState.STROKE_DETECTED:
				return
			
			_update_tee_box_roi(bridge_class)
			var detection = bridge_class.detectBallStereo()
			if detection == null or detection.size() < 7:
				detection = bridge_class.detectBall()
			
			if detection != null and detection.size() >= 7:
				# Fresh Frame Gate: Reject stale inference frames so static 2D pixels are never
				# re-projected across 90 Hz frames while the headset rotates!
				var yolo_seq: float = float(detection[8]) if detection.size() >= 9 else -1.0
				if yolo_seq >= 0.0:
					if yolo_seq == _last_processed_yolo_seq:
						return
					_last_processed_yolo_seq = yolo_seq

				var is_found: bool = (float(detection[0]) > 0.5)
				if is_found:
					var norm_x: float = float(detection[1])
					var norm_y: float = float(detection[2])
					var right_norm_x: float = float(detection[3])
					var right_norm_y: float = float(detection[4])
					var conf: float = float(detection[5])
					var has_stereo: bool = (float(detection[6]) > 0.5)
					var norm_w: float = float(detection[7]) if detection.size() >= 8 else 0.05
					
					_last_left_norm_x = norm_x
					_last_left_norm_y = norm_y
					_last_right_norm_x = right_norm_x
					_last_right_norm_y = right_norm_y
					_last_has_stereo = has_stereo
					
					_on_physical_ball_detected(norm_x, norm_y, norm_w, has_stereo, right_norm_x, right_norm_y)
				else:
					var conf: float = float(detection[5]) if detection.size() >= 7 else float(detection[4])
					# Log periodically that bridge is polling successfully
					if randf() < 0.05:
						if conf < 0.0:
							print("[XRController] YOLO Warning: Model not active (status: %.0f)" % conf)
						else:
							print("[XRController] YOLO searching... frame_count=%d, best_conf=%.1f%%" % [
								bridge_class.getCameraFrameCount(), conf * 100.0
							])
		
		if _active_cam_texture != null:
			var img: Image = _active_cam_texture.get_image()
			if img != null and not img.is_empty():
				_detect_ball_in_camera_image(img)

func _update_tee_box_roi(bridge_class) -> void:
	if xr_camera == null or bridge_class == null:
		return
	
	# Compute physical camera world transform (offset from eye center + optical downward tilt)
	var cam_pos: Vector3 = xr_camera.global_position
	var cam_basis: Basis = xr_camera.global_transform.basis
	var cam_origin: Vector3 = cam_pos + cam_basis * Vector3(camera_x_offset_m, camera_y_offset_m, camera_z_offset_m)
	var cam_phys_basis: Basis = cam_basis * Basis(Vector3.RIGHT, deg_to_rad(-camera_optical_tilt_deg))
	var cam_phys_transform: Transform3D = Transform3D(cam_phys_basis, cam_origin)
	var cam_inv: Transform3D = cam_phys_transform.affine_inverse()
	
	var tan_h: float = tan(deg_to_rad(camera_hfov_deg * 0.5))
	var tan_v: float = tan(deg_to_rad(camera_vfov_deg * 0.5))
	
	var r_rad: float = deg_to_rad(tee_box_rotation_deg)
	var fwd_3d: Vector3 = Vector3(-sin(r_rad), 0.0, -cos(r_rad)).normalized()


	# Priority 1: When a stroke is in progress, expand ROI along the ACTUAL rolling path of the ball!
	if ball_tracking_state == BallTrackingState.STROKE_DETECTED:
		var ball_motion_2d := _prev_ball_pos_2d - _locked_ball_pos_2d
		if ball_motion_2d.length() > 0.02:
			fwd_3d = Vector3(ball_motion_2d.x, 0.0, ball_motion_2d.y).normalized()
		var p_start := tee_box_pos + fwd_3d * 0.08 # Forward of tee (exclude putter & tee)
		var p_end := tee_box_pos + fwd_3d * 0.90   # 90 cm ahead along ball trajectory
		var l0: Vector3 = cam_inv * p_start
		var l1: Vector3 = cam_inv * p_end
		if l0.z < -0.15 and l1.z < -0.15:
			var nx0 = 0.5 + (l0.x / (-l0.z * 2.0 * tan_h))
			var ny0 = 0.5 - (l0.y / (-l0.z * 2.0 * tan_v))
			var nx1 = 0.5 + (l1.x / (-l1.z * 2.0 * tan_h))
			var ny1 = 0.5 - (l1.y / (-l1.z * 2.0 * tan_v))
			var margin := 0.16 # Generous lateral margin around putting corridor
			var min_x = clampf(minf(nx0, nx1) - margin, 0.0, 1.0)
			var max_x = clampf(maxf(nx0, nx1) + margin, 0.0, 1.0)
			var min_y = clampf(minf(ny0, ny1) - margin, 0.0, 1.0)
			var max_y = clampf(maxf(ny0, ny1) + margin, 0.0, 1.0)
			if (max_x - min_x) >= 0.08 and (max_y - min_y) >= 0.08:
				bridge_class.setTeeBoxRoi(min_x, min_y, max_x, max_y)
				return

	# Priority 2: While locked on tee, cover from the ball at address through the forward putting corridor (+0.65m)
	# This ensures the camera tracks the ball both at address AND as it rolls forward!
	if enable_tee_box and ball_tracking_state == BallTrackingState.LOCKED_ON_TEE:
		var p_start := tee_box_pos - fwd_3d * 0.08
		var p_end := tee_box_pos + fwd_3d * 0.65
		var l0: Vector3 = cam_inv * p_start
		var l1: Vector3 = cam_inv * p_end
		if l0.z < -0.15 and l1.z < -0.15:
			var nx0 = 0.5 + (l0.x / (-l0.z * 2.0 * tan_h))
			var ny0 = 0.5 - (l0.y / (-l0.z * 2.0 * tan_v))
			var nx1 = 0.5 + (l1.x / (-l1.z * 2.0 * tan_h))
			var ny1 = 0.5 - (l1.y / (-l1.z * 2.0 * tan_v))
			var margin := 0.16 # Clean lateral corridor around putting line
			var min_x = clampf(minf(nx0, nx1) - margin, 0.0, 1.0)
			var max_x = clampf(maxf(nx0, nx1) + margin, 0.0, 1.0)
			var min_y = clampf(minf(ny0, ny1) - margin, 0.0, 1.0)
			var max_y = clampf(maxf(ny0, ny1) + margin, 0.0, 1.0)
			if (max_x - min_x) >= 0.08 and (max_y - min_y) >= 0.08:
				bridge_class.setTeeBoxRoi(min_x, min_y, max_x, max_y)
				return

	# Priority 3: Dynamic Visual Lock on tracked ball (during placement / search)
	if _has_filtered_ball and _lost_ball_timer > 0.0 and ball_tracking_state != BallTrackingState.LOCKED_ON_TEE:
		var ball_local: Vector3 = cam_inv * _filtered_ball_pos
		if ball_local.z < -0.15:
			var nx = 0.5 + (ball_local.x / (-ball_local.z * 2.0 * tan_h))
			var ny = 0.5 - (ball_local.y / (-ball_local.z * 2.0 * tan_v))
			if nx >= -0.1 and nx <= 1.1 and ny >= -0.1 and ny <= 1.1:
				var half_box = 0.22
				var min_x = clampf(nx - half_box, 0.0, 1.0)
				var max_x = clampf(nx + half_box, 0.0, 1.0)
				var min_y = clampf(ny - half_box, 0.0, 1.0)
				var max_y = clampf(ny + half_box, 0.0, 1.0)
				if (max_x - min_x) >= 0.06 and (max_y - min_y) >= 0.06:
					bridge_class.setTeeBoxRoi(min_x, min_y, max_x, max_y)
					return

	# Priority 4: Focus directly on the Mini-Tee Bullseye where player places the ball
	if enable_tee_box:
		var tee_local: Vector3 = cam_inv * tee_box_pos
		if tee_local.z < -0.15:
			var tnx = 0.5 + (tee_local.x / (-tee_local.z * 2.0 * tan_h))
			var tny = 0.5 - (tee_local.y / (-tee_local.z * 2.0 * tan_v))
			if tnx >= -0.1 and tnx <= 1.1 and tny >= -0.1 and tny <= 1.1:
				var half_box = 0.30
				var min_x = clampf(tnx - half_box, 0.0, 1.0)
				var max_x = clampf(tnx + half_box, 0.0, 1.0)
				var min_y = clampf(tny - half_box, 0.0, 1.0)
				var max_y = clampf(tny + half_box, 0.0, 1.0)
				if (max_x - min_x) >= 0.06 and (max_y - min_y) >= 0.06:
					bridge_class.setTeeBoxRoi(min_x, min_y, max_x, max_y)
					return

	# Full-frame wide search (only during initial ball placement search)
	bridge_class.clearTeeBoxRoi()

func _ensure_tee_box_marker() -> void:
	if _tee_box_marker == null:
		_tee_box_marker = Node3D.new()
		_tee_box_marker.name = "MiniTeeBullseye"
		
		# 1. Unshaded materials with glowing colors
		_tee_glass_mat = StandardMaterial3D.new()
		_tee_glass_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_glass_mat.albedo_color = Color(0.01, 0.06, 0.12, 0.40)
		_tee_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		
		_tee_frame_mat = StandardMaterial3D.new()
		_tee_frame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_frame_mat.albedo_color = Color(0.0, 0.85, 1.0, 0.85)
		_tee_frame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		
		_tee_ring_mat = StandardMaterial3D.new()
		_tee_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_ring_mat.albedo_color = Color(0.0, 0.95, 1.0, 0.90)
		_tee_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		
		_tee_arrow_mat = StandardMaterial3D.new()
		_tee_arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_arrow_mat.albedo_color = Color(0.1, 1.0, 0.8, 0.95)
		_tee_arrow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_tee_arrow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_tee_arrow_mat.albedo_texture = preload("res://textures/tee_arrow.png")
		
		_tee_arc_mat = StandardMaterial3D.new()
		_tee_arc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_arc_mat.albedo_color = Color(0.2, 0.6, 1.0, 0.60)
		_tee_arc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		
		_tee_handle_mat = StandardMaterial3D.new()
		_tee_handle_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_handle_mat.albedo_color = Color(0.08, 0.45, 1.0, 0.95) # Royal blue handles from concept sketch
		_tee_handle_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		
		# 2. Hierarchy Groups: Calibration elements vs Dedicated Ball Spot Circle
		_tee_calibration_root = Node3D.new()
		_tee_calibration_root.name = "CalibrationGroup"
		_tee_box_marker.add_child(_tee_calibration_root)
		
		_tee_ball_spot_root = Node3D.new()
		_tee_ball_spot_root.name = "BallSpotGroup"
		_tee_box_marker.add_child(_tee_ball_spot_root)
		
		# --- Calibration Group Elements ---
		# Translucent Mat Backing (0.18m wide x 0.30m long)
		var backing_mesh = BoxMesh.new()
		backing_mesh.size = Vector3(0.18, 0.0004, 0.30)
		var backing = MeshInstance3D.new()
		backing.mesh = backing_mesh
		backing.material_override = _tee_glass_mat
		backing.position = Vector3(0.0, 0.0004, -0.03)
		_tee_calibration_root.add_child(backing)
		
		# Rectangular Mat Frame Borders
		var fb = MeshInstance3D.new()
		var fb_m = BoxMesh.new()
		fb_m.size = Vector3(0.18, 0.0012, 0.004)
		fb.mesh = fb_m
		fb.material_override = _tee_frame_mat
		fb.position = Vector3(0.0, 0.001, -0.18)
		_tee_calibration_root.add_child(fb)
		
		var bb = MeshInstance3D.new()
		var bb_m = BoxMesh.new()
		bb_m.size = Vector3(0.18, 0.0012, 0.004)
		bb.mesh = bb_m
		bb.material_override = _tee_frame_mat
		bb.position = Vector3(0.0, 0.001, 0.12)
		_tee_calibration_root.add_child(bb)
		
		var lb = MeshInstance3D.new()
		var lb_m = BoxMesh.new()
		lb_m.size = Vector3(0.004, 0.0012, 0.30)
		lb.mesh = lb_m
		lb.material_override = _tee_frame_mat
		lb.position = Vector3(-0.09, 0.001, -0.03)
		_tee_calibration_root.add_child(lb)
		
		var rb = MeshInstance3D.new()
		var rb_m = BoxMesh.new()
		rb_m.size = Vector3(0.004, 0.0012, 0.30)
		rb.mesh = rb_m
		rb.material_override = _tee_frame_mat
		rb.position = Vector3(0.09, 0.001, -0.03)
		_tee_calibration_root.add_child(rb)
		
		# "FRONT" Directional Arrow & Label
		var arrow_mesh = PlaneMesh.new()
		arrow_mesh.size = Vector2(0.065, 0.09)
		arrow_mesh.orientation = PlaneMesh.FACE_Y
		var arrow_quad = MeshInstance3D.new()
		arrow_quad.name = "DirectionArrow"
		arrow_quad.mesh = arrow_mesh
		arrow_quad.material_override = _tee_arrow_mat
		arrow_quad.position = Vector3(0.0, 0.0014, -0.225)
		_tee_calibration_root.add_child(arrow_quad)
		
		_tee_front_label = Label3D.new()
		_tee_front_label.text = "FRONT"
		_tee_front_label.font_size = 28
		_tee_front_label.pixel_size = 0.0009
		_tee_front_label.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		_tee_front_label.position = Vector3(0.0, 0.0015, -0.14)
		_tee_front_label.modulate = Color(0.0, 0.95, 1.0, 0.85)
		_tee_calibration_root.add_child(_tee_front_label)
		
		# Curved Rotation Arc (R = 0.38m from theta = -75 deg to +75 deg)
		var arc_segments = 18
		var min_deg = -75.0
		var max_deg = 75.0
		var arc_radius = 0.38
		var seg_len = (2.0 * PI * arc_radius * ((max_deg - min_deg) / 360.0)) / float(arc_segments)
		for i in range(arc_segments):
			var a1 = deg_to_rad(lerp(min_deg, max_deg, float(i) / float(arc_segments)))
			var a2 = deg_to_rad(lerp(min_deg, max_deg, float(i + 1) / float(arc_segments)))
			var mid_a = (a1 + a2) * 0.5
			var pos = Vector3(arc_radius * sin(mid_a), 0.0012, arc_radius * cos(mid_a))
			var seg = MeshInstance3D.new()
			var seg_m = BoxMesh.new()
			seg_m.size = Vector3(0.004, 0.001, seg_len * 1.05)
			seg.mesh = seg_m
			seg.material_override = _tee_arc_mat
			seg.position = pos
			seg.rotation.y = mid_a + deg_to_rad(90.0)
			_tee_calibration_root.add_child(seg)
		
		# Blue Square Rotation Handles
		var handle_mesh = BoxMesh.new()
		handle_mesh.size = Vector3(0.038, 0.024, 0.038)
		
		_tee_rot_handle_l = MeshInstance3D.new()
		_tee_rot_handle_l.name = "HandleLeft"
		_tee_rot_handle_l.mesh = handle_mesh
		_tee_rot_handle_l.material_override = _tee_handle_mat
		_tee_rot_handle_l.position = Vector3(arc_radius * sin(deg_to_rad(-75.0)), 0.012, arc_radius * cos(deg_to_rad(-75.0)))
		_tee_calibration_root.add_child(_tee_rot_handle_l)
		
		_tee_rot_handle_r = MeshInstance3D.new()
		_tee_rot_handle_r.name = "HandleRight"
		_tee_rot_handle_r.mesh = handle_mesh
		_tee_rot_handle_r.material_override = _tee_handle_mat
		_tee_rot_handle_r.position = Vector3(arc_radius * sin(deg_to_rad(75.0)), 0.012, arc_radius * cos(deg_to_rad(75.0)))
		_tee_calibration_root.add_child(_tee_rot_handle_r)
		
		# Floating Degree Readout Label
		_tee_degree_label = Label3D.new()
		_tee_degree_label.text = "AIM: 0.0°"
		_tee_degree_label.font_size = 28
		_tee_degree_label.pixel_size = 0.0011
		_tee_degree_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_tee_degree_label.position = Vector3(0.0, 0.06, 0.16)
		_tee_degree_label.modulate = Color(0.1, 0.85, 1.0, 0.95)
		_tee_degree_label.visible = false
		_tee_calibration_root.add_child(_tee_degree_label)
		
		# In-VR Floating Course/Debug HUD (standing next to tee, hands-free)
		_tee_hud_label = Label3D.new()
		_tee_hud_label.name = "TeeDebugHUD"
		_tee_hud_label.text = "[MINI-TEE HUD: INITIALIZING]"
		_tee_hud_label.font_size = 22
		_tee_hud_label.pixel_size = 0.00095
		_tee_hud_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_tee_hud_label.no_depth_test = true
		_tee_hud_label.render_priority = 100
		_tee_hud_label.outline_size = 6
		_tee_hud_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
		_tee_hud_label.position = Vector3(0.40, 0.45, -0.15)
		_tee_hud_label.modulate = Color(0.1, 1.0, 0.85, 0.95)
		_tee_box_marker.add_child(_tee_hud_label)
		
		# Confirmation Floating Button [ ✔ LOCK TEE & PLAY ]
		_tee_confirm_btn = Node3D.new()
		_tee_confirm_btn.name = "ConfirmButton"
		_tee_confirm_btn.position = Vector3(0.0, 0.08, -0.34)
		
		var c_mesh = BoxMesh.new()
		c_mesh.size = Vector3(0.24, 0.045, 0.05)
		_tee_confirm_mesh = MeshInstance3D.new()
		_tee_confirm_mesh.mesh = c_mesh
		
		_tee_confirm_mat = StandardMaterial3D.new()
		_tee_confirm_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_confirm_mat.albedo_color = Color(0.1, 0.75, 0.45, 0.95)
		_tee_confirm_mesh.material_override = _tee_confirm_mat
		_tee_confirm_btn.add_child(_tee_confirm_mesh)
		
		_tee_confirm_label = Label3D.new()
		_tee_confirm_label.text = "✔ LOCK TEE & PLAY"
		_tee_confirm_label.font_size = 22
		_tee_confirm_label.pixel_size = 0.00095
		_tee_confirm_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_tee_confirm_label.position = Vector3(0.0, 0.042, 0.0)
		_tee_confirm_label.modulate = Color(1.0, 1.0, 1.0, 0.98)
		_tee_confirm_btn.add_child(_tee_confirm_label)
		_tee_confirm_btn.visible = not is_tee_confirmed
		_tee_calibration_root.add_child(_tee_confirm_btn)
		
		# Re-align Button [ ⚙ ADJUST TEE ]
		_tee_realign_btn = Node3D.new()
		_tee_realign_btn.name = "RealignButton"
		_tee_realign_btn.position = Vector3(-0.13, 0.05, 0.38) # 38cm behind tee, left side
		
		var r_mesh = BoxMesh.new()
		r_mesh.size = Vector3(0.20, 0.038, 0.065)
		_tee_realign_mesh = MeshInstance3D.new()
		_tee_realign_mesh.mesh = r_mesh
		
		_tee_realign_mat = StandardMaterial3D.new()
		_tee_realign_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_realign_mat.albedo_color = Color(0.12, 0.35, 0.65, 0.85)
		_tee_realign_mesh.material_override = _tee_realign_mat
		_tee_realign_btn.add_child(_tee_realign_mesh)
		
		_tee_realign_label = Label3D.new()
		_tee_realign_label.text = "⚙ ADJUST TEE"
		_tee_realign_label.font_size = 18
		_tee_realign_label.pixel_size = 0.0009
		_tee_realign_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_tee_realign_label.position = Vector3(0.0, 0.038, 0.0)
		_tee_realign_label.modulate = Color(0.7, 0.9, 1.0, 0.95)
		_tee_realign_btn.add_child(_tee_realign_label)
		_tee_realign_btn.visible = is_tee_confirmed
		_tee_box_marker.add_child(_tee_realign_btn)
		
		# Dedicated Simulation Button [ 🎯 SIMULATE ]
		_tee_sim_btn = Node3D.new()
		_tee_sim_btn.name = "SimulateButton"
		_tee_sim_btn.position = Vector3(0.13, 0.05, 0.38) # 38cm behind tee, right side
		
		var s_mesh = BoxMesh.new()
		s_mesh.size = Vector3(0.20, 0.038, 0.065)
		_tee_sim_mesh = MeshInstance3D.new()
		_tee_sim_mesh.mesh = s_mesh
		
		_tee_sim_mat = StandardMaterial3D.new()
		_tee_sim_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_sim_mat.albedo_color = Color(0.1, 0.40, 0.45, 0.85)
		_tee_sim_mesh.material_override = _tee_sim_mat
		_tee_sim_btn.add_child(_tee_sim_mesh)
		
		_tee_sim_label = Label3D.new()
		_tee_sim_label.text = "🎯 SIMULATE"
		_tee_sim_label.font_size = 18
		_tee_sim_label.pixel_size = 0.0009
		_tee_sim_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_tee_sim_label.position = Vector3(0.0, 0.038, 0.0)
		_tee_sim_label.modulate = Color(0.4, 1.0, 0.8, 0.95)
		_tee_sim_btn.add_child(_tee_sim_label)
		_tee_sim_btn.visible = is_tee_confirmed; _set_extra_floor_btns_visible(is_tee_confirmed)
		_tee_box_marker.add_child(_tee_sim_btn)

		# [ ● REC ] session recorder (right of SIMULATE) and [ GREEN ] speed selector (left of ADJUST TEE)
		var rec_parts := _make_floor_button("RecordButton", Vector3(0.39, 0.05, 0.38), Color(0.45, 0.08, 0.08, 0.85), "● REC", Color(1.0, 0.6, 0.6, 0.95))
		_tee_rec_btn = rec_parts[0]; _tee_rec_mat = rec_parts[1]; _tee_rec_label = rec_parts[2]
		var green_parts := _make_floor_button("GreenSpeedButton", Vector3(-0.39, 0.05, 0.38), Color(0.08, 0.35, 0.15, 0.85), "GREEN", Color(0.6, 1.0, 0.7, 0.95))
		_tee_green_btn = green_parts[0]; _tee_green_mat = green_parts[1]; _tee_green_label = green_parts[2]
		_update_green_button_label()
		_set_extra_floor_btns_visible(is_tee_confirmed)
		
		# --- Dedicated Ball Tracking Circle Group (Visible during putting) ---
		_tee_ball_spot_mat = StandardMaterial3D.new()
		_tee_ball_spot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tee_ball_spot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_tee_ball_spot_mat.albedo_color = Color(0.2, 0.85, 1.0, 0.85)
		
		# Primary ball placement ring (diameter ~5.2 cm, cleanly outlines standard 4.3 cm golf ball)
		var spot_ring = MeshInstance3D.new()
		spot_ring.name = "BallTrackingRing"
		var ring_m = TorusMesh.new()
		ring_m.inner_radius = 0.024
		ring_m.outer_radius = 0.028
		ring_m.rings = 36
		ring_m.ring_segments = 12
		spot_ring.mesh = ring_m
		spot_ring.material_override = _tee_ball_spot_mat
		spot_ring.position = Vector3(0.0, 0.0014, 0.0)
		_tee_ball_spot_root.add_child(spot_ring)
		
		# Outer concentric accent ring (diameter ~8.4 cm)
		var outer_ring = MeshInstance3D.new()
		outer_ring.name = "BallOuterRing"
		var outer_m = TorusMesh.new()
		outer_m.inner_radius = 0.040
		outer_m.outer_radius = 0.043
		outer_m.rings = 36
		outer_m.ring_segments = 8
		outer_ring.mesh = outer_m
		outer_ring.material_override = _tee_ball_spot_mat
		outer_ring.position = Vector3(0.0, 0.0012, 0.0)
		_tee_ball_spot_root.add_child(outer_ring)
		
		# Center ball target crosshairs
		var ch_h = MeshInstance3D.new()
		var ch_hm = BoxMesh.new()
		ch_hm.size = Vector3(0.06, 0.0008, 0.0018)
		ch_h.mesh = ch_hm
		ch_h.material_override = _tee_ball_spot_mat
		ch_h.position = Vector3(0.0, 0.0011, 0.0)
		_tee_ball_spot_root.add_child(ch_h)
		
		var ch_v = MeshInstance3D.new()
		var ch_vm = BoxMesh.new()
		ch_vm.size = Vector3(0.0018, 0.0008, 0.06)
		ch_v.mesh = ch_vm
		ch_v.material_override = _tee_ball_spot_mat
		_tee_ball_spot_root.add_child(ch_v)
		
		_tee_telemetry_label = Label3D.new()
		_tee_telemetry_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_tee_telemetry_label.no_depth_test = true
		_tee_telemetry_label.render_priority = 100
		_tee_telemetry_label.position = Vector3(0.0, 0.28, -0.06)
		_tee_telemetry_label.font_size = 32
		_tee_telemetry_label.pixel_size = 0.0016
		_tee_telemetry_label.outline_size = 8
		_tee_telemetry_label.outline_modulate = Color(0, 0, 0, 0.95)
		_tee_telemetry_label.modulate = Color(0.2, 0.9, 1.0)
		_tee_telemetry_label.text = "PLACE BALL IN CIRCLE"
		_tee_box_marker.add_child(_tee_telemetry_label)
		
		_tee_calibration_root.visible = not is_tee_confirmed
		_tee_ball_spot_root.visible = true
		
		add_child(_tee_box_marker)

func _ensure_tracker_marker() -> void:
	if _ball_tracker_marker == null:
		_ball_tracker_marker = MeshInstance3D.new()
		var ring = TorusMesh.new()
		ring.inner_radius = 0.024
		ring.outer_radius = 0.038
		ring.rings = 24
		ring.ring_segments = 16
		_ball_tracker_marker.mesh = ring
		var mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.1, 1.0, 0.4, 0.95)
		_ball_tracker_marker.material_override = mat
		add_child(_ball_tracker_marker)

func _detect_ball_in_camera_image(img: Image) -> void:
	# Downsample / sample pixels to locate bright white golf ball
	var w = img.get_width()
	var h = img.get_height()
	if w <= 16 or h <= 16:
		return
	
	var min_bright = 0.72 # Normalized brightness (0.0 to 1.0)
	var sum_x := 0.0
	var sum_y := 0.0
	var count := 0
	var min_x := float(w)
	var max_x := 0.0
	var min_y := float(h)
	var max_y := 0.0
	
	# Sample every 4th pixel for speed
	var step = 4
	for y in range(0, h, step):
		for x in range(0, w, step):
			var col: Color = img.get_pixel(x, y)
			# Lum = 0.299*R + 0.587*G + 0.114*B
			var lum = col.r * 0.299 + col.g * 0.587 + col.b * 0.114
			if lum >= min_bright and col.r > 0.65 and col.g > 0.65 and col.b > 0.65:
				sum_x += x
				sum_y += y
				count += 1
				if x < min_x: min_x = float(x)
				if x > max_x: max_x = float(x)
				if y < min_y: min_y = float(y)
				if y > max_y: max_y = float(y)
	
	# At 640x480 with step=4, a real golf ball is approx 3 to 150 sampled pixels
	if count >= 3 and count <= 250:
		var box_w = max_x - min_x
		var box_h = max_y - min_y
		if box_w > 0 and box_h > 0:
			var aspect = box_w / box_h
			if aspect >= 0.55 and aspect <= 1.8:
				var cx = sum_x / count
				var cy = sum_y / count
				var norm_x = cx / float(w)
				var norm_y = cy / float(h)
				var norm_w = box_w / float(w)
				_on_physical_ball_detected(norm_x, norm_y, norm_w)

func _check_and_process_high_speed_putt(bridge, forward_dir_2d: Vector2) -> bool:
	if bridge == null or not bridge.isHighSpeedPuttReady():
		return false
	var tele = bridge.getHighSpeedPuttTelemetry()
	if tele == null or tele.size() < 4:
		bridge.clearHighSpeedPutt()
		return false
	var raw_speed: float = float(tele[0])
	var raw_angle: float = float(tele[1])
	var samples: int = int(tele[2])
	var dt: float = float(tele[3])
	if raw_speed < 0.20 or samples < 2:
		bridge.clearHighSpeedPutt()
		return false

	_hit_timestamp = _total_running_time

	# Head Ego-Motion Compensation:
	var head_vel_2d := Vector2.ZERO
	if dt > 0.005 and _head_pos_history.size() >= 2:
		var target_t = _total_running_time - dt
		var past_pos = _head_pos_history[0]["pos"]
		for entry in _head_pos_history:
			if entry["time"] <= target_t:
				past_pos = entry["pos"]
			else:
				break
		var current_pos = Vector2(xr_camera.global_position.x, xr_camera.global_position.z)
		head_vel_2d = (current_pos - past_pos) / dt
		if head_vel_2d.length() > 0.6:
			head_vel_2d = head_vel_2d.normalized() * 0.6
	elif _head_linear_vel != Vector3.ZERO:
		head_vel_2d = Vector2(_head_linear_vel.x, _head_linear_vel.z).limit_length(0.6)

	var angle_rad = deg_to_rad(raw_angle)
	var apparent_dir = forward_dir_2d.rotated(-angle_rad)
	var apparent_vel_2d = apparent_dir * raw_speed
	var true_vel_2d = apparent_vel_2d + head_vel_2d
	var compensated_speed = true_vel_2d.length()
	var compensated_dir = true_vel_2d.normalized() if compensated_speed > 0.05 else forward_dir_2d
	var compensated_angle = rad_to_deg(forward_dir_2d.angle_to(compensated_dir))

	# Speed v2: reconstruct metric floor positions per frame and fit. Old value kept for comparison.
	var v2 := _estimate_speed_v2(bridge, forward_dir_2d)
	_last_speed_v2 = v2
	var v2_used: bool = use_speed_v2 and bool(v2.get("valid", false))
	print("[SPEED v2] %s: v2=%.2f m/s (%+.1f°, n=%d/%d, rms=%.1fmm, span=%.3fs) | old gate=%.2f m/s (%+.1f°) %s" % [
		"USED" if v2_used else "NOT USED",
		float(v2.get("speed", 0.0)), float(v2.get("angle_deg", 0.0)), int(v2.get("used", 0)), int(v2.get("n", 0)),
		float(v2.get("rms_m", 0.0)) * 1000.0, float(v2.get("span_s", 0.0)),
		compensated_speed, compensated_angle, str(v2.get("reason", ""))
	])
	_log_speed_v2(v2, v2_used, raw_speed, raw_angle, compensated_speed, compensated_angle, forward_dir_2d)

	if use_speed_v2 and not v2_used:
		# Not enough clean samples = not a real putt (putter touch, blip, detection glitch).
		# Previously this fell back to the 2-point gate and launched phantom 1.5-3 m/s putts.
		_record_event("REJECTED putt: %s (gate said %.2f m/s)" % [str(v2.get("reason", "")), compensated_speed])
		bridge.clearHighSpeedPutt()
		return false

	if v2_used:
		_launch_speed = float(v2.speed)
		_launch_direction = v2.direction
		_launch_angle_deg = float(v2.angle_deg)
	else:
		_launch_speed = compensated_speed
		_launch_angle_deg = compensated_angle
		_launch_direction = compensated_dir
	_is_high_speed_telemetry_putt = true
	_stroke_samples.clear()

	print("[PHOTOCELL GATE] >>> CONFIRMED PUTT HANDOFF! raw=%.2f m/s (%+.1f°) -> comp=%.2f m/s (%+.1f°), head_sway=%.2f m/s, samples=%d, dt=%.3fs <<<" % [
		raw_speed, raw_angle, _launch_speed, _launch_angle_deg, head_vel_2d.length(), samples, dt
	])
	_record_event("HIT (Photocell Gate @ 90Hz): speed=%.2f m/s, angle=%+.1f° (raw=%.2f m/s, sway=%.2f m/s, %d samples)" % [
		_launch_speed, _launch_angle_deg, raw_speed, head_vel_2d.length(), samples
	])
	bridge.clearHighSpeedPutt()
	_handoff_to_virtual_ball(0.06, forward_dir_2d)
	return true

func _on_physical_ball_detected(norm_x: float, norm_y: float, norm_w: float = 0.0, has_stereo: bool = false, right_norm_x: float = 0.0, right_norm_y: float = 0.0) -> void:
	if xr_camera == null:
		return
	
	var bridge = _get_bridge_class()
	
	# Strict Head Gaze Gate: When looking away at the flag or room,
	# NEVER process ball detections or trigger false strokes!
	if enable_tee_box and not _is_looking_at_ball_area() and ball_tracking_state != BallTrackingState.STROKE_DETECTED:
		return
	
	# Left Camera Origin (Hardware: -32.2mm X, -17.9mm Y, -62.7mm Z)
	var cam_pos = xr_camera.global_position
	var cam_basis = xr_camera.global_transform.basis
	var left_cam_origin = cam_pos + cam_basis * Vector3(camera_x_offset_m, camera_y_offset_m, camera_z_offset_m)
	
	# Pinhole projection for Left Camera
	var tan_half_h = tan(deg_to_rad(camera_hfov_deg * 0.5))
	var tan_half_v = tan(deg_to_rad(camera_vfov_deg * 0.5))
	var left_cam_dir = Vector3(
		(norm_x - 0.5) * 2.0 * tan_half_h,
		-(norm_y - 0.5) * 2.0 * tan_half_v,
		-1.0
	).normalized()
	
	# Apply downward optical tilt rotation (13 deg pitch down)
	var tilt_basis = Basis(Vector3.RIGHT, deg_to_rad(-camera_optical_tilt_deg))
	var left_local_ray = (tilt_basis * left_cam_dir).normalized()
	var left_world_ray = (cam_basis * left_local_ray).normalized()
	
	# Determine 3D marker position
	var floor_y: float = tee_box_pos.y if enable_tee_box else 0.002
	var final_marker_pos: Vector3
	var stereo_success: bool = false
	
	if has_stereo and right_norm_x > 0.0:
		# Right Camera Origin: Quest 3 baseline is +32.2mm (+X) on visor
		var right_x_offset = -camera_x_offset_m # +0.0322m
		var right_cam_origin = cam_pos + cam_basis * Vector3(right_x_offset, camera_y_offset_m, camera_z_offset_m)
		
		var right_cam_dir = Vector3(
			(right_norm_x - 0.5) * 2.0 * tan_half_h,
			-(right_norm_y - 0.5) * 2.0 * tan_half_v,
			-1.0
		).normalized()
		var right_local_ray = (tilt_basis * right_cam_dir).normalized()
		var right_world_ray = (cam_basis * right_local_ray).normalized()
		
		# 3D Stereo Triangulation: Solve closest point of approach between the two 3D rays
		var w0 = left_cam_origin - right_cam_origin
		var b = left_world_ray.dot(right_world_ray)
		var d = left_world_ray.dot(w0)
		var e = right_world_ray.dot(w0)
		var denom = 1.0 - b * b
		
		if denom > 1e-5:
			var s = (b * e - d) / denom # Distance along Left ray
			var t = (e - b * d) / denom # Distance along Right ray
			
			if s > 0.15 and s < 4.5 and t > 0.15 and t < 4.5:
				var pt_left = left_cam_origin + left_world_ray * s
				var pt_right = right_cam_origin + right_world_ray * t
				var ray_err = pt_left.distance_to(pt_right)
				
				# Triangulation passes if rays intersect within distance-adaptive threshold
				var max_ray_err = 0.06 + 0.05 * s
				if ray_err < max_ray_err:
					var metric_diam = norm_w * 2.0 * s * tan_half_h
					# Real golf ball is 4.27cm. Allow 1.8cm to 9.0cm range to reject large mats, rugs, or tiny speck noise
					if metric_diam >= 0.018 and metric_diam <= 0.090:
						var triangulated_pos = (pt_left + pt_right) * 0.5
						stereo_success = true
						if clamp_to_floor or enable_tee_box:
							final_marker_pos = Vector3(triangulated_pos.x, floor_y, triangulated_pos.z)
						else:
							final_marker_pos = triangulated_pos
						
						if randf() < 0.05:
							print("[XRController] STEREO LOCK: dist=%.3fm, diam=%.1fmm, err=%.1fmm, pos=(%.3f, %.3f, %.3f)" % [
								s, metric_diam * 1000.0, ray_err * 1000.0, final_marker_pos.x, final_marker_pos.y, final_marker_pos.z
							])
					else:
						if randf() < 0.05:
							print("[XRController] STEREO REJECT: Object at dist=%.3fm has metric size %.1fmm (not a golf ball)" % [
								s, metric_diam * 1000.0
							])
	
	if not stereo_success:
		# Monocular Fallback: Raycast Left camera directly onto calibrated floor plane.
		# If the right camera gets blinded by glare/shadow during impact, Left camera preserves tracking!
		if (clamp_to_floor or enable_tee_box) and left_world_ray.y < -0.02:
			var t_floor = (floor_y - left_cam_origin.y) / left_world_ray.y
			if t_floor > 0.15 and t_floor < 4.0:
				var mono_pos = left_cam_origin + left_world_ray * t_floor
				mono_pos.y = floor_y
				# If locked on tee, accept monocular detection along putting track within 0.85m
				if ball_tracking_state == BallTrackingState.LOCKED_ON_TEE:
					var mono_2d := Vector2(mono_pos.x, mono_pos.z)
					if mono_2d.distance_to(_locked_ball_pos_2d) <= 0.85:
						final_marker_pos = mono_pos
					else:
						return
				else:
					final_marker_pos = mono_pos
			else:
				return
		else:
			return

	# Distance gating: Reject false room detections far away from the calibrated tee
	if enable_tee_box:
		var tee_pos_2d := Vector2(tee_box_pos.x, tee_box_pos.z)
		var det_pos_2d := Vector2(final_marker_pos.x, final_marker_pos.z)
		if ball_tracking_state == BallTrackingState.LOCKED_ON_TEE:
			# Allow forward displacement along putting track up to 0.85m
			if det_pos_2d.distance_to(_locked_ball_pos_2d) > 0.85:
				return
		elif ball_tracking_state == BallTrackingState.SEARCHING or ball_tracking_state == BallTrackingState.APPROACHING_TEE:
			# Ball must be placed near the tee mat (<= 0.50m)
			if det_pos_2d.distance_to(tee_pos_2d) > 0.50:
				return
	
	# Deadband / 1-Euro smoothing:
	# If stationary (< 3 cm delta), lock aggressively to kill micro-jitter.
	# If ball moved (> 10 cm delta), follow quickly.
	if not _has_filtered_ball or _lost_ball_timer <= 0.0:
		_filtered_ball_pos = final_marker_pos
		_has_filtered_ball = true
	else:
		var dist_delta = _filtered_ball_pos.distance_to(final_marker_pos)
		var alpha: float
		if ball_tracking_state == BallTrackingState.STROKE_DETECTED:
			alpha = 0.95 # Fast tracking during active stroke
		elif dist_delta < 0.025:
			alpha = 0.20 # Smooth anchor while resting stationary on tee
		else:
			alpha = 0.65 # Stable tracking during address
		_filtered_ball_pos = _filtered_ball_pos.lerp(final_marker_pos, alpha)
		if clamp_to_floor:
			_filtered_ball_pos.y = floor_y
	
	_lost_ball_timer = 1.0 # Hold tracking lock for 1.0s across dropped frames
	
	# Ball position in 2D floor coordinates (X, Z)
	var ball_pos_2d := Vector2(_filtered_ball_pos.x, _filtered_ball_pos.z)
	var tee_pos_2d := Vector2(tee_box_pos.x, tee_box_pos.z)
	var dist_to_tee_2d := ball_pos_2d.distance_to(tee_pos_2d)
	
	# Putting forward direction vector along floor (XZ)
	var rot_rad := deg_to_rad(tee_box_rotation_deg)
	var forward_dir_2d := Vector2(-sin(rot_rad), -cos(rot_rad)).normalized()
	var lateral_dir_2d := Vector2(forward_dir_2d.y, -forward_dir_2d.x)

	# Compute instantaneous ball velocity across frames (for accurate, noise-resistant stroke velocity)
	var frame_dt := maxf(_total_running_time - _prev_ball_time, 0.016)
	if _prev_ball_pos_2d != Vector2.ZERO and frame_dt < 0.65:
		_instant_ball_vel_2d = (ball_pos_2d - _prev_ball_pos_2d) / frame_dt
	else:
		_instant_ball_vel_2d = Vector2.ZERO
	_prev_ball_pos_2d = ball_pos_2d
	_prev_ball_time = _total_running_time

	match ball_tracking_state:
		BallTrackingState.SEARCHING, BallTrackingState.APPROACHING_TEE:
			if dist_to_tee_2d <= 0.14: # Within 14 cm of tee center (comfortable bullseye radius)
				_is_ball_on_tee = true
				ball_tracking_state = BallTrackingState.LOCKED_ON_TEE
				_locked_ball_pos_2d = ball_pos_2d
				_locked_ball_time = _total_running_time
				_tee_lock_settle_timer = 0.25 # Short 0.25s settle window
				_tee_spot_locked_flash_timer = 0.45
				_tee_spot_opacity = 1.0
				_ball_missing_at_tee_timer = 0.0
				_ball_seen_recently_timer = 0.50
				_tee_timeout_timer = 30.0
				if not _has_played_lock_sound:
					_has_played_lock_sound = true
					_play_lock_chime()
					var dominant_ctrl = right_controller if golfer_handedness == "right" else left_controller
					_pulse_haptic(dominant_ctrl, golfer_handedness, 0.65, 0.08, "BALL_LOCKED")
					_record_event("BALL LOCKED ON TEE")
					print("[PUTT] >>> 1. BALL LOCKED ON TEE: pos=(%.3f, %.3f), dist_to_center=%.1fmm <<<" % [
						ball_pos_2d.x, ball_pos_2d.y, dist_to_tee_2d * 1000.0
					])
				_stroke_samples.clear()
				_arm_high_speed_corridor()
				if bridge != null:
					bridge.pauseYoloInference()
					bridge.setExposureLock(true)
				print("[XRController] Stage 1 Complete: Ball confirmed on tee. YOLO PAUSED (0% tracking CPU). Classical 60Hz CV armed. 30s timeout active.")
			elif dist_to_tee_2d <= 0.50:
				_is_ball_on_tee = false
				ball_tracking_state = BallTrackingState.APPROACHING_TEE
				if bridge != null:
					bridge.disarmHighSpeedCorridor()
					bridge.setExposureLock(false)
			else:
				_is_ball_on_tee = false
				ball_tracking_state = BallTrackingState.SEARCHING
				if bridge != null:
					bridge.disarmHighSpeedCorridor()
					bridge.setExposureLock(false)

		BallTrackingState.LOCKED_ON_TEE:
			# Keep high-speed putting corridor armed with latest camera projection (60-90 Hz differential tracker)
			_arm_high_speed_corridor()

			# Check if high-speed differential tracker finished a putt! (Highest priority @ 60-90 Hz)
			if _check_and_process_high_speed_putt(bridge, forward_dir_2d):
				return

			if dist_to_tee_2d <= 0.14:
				_ball_seen_recently_timer = 0.50
				_ball_missing_at_tee_timer = 0.0

			var disp_vec := ball_pos_2d - _locked_ball_pos_2d
			var fwd_disp := disp_vec.dot(forward_dir_2d)
			var lat_disp := absf(disp_vec.dot(lateral_dir_2d))
			var instant_speed := _instant_ball_vel_2d.length()

			# 1. Stationary / Resting on Tee & Club Address Buffer Zone:
			# Motion behind or within 8 cm of the tee is considered address jitter / waggle
			if fwd_disp < 0.08:
				_locked_ball_time = _total_running_time
				if disp_vec.length() <= 0.08 and instant_speed < 0.20:
					_locked_ball_pos_2d = _locked_ball_pos_2d.lerp(ball_pos_2d, 0.15)
				return

			# 2. Forward Roll / Stroke Detected!
			var is_head_steady := (_head_angular_speed < 0.25)
			if is_head_steady and is_tee_in_camera_view():
				# Never immediate handoff from LOCKED_ON_TEE!
				# A single-frame YOLO jump or putter occlusion must never trigger a putt.
				# When forward displacement and velocity exceed address threshold,
				# enter STROKE_DETECTED to track and verify consecutive moving samples.
				# Speed v2: the camera tracker (PuttTracker) is the only putt source. The old YOLO 2-point path measured
				# with the wrong scale and fired a 1.37 m/s putt the tracker had correctly measured at ~0.9 m/s.
				if not use_speed_v2 and fwd_disp >= 0.08 and instant_speed >= 0.18 and lat_disp <= 0.18:
					# Gate Entrance: Point 1 (P1)
					ball_tracking_state = BallTrackingState.STROKE_DETECTED
					_stroke_measuring_timer = 0.0
					_stroke_samples.clear()
					_stroke_samples.append({
						"pos": ball_pos_2d,
						"fwd": fwd_disp,
						"lat": lat_disp,
						"time": _total_running_time,
						"norm_x": _last_left_norm_x,
						"norm_y": _last_left_norm_y
					})
					print("[CORRIDOR] >>> POINT 1/3 (Gate Entry at +%.1fcm): fwd=%.3fm, lat=%.3fm, speed=%.2f m/s <<<" % [
						fwd_disp * 100.0, fwd_disp, lat_disp, instant_speed
					])
					if bridge != null:
						bridge.saveCorridorSnippet(1, _last_left_norm_x, _last_left_norm_y, 0.0, 0.0)
						bridge.startPuttRecording()
						bridge.startRecordingStroke(12)
					return

		BallTrackingState.STROKE_DETECTED:
			# High-Speed CV still takes highest priority if it finishes during stroke:
			if _check_and_process_high_speed_putt(bridge, forward_dir_2d):
				return

			# If player rotates their head significantly during stroke measurement, abort stroke detection
			if _head_angular_speed > 0.75:
				print("[CORRIDOR] Head moved sharply during stroke measurement (speed=%.2f). Resetting corridor." % _head_angular_speed)
				_stroke_samples.clear()
				ball_tracking_state = BallTrackingState.LOCKED_ON_TEE
				return

			var disp_vec := ball_pos_2d - _locked_ball_pos_2d
			var fwd_disp := disp_vec.dot(forward_dir_2d)
			var lat_disp := absf(disp_vec.dot(lateral_dir_2d))

			if _stroke_samples.size() >= 1:
				var last_sample: Dictionary = _stroke_samples[_stroke_samples.size() - 1]
				var last_fwd: float = float(last_sample["fwd"])

				# Require continuous forward progress: each sample must advance forward by at least +0.025m
				if fwd_disp >= (last_fwd + 0.025) and lat_disp <= 0.22:
					_stroke_samples.append({
						"pos": ball_pos_2d,
						"fwd": fwd_disp,
						"lat": lat_disp,
						"time": _total_running_time,
						"norm_x": _last_left_norm_x,
						"norm_y": _last_left_norm_y
					})
					print("[CORRIDOR] Sample %d: fwd=%.3fm, lat=%.3fm, speed=%.2f m/s" % [
						_stroke_samples.size(), fwd_disp, lat_disp, _instant_ball_vel_2d.length()
					])

					# Require at least 2 confirmed forward-moving samples AND total forward displacement >= 0.14m:
					if _stroke_samples.size() >= 2 and fwd_disp >= 0.14:
						var first_s: Dictionary = _stroke_samples[0]
						var dt: float = maxf(_total_running_time - float(first_s["time"]), 0.04)
						var delta_vec := ball_pos_2d - (first_s["pos"] as Vector2)
						var measured_speed := delta_vec.length() / dt
						_hit_timestamp = float(first_s["time"])
						_launch_speed = clampf(measured_speed, 0.30, 3.5)
						_launch_direction = delta_vec.normalized() if delta_vec.length() > 0.03 else forward_dir_2d
						_launch_angle_deg = rad_to_deg(forward_dir_2d.angle_to(_launch_direction))
						print("[CORRIDOR] >>> 2-POINT OPTICAL TRAJECTORY CONFIRMED! speed=%.2f m/s, angle=%+.1f°, dt=%.3fs, travel=%.2fm <<<" % [
							_launch_speed, _launch_angle_deg, dt, delta_vec.length()
						])
						_record_event("HIT (Optical Trajectory): speed=%.2f m/s, angle=%+.1f°" % [_launch_speed, _launch_angle_deg])
						if bridge != null:
							bridge.saveCorridorSnippet(2, _last_left_norm_x, _last_left_norm_y, _launch_speed, _launch_angle_deg)
						_handoff_to_virtual_ball(fwd_disp, forward_dir_2d)
						return
				elif fwd_disp < (last_fwd - 0.04) or lat_disp > 0.28:
					# Ball moved backwards or far off line (club waggle / address adjustment) -> reset back to tee
					print("[CORRIDOR] Non-forward or erratic movement in corridor (fwd=%.3f, lat=%.3f). Resetting to LOCKED_ON_TEE." % [fwd_disp, lat_disp])
					_stroke_samples.clear()
					ball_tracking_state = BallTrackingState.LOCKED_ON_TEE
					return

		BallTrackingState.BALL_ROLLING:
			# Ball is in play / rolling on virtual green.
			# Lockout: Wait at least 2.5s before allowing tee re-lock so putter follow-through never triggers false hits!
			if _ball_rolling_timer >= 2.5 and dist_to_tee_2d <= 0.14 and _instant_ball_vel_2d.length() < 0.20:
				_is_ball_on_tee = true
				ball_tracking_state = BallTrackingState.LOCKED_ON_TEE
				_locked_ball_pos_2d = ball_pos_2d
				_locked_ball_time = _total_running_time
				_tee_lock_settle_timer = 0.50
				_tee_spot_locked_flash_timer = 0.45
				_tee_spot_opacity = 1.0
				_ball_missing_at_tee_timer = 0.0
				_ball_seen_recently_timer = 0.50
				if not _has_played_lock_sound:
					_has_played_lock_sound = true
					_play_lock_chime()
					var dominant_ctrl = right_controller if golfer_handedness == "right" else left_controller
					_pulse_haptic(dominant_ctrl, golfer_handedness, 0.65, 0.08, "BALL_LOCKED")
					_record_event("BALL LOCKED ON TEE")
					print("[PUTT] >>> 1. BALL LOCKED ON TEE (Recovered from roll): pos=(%.3f, %.3f), dist_to_center=%.1fmm <<<" % [
						ball_pos_2d.x, ball_pos_2d.y, dist_to_tee_2d * 1000.0
					])

	# Display glowing 3D tracking ring (flat on floor or billboarding in 3D space)
	_ensure_tracker_marker()
	if _ball_tracker_marker != null:
		# When the ball is locked on tee, or during stroke/roll, hide the ring completely so ZERO clutter around real ball!
		if ball_tracking_state == BallTrackingState.LOCKED_ON_TEE or ball_tracking_state == BallTrackingState.STROKE_DETECTED or ball_tracking_state == BallTrackingState.BALL_ROLLING:
			_ball_tracker_marker.visible = false
		else:
			_ball_tracker_marker.visible = true
			_ball_tracker_marker.global_position = _filtered_ball_pos
			if clamp_to_floor:
				_ball_tracker_marker.global_transform.basis = Basis.IDENTITY
			else:
				# Billboard facing player in 3D free space
				_ball_tracker_marker.look_at(cam_pos, Vector3.UP)
				_ball_tracker_marker.rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))
			_marker_fade_timer = 1.2
	
	# Virtual golf ball visibility: Keep strictly hidden while addressing/locked on the tee
	# The virtual ball emerges cleanly at _handoff_to_virtual_ball when rolling onto the green
	if golf_ball != null:
		if ball_tracking_state == BallTrackingState.LOCKED_ON_TEE or ball_tracking_state == BallTrackingState.APPROACHING_TEE:
			golf_ball.visible = false
	
	print("[XRController] BALL FLOOR CLAMPED: pos=(%.3f, %.3f, %.3f), state=%s" % [
		_filtered_ball_pos.x, _filtered_ball_pos.y, _filtered_ball_pos.z, _ball_tracking_state_to_str()
	])

func _handoff_to_virtual_ball(fwd_disp: float, forward_dir_2d: Vector2) -> void:
	if ball_tracking_state != BallTrackingState.STROKE_DETECTED and ball_tracking_state != BallTrackingState.LOCKED_ON_TEE:
		return
	
	# Photocell Gate & High-Speed CV telemetry returns reconstructed physical launch speed v0 directly:
	if _is_high_speed_telemetry_putt:
		_launch_speed = clampf(_launch_speed, 0.25, 5.5)
		_is_high_speed_telemetry_putt = false
		_stroke_samples.clear()
	else:
		# Fallback / low-speed YOLO stroke: compute launch velocity & direction from samples:
		var measured_speed := _launch_speed
		var measured_dir := _launch_direction
		
		if _stroke_samples.size() >= 2:
			var first_s: Dictionary = _stroke_samples[0]
			var last_s: Dictionary = _stroke_samples[_stroke_samples.size() - 1]
			var dt: float = float(last_s["time"]) - float(first_s["time"])
			var delta_pos: Vector2 = (last_s["pos"] as Vector2) - (first_s["pos"] as Vector2)
			if dt > 0.03:
				var sample_speed := delta_pos.length() / dt
				measured_speed = clampf(sample_speed, 0.25, 6.0)
				if delta_pos.length() > 0.02:
					measured_dir = delta_pos.normalized()
		
		if measured_dir.dot(forward_dir_2d) < -0.2:
			measured_dir = forward_dir_2d
		
		var raw_speed := measured_speed # was maxf(_launch_speed, measured_speed), which biased speeds upward
		_launch_speed = clampf(raw_speed * putt_force_multiplier, 0.30, 5.0)
		_launch_direction = measured_dir
		_launch_angle_deg = rad_to_deg(forward_dir_2d.angle_to(_launch_direction))

	# Spawn virtual ball at the tee spot along stroke trajectory with full measured initial velocity v0
	var spawn_dist := clampf(fwd_disp, 0.02, 0.08)
	var tee_pos_2d := Vector2(tee_box_pos.x, tee_box_pos.z)
	var handoff_xz := tee_pos_2d + _launch_direction * spawn_dist

	_last_putt_result = "SPEED: %.2f m/s (%.1f mph) | ANGLE: %+.1f°" % [
		_launch_speed, _launch_speed * 2.23694, _launch_angle_deg
	]
	
	print("[PUTT] >>> 3. MEASURED TELEMETRY: v0=%.2f m/s (%.1f mph), angle=%+.1f°, samples=%d, dt=%.3fs <<<" % [
		_launch_speed, _launch_speed * 2.23694,
		_launch_angle_deg, _stroke_samples.size(), _total_running_time - _hit_timestamp
	])
	_record_event("MEASURED: speed=%.2f m/s, angle=%+.1f°, samples=%d" % [_launch_speed, _launch_angle_deg, _stroke_samples.size()])
	
	if _tee_telemetry_label != null:
		_tee_telemetry_label.text = "SPEED: %.2f m/s (%.1f mph)\nANGLE: %+.1f°" % [_launch_speed, _launch_speed * 2.23694, _launch_angle_deg]
		_tee_telemetry_label.modulate = Color(0.1, 1.0, 0.5, 0.95)

	if golf_ball != null:
		if golf_ball.has_method("reset_to_position"):
			golf_ball.call("reset_to_position", handoff_xz, true)
		else:
			golf_ball.global_position = Vector3(handoff_xz.x, tee_box_pos.y + 0.0213, handoff_xz.y)
		golf_ball.visible = true # Virtual ball emerges on the green!
		var launch_vel := _launch_direction * _launch_speed
		golf_ball.call("strike", launch_vel)
	
	_record_match_stroke(_launch_speed)
	ball_tracking_state = BallTrackingState.BALL_ROLLING
	_ball_rolling_timer = 0.0
	_stroke_samples.clear()
	var bridge = _get_bridge_class()
	if bridge != null:
		bridge.disarmHighSpeedCorridor()
	_trigger_instant_replay()

func _trigger_instant_replay() -> void:
	_ensure_replay_card()
	# Schedule texture loading after 0.25s so Java snapshot thread finishes flushing the JPEG to storage
	get_tree().create_timer(0.25).timeout.connect(_load_replay_card_texture)

func _ensure_replay_card() -> void:
	if _replay_card == null:
		_replay_card = Sprite3D.new()
		_replay_card.name = "PuttReplayCard"
		_replay_card.pixel_size = 0.00065 # ~41cm wide x 31cm tall
		_replay_card.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_replay_card.no_depth_test = true
		_replay_card.render_priority = 85
		_replay_card.visible = false
		add_child(_replay_card)

func _load_replay_card_texture() -> void:
	_ensure_replay_card()
	var candidates: Array[String] = [
		"/sdcard/Android/data/com.example.realballputting/files/corridor_composite.jpg",
		"/storage/emulated/0/Android/data/com.example.realballputting/files/corridor_composite.jpg",
		OS.get_user_data_dir() + "/corridor_composite.jpg"
	]
	var loaded_img: Image = null
	for path in candidates:
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img != null and not img.is_empty():
				loaded_img = img
				break
	
	if loaded_img != null:
		var tex := ImageTexture.create_from_image(loaded_img)
		_replay_card.texture = tex
		_replay_card.global_position = tee_box_pos + Vector3(0.0, 0.42, 0.0)
		_replay_card.modulate = Color(1.0, 1.0, 1.0, 1.0)
		_replay_card.visible = true
		_replay_card_timer = 7.0
		print("[XRController] >>> IN-HEADSET REPLAY CARD DISPLAYED! (7s display) <<<")
	else:
		print("[XRController] Replay card image not found yet on storage.")

func _project_point_to_norm_cam(p: Vector3, cam_inv: Transform3D, tan_h: float, tan_v: float) -> Vector2:
	var local: Vector3 = cam_inv * p
	if local.z >= -0.15:
		return Vector2(-1.0, -1.0)
	var nx: float = 0.5 + (local.x / (-local.z * 2.0 * tan_h))
	var ny: float = 0.5 - (local.y / (-local.z * 2.0 * tan_v))
	return Vector2(nx, ny)

# =========================================================================
# SPEED v2 — floor-plane reconstruction + least-squares fit
# =========================================================================
const SPEED_V2_SPAWN_DIST := 0.06 # must match the fwd_disp passed to _handoff_to_virtual_ball for HS putts

## Head (XR camera) pose at a wall-clock time, interpolated from the pose history.
func _head_pose_at(t_s: float) -> Transform3D:
	if _cam_pose_history.is_empty():
		return xr_camera.global_transform
	if t_s <= float(_cam_pose_history[0]["t"]):
		return _cam_pose_history[0]["xf"]
	for i in range(1, _cam_pose_history.size()):
		var b: Dictionary = _cam_pose_history[i]
		if float(b["t"]) >= t_s:
			var a: Dictionary = _cam_pose_history[i - 1]
			var span := float(b["t"]) - float(a["t"])
			var w := (t_s - float(a["t"])) / span if span > 1e-6 else 0.0
			return (a["xf"] as Transform3D).interpolate_with(b["xf"] as Transform3D, w)
	return _cam_pose_history[_cam_pose_history.size() - 1]["xf"]

## Inverse of _project_point_to_norm_cam: normalized camera coords -> point on horizontal plane y = plane_y.
## Returns Vector3(NAN...) when the ray does not hit the plane.
func _norm_cam_to_floor(norm: Vector2, head_xf: Transform3D, plane_y: float) -> Vector3:
	var cam_origin: Vector3 = head_xf.origin + head_xf.basis * Vector3(camera_x_offset_m, camera_y_offset_m, camera_z_offset_m)
	var cam_basis: Basis = head_xf.basis * Basis(Vector3.RIGHT, deg_to_rad(-camera_optical_tilt_deg))
	var tan_h: float = tan(deg_to_rad(camera_hfov_deg * 0.5))
	var tan_v: float = tan(deg_to_rad(camera_vfov_deg * 0.5))
	var dir_local := Vector3((norm.x - 0.5) * 2.0 * tan_h, -(norm.y - 0.5) * 2.0 * tan_v, -1.0)
	var dir: Vector3 = cam_basis * dir_local
	if dir.y > -1e-4:
		return Vector3(NAN, NAN, NAN)
	var k := (plane_y - cam_origin.y) / dir.y
	return cam_origin + dir * k

## Pixel scale from the sensor's active array to the stream (the stream is scaled, then center-cropped: 1280x1280 -> 640x480)
func _calib_stream_params() -> Dictionary:
	if _cam_calib.size() < 9 or _cam_calib[0] < 0.5:
		return {}
	var aw: float = _cam_calib[5]
	var ah: float = _cam_calib[6]
	var sw: float = _cam_calib[7]
	var sh: float = _cam_calib[8]
	var sc: float = maxf(sw / aw, sh / ah)
	var off_x: float = (aw * sc - sw) * 0.5
	var off_y: float = (ah * sc - sh) * 0.5
	return {"fx": _cam_calib[1] * sc, "fy": _cam_calib[2] * sc,
		"cx": _cam_calib[3] * sc - off_x, "cy": _cam_calib[4] * sc - off_y, "w": sw, "h": sh}

## Same as _norm_cam_to_floor but using the camera's reported intrinsics (fx, fy, cx, cy) for the ray direction.
func _norm_cam_to_floor_intr(norm: Vector2, head_xf: Transform3D, plane_y: float) -> Vector3:
	var k := _calib_stream_params()
	if k.is_empty():
		return Vector3(NAN, NAN, NAN)
	var px: float = norm.x * float(k.w)
	var py: float = norm.y * float(k.h)
	var cam_origin: Vector3 = head_xf.origin + head_xf.basis * Vector3(camera_x_offset_m, camera_y_offset_m, camera_z_offset_m)
	var cam_basis: Basis = head_xf.basis * Basis(Vector3.RIGHT, deg_to_rad(-camera_optical_tilt_deg))
	var dir: Vector3 = cam_basis * Vector3((px - float(k.cx)) / float(k.fx), -(py - float(k.cy)) / float(k.fy), -1.0)
	if dir.y > -1e-4:
		return Vector3(NAN, NAN, NAN)
	var t := (plane_y - cam_origin.y) / dir.y
	return cam_origin + dir * t

## Replaces the hand-tuned camera_hfov/vfov/tilt with the camera's factory calibration.
## The old values (96 x 72 deg) made every distance ~1.5x too long, which is why speeds read ~1.5x too high.
func _try_apply_camera_calibration() -> void:
	var bridge = _get_bridge_class()
	if bridge == null:
		return
	var c = bridge.getCameraCalibration()
	if c == null or c.size() < 9 or float(c[0]) < 0.5:
		return
	_cam_calib = PackedFloat32Array(c)
	_cam_calib_applied = true
	var k := _calib_stream_params()
	var hfov := rad_to_deg(2.0 * atan((float(k.w) * 0.5) / float(k.fx)))
	var vfov := rad_to_deg(2.0 * atan((float(k.h) * 0.5) / float(k.fy)))
	# Lens rotation quaternion = 180 deg flip about X (camera convention) + the downward tilt
	var tilt := camera_optical_tilt_deg
	if _cam_calib.size() >= 16:
		var qw: float = absf(_cam_calib[15])
		var ang := rad_to_deg(2.0 * acos(clampf(qw, 0.0, 1.0)))
		var t := 180.0 - ang
		if t > 0.0 and t < 30.0:
			tilt = t
	print("[CAM CALIB] factory calibration: HFOV %.1f, VFOV %.1f, tilt %.1f deg, principal point (%.1f, %.1f) px  (configured: %.1f / %.1f / %.1f)" % [
		hfov, vfov, tilt, float(k.cx), float(k.cy), camera_hfov_deg, camera_vfov_deg, camera_optical_tilt_deg])
	if use_camera_intrinsics:
		camera_hfov_deg = hfov
		camera_vfov_deg = vfov
		camera_optical_tilt_deg = tilt
		_record_event("Camera calibration applied: FOV %.1f x %.1f, tilt %.1f" % [hfov, vfov, tilt])

func _estimate_speed_v2(bridge, forward_dir_2d: Vector2) -> Dictionary:
	if bridge == null or xr_camera == null:
		return {"valid": false, "reason": "no bridge"}
	var raw = bridge.getHighSpeedSamples()
	if raw == null or raw.size() < 1:
		return {"valid": false, "reason": "no samples from bridge"}
	var count := int(raw[0])
	if raw.size() < 1 + count * 4:
		return {"valid": false, "reason": "malformed sample array"}
	if not _cam_calib_applied:
		_try_apply_camera_calibration()

	var floor_y: float = tee_box_pos.y if enable_tee_box else 0.002
	var ball_center_y := floor_y + 0.02135 # blob centroid ~ ball centre, not the contact point
	var now_s := Time.get_ticks_usec() / 1_000_000.0

	var times := PackedFloat64Array()
	var pts := PackedVector2Array()
	var pts_intr := PackedVector2Array()
	var samples_log := []
	for i in count:
		var t_rel := float(raw[1 + i * 4])
		var age := float(raw[2 + i * 4])
		var norm := Vector2(float(raw[3 + i * 4]), float(raw[4 + i * 4]))
		var head_xf := _head_pose_at(now_s - age - 0.025) # image vs head pose lag measured from a recording (see PuttTracker.PROJ_LAG_NS)
		var p_fov := _norm_cam_to_floor(norm, head_xf, ball_center_y)
		var p_int := _norm_cam_to_floor_intr(norm, head_xf, ball_center_y)
		var p := p_int if (use_camera_intrinsics and not is_nan(p_int.x)) else p_fov
		var b := head_xf.basis
		var o := head_xf.origin
		# [t_rel, age, norm_x, norm_y, floor_x, floor_z, head basis x(3) y(3) z(3), head origin(3)] -> offline re-analysis
		samples_log.append([snappedf(t_rel, 0.0001), snappedf(age, 0.0001), snappedf(norm.x, 0.00001), snappedf(norm.y, 0.00001),
			snappedf(p.x, 0.0001), snappedf(p.z, 0.0001),
			snappedf(b.x.x, 0.00001), snappedf(b.x.y, 0.00001), snappedf(b.x.z, 0.00001),
			snappedf(b.y.x, 0.00001), snappedf(b.y.y, 0.00001), snappedf(b.y.z, 0.00001),
			snappedf(b.z.x, 0.00001), snappedf(b.z.y, 0.00001), snappedf(b.z.z, 0.00001),
			snappedf(o.x, 0.0001), snappedf(o.y, 0.0001), snappedf(o.z, 0.0001)])
		if is_nan(p.x):
			continue
		times.append(t_rel)
		pts.append(Vector2(p.x, p.z))
		if not is_nan(p_int.x):
			pts_intr.append(Vector2(p_int.x, p_int.z))

	var start_pos: Vector2 = _locked_ball_pos_2d if _locked_ball_pos_2d != Vector2.ZERO else Vector2(tee_box_pos.x, tee_box_pos.z)
	var decel := 0.56 * 9.81 / maxf(physical_mat_stimp, 6.0)
	var res := PuttSpeedEstimator.estimate(times, pts, start_pos, decel, SPEED_V2_SPAWN_DIST, forward_dir_2d)
	res["samples"] = samples_log
	res["start_pos"] = [start_pos.x, start_pos.y]
	res["cam_calib"] = Array(_cam_calib)
	# Always compute the alternative (intrinsics / FOV) estimate too, for comparison in the log
	if not use_camera_intrinsics and pts_intr.size() == pts.size() and pts.size() >= 3:
		var alt := PuttSpeedEstimator.estimate(times, pts_intr, start_pos, decel, SPEED_V2_SPAWN_DIST, forward_dir_2d)
		res["alt_intrinsics_speed"] = alt.get("speed", 0.0)
		res["alt_intrinsics_valid"] = alt.get("valid", false)
		print("[SPEED v2] intrinsics model would give %.2f m/s (valid=%s, %s)" % [
			float(alt.get("speed", 0.0)), str(alt.get("valid", false)), str(alt.get("reason", ""))])
	return res

func _log_speed_v2(v2: Dictionary, used: bool, raw_speed: float, raw_angle: float, old_speed: float, old_angle: float, fwd: Vector2) -> void:
	var entry := {
		"time": Time.get_datetime_string_from_system(),
		"used_v2": used,
		"v2_speed": v2.get("speed", 0.0), "v2_angle": v2.get("angle_deg", 0.0),
		"v2_valid": v2.get("valid", false), "v2_reason": v2.get("reason", ""),
		"v2_rms_mm": float(v2.get("rms_m", 0.0)) * 1000.0, "v2_lateral_rms_mm": float(v2.get("lateral_rms_m", 0.0)) * 1000.0,
		"v2_n": v2.get("n", 0), "v2_used_n": v2.get("used", 0), "v2_span_s": v2.get("span_s", 0.0),
		"v2_first_dist": v2.get("first_dist", 0.0), "v2_last_dist": v2.get("last_dist", 0.0),
		"gate_raw_speed": raw_speed, "gate_raw_angle": raw_angle,
		"gate_comp_speed": old_speed, "gate_comp_angle": old_angle,
		"forward": [fwd.x, fwd.y], "start_pos": v2.get("start_pos", []),
		"head_pos": [xr_camera.global_position.x, xr_camera.global_position.y, xr_camera.global_position.z],
		"cam": [camera_hfov_deg, camera_vfov_deg, camera_optical_tilt_deg, camera_x_offset_m, camera_y_offset_m, camera_z_offset_m],
		"mat_stimp": physical_mat_stimp,
		"cam_calib": v2.get("cam_calib", []),
		"alt_intrinsics_speed": v2.get("alt_intrinsics_speed", 0.0),
		"use_camera_intrinsics": use_camera_intrinsics,
		"samples": v2.get("samples", []), # [t_rel, age, norm_x, norm_y, floor_x, floor_z]
	}
	var line := JSON.stringify(entry)
	var paths := ["user://speed_v2_log.jsonl"]
	if OS.has_feature("android"):
		paths.push_front("/storage/emulated/0/Android/data/com.example.realballputting/files/speed_v2_log.jsonl")
	for path in paths:
		var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
		if f != null:
			f.seek_end()
			f.store_line(line)
			f.close()
			return

# =========================================================================
# FLOOR BUTTON HELPERS + SESSION RECORDER (replay on Mac: tools/replay)
# =========================================================================
func _make_floor_button(node_name: String, pos: Vector3, bg: Color, text: String, text_col: Color) -> Array:
	var root := Node3D.new()
	root.name = node_name
	root.position = pos
	var box := BoxMesh.new()
	box.size = Vector3(0.20, 0.038, 0.065)
	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = bg
	mesh.material_override = mat
	root.add_child(mesh)
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 18
	lbl.pixel_size = 0.0009
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.position = Vector3(0.0, 0.038, 0.0)
	lbl.modulate = text_col
	root.add_child(lbl)
	if _tee_box_marker != null:
		_tee_box_marker.add_child(root)
	return [root, mat, lbl]

func _set_extra_floor_btns_visible(v: bool) -> void:
	if _tee_rec_btn != null:
		_tee_rec_btn.visible = v or _rec_active
	if _tee_green_btn != null:
		_tee_green_btn.visible = v

func _update_green_button_label() -> void:
	if _tee_green_label == null:
		return
	var label := green_speed_mode.to_upper()
	var st := physical_mat_stimp
	var cm = _get_course_manager()
	for p in CourseManager.GREEN_SPEED_PRESETS:
		if p["id"] == green_speed_mode:
			label = str(p["label"])
	if cm != null:
		st = cm.get_active_stimp()
	_tee_green_label.text = "%s  %.1f" % [label, st]

func _auto_start_recording() -> void:
	# Camera + bridge need a moment after startup; retry until the recorder is available
	if _rec_active:
		return
	var bridge = _get_bridge_class()
	if bridge == null or not _cam_calib_applied:
		get_tree().create_timer(1.0).timeout.connect(_auto_start_recording)
		return
	toggle_session_recording()

func _on_record_session_toggled(enabled: bool) -> void:
	_record_session_requested = enabled
	print("[XRController] RECORD SESSION %s (starts at stance selection)" % ("ON" if enabled else "OFF"))

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_stop_recording_if_active("app paused/closed")

func _stop_recording_if_active(reason: String) -> void:
	if not _rec_active:
		return
	var bridge = _get_bridge_class()
	if bridge != null:
		bridge.stopSessionRecording()
	_on_recording_stopped(reason)

## Compact snapshot of hands + tee interaction for the recording (tee alignment analysis)
func _hands_state_json() -> String:
	var hands := {}
	for side in ["r", "l"]:
		var hv = right_hand_vis if side == "r" else left_hand_vis
		if hv != null and hv.is_hand_tracked:
			var m: Vector3 = hv.pinch_midpoint
			var a: Vector3 = hv.pinch_aim_direction
			hands[side] = [snappedf(hv.pinch_distance_m, 0.0001), snappedf(m.x, 0.001), snappedf(m.y, 0.001), snappedf(m.z, 0.001),
				snappedf(a.x, 0.001), snappedf(a.y, 0.001), snappedf(a.z, 0.001)]
	return JSON.stringify({"type": "hands", "hands": hands, "hover": _last_hover_target, "drag": int(_tee_drag_state),
		"flow": int(current_flow_state), "tee_confirmed": is_tee_confirmed,
		"tee": [snappedf(tee_box_pos.x, 0.001), snappedf(tee_box_pos.y, 0.001), snappedf(tee_box_pos.z, 0.001), snappedf(tee_box_rotation_deg, 0.1)],
		"aim": [snappedf(_smoothed_floor_aim.x, 0.001), snappedf(_smoothed_floor_aim.z, 0.001), _floor_aim_valid]})

func toggle_session_recording() -> void:
	var bridge = _get_bridge_class()
	if bridge == null:
		_record_event("REC not available (no camera bridge)")
		return
	var hand_ctrl = right_controller if golfer_handedness == "right" else left_controller
	if _rec_active:
		_rec_manual_stop = true
		bridge.stopSessionRecording()
		_on_recording_stopped("stopped by player")
		_pulse_haptic(hand_ctrl, golfer_handedness, 0.6, 0.12, "REC stop")
		return
	var path: String = str(bridge.startSessionRecording(300))
	if path == "":
		_record_event("REC failed to start")
		return
	_rec_active = true
	_rec_manual_stop = false
	_rec_dir = path
	_rec_started_s = Time.get_ticks_msec() / 1000.0
	_write_recording_meta(path)
	if _tee_rec_mat != null:
		_tee_rec_mat.albedo_color = Color(0.95, 0.1, 0.1, 0.95)
	_pulse_haptic(hand_ctrl, golfer_handedness, 0.8, 0.08, "REC start")
	_record_event("RECORDING started: %s" % path)

func _on_recording_stopped(reason: String) -> void:
	print("[XRController] RECORDING STOPPED (%s) after %.1fs: %s" % [reason, Time.get_ticks_msec() / 1000.0 - _rec_started_s, _rec_dir])
	_record_event("RECORDING stopped (%s): %s" % [reason, _rec_dir])
	_rec_active = false
	if _tee_rec_mat != null:
		_tee_rec_mat.albedo_color = Color(0.45, 0.08, 0.08, 0.85)
	if _tee_rec_label != null:
		_tee_rec_label.text = "● REC"
	_set_extra_floor_btns_visible(is_tee_confirmed)

func _write_recording_meta(dir_path: String) -> void:
	var meta := {
		"created": Time.get_datetime_string_from_system(),
		"tee_box_pos": [tee_box_pos.x, tee_box_pos.y, tee_box_pos.z],
		"tee_box_rotation_deg": tee_box_rotation_deg,
		"enable_tee_box": enable_tee_box,
		"camera": {"hfov_deg": camera_hfov_deg, "vfov_deg": camera_vfov_deg, "tilt_deg": camera_optical_tilt_deg,
			"offset_m": [camera_x_offset_m, camera_y_offset_m, camera_z_offset_m]},
		"cam_calib": Array(_cam_calib),
		"physical_mat_stimp": physical_mat_stimp,
		"green_speed_mode": green_speed_mode,
		"use_speed_v2": use_speed_v2,
		"handedness": golfer_handedness,
		"head_pose_note": "events.jsonl type=head: Godot world position + rotation quaternion of the XR camera",
	}
	var f := FileAccess.open(dir_path.path_join("meta.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(meta, "  "))
		f.close()

func _arm_high_speed_corridor() -> void:
	var bridge = _get_bridge_class()
	if bridge == null or xr_camera == null:
		return
	
	var cam_pos: Vector3 = xr_camera.global_position
	var cam_basis: Basis = xr_camera.global_transform.basis

	# 1. Gaze check: If physical tee is temporarily outside view, skip updating camera projection
	if not is_tee_in_camera_view():
		return

	var cam_origin: Vector3 = cam_pos + cam_basis * Vector3(camera_x_offset_m, camera_y_offset_m, camera_z_offset_m)
	var cam_phys_basis: Basis = cam_basis * Basis(Vector3.RIGHT, deg_to_rad(-camera_optical_tilt_deg))
	var cam_phys_transform := Transform3D(cam_phys_basis, cam_origin)
	var cam_inv := cam_phys_transform.affine_inverse()

	var tan_h: float = tan(deg_to_rad(camera_hfov_deg * 0.5))
	var tan_v: float = tan(deg_to_rad(camera_vfov_deg * 0.5))

	var r_rad: float = deg_to_rad(tee_box_rotation_deg)
	var fwd_3d: Vector3 = Vector3(-sin(r_rad), 0.0, -cos(r_rad)).normalized()
	var lat_3d: Vector3 = Vector3(fwd_3d.z, 0.0, -fwd_3d.x).normalized()

	# 2. Anchor corridor to real physical ball if tracked on floor, otherwise fallback to tee_box_pos
	var floor_y: float = tee_box_pos.y if enable_tee_box else 0.002
	var ball_anchor: Vector3 = tee_box_pos
	if _locked_ball_pos_2d != Vector2.ZERO:
		ball_anchor = Vector3(_locked_ball_pos_2d.x, floor_y, _locked_ball_pos_2d.y)
	elif _filtered_ball_pos.length() > 0.1 and absf(_filtered_ball_pos.y - floor_y) < 0.20:
		ball_anchor = _filtered_ball_pos
		ball_anchor.y = floor_y

	# Forward corridor: starts at the ball address spot and ends at +45cm
	var p_start := ball_anchor
	var p_exit := ball_anchor + fwd_3d * 0.75 # corridor length (tracker follows the ball to ~65 cm)
	var w_half := 0.24 # lateral half-width (a few degrees off line = several cm after 65 cm)

	var c0 := p_start - lat_3d * w_half
	var c1 := p_start + lat_3d * w_half
	var c2 := p_exit - lat_3d * w_half
	var c3 := p_exit + lat_3d * w_half

	var s_start := _project_point_to_norm_cam(p_start, cam_inv, tan_h, tan_v)
	var s_exit := _project_point_to_norm_cam(p_exit, cam_inv, tan_h, tan_v)
	var sc0 := _project_point_to_norm_cam(c0, cam_inv, tan_h, tan_v)
	var sc1 := _project_point_to_norm_cam(c1, cam_inv, tan_h, tan_v)
	var sc2 := _project_point_to_norm_cam(c2, cam_inv, tan_h, tan_v)
	var sc3 := _project_point_to_norm_cam(c3, cam_inv, tan_h, tan_v)

	if s_start.x < 0.02 or s_start.x > 0.98 or s_start.y < 0.02 or s_start.y > 0.98:
		# Tee ball spot is outside camera frame, skip reprojecting
		return

	var margin := 0.05 # Generous ±5% screen margin to guarantee ball & streak remain in ROI
	var min_x := clampf(minf(minf(minf(sc0.x, sc1.x), minf(sc2.x, sc3.x)), minf(s_start.x, s_exit.x)) - margin, 0.0, 1.0)
	var max_x := clampf(maxf(maxf(maxf(sc0.x, sc1.x), maxf(sc2.x, sc3.x)), maxf(s_start.x, s_exit.x)) + margin, 0.0, 1.0)
	var min_y := clampf(minf(minf(minf(sc0.y, sc1.y), minf(sc2.y, sc3.y)), minf(s_start.y, s_exit.y)) - margin, 0.0, 1.0)
	var max_y := clampf(maxf(maxf(maxf(sc0.y, sc1.y), maxf(sc2.y, sc3.y)), maxf(s_start.y, s_exit.y)) + margin, 0.0, 1.0)

	var delta_screen := s_exit - s_start
	var screen_len := delta_screen.length()
	if screen_len < 0.04:
		return
	var fwd_norm := delta_screen.normalized()
	var physical_corridor_len := 0.75
	var meters_per_norm_unit := physical_corridor_len / screen_len

	bridge.armHighSpeedCorridor(min_x, min_y, max_x, max_y, s_start.x, s_start.y, fwd_norm.x, fwd_norm.y, meters_per_norm_unit, screen_len)


func _on_session_begun() -> void:
	print("[XRController] OpenXR session begun! Re-applying viewport and split screen configuration...")
	get_viewport().use_xr = true
	if xr_camera != null:
		xr_camera.current = true
	_log_passthrough_status()
	_apply_initial_tee_state()

func _on_session_focussed() -> void:
	print("[XRController] OpenXR session FOCUS gained! Activating viewport and split screen...")
	get_viewport().use_xr = true
	if xr_camera != null:
		xr_camera.current = true
	_log_passthrough_status()
	_apply_initial_tee_state()

func _log_passthrough_status() -> void:
	if xr_interface != null:
		print("[XRController] Passthrough supported on xr_interface: ", xr_interface.is_passthrough_supported())
		print("[XRController] Passthrough enabled on xr_interface: ", xr_interface.is_passthrough_enabled())
	
	if Engine.has_singleton("OpenXRFbPassthroughExtension"):
		var fb_ext = Engine.get_singleton("OpenXRFbPassthroughExtension")
		print("[XRController] OpenXRFbPassthroughExtension singleton found.")
		print("[XRController] FB Passthrough supported: ", fb_ext.is_passthrough_supported())
		print("[XRController] FB Passthrough started: ", fb_ext.is_passthrough_started())

func set_split_mode(mode: SplitMode) -> void:
	current_mode = mode
	_apply_split_mode(mode)

func cycle_split_mode() -> void:
	var next_mode = (int(current_mode) + 1) % 3
	current_mode = next_mode as SplitMode
	_apply_split_mode(current_mode)

func cycle_split_orientation() -> void:
	var next_orient = (int(split_orientation) + 1) % 3
	split_orientation = next_orient as SplitOrientation
	match split_orientation:
		SplitOrientation.ACROSS_TARGET_LINE:
			print("[XRController] Split Orientation: ACROSS_TARGET_LINE (90° - Left is VR, Right is Passthrough)")
		SplitOrientation.ALONG_TARGET_LINE:
			print("[XRController] Split Orientation: ALONG_TARGET_LINE (Parallel to putting track)")
		SplitOrientation.HEAD_GAZE_ALIGNED:
			print("[XRController] Split Orientation: HEAD_GAZE_ALIGNED (3D Gaze Plane)")
	_apply_active_plane()

func toggle_invert_split() -> void:
	invert_split = not invert_split
	_apply_active_plane()
	print("[XRController] Toggled invert_split to: ", invert_split)

func set_golfer_handedness(h: String) -> void:
	golfer_handedness = h
	invert_split = false
	_apply_active_plane()
	_setup_wrist_hud()
	_save_tee_box_settings()
	print("[XRController] Golfer stance set to: %s-Handed (invert_split=%s)" % [golfer_handedness.capitalize(), invert_split])

func _apply_split_mode(mode: SplitMode) -> void:
	match mode:
		SplitMode.SPLIT_SCREEN:
			print("[XRController] Split Mode: 3D STEREOSCOPIC SPLIT SCREEN (VR + Passthrough)")
			set_passthrough(true)
			_apply_active_plane()
			split_mode_changed.emit("SPLIT_SCREEN", world_split_offset_z)
		SplitMode.FULL_PASSTHROUGH:
			print("[XRController] Split Mode: 100% FULL PASSTHROUGH (Physical Room)")
			set_passthrough(true)
			# Plane at -9999m discards all objects -> 100% Passthrough
			_update_material_uniforms(true, Vector3(0, 0, -9999.0), Vector3(0, 0, 1), 0.0, false)
			split_mode_changed.emit("FULL_PASSTHROUGH", 0.0)
		SplitMode.FULL_VR:
			print("[XRController] Split Mode: 100% FULL VR (Putting Green)")
			set_passthrough(false)
			_update_material_uniforms(false, Vector3.ZERO, Vector3(0, 0, 1), 0.0, false)
			split_mode_changed.emit("FULL_VR", 1.0)

func _apply_active_plane() -> void:
	if current_mode != SplitMode.SPLIT_SCREEN:
		return

	var plane_pt := tee_box_pos
	var plane_norm := Vector3(0.0, 0.0, 1.0)
	var active_invert: bool = false

	match split_orientation:
		SplitOrientation.ACROSS_TARGET_LINE:
			# Perpendicular to target line:
			# Ahead (-Z towards hole) is VR putting green
			# Behind (+Z behind ball) is Passthrough physical room
			var rot_b := Basis(Vector3.UP, deg_to_rad(tee_box_rotation_deg))
			plane_pt = tee_box_pos - rot_b * Vector3(0.0, 0.0, world_split_offset_z)
			plane_norm = rot_b * Vector3(0.0, 0.0, 1.0)
			active_invert = false
		SplitOrientation.ALONG_TARGET_LINE:
			# Parallel to target line:
			var rot_b := Basis(Vector3.UP, deg_to_rad(tee_box_rotation_deg))
			var offset_sign := 1.0 if (golfer_handedness == "right") else -1.0
			plane_pt = tee_box_pos + rot_b * Vector3(world_split_offset_x * offset_sign, 0.0, 0.0)
			plane_norm = rot_b * Vector3(offset_sign, 0.0, 0.0)
			active_invert = false
		SplitOrientation.HEAD_GAZE_ALIGNED:
			if xr_camera != null:
				plane_pt = xr_camera.global_position
				var right_vec := xr_camera.global_transform.basis.x
				right_vec.y = 0.0 # Keep plane strictly vertical
				if right_vec.length_squared() > 0.001:
					plane_norm = right_vec.normalized()
			active_invert = invert_split

	_update_material_uniforms(true, plane_pt, plane_norm, divider_width_m, active_invert)

func set_passthrough(enable: bool) -> void:
	if not is_xr_active or xr_interface == null:
		return
		
	if enable:
		var supported: bool = xr_interface.is_passthrough_supported()
		print("[XRController] Requesting Passthrough ENABLE (supported: %s)" % supported)
		
		if supported:
			if not xr_interface.is_passthrough_enabled():
				var started: bool = xr_interface.start_passthrough()
				print("[XRController] start_passthrough returned: ", started)
			
			get_viewport().transparent_bg = true
			is_passthrough_active = true
			_apply_environment_transparency(true)
			print("[XRController] Quest 3 Mixed Reality Passthrough ACTIVE.")
		else:
			get_viewport().transparent_bg = true
			is_passthrough_active = true
			_apply_environment_transparency(true)
		
		# In Mixed Reality Passthrough, hide artificial controller box meshes so real hands show cleanly
		_set_controller_meshes_visible(false)
	else:
		if xr_interface.is_passthrough_enabled():
			xr_interface.stop_passthrough()
		get_viewport().transparent_bg = false
		is_passthrough_active = false
		_apply_environment_transparency(false)
		_set_controller_meshes_visible(true)
		print("[XRController] Virtual Reality mode (Passthrough OFF).")
		
	xr_state_changed.emit(is_xr_active, is_passthrough_active)

func _apply_environment_transparency(transparent: bool) -> void:
	var world_env: WorldEnvironment = get_tree().root.find_child("WorldEnvironment", true, false)
	if world_env != null and world_env.environment != null:
		var env := world_env.environment
		if transparent:
			env.background_mode = Environment.BG_CLEAR_COLOR
			RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.9, 0.95, 0.9)
			env.ambient_light_energy = 0.8
		else:
			env.background_mode = Environment.BG_SKY
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_sky_contribution = 0.85
			env.ambient_light_energy = 0.45

	# In Mixed Reality, hide artificial SkyDome sphere so real room walls/ceiling/floor show through
	var sky_dome: Node3D = get_tree().root.find_child("SkyDome", true, false)
	if sky_dome != null:
		sky_dome.visible = not transparent
		print("[XRController] SkyDome visibility set to: ", sky_dome.visible)

func _collect_split_materials() -> void:
	_split_materials.clear()
	var scene_root := get_tree().current_scene
	if scene_root == null:
		scene_root = get_parent()
	if scene_root != null:
		_traverse_and_collect_materials(scene_root)
	print("[XRController] Collected %d split-screen materials across scene." % _split_materials.size())

func _traverse_and_collect_materials(node: Node) -> void:
	# Never cull the flag assembly or golf ball! Pin, cloth, cup, and ball must stay 100% visible
	if node.name == "GolfFlagAssembly" or node.name.begins_with("GolfFlag") or node.name == "GolfBall" or node.name.begins_with("GolfBall") or node.name == "BallMesh":
		return
		
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		if mi.material_override is ShaderMaterial:
			_register_material(mi.material_override)
		if mi.mesh != null:
			if mi.mesh is PrimitiveMesh and mi.mesh.material is ShaderMaterial:
				_register_material(mi.mesh.material)
			for s in range(mi.mesh.get_surface_count()):
				var sm = mi.mesh.surface_get_material(s)
				if sm is ShaderMaterial:
					_register_material(sm)
		for i in range(mi.get_surface_override_material_count()):
			var mat = mi.get_surface_override_material(i)
			if mat is ShaderMaterial:
				_register_material(mat)

	for child in node.get_children():
		_traverse_and_collect_materials(child)

func _register_material(mat: ShaderMaterial) -> void:
	if mat == null or _split_materials.has(mat):
		return
	var has_param := false
	if mat.get_shader_parameter("enable_split_screen") != null:
		has_param = true
	elif mat.shader != null and mat.shader.code.contains("enable_split_screen"):
		has_param = true

	if has_param:
		_split_materials.append(mat)
		var mat_name := mat.resource_path if mat.resource_path != "" else ("ShaderMat_%d" % mat.get_instance_id())
		print("[XRController] Registered split-screen material: ", mat_name)

func _update_material_uniforms(enabled: bool, plane_pt: Vector3, plane_norm: Vector3, div_width: float, invert: bool) -> void:
	for mat in _split_materials:
		if mat != null:
			mat.set_shader_parameter("enable_split_screen", enabled)
			mat.set_shader_parameter("split_plane_point", plane_pt)
			mat.set_shader_parameter("split_plane_normal", plane_norm)
			mat.set_shader_parameter("split_divider_width", div_width)
			mat.set_shader_parameter("split_blend_width", 0.35)
			mat.set_shader_parameter("show_split_laser", false)
			mat.set_shader_parameter("invert_split", invert)

func _connect_controller_signals() -> void:
	if left_controller != null:
		left_controller.button_pressed.connect(_on_controller_button_pressed.bind("left"))
		left_controller.button_released.connect(_on_controller_button_released.bind("left"))
		_setup_wrist_hud()
	if right_controller != null:
		right_controller.button_pressed.connect(_on_controller_button_pressed.bind("right"))
		right_controller.button_released.connect(_on_controller_button_released.bind("right"))

func _get_target_refresh_rate() -> float:
	var oxr = xr_interface as OpenXRInterface if xr_interface is OpenXRInterface else null
	if oxr != null and oxr.has_method("get_display_refresh_rate"):
		var rate: float = oxr.get_display_refresh_rate()
		if rate > 0.0:
			return rate
	return 90.0

func _setup_headset_fps_chip() -> void:
	if _headset_fps_chip == null and xr_camera != null:
		_headset_fps_chip = Label3D.new()
		_headset_fps_chip.name = "HeadsetFpsChip"
		_headset_fps_chip.text = "FPS: 90"
		_headset_fps_chip.font_size = 14
		_headset_fps_chip.pixel_size = 0.00045
		_headset_fps_chip.no_depth_test = true
		_headset_fps_chip.render_priority = 110
		_headset_fps_chip.outline_size = 4
		_headset_fps_chip.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
		_headset_fps_chip.modulate = Color(0.35, 1.0, 0.45, 0.95)
		# Peripheral HUD position (upper left, comfortable viewing distance)
		_headset_fps_chip.position = Vector3(-0.20, 0.13, -0.55)
		xr_camera.add_child(_headset_fps_chip)

func _setup_wrist_hud() -> void:
	var lead_ctrl = left_controller if golfer_handedness == "right" else right_controller
	if _wrist_hud_label == null and lead_ctrl != null:
		_wrist_hud_label = Label3D.new()
		_wrist_hud_label.name = "WristHUD"
		_wrist_hud_label.text = "[WRIST HUD]"
		_wrist_hud_label.font_size = 18
		_wrist_hud_label.pixel_size = 0.00065
		_wrist_hud_label.no_depth_test = true
		_wrist_hud_label.render_priority = 100
		_wrist_hud_label.outline_size = 5
		_wrist_hud_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
		_wrist_hud_label.modulate = Color(0.2, 0.9, 1.0, 0.95)
		_wrist_hud_label.position = Vector3(0.0, 0.06, -0.02)
		_wrist_hud_label.rotation_degrees = Vector3(-45.0, 0.0, 0.0)
		lead_ctrl.add_child(_wrist_hud_label)
	elif _wrist_hud_label != null and lead_ctrl != null:
		if _wrist_hud_label.get_parent() != lead_ctrl:
			_wrist_hud_label.reparent(lead_ctrl)

func _tee_drag_state_to_str(st: TeeDragState) -> String:
	match st:
		TeeDragState.MOVE: return "MOVE"
		TeeDragState.ROTATE_LEFT: return "ROT_LEFT"
		TeeDragState.ROTATE_RIGHT: return "ROT_RIGHT"
		_: return "IDLE"

func _pulse_haptic(ctrl_node, hand_name: String, amp: float, duration: float, label: String) -> void:
	if ctrl_node != null and ctrl_node.has_method("trigger_haptic_pulse"):
		ctrl_node.trigger_haptic_pulse("haptic", 0.0, amp, duration, 0.0)
	_last_haptic_str = "%s (%s, a=%.2f)" % [label, hand_name, amp]
	_last_haptic_time = _total_running_time
	print("[XRController] HAPTIC: %s on %s (amp=%.2f, dur=%.3fs)" % [label, hand_name, amp, duration])

func _append_to_putt_log(msg: String) -> void:
	var path := "user://putt_log.txt"
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file != null:
		file.seek_end()
		file.store_line("%s | %s" % [Time.get_time_string_from_system(), msg])
		file.flush()
		file.close()

func _record_event(evt_text: String) -> void:
	if _rec_active:
		var rb = _get_bridge_class()
		if rb != null:
			rb.recordEvent(JSON.stringify({"type": "game", "text": evt_text, "state": _ball_tracking_state_to_str()}))
	_last_event_str = evt_text
	_last_event_time = _total_running_time
	print("[XRController] EVENT: %s (t=%.2fs)" % [evt_text, _total_running_time])
	_append_to_putt_log("EVENT: %s (t=%.2fs)" % [evt_text, _total_running_time])

func _update_debug_hud(delta: float, rt: float, rg: float, lt: float, lg: float, r_hover: String, l_hover: String, r_hand_active: bool, r_pinch_dist: float, l_hand_active: bool, l_pinch_dist: float) -> void:
	_hud_update_timer += delta
	if _hud_update_timer < 0.035: # ~28 Hz refresh
		return
	_hud_update_timer = 0.0
	
	var fps: int = Engine.get_frames_per_second()
	var frame_ms: float = 1000.0 / maxf(1.0, float(fps))
	var target_hz: float = _get_target_refresh_rate()
	
	# Update in-headset peripheral FPS chip
	if _headset_fps_chip != null:
		_headset_fps_chip.text = "%d FPS (%.1f ms) • Target %d Hz" % [fps, frame_ms, int(target_hz)]
		if fps >= int(target_hz) - 2:
			_headset_fps_chip.modulate = Color(0.35, 1.0, 0.45, 0.92) # Green: Optimal Store Quality
		elif fps >= 72:
			_headset_fps_chip.modulate = Color(1.0, 0.85, 0.25, 0.92) # Yellow: Meets 72Hz baseline
		else:
			_headset_fps_chip.modulate = Color(1.0, 0.35, 0.35, 0.95) # Red: Dropping frames / Reprojection
	
	var state_str = _tee_drag_state_to_str(_tee_drag_state)
	var now = _total_running_time
	var last_event_ago = max(0.0, now - _last_event_time)
	var last_haptic_ago = max(0.0, now - _last_haptic_time)
	
	var hud_text = "[MINI-TEE DEBUG HUD]  FPS: %d (%.1f ms | %d Hz)\n" % [fps, frame_ms, int(target_hz)]
	hud_text += "Stance: %s-Handed | Dominant: %s\n" % [golfer_handedness.capitalize(), golfer_handedness.capitalize()]
	if is_tee_confirmed:
		hud_text += "Ball: %s\n" % [_ball_tracking_state_to_str()]
		if _last_putt_result != "":
			hud_text += "%s\n" % [_last_putt_result]
		elif _launch_speed > 0.0:
			hud_text += "Last Putt: %.2f m/s (%.1f mph) | Angle: %+.1f°\n" % [_launch_speed, _launch_speed * 2.23694, _launch_angle_deg]
	else:
		hud_text += "Tee State: %s | Src: %s\n" % [state_str, _drag_source if _drag_source != "" else "NONE"]
	hud_text += "Hands: R[%s: %.0fmm] L[%s: %.0fmm]\n" % [
		"PINCH" if r_pinch_dist < 0.035 else ("TRK" if r_hand_active else "OFF"), r_pinch_dist * 1000.0,
		"PINCH" if l_pinch_dist < 0.035 else ("TRK" if l_hand_active else "OFF"), l_pinch_dist * 1000.0
	]
	hud_text += "Armed: R[T:%s G:%s] L[T:%s G:%s] | Cd: %.2fs\n" % [
		"Y" if _right_trigger_armed else "N", "Y" if _right_grip_armed else "N",
		"Y" if _left_trigger_armed else "N", "Y" if _left_grip_armed else "N",
		_grab_cooldown
	]
	hud_text += "R-Aim: (Hover: %s) Trig: %.2f\n" % [r_hover, rt]
	hud_text += "L-Aim: (Hover: %s) Trig: %.2f\n" % [l_hover, lt]
	hud_text += "Last Evt: %s (%.1fs ago)\n" % [_last_event_str, last_event_ago]
	hud_text += "Tee Pos: (%.2f, %.2f) Rot: %.1f°" % [tee_box_pos.x, tee_box_pos.z, tee_box_rotation_deg]
	
	var text_color = Color(0.1, 1.0, 0.85, 0.95)
	if _tee_drag_state != TeeDragState.NONE:
		text_color = Color(1.0, 0.85, 0.2, 0.95) # Gold while moving
	elif _grab_cooldown > 0.0:
		text_color = Color(1.0, 0.45, 0.45, 0.95) # Reddish while in release cooldown
	
	if _tee_hud_label != null:
		_tee_hud_label.text = hud_text
		_tee_hud_label.modulate = text_color
	
	var lead_hand_active = l_hand_active if golfer_handedness == "right" else r_hand_active
	var lead_hand_vis = left_hand_vis if golfer_handedness == "right" else right_hand_vis
	var lead_ctrl = left_controller if golfer_handedness == "right" else right_controller
	
	var wrist_text = "[WRIST HUD]  FPS: %d (%.1f ms | %d Hz)\n" % [fps, frame_ms, int(target_hz)]
	wrist_text += "Stance: %s | Dominant: %s\n" % [golfer_handedness.capitalize(), golfer_handedness.capitalize()]
	if is_tee_confirmed:
		wrist_text += "Ball: %s\n" % [_ball_tracking_state_to_str()]
		if _last_putt_result != "":
			wrist_text += "%s\n" % [_last_putt_result]
		elif _launch_speed > 0.0:
			wrist_text += "Last Putt: %.2f m/s (%.1f mph) | Angle: %+.1f°\n" % [_launch_speed, _launch_speed * 2.23694, _launch_angle_deg]
		wrist_text += "Trig: Sim Putt | Grip: Flat Green\n"
	else:
		wrist_text += "Tee: %s | Src: %s\n" % [state_str, _drag_source if _drag_source != "" else "NONE"]
	wrist_text += "Hands: R[%s: %.0fmm] L[%s: %.0fmm]\n" % [
		"PINCH" if r_pinch_dist < 0.035 else ("TRK" if r_hand_active else "OFF"), r_pinch_dist * 1000.0,
		"PINCH" if l_pinch_dist < 0.035 else ("TRK" if l_hand_active else "OFF"), l_pinch_dist * 1000.0
	]
	wrist_text += "Armed: R[T:%s G:%s] L[T:%s G:%s] | Cd: %.2fs\n" % [
		"Y" if _right_trigger_armed else "N", "Y" if _right_grip_armed else "N",
		"Y" if _left_trigger_armed else "N", "Y" if _left_grip_armed else "N",
		_grab_cooldown
	]
	wrist_text += "Last Evt: %s (%.1fs ago)" % [_last_event_str, last_event_ago]

	if _wrist_hud_label != null:
		_wrist_hud_label.text = wrist_text
		_wrist_hud_label.modulate = text_color
		if lead_hand_active and lead_hand_vis != null and lead_hand_vis.wrist_position != Vector3.ZERO:
			_wrist_hud_label.top_level = true
			_wrist_hud_label.global_position = lead_hand_vis.wrist_position + Vector3(0.0, 0.09, 0.0)
			var eye_pos = xr_camera.global_position if xr_camera != null else _wrist_hud_label.global_position + Vector3(0, 0.5, 0)
			_wrist_hud_label.look_at(eye_pos, Vector3.UP)
			_wrist_hud_label.rotate_object_local(Vector3.UP, PI)
		elif lead_ctrl != null:
			_wrist_hud_label.top_level = false
			if _wrist_hud_label.get_parent() != lead_ctrl:
				_wrist_hud_label.reparent(lead_ctrl)
			_wrist_hud_label.position = Vector3(0.0, 0.06, -0.02)
			_wrist_hud_label.rotation_degrees = Vector3(-45.0, 0.0, 0.0)

func _on_controller_button_pressed(button_name: String, hand: String) -> void:
	print("[XRController] %s hand pressed button: %s (flow: %s)" % [hand, button_name, current_flow_state])
	if current_flow_state == GameFlowState.MAIN_MENU:
		if button_name == "ax_button" or button_name == "trigger_click":
			_show_stance_selection_page()
			return
	elif current_flow_state == GameFlowState.HANDEDNESS_SELECT:
		if hand == "right" and (button_name == "ax_button" or button_name == "trigger_click"):
			_select_handedness("right")
			return
		elif hand == "left" and (button_name == "ax_button" or button_name == "trigger_click"):
			_select_handedness("left")
			return
	
	# If in calibration setup, A/X button confirms tee placement immediately
	if current_flow_state == GameFlowState.TEE_CALIBRATION or not is_tee_confirmed:
		if button_name == "trigger_click" and _grab_cooldown > 0.0 and _last_hover_target.ends_with("_BTN"):
			return # duplicate of a hand pinch that already pressed the button
		if button_name == "ax_button" or (button_name == "trigger_click" and _last_hover_target == "CONFIRM_BTN"):
			_grab_cooldown = 0.6
			confirm_tee_placement()
			return
	else:
		# If playing putting game:
		if button_name == "trigger_click" and _grab_cooldown > 0.0 and _last_hover_target.ends_with("_BTN"):
			# Hand tracking reports a pinch BOTH as a pinch (handled in the floor-aim code) and as trigger_click.
			# The pinch path already pressed the button and set the cooldown -> ignore the duplicate.
			return
		if (button_name == "by_button" and hand == "left") or (button_name == "trigger_click" and _last_hover_target == "REALIGN_BTN"):
			_grab_cooldown = 0.6
			realign_tee()
			return
		elif button_name == "trigger_click" and _last_hover_target == "SIM_BTN":
			_grab_cooldown = 0.6
			simulate_putt()
			return
		elif button_name == "trigger_click" and _last_hover_target == "REC_BTN":
			_grab_cooldown = 0.8
			toggle_session_recording()
			return
		elif button_name == "trigger_click" and _last_hover_target == "GREEN_BTN":
			_grab_cooldown = 0.6
			cycle_green_speed()
			return

	match button_name:
		"by_button":
			# B button on Right controller: reset putting ball during gameplay, or cycle modes
			if current_flow_state == GameFlowState.PUTTING_GAMEPLAY:
				reset_putting_ball()
			else:
				cycle_split_mode()
		"primary_click":
			# Thumbstick click: cycle green speed during gameplay (B still resets the ball), summon tee during calibration
			if current_flow_state == GameFlowState.PUTTING_GAMEPLAY:
				cycle_green_speed()
			else:
				summon_tee_to_player()
		"ax_button":
			# Cycle plane orientation: 90° Across Target Line -> Along Target Line -> Head-Gaze
			cycle_split_orientation()
		"trigger_click":
			if current_flow_state == GameFlowState.TEE_CALIBRATION:
				if _tee_drag_state == TeeDragState.NONE:
					# Only trigger if NOT hovering over calibration handles and not in cooldown!
					if _last_hover_target == "NONE" and _grab_cooldown <= 0.0 and not _floor_aim_valid:
						reset_putting_ball()
						_save_calibration_bundle()
						ball_reset_requested.emit()
			elif current_flow_state == GameFlowState.PUTTING_GAMEPLAY:
				# In putting gameplay, trigger clicks only interact with targeted floor buttons (ADJUST TEE, SIMULATE).
				# Real putts are struck with the physical putter. NEVER blindly simulate putts here!
				pass

func trigger_virtual_stroke(speed_mps: float = 1.8) -> void:
	if current_flow_state != GameFlowState.PUTTING_GAMEPLAY or golf_ball == null:
		return
	var ball_state = golf_ball.get("state")
	if ball_state != null and ball_state != 0:
		reset_putting_ball()
	
	# Calculate forward direction towards the cup along aimed putting line
	var rot_rad := deg_to_rad(tee_box_rotation_deg)
	var fwd_2d := Vector2(-sin(rot_rad), -cos(rot_rad)).normalized()
	var launch_vel := fwd_2d * speed_mps
	
	_launch_speed = speed_mps
	_launch_angle_deg = 0.0
	_launch_direction = fwd_2d
	
	ball_tracking_state = BallTrackingState.BALL_ROLLING
	_ball_rolling_timer = 0.0
	_ball_at_tee_recover_timer = 0.0
	_has_played_lock_sound = false
	_ball_missing_at_tee_timer = 0.0
	
	golf_ball.visible = true
	golf_ball.call("strike", launch_vel)
	
	var ctrl = right_controller if golfer_handedness == "right" else left_controller
	_pulse_haptic(ctrl, golfer_handedness, 0.75, 0.10, "Putt Struck")
	_record_event("TRIGGER STROKE: %.2f m/s" % speed_mps)
	print("[XRController] >>> TRIGGER PUTT STRUCK! speed=%.2f m/s towards hole <<<" % speed_mps)

func simulate_putt(speed_override: float = 0.0) -> void:
	if current_flow_state != GameFlowState.PUTTING_GAMEPLAY or golf_ball == null:
		return
	var speed := speed_override
	if speed <= 0.0:
		speed = SIM_SPEEDS[_sim_speed_index % SIM_SPEEDS.size()]
		_sim_speed_index += 1
	
	reset_putting_ball()
	trigger_virtual_stroke(speed)
	_record_event("SIMULATED PUTT: %.2f m/s" % speed)
	print("[XRController] >>> SIMULATED PUTT TRIGGERED: speed=%.2f m/s (%.1f mph) towards hole <<<" % [speed, speed * 2.23694])
	if _tee_telemetry_label != null:
		_tee_telemetry_label.text = "SIMULATED PUTT\n%.2f m/s (%.1f mph)" % [speed, speed * 2.23694]
		_tee_telemetry_label.modulate = Color(0.2, 0.9, 1.0, 0.95)

func _on_controller_button_released(_button_name: String, _hand: String) -> void:
	pass

func confirm_tee_placement() -> void:
	current_flow_state = GameFlowState.PUTTING_GAMEPLAY
	is_tee_confirmed = true
	_save_tee_box_settings()
	if _tee_calibration_root != null: _tee_calibration_root.visible = false
	if _tee_ball_spot_root != null: _tee_ball_spot_root.visible = true
	if _tee_confirm_btn != null: _tee_confirm_btn.visible = false
	if _tee_realign_btn != null: _tee_realign_btn.visible = true
	if _tee_sim_btn != null: _tee_sim_btn.visible = true; _set_extra_floor_btns_visible(true)
	_hide_laser_guide()
	
	# Hide virtual hands completely during putting gameplay!
	_set_hand_visualizers_enabled(false)
	
	# Reveal virtual putting course aligned with physical tee mat
	if test_green_controller != null:
		if test_green_controller.has_method("align_to_tee_box"):
			test_green_controller.align_to_tee_box(tee_box_pos, tee_box_rotation_deg)
		if test_green_controller.has_method("set_course_visible"):
			test_green_controller.set_course_visible(true)
	
	set_split_mode(SplitMode.SPLIT_SCREEN)
	_apply_active_plane()
	reset_putting_ball() # Clean start: ball tracking in SEARCHING, with 0.8s settle window
	_pulse_haptic(right_controller, "right", 0.85, 0.12, "Tee Confirmed")
	_pulse_haptic(left_controller, "left", 0.85, 0.12, "Tee Confirmed")
	_record_event("Tee Placement Confirmed! Putting Green Active.")
	print("[XRController] TEE PLACEMENT CONFIRMED: Course visible, virtual hands hidden, ball tracking circle active.")

func realign_tee() -> void:
	_start_tee_calibration()

func _start_tee_calibration() -> void:
	current_flow_state = GameFlowState.TEE_CALIBRATION
	is_tee_confirmed = false
	_save_tee_box_settings()
	_hide_welcome_screen()
	
	# Course remains hidden during tee calibration
	if test_green_controller != null and test_green_controller.has_method("set_course_visible"):
		test_green_controller.set_course_visible(false)
	set_split_mode(SplitMode.FULL_PASSTHROUGH)
	
	# Outlined hands active for positioning tee
	_set_hand_visualizers_enabled(true)
	
	# Show mini tee on floor with calibration handles and lock button
	_ensure_tee_box_marker()
	if _tee_box_marker != null:
		_tee_box_marker.visible = true
	if _tee_calibration_root != null:
		_tee_calibration_root.visible = true
	if _tee_ball_spot_root != null:
		_tee_ball_spot_root.visible = true
	if _tee_confirm_btn != null:
		_tee_confirm_btn.visible = true
	if _tee_realign_btn != null:
		_tee_realign_btn.visible = false
	if _tee_sim_btn != null:
		_tee_sim_btn.visible = false; _set_extra_floor_btns_visible(false)
		
	var dom_c = right_controller if golfer_handedness == "right" else left_controller
	var dom_h = "right" if golfer_handedness == "right" else "left"
	_pulse_haptic(dom_c, dom_h, 0.6, 0.08, "Start Tee Calibration")
	_record_event("Tee Calibration Started: Align mini tee on physical mat")
	print("[XRController] TEE CALIBRATION ACTIVE (Stage 3): Position mini tee on mat, outlined hands active, course hidden.")

func _apply_initial_tee_state() -> void:
	if current_flow_state == GameFlowState.MAIN_MENU or current_flow_state == GameFlowState.HANDEDNESS_SELECT:
		# Keep putting course and mini tee hidden during initial startup menus
		if test_green_controller != null and test_green_controller.has_method("set_course_visible"):
			test_green_controller.set_course_visible(false)
		set_split_mode(SplitMode.FULL_PASSTHROUGH)
		_set_hand_visualizers_enabled(true)
		if _tee_box_marker != null:
			_tee_box_marker.visible = false
		return

	if not is_tee_confirmed:
		if test_green_controller != null and test_green_controller.has_method("set_course_visible"):
			test_green_controller.set_course_visible(false)
		set_split_mode(SplitMode.FULL_PASSTHROUGH)
		_set_hand_visualizers_enabled(true)
		if _tee_calibration_root != null: _tee_calibration_root.visible = true
		if _tee_ball_spot_root != null: _tee_ball_spot_root.visible = true
		if _tee_confirm_btn != null: _tee_confirm_btn.visible = true
		if _tee_realign_btn != null: _tee_realign_btn.visible = false
		if _tee_sim_btn != null: _tee_sim_btn.visible = false; _set_extra_floor_btns_visible(false)
		print("[XRController] Initial State: CALIBRATION MODE (Course hidden, outlined hands active).")
	else:
		if test_green_controller != null and test_green_controller.has_method("set_course_visible"):
			test_green_controller.set_course_visible(true)
		_notify_course_alignment()
		set_split_mode(SplitMode.SPLIT_SCREEN)
		_set_hand_visualizers_enabled(false)
		if _tee_calibration_root != null: _tee_calibration_root.visible = false
		if _tee_ball_spot_root != null: _tee_ball_spot_root.visible = true
		if _tee_confirm_btn != null: _tee_confirm_btn.visible = false
		if _tee_realign_btn != null: _tee_realign_btn.visible = true
		if _tee_sim_btn != null: _tee_sim_btn.visible = true; _set_extra_floor_btns_visible(true)
		_hide_laser_guide()
		print("[XRController] Initial State: PUTTING GAMEPLAY (Course visible, hands hidden, ball tracking circle active).")

func _save_tee_box_settings() -> void:
	var cfg = ConfigFile.new()
	cfg.set_value("tee_box", "pos_x", tee_box_pos.x)
	cfg.set_value("tee_box", "pos_y", tee_box_pos.y)
	cfg.set_value("tee_box", "pos_z", tee_box_pos.z)
	cfg.set_value("tee_box", "rotation_deg", tee_box_rotation_deg)
	cfg.set_value("tee_box", "confirmed", is_tee_confirmed)
	cfg.set_value("player", "handedness", golfer_handedness)
	cfg.set_value("player", "completed_welcome", has_completed_welcome)
	cfg.set_value("split", "offset_z", world_split_offset_z)
	cfg.set_value("player", "green_speed", green_speed_mode)
	cfg.save("user://tee_box_settings.cfg")
	print("[XRController] TEE BOX & PROFILE SAVED: pos=%s, rot=%.1f deg, confirmed=%s, stance=%s, welcome_done=%s, split_offset_z=%.2f" % [tee_box_pos, tee_box_rotation_deg, is_tee_confirmed, golfer_handedness, has_completed_welcome, world_split_offset_z])

func _load_tee_box_settings() -> void:
	var cfg = ConfigFile.new()
	if cfg.load("user://tee_box_settings.cfg") == OK:
		var px = cfg.get_value("tee_box", "pos_x", 0.0)
		var py = cfg.get_value("tee_box", "pos_y", 0.002)
		var pz = cfg.get_value("tee_box", "pos_z", 1.2)
		# Sanity check: keep tee box within reach if saved coordinates were wildly offset
		if abs(px) > 2.0 or pz < 0.2 or pz > 3.2:
			print("[XRController] Clamping out-of-bounds tee pos (%.2f, %.2f) to default (0.0, 1.3)" % [px, pz])
			px = 0.0
			pz = 1.3
		tee_box_pos = Vector3(px, py, pz)
		tee_box_rotation_deg = cfg.get_value("tee_box", "rotation_deg", 0.0)
		tee_box_rotation_deg = fposmod(tee_box_rotation_deg + 180.0, 360.0) - 180.0
		if absf(tee_box_rotation_deg) > 75.0:
			tee_box_rotation_deg = 0.0
		is_tee_confirmed = cfg.get_value("tee_box", "confirmed", false)
		golfer_handedness = cfg.get_value("player", "handedness", "right")
		has_completed_welcome = cfg.get_value("player", "completed_welcome", false)
		world_split_offset_z = cfg.get_value("split", "offset_z", 0.45)
		green_speed_mode = cfg.get_value("player", "green_speed", "mat")
		invert_split = false
		print("[XRController] TEE BOX & PROFILE LOADED: pos=%s, rot=%.1f deg, confirmed=%s, stance=%s, welcome_done=%s, split_offset_z=%.2f" % [tee_box_pos, tee_box_rotation_deg, is_tee_confirmed, golfer_handedness, has_completed_welcome, world_split_offset_z])
	else:
		tee_box_pos = Vector3(0.0, 0.002, 1.2)
		tee_box_rotation_deg = 0.0
		is_tee_confirmed = false
		golfer_handedness = "right"
		has_completed_welcome = false
		world_split_offset_z = 0.45
		invert_split = false
	
	call_deferred("_apply_initial_tee_state")

func _notify_course_alignment() -> void:
	if test_green_controller != null and test_green_controller.has_method("align_to_tee_box"):
		test_green_controller.align_to_tee_box(tee_box_pos, tee_box_rotation_deg)
	_apply_active_plane()

# -----------------------------------------------------------------------------
# Game Menu 3D Spatial UI & Stance Selection
# -----------------------------------------------------------------------------
func _show_main_menu() -> void:
	current_flow_state = GameFlowState.MAIN_MENU
	if test_green_controller != null and test_green_controller.has_method("set_course_visible"):
		test_green_controller.set_course_visible(false)
	set_split_mode(SplitMode.FULL_PASSTHROUGH)
	_set_hand_visualizers_enabled(true)
	if _tee_box_marker != null:
		_tee_box_marker.visible = false
		
	if game_menu == null and test_green_controller != null:
		game_menu = test_green_controller.get_node_or_null("GameMenu")
	if game_menu == null:
		game_menu = get_node_or_null("../GameMenu")
		
	if game_menu != null:
		var cam_tf = xr_camera.global_transform if xr_camera != null else global_transform
		var fwd = -cam_tf.basis.z
		game_menu.call("position_in_front_of", cam_tf.origin, fwd)
		game_menu.call("show_main_page")
		
	_hide_laser_guide()
	print("[XRController] Main Menu opened (Stage 1)")

## Keeps the menu in front of the player: if it is more than ~28 deg off to the side (or too near/far),
## it glides back in front of the head. It was placed only once at startup, often before head tracking had settled,
## so it ended up somewhere in the room and had to be searched for.
var _menu_follow_active := false
func _menu_follow(delta: float) -> void:
	if xr_camera == null or game_menu == null:
		return
	var cam: Transform3D = xr_camera.global_transform
	var fwd: Vector3 = -cam.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.1:
		return
	fwd = fwd.normalized()
	var to_menu: Vector3 = game_menu.global_position - cam.origin
	to_menu.y = 0.0
	var dist := to_menu.length()
	var ang := rad_to_deg(fwd.angle_to(to_menu.normalized())) if dist > 0.05 else 180.0
	if ang > 28.0 or dist < 0.7 or dist > 1.8:
		_menu_follow_active = true
	if _menu_follow_active:
		var target: Vector3 = cam.origin + fwd * 1.15
		target.y = maxf(0.95, cam.origin.y - 0.08)
		var p: Vector3 = game_menu.global_position.lerp(target, clampf(delta * 4.0, 0.0, 1.0))
		game_menu.global_position = p
		game_menu.look_at(cam.origin, Vector3.UP)
		game_menu.rotate_object_local(Vector3.UP, PI)
		if p.distance_to(target) < 0.03:
			_menu_follow_active = false

func _show_stance_selection_page() -> void:
	current_flow_state = GameFlowState.HANDEDNESS_SELECT
	if game_menu != null:
		game_menu.call("show_stance_page")
	_hide_laser_guide()
	var dom_c = right_controller if golfer_handedness == "right" else left_controller
	var dom_h = "right" if golfer_handedness == "right" else "left"
	_pulse_haptic(dom_c, dom_h, 0.5, 0.05, "Show Stance Select")
	print("[XRController] Stance Selection page opened (Stage 2)")

func _show_welcome_screen() -> void:
	_show_main_menu()

func _hide_welcome_screen() -> void:
	if game_menu != null:
		game_menu.call("hide_menu")
	_hide_laser_guide()
	print("[XRController] Game Menu closed.")

func _select_handedness(h: String) -> void:
	has_completed_welcome = true
	set_golfer_handedness(h)
	var ctrl = right_controller if h == "right" else left_controller
	_pulse_haptic(ctrl, h, 0.8, 0.1, "Selected " + h.capitalize() + "-Handed Stance")
	_record_event("Stance selected: %s-Handed" % h.capitalize())
	if _record_session_requested and not _rec_active:
		toggle_session_recording()
	_start_tee_calibration()

func _process_welcome_screen(_delta: float) -> void:
	if game_menu == null or not game_menu.visible:
		_hide_laser_guide()
		return
	_menu_follow(_delta)
	
	var r_hand_active: bool = right_hand_vis != null and right_hand_vis.is_hand_tracked
	var l_hand_active: bool = left_hand_vis != null and left_hand_vis.is_hand_tracked
	var rt: float = right_controller.get_float("trigger") if (right_controller != null and right_controller.get_is_active()) else 0.0
	var lt: float = left_controller.get_float("trigger") if (left_controller != null and left_controller.get_is_active()) else 0.0
	var r_pinch: float = right_hand_vis.pinch_distance_m if r_hand_active else 1.0
	var l_pinch: float = left_hand_vis.pinch_distance_m if l_hand_active else 1.0
	
	var pointers: Array = []
	if r_hand_active:
		pointers.append({"pos": right_hand_vis.pinch_midpoint, "dir": right_hand_vis.pinch_aim_direction, "trigger": r_pinch < 0.035, "hand": "right"})
	elif right_controller != null and right_controller.get_is_active():
		pointers.append({"pos": right_controller.global_position, "dir": -right_controller.global_transform.basis.z, "trigger": rt >= 0.5, "hand": "right"})
		
	if l_hand_active:
		pointers.append({"pos": left_hand_vis.pinch_midpoint, "dir": left_hand_vis.pinch_aim_direction, "trigger": l_pinch < 0.035, "hand": "left"})
	elif left_controller != null and left_controller.get_is_active():
		pointers.append({"pos": left_controller.global_position, "dir": -left_controller.global_transform.basis.z, "trigger": lt >= 0.5, "hand": "left"})
	
	var hit_anything := false
	for ptr in pointers:
		var res: Dictionary = game_menu.call("process_pointer_ray", ptr.pos, ptr.dir, ptr.trigger)
		if res.get("hit", false):
			hit_anything = true
			_draw_laser_guide(ptr.pos, res.get("laser_to", ptr.pos + ptr.dir * 1.5), Color(0.2, 0.95, 0.6, 0.85))
			var h_name: String = res.get("hovered", "NONE")
			if h_name != _welcome_hovered_btn:
				_welcome_hovered_btn = h_name
				if h_name != "NONE":
					var h_ctrl = right_controller if ptr.hand == "right" else left_controller
					_pulse_haptic(h_ctrl, ptr.hand, 0.3, 0.02, "Hover " + h_name)
			break
			
	if not hit_anything:
		_hide_laser_guide()
		_welcome_hovered_btn = "NONE"

func _draw_laser_guide(from_pos: Vector3, to_pos: Vector3, color: Color) -> void:
	_update_laser_guide(from_pos, to_pos, color)

func _save_calibration_bundle() -> void:
	var bundle_id = str(int(Time.get_unix_time_from_system() * 1000))
	print("[XRController] CAPTURING CALIBRATION BUNDLE: ", bundle_id)
	
	var bridge_class = null
	if Engine.has_singleton("JavaClassWrapper"):
		var jcw = Engine.get_singleton("JavaClassWrapper")
		bridge_class = jcw.wrap("com.godot.game.HeadsetCameraBridge")
	elif OS.has_feature("android"):
		bridge_class = JavaClassWrapper.wrap("com.godot.game.HeadsetCameraBridge")
	
	# 1. Ask HeadsetCameraBridge to save Raw 640x480 and Crop 320x320 images
	if bridge_class != null:
		bridge_class.saveCalibrationBundle(bundle_id)
			
	# 2. Capture VR stereoscopic display viewport
	var vp = get_viewport()
	if vp != null:
		var img: Image = vp.get_texture().get_image()
		if img != null and not img.is_empty():
			var png_buf = img.save_png_to_buffer()
			if bridge_class != null:
				bridge_class.saveImageFile("bundle_" + bundle_id + "_vr.png", png_buf)
			else:
				img.save_png("user://bundle_" + bundle_id + "_vr.png")
	
	# 3. Save 6DOF Head Pose, Optical Matrix, and Tracking Metadata
	var cam_pos = xr_camera.global_position if xr_camera != null else Vector3.ZERO
	var cam_basis = xr_camera.global_transform.basis if xr_camera != null else Basis.IDENTITY
	var cam_quat = cam_basis.get_rotation_quaternion()
	var cam_origin = cam_pos + cam_basis * Vector3(camera_x_offset_m, camera_y_offset_m, camera_z_offset_m)
	
	var meta = {
		"bundle_id": bundle_id,
		"timestamp": Time.get_datetime_string_from_system(),
		"head_pos": [cam_pos.x, cam_pos.y, cam_pos.z],
		"head_quat": [cam_quat.x, cam_quat.y, cam_quat.z, cam_quat.w],
		"cam_origin": [cam_origin.x, cam_origin.y, cam_origin.z],
		"ball_filtered_pos": [_filtered_ball_pos.x, _filtered_ball_pos.y, _filtered_ball_pos.z],
		"left_norm_x": _last_left_norm_x,
		"left_norm_y": _last_left_norm_y,
		"right_norm_x": _last_right_norm_x,
		"right_norm_y": _last_right_norm_y,
		"has_stereo": _last_has_stereo,
		"disparity": (_last_left_norm_x - _last_right_norm_x) if _last_has_stereo else 0.0,
		"camera_optical_tilt_deg": camera_optical_tilt_deg,
		"camera_hfov_deg": camera_hfov_deg,
		"camera_vfov_deg": camera_vfov_deg,
		"camera_x_offset_m": camera_x_offset_m,
		"camera_y_offset_m": camera_y_offset_m,
		"camera_z_offset_m": camera_z_offset_m,
		"clamp_to_floor": clamp_to_floor
	}
	
	var json_str = JSON.stringify(meta, "\t")
	if bridge_class != null:
		bridge_class.saveTextFile("bundle_" + bundle_id + "_meta.json", json_str)
	else:
		var meta_file = FileAccess.open("user://bundle_" + bundle_id + "_meta.json", FileAccess.WRITE)
		if meta_file != null:
			meta_file.store_string(json_str)
			meta_file.close()
	print("[XRController] SUCCESS: Calibration bundle saved: bundle_", bundle_id)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if current_flow_state == GameFlowState.MAIN_MENU:
			if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER or event.keycode == KEY_P:
				_show_stance_selection_page()
				return
		elif current_flow_state == GameFlowState.HANDEDNESS_SELECT:
			if event.keycode == KEY_R:
				_select_handedness("right")
				return
			elif event.keycode == KEY_L:
				_select_handedness("left")
				return
			elif event.keycode == KEY_ESCAPE:
				_show_main_menu()
				return
		elif current_flow_state == GameFlowState.TEE_CALIBRATION:
			if event.keycode == KEY_ENTER or event.keycode == KEY_SPACE:
				confirm_tee_placement()
				return
		match event.keycode:
			KEY_W:
				_show_welcome_screen()
			KEY_C:
				_save_calibration_bundle()
			KEY_P:
				cycle_split_mode()
			KEY_O:
				cycle_split_orientation()
			KEY_I:
				toggle_invert_split()
			KEY_UP:
				world_split_offset_z = clamp(world_split_offset_z - 0.1, -1.0, 5.0)
				_apply_active_plane()
			KEY_DOWN:
				world_split_offset_z = clamp(world_split_offset_z + 0.1, -1.0, 5.0)
				_apply_active_plane()
			KEY_T:
				summon_tee_to_player()
			KEY_LEFT:
				world_split_offset_x = clamp(world_split_offset_x - 0.05, -2.5, 2.5)
				_apply_active_plane()
			KEY_RIGHT:
				world_split_offset_x = clamp(world_split_offset_x + 0.05, -2.5, 2.5)
				_apply_active_plane()

func summon_tee_to_player() -> void:
	var forward = Vector3.FORWARD
	var ref_pos = Vector3.ZERO
	if xr_camera != null:
		ref_pos = xr_camera.global_position
		forward = -xr_camera.global_transform.basis.z
		forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	
	var summon_pos = ref_pos + forward * 1.25
	summon_pos.y = 0.002
	tee_box_pos = summon_pos
	_save_tee_box_settings()
	var dom_c = right_controller if golfer_handedness == "right" else left_controller
	var dom_h = "right" if golfer_handedness == "right" else "left"
	_pulse_haptic(dom_c, dom_h, 0.70, 0.08, "Summon Tee")
	_record_event("Summoned Mini-Tee 1.25m in front of player")

func _set_controller_meshes_visible(is_visible: bool) -> void:
	if left_controller != null:
		for child in left_controller.get_children():
			if child is MeshInstance3D and child.name != "LaserGuide":
				child.visible = is_visible
	if right_controller != null:
		for child in right_controller.get_children():
			if child is MeshInstance3D and child.name != "LaserGuide":
				child.visible = is_visible

func _update_laser_guide(from_pos: Vector3, to_pos: Vector3, color: Color = Color(1.0, 0.85, 0.2, 0.75), reticle_radius: float = 0.045) -> void:
	if _laser_guide == null:
		_laser_guide = MeshInstance3D.new()
		_laser_guide.name = "LaserGuide"
		var cyl = CylinderMesh.new()
		cyl.top_radius = 0.0018
		cyl.bottom_radius = 0.0028
		cyl.height = 1.0
		cyl.radial_segments = 12
		_laser_guide.mesh = cyl
		
		_laser_mat = StandardMaterial3D.new()
		_laser_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_laser_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_laser_guide.material_override = _laser_mat
		add_child(_laser_guide)
		
	if _ground_reticle == null:
		_ground_reticle = MeshInstance3D.new()
		_ground_reticle.name = "GroundReticle"
		var ring = TorusMesh.new()
		ring.inner_radius = 0.035
		ring.outer_radius = 0.045
		ring.rings = 24
		ring.ring_segments = 16
		_ground_reticle.mesh = ring
		
		_ground_reticle_mat = StandardMaterial3D.new()
		_ground_reticle_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ground_reticle_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ground_reticle.material_override = _ground_reticle_mat
		add_child(_ground_reticle)
		
	if _laser_mat != null:
		_laser_mat.albedo_color = color
	if _ground_reticle_mat != null:
		_ground_reticle_mat.albedo_color = color
		
	var dist = from_pos.distance_to(to_pos)
	if dist > 0.05:
		_laser_guide.visible = true
		var mid = (from_pos + to_pos) * 0.5
		_laser_guide.global_position = mid
		_laser_guide.scale = Vector3(1.0, dist, 1.0)
		_laser_guide.look_at(to_pos, Vector3.UP)
		_laser_guide.rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))
		
		_ground_reticle.visible = true
		_ground_reticle.global_position = Vector3(to_pos.x, 0.003, to_pos.z)
		var scale_fac = reticle_radius / 0.045
		_ground_reticle.scale = Vector3(scale_fac, scale_fac, scale_fac)
	else:
		_laser_guide.visible = false
		_ground_reticle.visible = false

func _hide_laser_guide() -> void:
	if _laser_guide != null:
		_laser_guide.visible = false
	if _ground_reticle != null:
		_ground_reticle.visible = false

