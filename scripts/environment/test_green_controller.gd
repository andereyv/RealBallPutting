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
## Distance from the tee to the hole (m). The whole green is placed so the cup lies this far down the aimed line
## (the green keeps its shape around the cup; the tee just sits further up or down the slope).
var pin_distance_m: float = 2.4

## Longest pin that still keeps the tee on the green (green half-length minus fringe and a margin).
func max_pin_distance() -> float:
	if green_generator == null:
		return 5.5
	return maxf(1.0, float(green_generator.green_length) * 0.5 - float(green_generator.fringe_width) - 0.3 - _profile_cup().y)

## Hole layout (2026-09-23, rounds): where on the green the ball and the cup are (green-local XZ). When off, the
## practice layout is used: the green's own cup, ball pin_distance_m straight "below" it.
var use_hole_layout := false
var hole_ball_local := Vector2(0.0, 2.4)
var hole_cup_local := Vector2.ZERO
var _has_tee := false
var _tee_pos := Vector3.ZERO
var _tee_rot_deg := 0.0
## Glide (after a missed putt in a round the green slides so the ball's new spot lands on the ball spot)
const GLIDE_S := 1.1
var _glide_t := -1.0
var _glide_from := Transform3D.IDENTITY
var _glide_to := Transform3D.IDENTITY
var _glide_next := false
signal glide_finished()
## Everything needed to redraw the virtual course offline from a recording (xr_controller logs it as "SCENE {...}")
signal scene_changed(info: Dictionary)
var _scene_log_t := 0.0

func scene_info(reason: String) -> Dictionary:
	var t := green_generator.global_transform
	var lay := current_layout()
	var prof := ""
	if course_manager != null and course_manager.get_current_profile() != null:
		prof = course_manager.get_current_profile().id
	var e := t.basis.get_euler()
	return {"why": reason, "o": [snappedf(t.origin.x, 0.0001), snappedf(t.origin.y, 0.0001), snappedf(t.origin.z, 0.0001)],
		"yaw": snappedf(rad_to_deg(e.y), 0.001), "pitch": snappedf(rad_to_deg(e.x), 0.001), "roll": snappedf(rad_to_deg(e.z), 0.001),
		"ball": [snappedf(lay[0].x, 0.0001), snappedf(lay[0].y, 0.0001)], "cup": [snappedf(lay[1].x, 0.0001), snappedf(lay[1].y, 0.0001)],
		"green": prof, "vis": is_course_visible, "layout": "hole" if use_hole_layout else "practice", "pin": pin_distance_m,
		"tee": [snappedf(_tee_pos.x, 0.0001), snappedf(_tee_pos.y, 0.0001), snappedf(_tee_pos.z, 0.0001)], "tee_rot": snappedf(_tee_rot_deg, 0.01),
		"glide": _glide_t >= 0.0, "scenery": parkland != null and parkland.visible}

func set_hole_layout(ball_local: Vector2, cup_local: Vector2, glide: bool = false) -> void:
	use_hole_layout = true
	hole_ball_local = ball_local
	hole_cup_local = cup_local
	_glide_next = glide and _has_tee and is_course_visible
	if green_generator != null:
		green_generator.set_cup_fast(cup_local)
	if _has_tee:
		align_to_tee_box(_tee_pos, _tee_rot_deg)

func clear_hole_layout() -> void:
	use_hole_layout = false
	if green_generator != null:
		green_generator.set_cup_fast(_profile_cup())
	if _has_tee:
		align_to_tee_box(_tee_pos, _tee_rot_deg)

func is_gliding() -> bool:
	return _glide_t >= 0.0

func _profile_cup() -> Vector2:
	if course_manager != null and course_manager.get_current_profile() != null:
		return course_manager.get_current_profile().cup_position_xz
	return Vector2.ZERO

## [ball_local, cup_local] of the current layout
func current_layout() -> Array:
	if use_hole_layout:
		return [hole_ball_local, hole_cup_local]
	var cup := _profile_cup()
	var d := clampf(pin_distance_m, 1.0, max_pin_distance())
	return [cup + Vector2(0.0, d), cup]

func _process(delta: float) -> void:
	if _glide_t < 0.0:
		return
	_glide_t += delta
	var k := clampf(_glide_t / GLIDE_S, 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k)
	_apply_green_transform(_glide_from.interpolate_with(_glide_to, k))
	_scene_log_t += delta
	if _scene_log_t >= 0.1:
		_scene_log_t = 0.0
		scene_changed.emit(scene_info("glide"))
	if _glide_t >= GLIDE_S:
		_glide_t = -1.0
		_apply_green_transform(_glide_to)
		_finish_alignment()
		scene_changed.emit(scene_info("glide_end"))
		glide_finished.emit()

var parkland: Node3D = null ## scripts/environment/parkland.gd, child of the green so it follows alignment

func _ready() -> void:
	_force_clean_environment()
	if green_generator != null:
		# the green only receives shadows (flag, ball); casting put its 61k triangles into the shadow map every frame
		green_generator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parkland = preload("res://scripts/environment/parkland.gd").new()
		parkland.name = "Parkland"
		green_generator.add_child(parkland)
		parkland.build(green_generator)

## Scenery on/off (menu): the parkland ring around the green.
func set_scenery(on: bool, trees: bool = true) -> void:
	if parkland != null:
		parkland.visible = on
		if parkland.has_method("set_trees_visible"):
			parkland.set_trees_visible(trees)
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
		# late-afternoon parkland light: lower, warmer sun (long tree shadows); the sky's sun glow follows it
		sun.rotation_degrees = Vector3(-26.0, -40.0, 0.0)
		sun.light_color = Color(1.0, 0.89, 0.74)
		sun.light_energy = 1.2
		var sky_dome: MeshInstance3D = lighting_rig.get_node_or_null("SkyDome")
		if sky_dome != null and sky_dome.material_override is ShaderMaterial:
			(sky_dome.material_override as ShaderMaterial).set_shader_parameter("sun_direction", sun.transform.basis.z)
		sun.shadow_enabled = true
		sun.shadow_bias = 0.03
		sun.shadow_normal_bias = 1.2
		# Quest budget (2026-09-24): one orthogonal shadow map covering the green and the player (was 4 PSSM
		# splits out to 100 m, each rendering every tree again)
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		sun.directional_shadow_max_distance = 10.0
		sun.shadow_blur = 0.6

## Settings -> Shadows
func set_shadows(on: bool) -> void:
	var lighting_rig := get_node_or_null("LightingRig")
	var sun: DirectionalLight3D = lighting_rig.get_node_or_null("SunLight") if lighting_rig != null else null
	if sun != null:
		sun.shadow_enabled = on

## Settings -> Flow lines (moving slope streaks on the green)
func set_flow_lines(on: bool) -> void:
	if green_generator != null and green_generator.material_override is ShaderMaterial:
		(green_generator.material_override as ShaderMaterial).set_shader_parameter("show_flow_lines", on)

func _align_scene_elements() -> void:
	if green_generator == null:
		return
	if _has_tee:
		# XR: the course is laid out around the ball spot (a desktop layout here would move the flag off the cup)
		align_to_tee_box(_tee_pos, _tee_rot_deg)
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

## Dynamically orients the putting course (green terrain, cup, flag, and ball) so the layout's ball position lands
## on the player's ball spot and the cup lies straight down the aimed line. The green is turned around as needed.
func align_to_tee_box(tee_pos: Vector3, rotation_deg: float) -> void:
	if green_generator == null:
		return
	_has_tee = true
	_tee_pos = tee_pos
	_tee_rot_deg = rotation_deg
	_aim_sun(rotation_deg)

	var lay := current_layout()
	var ball: Vector2 = lay[0]
	var cup: Vector2 = lay[1]
	if green_generator.cup_position_xz != cup:
		green_generator.set_cup_fast(cup)
	var dir := cup - ball
	if dir.length() < 0.01:
		dir = Vector2(0.0, -1.0)
	# yaw that turns the local ball->cup direction onto the aimed line (Godot yaw: (0,0,-1) -> (-sin a, 0, -cos a))
	var yaw := deg_to_rad(rotation_deg) - atan2(-dir.x, -dir.y)
	var b := Basis(Vector3.UP, yaw)
	var origin := tee_pos - b * Vector3(ball.x, 0.0, ball.y)
	origin.y = tee_pos.y - float(green_generator.call("get_surface_height", ball.x, ball.y))
	var target := Transform3D(b, origin)
	if _glide_next:
		_glide_next = false
		_glide_from = green_generator.global_transform
		_glide_to = target
		_glide_t = 0.0
		scene_changed.emit(scene_info("glide_start"))
		return
	_glide_t = -1.0
	_apply_green_transform(target)
	_finish_alignment()
	scene_changed.emit(scene_info("align"))

## Green + flag follow this transform (the flag is not a child of the green)
func _apply_green_transform(t: Transform3D) -> void:
	green_generator.global_transform = t
	var cup: Vector2 = green_generator.cup_position_xz
	var cup_y: float = green_generator.call("get_surface_height", cup.x, cup.y)
	if flag_assembly != null:
		flag_assembly.global_transform.basis = t.basis
		flag_assembly.global_position = green_generator.to_global(Vector3(cup.x, cup_y, cup.y))
		flag_assembly.visible = is_course_visible

func _finish_alignment() -> void:
	if golf_ball != null:
		if golf_ball.state == GolfBallPhysics.BallState.AT_REST:
			var ball_world := _tee_pos
			ball_world.y = _tee_pos.y + 0.0213 # Ball sits flush on turf/floor
			golf_ball.global_position = ball_world
			golf_ball.init_with_green(green_generator)
			golf_ball.visible = false # Never show virtual ball while at rest on tee
	if putting_controller != null:
		putting_controller.golf_ball = golf_ball
		putting_controller.green_generator = green_generator

## Hole number on the flag (rounds); 0 = plain flag (practice).
var _flag_vp: SubViewport = null
var _flag_label: Label = null
func set_flag_number(n: int) -> void:
	var cloth := flag_assembly.get_node_or_null("Flagstick/FlagCloth") as MeshInstance3D if flag_assembly != null else null
	if cloth == null or cloth.mesh == null or not (cloth.mesh.surface_get_material(0) is ShaderMaterial):
		return
	var mat := cloth.mesh.surface_get_material(0) as ShaderMaterial
	if n <= 0:
		mat.set_shader_parameter("show_number", false)
		return
	if _flag_vp == null:
		_flag_vp = SubViewport.new()
		_flag_vp.size = Vector2i(256, 256)
		_flag_vp.transparent_bg = true
		_flag_vp.disable_3d = true
		add_child(_flag_vp)
		_flag_label = Label.new()
		_flag_label.size = Vector2(256, 256)
		_flag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_flag_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var f = load("res://fonts/InterDisplay-SemiBold.ttf")
		if f != null:
			_flag_label.add_theme_font_override("font", f)
		_flag_label.add_theme_color_override("font_color", Color.WHITE)
		_flag_vp.add_child(_flag_label)
	_flag_label.text = str(n)
	_flag_label.add_theme_font_size_override("font_size", 230 if n < 10 else 170)
	_flag_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	mat.set_shader_parameter("number_tex", _flag_vp.get_texture())
	mat.set_shader_parameter("show_number", true)

## World position of the cup (flag foot)
func cup_world() -> Vector3:
	return flag_assembly.global_position if flag_assembly != null else Vector3.ZERO

## Keep the low sun behind the player's right shoulder whatever way the tee is aimed: the green and the trees
## beyond it are lit from the front (golden), shadows fall towards the hole.
func _aim_sun(course_rotation_deg: float) -> void:
	var lighting_rig := get_node_or_null("LightingRig")
	if lighting_rig == null:
		return
	var sun: DirectionalLight3D = lighting_rig.get_node_or_null("SunLight")
	if sun == null:
		return
	sun.rotation_degrees = Vector3(-26.0, course_rotation_deg + 150.0, 0.0)
	var sky_dome: MeshInstance3D = lighting_rig.get_node_or_null("SkyDome")
	if sky_dome != null and sky_dome.material_override is ShaderMaterial:
		(sky_dome.material_override as ShaderMaterial).set_shader_parameter("sun_direction", sun.transform.basis.z)
	# scenery is lit per vertex from the same sun
	if parkland != null and parkland.has_method("get_split_materials"):
		var sc: Color = sun.light_color * sun.light_energy * 0.85
		for m in parkland.get_split_materials():
			m.set_shader_parameter("sun_dir", sun.global_transform.basis.z)
			m.set_shader_parameter("sun_col", Vector3(sc.r, sc.g, sc.b))

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
	if green_generator != null:
		scene_changed.emit(scene_info("visible" if vis else "hidden"))

