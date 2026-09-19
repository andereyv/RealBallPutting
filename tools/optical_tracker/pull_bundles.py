#!/usr/bin/env python3
"""
Pulls and parses 6DOF calibration bundles from Meta Quest 3.
Each bundle contains:
  - bundle_<id>_raw.jpg   (Raw uncropped camera frame)
  - bundle_<id>_crop.jpg  (320x320 YOLO crop with bounding box)
  - bundle_<id>_vr.png    (Stereo display capture what eyes saw)
  - bundle_<id>_meta.json (6DOF head pose, camera transform, detection coordinates)
"""

import os
import sys
import glob
import json
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CAPTURES_DIR = os.path.join(SCRIPT_DIR, "captures")
DEVICE_PATH = "/storage/emulated/0/Android/data/com.godot.game/files"

def main():
    os.makedirs(CAPTURES_DIR, exist_ok=True)
    
    device_ip = "192.168.2.23:5555"
    print(f"[1/3] Checking ADB connection to {device_ip}...")
    subprocess.run(["adb", "connect", device_ip], check=False)
    
    print(f"[2/3] Listing bundles on headset...")
    res = subprocess.run(
        ["adb", "-s", device_ip, "shell", f"ls {DEVICE_PATH}/bundle_*"],
        capture_output=True, text=True
    )
    
    if "No such file" in res.stderr or not res.stdout.strip():
        print("No bundles found yet on headset. Squeeze the GRIP button while looking at the ball to capture!")
        return

    files = res.stdout.strip().split()
    print(f"Found {len(files)} bundle files on headset. Pulling...")
    
    subprocess.run(
        ["adb", "-s", device_ip, "pull", f"{DEVICE_PATH}/.", CAPTURES_DIR],
        check=False
    )
    
    meta_files = sorted(glob.glob(os.path.join(CAPTURES_DIR, "bundle_*_meta.json")))
    print(f"\n[3/3] Parsed {len(meta_files)} Calibration Bundles in {CAPTURES_DIR}:\n")
    print(f"{'Bundle ID':<16} | {'Timestamp':<20} | {'Head Position (X,Y,Z)':<26} | {'Ball 3D Pos':<24} | {'Tilt / FOV'}")
    print("-" * 110)
    
    for mf in meta_files:
        try:
            with open(mf, "r") as f:
                data = json.load(f)
            bid = data.get("bundle_id", os.path.basename(mf).split("_")[1])
            ts = data.get("timestamp", "")
            hp = data.get("head_pos", [0, 0, 0])
            bp = data.get("ball_filtered_pos", [0, 0, 0])
            tilt = data.get("camera_optical_tilt_deg", 0)
            vfov = data.get("camera_vfov_deg", 0)
            
            hp_str = f"({hp[0]:.2f}, {hp[1]:.2f}, {hp[2]:.2f})"
            bp_str = f"({bp[0]:.2f}, {bp[1]:.2f}, {bp[2]:.2f})"
            opt_str = f"Tilt:{tilt:.1f}° / VFOV:{vfov:.1f}°"
            
            print(f"{bid:<16} | {ts:<20} | {hp_str:<26} | {bp_str:<24} | {opt_str}")
        except Exception as e:
            print(f"Error reading {mf}: {e}")

if __name__ == "__main__":
    main()
