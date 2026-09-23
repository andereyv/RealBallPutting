extends RefCounted
## Speed v2 — metric putt speed estimator.
##
## Works on ball positions that have already been converted to real floor coordinates
## (metres, XZ plane), so camera perspective and head motion are no longer part of the problem.
##
## Model: the ball rolls in a straight line with constant rolling deceleration `decel`:
##     s(t) = s0 + v0*t - 0.5*decel*t^2
## Right after impact the ball SKIDS (slows much faster than rolling). What decides how far it goes is the
## speed once it rolls, so when the track is long enough we fit only the later, rolling part (s >= LATE_MIN_DIST)
## with the known rolling deceleration, and extrapolate back to ref_dist as an EQUIVALENT rolling speed:
## a purely rolling virtual ball launched with it stops where the real ball stops.
##
## Pure function, no scene access -> easy to test and to mirror in an offline replay tool.

const MIN_SAMPLES := 3
const MAX_RMS_M := 0.010        # reject fits with >1 cm residual RMS
const MIN_SPAN_S := 0.025       # need at least ~2 frame intervals
const MIN_TRAVEL_M := 0.10      # a putt is tracked over >= 18 cm; 3 points over 4 cm was a toe nudging the ball (2026-09-22)
const MAX_ANGLE_DEG := 25.0     # real putts start within a few degrees of the line; 46 deg was that same toe nudge
const OUTLIER_FLOOR_M := 0.004  # never reject residuals under 4 mm
const LATE_MIN_DIST := 0.12     # fit only samples beyond 12 cm (past the skid) when enough exist
const LATE_MIN_SAMPLES := 4
const MAX_DECEL := 6.0          # m/s^2 (only used if free-deceleration fitting is enabled)
const USE_FREE_DECEL := false
## The rolling deceleration is also fitted from the samples, pulled towards `decel` (the mat's) by a prior.
## Short tracks (< ~0.2 s) stay at the mat value; long tracks on a faster surface (wood floor: ~0.1 m/s^2
## vs 0.43 on the mat) follow the data. Without this, floor putts came out 5-12 % fast (2026-09-22).
## Weight 3e-4: mat putts change by <= 0.02 m/s (one by 0.05), floor putts match frame-by-frame truth.
const FIT_DECEL_WITH_PRIOR := true
const DECEL_PRIOR_WEIGHT := 0.0003
const DECEL_MIN := 0.05
const DECEL_MAX := 1.2

## times:      sample times in seconds (relative, from camera sensor timestamps)
## pts:        floor positions (x, z) in metres
## start_pos:  ball position at address (x, z); distances are measured from here
## decel:      rolling deceleration of the PHYSICAL mat (m/s^2)
## ref_dist:   distance from start_pos at which the returned speed is evaluated
##             (= where the virtual ball is spawned)
## forward:    intended putting direction (for the angle)
static func estimate(times: PackedFloat64Array, pts: PackedVector2Array, start_pos: Vector2,
		decel: float, ref_dist: float, forward: Vector2) -> Dictionary:
	var n := pts.size()
	var res := {"valid": false, "n": n, "used": 0, "reason": ""}
	if n < MIN_SAMPLES or times.size() != n:
		res.reason = "too few samples (%d)" % n
		return res

	# 1. Direction of travel = principal axis of the points (least-squares line), oriented first->last
	var mean := Vector2.ZERO
	for p in pts:
		mean += p
	mean /= float(n)
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	for p in pts:
		var d := p - mean
		sxx += d.x * d.x
		sxy += d.x * d.y
		syy += d.y * d.y
	var theta := 0.5 * atan2(2.0 * sxy, sxx - syy)
	var dir := Vector2(cos(theta), sin(theta))
	if dir.dot(pts[n - 1] - pts[0]) < 0.0:
		dir = -dir
	var lateral := Vector2(-dir.y, dir.x)

	# The address position comes from a different detector (YOLO) and was seen 20-25 cm off the tracked samples.
	# The tracker fires at ~1-2 cm of movement, so if start_pos is far off, place it just behind the first sample.
	if start_pos.distance_to(pts[0]) > 0.06:
		start_pos = pts[0] - dir * 0.015

	# 2. Along-track distance from address, corrected for known deceleration
	var s := PackedFloat64Array()
	var lat_sq := 0.0
	for i in n:
		var si := (pts[i] - start_pos).dot(dir)
		s.append(si)
		var li := (pts[i] - mean).dot(lateral)
		lat_sq += li * li

	# 3. Fit s(t) = s0 + v0*t - 0.5*a*t^2 (a free if enough data, else a = decel), one robust outlier pass
	var mask := []
	mask.resize(n)
	mask.fill(true)
	var late_count := 0
	for i in n:
		if s[i] >= LATE_MIN_DIST:
			late_count += 1
	var late_only := late_count >= LATE_MIN_SAMPLES
	if late_only:
		for i in n:
			mask[i] = s[i] >= LATE_MIN_DIST
	res.late_only = late_only
	var free_decel := USE_FREE_DECEL
	var fit := _fit(times, s, mask, decel, free_decel)
	if not fit.ok:
		res.reason = "degenerate fit"
		return res
	for _pass in 2:
		if n >= 5:
			var abs_res := []
			var in_res := []
			for i in n:
				var rr := absf(s[i] - _eval(fit, times[i]))
				abs_res.append(rr)
				if mask[i]:
					in_res.append(rr)
			in_res.sort()
			var mad: float = in_res[int(in_res.size() / 2.0)]
			var thresh := maxf(3.0 * 1.4826 * mad, OUTLIER_FLOOR_M)
			var kept := 0
			var before := 0
			var prev_mask := mask.duplicate()
			for i in n:
				if mask[i]:
					before += 1
				mask[i] = mask[i] and abs_res[i] <= thresh
				if mask[i]:
					kept += 1
			if kept == before and before >= 5:
				# Nothing beyond the MAD threshold, but one gross outlier can drag the fit enough to hide itself:
				# if the worst point is far off, drop it.
				var worst := -1
				var worst_r := 0.0
				for i in n:
					if mask[i] and abs_res[i] > worst_r:
						worst_r = abs_res[i]
						worst = i
				if worst >= 0 and worst_r > MAX_RMS_M:
					mask[worst] = false
					kept -= 1
			if kept < MIN_SAMPLES:
				mask = prev_mask
			elif kept < before:
				fit = _fit(times, s, mask, decel, free_decel)
				if not fit.ok:
					res.reason = "degenerate fit after outlier rejection"
					return res

	var s0: float = fit.a
	var v0: float = fit.b
	var acc: float = fit.acc
	var used := 0
	var t_sum := 0.0
	var rss := 0.0
	var t_min := INF
	var t_max := -INF
	for i in n:
		if not mask[i]:
			continue
		used += 1
		t_sum += times[i]
		t_min = minf(t_min, times[i])
		t_max = maxf(t_max, times[i])
		var r := s[i] - _eval(fit, times[i])
		rss += r * r
	var rms := sqrt(rss / float(used))
	var t_c := t_sum / float(used)

	# 4. Speed at the reference distance: evaluate at the centroid time (best-determined point
	#    of the fit) and move along the rolling model to ref_dist.
	var v_c := v0 - acc * t_c
	var s_c := s0 + v0 * t_c - 0.5 * acc * t_c * t_c
	var v_ref := sqrt(maxf(0.0, v_c * v_c + 2.0 * acc * (s_c - ref_dist)))

	res.used = used
	res.speed = v_ref
	res.speed_at_centroid = v_c
	res.decel_fit = acc
	res.decel_free = bool(fit.free)
	res.dist_at_centroid = s_c
	res.direction = dir
	res.angle_deg = rad_to_deg(forward.angle_to(dir))
	res.rms_m = rms
	res.lateral_rms_m = sqrt(lat_sq / float(n))
	res.span_s = t_max - t_min
	res.first_dist = s[0]
	res.last_dist = s[n - 1]

	if res.span_s < MIN_SPAN_S:
		res.reason = "time span too short (%.3fs)" % res.span_s
	elif res.last_dist - res.first_dist < MIN_TRAVEL_M:
		res.reason = "ball moved only %.0f cm" % ((res.last_dist - res.first_dist) * 100.0)
	elif absf(res.angle_deg) > MAX_ANGLE_DEG:
		res.reason = "start line %.0f deg off (not a putt)" % res.angle_deg
	elif rms > MAX_RMS_M:
		res.reason = "fit residual too high (%.1f mm)" % (rms * 1000.0)
	elif v_ref < 0.2 or v_ref > 6.0:
		res.reason = "speed out of range (%.2f m/s)" % v_ref
	else:
		res.valid = true
	return res


static func _eval(fit: Dictionary, t: float) -> float:
	return fit.a + fit.b * t - 0.5 * fit.acc * t * t


## Least squares for s = a + b*t - 0.5*acc*t^2. If free, acc is fitted (clamped to [0, MAX_DECEL]);
## otherwise acc = fixed_decel and only a, b are fitted.
static func _fit(t: PackedFloat64Array, s: PackedFloat64Array, mask: Array, fixed_decel: float, free: bool) -> Dictionary:
	if not free and FIT_DECEL_WITH_PRIOR:
		var pm := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
		var pr := [0.0, 0.0, 0.0]
		var pc := 0
		for i in t.size():
			if not mask[i]:
				continue
			pc += 1
			var pb := [1.0, t[i], -0.5 * t[i] * t[i]]
			for j in 3:
				pr[j] += pb[j] * s[i]
				for k in 3:
					pm[j][k] += pb[j] * pb[k]
		if pc >= 3:
			# prior row: sqrt(w) * acc = sqrt(w) * fixed_decel
			pm[2][2] += DECEL_PRIOR_WEIGHT
			pr[2] += DECEL_PRIOR_WEIGHT * fixed_decel
			var psol := _solve3(pm, pr)
			if psol.size() == 3:
				var acc_p := clampf(float(psol[2]), DECEL_MIN, DECEL_MAX)
				var lfp := _line_fit_fixed(t, s, mask, acc_p)
				lfp["free"] = true
				return lfp
	if free:
		# normal equations for basis [1, t, q] with q = -0.5 t^2
		var m := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
		var r := [0.0, 0.0, 0.0]
		var cnt := 0
		for i in t.size():
			if not mask[i]:
				continue
			cnt += 1
			var bvec := [1.0, t[i], -0.5 * t[i] * t[i]]
			for j in 3:
				r[j] += bvec[j] * s[i]
				for k in 3:
					m[j][k] += bvec[j] * bvec[k]
		if cnt >= 3:
			var sol := _solve3(m, r)
			if sol.size() == 3 and sol[2] >= 0.0 and sol[2] <= MAX_DECEL:
				return {"ok": true, "a": sol[0], "b": sol[1], "acc": sol[2], "free": true}
			# implausible curvature -> fall back to fixed rolling deceleration
	var lf := _line_fit_fixed(t, s, mask, fixed_decel)
	lf["free"] = false
	return lf


static func _line_fit_fixed(t: PackedFloat64Array, s: PackedFloat64Array, mask: Array, decel: float) -> Dictionary:
	var n := 0.0
	var st := 0.0
	var sy := 0.0
	var stt := 0.0
	var sty := 0.0
	for i in t.size():
		if not mask[i]:
			continue
		var y := s[i] + 0.5 * decel * t[i] * t[i]
		n += 1.0
		st += t[i]
		sy += y
		stt += t[i] * t[i]
		sty += t[i] * y
	var den := n * stt - st * st
	if n < 2.0 or absf(den) < 1e-12:
		return {"ok": false}
	var b := (n * sty - st * sy) / den
	var a := (sy - b * st) / n
	return {"ok": true, "a": a, "b": b, "acc": decel}


static func _solve3(m: Array, r: Array) -> Array:
	var det := _det3(m)
	if absf(det) < 1e-14:
		return []
	var out := []
	for c in 3:
		var mc := [m[0].duplicate(), m[1].duplicate(), m[2].duplicate()]
		for row in 3:
			mc[row][c] = r[row]
		out.append(_det3(mc) / det)
	return out


static func _det3(m: Array) -> float:
	return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) \
		- m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) \
		+ m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
