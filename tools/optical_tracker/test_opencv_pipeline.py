#!/usr/bin/env python3
"""
OpenCV High-Speed Putting Corridor Benchmark
Tests classical computer vision (frame differencing + contour analysis)
on real high-speed Quest 3 headset camera frames from actual putting tests.
"""

import cv2
import numpy as np
import glob
import time
import os

def run_benchmark():
    captures_dir = "tools/optical_tracker/captures/test_2342/files"
    if not os.path.exists(captures_dir):
        print(f"Error: Directory {captures_dir} not found.")
        return

    # 1. Load Pre-Stroke Frames (Baseline Floor)
    pre_frames = [
        os.path.join(captures_dir, "stroke_seq_pre_0.jpg"),
        os.path.join(captures_dir, "stroke_seq_pre_1.jpg"),
        os.path.join(captures_dir, "stroke_seq_pre_2.jpg")
    ]
    pre_imgs = [cv2.imread(f, cv2.IMREAD_GRAYSCALE) for f in pre_frames if os.path.exists(f)]
    if not pre_imgs:
        print("Error: No pre-stroke frames found.")
        return

    # Compute median/mean background
    bg_frame = np.median(pre_imgs, axis=0).astype(np.uint8)
    h, w = bg_frame.shape

    # 2. Define Putting Corridor ROI (Zone B: forward putting area)
    # The golfer putts towards the left (X: 0.10 to 0.50, Y: 0.45 to 0.75)
    roi_x1, roi_x2 = int(0.12 * w), int(0.50 * w)
    roi_y1, roi_y2 = int(0.48 * h), int(0.72 * h)
    bg_roi = bg_frame[roi_y1:roi_y2, roi_x1:roi_x2]

    # 3. Load Stroke Sequence Frames in chronological order
    stroke_files = [os.path.join(captures_dir, f"stroke_seq_{i}.jpg") for i in range(12)]
    stroke_files = [f for f in stroke_files if os.path.exists(f)]

    print(f"Loaded {len(stroke_files)} stroke frames. Running OpenCV pipeline...")

    latencies_us = []
    tracked_points = []
    annotated_frames = []

    for idx, fpath in enumerate(stroke_files):
        t0 = time.perf_counter_ns()
        
        # Load frame (simulate 8-bit grayscale tracking camera buffer)
        frame = cv2.imread(fpath, cv2.IMREAD_GRAYSCALE)
        frame_roi = frame[roi_y1:roi_y2, roi_x1:roi_x2]

        # A. Classical Difference against floor baseline
        diff = cv2.absdiff(frame_roi, bg_roi)

        # B. Adaptive / Otsu or thresholding
        _, thresh = cv2.threshold(diff, 20, 255, cv2.THRESH_BINARY)

        # C. Morphological cleaning (remove sensor shot noise)
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        clean = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, kernel)

        # D. Contour detection & circular blob filter
        contours, _ = cv2.findContours(clean, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        
        best_center = None
        best_score = 0.0

        for c in contours:
            area = cv2.contourArea(c)
            # Golf ball blob size filter (expected ~30 to 1500 px at this distance)
            if 30 <= area <= 1500:
                perimeter = cv2.arcLength(c, True)
                if perimeter > 0:
                    circularity = 4 * np.pi * (area / (perimeter * perimeter))
                    if circularity > 0.45:
                        M = cv2.moments(c)
                        if M["m00"] > 0:
                            cx = int(M["m10"] / M["m00"]) + roi_x1
                            cy = int(M["m01"] / M["m00"]) + roi_y1
                            score = circularity * area
                            if score > best_score:
                                best_score = score
                                (x_circ, y_circ), radius = cv2.minEnclosingCircle(c)
                                best_center = (cx, cy, int(radius))

        t1 = time.perf_counter_ns()
        latency_us = (t1 - t0) / 1000.0
        latencies_us.append(latency_us)

        if best_center is not None:
            tracked_points.append({
                "frame_idx": idx,
                "x": best_center[0],
                "y": best_center[1],
                "radius": best_center[2],
                "norm_x": best_center[0] / w,
                "norm_y": best_center[1] / h,
                "latency_us": latency_us
            })
            print(f"  Frame #{idx:02d}: Detected Ball at ({best_center[0]}, {best_center[1]}) | r={best_center[2]}px | Latency: {latency_us:.1f} us ({latency_us/1000.0:.2f} ms)")
        else:
            print(f"  Frame #{idx:02d}: No moving blob | Latency: {latency_us:.1f} us ({latency_us/1000.0:.2f} ms)")

    avg_latency_ms = (np.mean(latencies_us) / 1000.0) if latencies_us else 0.0
    max_latency_ms = (np.max(latencies_us) / 1000.0) if latencies_us else 0.0

    print("\n--- OpenCV Benchmark Results ---")
    print(f"Frames processed: {len(stroke_files)}")
    print(f"Ball detections:  {len(tracked_points)} / {len(stroke_files)}")
    print(f"Average Latency:  {avg_latency_ms:.2f} ms (equivalent to {1000.0/max(avg_latency_ms, 0.001):.0f} FPS throughput)")
    print(f"Maximum Latency:  {max_latency_ms:.2f} ms")

    # 4. Generate Output Visual Validation Image
    out_img = cv2.imread(stroke_files[0]) # Start with address/impact frame
    
    # Draw Corridor ROI boundary (Orange)
    cv2.rectangle(out_img, (roi_x1, roi_y1), (roi_x2, roi_y2), (0, 165, 255), 2)
    cv2.putText(out_img, "OpenCV Corridor (Zone B)", (roi_x1 + 6, roi_y1 - 8),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 165, 255), 2)

    # Plot tracked trajectory
    prev_pt = None
    colors = [
        (0, 255, 255), # Yellow
        (0, 255, 128), # Light Green
        (0, 255, 0),   # Green
        (255, 255, 0), # Cyan
        (255, 128, 0), # Blue-Orange
        (255, 0, 128)  # Purple
    ]

    for i, pt in enumerate(tracked_points):
        curr = (pt["x"], pt["y"])
        c_color = colors[i % len(colors)]
        cv2.circle(out_img, curr, max(8, pt["radius"]), c_color, 2)
        cv2.circle(out_img, curr, 2, (0, 0, 255), -1)
        if prev_pt is not None:
            cv2.line(out_img, prev_pt, curr, (255, 255, 255), 2)
        prev_pt = curr
        cv2.putText(out_img, f"#{pt['frame_idx']}", (curr[0] + 8, curr[1] - 6),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, c_color, 1)

    # Add header badge
    cv2.rectangle(out_img, (8, 8), (560, 50), (15, 20, 28), -1)
    cv2.rectangle(out_img, (8, 8), (560, 50), (0, 210, 255), 2)
    badge_text = f"OpenCV Benchmark: {len(tracked_points)} frames tracked | Avg Latency: {avg_latency_ms:.2f}ms"
    cv2.putText(out_img, badge_text, (16, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 200), 2)

    output_path = "tools/optical_tracker/captures/opencv_benchmark_result.jpg"
    cv2.imwrite(output_path, out_img)
    print(f"\nResult image saved to: {output_path}")

if __name__ == "__main__":
    run_benchmark()
