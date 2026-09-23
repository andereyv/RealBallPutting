@tool
extends MeshInstance3D
## Regulation golf cup (108 mm), built to be seen from the INSIDE.
##
## Top to bottom, like a freshly cut tournament hole:
##   - a band of turf roots / soil (the top ~2 cm is cut earth, the liner is set below the surface)
##   - a crisp white lip where the painted liner begins, catching the light
##   - the white painted band of the liner
##   - the dark liner wall, shading darker towards the bottom (no sky reaches down there)
##   - the floor, with a metal ferrule socket in the middle
##
## The old cup was two CylinderMeshes with outward normals, so you saw their OUTSIDE through the
## square pit in the green: a black crescent with a white arc. The green shader now cuts a round
## hole (putting_green.gdshader, cup_* uniforms) and this mesh fills it.

@export var radius: float = 0.054: ## cut radius; must match GreenGenerator.cup_radius
	set(v):
		radius = v
		_rebuild()
@export var depth: float = 0.109: ## floor = where ball_controller rests a holed ball (bottom at -0.109)
	set(v):
		depth = v
		_rebuild()
@export var segments: int = 72:
	set(v):
		segments = maxi(v, 12)
		_rebuild()
@export var soil_band: float = 0.008: ## visible cut earth above the liner (real: ~25 mm, but at 22 mm it read as a sunken sleeve in VR)
	set(v):
		soil_band = v
		_rebuild()
@export var liner_band: float = 0.030: ## white painted band at the top of the liner
	set(v):
		liner_band = v
		_rebuild()
@export var liner_inset: float = 0.0025: ## the liner wall sits this far inside the cut earth
	set(v):
		liner_inset = v
		_rebuild()

const ROOTS := Color(0.24, 0.25, 0.13)
const SOIL := Color(0.38, 0.28, 0.18)
const LINER_WHITE := Color(0.86, 0.86, 0.84)
const LINER_DARK := Color(0.13, 0.13, 0.14)
const FLOOR_DARK := Color(0.09, 0.09, 0.095)
const FERRULE_COLLAR := Color(0.30, 0.31, 0.32)
const SOCKET := Color(0.008, 0.008, 0.009)

func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rebuild()

func _rebuild() -> void:
	if not is_node_ready():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var r_out := radius
	var r_in := radius - liner_inset
	var y_liner := -soil_band
	var y_dark := -(soil_band + liner_band)
	var y_floor := -depth

	# Cut earth: dark roots at the top turning to soil, with per-clump variation so it reads organic.
	_wall(st, [
		[0.0, r_out, ROOTS],
		[-soil_band * 0.35, r_out, ROOTS.lerp(SOIL, 0.6)],
		[y_liner, r_out, SOIL * 0.78],
	], true)
	# The liner's top edge: a thin horizontal white ring that closes the gap between earth and liner.
	_ring_up(st, y_liner, r_in, r_out, LINER_WHITE * 1.02, LINER_WHITE)
	# White painted band, slightly shaded at its lower edge.
	_wall(st, [
		[y_liner, r_in, LINER_WHITE],
		[y_dark, r_in, LINER_WHITE * 0.80],
	], false)
	# Dark liner wall, darkening towards the floor (ambient occlusion baked into vertex colours).
	_wall(st, [
		[y_dark, r_in, LINER_DARK],
		[y_floor + 0.012, r_in, LINER_DARK * 0.55],
		[y_floor, r_in, FLOOR_DARK * 0.65],
	], false)
	# Floor: darker in the corner where it meets the wall.
	_disc_up(st, y_floor, r_in, FLOOR_DARK, FLOOR_DARK * 0.65)
	# Ferrule socket: metal collar and the dark hole the flagstick sits in.
	_ring_up(st, y_floor + 0.0006, 0.0095, 0.0125, FERRULE_COLLAR, FERRULE_COLLAR * 0.8)
	_disc_up(st, y_floor + 0.0007, 0.0095, SOCKET, SOCKET)

	var m := st.commit()
	# The shader shows each surface only from its inner side, so the outside of the cup can never
	# poke through the green (first version used a plain material with culling off, and its outer
	# wall showed wherever the turf around the hole dipped below the rim).
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/cup_liner.gdshader")
	m.surface_set_material(0, mat)
	mesh = m

func _angle(i: int) -> float:
	return TAU * float(i % segments) / float(segments)

## Deterministic 0..1 per segment, for the soil clumps.
func _hash(i: int) -> float:
	var x := sin(float(i % segments) * 12.9898) * 43758.5453
	return x - floorf(x)

## Vertical wall, rows = [[y, r, color], ...] from top to bottom, normals facing the cup's axis.
func _wall(st: SurfaceTool, rows: Array, clumpy: bool) -> void:
	for k in range(rows.size() - 1):
		var top: Array = rows[k]
		var bot: Array = rows[k + 1]
		for i in range(segments):
			var a0 := _angle(i)
			var a1 := _angle(i + 1)
			var v0 := 1.0
			var v1 := 1.0
			if clumpy:
				v0 = 0.86 + 0.28 * _hash(i)
				v1 = 0.86 + 0.28 * _hash(i + 1)
			var A := Vector3(cos(a0) * float(top[1]), float(top[0]), sin(a0) * float(top[1]))
			var B := Vector3(cos(a1) * float(top[1]), float(top[0]), sin(a1) * float(top[1]))
			var C := Vector3(cos(a1) * float(bot[1]), float(bot[0]), sin(a1) * float(bot[1]))
			var D := Vector3(cos(a0) * float(bot[1]), float(bot[0]), sin(a0) * float(bot[1]))
			var n0 := Vector3(-cos(a0), 0.0, -sin(a0))
			var n1 := Vector3(-cos(a1), 0.0, -sin(a1))
			var ct: Color = top[2]
			var cb: Color = bot[2]
			# Seen from the axis, A B C run clockwise (Godot front face).
			_v(st, A, n0, ct * v0)
			_v(st, B, n1, ct * v1)
			_v(st, C, n1, cb * v1)
			_v(st, A, n0, ct * v0)
			_v(st, C, n1, cb * v1)
			_v(st, D, n0, cb * v0)

## Flat annulus facing up, between r_a (inner) and r_b (outer).
func _ring_up(st: SurfaceTool, y: float, r_a: float, r_b: float, c_in: Color, c_out: Color) -> void:
	for i in range(segments):
		var a0 := _angle(i)
		var a1 := _angle(i + 1)
		var I0 := Vector3(cos(a0) * r_a, y, sin(a0) * r_a)
		var I1 := Vector3(cos(a1) * r_a, y, sin(a1) * r_a)
		var O0 := Vector3(cos(a0) * r_b, y, sin(a0) * r_b)
		var O1 := Vector3(cos(a1) * r_b, y, sin(a1) * r_b)
		_v(st, I0, Vector3.UP, c_in)
		_v(st, O0, Vector3.UP, c_out)
		_v(st, O1, Vector3.UP, c_out)
		_v(st, I0, Vector3.UP, c_in)
		_v(st, O1, Vector3.UP, c_out)
		_v(st, I1, Vector3.UP, c_in)

## Flat disc facing up.
func _disc_up(st: SurfaceTool, y: float, r: float, c_center: Color, c_edge: Color) -> void:
	var O := Vector3(0.0, y, 0.0)
	for i in range(segments):
		var a0 := _angle(i)
		var a1 := _angle(i + 1)
		_v(st, O, Vector3.UP, c_center)
		_v(st, Vector3(cos(a0) * r, y, sin(a0) * r), Vector3.UP, c_edge)
		_v(st, Vector3(cos(a1) * r, y, sin(a1) * r), Vector3.UP, c_edge)

func _v(st: SurfaceTool, p: Vector3, n: Vector3, c: Color) -> void:
	c.a = 1.0
	st.set_color(c.srgb_to_linear()) # colours above are authored in sRGB; the shader wants linear
	st.set_normal(n)
	st.add_vertex(p)
