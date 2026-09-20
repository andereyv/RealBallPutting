#!/usr/bin/env python3
"""Angle test 1, stage 2 (python port of tools/replay/check_mat_edge.gd, so it can run
without a Godot install): unproject the mat edge samples from mat_edge_detect.py onto the
floor plane with the head pose at each frame, and report the mat's world heading relative
to the tee's aimed forward direction.

The unprojection mirrors xr_controller._norm_cam_to_floor (and _norm_cam_to_floor_intr)
line for line, so any bias it shows is a bias the live ball tracker has too.

  python3 tools/replay/mat_edge_world.py <rec_dir> [--intr] [--lens-quat] [--lag 0.025]
"""
import json, math, os, sys

import numpy as np

PROJ_LAG_S = 0.025


def quat_to_mat(q):
    """Godot Quaternion(x, y, z, w) -> 3x3 rotation matrix."""
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def slerp(q0, q1, t):
    q0 = np.asarray(q0, float)
    q1 = np.asarray(q1, float)
    d = float(np.dot(q0, q1))
    if d < 0:
        q1, d = -q1, -d
    if d > 0.9995:
        q = q0 + t * (q1 - q0)
    else:
        th = math.acos(max(-1.0, min(1.0, d)))
        s = math.sin(th)
        q = (math.sin((1 - t) * th) / s) * q0 + (math.sin(t * th) / s) * q1
    return q / (np.linalg.norm(q) or 1.0)


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def load_heads(path):
    ts, qs, ps = [], [], []
    with open(path) as f:
        for line in f:
            if '"type":"head"' not in line:
                continue
            e = json.loads(line)
            ts.append(e["t_ns"] / 1e9)
            qs.append(e["q"])
            ps.append(e["p"])
    return np.array(ts), np.array(qs, float), np.array(ps, float)


def pose_at(ts, qs, ps, t):
    i = int(np.searchsorted(ts, t))
    if i <= 0:
        return quat_to_mat(qs[0]), ps[0]
    if i >= ts.size:
        return quat_to_mat(qs[-1]), ps[-1]
    span = ts[i] - ts[i - 1]
    w = (t - ts[i - 1]) / span if span > 1e-9 else 0.0
    return quat_to_mat(slerp(qs[i - 1], qs[i], w)), ps[i - 1] + (ps[i] - ps[i - 1]) * w


def yaw_pitch_roll(R):
    """Godot Basis.get_euler() default order YXZ."""
    sx = -R[1, 2]
    sx = max(-1.0, min(1.0, sx))
    x = math.asin(sx)
    if abs(sx) < 0.9999:
        y = math.atan2(R[0, 2], R[2, 2])
        z = math.atan2(R[1, 0], R[1, 1])
    else:
        y = math.atan2(-R[2, 0], R[0, 0])
        z = 0.0
    return math.degrees(y), math.degrees(x), math.degrees(z)


def make_unproject(meta, use_intr, use_lens_quat):
    cam = meta["camera"]
    off = np.array(cam["offset_m"], float)
    tilt = math.radians(cam["tilt_deg"])
    cal = meta.get("cam_calib") or []
    if use_lens_quat and len(cal) >= 16:
        # full LENS_POSE_ROTATION instead of "180 deg flip about X + tilt about X"
        q = [cal[12], cal[13], cal[14], cal[15]]
        Rl = quat_to_mat(q)
        flip = np.diag([1.0, -1.0, -1.0])  # camera (x right, y down, z fwd) -> Godot (x right, y up, z back)
        cam_rel = Rl @ flip
    else:
        cam_rel = rot_x(-tilt)
    if use_intr:
        aw, ah, sw, sh = cal[5], cal[6], cal[7], cal[8]
        sc = max(sw / aw, sh / ah)
        fx, fy = cal[1] * sc, cal[2] * sc
        cx = cal[3] * sc - (aw * sc - sw) * 0.5
        cy = cal[4] * sc - (ah * sc - sh) * 0.5

        def ray(u, v):
            return np.array([(u * sw - cx) / fx, -(v * sh - cy) / fy, -1.0])
    else:
        th = math.tan(math.radians(cam["hfov_deg"] * 0.5))
        tv = math.tan(math.radians(cam["vfov_deg"] * 0.5))

        def ray(u, v):
            return np.array([(u - 0.5) * 2.0 * th, -(v - 0.5) * 2.0 * tv, -1.0])

    def unproject(uv, R, p, plane_y):
        origin = p + R @ off
        B = R @ cam_rel
        out = []
        for u, v in uv:
            d = B @ ray(u, v)
            if d[1] > -1e-4:
                continue
            k = (plane_y - origin[1]) / d[1]
            w = origin + d * k
            out.append((w[0], w[2]))
        return np.array(out)

    return unproject


def fit_dir(pts, fwd):
    c = pts.mean(0)
    d = pts - c
    sxx = float((d[:, 0] ** 2).sum())
    sxy = float((d[:, 0] * d[:, 1]).sum())
    syy = float((d[:, 1] ** 2).sum())
    th = 0.5 * math.atan2(2 * sxy, sxx - syy)
    dirv = np.array([math.cos(th), math.sin(th)])
    if float(dirv @ fwd) < 0:
        dirv = -dirv
    nrm = np.array([-dirv[1], dirv[0]])
    rms = float(np.sqrt(((d @ nrm) ** 2).mean()))
    ang = math.degrees(math.atan2(fwd[0] * dirv[1] - fwd[1] * dirv[0], float(fwd @ dirv)))
    return dirv, c, rms, ang


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rec = args[0]
    use_intr = "--intr" in sys.argv
    use_lens = "--lens-quat" in sys.argv
    lag = float(sys.argv[sys.argv.index("--lag") + 1]) if "--lag" in sys.argv else PROJ_LAG_S

    meta = json.load(open(os.path.join(rec, "meta.json")))
    edges = json.load(open(os.path.join(rec, "mat_edges.json")))
    ts, qs, ps = load_heads(os.path.join(rec, "events.jsonl"))
    mat_y = float(meta["tee_box_pos"][1])
    rot = math.radians(float(meta["tee_box_rotation_deg"]))
    fwd = np.array([-math.sin(rot), -math.cos(rot)])
    unproject = make_unproject(meta, use_intr, use_lens)

    print("model: %s ray, lens %s, lag %.0f ms   tee forward heading %+.2f deg   mat plane y=%.4f" % (
        "intrinsics" if use_intr else "fov", "quaternion" if use_lens else "tilt-only",
        lag * 1000, math.degrees(math.atan2(fwd[0], fwd[1])), mat_y))

    rows = []
    for e in edges:
        cap = (e["arrival"] - e["latency"]) / 1e9 - lag
        R, p = pose_at(ts, qs, ps, cap)
        top = unproject(e["top"], R, p, mat_y)
        bot = unproject(e["bottom"], R, p, mat_y)
        if len(top) < 8 or len(bot) < 8:
            continue
        dt, ct, rt, at = fit_dir(top, fwd)
        db, cb, rb, ab = fit_dir(bot, fwd)
        d = dt + db
        d /= np.linalg.norm(d)
        nrm = np.array([-d[1], d[0]])
        width = abs(float((cb - ct) @ nrm))
        yaw, pitch, roll = yaw_pitch_roll(R)
        rows.append(dict(f=e["frame"], yaw=yaw, pitch=pitch, roll=roll,
                         at=at, ab=ab, ang=0.5 * (at + ab), width=width,
                         rms=(rt + rb) * 0.5, dist=float(np.hypot(*(ct - np.array([p[0], p[2]]))))))

    if not rows:
        sys.exit("no frames unprojected")
    A = np.array([r["ang"] for r in rows])
    W = np.array([r["width"] for r in rows])
    Y = np.array([r["yaw"] for r in rows])
    P = np.array([r["pitch"] for r in rows])
    Ro = np.array([r["roll"] for r in rows])
    D = np.array([r["dist"] for r in rows])

    print(" frame    yaw  pitch   roll |  top     bot     mean | width cm | fit rms mm | dist m")
    for r in rows[:: max(1, len(rows) // 25)]:
        print("%6d %+6.1f %+6.1f %+6.1f | %+6.2f %+6.2f  %+6.2f | %8.1f | %9.1f | %5.2f" % (
            r["f"], r["yaw"], r["pitch"], r["roll"], r["at"], r["ab"], r["ang"],
            r["width"] * 100, r["rms"] * 1000, r["dist"]))

    def st(name, v, unit, scale=1.0):
        v = v * scale
        print("%-16s mean %+8.3f %-3s  sd %6.3f  median %+8.3f  min %+8.3f  max %+8.3f  n=%d" % (
            name, v.mean(), unit, v.std(), float(np.median(v)), v.min(), v.max(), v.size))

    print()
    st("mat vs tee fwd", A, "deg")
    st("mat width", W, "cm", 100.0)
    st("edge fit rms", np.array([r["rms"] for r in rows]), "mm", 1000.0)
    for nm, v in (("yaw", Y), ("pitch", P), ("roll", Ro), ("dist", D)):
        var = float(((v - v.mean()) ** 2).mean())
        if var > 1e-9:
            slope = float(((v - v.mean()) * (A - A.mean())).mean() / var)
            print("  angle vs head %-5s slope %+7.4f deg/%s  (range %.1f)" % (nm, slope, nm, v.max() - v.min()))


if __name__ == "__main__":
    main()
