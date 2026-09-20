#!/usr/bin/env python3
"""Angle test 1: measure the physical mat's long edge through the SAME camera model
the ball tracker uses, so we can compare the mat's world direction with the tee's
aligned forward direction and with the measured putt directions.

Stage 1 (this script, image space): find the dark mat band in each full-res frame,
fit its top and bottom edge as straight lines, and emit sample points along those
lines in the tracker's normalised image coords (x/w, y/h, origin top-left).

  python3 tools/replay/mat_edge_detect.py <rec_dir> [--every N] [--max M] [--debug]

Writes <rec_dir>/mat_edges.json:
  [{"frame":i,"arrival":ns,"latency":ns,"rms_px":..,"span_px":..,
    "top":[[u,v],...],"bottom":[[u,v],...]}, ...]

Stage 2 is tools/replay/check_mat_edge.gd, which unprojects these onto the floor
plane with the head pose at each frame and fits the world-space direction.
"""
import json, os, sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rec_info

COL_STEP = 2          # sample every Nth image column
ROW_LO, ROW_HI = 60, 476
MIN_RUN, MAX_RUN = 25, 230
MEDIAN_WINDOW = 25.0  # px: drop columns whose edge is far from the band median (kills the target box)
REJECT_PX = 3.0       # robust line-fit rejection
MIN_INLIERS = 80
MIN_SPAN = 260.0      # px
MAX_RMS = 1.5         # px
N_SAMPLES = 24        # points emitted per edge


def _smooth(col: np.ndarray) -> np.ndarray:
    k = np.ones(5) / 5.0
    return np.convolve(col, k, mode="same")


def _column_edges(col: np.ndarray):
    """Longest dark run in one column -> (subpixel top, subpixel bottom, thr) or None."""
    c = _smooth(col.astype(np.float32))
    seg = c[ROW_LO:ROW_HI]
    lo = np.percentile(seg, 10.0)
    hi = np.percentile(seg, 70.0)
    if hi - lo < 8.0:          # no contrast in this column -> no mat here
        return None
    thr = 0.5 * (lo + hi)
    dark = seg < thr
    # longest run of True
    idx = np.flatnonzero(np.diff(np.concatenate(([0], dark.view(np.int8), [0]))))
    if idx.size < 2:
        return None
    starts, ends = idx[0::2], idx[1::2]
    lens = ends - starts
    j = int(np.argmax(lens))
    if not (MIN_RUN <= lens[j] <= MAX_RUN):
        return None
    a, b = int(starts[j]), int(ends[j] - 1)          # first / last dark row inside seg
    # subpixel: crossing of thr between the last light pixel and the first dark one
    def _cross(i_light, i_dark):
        v0, v1 = c[ROW_LO + i_light], c[ROW_LO + i_dark]
        if abs(v1 - v0) < 1e-3:
            return float(ROW_LO + i_dark)
        f = (v0 - thr) / (v0 - v1)
        return float(ROW_LO + i_light) + f * (i_dark - i_light)
    top = _cross(a - 1, a) if a > 0 else float(ROW_LO + a)
    bot = _cross(b + 1, b) if b + 1 < seg.size else float(ROW_LO + b)
    return top, bot, thr


def _robust_line(xs: np.ndarray, ys: np.ndarray):
    """y = m*x + c with iterative outlier rejection. Returns (m, c, mask, rms)."""
    mask = np.ones(xs.size, bool)
    m = c = 0.0
    rms = 0.0
    for _ in range(4):
        if mask.sum() < 10:
            return None
        A = np.stack([xs[mask], np.ones(mask.sum())], 1)
        sol, *_ = np.linalg.lstsq(A, ys[mask], rcond=None)
        m, c = float(sol[0]), float(sol[1])
        res = ys - (m * xs + c)
        rms = float(np.sqrt(np.mean(res[mask] ** 2)))
        new = np.abs(res) <= max(REJECT_PX, 2.5 * rms)
        if new.sum() == mask.sum() and np.array_equal(new, mask):
            break
        mask = new
    return m, c, mask, rms


def _fit_edge(xs, ys):
    xs = np.asarray(xs, float)
    ys = np.asarray(ys, float)
    if xs.size < MIN_INLIERS:
        return None
    # band median kills the target box / putter columns before the line fit sees them
    keep = np.abs(ys - np.median(ys)) < MEDIAN_WINDOW
    if keep.sum() < MIN_INLIERS:
        return None
    r = _robust_line(xs[keep], ys[keep])
    if r is None:
        return None
    m, c, mask, rms = r
    xin = xs[keep][mask]
    if xin.size < MIN_INLIERS or rms > MAX_RMS:
        return None
    span = float(xin.max() - xin.min())
    if span < MIN_SPAN:
        return None
    return m, c, float(xin.min()), float(xin.max()), rms, int(xin.size)


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rec = args[0] if args else rec_info.newest_recording()
    every = int(sys.argv[sys.argv.index("--every") + 1]) if "--every" in sys.argv else 10
    hardmax = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 10 ** 9
    debug = "--debug" in sys.argv

    out = []
    seen = full = 0
    reasons = {"run": 0, "topfit": 0, "botfit": 0, "ok": 0}
    for i, fr in enumerate(rec_info.iter_frames(os.path.join(rec, "frames.bin"))):
        seen += 1
        if fr["w"] < 640 or i % every:
            continue
        full += 1
        if full > hardmax:
            break
        img = np.frombuffer(fr["y"], np.uint8).reshape(fr["h"], fr["w"])
        xs, tops, bots = [], [], []
        for x in range(0, fr["w"], COL_STEP):
            e = _column_edges(img[:, x])
            if e is None:
                continue
            xs.append(x + 0.5)
            tops.append(e[0])
            bots.append(e[1])
        if len(xs) < MIN_INLIERS:
            reasons["run"] += 1
            continue
        ft = _fit_edge(xs, tops)
        if ft is None:
            reasons["topfit"] += 1
            continue
        fb = _fit_edge(xs, bots)
        if fb is None:
            reasons["botfit"] += 1
            continue
        reasons["ok"] += 1
        rec_pts = {"frame": i, "arrival": fr["arrival"], "latency": fr["latency"],
                   "w": fr["w"], "h": fr["h"]}
        for name, f in (("top", ft), ("bottom", fb)):
            m, c, x0, x1, rms, n = f
            xx = np.linspace(x0, x1, N_SAMPLES)
            rec_pts[name] = [[float(u) / fr["w"], float(m * u + c) / fr["h"]] for u in xx]
            rec_pts[name + "_rms_px"] = round(rms, 3)
            rec_pts[name + "_n"] = n
            rec_pts[name + "_deg_img"] = round(float(np.degrees(np.arctan(m))), 3)
        rec_pts["span_px"] = round(ft[3] - ft[2], 1)
        out.append(rec_pts)
        if debug and len(out) <= 5:
            print("frame %5d  cols %3d  top %+.3f px/px rms %.2f n %3d  bottom %+.3f rms %.2f n %3d  span %.0f" % (
                i, len(xs), ft[0], ft[4], ft[5], fb[0], fb[4], fb[5], ft[3] - ft[2]))

    path = os.path.join(rec, "mat_edges.json")
    json.dump(out, open(path, "w"))
    print("frames scanned %d (full-res sampled %d), usable %d  [%s]" % (
        seen, full, len(out), ", ".join("%s=%d" % kv for kv in reasons.items())))
    if out:
        band = [(r["bottom_deg_img"] + r["top_deg_img"]) * 0.5 for r in out]
        print("image-space edge tilt: median %+.2f deg, spread %.2f deg" % (
            float(np.median(band)), float(np.std(band))))
    print("wrote", path)


if __name__ == "__main__":
    main()
