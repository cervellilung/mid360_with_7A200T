"""Manual static-scene 3D/2D correspondences and ground-point picker."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from .frame import FrameAssembler
from .protocol import PacketError, decode_mid360
from .session import CAMERA, RADAR, SessionReader
from .sources import decode_camera


def _load_scene(directory: Path):
    assembler = FrameAssembler()
    camera = scan = None
    for event in SessionReader(directory):
        if event.kind == CAMERA and camera is None:
            camera = decode_camera(event.payload)
        if event.kind == RADAR:
            try:
                finished = assembler.add(decode_mid360(event.payload, event.host_ns))
            except PacketError:
                continue
            if finished is not None:
                scan = finished.points
        if camera is not None and scan is not None:
            return camera, scan
    last = assembler.flush()
    if camera is None or (scan is None and last is None):
        raise ValueError(f"{directory}: needs a camera frame and a radar scan")
    return camera, scan if scan is not None else last.points


def run_picker(sessions: list[Path], matches_out: Path, ground_out: Path) -> int:
    import cv2
    from PySide6.QtCore import Qt, Signal
    from PySide6.QtGui import QImage, QPixmap
    from PySide6.QtWidgets import (QApplication, QHBoxLayout, QLabel, QMainWindow,
                                   QPushButton, QVBoxLayout, QWidget)

    class ClickLabel(QLabel):
        clicked = Signal(int, int)
        def mousePressEvent(self, event):
            self.clicked.emit(int(event.position().x()), int(event.position().y()))

    app = QApplication.instance() or QApplication([])
    window = QMainWindow()
    root = QWidget()
    outer = QVBoxLayout(root)
    row = QHBoxLayout()
    image_label, bev_label = ClickLabel(), ClickLabel()
    row.addWidget(image_label)
    row.addWidget(bev_label)
    outer.addLayout(row)
    message = QLabel("Click a camera feature and the matching occupied LiDAR cell, then Add match.")
    outer.addWidget(message)
    controls = QHBoxLayout()
    add_match = QPushButton("Add match")
    add_ground = QPushButton("Add ground point")
    next_scene = QPushButton("Next recording")
    save = QPushButton("Save")
    for button in (add_match, add_ground, next_scene, save):
        controls.addWidget(button)
    outer.addLayout(controls)
    window.setCentralWidget(root)
    window.setWindowTitle("Static LiDAR / camera calibration picker")
    matches = json.loads(matches_out.read_text(encoding="utf-8")) if matches_out.exists() else []
    ground = json.loads(ground_out.read_text(encoding="utf-8")) if ground_out.exists() else []
    current = [0]
    chosen_pixel = [None]
    chosen_point = [None]
    chosen_ground = [None]
    scene = [None, None]

    def show_bgr(label, bgr):
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        q = QImage(rgb.data, rgb.shape[1], rgb.shape[0], rgb.strides[0], QImage.Format_RGB888).copy()
        label.setPixmap(QPixmap.fromImage(q))
        label.setFixedSize(rgb.shape[1], rgb.shape[0])

    def load_current():
        camera, points = _load_scene(sessions[current[0]])
        scene[:] = [camera, points]
        show_bgr(image_label, camera)
        occupancy = np.zeros((60, 55), np.uint8)
        for p in points:
            x, y = int(p["x"]), int(p["y"])
            if 500 <= x < 6000 and -3000 <= y < 3000:
                row, col = (y+3000)//100, (x-500)//100
                occupancy[row, col] = min(255, int(occupancy[row, col])+30)
        bev = cv2.resize(cv2.applyColorMap(occupancy, cv2.COLORMAP_TURBO),
                         (550, 600), interpolation=cv2.INTER_NEAREST)
        show_bgr(bev_label, bev)
        chosen_pixel[0] = chosen_point[0] = None
        message.setText(f"{sessions[current[0]].name} ({current[0]+1}/{len(sessions)}) | "
                        f"{len(matches)} matches, {len(ground)} ground points")

    def image_clicked(x, y):
        if scene[0] is not None and 0 <= x < scene[0].shape[1] and 0 <= y < scene[0].shape[0]:
            chosen_pixel[0] = [x, y]
            message.setText(f"Image pixel {chosen_pixel[0]}; select the corresponding LiDAR cell")

    def bev_clicked(x, y):
        if not 0 <= x < 550 or not 0 <= y < 600:
            return
        col, row = x//10, y//10
        selected = [p for p in scene[1]
                    if 500 <= int(p["x"]) < 6000 and -3000 <= int(p["y"]) < 3000
                    and (int(p["x"])-500)//100 == col and (int(p["y"])+3000)//100 == row]
        if selected:
            xyz = [[int(p[k]) for k in ("x", "y", "z")] for p in selected]
            chosen_point[0] = [int(v) for v in np.median(xyz, axis=0)]
            chosen_ground[0] = min(xyz, key=lambda row: row[2])
            message.setText(f"LiDAR point {chosen_point[0]}; image pixel {chosen_pixel[0]}")
        else:
            message.setText("No point in that LiDAR cell")

    def add_correspondence():
        if chosen_pixel[0] is None or chosen_point[0] is None:
            message.setText("Select both an image pixel and a LiDAR cell first")
            return
        matches.append({"lidar_mm": chosen_point[0], "pixel": chosen_pixel[0],
                        "session": sessions[current[0]].name})
        message.setText(f"Added match {len(matches)}")

    def add_ground_point():
        if chosen_point[0] is None:
            message.setText("Select a LiDAR ground cell first")
            return
        ground.append(chosen_ground[0])
        message.setText(f"Added ground point {len(ground)}")

    def save_all():
        matches_out.parent.mkdir(parents=True, exist_ok=True)
        ground_out.parent.mkdir(parents=True, exist_ok=True)
        matches_out.write_text(json.dumps(matches, indent=2), encoding="utf-8")
        ground_out.write_text(json.dumps(ground, indent=2), encoding="utf-8")
        message.setText(f"Saved {len(matches)} matches and {len(ground)} ground points")

    image_label.clicked.connect(image_clicked)
    bev_label.clicked.connect(bev_clicked)
    add_match.clicked.connect(add_correspondence)
    add_ground.clicked.connect(add_ground_point)
    next_scene.clicked.connect(lambda: (current.__setitem__(0, (current[0]+1)%len(sessions)), load_current()))
    save.clicked.connect(save_all)
    load_current()
    window.show()
    return app.exec()
