"""Small monitoring UI; never opens hardware on import."""

from __future__ import annotations

import sys
import time


def run_ui(source, pipeline, title: str = "MID-360 PC prototype",
           radar_only: bool = False) -> int:
    from PySide6.QtCore import QTimer, Qt
    from PySide6.QtGui import QImage, QPixmap
    from PySide6.QtWidgets import QApplication, QHBoxLayout, QLabel, QMainWindow, QPushButton, QVBoxLayout, QWidget

    app = QApplication.instance() or QApplication(sys.argv)
    window = QMainWindow()
    window.setWindowTitle(title)
    root = QWidget()
    layout = QVBoxLayout(root)
    images = QHBoxLayout()
    video_label, bev_label = QLabel(), QLabel()
    for label in ((bev_label,) if radar_only else (video_label, bev_label)):
        label.setAlignment(Qt.AlignCenter)
        images.addWidget(label)
    layout.addLayout(images)
    status_label = QLabel("Waiting for data")
    layout.addWidget(status_label)
    pause = QPushButton("Pause")
    layout.addWidget(pause)
    window.setCentralWidget(root)
    window.resize(680 if radar_only else 1250, 700)

    paused = False
    def toggle():
        nonlocal paused
        paused = not paused
        pause.setText("Resume" if paused else "Pause")
    pause.clicked.connect(toggle)

    def set_image(label, bgr):
        from cv2 import cvtColor, COLOR_BGR2RGB
        rgb = cvtColor(bgr, COLOR_BGR2RGB)
        img = QImage(rgb.data, rgb.shape[1], rgb.shape[0], rgb.strides[0], QImage.Format_RGB888).copy()
        label.setPixmap(QPixmap.fromImage(img).scaled(620, 620, Qt.KeepAspectRatio))

    timer = QTimer()
    def tick():
        if not paused:
            for event in source.poll():
                pipeline.ingest(event)
        video, bev, state = pipeline.render(time.monotonic_ns())
        if not radar_only:
            set_image(video_label, video)
        set_image(bev_label, bev)
        stats = state["stats"]
        nearest = min((d.distance_mm for d in pipeline.tracks), default=None) if state["radar_ok"] else None
        nearest_text = "none" if nearest is None else f"{nearest/1000:.2f}m"
        radar_state = "STARTING" if state.get("radar_starting") else ("OK" if state["radar_ok"] else "NO DATA")
        status_label.setText(
            f"Radar packets {stats['radar_packets']}  Bad {stats['bad_radar_packets']}  "
            f"Scans {stats['scans']}  Camera {stats['camera_frames']}  Odom {stats['odom_frames']}  "
            f"Radar {radar_state}  Age {state['scan_age_ms']} ms  Nearest {nearest_text}  "
            f"{'CALIBRATED' if state['calibrated'] else 'HUD ONLY'}")
        if getattr(source, "finished", False):
            timer.stop()
            pipeline.finish()
    timer.timeout.connect(tick)
    timer.start(40)
    window.show()
    try:
        return app.exec()
    finally:
        timer.stop()
        source.close()
        pipeline.finish()
