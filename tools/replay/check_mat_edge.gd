extends SceneTree
## Angle test 1, stage 2: unproject the mat's long edges (tools/replay/mat_edge_detect.py)
## onto the floor plane with the SAME camera model + head pose the ball tracker uses,
## and report the mat's world heading vs. the tee's aligned forward direction.
##
## If the camera model were skewed, the measured mat heading would drift with head pose;
## if it is sound, every frame should land on the same heading and the same mat width.
##
##   <godot 4.7.2> --headless --path . --script tools/replay/check_mat_edge.gd -- <rec_dir>

const PROJ_LAG_S := 0.025

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: ... --script tools/replay/check_mat_edge.gd -- <rec_dir>")
		quit(1)
		return
	var dir: String = args[0]
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	var edges = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("mat_edges.json")))
	if edges == null or (edges as Array).is_empty():
		printerr("no mat_edges.json - run tools/replay/mat_edge_detect.py first")
		quit(1)
		return

	var head_t := PackedFloat64Array()
	var head_xf: Array[Transform3D] = []
	var f := FileAccess.open(dir.path_join("events.jsonl"), FileAccess.READ)
	while not f.eof_reached():
		var line := f.get_line()
		if line.find("\"type\":\"head\"") < 0:
			continue
		var e = JSON.parse_string(line)
		if e == null:
			continue
		var p: Array = e["p"]
		var q: Array = e["q"]
		head_t.append(float(e["t_ns"]) / 1e9)
		head_xf.append(Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3])), Vector3(p[0], p[1], p[2])))
	f.close()

	var C = load("res://scripts/xr/xr_controller.gd").new()
	var cam: Dictionary = meta["camera"]
	C.camera_hfov_deg = cam["hfov_deg"]
	C.camera_vfov_deg = cam["vfov_deg"]
	C.camera_optical_tilt_deg = cam["tilt_deg"]
	C.camera_x_offset_m = cam["offset_m"][0]
	C.camera_y_offset_m = cam["offset_m"][1]
	C.camera_z_offset_m = cam["offset_m"][2]
	var tee: Array = meta["tee_box_pos"]
	var mat_y: float = float(tee[1]) # the edge lies on the mat surface, not on the ball's centre plane
	var rot := deg_to_rad(float(meta["tee_box_rotation_deg"]))
	var fwd := Vector2(-sin(rot), -cos(rot)).normalized()

	print("tee forward = (%.4f, %.4f)  heading %+.2f deg   mat plane y = %.4f" % [fwd.x, fwd.y, rad_to_deg(atan2(fwd.x, fwd.y)), mat_y])
	print("frame   head yaw  pitch   roll |  top deg  bot deg   mean | width cm | rms mm")

	var angles := PackedFloat64Array()
	var widths := PackedFloat64Array()
	var yaws := PackedFloat64Array()
	var rows: Array = []
	for rec in edges:
		var cap_s := (float(rec["arrival"]) - float(rec["latency"])) / 1e9 - PROJ_LAG_S
		var xf := _pose_at(head_t, head_xf, cap_s)
		var top := _fit_world(C, rec["top"], xf, mat_y, fwd)
		var bot := _fit_world(C, rec["bottom"], xf, mat_y, fwd)
		if top.is_empty() or bot.is_empty():
			continue
		# perpendicular distance between the two edge lines = mat width (camera-scale check)
		var d: Vector2 = (Vector2(top["dir"][0], top["dir"][1]) + Vector2(bot["dir"][0], bot["dir"][1])).normalized()
		var nrm := Vector2(-d.y, d.x)
		var width: float = absf((Vector2(bot["mid"][0], bot["mid"][1]) - Vector2(top["mid"][0], top["mid"][1])).dot(nrm))
		var mean_ang: float = 0.5 * (float(top["angle"]) + float(bot["angle"]))
		var e := xf.basis.get_euler()
		angles.append(mean_ang)
		widths.append(width)
		yaws.append(rad_to_deg(e.y))
		rows.append({"f": rec["frame"], "yaw": rad_to_deg(e.y), "ang": mean_ang, "w": width})
		print("%5d   %+7.1f %+6.1f %+6.1f | %+7.2f %+7.2f  %+7.2f | %7.1f  | %5.1f" % [
			int(rec["frame"]), rad_to_deg(e.y), rad_to_deg(e.x), rad_to_deg(e.z),
			float(top["angle"]), float(bot["angle"]), mean_ang, width * 100.0,
			(float(top["rms"]) + float(bot["rms"])) * 500.0])

	if angles.is_empty():
		printerr("no frames unprojected")
		quit(1)
		return
	print("\n--- mat edge vs tee forward (positive = mat points right of the aimed line) ---")
	_stats("angle offset  ", angles, "deg")
	_stats("measured width", widths, "m")
	# does the measured angle track head yaw? (it must not, if the camera model is sound)
	var cov := 0.0
	var vy := 0.0
	var my := _mean(yaws)
	var ma := _mean(angles)
	for i in range(angles.size()):
		cov += (yaws[i] - my) * (angles[i] - ma)
		vy += (yaws[i] - my) * (yaws[i] - my)
	if vy > 1e-6:
		print("angle vs head yaw slope: %+.4f deg per deg of yaw (over %.0f deg of yaw range)" % [cov / vy, _span(yaws)])
	C.free()
	quit()

func _fit_world(C, pts: Array, xf: Transform3D, plane_y: float, fwd: Vector2) -> Dictionary:
	var w := PackedVector2Array()
	for p in pts:
		var p3: Vector3 = C._norm_cam_to_floor(Vector2(float(p[0]), float(p[1])), xf, plane_y)
		if is_nan(p3.x):
			continue
		w.append(Vector2(p3.x, p3.z))
	if w.size() < 8:
		return {}
	# PCA direction of the world-space points
	var c := Vector2.ZERO
	for v in w:
		c += v
	c /= float(w.size())
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	for v in w:
		var d := v - c
		sxx += d.x * d.x
		sxy += d.x * d.y
		syy += d.y * d.y
	var theta := 0.5 * atan2(2.0 * sxy, sxx - syy)
	var dir := Vector2(cos(theta), sin(theta))
	if dir.dot(fwd) < 0.0:
		dir = -dir
	var nrm := Vector2(-dir.y, dir.x)
	var ss := 0.0
	for v in w:
		var r := (v - c).dot(nrm)
		ss += r * r
	var rms: float = sqrt(ss / float(w.size()))
	var ang := rad_to_deg(atan2(fwd.x * dir.y - fwd.y * dir.x, fwd.dot(dir)))
	return {"dir": [dir.x, dir.y], "mid": [c.x, c.y], "rms": rms, "angle": ang}

func _mean(a: PackedFloat64Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / float(a.size())

func _span(a: PackedFloat64Array) -> float:
	var lo := a[0]
	var hi := a[0]
	for v in a:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo

func _stats(label: String, a: PackedFloat64Array, unit: String) -> void:
	var m := _mean(a)
	var s := 0.0
	for v in a:
		s += (v - m) * (v - m)
	var sd: float = sqrt(s / float(a.size()))
	var sorted := Array(a)
	sorted.sort()
	print("%s: mean %+8.3f %s   sd %6.3f   median %+8.3f   min %+8.3f   max %+8.3f   n=%d" % [
		label, m, unit, sd, sorted[sorted.size() / 2], sorted[0], sorted[sorted.size() - 1], a.size()])

func _pose_at(ts: PackedFloat64Array, xfs: Array[Transform3D], t: float) -> Transform3D:
	if t <= ts[0]:
		return xfs[0]
	for i in range(1, ts.size()):
		if ts[i] >= t:
			var span := ts[i] - ts[i - 1]
			var w := (t - ts[i - 1]) / span if span > 1e-9 else 0.0
			return xfs[i - 1].interpolate_with(xfs[i], w)
	return xfs[xfs.size() - 1]
