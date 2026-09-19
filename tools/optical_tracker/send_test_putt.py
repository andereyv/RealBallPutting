#!/usr/bin/env python3
"""
Test utility to broadcast optical tracking UDP payloads to Godot.
Target: 127.0.0.1:4242
"""

import socket
import json
import time
import sys

UDP_IP = "127.0.0.1"
UDP_PORT = 4242

def send_payload(data: dict):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    message = json.dumps(data).encode("utf-8")
    sock.sendto(message, (UDP_IP, UDP_PORT))
    print(f"[Sender] Transmitted to {UDP_IP}:{UDP_PORT} -> {data}")

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "reset":
        send_payload({"command": "reset"})
        return

    speed = float(sys.argv[1]) if len(sys.argv) > 1 else 2.35 # m/s
    angle = float(sys.argv[2]) if len(sys.argv) > 2 else -0.8 # deg (slight left)

    payload = {
        "type": "launch",
        "speed_mps": speed,
        "angle_deg": angle,
        "confidence": 0.97
    }
    send_payload(payload)

if __name__ == "__main__":
    main()
