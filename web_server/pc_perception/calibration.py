"""Offline calibration tools; floating point is confined to this module."""

from __future__ import annotations

from dataclasses import asdict
import json
from math import floor
from pathlib import Path

import numpy as np

from .projection import Calibration, Q16, Q30, Q8


def _cv2():
    try:
        import cv2
    except ImportError as exc:
        raise RuntimeError("OpenCV is required for calibration; install requirements.txt") from exc
    return cv2


def camera_intrinsics(image_paths: list[Path], columns: int, rows: int,
                      square_mm: float) -> dict:
    cv2 = _cv2()
    board = np.zeros((columns*rows, 3), np.float32)
    board[:, :2] = np.mgrid[0:columns, 0:rows].T.reshape(-1, 2) * square_mm
    object_points, image_points = [], []
    size = None
    for path in image_paths:
        frame = cv2.imread(str(path))
        if frame is None:
            continue
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        this_size = (gray.shape[1], gray.shape[0])
        if size is not None and size != this_size:
            raise ValueError("calibration images have different resolutions")
        size = this_size
        ok, corners = cv2.findChessboardCorners(gray, (columns, rows))
        if ok:
            refined = cv2.cornerSubPix(gray, corners, (11, 11), (-1, -1),
                                       (cv2.TERM_CRITERIA_EPS+cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001))
            object_points.append(board)
            image_points.append(refined)
    if len(object_points) < 8 or size is None:
        raise ValueError("at least 8 usable checkerboard views are required")
    rms, matrix, distortion, *_ = cv2.calibrateCamera(object_points, image_points, size, None, None)
    return {"width": size[0], "height": size[1], "camera_matrix": matrix.tolist(),
            "distortion": distortion.reshape(-1).tolist(), "rms_px": float(rms),
            "usable_images": len(object_points)}


def solve_extrinsics(correspondences: list[dict], intrinsic: dict,
                     camera_id: str, mount_id: str, lut_width: int = 33,
                     lut_height: int = 25) -> Calibration:
    """Requires manually checked LiDAR 3D / image 2D matches at varying depths."""
    cv2 = _cv2()
    if len(correspondences) < 8:
        raise ValueError("at least 8 3D-to-2D correspondences are required")
    xyz = np.array([p["lidar_mm"] for p in correspondences], np.float64)
    uv = np.array([p["pixel"] for p in correspondences], np.float64)
    if np.linalg.matrix_rank(xyz-xyz.mean(axis=0)) < 3:
        raise ValueError("3D correspondences must span multiple depths and heights")
    matrix = np.array(intrinsic["camera_matrix"], np.float64)
    distortion = np.array(intrinsic["distortion"], np.float64)
    ok, rvec, tvec, inliers = cv2.solvePnPRansac(
        xyz, uv, matrix, distortion, flags=cv2.SOLVEPNP_EPNP,
        reprojectionError=8.0, iterationsCount=200)
    if not ok or inliers is None or len(inliers) < 6:
        raise ValueError("external calibration did not converge")
    rvec, tvec = cv2.solvePnPRefineLM(xyz[inliers[:, 0]], uv[inliers[:, 0]],
                                       matrix, distortion, rvec, tvec)
    r, _ = cv2.Rodrigues(rvec)
    projected, _ = cv2.projectPoints(xyz, rvec, tvec, matrix, distortion)
    errors = np.linalg.norm(projected.reshape(-1, 2)-uv, axis=1)
    p95 = float(np.percentile(errors, 95))
    width, height = int(intrinsic["width"]), int(intrinsic["height"])
    fx, fy, cx, cy = matrix[0, 0], matrix[1, 1], matrix[0, 2], matrix[1, 2]
    coeff = list(distortion.reshape(-1)) + [0.0]*8
    k1, k2, p1, p2, k3, k4, k5, k6 = coeff[:8]
    du, dv = [], []
    for gy in range(lut_height):
        v = gy*(height-1)/(lut_height-1)
        yn = (v-cy)/fy
        for gx in range(lut_width):
            u = gx*(width-1)/(lut_width-1)
            xn = (u-cx)/fx
            r2 = xn*xn+yn*yn
            radial = (1+k1*r2+k2*r2*r2+k3*r2*r2*r2) / (1+k4*r2+k5*r2*r2+k6*r2*r2*r2)
            xd = xn*radial + 2*p1*xn*yn + p2*(r2+2*xn*xn)
            yd = yn*radial + p1*(r2+2*yn*yn) + 2*p2*xn*yn
            du.append(round((fx*xd+cx-u)*Q8))
            dv.append(round((fy*yd+cy-v)*Q8))
    if max(map(abs, du+dv)) > 32767:
        raise ValueError("distortion exceeds signed 16-bit correction LUT")
    return Calibration(width, height, camera_id, mount_id,
                       tuple(round(float(v)*Q30) for v in r.reshape(-1)),
                       tuple(round(float(v)) for v in tvec.reshape(-1)),
                       round(float(fx)*Q16), round(float(fy)*Q16),
                       round(float(cx)*Q16), round(float(cy)*Q16),
                       lut_width, lut_height, tuple(du), tuple(dv), p95,
                       bool(p95 <= 20.0 and len(inliers) >= 6))


def fit_ground_plane(points_mm: np.ndarray, up_z_sign: int = 1) -> dict:
    pts = np.asarray(points_mm, np.float64)
    if len(pts) < 20:
        raise ValueError("at least 20 selected ground points are required")
    centroid = pts.mean(axis=0)
    _, _, vh = np.linalg.svd(pts-centroid, full_matrices=False)
    normal = vh[-1]
    if normal[2]*up_z_sign < 0:
        normal *= -1
    residual = np.abs((pts-centroid) @ normal)
    if float(np.percentile(residual, 95)) > 30:
        raise ValueError("ground points are not on one plane within 30 mm")
    return {"plane_nx_q30": round(float(normal[0])*Q30),
            "plane_ny_q30": round(float(normal[1])*Q30),
            "plane_nz_q30": round(float(normal[2])*Q30),
            "plane_d_mm": round(float(-normal @ centroid)),
            "residual_p95_mm": float(np.percentile(residual, 95))}


def estimate_time_offset(pairs: list[dict]) -> dict:
    """Device-to-host receive-clock anchor; network delay remains in residual."""
    if len(pairs) < 20:
        raise ValueError("at least 20 timestamp pairs are required")
    differences = np.asarray([int(p["host_ns"])-int(p["device_ns"]) for p in pairs], np.int64)
    baseline = int(np.median(differences))
    return {"host_minus_device_ns": baseline,
            "jitter_p95_ns": int(np.percentile(np.abs(differences-baseline), 95)),
            "pairs": len(pairs)}


def save_calibration(cal: Calibration, path: str | Path) -> None:
    Path(path).write_text(json.dumps(asdict(cal), indent=2), encoding="utf-8")
