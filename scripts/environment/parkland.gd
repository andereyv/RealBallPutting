extends Node3D
## Parkland scenery around the green (prototype, 2026-09-23). Everything is generated in code, no asset downloads:
##   - ground: a first cut with mowing stripes around the green, rough beyond, gently rolling further out
##   - trees: a ring of broadleaf and pine trees (4 procedural variants, MultiMesh instanced, wind sway)
##   - hills: a distant ring of low hills with a forest silhouette on top, fading into haze
## It is a child of the GreenSurface, so it moves with the tee alignment and the pin distance.
## Budget: 6 draw calls (+ shadows), ~45k triangles.

@export var tree_count := 95
@export var tree_inner_radius := 24.0
@export var tree_outer_radius := 75.0
@export var ground_radius := 140.0
@export var seed_value := 7

var green: Node3D # GreenGenerator (get_surface_height, green_width, green_length)
## Trees are hidden per instance on the room side of the MR split (2026-09-24) instead of discarding pixels in the
## shader: a shader with discard can't skip hidden pixels early, and the stacked canopies were drawn several times over.
var _tree_sets: Array = [] # [{"mm": MultiMesh, "xf": Array[Transform3D], "reach": Array[float]}]
var _cull_key := ""
var _prewarm := false
var _mats: Array[ShaderMaterial] = []
var _rng := RandomNumberGenerator.new()

const TREE_SHADER := preload("res://shaders/parkland_tree.gdshader")
const GROUND_SHADER := preload("res://shaders/parkland_ground.gdshader")

func build(green_node: Node3D) -> void:
	green = green_node
	_rng.seed = seed_value
	for c in get_children():
		c.queue_free()
	_mats.clear()
	_tree_sets.clear()
	_cull_key = ""
	_build_ground()
	_build_hills()
	_build_trees()

## Materials that need the MR split uniforms (xr_controller registers them).
## Scenery "Open": ground and hills stay, the trees go (they are most of the scenery's drawing cost)
func set_trees_visible(on: bool) -> void:
	for c in get_children():
		if c is MultiMeshInstance3D and str(c.name).begins_with("Trees"):
			c.visible = on

func get_split_materials() -> Array:
	return _mats

# ------------------------------------------------------------------ ground
func _green_half() -> Vector2:
	return Vector2(float(green.get("green_width")) * 0.5, float(green.get("green_length")) * 0.5)

## Height of the surrounding ground at local (x, z): follows the green's edge, then drops a little and rolls.
func _ground_h(x: float, z: float) -> float:
	var half := _green_half()
	var ex := x / half.x
	var ez := z / half.y
	var r := sqrt(ex * ex + ez * ez) # 1 = green edge (ellipse)
	var cx := x
	var cz := z
	if r > 0.95:
		cx = x * 0.95 / r
		cz = z * 0.95 / r
	var edge_h: float = float(green.call("get_surface_height", cx, cz))
	var out_m := maxf(0.0, (r - 0.95)) * minf(half.x, half.y) # metres outside the green, roughly
	var drop := -0.06 - 0.12 * smoothstep(0.0, 6.0, out_m)
	var roll := (sin(x * 0.07 + 1.3) * cos(z * 0.05 - 0.4) * 0.8 + sin(x * 0.021 - z * 0.017) * 2.2) * smoothstep(4.0, 40.0, out_m)
	return edge_h + drop + roll - 0.015

func _build_ground() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 46
	var segs := 120
	var radii: Array[float] = []
	for i in rings + 1:
		var t := float(i) / float(rings)
		radii.append(pow(t, 2.2) * ground_radius)
	var half := _green_half()
	var verts := []
	for i in rings + 1:
		var row := []
		for j in segs:
			var a := TAU * float(j) / float(segs)
			var x := cos(a) * radii[i]
			var z := sin(a) * radii[i]
			var ex := x / half.x
			var ez := z / half.y
			var out_m := maxf(0.0, sqrt(ex * ex + ez * ez) - 0.95) * minf(half.x, half.y)
			row.append([Vector3(x, _ground_h(x, z), z), out_m])
		verts.append(row)
	for i in rings:
		for j in segs:
			var j2 := (j + 1) % segs
			var q := [verts[i][j], verts[i][j2], verts[i + 1][j2], verts[i + 1][j]]
			for idx in [0, 2, 1, 0, 3, 2]:
				var v = q[idx]
				st.set_color(Color(clampf(float(v[1]) / 10.0, 0.0, 1.0), 0, 0))
				st.add_vertex(v[0])
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "ParklandGround"
	mi.mesh = st.commit()
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	m.render_priority = -100 # transparent (room-edge fade): after the sky dome (-128), before the green (0)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mats.append(m)
	add_child(mi)

func _build_hills() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 160
	var r0 := 170.0
	var r1 := 260.0
	for j in segs:
		var a0 := TAU * float(j) / float(segs)
		var a1 := TAU * float(j + 1) / float(segs)
		var h0 := _hill_h(a0)
		var h1 := _hill_h(a1)
		var p00 := Vector3(cos(a0) * r0, -1.5, sin(a0) * r0)
		var p01 := Vector3(cos(a1) * r0, -1.5, sin(a1) * r0)
		var p10 := Vector3(cos(a0) * r1, h0, sin(a0) * r1)
		var p11 := Vector3(cos(a1) * r1, h1, sin(a1) * r1)
		for v in [p00, p11, p10, p00, p01, p11]:
			st.set_color(Color(1, 0, 0))
			st.add_vertex(v)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "ParklandHills"
	mi.mesh = st.commit()
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	m.set_shader_parameter("is_hills", true)
	m.render_priority = -101 # behind the ground
	m.set_shader_parameter("haze_start", 60.0)
	m.set_shader_parameter("haze_end", 300.0)
	m.set_shader_parameter("haze_max", 0.72)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mats.append(m)
	add_child(mi)

## Hill profile with a bumpy forest silhouette along the ridge.
func _hill_h(a: float) -> float:
	var base := 9.0 + 7.0 * sin(a * 3.0 + 0.7) + 4.0 * sin(a * 7.0 - 1.1)
	var forest := 3.5 * absf(sin(a * 61.0)) + 2.0 * absf(sin(a * 137.0 + 0.4))
	return base + forest

# ------------------------------------------------------------------ trees
func _build_trees() -> void:
	var variants := [_broadleaf_mesh(0), _broadleaf_mesh(1), _broadleaf_mesh(2), _pine_mesh()]
	var placements := []
	for v in variants.size():
		placements.append([])
	var half := _green_half()
	var tries := 0
	while tries < tree_count * 6 and _count(placements) < tree_count:
		tries += 1
		var a := _rng.randf() * TAU
		var r := lerpf(tree_inner_radius, tree_outer_radius, pow(_rng.randf(), 0.8))
		var p := Vector2(cos(a) * r, sin(a) * r)
		# keep clear of the green (ellipse + 9 m) and keep the view down the line from the tee open (local +z side)
		var ex := p.x / (half.x + 9.0)
		var ez := p.y / (half.y + 9.0)
		if ex * ex + ez * ez < 1.0:
			continue
		if p.y > 0.0 and absf(p.x) < half.x + 6.0:
			continue
		var ok := true
		for list in placements:
			for q in list:
				if Vector2(q[0].x, q[0].z).distance_to(p) < 5.5:
					ok = false
					break
		if not ok:
			continue
		var v := 3 if _rng.randf() < 0.28 else _rng.randi_range(0, 2)
		var s := _rng.randf_range(0.8, 1.35)
		placements[v].append([Vector3(p.x, _ground_h(p.x, p.y) - 0.1, p.y), s, _rng.randf() * TAU])
	for v in variants.size():
		if placements[v].is_empty():
			continue
		var mm := MultiMesh.new()
		var set := {"mm": mm, "xf": [], "reach": []}
		_tree_sets.append(set)
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = variants[v]
		mm.instance_count = placements[v].size()
		for i in placements[v].size():
			var pl = placements[v][i]
			var b := Basis(Vector3.UP, pl[2]).scaled(Vector3.ONE * pl[1])
			mm.set_instance_transform(i, Transform3D(b, pl[0]))
			set["xf"].append(Transform3D(b, pl[0]))
			set["reach"].append(8.0 * float(pl[1])) # crown reach from the trunk (m)
			var tint := _rng.randf_range(0.85, 1.12)
			mm.set_instance_color(i, Color(tint, tint * _rng.randf_range(0.95, 1.05), tint))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Trees%d" % v
		mmi.multimesh = mm
		# no shadow casting: 95 trees drawn again into every shadow split was a big share of the frame on Quest,
		# and the sun's shadow range now ends ~10 m out (trees stand 24-75 m away)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := ShaderMaterial.new()
		m.shader = TREE_SHADER
		mmi.material_override = m
		_mats.append(m)
		add_child(mmi)

func _process(_delta: float) -> void:
	if _prewarm or _mats.is_empty() or _tree_sets.is_empty():
		return
	var m: ShaderMaterial = _mats[0]
	var on = m.get_shader_parameter("enable_split_screen")
	var pt = m.get_shader_parameter("split_plane_point")
	var n = m.get_shader_parameter("split_plane_normal")
	var inv = m.get_shader_parameter("invert_split")
	var fade = m.get_shader_parameter("split_fade_angular")
	var key := "%s|%s|%s|%s|%s|%s" % [on, pt, n, inv, fade, global_transform]
	if key != _cull_key:
		_cull_key = key
		_cull_trees(on == true, pt if pt is Vector3 else Vector3.ZERO, n if n is Vector3 else Vector3(0, 0, 1), inv == true,
			float(fade) if fade != null else 0.0)

## fade: the room-edge angle (split_fade_angular). Trees wait until the ground under them is ~60 % faded in, so a
## solid tree never stands in the half-transparent edge. Measured from the split point (fixed), so trees don't pop
## in and out as the head moves.
func _cull_trees(on: bool, pt: Vector3, n: Vector3, inv: bool, fade: float = 0.0) -> void:
	var gt := global_transform
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for set in _tree_sets:
		var mm: MultiMesh = set["mm"]
		for i in mm.instance_count:
			var xf: Transform3D = set["xf"][i]
			var show := true
			if on:
				var wp := gt * xf.origin
				var d := (wp - pt).dot(n)
				if inv:
					d = -d
				show = d < -float(set["reach"][i]) # the whole crown must be on the virtual side
				if show and fade > 0.0:
					show = -d > fade * 0.6 * wp.distance_to(pt)
			mm.set_instance_transform(i, xf if show else Transform3D(Basis().scaled(Vector3.ZERO), xf.origin))

## Startup warm-up (xr_controller._prewarm): draw every tree variant once at a millimetre size, so the shader is
## prepared without anything showing.
func set_prewarm(on: bool) -> void:
	_prewarm = on
	_cull_key = ""
	if on:
		for set in _tree_sets:
			var mm: MultiMesh = set["mm"]
			for i in mm.instance_count:
				var xf: Transform3D = set["xf"][i]
				mm.set_instance_transform(i, Transform3D(xf.basis.scaled(Vector3.ONE * 0.0001), xf.origin))

func _count(placements: Array) -> int:
	var n := 0
	for l in placements:
		n += l.size()
	return n

## Broadleaf tree: tapered trunk + a canopy of 6-9 noisy lumps. Normals point out from the canopy centre so the
## whole crown shades as one soft volume (reads as foliage, not as a pile of balls).
func _broadleaf_mesh(kind: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := RandomNumberGenerator.new()
	r.seed = 100 + kind
	var height: float = [9.0, 11.5, 7.5][kind]
	var crown_r: float = [3.6, 3.2, 4.2][kind]
	var trunk_col := Color(0.16, 0.12, 0.09)
	_add_trunk(st, height * 0.55, 0.22 + 0.05 * kind, trunk_col)
	var centre := Vector3(0, height * 0.62, 0)
	var leaf_dark: Color = [Color(0.035, 0.085, 0.03), Color(0.045, 0.095, 0.03), Color(0.06, 0.09, 0.035)][kind]
	var leaf_light: Color = [Color(0.21, 0.33, 0.09), Color(0.25, 0.35, 0.08), Color(0.28, 0.31, 0.10)][kind]
	var lumps := 6 + kind
	for k in lumps:
		var off: Vector3 = Vector3(r.randf_range(-1, 1), r.randf_range(-0.5, 0.9), r.randf_range(-1, 1)).normalized() * crown_r * r.randf_range(0.35, 0.75)
		if k == 0:
			off = Vector3(0, crown_r * 0.25, 0)
		var lr: float = crown_r * r.randf_range(0.55, 0.8)
		_add_lump(st, centre + off, lr, centre, crown_r, leaf_dark, leaf_light, r)
	return st.commit()

func _pine_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_trunk(st, 3.0, 0.25, Color(0.26, 0.19, 0.14))
	var tiers := 4
	for t in tiers:
		var y0 := 2.0 + t * 2.4
		var rad := 3.0 - t * 0.62
		var hgt := 4.2 - t * 0.5
		_add_cone(st, y0, hgt, rad, Color(0.025, 0.07, 0.04), Color(0.08, 0.16, 0.07))
	return st.commit()

func _add_trunk(st: SurfaceTool, h: float, rad: float, col: Color) -> void:
	var n := 8
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var b0 := Vector3(cos(a0) * rad, 0, sin(a0) * rad)
		var b1 := Vector3(cos(a1) * rad, 0, sin(a1) * rad)
		var t0 := Vector3(cos(a0) * rad * 0.55, h, sin(a0) * rad * 0.55)
		var t1 := Vector3(cos(a1) * rad * 0.55, h, sin(a1) * rad * 0.55)
		for v in [[b0, a0], [t1, a1], [t0, a0], [b0, a0], [b1, a1], [t1, a1]]:
			st.set_color(col)
			st.set_normal(Vector3(cos(v[1]), 0, sin(v[1])))
			st.add_vertex(v[0])

func _add_lump(st: SurfaceTool, c: Vector3, rad: float, crown_c: Vector3, crown_r: float, dark: Color, light: Color, r: RandomNumberGenerator) -> void:
	var rings := 8
	var segs := 12
	var ph := r.randf() * 10.0
	var pts := []
	for i in rings + 1:
		var v := float(i) / rings
		var phi := PI * v
		var row := []
		for j in segs:
			var th := TAU * float(j) / segs
			var dir := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var jitter := 1.0 + 0.09 * sin(th * 3.0 + ph) * sin(phi * 2.0 + ph * 0.7) + 0.05 * sin(th * 7.0 + phi * 5.0 + ph)
			row.append(c + dir * rad * jitter)
		pts.append(row)
	for i in rings:
		for j in segs:
			var j2 := (j + 1) % segs
			var q := [pts[i][j], pts[i][j2], pts[i + 1][j2], pts[i + 1][j]]
			for idx in [0, 1, 2, 0, 2, 3]:
				var p: Vector3 = q[idx]
				var nrm := (p - crown_c).normalized()
				# darker underneath and inside the crown, lighter on top and outside
				var up := clampf((p.y - (crown_c.y - crown_r)) / (2.0 * crown_r), 0.0, 1.0)
				var outer := clampf((p - crown_c).length() / (crown_r * 1.3), 0.0, 1.0)
				var col := dark.lerp(light, clampf(up * 0.65 + outer * 0.45, 0.0, 1.0))
				st.set_color(col)
				st.set_normal(nrm)
				st.add_vertex(p)

func _add_cone(st: SurfaceTool, y0: float, h: float, rad: float, dark: Color, light: Color) -> void:
	var n := 10
	var tip := Vector3(0, y0 + h, 0)
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var b0 := Vector3(cos(a0) * rad, y0, sin(a0) * rad)
		var b1 := Vector3(cos(a1) * rad, y0, sin(a1) * rad)
		var n0 := Vector3(cos(a0), rad / h, sin(a0)).normalized()
		var n1 := Vector3(cos(a1), rad / h, sin(a1)).normalized()
		st.set_color(dark); st.set_normal(n0); st.add_vertex(b0)
		st.set_color(light); st.set_normal((n0 + n1).normalized()); st.add_vertex(tip)
		st.set_color(dark); st.set_normal(n1); st.add_vertex(b1)
		# underside
		st.set_color(dark * 0.6); st.set_normal(Vector3.DOWN); st.add_vertex(b0)
		st.set_color(dark * 0.6); st.set_normal(Vector3.DOWN); st.add_vertex(b1)
		st.set_color(dark * 0.6); st.set_normal(Vector3.DOWN); st.add_vertex(Vector3(0, y0 + 0.3, 0))
