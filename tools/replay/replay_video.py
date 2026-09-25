#!/usr/bin/env python3
"""Side-by-side video: headset camera (real room) | redrawn virtual view (tools/replay/replay_view.gd).  2026-09-24

  1) camera frames at the view's times (run where frames.bin is; small output):
       python3 tools/replay/replay_video.py extract <rec_dir> <view_dir>/frames.csv <cam.npz>
       python3 tools/replay/replay_video.py extract <rec_dir> <t0>:<t1>:<fps> <cam.npz>   (same times as replay_view.gd)
  2) compose (needs numpy, Pillow; ffmpeg for the .mp4):
       python3 tools/replay/replay_video.py compose <view_dir> <cam.npz> <out.mp4> [fps] [overlay]
     overlay: the view was rendered with replay_view.gd ... cam -> camera | camera with the virtual scene on top

frames.csv (written by replay_view.gd) holds the event-clock time (t_ns) of every rendered view; camera frames are
matched on their arrival time (System.nanoTime, the same clock as events.jsonl).
"""
import csv, os, subprocess, sys

def extract(rec_dir, frames_csv, out_npz):
    import numpy as np
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import rec_info
    if os.path.exists(frames_csv):
        want = [int(r["t_ns"]) for r in csv.DictReader(open(frames_csv))]
    else:
        # "t0:t1:fps" - the same times replay_view.gd renders for those arguments (t = 0 at the first event)
        t0, t1, fps = [float(x) for x in frames_csv.split(":")]
        first = None
        last = None
        for line in open(os.path.join(rec_dir, "events.jsonl")):
            if '"t_ns":' in line:
                try:
                    tn = int(line.split('"t_ns":')[1].split(",")[0])
                except ValueError:
                    continue
                first = tn if first is None else first
                if '"type":"head"' in line:
                    last = tn
        t1 = min(t1, (last - first) / 1e9)
        want = []
        t = t0
        while t <= t1 + 1e-9:
            want.append(first + int(t * 1e9))
            t += 1.0 / fps
    # pass 1: timestamps only
    stamps = [fr["arrival"] for fr in rec_info.iter_frames(os.path.join(rec_dir, "frames.bin"), decode=False)]
    pick = {}
    j = 0
    for i, t in enumerate(want):
        while j + 1 < len(stamps) and abs(stamps[j + 1] - t) <= abs(stamps[j] - t):
            j += 1
        pick.setdefault(j, []).append(i)
    imgs = [None] * len(want)
    for k, fr in enumerate(rec_info.iter_frames(os.path.join(rec_dir, "frames.bin"))):
        if k in pick:
            y = np.frombuffer(fr["y"], np.uint8).reshape(fr["h"], fr["w"])
            for i in pick[k]:
                imgs[i] = y
        if k > max(pick):
            break
    # frames can change size inside a recording (full-resolution putt frames): scale everything to the most common one
    from collections import Counter
    from PIL import Image
    h, w = Counter(im.shape for im in imgs if im is not None).most_common(1)[0][0]
    def fit(im):
        if im is None:
            return np.zeros((h, w), np.uint8)
        if im.shape != (h, w):
            return np.asarray(Image.fromarray(im).resize((w, h)))
        return im
    arr = np.stack([fit(im) for im in imgs])
    dt = [(stamps[j] - t) / 1e6 for j, ii in pick.items() for t in [want[i] for i in ii]]
    np.savez_compressed(out_npz, frames=arr)
    print("camera frames %s -> %s (max time offset %.1f ms)" % (arr.shape, out_npz, max(abs(d) for d in dt)))

def compose(view_dir, cam_npz, out_mp4, fps=15, overlay=False):
    import numpy as np
    from PIL import Image
    cams = np.load(cam_npz)["frames"]
    tmp = os.path.join(view_dir, "sbs")
    os.makedirs(tmp, exist_ok=True)
    n = 0
    for i in range(len(cams)):
        vp = os.path.join(view_dir, "v_%05d.png" % i)
        if not os.path.exists(vp):
            break
        if overlay:
            # virtual view rendered from the tracking camera (replay_view.gd ... cam): lay it over the camera image
            v = Image.open(vp).convert("RGBA")
            c = Image.fromarray(cams[i]).convert("RGBA").resize(v.size)
            a = v.getchannel("A").point(lambda x: int(x * 0.55))
            v.putalpha(a)
            both = Image.alpha_composite(c, v).convert("RGB")
            o = Image.new("RGB", (both.width * 2, both.height))
            o.paste(c.convert("RGB"), (0, 0))
            o.paste(both, (both.width, 0))
        else:
            v = Image.open(vp).convert("RGB")
            c = Image.fromarray(cams[i]).convert("RGB")
            c = c.resize((int(c.width * v.height / c.height), v.height))
            o = Image.new("RGB", (c.width + v.width, v.height))
            o.paste(c, (0, 0))
            o.paste(v, (c.width, 0))
        o.save(os.path.join(tmp, "s_%05d.png" % i))
        n += 1
    print("composed %d frames" % n)
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", os.path.join(tmp, "s_%05d.png"),
                        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", out_mp4], check=True)
        print("wrote", out_mp4)
    except (OSError, subprocess.CalledProcessError) as e:
        print("ffmpeg not available (%s); the side-by-side PNGs are in %s" % (e, tmp))

if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "extract":
        extract(sys.argv[2], sys.argv[3], sys.argv[4])
    elif len(sys.argv) >= 5 and sys.argv[1] == "compose":
        compose(sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5]) if len(sys.argv) > 5 else 15,
                len(sys.argv) > 6 and sys.argv[6] == "overlay")
    else:
        print(__doc__)
