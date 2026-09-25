extends SceneTree
## Redraw what the headset showed of the virtual course, from a session recording (2026-09-24).
##
##   godot --path . --rendering-driver opengl3 -s tools/replay/replay_view.gd -- <rec_dir> <out_dir> [fps=15] [t0=0] [t1=end] [pin=2.4] [eye|cam]
##
## Views: "eye" (default) = from the head, wide, like the headset; "cam" = from the headset's tracking camera (its
## offset, 11 deg tilt and 72.5 x 57.7 deg field of view from meta.json), 640 x 480 with a transparent background, so
## replay_video.py can lay it over the camera image: the floor grid must then lie on the real floor and the ring on
## the real ball spot. If they drift apart when the head moves, the app's floor height and the real floor differ.
##
## Uses the recording's head poses (type=head) and the SCENE / SPLIT events (where the green, cup and ball were, and
## where the real room ends and the green starts). Writes out_dir/v_00000.png ... and out_dir/frames.csv (time of each
## image), which tools/replay/replay_video.py puts next to the headset camera images.
##
## World-fixed references are added on top: a 25 cm grid on the real floor (y = 0) and a ring on the ball spot. If the
## green slides against the grid in the video, the app moved the green; if it stays put, the app didn't.
## Recordings made before SCENE logging: the practice layout is rebuilt from meta.json (tee) and pin=.

var rec := ""
var out := ""
var fps := 15.0
var t_from := 0.0
var t_to := 1e9
var pin := 2.4
var view_mode := "eye"

var heads: Array = []   # [t, pos, quat]
var scenes: Array = []  # [t, info]
var splits: Array = []  # [t, info]
var meta := {}
var t0_ns := 0

var xr
var tgc
var cam: Camera3D
var hud: Label

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 2:
		print("usage: -- <rec_dir> <out_dir> [fps] [t0] [t1] [pin]")
		quit(1)
		return
	rec = a[0]
	out = a[1]
	if a.size() > 2: fps = float(a[2])
	if a.size() > 3: t_from = float(a[3])
	if a.size() > 4: t_to = float(a[4])
	if a.size() > 5: pin = float(a[5])
	if a.size() > 6: view_mode = a[6]
	DirAccess.make_dir_recursive_absolute(out)
	_load()
	_run.call_deferred()

func _load() -> void:
	var mf := FileAccess.open(rec.path_join("meta.json"), FileAccess.READ)
	if mf != null:
		meta = JSON.parse_string(mf.get_as_text())
	var f := FileAccess.open(rec.path_join("events.jsonl"), FileAccess.READ)
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var e = JSON.parse_string(line)
		if typeof(e) != TYPE_DICTIONARY or not e.has("t_ns"):
			continue
		var tn := int(e["t_ns"])
		if t0_ns == 0:
			t0_ns = tn
		var t := float(tn - t0_ns) / 1e9
		match str(e.get("type", "")):
			"head":
				var p: Array = e["p"]
				var q: Array = e["q"]
				heads.append([t, Vector3(p[0], p[1], p[2]), Quaternion(q[0], q[1], q[2], q[3])])
			"game":
				var txt := str(e.get("text", ""))
				if txt.begins_with("SCENE "):
					scenes.append([t, JSON.parse_string(txt.substr(6))])
				elif txt.begins_with("SPLIT "):
					splits.append([t, JSON.parse_string(txt.substr(6))])
	print("heads %d, scene events %d, split events %d" % [heads.size(), scenes.size(), splits.size()])

func _find_xr(n):
	if n is XRController:
		return n
	for c in n.get_children():
		var r = _find_xr(c)
		if r != null:
			return r
	return null

func _run() -> void:
	var scn = load("res://scenes/environment/test_green.tscn").instantiate()
	xr = _find_xr(scn)
	if xr != null:
		xr.process_mode = Node.PROCESS_MODE_DISABLED # we drive the scene ourselves
	root.add_child(scn)
	current_scene = scn
	await create_timer(0.8).timeout
	for n in root.find_children("*", "CanvasLayer", true, false):
		n.visible = false
	tgc = xr.test_green_controller
	var gm = tgc.get_node_or_null("GameMenu")
	if gm != null:
		gm.visible = false
	if xr._flow != null:
		xr._flow.menu.hide_menu()
	xr.is_passthrough_active = true
	xr._apply_environment_transparency(true)
	if view_mode == "cam":
		root.transparent_bg = true
		RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
		root.get_window().size = Vector2i(640, 480)
	else:
		RenderingServer.set_default_clear_color(Color(0.16, 0.16, 0.17, 1)) # the real room (passthrough) side
	xr._collect_split_materials()
	if xr.get("_tee_box_marker") != null:
		xr._tee_box_marker.visible = false
	_add_references()
	cam = Camera3D.new()
	cam.fov = 88.0
	if view_mode == "cam":
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.fov = float(meta.get("camera", {}).get("vfov_deg", 57.66))
	cam.near = 0.03
	cam.far = 1000.0
	root.add_child(cam)
	cam.current = true
	var layer := CanvasLayer.new()
	root.add_child(layer)
	hud = Label.new()
	hud.position = Vector2(12, 8)
	hud.add_theme_font_size_override("font_size", 18)
	hud.add_theme_color_override("font_color", Color(1, 1, 0.6))
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 5)
	layer.add_child(hud)
	hud.visible = view_mode != "cam"

	var t_end: float = minf(t_to, heads[-1][0]) if heads.size() > 0 else 0.0
	var csv := FileAccess.open(out.path_join("frames.csv"), FileAccess.WRITE)
	csv.store_line("index,t_s,t_ns")
	var i := 0
	var t := t_from
	var cur_scene := -2
	var cur_split := -2
	while t <= t_end:
		var si := _last_before(scenes, t)
		if si != cur_scene:
			cur_scene = si
			_apply_scene(scenes[si][1] if si >= 0 else {})
		var pi := _last_before(splits, t)
		if pi != cur_split:
			cur_split = pi
			_apply_split(splits[pi][1] if pi >= 0 else {})
		var pose := _head_at(t)
		var hb := Basis(pose[1])
		if view_mode == "cam":
			# same model as xr_controller.is_tee_in_camera_view(): lens offset in head space, optical axis tilted down
			var c: Dictionary = meta.get("camera", {})
			var off: Array = c.get("offset_m", [-0.0322, -0.0179, -0.0627])
			cam.global_transform = Transform3D(hb * Basis(Vector3.RIGHT, deg_to_rad(-float(c.get("tilt_deg", 11.12)))),
				pose[0] + hb * Vector3(off[0], off[1], off[2]))
		else:
			cam.global_transform = Transform3D(hb, pose[0])
		var g: Node3D = tgc.green_generator
		hud.text = "t %.2f s   head (%.2f, %.2f, %.2f)\ngreen (%.3f, %.3f, %.3f) yaw %.2f°  %s" % [t, pose[0].x, pose[0].y, pose[0].z,
			g.global_position.x, g.global_position.y, g.global_position.z, rad_to_deg(g.global_transform.basis.get_euler().y),
			"" if si >= 0 else "(no SCENE yet: practice layout from meta.json)"]
		await process_frame
		await process_frame
		root.get_viewport().get_texture().get_image().save_png(out.path_join("v_%05d.png" % i))
		csv.store_line("%d,%.4f,%d" % [i, t, t0_ns + int(t * 1e9)])
		i += 1
		t += 1.0 / fps
	print("wrote %d frames to %s" % [i, out])
	quit()

func _last_before(arr: Array, t: float) -> int:
	var best := -1
	for k in arr.size():
		if arr[k][0] <= t:
			best = k
		else:
			break
	return best

func _head_at(t: float) -> Array:
	if heads.is_empty():
		return [Vector3(0, 1.6, 0), Quaternion.IDENTITY]
	var lo := 0
	var hi := heads.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if heads[mid][0] <= t:
			lo = mid
		else:
			hi = mid
	var a: Array = heads[lo]
	var b: Array = heads[hi]
	var k := 0.0 if b[0] <= a[0] else clampf((t - a[0]) / (b[0] - a[0]), 0.0, 1.0)
	return [a[1].lerp(b[1], k), (a[2] as Quaternion).slerp(b[2], k)]

func _apply_scene(info: Dictionary) -> void:
	var cm = xr._get_course_manager()
	if info.is_empty():
		# no SCENE events (older recording): practice layout on the saved tee
		var tp: Array = meta.get("tee_box_pos", [0.0, 0.002, 1.2])
		tgc.pin_distance_m = pin
		tgc.set_course_visible(true)
		tgc.align_to_tee_box(Vector3(tp[0], tp[1], tp[2]), float(meta.get("tee_box_rotation_deg", 0.0)))
		return
	var want := str(info.get("green", ""))
	if cm != null and want != "" and cm.get_current_profile().id != want:
		var profs: Array = cm.get_available_profiles()
		for k in profs.size():
			if profs[k].id == want:
				cm.load_green_by_index(k)
	var gg = tgc.green_generator
	var cup: Array = info.get("cup", [0, 0])
	gg.set_cup_fast(Vector2(cup[0], cup[1]))
	var o: Array = info["o"]
	var b := Basis.from_euler(Vector3(deg_to_rad(float(info.get("pitch", 0))), deg_to_rad(float(info["yaw"])), deg_to_rad(float(info.get("roll", 0)))))
	tgc._apply_green_transform(Transform3D(b, Vector3(o[0], o[1], o[2])))
	var vis := bool(info.get("vis", true))
	gg.visible = vis
	if tgc.flag_assembly != null:
		tgc.flag_assembly.visible = vis
	if tgc.parkland != null:
		tgc.parkland.visible = bool(info.get("scenery", true))
	var sky: Node3D = root.find_child("SkyDome", true, false)
	if sky != null:
		sky.visible = vis and bool(info.get("scenery", true))

func _apply_split(info: Dictionary) -> void:
	if info.is_empty():
		# older recording: the split the app would have used (across the aimed line, world_split_offset_z past the ball)
		var tp: Array = meta.get("tee_box_pos", [0.0, 0.002, 1.2])
		xr.tee_box_pos = Vector3(tp[0], tp[1], tp[2])
		xr.tee_box_rotation_deg = float(meta.get("tee_box_rotation_deg", 0.0))
		xr.current_mode = xr.SplitMode.SPLIT_SCREEN
		xr._apply_active_plane()
		return
	var p: Array = info["p"]
	var n: Array = info["n"]
	xr._update_material_uniforms(bool(info["on"]), Vector3(p[0], p[1], p[2]), Vector3(n[0], n[1], n[2]), 0.0, bool(info.get("inv", false)))

## World-fixed: 25 cm grid on the real floor around the ball spot, a ring on the ball spot
func _add_references() -> void:
	var tp: Array = meta.get("tee_box_pos", [0.0, 0.002, 1.2])
	var c := Vector3(tp[0], 0.0, tp[2])
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.2, 0.55)
	mat.no_depth_test = true
	mat.render_priority = 100
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var r := 2.0
	var step := 0.25
	var k := -r
	while k <= r + 0.001:
		im.surface_add_vertex(c + Vector3(k, 0.001, -r))
		im.surface_add_vertex(c + Vector3(k, 0.001, r))
		im.surface_add_vertex(c + Vector3(-r, 0.001, k))
		im.surface_add_vertex(c + Vector3(r, 0.001, k))
		k += step
	for s in 48:
		var a0 := TAU * s / 48.0
		var a1 := TAU * (s + 1) / 48.0
		for rad in [0.03, 0.045]:
			im.surface_add_vertex(c + Vector3(cos(a0) * rad, 0.002, sin(a0) * rad))
			im.surface_add_vertex(c + Vector3(cos(a1) * rad, 0.002, sin(a1) * rad))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	root.add_child(mi)
