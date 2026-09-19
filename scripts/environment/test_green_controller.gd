class_name TestGreenController
extends Node3D

## Master controller for the test putting green environment.
## Connects green terrain, ball rolling physics, putting gameplay controller,
## camera presets, and the HUD simulator dashboard.

const GreenGeneratorScript = preload("res://scripts/environment/green_generator.gd")
const FreeLookCameraScript = preload("res://scripts/camera/free_look_camera.gd")

@onready var green_generator: GreenGenerator = $GreenSurface
@onready var flag_assembly: Node3D = $GolfFlagAssembly
@onready var golf_ball: GolfBallPhysics = $GolfBall
@onready var inspection_camera: FreeLookCamera = $FreeLookCamera
@onready var putting_controller: PuttingController = $PuttingController
@onready var xr_player: XROrigin3D = get_node_or_null("XRPlayer")
@onready var course_manager: CourseManager = get_node_or_null("CourseManager")
@onready var match_manager: MatchManager = get_node_or_null("MatchManager")

var is_grid_visible: bool = true

func _ready() -> void:
	_force_clean_environment()
	if course_manager != null:
		course_manager.green_generator = green_generator
		course_manager.test_green_controller = self
		course_manager.golf_ball = golf_ball
	call_deferred("_align_scene_elements")

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G:
			toggle_contour_grid()
		elif event.keycode == KEY_N and course_manager != null and course_manager.has_method("cycle_next_green"):
			var next_green = course_manager.call("cycle_next_green")
			if next_green != null:
				print("[TestGreen] Switched to green: ", next_green.get("display_name"))

func toggle_contour_grid() -> void:
	is_grid_visible = not is_grid_visible
	if green_generator != null and green_generator.material_override is ShaderMaterial:
		var mat: ShaderMaterial = green_generator.material_override
		mat.set_shader_parameter("show_contour_grid", is_grid_visible)

func _force_clean_environment() -> void:
	var lighting_rig := get_node_or_null("LightingRig")
	if lighting_rig == null:
		return
		
	var world_environment: WorldEnvironment = lighting_rig.get_node_or_null("WorldEnvironment")
	if world_environment != null:
		var env: Environment = world_environment.environment
		if env == null:
			env = Environment.new()
			world_environment.environment = env

		env.background_mode = Environment.BG_SKY
		env.fog_enabled = false
		env.volumetric_fog_enabled = false
		
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = Color(0.35, 0.58, 0.92)
		sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.90)
		sky_mat.ground_bottom_color = Color(0.35, 0.42, 0.36)
		sky_mat.ground_horizon_color = Color(0.70, 0.80, 0.90)
		sky_mat.sky_curve = 0.10
		sky_mat.ground_curve = 0.02
		sky_mat.sun_angle_max = 30.0
		
		var new_sky := Sky.new()
		new_sky.sky_material = sky_mat
		env.sky = new_sky
		
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 0.85
		env.ambient_light_energy = 0.45
		
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.tonemap_exposure = 1.0
		env.tonemap_white = 1.0

	var sun: DirectionalLight3D = lighting_rig.get_node_or_null("SunLight")
	if sun != null:
		sun.rotation_degrees = Vector3(-35.0, -45.0, 0.0)
		sun.light_color = Color(1.0, 0.96, 0.88)
		sun.light_energy = 1.1
		sun.shadow_enabled = true
		sun.shadow_bias = 0.03
		sun.shadow_normal_bias = 1.2

func _align_scene_elements() -> void:
	if green_generator == null:
		return
		
	# 1. Align flagstick and cup assembly with the green surface at the cup location (8-ft practice pin)
	var cup_xz := Vector2(0.0, 0.0)
	green_generator.set("cup_position_xz", cup_xz)
	var cup_y: float = green_generator.call("get_surface_height", cup_xz.x, cup_xz.y)
	if flag_assembly != null:
		flag_assembly.position = Vector3(cup_xz.x, cup_y, cup_xz.y)
		flag_assembly.visible = true

	# 2. Align golf ball resting on the bentgrass surface at standard address
	var ball_xz := Vector2(0.0, 2.4)
	var ball_y: float = green_generator.call("get_surface_height", ball_xz.x, ball_xz.y)
	var ball_pos := Vector3(ball_xz.x, ball_y + 0.0213, ball_xz.y)
	print("[TestGreen] Target layout: Ball at ", ball_xz, " -> Cup at ", cup_xz, " -> Distance: ", "%.1f" % (ball_xz - cup_xz).length(), " m (", "%.1f" % ((ball_xz - cup_xz).length() * 3.28084), " ft)")
	if golf_ball != null:
		golf_ball.position = ball_pos
		golf_ball.call("init_with_green", green_generator)

	# 3. Connect Putting Controller
	if putting_controller != null:
		putting_controller.set("golf_ball", golf_ball)
		putting_controller.set("green_generator", green_generator)
		putting_controller.set("default_ball_pos", ball_xz)
		putting_controller.set("cup_pos", cup_xz)

	# 4. Synchronize inspection camera targets & trigger default address perspective
	if inspection_camera != null:
		inspection_camera.near = 0.05
		inspection_camera.far = 2000.0
		inspection_camera.set("ball_position", ball_pos)
		inspection_camera.set("cup_position", Vector3(cup_xz.x, cup_y, cup_xz.y))
		inspection_camera.call("set_preset", FreeLookCameraScript.PresetView.ADDRESS, false)
		
	# 5. Position XR origin near ball address at turf height
	if xr_player != null:
		xr_player.position = Vector3(0.4, ball_y, ball_xz.y)

## Dynamically orients the putting course (green terrain, cup, flag, and ball)
## so the putting line starts at the player's mini-tee position and flows along the aimed line.
func align_to_tee_box(tee_pos: Vector3, rotation_deg: float) -> void:
	if green_generator == null:
		return
	
	var course_basis := Basis(Vector3.UP, deg_to_rad(rotation_deg))
	
	# In local coordinates of green_generator: ball is at (0, 0, 2.4), cup is at (0, 0, 0)
	# Align so local (0, 0, 2.4) lands precisely at tee_pos on the physical floor
	green_generator.global_transform.basis = course_basis
	green_generator.global_position = tee_pos - course_basis * Vector3(0.0, 0.0, 2.4)
	var turf_h_at_tee: float = green_generator.call("get_surface_height", 0.0, 2.4)
	green_generator.global_position.y = tee_pos.y - turf_h_at_tee
	
	# The cup is at local (0, 0, 0) -> world position:
	var cup_local_y: float = green_generator.call("get_surface_height", 0.0, 0.0)
	var cup_world := green_generator.to_global(Vector3(0.0, cup_local_y, 0.0))
	
	if flag_assembly != null:
		flag_assembly.global_transform.basis = course_basis
		flag_assembly.global_position = cup_world
		flag_assembly.visible = true
	
	if golf_ball != null:
		if golf_ball.state == GolfBallPhysics.BallState.AT_REST:
			var ball_world := tee_pos
			ball_world.y = tee_pos.y + 0.0213 # Ball sits flush on turf/floor
			golf_ball.global_position = ball_world
			golf_ball.init_with_green(green_generator)
			golf_ball.visible = false # Never show virtual ball while at rest on tee

	if putting_controller != null:
		putting_controller.golf_ball = golf_ball
		putting_controller.green_generator = green_generator

var is_course_visible: bool = true

## Controls whether the virtual championship putting green, cup, flag, and ball are visible.
## Used during mini-tee box calibration so the physical room and putting mat remain completely unobstructed.
func set_course_visible(vis: bool) -> void:
	is_course_visible = vis
	if green_generator != null:
		green_generator.visible = vis
	if flag_assembly != null:
		flag_assembly.visible = vis
	if golf_ball != null:
		golf_ball.visible = false # Phase 1: Keep hidden during tracking validation
	if putting_controller != null:
		putting_controller.process_mode = Node.PROCESS_MODE_INHERIT if vis else Node.PROCESS_MODE_DISABLED
	print("[TestGreen] Course visibility set to: ", vis)

