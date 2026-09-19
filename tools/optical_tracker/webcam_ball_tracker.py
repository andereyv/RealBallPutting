#!/usr/bin/env python3
"""
Optical Real-Ball Tracking Prototype via OpenCV & UDP
Hardened for patterned rugs, floor glare, and indoor lighting.
"""

import cv2
import numpy as np
import socket
import json
import time
import argparse

try:
    from ultralytics import YOLO
    HAVE_YOLO = True
except ImportError:
    HAVE_YOLO = False

DEFAULT_UDP_IP = "127.0.0.1"
DEFAULT_UDP_PORT = 4242
GOLF_BALL_DIAMETER_METERS = 0.04267

class OpticalBallTracker:
    def __init__(self, camera_index=0, mock_mode=False, target_dir="DOWN", speed_mult=2.0, udp_ip=DEFAULT_UDP_IP, udp_port=DEFAULT_UDP_PORT):
        self.camera_index = camera_index
        self.mock_mode = mock_mode
        self.target_dir = target_dir.upper()
        dir_angles = {"DOWN": 0.0, "RIGHT": 90.0, "UP": 180.0, "LEFT": 270.0}
        self.target_angle_deg = dir_angles.get(self.target_dir, 0.0)
        self.udp_ip = udp_ip
        self.udp_port = udp_port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        
        self.state = "SEARCHING"
        self.address_pos = None
        self.tee_pos = None
        self.address_radius = 14.0
        self.lock_counter = 0
        self.missing_frames = 0
        self.frame_counter = 0
        
        self.yolo_model = None
        if HAVE_YOLO:
            try:
                print("[OpticalTracker] Initializing YOLOv8n for AI Address Detection...")
                self.yolo_model = YOLO("yolov8n.pt")
                print("[OpticalTracker] YOLOv8n initialized successfully!")
            except Exception as e:
                print(f"[OpticalTracker] Note: Could not initialize YOLO: {e}")
        
        self.tracked_candidates = []
        self.launch_history = []
        self.cooldown_timer = 0.0
        
        self.meters_per_pixel = 0.0014
        self.speed_multiplier = speed_mult
        self.last_address_time = time.time()
        
        self.last_shot = None
        self.last_trail = None

    def send_udp(self, payload: dict):
        try:
            message = json.dumps(payload).encode("utf-8")
            self.sock.sendto(message, (self.udp_ip, self.udp_port))
            print(f"[UDP Sent -> {self.udp_ip}:{self.udp_port}] -> {payload}")
        except Exception as e:
            print(f"[UDP Error] {e}")

    def on_mouse(self, event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN:
            self.launch_history = []
            self.missing_frames = 0
            
            best_c = None
            best_dist = 60.0
            for c in self.tracked_candidates:
                d = np.hypot(c["pos"][0] - x, c["pos"][1] - y)
                if d < best_dist:
                    best_dist = d
                    best_c = c
                    
            if best_c is not None:
                self.address_pos = (best_c["pos"][0], best_c["pos"][1])
                self.address_radius = best_c["radius"]
            else:
                self.address_pos = (float(x), float(y))
                self.address_radius = 14.0

            self.tee_pos = (self.address_pos[0], self.address_pos[1])
            self.state = "AT_ADDRESS"
            self.meters_per_pixel = GOLF_BALL_DIAMETER_METERS / (self.address_radius * 2.0)
            self.send_udp({"type": "ready", "meters_per_pixel": self.meters_per_pixel})
            print(f"[Tracker] Locked at ({self.address_pos[0]:.1f}, {self.address_pos[1]:.1f})")

    def isolate_ball_mask(self, bgr_frame):
        """Filters frame for high-brightness golf ball pixels, allowing for webcam indoor white-balance tint."""
        hsv = cv2.cvtColor(bgr_frame, cv2.COLOR_BGR2HSV)
        # Golf ball under indoor webcam auto-white balance has V >= 140 and S up to 160 (cool blue/cyan tint)
        lower_white = np.array([0, 0, 140])
        upper_white = np.array([180, 160, 255])
        mask = cv2.inRange(hsv, lower_white, upper_white)
        
        # Clean small noise specks
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
        return mask

    def find_ball_in_mask(self, mask, offset_x=0, offset_y=0, min_radius=8, max_radius=25):
        """Finds circular contours matching golf ball dimensions and roundness."""
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        candidates = []
        
        for cnt in contours:
            area = cv2.contourArea(cnt)
            min_area = np.pi * (min_radius ** 2) * 0.55
            max_area = np.pi * (max_radius ** 2) * 1.45
            
            if min_area <= area <= max_area:
                perimeter = cv2.arcLength(cnt, True)
                if perimeter > 0:
                    circularity = 4 * np.pi * (area / (perimeter * perimeter))
                    # Golf ball is round (> 0.74 rejects rugs, putters, ruler stripes, and floor lines)
                    if circularity >= 0.74:
                        (cx, cy), radius = cv2.minEnclosingCircle(cnt)
                        candidates.append((cx + offset_x, cy + offset_y, radius, circularity))
                        
        candidates.sort(key=lambda item: item[3], reverse=True)
        return [(c[0], c[1], c[2]) for c in candidates]

    def track_in_local_roi(self, frame, center_x, center_y, roi_size=80):
        h, w = frame.shape[:2]
        x0 = max(0, int(center_x - roi_size // 2))
        x1 = min(w, int(center_x + roi_size // 2))
        y0 = max(0, int(center_y - roi_size // 2))
        y1 = min(h, int(center_y + roi_size // 2))
        
        sub = frame[y0:y1, x0:x1]
        if sub.size == 0 or sub.shape[0] < 15 or sub.shape[1] < 15:
            return None
            
        mask = self.isolate_ball_mask(sub)
        candidates = self.find_ball_in_mask(mask, offset_x=x0, offset_y=y0)
        
        if len(candidates) > 0:
            # Return candidate closest to expected center
            return min(candidates, key=lambda c: np.hypot(c[0] - center_x, c[1] - center_y))
        return None

    def find_forward_ball(self, frame, ax, ay, max_forward=320, corridor_width=60):
        """Looks exclusively in a restricted forward corridor in the stroke direction."""
        rad = np.radians(self.target_angle_deg)
        u_fwd = np.array([np.sin(rad), np.cos(rad)])
        u_lat = np.array([np.cos(rad), -np.sin(rad)])
        
        # Calculate bounding box encompassing only the forward corridor
        h, w = frame.shape[:2]
        p_front = np.array([ax, ay]) + u_fwd * max_forward
        p_left = np.array([ax, ay]) + u_lat * corridor_width
        p_right = np.array([ax, ay]) - u_lat * corridor_width
        
        xs = [ax, p_front[0], p_left[0], p_right[0], p_front[0] + u_lat[0] * corridor_width, p_front[0] - u_lat[0] * corridor_width]
        ys = [ay, p_front[1], p_left[1], p_right[1], p_front[1] + u_lat[1] * corridor_width, p_front[1] - u_lat[1] * corridor_width]
        
        x0 = max(0, int(min(xs)))
        x1 = min(w, int(max(xs)))
        y0 = max(0, int(min(ys)))
        y1 = min(h, int(max(ys)))
        
        sub = frame[y0:y1, x0:x1]
        if sub.size == 0:
            return None
            
        mask = self.isolate_ball_mask(sub)
        candidates = self.find_ball_in_mask(mask, offset_x=x0, offset_y=y0)
        
        valid = []
        for c in candidates:
            dx = c[0] - ax
            dy = c[1] - ay
            proj_fwd = dx * u_fwd[0] + dy * u_fwd[1]
            proj_lat = abs(dx * u_lat[0] + dy * u_lat[1])
            if 15.0 <= proj_fwd <= max_forward and proj_lat <= corridor_width:
                valid.append((c[0], c[1], c[2], proj_fwd))
                
        if len(valid) == 0:
            return None
        # Ball is furthest along forward path
        best = max(valid, key=lambda item: item[3])
        return (best[0], best[1], best[2], best[3])

    def run_webcam_mode(self):
        cap = cv2.VideoCapture(self.camera_index)
        cap.set(cv2.CAP_PROP_FPS, 60)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        
        if not cap.isOpened():
            print(f"[Error] Camera {self.camera_index} failed to open.")
            return

        window_name = "Optical Ball Tracker - Golf Sim"
        cv2.namedWindow(window_name)
        cv2.setMouseCallback(window_name, self.on_mouse)

        while True:
            ret, frame = cap.read()
            if not ret:
                break
                
            self.frame_counter += 1
            now = time.time()
            h, w = frame.shape[:2]

            # -------------------------------------------------------------
            # SEARCHING (HYBRID CONTOUR + YOLO AI)
            # -------------------------------------------------------------
            if self.state == "SEARCHING":
                raw_candidates = []
                
                # Fast contour detection every frame (0.5ms)
                mask = self.isolate_ball_mask(frame)
                raw_candidates.extend(self.find_ball_in_mask(mask))
                
                # Periodic YOLOv8n inference (every 6 frames ~ 0.1s)
                if self.yolo_model is not None and (self.frame_counter % 6 == 0):
                    try:
                        res = self.yolo_model(frame, imgsz=1024, conf=0.08, classes=[32], verbose=False)
                        for r in res:
                            for box in r.boxes:
                                x1, y1, x2, y2 = [float(v) for v in box.xyxy[0]]
                                cx, cy = (x1 + x2) / 2.0, (y1 + y2) / 2.0
                                r_val = max(x2 - x1, y2 - y1) / 2.0
                                if 8.0 <= r_val <= 26.0:
                                    raw_candidates.append((cx, cy, r_val))
                    except Exception:
                        pass
                
                updated = []
                for rc in raw_candidates:
                    matched = False
                    for tc in self.tracked_candidates:
                        if np.hypot(rc[0] - tc["pos"][0], rc[1] - tc["pos"][1]) < 10.0:
                            tc["pos"] = (tc["pos"][0] * 0.8 + rc[0] * 0.2, tc["pos"][1] * 0.8 + rc[1] * 0.2)
                            tc["frames"] += 1
                            updated.append(tc)
                            matched = True
                            break
                    if not matched:
                        updated.append({"pos": (rc[0], rc[1]), "radius": rc[2], "frames": 1})
                self.tracked_candidates = updated
                
                best_cand = None
                max_f = 0
                for c in self.tracked_candidates:
                    cv2.circle(frame, (int(c["pos"][0]), int(c["pos"][1])), int(c["radius"] + 3), (0, 165, 255), 1)
                    if c["frames"] > max_f:
                        max_f = c["frames"]
                        best_cand = c
                        
                if best_cand is not None and best_cand["frames"] >= 10:
                    self.address_pos = (best_cand["pos"][0], best_cand["pos"][1])
                    self.tee_pos = (self.address_pos[0], self.address_pos[1])
                    self.address_radius = best_cand["radius"]
                    self.state = "AT_ADDRESS"
                    self.meters_per_pixel = GOLF_BALL_DIAMETER_METERS / (self.address_radius * 2.0)
                    self.send_udp({"type": "ready", "meters_per_pixel": self.meters_per_pixel})
                else:
                    cv2.putText(frame, "SEARCHING... (Click on ball to lock instantly)", 
                                (20, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 165, 255), 2)

            # -------------------------------------------------------------
            # WAITING FOR BALL (STRICT TEE ROI)
            # -------------------------------------------------------------
            elif self.state == "WAITING_FOR_BALL":
                tx, ty = self.tee_pos
                cv2.circle(frame, (int(tx), int(ty)), int(self.address_radius + 6), (0, 180, 255), 2)
                cv2.putText(frame, "RE-SPOT BALL IN TEE CIRCLE", (20, 35), 
                            cv2.FONT_HERSHEY_SIMPLEX, 0.75, (0, 180, 255), 2)
                
                local_ball = self.track_in_local_roi(frame, tx, ty, roi_size=90)
                if local_ball is not None:
                    self.lock_counter += 1
                    cv2.circle(frame, (int(local_ball[0]), int(local_ball[1])), int(local_ball[2] + 3), (0, 255, 200), 2)
                    if self.lock_counter >= 5:
                        self.address_pos = (local_ball[0], local_ball[1])
                        self.address_radius = local_ball[2]
                        self.state = "AT_ADDRESS"
                        self.lock_counter = 0
                        self.missing_frames = 0
                        self.last_address_time = now
                        self.send_udp({"type": "ready", "meters_per_pixel": self.meters_per_pixel})
                else:
                    self.lock_counter = 0

            # -------------------------------------------------------------
            # AT ADDRESS
            # -------------------------------------------------------------
            elif self.state == "AT_ADDRESS":
                ax, ay = self.address_pos
                local_ball = self.track_in_local_roi(frame, ax, ay, roi_size=80)
                rad = np.radians(self.target_angle_deg)
                
                if local_ball is not None:
                    fwd_disp = (local_ball[0] - ax) * np.sin(rad) + (local_ball[1] - ay) * np.cos(rad)
                    if fwd_disp > 16.0:
                        self.state = "LAUNCH_TRACKING"
                        prev_time = self.last_address_time if self.last_address_time > 0 else (now - 0.02)
                        self.launch_history = [(ax, ay, prev_time), (local_ball[0], local_ball[1], now)]
                    else:
                        self.missing_frames = 0
                        self.last_address_time = now
                        self.address_pos = (ax * 0.9 + local_ball[0] * 0.1, ay * 0.9 + local_ball[1] * 0.1)
                else:
                    fwd_ball = self.find_forward_ball(frame, ax, ay, max_forward=250)
                    if fwd_ball is not None and 18.0 <= fwd_ball[3] <= 220.0:
                        self.state = "LAUNCH_TRACKING"
                        prev_time = self.last_address_time if self.last_address_time > 0 else (now - 0.02)
                        self.launch_history = [(ax, ay, prev_time), (fwd_ball[0], fwd_ball[1], now)]
                    else:
                        self.missing_frames += 1
                        if self.missing_frames >= 4:
                            self.state = "WAITING_FOR_BALL" if self.tee_pos else "SEARCHING"
                            self.address_pos = None
                            self.missing_frames = 0

                # Target guide graphics
                arrow_dx = 70.0 * np.sin(rad)
                arrow_dy = 70.0 * np.cos(rad)
                cv2.arrowedLine(frame, (int(ax), int(ay)), (int(ax + arrow_dx), int(ay + arrow_dy)), (0, 255, 200), 2)
                cv2.circle(frame, (int(ax), int(ay)), int(self.address_radius + 4), (0, 255, 0), 2)
                cv2.putText(frame, "BALL LOCKED - READY TO STRIKE!", (20, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (0, 255, 0), 2)

            # -------------------------------------------------------------
            # LAUNCH TRACKING
            # -------------------------------------------------------------
            elif self.state == "LAUNCH_TRACKING":
                ax, ay = self.launch_history[0][:2]
                fwd_ball = self.find_forward_ball(frame, ax, ay, max_forward=380)
                if fwd_ball is not None:
                    self.launch_history.append((fwd_ball[0], fwd_ball[1], now))
                    cv2.circle(frame, (int(fwd_ball[0]), int(fwd_ball[1])), 15, (0, 255, 255), 2)
                    
                if len(self.launch_history) >= 3:
                    p0 = self.launch_history[0]
                    p_end = self.launch_history[-1]
                    dt = p_end[2] - p0[2]
                    
                    raw_dx = p_end[0] - p0[0]
                    raw_dy = p_end[1] - p0[1]
                    rad = np.radians(self.target_angle_deg)
                    
                    fwd_px = raw_dx * np.sin(rad) + raw_dy * np.cos(rad)
                    lat_px = -(raw_dx * np.cos(rad) - raw_dy * np.sin(rad))
                    
                    if dt > 0.015 and np.hypot(raw_dx, raw_dy) > (self.address_radius * 1.3):
                        v_fwd = ((fwd_px * self.meters_per_pixel) / dt) * self.speed_multiplier
                        v_lat = ((lat_px * self.meters_per_pixel) / dt) * self.speed_multiplier
                        speed_mps = float(np.hypot(v_fwd, v_lat))
                        
                        if 0.40 <= speed_mps <= 8.5:
                            angle_deg = float(np.degrees(np.arctan2(v_lat, max(v_fwd, 0.001))))
                            payload = {
                                "type": "launch",
                                "speed_mps": round(speed_mps, 2),
                                "angle_deg": round(angle_deg, 1),
                                "confidence": 0.99
                            }
                            self.send_udp(payload)
                            self.last_shot = payload
                            self.last_trail = (p0, p_end)
                            self.state = "COOLDOWN"
                            self.cooldown_timer = now + 2.5
                        else:
                            self.state = "WAITING_FOR_BALL" if self.tee_pos else "SEARCHING"
                            self.address_pos = None
                    else:
                        self.state = "WAITING_FOR_BALL" if self.tee_pos else "SEARCHING"
                        self.address_pos = None

            # -------------------------------------------------------------
            # COOLDOWN
            # -------------------------------------------------------------
            elif self.state == "COOLDOWN":
                if now > self.cooldown_timer:
                    self.state = "WAITING_FOR_BALL" if self.tee_pos else "SEARCHING"
                    self.address_pos = None
                    self.missing_frames = 0
                    
                if self.last_shot is not None:
                    spd = self.last_shot['speed_mps']
                    ang = self.last_shot['angle_deg']
                    msg = f"SHOT: {spd:.2f} m/s ({spd * 2.237:.1f} mph) | Angle: {ang:+.1f} deg"
                    cv2.putText(frame, msg, (20, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
                    if self.last_trail is not None:
                        p0, p1 = self.last_trail
                        cv2.arrowedLine(frame, (int(p0[0]), int(p0[1])), (int(p1[0]), int(p1[1])), (0, 255, 255), 3)

            # Bottom HUD status
            hud_text = f"Speed Multiplier: {self.speed_multiplier:.2f}x ([W]+ / [S]-) | [C]: Clear | [R]: Reset Godot"
            cv2.putText(frame, hud_text, (20, h - 18), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (200, 200, 200), 1)

            cv2.imshow(window_name, frame)
            key = cv2.waitKey(1) & 0xFF
            if key == ord('q') or key == 27:
                break
            elif key == ord('w') or key == ord('W'):
                self.speed_multiplier = round(min(5.0, self.speed_multiplier + 0.10), 2)
                print(f"[Tracker] Speed multiplier: {self.speed_multiplier:.2f}x")
            elif key == ord('s') or key == ord('S'):
                self.speed_multiplier = round(max(0.5, self.speed_multiplier - 0.10), 2)
                print(f"[Tracker] Speed multiplier: {self.speed_multiplier:.2f}x")
            elif key == ord('c') or key == ord('C'):
                self.address_pos = None
                self.tee_pos = None
                self.state = "SEARCHING"
                self.tracked_candidates = []
            elif key == ord('r') or key == ord('R'):
                self.send_udp({"command": "reset"})

        cap.release()
        cv2.destroyAllWindows()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Optical Real-Ball Putting Tracker")
    parser.add_argument("--ip", type=str, default="127.0.0.1", help="Target UDP IP (e.g. 192.168.x.x for Quest Wi-Fi or 127.0.0.1 for local)")
    parser.add_argument("--port", type=int, default=4242, help="Target UDP port (default: 4242)")
    parser.add_argument("--cam", type=int, default=0, help="Webcam device index (default: 0)")
    parser.add_argument("--dir", type=str, choices=["DOWN", "UP", "LEFT", "RIGHT"], default="DOWN", help="Putting direction on screen")
    parser.add_argument("--speed", type=float, default=2.0, help="Perspective speed multiplier (default: 2.0)")
    args = parser.parse_args()
    OpticalBallTracker(camera_index=args.cam, target_dir=args.dir, speed_mult=args.speed, udp_ip=args.ip, udp_port=args.port).run_webcam_mode()