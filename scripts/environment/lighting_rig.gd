@tool
class_name LightingRigController
extends Node3D

## Explicit programmatic configuration for outdoor golf lighting & ACES tonemapping.
## Ensures physically grounded sun angles, clear sky, no fog, and highlight protection.

@export var apply_in_editor: bool = true

@onready var sun_light: DirectionalLight3D = $SunLight
@onready var world_env: WorldEnvironment = $WorldEnvironment

func _ready() -> void:
	apply_lighting_setup()

func apply_lighting_setup() -> void:
	# 1. Calibrated Directional Sun (raking morning sun)
	if sun_light == null:
		sun_light = get_node_or_null("SunLight")
	if sun_light != null:
		sun_light.rotation_degrees = Vector3(-35.0, -45.0, 0.0)
		sun_light.light_color = Color(1.0, 0.96, 0.88) # Warm daylight
		sun_light.light_energy = 1.1
		sun_light.shadow_enabled = true
		sun_light.shadow_bias = 0.03
		sun_light.shadow_normal_bias = 1.2
		sun_light.shadow_blur = 1.0

	# 2. WorldEnvironment with Clear Procedural Sky, No Fog, and ACES Tonemapping
	if world_env == null:
		world_env = get_node_or_null("WorldEnvironment")
	if world_env != null:
		var env := world_env.environment
		if env == null:
			env = Environment.new()
			world_env.environment = env

		# Completely disable any fog
		env.fog_enabled = false
		env.volumetric_fog_enabled = false

		env.background_mode = Environment.BG_SKY

		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = Color(0.35, 0.58, 0.92)
		sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.90)
		sky_mat.sky_curve = 0.10
		sky_mat.ground_bottom_color = Color(0.35, 0.42, 0.36)
		sky_mat.ground_horizon_color = Color(0.70, 0.80, 0.90)
		sky_mat.ground_curve = 0.02
		sky_mat.sun_angle_max = 30.0

		var sky := Sky.new()
		sky.sky_material = sky_mat
		env.sky = sky

		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 0.85
		env.ambient_light_energy = 0.40

		# ACES tonemapping
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.tonemap_exposure = 1.0
		env.tonemap_white = 1.0
