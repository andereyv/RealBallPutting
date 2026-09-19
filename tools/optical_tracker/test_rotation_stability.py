#!/usr/bin/env python3
"""
Evaluates angular pointing error of the 3D rays towards the true physical ball position.
Tests how well the calibrated optics maintain gaze lock across pure head rotations.
"""

import json
import glob
import os
from PIL import Image
import numpy as np
from scipy.spatial.transform import Rotation as R

CAPTURES_DIR = os.path.join(os.path.dirname(__file__), "captures")

# True physical ball position from multi-pose triangulation
BALL_WORLD_PT = np.array([0.5605, 0.4891, 2.4127])

# Calibrated Quest 3 parameters
HW_OFFSET = np.array([-0.0322, -0.0179, -0.0627])
TILT_DEG = 10.75
HFOV_DEG = 66.91
VFOV_DEG = 52.72

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

def main():
    meta_files = sorted(glob.glob(os.path.join(CAPTURES_DIR, "bundle_*_meta.json")))
    
    # Only test the new batch (captured after 22:20)
    new_bundles = []
    for mf in meta_files:
        with open(mf, "r") as f:
            meta = json.load(f)
        bid = meta["bundle_id"]
        if int(bid) < 1788985200000:
            continue
        raw_path = os.path.join(CAPTURES_DIR, f"bundle_{bid}_raw.jpg")
        center_info = find_ball_center_in_raw(raw_path)
        if center_info is None:
            continue
        norm_x, norm_y, w, h = center_info
        new_bundles.append({
            "id": bid,
            "meta": meta,
            "norm_x": norm_x,
            "norm_y": norm_y,
            "head_pos": np.array(meta["head_pos"]),
            "head_quat": np.array(meta["head_quat"]),
            "w": w,
            "h": h
        })

    print(f"\n==========================================================================")
    print(f" ROTATION STABILITY & ANGULAR ACCURACY (Batch of {len(new_bundles)} bundles)")
    print(f" True Ball Position: ({BALL_WORLD_PT[0]:.3f}, {BALL_WORLD_PT[1]:.3f}, {BALL_WORLD_PT[2]:.3f}) m")
    print(f"==========================================================================")
    
    tan_half_h = np.tan(np.deg2rad(HFOV_DEG * 0.5))
    tan_half_v = np.tan(np.deg2rad(VFOV_DEG * 0.5))
    tilt_rot = R.from_euler('x', -TILT_DEG, degrees=True)
    
    angular_errors = []
    lateral_misses = []
    
    for i, b in enumerate(new_bundles):
        # Exclude pose 6 where arrow keys were selected with 0% conf
        if b["id"] == "1788985313912":
            print(f"  [Skipped Pose {i+1}]: 0% Conf False Detection on Keyboard Arrow Key")
            continue
            
        head_rot = R.from_quat(b["head_quat"])
        cam_origin = b["head_pos"] + head_rot.apply(HW_OFFSET)
        
        # Ground truth vector from camera to ball
        true_vec = BALL_WORLD_PT - cam_origin
        dist_to_ball = np.linalg.norm(true_vec)
        true_dir = true_vec / dist_to_ball
        
        # Computed ray from detected pixel
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
        
        # Angle between computed ray and true direction (degrees)
        dot = np.clip(np.dot(world_dir, true_dir), -1.0, 1.0)
        angle_deg = np.rad2deg(np.arccos(dot))
        
        # Lateral miss distance at ball distance (arc length = angle * dist)
        lateral_miss_mm = np.deg2rad(angle_deg) * dist_to_ball * 1000.0
        
        angular_errors.append(angle_deg)
        lateral_misses.append(lateral_miss_mm)
        
        # Projected 3D point along ray at ball distance
        ray_ball_pt = cam_origin + world_dir * dist_to_ball
        error_xyz = ray_ball_pt - BALL_WORLD_PT
        
        print(f"Pose {i+1} [ID {b['id']}]:")
        print(f"  Pixel: ({nx*b['w']:.0f}, {ny*b['h']:.0f}) | Dist: {dist_to_ball*100.0:.1f} cm")
        print(f"  Ray Angular Offset:  {angle_deg:.2f}°")
        print(f"  Lateral Reticle Miss: {lateral_miss_mm:.1f} mm ({lateral_miss_mm/10.0:.2f} cm)")
        print(f"  Offset Vector: dX={error_xyz[0]*1000.0:+.1f}mm, dY={error_xyz[1]*1000.0:+.1f}mm, dZ={error_xyz[2]*1000.0:+.1f}mm\n")

    print(f"==========================================================================")
    print(f"SUMMARY FOR VALID BALL DETECTIONS:")
    print(f"  Mean Angular Error:    {np.mean(angular_errors):.2f}°")
    print(f"  Mean Reticle Miss:     {np.mean(lateral_misses):.1f} mm ({np.mean(lateral_misses)/10.0:.2f} cm)")
    print(f"  Max Reticle Miss:      {np.max(lateral_misses):.1f} mm")
    print(f"==========================================================================\n")

if __name__ == "__main__":
    main()
