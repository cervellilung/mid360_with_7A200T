"""Explicit, user-operated checkerboard image collection with a Qt preview."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path


def capture_checkerboard(camera_index: int, output_dir: str | Path,
                         width: int = 640, height: int = 480) -> int:
    import cv2
    from PySide6.QtCore import Qt, QTimer
    from PySide6.QtGui import QImage, QPixmap
    from PySide6.QtWidgets import QApplication, QMainWindow, QWidget, QVBoxLayout, QLabel, QPushButton

    if camera_index < 0:
        raise ValueError("camera index must be explicit and nonnegative")
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    camera = cv2.VideoCapture(camera_index, cv2.CAP_DSHOW if hasattr(cv2, "CAP_DSHOW") else cv2.CAP_ANY)
    if not camera.isOpened():
        raise RuntimeError(f"camera {camera_index} could not be opened")
    camera.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    camera.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    app = QApplication.instance() or QApplication([])
    window = QMainWindow()
    central = QWidget()
    layout = QVBoxLayout(central)
    preview = QLabel()
    preview.setAlignment(Qt.AlignCenter)
    label = QLabel("Move the checkerboard to varied distances and tilts, then Capture (at least 8 views).")
    button = QPushButton("Capture")
    layout.addWidget(preview)
    layout.addWidget(label)
    layout.addWidget(button)
    window.setCentralWidget(central)
    window.setWindowTitle(f"Checkerboard capture: camera {camera_index}")
    frame = [None]
    count = [0]
    timer = QTimer()

    def tick():
        ok, image = camera.read()
        if not ok:
            label.setText("Camera frame unavailable")
            return
        frame[0] = image.copy()
        rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        q = QImage(rgb.data, rgb.shape[1], rgb.shape[0], rgb.strides[0], QImage.Format_RGB888).copy()
        preview.setPixmap(QPixmap.fromImage(q))

    def save():
        if frame[0] is None:
            return
        filename = output / f"checker_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.png"
        if cv2.imwrite(str(filename), frame[0]):
            count[0] += 1
            label.setText(f"Saved {count[0]} views to {output}")
    button.clicked.connect(save)
    timer.timeout.connect(tick)
    timer.start(40)
    window.show()
    try:
        return app.exec()
    finally:
        timer.stop()
        camera.release()
