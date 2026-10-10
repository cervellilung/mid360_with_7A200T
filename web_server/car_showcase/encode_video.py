"""Encode 120 browser frames as a 20-second 24 fps MP4 using installed OpenCV."""

from pathlib import Path
import cv2

ROOT = Path(__file__).resolve().parents[2] / "sample" / "car_showcase"
images = sorted((ROOT / "output" / "video_frames").glob("frame_*.png"))
if len(images) != 120:
    raise SystemExit(f"need 120 captured frames; found {len(images)}")
first = cv2.imread(str(images[0]))
if first is None:
    raise SystemExit("cannot read first frame")
height, width = first.shape[:2]
out = ROOT / "output" / "rotation_demo_20s.mp4"
writer = cv2.VideoWriter(str(out), cv2.VideoWriter_fourcc(*"mp4v"), 24, (width, height))
if not writer.isOpened():
    raise SystemExit("OpenCV MP4 encoder unavailable")
for image_path in images:
    frame = cv2.imread(str(image_path))
    if frame is None or frame.shape[:2] != (height, width):
        writer.release()
        raise SystemExit(f"invalid frame: {image_path}")
    for _ in range(4):
        writer.write(frame)
writer.release()
print(f"{out} {width}x{height} 24 fps 20 s")
