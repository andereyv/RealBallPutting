extends SceneTree
## Speed stage of the replay: runs the tracker output (replay_putts.jsonl) through the SAME code the game uses:
## xr_controller._norm_cam_to_floor (image -> floor, with the head pose at each frame) and PuttSpeedEstimator.
##
## Usage (from the project folder):
##   <godot 4.7.2> --headless --path . --script tools/replay/replay_speed.gd -- <rec_dir>

const PuttSpeedEstimator = preload("res://scripts/physics/putt_speed_estimator.gd")
const PROJ_LAG_S := 0.025 # head pose lags the camera image by ~25 ms (measured, see PuttTracker.PROJ_LAG_NS)

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: ... --script tools/replay/replay_speed.gd -- <rec_dir>")
		quit(1)
		return
	var dir: String = args[0]
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("meta.json")))
	# head poses
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
	if head_t.size() < 2:
		printerr("no head poses in recording")
		quit(1)
		return

	var C = load("res://scripts/xr/xr_controller.gd").new()
	var cam: Dictionary = meta["camera"]
	C.camera_hfov_deg = cam["hfov_deg"]
	C.camera_vfov_deg = cam["vfov_deg"]
	C.camera_optical_tilt_deg = cam["tilt_deg"]
	C.camera_x_offset_m = cam["offset_m"][0]
	C.camera_y_offset_m = cam["offset_m"][1]
	C.camera_z_offset_m = cam["offset_m"][2]
	var tee: Array = meta["tee_box_pos"]
	var floor_y: float = float(tee[1]) if bool(meta.get("enable_tee_box", true)) else 0.002
	var plane_y := floor_y + 0.02135
	var rot := deg_to_rad(float(meta["tee_box_rotation_deg"]))
	var fwd := Vector2(-sin(rot), -cos(rot)).normalized()
	var stimp := float(meta.get("physical_mat_stimp", 12.7))
	var decel := 0.56 * 9.81 / maxf(stimp, 6.0)

	print("putt  time     gate m/s  v2 m/s  angle   n(used)  rms mm  range cm   status")
	var pf := FileAccess.open(dir.path_join("replay_putts.jsonl"), FileAccess.READ)
	if pf == null:
		printerr("run ReplayRunner first (replay_putts.jsonl missing)")
		quit(1)
		return
	var out := FileAccess.open(dir.path_join("replay_speed.jsonl"), FileAccess.WRITE)
	while not pf.eof_reached():
		var line := pf.get_line()
		if line.strip_edges() == "":
			continue
		var putt: Dictionary = JSON.parse_string(line)
		var times := PackedFloat64Array()
		var pts := PackedVector2Array()
		for smp in putt["samples"]:
			var cap_s := float(smp[1]) / 1e9 - PROJ_LAG_S
			var xf := _pose_at(head_t, head_xf, cap_s)
			var p3: Vector3 = C._norm_cam_to_floor(Vector2(smp[2], smp[3]), xf, plane_y)
			if is_nan(p3.x):
				continue
			times.append(float(smp[0]))
			pts.append(Vector2(p3.x, p3.z))
		var far := Vector2(1e6, 1e6) # no address position in replay -> estimator uses first sample
		var r: Dictionary = PuttSpeedEstimator.estimate(times, pts, far, decel, 0.06, fwd)
		print("%3d  %6.2fs   %5.2f     %5.2f  %+5.1f°  %2d(%2d)   %5.1f   %3.0f-%3.0f   %s" % [
			int(putt["putt"]), float(putt["t_s"]), float(putt["gate_speed"]), float(r.get("speed", 0.0)),
			float(r.get("angle_deg", 0.0)), int(r.get("n", 0)), int(r.get("used", 0)), float(r.get("rms_m", 0.0)) * 1000.0,
			float(r.get("first_dist", 0.0)) * 100.0, float(r.get("last_dist", 0.0)) * 100.0,
			"OK" if r.get("valid", false) else "REJECTED: " + str(r.get("reason", ""))])
		var roll := 0.0
		if r.get("valid", false):
			roll = float(r["speed"]) * float(r["speed"]) / (2.0 * decel) + 0.06
		out.store_line(JSON.stringify({"putt": putt["putt"], "t_s": putt["t_s"], "v2_speed": r.get("speed", 0.0), "valid": r.get("valid", false),
			"reason": r.get("reason", ""), "rms_mm": float(r.get("rms_m", 0.0)) * 1000.0, "predicted_roll_on_mat_m": roll,
			"direction": [float(r.get("direction", Vector2.ZERO).x), float(r.get("direction", Vector2.ZERO).y)],
			"times": Array(times), "floor_xz": Array(pts).map(func(v): return [v.x, v.y])}))
		if r.get("valid", false):
			print("      -> predicted roll on the mat (Stimp %.1f): %.2f m" % [stimp, roll])
	out.close()
	C.free()
	quit()

func _pose_at(ts: PackedFloat64Array, xfs: Array[Transform3D], t: float) -> Transform3D:
	if t <= ts[0]:
		return xfs[0]
	for i in range(1, ts.size()):
		if ts[i] >= t:
			var span := ts[i] - ts[i - 1]
			var w := (t - ts[i - 1]) / span if span > 1e-9 else 0.0
			return xfs[i - 1].interpolate_with(xfs[i], w)
	return xfs[xfs.size() - 1]
