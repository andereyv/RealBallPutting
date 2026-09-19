#!/usr/bin/env python3
"""
Simulates Quest 3 Dual-Camera Stereo Triangulation on Mac using captured bundles.
"""

import glob
import json
import os
import cv2
import numpy as np

def run():
    bundle_dir = "scratch/captured_frames/files"
    meta_files = sorted(glob.glob(os.path.join(bundle_dir, "bundle_*_meta.json")))
    print(f"Loaded {len(meta_files)} total bundle metadata files on Mac.\n")

    stereo_bundles = []
    for mf in meta_files:
        with open(mf) as f:
            meta = json.load(f)
        if meta.get("has_stereo", False):
            stereo_bundles.append((mf, meta))

    print(f"Found {len(stereo_bundles)} full stereo bundles with Left + Right camera frames!\n")

    for mf, meta in stereo_bundles:
        bid = meta.get("bundle_id", "unknown")
        ts = meta.get("timestamp", "unknown")
        lx = meta.get("left_norm_x", 0.0)
        ly = meta.get("left_norm_y", 0.0)
        rx = meta.get("right_norm_x", 0.0)
        ry = meta.get("right_norm_y", 0.0)
        disp = meta.get("disparity", 0.0)
        ball_pos = meta.get("ball_filtered_pos", [0, 0, 0])
        head_pos = meta.get("head_pos", [0, 0, 0])

        hfov_deg = meta.get("camera_hfov_deg", 73.5)
        hfov_rad = np.deg2rad(hfov_deg)
        f_norm = 1.0 / (2.0 * np.tan(hfov_rad / 2.0))
        dist_m = (0.064 * f_norm) / disp if disp > 0 else 0.0

        left_img = os.path.join(bundle_dir, f"bundle_{bid}_left_raw.jpg")
        right_img = os.path.join(bundle_dir, f"bundle_{bid}_right_raw.jpg")
        has_l = os.path.exists(left_img)
        has_r = os.path.exists(right_img)

        print(f"--- Bundle {bid} ({ts}) ---")
        print(f"  Left Image:  {left_img} (exists: {has_l})")
        print(f"  Right Image: {right_img} (exists: {has_r})")
        print(f"  Left Ray:    ({lx:.3f}, {ly:.3f})")
        print(f"  Right Ray:   ({rx:.3f}, {ry:.3f})")
        print(f"  Disparity:   {disp:.4f}")
        print(f"  Distance:    {dist_m:.2f} m from Quest camera baseline")
        print(f"  Head Pose:   ({head_pos[0]:.3f}, {head_pos[1]:.3f}, {head_pos[2]:.3f})")
        print(f"  3D Ball:     ({ball_pos[0]:.3f}, {ball_pos[1]:.3f}, {ball_pos[2]:.3f})\n")

if __name__ == "__main__":
    run()
