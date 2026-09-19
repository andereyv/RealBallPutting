#!/usr/bin/env python3
"""
Hardware-constrained optical calibration solver.
Fixes camera translation to Quest 3 hardware sensor pose:
  x = -0.0322 m (-32.2 mm)
  y = -0.0179 m (-17.9 mm)
  z = -0.0627 m (-62.7 mm)
Optimizes:
  tilt (optical downward angle)
  hfov, vfov (focal field of view)
"""

import json
import glob
import os
from PIL import Image
import numpy as np
from scipy.spatial.transform import Rotation as R
from scipy.optimize import minimize

CAPTURES_DIR = os.path.join(os.path.dirname(__file__), "captures")

def find_ball_center_in_raw(raw_path):
    try:
        pil_img = Image.open(raw_path).convert("RGB")
    except Exception:
        return None
    img = np.array(pil_img)
    r = img[:, :, 0]
    g = img[:, :, 1]
    b = img[:, :, 2]
    red_mask = (r > 180) & (g < 60) & (b < 60)
    pts = np.argwhere(red_mask)
    if len(pts) == 0:
        return None
    cy = float(np.mean(pts[:, 0]))
    cx = float(np.mean(pts[:, 1]))
    h, w, _ = img.shape
    return cx / float(w), cy / float(h), w, h

def load_bundles(min_timestamp=None):
    meta_files = sorted(glob.glob(os.path.join(CAPTURES_DIR, "bundle_*_meta.json")))
    bundles = []
    for mf in meta_files:
        with open(mf, "r") as f:
            meta = json.load(f)
        bid = meta["bundle_id"]
        if min_timestamp and int(bid) < min_timestamp:
            continue
        if bid == "1788984866756": # Skip trackpad outlier
            continue
        raw_path = os.path.join(CAPTURES_DIR, f"bundle_{bid}_raw.jpg")
        center_info = find_ball_center_in_raw(raw_path)
        if center_info is None:
            continue
        norm_x, norm_y, w, h = center_info
        bundles.append({
            "id": bid,
            "meta": meta,
            "norm_x": norm_x,
            "norm_y": norm_y,
            "head_pos": np.array(meta["head_pos"]),
            "head_quat": np.array(meta["head_quat"]),
            "w": w,
            "h": h
        })
    return bundles

def compute_rays(bundles, cam_offset, tilt_deg, hfov_deg, vfov_deg):
    rays = []
    origins = []
    tan_half_h = np.tan(np.deg2rad(hfov_deg * 0.5))
    tan_half_v = np.tan(np.deg2rad(vfov_deg * 0.5))
    tilt_rot = R.from_euler('x', -tilt_deg, degrees=True)
    
    for b in bundles:
        head_rot = R.from_quat(b["head_quat"])
        cam_origin = b["head_pos"] + head_rot.apply(cam_offset)
        nx = b["norm_x"]
        ny = b["norm_y"]
        cam_dir = np.array([
            (nx - 0.5) * 2.0 * tan_half_h,
            -(ny - 0.5) * 2.0 * tan_half_v,
            -1.0
        ])
        cam_dir /= np.linalg.norm(cam_dir)
        world_dir = head_rot.apply(tilt_rot.apply(cam_dir))
        world_dir /= np.linalg.norm(world_dir)
        rays.append(world_dir)
        origins.append(cam_origin)
        
    return np.array(origins), np.array(rays)

def triangulate_rays(origins, rays):
    n = len(origins)
    A = np.zeros((3, 3))
    b = np.zeros(3)
    I = np.eye(3)
    for i in range(n):
        D = rays[i].reshape(3, 1)
        O = origins[i]
        proj = I - D @ D.T
        A += proj
        b += proj @ O
    P = np.linalg.solve(A, b)
    residuals = []
    for i in range(n):
        D = rays[i]
        O = origins[i]
        diff = P - O
        dist = np.linalg.norm(diff - np.dot(diff, D) * D)
        residuals.append(dist)
    return P, np.array(residuals)

def main():
    import sys
    min_ts = 1788985000000 if len(sys.argv) > 1 and sys.argv[1] == "new" else None
    bundles = load_bundles(min_timestamp=min_ts)
    batch_name = "NEW BATCH (Just Captured)" if min_ts else "ALL BATCHES COMBINED"
    print(f"\n================================================================")
    print(f" EVALUATING: {batch_name} ({len(bundles)} bundles)")
    print(f"================================================================")
    
    hw_offset = np.array([-0.0322, -0.0179, -0.0627])
    
    # 1. Test performance with current app parameters
    app_tilt = 10.75
    app_hfov = 66.91
    app_vfov = 52.72
    cur_origins, cur_rays = compute_rays(bundles, hw_offset, app_tilt, app_hfov, app_vfov)
    cur_ball_pt, cur_residuals = triangulate_rays(cur_origins, cur_rays)
    
    print(f"Current App Calibration (Tilt={app_tilt}°, HFOV={app_hfov}°, VFOV={app_vfov}°):")
    print(f"  Estimated Ball 3D:   ({cur_ball_pt[0]:.4f}, {cur_ball_pt[1]:.4f}, {cur_ball_pt[2]:.4f}) m")
    print(f"  Average Ray Error:   {np.mean(cur_residuals)*1000.0:.2f} mm (Max: {np.max(cur_residuals)*1000.0:.2f} mm)\n")
    
    for i, b in enumerate(bundles):
        reported = b["meta"].get("ball_filtered_pos", [0, 0, 0])
        dist_to_reported = np.linalg.norm(cur_ball_pt - np.array(reported))
        print(f"  Pose {i+1} [ID {b['id']}]: Head=({b['head_pos'][0]:.2f}, {b['head_pos'][1]:.2f}, {b['head_pos'][2]:.2f}) | "
              f"Pixel=({b['norm_x']*b['w']:.0f}, {b['norm_y']*b['h']:.0f}) | Ray Error={cur_residuals[i]*1000.0:.1f} mm | App Dist={dist_to_reported*1000.0:.1f} mm")

    # 2. Re-optimize on this dataset
    def loss(params):
        tilt, hfov = params
        tan_h = np.tan(np.deg2rad(hfov * 0.5))
        vfov = 2.0 * np.rad2deg(np.arctan(tan_h * (3.0 / 4.0)))
        o, r = compute_rays(bundles, hw_offset, tilt, hfov, vfov)
        _, res = triangulate_rays(o, r)
        return np.mean(res)

    res = minimize(loss, [app_tilt, app_hfov], bounds=[(0.0, 25.0), (55.0, 85.0)], method='L-BFGS-B')
    opt_tilt, opt_hfov = res.x
    tan_h = np.tan(np.deg2rad(opt_hfov * 0.5))
    opt_vfov = 2.0 * np.rad2deg(np.arctan(tan_h * (3.0 / 4.0)))

    opt_origins, opt_rays = compute_rays(bundles, hw_offset, opt_tilt, opt_hfov, opt_vfov)
    opt_ball_pt, opt_residuals = triangulate_rays(opt_origins, opt_rays)

    print(f"\nOptimal Fit for this dataset:")
    print(f"  Tilt: {opt_tilt:.2f}°, HFOV: {opt_hfov:.2f}°, VFOV: {opt_vfov:.2f}°")
    print(f"  Ball 3D: ({opt_ball_pt[0]:.4f}, {opt_ball_pt[1]:.4f}, {opt_ball_pt[2]:.4f}) m")
    print(f"  Optimal Average Ray Error: {np.mean(opt_residuals)*1000.0:.2f} mm (Max: {np.max(opt_residuals)*1000.0:.2f} mm)")
    print("================================================================\n")

if __name__ == "__main__":
    main()
