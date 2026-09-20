#!/usr/bin/env python3
"""Inspect a session recording pulled from the Quest (tools/pull_sessions.sh).

Usage:
  python3 tools/replay/rec_info.py                      # newest recording under tools/sessions
  python3 tools/replay/rec_info.py <rec_dir> [--png N]  # also export every N-th frame as PNG (needs numpy + Pillow)

Recording layout (written by HeadsetCameraBridge.SessionRecorder):
  frames.bin   : repeated [b'FRM1' | sensorTsNs i64 | arrivalNanoTime i64 | captureLatencyNs i64 | w i32 | h i32 | len i32 | zlib(Y w*h)]  (big-endian)
  events.jsonl : {"t_ns": System.nanoTime, "type": head|arm|disarm|clear|game|start|stop, ...}
  meta.json    : tee pose, camera params, calibration (written by Godot)
"""
import glob, json, os, struct, sys, zlib

HDR = struct.Struct(">4sqqqiii")

def iter_frames(path, decode=True):
    with open(path, "rb") as f:
        while True:
            h = f.read(HDR.size)
            if len(h) < HDR.size:
                return
            magic, ts, arrival, lat, w, hgt, ln = HDR.unpack(h)
            if magic != b"FRM1":
                raise ValueError("bad frame magic at offset %d" % (f.tell() - HDR.size))
            data = f.read(ln)
            if len(data) < ln:
                return
            yield {"ts": ts, "arrival": arrival, "latency": lat, "w": w, "h": hgt,
                   "y": zlib.decompress(data) if decode else None}

def load_events(path):
    ev = []
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line:
                try:
                    ev.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return ev

def newest_recording():
    here = os.path.dirname(os.path.abspath(__file__))
    cands = glob.glob(os.path.join(here, "..", "sessions", "**", "rec_*"), recursive=True)
    cands = [c for c in cands if os.path.isdir(c)]
    return max(cands, key=os.path.getmtime) if cands else None

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rec = args[0] if args else newest_recording()
    if not rec:
        sys.exit("No recording found. Run tools/pull_sessions.sh first or pass a directory.")
    png_every = int(sys.argv[sys.argv.index("--png") + 1]) if "--png" in sys.argv else 0
    print("Recording:", os.path.abspath(rec))
    if os.path.exists(os.path.join(rec, "meta.json")):
        meta = json.load(open(os.path.join(rec, "meta.json")))
        print("  tee:", meta.get("tee_box_pos"), "rot:", meta.get("tee_box_rotation_deg"),
              "camera:", meta.get("camera"), "green:", meta.get("green_speed_mode"))
    n = 0; t0 = t1 = None; dts = []; prev = None; size = 0
    for fr in iter_frames(os.path.join(rec, "frames.bin"), decode=png_every > 0):
        if t0 is None: t0 = fr["ts"]
        t1 = fr["ts"]
        if prev is not None: dts.append((fr["ts"] - prev) / 1e6)
        prev = fr["ts"]
        if png_every and n % png_every == 0:
            import numpy as np
            from PIL import Image
            out = os.path.join(rec, "png"); os.makedirs(out, exist_ok=True)
            Image.fromarray(np.frombuffer(fr["y"], np.uint8).reshape(fr["h"], fr["w"])).save(os.path.join(out, "f%05d.png" % n))
        n += 1
    size = os.path.getsize(os.path.join(rec, "frames.bin")) if os.path.exists(os.path.join(rec, "frames.bin")) else 0
    if n:
        dts.sort()
        print("  frames: %d over %.1f s (%.1f fps), frame gap median %.1f ms, max %.1f ms, file %.0f MB" % (
            n, (t1 - t0) / 1e9, (n - 1) / max(1e-9, (t1 - t0) / 1e9), dts[len(dts)//2] if dts else 0, dts[-1] if dts else 0, size / 1e6))
    ev = load_events(os.path.join(rec, "events.jsonl"))
    kinds = {}
    for e in ev: kinds[e.get("type")] = kinds.get(e.get("type"), 0) + 1
    print("  events:", kinds)
    t_start = ev[0]["t_ns"] if ev else 0
    for e in ev:
        if e.get("type") in ("game", "stop") and ("PUTT" in str(e.get("text", "")) or "HIT" in str(e.get("text", ""))
                                                   or "REJECTED" in str(e.get("text", "")) or e.get("type") == "stop"
                                                   or "LOCKED" in str(e.get("text", ""))):
            print("   %7.2fs  %s" % ((e["t_ns"] - t_start) / 1e9, e.get("text", e)))

if __name__ == "__main__":
    main()
