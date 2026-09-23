@tool
class_name GreenGenerator
extends MeshInstance3D

## Procedural Championship Putting Green Generator for Godot 4.
## Generates a high-subdivision undulating green mesh with accurate bentgrass slopes,
## organic fringe/collar zones, recessed regulation cup cutout, and collision mesh.

@export_group("Dimensions & Resolution")
@export var green_length: float = 14.0:
	set(v): green_length = v; _queue_refresh()
@export var green_width: float = 9.0:
	set(v): green_width = v; _queue_refresh()
@export var resolution_x: int = 140:
	set(v): resolution_x = v; _queue_refresh()
@export var resolution_z: int = 220:
	set(v): resolution_z = v; _queue_refresh()

@export_group("Slope & Undulation Profile")
@export var overall_grade_slope: float = 0.012:
	set(v): overall_grade_slope = v; _queue_refresh()
@export var cross_break_strength: float = 0.06:
	set(v): cross_break_strength = v; _queue_refresh()
@export var tier_ridge_height: float = 0.12:
	set(v): tier_ridge_height = v; _queue_refresh()
@export var noise_amplitude: float = 0.035:
	set(v): noise_amplitude = v; _queue_refresh()
@export var noise_frequency: float = 0.25:
	set(v): noise_frequency = v; _queue_refresh()

@export_group("Fringe & Shape")
@export var fringe_width: float = 0.85:
	set(v): fringe_width = v; _queue_refresh()
@export var organic_edge_variance: float = 0.45:
	set(v): organic_edge_variance = v; _queue_refresh()

@export_group("Hole Placement")
@export var cup_position_xz: Vector2 = Vector2(0.0, 0.0):
	set(v): cup_position_xz = v; _queue_refresh()
@export var cup_radius: float = 0.054:
	set(v): cup_radius = v; _queue_refresh()
@export var cup_depth: float = 0.12:
	set(v): cup_depth = v; _queue_refresh()

@export_group("Physics")
@export var generate_collision: bool = true:
	set(v): generate_collision = v; _queue_refresh()

var _fast_noise: FastNoiseLite
var _is_dirty: bool = false

func _ready() -> void:
	_init_noise()
	generate_green()

func _queue_refresh() -> void:
	if not _is_dirty and is_inside_tree():
		_is_dirty = true
		call_deferred("_regenerate_if_dirty")

func _regenerate_if_dirty() -> void:
	if _is_dirty:
		_is_dirty = false
		_init_noise()
		generate_green()

## Batch apply entire green profile in a single rebuild
func apply_profile(profile: Resource) -> void:
	if profile == null:
		return
	green_length = profile.green_length
	green_width = profile.green_width
	resolution_x = profile.resolution_x
	resolution_z = profile.resolution_z
	overall_grade_slope = profile.overall_grade_slope
	cross_break_strength = profile.cross_break_strength
	tier_ridge_height = profile.tier_ridge_height
	noise_amplitude = profile.noise_amplitude
	noise_frequency = profile.noise_frequency
	fringe_width = profile.fringe_width
	organic_edge_variance = profile.organic_edge_variance
	cup_position_xz = profile.cup_position_xz
	cup_radius = profile.cup_radius
	cup_depth = profile.cup_depth
	_init_noise()
	generate_green()

func _init_noise() -> void:
	if _fast_noise == null:
		_fast_noise = FastNoiseLite.new()
		_fast_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_fast_noise.frequency = noise_frequency
		_fast_noise.fractal_octaves = 2
		_fast_noise.fractal_gain = 0.4

## Analytical height function at any (x, z) coordinate
func get_surface_height(x: float, z: float) -> float:
	# 1. Subtle back-to-front grade (higher at the back pin shelf)
	var base_slope := -z * overall_grade_slope
	
	# 2. Championship Two-Tier Transition Ridge
	# S-curve rise of ~12cm between z = 1.2 (lower collection bowl) and z = -1.2 (upper shelf)
	var tier_t := clampf((-z + 0.2) / 2.4, 0.0, 1.0)
	var tier := smoothstep(0.0, 1.0, tier_t) * tier_ridge_height
	
	# 3. Cross-slope crown (produces authentic left-to-right borrow toward the cup)
	var cross := -sin(x * 0.32 + 0.15) * cross_break_strength
	
	# 4. Organic micro-swales via low-amplitude noise
	var organic := 0.0
	if _fast_noise != null:
		organic = _fast_noise.get_noise_2d(x, z) * noise_amplitude
		
	# 5. Natural perimeter apron fall-off (edges roll gently away from green)
	var norm_x := (x / (green_width * 0.5))
	var norm_z := (z / (green_length * 0.5))
	var dist_center_sq := norm_x * norm_x + norm_z * norm_z
	var perimeter_roll := 0.0
	if dist_center_sq > 0.8:
		perimeter_roll = -pow(dist_center_sq - 0.8, 2.0) * 0.15

	return base_slope + tier + cross + organic + perimeter_roll

## Computes surface normal analytically using central differences
func get_surface_normal(x: float, z: float) -> Vector3:
	var eps := 0.02
	var h_l := get_surface_height(x - eps, z)
	var h_r := get_surface_height(x + eps, z)
	var h_d := get_surface_height(x, z - eps)
	var h_u := get_surface_height(x, z + eps)
	var dx := (h_r - h_l) / (2.0 * eps)
	var dz := (h_u - h_d) / (2.0 * eps)
	return Vector3(-dx, 1.0, -dz).normalized()

## Calculates whether a point is in the putting surface or fringe collar (0.0 to 1.0)
func get_fringe_factor(x: float, z: float) -> float:
	var half_w := (green_width * 0.5) - fringe_width
	var half_l := (green_length * 0.5) - fringe_width
	
	# Organic kidney / championship green contour perturbation
	var angle := atan2(z, x)
	var organic_offset := 0.0
	if _fast_noise != null:
		organic_offset = _fast_noise.get_noise_2d(cos(angle) * 3.0, sin(angle) * 3.0) * organic_edge_variance
	
	var r_green_x := half_w + organic_offset * 0.6
	var r_green_z := half_l + organic_offset * 0.9
	
	var norm_x := x / maxf(r_green_x, 0.1)
	var norm_z := z / maxf(r_green_z, 0.1)
	var dist := sqrt(norm_x * norm_x + norm_z * norm_z)
	
	# Smooth transition through the collar band
	return clampf((dist - 0.82) / 0.28, 0.0, 1.0)

## Generates the high-resolution putting green mesh (the cup itself is cut in the shader)
func generate_green() -> void:
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var half_w := green_width * 0.5
	var half_l := green_length * 0.5
	var dx := green_width / float(resolution_x - 1)
	var dz := green_length / float(resolution_z - 1)
	
	# Grid of vertices
	var grid_indices: Array = []
	grid_indices.resize(resolution_x * resolution_z)
	
	var vert_idx := 0
	for iz in range(resolution_z):
		var z := -half_l + iz * dz
		for ix in range(resolution_x):
			var x := -half_w + ix * dx
			
			var dist_to_cup := Vector2(x - cup_position_xz.x, z - cup_position_xz.y).length()
			var y := get_surface_height(x, z)
			var normal := get_surface_normal(x, z)
			var fringe := get_fringe_factor(x, z)
			
			# The cup is cut per pixel in putting_green.gdshader (cup_* uniforms), not by dropping grid
			# vertices: the grid is ~6.4 cm, wider than the cup's 5.4 cm radius, so recessing vertices made
			# a 13 cm square pyramid pit whose contour lines showed up as concentric squares.
			if dist_to_cup < cup_radius:
				fringe = 0.0
			
			var uv := Vector2((x + half_w) / green_width, (z + half_l) / green_length)
			
			# Set vertex attributes
			surface_tool.set_color(Color(fringe, 0.0, 0.0, 1.0))
			surface_tool.set_normal(normal)
			surface_tool.set_uv(uv)
			surface_tool.add_vertex(Vector3(x, y, z))
			
			grid_indices[iz * resolution_x + ix] = vert_idx
			vert_idx += 1

	# Generate quad triangles
	for iz in range(resolution_z - 1):
		for ix in range(resolution_x - 1):
			var i00: int = grid_indices[iz * resolution_x + ix]
			var i10: int = grid_indices[iz * resolution_x + (ix + 1)]
			var i01: int = grid_indices[(iz + 1) * resolution_x + ix]
			var i11: int = grid_indices[(iz + 1) * resolution_x + (ix + 1)]
			
			# Triangle 1
			surface_tool.add_index(i00)
			surface_tool.add_index(i10)
			surface_tool.add_index(i01)
			
			# Triangle 2
			surface_tool.add_index(i10)
			surface_tool.add_index(i11)
			surface_tool.add_index(i01)

	surface_tool.generate_tangents()
	mesh = surface_tool.commit()
	
	# Assign default material if not set
	if material_override == null:
		var mat = load("res://shaders/putting_green_material.tres")
		if mat != null:
			material_override = mat

	_apply_cup_to_material()
	
	# Update collision body if present or requested
	_update_collision()

## Tells the green shader where to cut the cup (mesh-local XZ, so it follows course re-alignment).
func _apply_cup_to_material() -> void:
	var sm := material_override as ShaderMaterial
	if sm == null:
		return
	sm.set_shader_parameter("cup_center_local", cup_position_xz)
	sm.set_shader_parameter("cup_radius", cup_radius)

func _update_collision() -> void:
	var static_body := get_node_or_null("StaticBody3D") as StaticBody3D
	if not generate_collision:
		if static_body != null:
			static_body.queue_free()
		return
		
	if static_body == null:
		static_body = StaticBody3D.new()
		static_body.name = "StaticBody3D"
		add_child(static_body)
		if Engine.is_editor_hint():
			static_body.owner = get_tree().edited_scene_root
			
	var col_shape := static_body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape == null:
		col_shape = CollisionShape3D.new()
		col_shape.name = "CollisionShape3D"
		static_body.add_child(col_shape)
		if Engine.is_editor_hint():
			col_shape.owner = get_tree().edited_scene_root
			
	if mesh != null:
		col_shape.shape = mesh.create_trimesh_shape()
