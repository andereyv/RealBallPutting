class_name UDPBallReceiver
extends Node

## Optical Ball Tracking UDP Receiver for "Golf Sim: Real Ball Putting".
## Listens for high-speed launch data broadcast from an external optical tracking script
## (e.g. Python OpenCV webcam pipeline or high-speed camera).
##
## Expected JSON Payload Formats:
##
## 1. Ball Launch Strike:
##    {
##      "type": "launch",       // or "strike", "shot"
##      "speed_mps": 2.45,      // Ball speed in meters per second (e.g. 1.0 to 6.0 m/s)
##      "angle_deg": -1.5,      // Horizontal launch angle relative to target line (+ = right, - = left)
##      "confidence": 0.96      // Optional confidence metric (0.0 to 1.0)
##    }
##
## 2. Ball Reset / Re-spot:
##    {
##      "command": "reset"      // or "type": "reset"
##    }
##
## 3. Heartbeat / Ready:
##    {
##      "type": "ping"          // or "ready"
##    }

signal ball_strike_received(speed_mps: float, angle_deg: float, data: Dictionary)
signal ball_reset_received()
signal tracking_status_changed(connected: bool, message: String)

@export_group("Network Configuration")
@export var port: int = 4242
@export var bind_address: String = "*"
@export var enabled: bool = true

@export_group("Target References")
@export var putting_controller: PuttingController
@export var golf_ball: GolfBallPhysics

var _peer: PacketPeerUDP = null
var _is_bound: bool = false
var _total_packets_received: int = 0
var _last_received_time: float = -1.0

func _ready() -> void:
	if not enabled:
		print("[UDPBallReceiver] Disabled by export setting.")
		return
	
	_setup_receiver()

func _setup_receiver() -> void:
	_peer = PacketPeerUDP.new()
	var err := _peer.bind(port, bind_address)
	if err != OK and bind_address != "*":
		print("[UDPBallReceiver] Fallback binding to '*'...")
		err = _peer.bind(port, "*")
	if err == OK:
		_is_bound = true
		print("[UDPBallReceiver] Successfully bound to port %d. Awaiting optical tracking packets..." % port)
		tracking_status_changed.emit(true, "UDP Bound to port %d" % port)
	else:
		_is_bound = false
		print("[UDPBallReceiver] Note: Could not bind UDP socket to port %d (Code: %d). Optical UDP listener inactive." % [port, err])
		tracking_status_changed.emit(false, "UDP inactive")

func _exit_tree() -> void:
	if _peer != null and _is_bound:
		_peer.close()
		_is_bound = false
		print("[UDPBallReceiver] UDP socket closed.")

func _process(_delta: float) -> void:
	if not _is_bound or _peer == null:
		return

	# Drain all available UDP packets from the queue
	while _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		var packet_str := packet.get_string_from_utf8()
		_handle_packet_string(packet_str)

func _handle_packet_string(json_text: String) -> void:
	if json_text.is_empty():
		return

	var parsed = JSON.parse_string(json_text)
	if parsed == null or not (parsed is Dictionary):
		printerr("[UDPBallReceiver] Received invalid JSON packet: ", json_text)
		return

	var data: Dictionary = parsed
	_total_packets_received += 1
	_last_received_time = Time.get_ticks_msec() / 1000.0

	# 1. Check for Reset Command
	if data.get("command") == "reset" or data.get("type") == "reset" or data.get("action") == "reset":
		print("[UDPBallReceiver] Reset command received from tracker.")
		ball_reset_received.emit()
		_execute_ball_reset()
		return

	# 2. Check for Heartbeat / Ping
	if data.get("type") == "ping" or data.get("type") == "ready":
		print("[UDPBallReceiver] Heartbeat received from optical tracker.")
		tracking_status_changed.emit(true, "Tracker connected")
		return

	# 3. Check for Launch / Strike Event
	var has_speed := false
	var speed_mps: float = 0.0

	# Flexible key parsing for launch speed
	if data.has("speed_mps"):
		speed_mps = float(data["speed_mps"])
		has_speed = true
	elif data.has("speed"):
		speed_mps = float(data["speed"])
		has_speed = true
	elif data.has("launch_speed"):
		speed_mps = float(data["launch_speed"])
		has_speed = true
	elif data.has("velocity"):
		speed_mps = float(data["velocity"])
		has_speed = true
	elif data.has("ball_speed_mps"):
		speed_mps = float(data["ball_speed_mps"])
		has_speed = true

	# Flexible key parsing for horizontal launch angle
	var angle_deg: float = 0.0
	if data.has("angle_deg"):
		angle_deg = float(data["angle_deg"])
	elif data.has("angle"):
		angle_deg = float(data["angle"])
	elif data.has("launch_angle_deg"):
		angle_deg = float(data["launch_angle_deg"])
	elif data.has("launch_angle"):
		angle_deg = float(data["launch_angle"])
	elif data.has("horizontal_angle_deg"):
		angle_deg = float(data["horizontal_angle_deg"])

	if has_speed and speed_mps > 0.01:
		print("[UDPBallReceiver] STRIKE DETECTED -> Speed: %.2f m/s (%.1f mph), Angle: %+.1f°" % [
			speed_mps, speed_mps * 2.23694, angle_deg
		])
		ball_strike_received.emit(speed_mps, angle_deg, data)
		_execute_ball_strike(speed_mps, angle_deg, data)

func _execute_ball_strike(speed_mps: float, angle_deg: float, data: Dictionary) -> void:
	# Ensure references are linked
	_resolve_target_references()

	# If ball is currently rolling or in cup, ignore or reset first
	if golf_ball != null and golf_ball.state != GolfBallPhysics.BallState.AT_REST:
		print("[UDPBallReceiver] Ball was already in motion. Re-spotting before new strike.")
		_execute_ball_reset()

	# Calculate launch trajectory
	var aim_angle: float = 0.0
	if putting_controller != null:
		aim_angle = putting_controller.aim_angle

	# Effective launch angle in world XZ space:
	# aim_angle is base direction toward pin, angle_deg is deviation measured by optical camera
	var launch_rad := aim_angle + deg_to_rad(angle_deg)
	var launch_dir := Vector2(-sin(launch_rad), -cos(launch_rad)).normalized()
	var launch_vel := launch_dir * speed_mps

	if golf_ball != null:
		golf_ball.strike(launch_vel)
		print("[UDPBallReceiver] Fired physical ball with velocity vector: ", launch_vel)

	# Update HUD status if available
	_notify_hud(speed_mps, angle_deg, data)

func _execute_ball_reset() -> void:
	_resolve_target_references()
	if putting_controller != null:
		putting_controller.reset_ball()
	elif golf_ball != null:
		golf_ball.reset_to_position(Vector2(0.0, 2.5))

func _resolve_target_references() -> void:
	var parent_node := get_parent()
	if parent_node == null:
		return
	if putting_controller == null:
		putting_controller = parent_node.get_node_or_null("PuttingController") as PuttingController
	if golf_ball == null:
		golf_ball = parent_node.get_node_or_null("GolfBall") as GolfBallPhysics

func _notify_hud(speed_mps: float, angle_deg: float, _data: Dictionary) -> void:
	var parent_node := get_parent()
	if parent_node == null:
		return
	var hud := parent_node.get_node_or_null("InspectionHUD")
	if hud != null:
		var status_label: Label = hud.get_node_or_null("HUDPanel/VBox/StatusLabel")
		if status_label != null:
			var speed_mph := speed_mps * 2.23694
			status_label.text = "OPTICAL STRIKE! Speed: %.2f m/s (%.1f mph) • Angle: %+.1f°" % [speed_mps, speed_mph, angle_deg]
			status_label.modulate = Color(0.4, 0.95, 1.0)
