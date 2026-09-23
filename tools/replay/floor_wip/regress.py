#!/usr/bin/env python3
"""Run the PuttTracker replay over the regression set and summarise each detected putt.

  tools/replay/floor_wip/run.sh [baseline|wip]   (compiles, then runs this)

Per putt: time, gate speed, number of real samples, forward span (m), and a straight-line floor speed fitted
through the samples unprojected with the same camera model as the game (mat_edge_world.make_unproject), so the
old and new tracker can be compared on the same recordings without Godot.
"""
import json, math, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(PROJ, "tools", "replay"))
from mat_edge_world import load_heads, pose_at, make_unproject

# putt windows cut from the full recordings (tools/sessions is git-ignored)
RS = os.path.join(PROJ, "tools", "sessions", "regression")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PROJ, "tools", "replay", "build")
EXPECT = {  # real putts (replay time, s) that must be found; from the live HIT lines / frame inspection
    "rec_20260920_182403": [26.5, 55.2, 78.9],
    "rec_20260920_175353": [16.0, 38.8],
    "rec_20260920_173840": [15.7, 34.5, 53.0],
    "rec_20260920_152622": [18.0],
    "floor_20260921_202308": [64.0],
    "floor_20260921_214040": [33.2],
    "floor_20260921_230508": [26.6],  # first recording with colour (FRM2)
    "floor_20260922_202036": [33.3, 105.8, 144.6],  # wood floor, evening; true speed ~1.1 m/s each (frame-by-frame check)
    "floor_20260922_204621": [39.3, 82.0, 118.0],  # wood floor, first build with Fix 14: 3/3 live; truth 1.15/1.03/~1.2 m/s
    "floor_20260922_222427": [31.6, 86.0, 115.3, 141.7],  # anchor on putter face / off-projection (Fix 15); 66.7 = toe nudge, rejected in Godot
}


# recorded before the disarm race was fixed: their disarm events cut tracking short (see replay.sh --ignore-disarm)
IGNORE_DISARM = {"floor_20260922_202036", "floor_20260922_222427", "rec_20260920_173840", "rec_20260920_175353", "rec_20260920_182403", "rec_20260920_152622"}


def summarise(rec):
    d = os.path.join(RS, rec)
    meta = json.load(open(os.path.join(d, "meta.json")))
    ts, qs, ps = load_heads(os.path.join(d, "events.jsonl"))
    unp = make_unproject(meta, False, False)
    plane = float(meta["tee_box_pos"][1]) + 0.02135
    rows = []
    pf = os.path.join(d, "replay_putts.jsonl")
    if not os.path.exists(pf):
        return rows
    for line in open(pf):
        p = json.loads(line)
        tt, pts = [], []
        for s in p["samples"]:
            R, pp = pose_at(ts, qs, ps, s[1] / 1e9 - 0.025)
            w = unp([[s[2], s[3]]], R, pp, plane)
            if len(w):
                tt.append(s[0]); pts.append(w[0])
        v = span = float("nan")
        if len(pts) >= 3:
            P = np.array(pts); T = np.array(tt)
            dvec = P[-1] - P[0]; L = np.linalg.norm(dvec)
            if L > 1e-6:
                s_along = (P - P[0]) @ (dvec / L)
                span = float(s_along.max() - s_along.min())
                v = float(np.polyfit(T, s_along, 1)[0])
        rows.append(dict(t=p["t_s"], gate=p["gate_speed"], n=len(pts), span=span, v=v))
    return rows


def main():
    total_ok = total_missed = total_extra = 0
    for rec in sorted(os.listdir(RS)):
        d = os.path.join(RS, rec)
        extra = ["--ignore-disarm"] if rec in IGNORE_DISARM else []
        r = subprocess.run(["java", "-cp", OUT, "ReplayRunner", d, "--quiet"] + extra, capture_output=True, text=True)
        if r.returncode != 0:
            print(rec, "REPLAY FAILED", r.stderr[-400:]); continue
        rows = summarise(rec)
        exp = EXPECT.get(rec, [])
        used = set()
        print("== %s: %d putt(s)" % (rec, len(rows)))
        for row in rows:
            # a detection belongs to the expected putt within 2 s before its reported time
            match = [e for e in exp if -1.5 <= row["t"] - e <= 2.5 and e not in used]
            tag = "ok" if match else "EXTRA"
            if match: used.add(match[0])
            print("   %7.2fs  gate %.2f m/s  fit %.2f m/s  n=%2d  span %.2f m  %s" % (
                row["t"], row["gate"], row["v"], row["n"], row["span"], tag))
            total_extra += (tag == "EXTRA")
        for e in exp:
            if e not in used:
                print("   MISSED putt near %.1fs" % e)
                total_missed += 1
        total_ok += len(used)
    print("\nTOTAL: %d found, %d missed, %d extra" % (total_ok, total_missed, total_extra))


if __name__ == "__main__":
    main()
