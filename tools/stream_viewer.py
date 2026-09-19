#!/usr/bin/env python3
"""
Stream Viewer & Recorder for Quest 3 Stereo Camera Feed
Connects to http://localhost:8080/stereo or /status and displays live feed.
Keys:
  's': Capture and save snapshot pair to disk
  'r': Toggle video recording to mp4
  'q' or ESC: Quit viewer
"""

import cv2
import urllib.request
import numpy as np
import time
import sys
import os

STREAM_URL = "http://localhost:8080/stereo"
STATUS_URL = "http://localhost:8080/status"

def main():
    print(f"🎬 Connecting to Quest 3 live stream at {STREAM_URL}...")
    print("👉 Controls: [S] Snapshot | [R] Record Video | [Q] Quit")
    
    try:
        stream = urllib.request.urlopen(STREAM_URL, timeout=5)
    except Exception as e:
        print(f"❌ Could not connect to stream at {STREAM_URL}: {e}")
        print("💡 Make sure ADB port forwarding is active: adb forward tcp:8080 tcp:8080")
        sys.exit(1)

    bytes_data = b""
    recording = False
    video_writer = None
    save_dir = os.path.expanduser("~/RealBallCaptures")
    os.makedirs(save_dir, exist_ok=True)

    while True:
        try:
            bytes_data += stream.read(4096)
            a = bytes_data.find(b"\xff\xd8") # JPEG start
            b = bytes_data.find(b"\xff\xd9") # JPEG end

            if a != -1 and b != -1:
                jpg = bytes_data[a:b+2]
                bytes_data = bytes_data[b+2:]
                frame = cv2.imdecode(np.frombuffer(jpg, dtype=np.uint8), cv2.IMREAD_COLOR)

                if frame is not None:
                    h, w, _ = frame.shape
                    
                    if recording:
                        if video_writer is None:
                            filename = os.path.join(save_dir, f"session_{int(time.time())}.mp4")
                            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
                            video_writer = cv2.VideoWriter(filename, fourcc, 30.0, (w, h))
                            print(f"🔴 Recording started: {filename}")
                        video_writer.write(frame)
                        cv2.circle(frame, (30, 30), 10, (0, 0, 255), -1)
                        cv2.putText(frame, "REC", (50, 38), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

                    cv2.imshow("Quest 3 Stereo Stream (Press 'q' to quit)", frame)

                key = cv2.waitKey(1) & 0xFF
                if key == ord("q") or key == 27:
                    break
                elif key == ord("s"):
                    snap_path = os.path.join(save_dir, f"snap_{int(time.time()*1000)}.jpg")
                    cv2.imwrite(snap_path, frame)
                    print(f"📸 Saved snapshot to {snap_path}")
                elif key == ord("r"):
                    recording = not recording
                    if not recording and video_writer is not None:
                        video_writer.release()
                        video_writer = None
                        print("⏹️ Recording saved.")

        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Stream error: {e}")
            break

    if video_writer is not None:
        video_writer.release()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
