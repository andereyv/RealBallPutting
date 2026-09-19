#!/usr/bin/env python3
"""
Multi-Pose Optical Calibration Solver for Meta Quest 3 Physical Ball Tracking.
Analyzes captured calibration bundles to determine:
1. Exact physical ball 3D position via multi-ray triangulation.
2. Ray intersection error (residual bundle alignment).
3. Optimal optical parameters (Tilt angle, HFOV, VFOV, Camera translation offset).
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
    """Finds the center of the red crosshair drawn on the raw image."""
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
    # pts are (y, x)
    cy = float(np.mean(pts[:, 0]))
    cx = float(np.mean(pts[:, 1]))
    h, w, _ = img.shape
    return cx / float(w), cy / float(h), w, h

def load_bundles():
    meta_files = sorted(glob.glob(os.path.join(CAPTURES_DIR, "bundle_*_meta.json")))
    bundles = []
    for mf in meta_files:
        with open(mf, "r") as f:
            meta = json.load(f)
        bid = meta["bundle_id"]
        # Skip known false-positive (Pose 5 where white trackpad was detected instead of ball)
        if bid == "1788984866756":
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
            "head_quat": np.array(meta["head_quat"]), # [x, y, z, w]
            "ball_pos_reported": np.array(meta["ball_filtered_pos"]),
            "w": w,
            "h": h
        })
    return bundles

def compute_rays(bundles, cam_offset, tilt_deg, hfov_deg, vfov_deg):
    rays = []
    origins = []
    tan_half_h = np.tan(np.deg2rad(hfov_deg * 0.5))
    tan_half_v = np.tan(np.deg2rad(vfov_deg * 0.5))
    
    # Tilt rotation around local X axis
    tilt_rot = R.from_euler('x', -tilt_deg, degrees=True)
    
    for b in bundles:
        head_rot = R.from_quat(b["head_quat"])
        # Camera origin in world space
        cam_origin = b["head_pos"] + head_rot.apply(cam_offset)
        
        # Pinhole local ray before tilt
        nx = b["norm_x"]
        ny = b["norm_y"]
        cam_dir = np.array([
            (nx - 0.5) * 2.0 * tan_half_h,
            -(ny - 0.5) * 2.0 * tan_half_v,
            -1.0
        ])
        cam_dir /= np.linalg.norm(cam_dir)
        
        # Apply downward optical tilt then head rotation to get world ray
        world_dir = head_rot.apply(tilt_rot.apply(cam_dir))
        world_dir /= np.linalg.norm(world_dir)
        
        rays.append(world_dir)
        origins.append(cam_origin)
        
    return np.array(origins), np.array(rays)

def triangulate_rays(origins, rays):
    """
    Computes the optimal 3D point P that minimizes sum of squared distances to all rays.
    Each ray is O_i + t * D_i.
    Distance from P to ray i: || (I - D_i D_i^T) (P - O_i) ||^2
    """
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
    
    # Residual distances to each ray
    residuals = []
    for i in range(n):
        D = rays[i]
        O = origins[i]
        diff = P - O
        dist = np.linalg.norm(diff - np.dot(diff, D) * D)
        residuals.append(dist)
        
    return P, np.array(residuals)

def main():
    bundles = load_bundles()
    print(f"Loaded {len(bundles)} valid calibration bundles.\n")
    if len(bundles) < 2:
        print("Need at least 2 bundles to solve.")
        return

    # Current settings from Godot:
    cur_offset = np.array([-0.032, -0.045, -0.065])
    cur_tilt = 8.4
    cur_hfov = 78.0
    cur_vfov = 62.0

    print("================================================================")
    print(" 1. TRIANGULATION WITH CURRENT SETTINGS")
    print(f"    Cam Offset: {cur_offset}")
    print(f"    Tilt: {cur_tilt}°, HFOV: {cur_hfov}°, VFOV: {cur_vfov}°")
    print("================================================================")
    origins, rays = compute_rays(bundles, cur_offset, cur_tilt, cur_hfov, cur_vfov)
    ball_pt, residuals = triangulate_rays(origins, rays)
    print(f"Estimated Physical Ball 3D Position: ({ball_pt[0]:.4f}, {ball_pt[1]:.4f}, {ball_pt[2]:.4f}) m")
    print(f"Average Ray-to-Point Miss Distance: {np.mean(residuals)*1000.0:.2f} mm (Max: {np.max(residuals)*1000.0:.2f} mm)\n")

    # Optimization: Find best (tilt, hfov, vfov, cam_y_offset) to minimize ray intersection error
    print("================================================================")
    print(" 2. OPTIMIZING OPTICAL PARAMETERS ACROSS ALL POSES")
    print("================================================================")

    def loss(params):
        tilt, hfov, vfov, y_off, z_off = params
        off = np.array([-0.032, y_off, z_off])
        o, r = compute_rays(bundles, off, tilt, hfov, vfov)
        _, res = triangulate_rays(o, r)
        return np.mean(res)

    init_params = [cur_tilt, cur_hfov, cur_vfov, cur_offset[1], cur_offset[2]]
    bounds = [(0.0, 20.0), (60.0, 95.0), (45.0, 80.0), (-0.08, 0.0), (-0.12, 0.0)]
    res = minimize(loss, init_params, bounds=bounds, method='L-BFGS-B')

    opt_tilt, opt_hfov, opt_vfov, opt_y_off, opt_z_off = res.x
    opt_offset = np.array([-0.032, opt_y_off, opt_z_off])
    opt_origins, opt_rays = compute_rays(bundles, opt_offset, opt_tilt, opt_hfov, opt_vfov)
    opt_ball_pt, opt_residuals = triangulate_rays(opt_origins, opt_rays)

    print(f"Optimized Parameters:")
    print(f"  Camera Optical Tilt:  {opt_tilt:.2f}° (was {cur_tilt}°)")
    print(f"  Camera HFOV:          {opt_hfov:.2f}° (was {cur_hfov}°)")
    print(f"  Camera VFOV:          {opt_vfov:.2f}° (was {cur_vfov}°)")
    print(f"  Camera Y Offset:      {opt_y_off*1000.0:.1f} mm (was {cur_offset[1]*1000.0:.1f} mm)")
    print(f"  Camera Z Offset:      {opt_z_off*1000.0:.1f} mm (was {cur_offset[2]*1000.0:.1f} mm)")
    print(f"Optimized Physical Ball 3D Position: ({opt_ball_pt[0]:.4f}, {opt_ball_pt[1]:.4f}, {opt_ball_pt[2]:.4f}) m")
    print(f"Optimized Average Residual Error:    {np.mean(opt_residuals)*1000.0:.2f} mm (Max: {np.max(opt_residuals)*1000.0:.2f} mm)")
    print("================================================================\n")

    for i, b in enumerate(bundles):
        print(f"Pose {i+1} [ID {b['id']}]: Head=({b['head_pos'][0]:.2f}, {b['head_pos'][1]:.2f}, {b['head_pos'][2]:.2f}) | "
              f"Pixel=({b['norm_x']*b['w']:.0f}, {b['norm_y']*b['h']:.0f}) | "
              f"Current Error={residuals[i]*1000.0:.1f} mm -> Optimized={opt_residuals[i]*1000.0:.1f} mm")

if __name__ == "__main__":
    main()
