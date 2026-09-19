#!/usr/bin/env python3
"""Summarise Speed v2 putt logs (speed_v2_log.jsonl pulled from the Quest with pull_sessions.sh).

Usage: python3 tools/speed_v2_report.py [path/to/speed_v2_log.jsonl] [--truth 1.23,1.50,...]
  --truth: optional reference speeds (m/s at ~6 cm, e.g. from 240 fps phone video), in putt order.
"""
import json, sys, glob, os, statistics as st

args = [a for a in sys.argv[1:] if not a.startswith("--")]
truth = []
if "--truth" in sys.argv:
    truth = [float(x) for x in sys.argv[sys.argv.index("--truth") + 1].split(",")]
path = args[0] if args else next(iter(sorted(glob.glob(os.path.join(os.path.dirname(__file__), "sessions", "**", "speed_v2_log.jsonl"), recursive=True))), None)
if not path:
    sys.exit("No speed_v2_log.jsonl found. Run tools/pull_sessions.sh first or pass a path.")

rows = [json.loads(l) for l in open(path) if l.strip()]
print(f"{len(rows)} putts from {path}\n")
print(f"{'#':>3} {'v2 m/s':>7} {'gate m/s':>8} {'diff':>6} {'v2 ang':>7} {'n':>5} {'rms mm':>6} {'lat mm':>6} {'range cm':>9}  {'truth':>6}  note")
for i, r in enumerate(rows):
    v2, g = r["v2_speed"], r["gate_comp_speed"]
    diff = f"{(v2 / g - 1) * 100:+.0f}%" if g > 0 else "-"
    tr = f"{truth[i]:.2f}" if i < len(truth) else ""
    rng = f"{r['v2_first_dist']*100:.0f}-{r['v2_last_dist']*100:.0f}"
    note = "" if r["v2_valid"] else r["v2_reason"]
    print(f"{i+1:>3} {v2:7.2f} {g:8.2f} {diff:>6} {r['v2_angle']:+7.1f} {r['v2_used_n']:>2}/{r['v2_n']:<2} {r['v2_rms_mm']:6.1f} {r['v2_lateral_rms_mm']:6.1f} {rng:>9}  {tr:>6}  {note}")

if truth:
    for name, key in (("v2", "v2_speed"), ("gate", "gate_comp_speed")):
        errs = [(r[key] / t - 1) * 100 for r, t in zip(rows, truth)]
        print(f"\n{name}: mean error {st.mean(errs):+.1f}%, spread (stdev) {st.pstdev(errs):.1f}%")
    ratio = st.median(t / r["v2_speed"] for r, t in zip(rows, truth) if r["v2_speed"] > 0)
    print(f"Suggested v2 scale factor: {ratio:.3f}")
