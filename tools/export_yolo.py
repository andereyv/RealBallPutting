import sys
from ultralytics import YOLO

print("Loading YOLOv8 nano model...")
model = YOLO("yolov8n.pt")

print("Exporting to ONNX format (320x320)...")
path = model.export(format="onnx", imgsz=320, simplify=True, dynamic=False)
print("Exported successfully to:", path)
