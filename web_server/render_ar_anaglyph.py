"""Render a red/cyan AR overlay from a real M3CP recording, entirely offline.

Input is one recording directory written by pc/record.py: radar on stream_1,
USB camera on stream_2, both stamped with the board's capture clock so they can
be aligned in time. For a set of camera frames this produces:

  * a plain 2-D AR overlay - the camera image with the accumulated MID-360
    points projected into it, coloured by range, plus the nearest obstacle in
    each image column annotated with its measured distance;
  * a red/cyan anaglyph of the same scene, where every AR element carries the
    disparity implied by its measured range (pc_perception/anaglyph.py), so
    viewing it through anaglyph glasses puts the AR layer at its real depth.

Nothing is written outside the output directory and no input file is touched.

Usage:
  python render_ar_anaglyph.py --recording <session dir> --out <output dir>
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT.parent))

from ar_render.m3cp_recording import CAMERA, RADAR, StreamFile, read_camera_meta
from pc_perception.anaglyph import DisparityModel, DEFAULT_BASELINE_MM, DEFAULT_FX_PX, \
    DEFAULT_MAX_PX, DEFAULT_ZERO_PARALLAX_MM, Q16
from pc_perception.protocol import PacketError, decode_mid360
from pc_perception.projection import Q30, Calibration, project_point


def assumed_calibration(width: int, height: int, fx_px: float,
                        roll_deg: float = 0.0, pitch_deg: float = 0.0,
                        yaw_deg: float = 0.0) -> Calibration:
    """Co-located forward-facing mount, no lens distortion.

    There is no calibration file for this rig yet, so the extrinsic starts from
    the pure axis convention between the two sensors (LiDAR x forward / y left /
    z up vs camera x right / y down / z forward) and the principal point is the
    image centre. The three angles then rotate the camera frame on top of that,
    which is what is needed when the camera is mounted upside down relative to
    the LiDAR. This is the dominant uncertainty in the overlay, so it is isolated
    here: a measured calibration can replace the whole function.
    """
    # row-major, LiDAR -> camera for a level, upright camera
    base = np.array([[0.0, -1.0, 0.0],
                     [0.0, 0.0, -1.0],
                     [1.0, 0.0, 0.0]])
    roll, pitch, yaw = np.radians([roll_deg, pitch_deg, yaw_deg])
    rotate_z = np.array([[np.cos(roll), -np.sin(roll), 0.0],
                         [np.sin(roll), np.cos(roll), 0.0],
                         [0.0, 0.0, 1.0]])
    rotate_x = np.array([[1.0, 0.0, 0.0],
                         [0.0, np.cos(pitch), -np.sin(pitch)],
                         [0.0, np.sin(pitch), np.cos(pitch)]])
    rotate_y = np.array([[np.cos(yaw), 0.0, np.sin(yaw)],
                         [0.0, 1.0, 0.0],
                         [-np.sin(yaw), 0.0, np.cos(yaw)]])
    rotation = rotate_z @ rotate_x @ rotate_y @ base
    return Calibration(
        width=width, height=height,
        camera_id=f"uvc-{width}x{height}",
        mount_id=f"assumed-colocated-r{roll_deg:g}p{pitch_deg:g}y{yaw_deg:g}",
        r_q30=tuple(int(round(v * Q30)) for v in rotation.reshape(-1)),
        t_mm=(0, 0, 0),
        fx_q16=int(fx_px * Q16), fy_q16=int(fx_px * Q16),
        cx_q16=int(width * Q16 // 2), cy_q16=int(height * Q16 // 2),
        lut_width=2, lut_height=2,
        distortion_du_q8=(0, 0, 0, 0), distortion_dv_q8=(0, 0, 0, 0),
        reprojection_p95_px=0.0, valid=True,
    )


def yuyv_to_bgr(raw: bytes, width: int, height: int, stride: int) -> np.ndarray:
    """YUYV -> BGR using the same BT.601 limited-range maths as the board's C code.

    OpenCV's COLOR_YUV2BGR_YUYV expects a particular 2-channel packing that does
    not match a plain 1280-byte row, so the conversion is done explicitly.
    """
    row_bytes = width * 2
    packed = np.frombuffer(raw, np.uint8, count=stride * height).reshape(height, stride)
    packed = packed[:, :row_bytes]
    luma = packed[:, 0::2].astype(np.int32)
    blue_diff = np.repeat(packed[:, 1::4].astype(np.int32), 2, axis=1)
    red_diff = np.repeat(packed[:, 3::4].astype(np.int32), 2, axis=1)
    c, d, e = luma - 16, blue_diff - 128, red_diff - 128
    red = np.clip((298 * c + 409 * e + 128) >> 8, 0, 255)
    green = np.clip((298 * c - 100 * d - 208 * e + 128) >> 8, 0, 255)
    blue = np.clip((298 * c + 516 * d + 128) >> 8, 0, 255)
    return np.stack([blue, green, red], axis=2).astype(np.uint8)


def rotate_image(image: np.ndarray, degrees: int) -> np.ndarray:
    """Turn an upside-down sensor back the right way up.

    The UVC module on this rig is mounted inverted (confirmed by comparing the
    recorded frame against a 180-degree rotation), so the frame is rotated here
    rather than compensated in the extrinsic. Rotating the image by 180 is
    equivalent to negating both camera axes, which leaves the base LiDAR-to-
    camera axis convention unchanged - so --roll-deg stays at 0.
    """
    if degrees == 180:
        return cv2.rotate(image, cv2.ROTATE_180)
    return image


from web_server.car_showcase.source import collect_points


def forward_cone(cloud_mm: np.ndarray, half_angle_deg: float) -> np.ndarray:
    """Mask of points inside a forward cone.

    The MID-360 scans a full sphere while the camera sees a narrow forward cone,
    so most points can be discarded before the (Python-side) projection.
    """
    x = cloud_mm[:, 0].astype(np.float64)
    y = cloud_mm[:, 1].astype(np.float64)
    z = cloud_mm[:, 2].astype(np.float64)
    return (x > 0) & (np.sqrt(y * y + z * z) <= x * np.tan(np.radians(half_angle_deg)))


def project_cloud(cloud_mm: np.ndarray, calibration: Calibration) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Project points, returning only those that land inside the image."""
    keep_u, keep_v, keep_r = [], [], []
    for x, y, z in cloud_mm:
        pixel = project_point((int(x), int(y), int(z)), calibration)
        if pixel is None:
            continue
        keep_u.append(pixel[0])
        keep_v.append(pixel[1])
        keep_r.append(float(np.sqrt(float(x) ** 2 + float(y) ** 2 + float(z) ** 2)) / 1000.0)
    return (np.asarray(keep_u, np.int32), np.asarray(keep_v, np.int32),
            np.asarray(keep_r, np.float32))


def paint(canvas: np.ndarray, us: np.ndarray, vs: np.ndarray,
          colours: np.ndarray, radius: int = 1) -> None:
    """Stamp square dots; vectorised over the point list."""
    height, width = canvas.shape[:2]
    for dy in range(-radius, radius + 1):
        rows = vs + dy
        inside_y = (rows >= 0) & (rows < height)
        for dx in range(-radius, radius + 1):
            cols = us + dx
            inside = inside_y & (cols >= 0) & (cols < width)
            canvas[rows[inside], cols[inside]] = colours[inside]


def range_colours(ranges: np.ndarray, near: float = 0.6, far: float = 8.0) -> np.ndarray:
    """Near objects red, far objects blue, so range reads without labels."""
    t = np.clip((ranges - near) / max(1e-6, far - near), 0.0, 1.0)
    blue = (t * 255.0).astype(np.uint8)
    red = ((1.0 - t) * 255.0).astype(np.uint8)
    green = (60.0 * (1.0 - np.abs(t - 0.5) * 2.0)).astype(np.uint8)
    return np.stack([blue, green, red], axis=1)


def risk_colour(distance_m: float) -> tuple[int, int, int]:
    if distance_m < 1.5:
        return (0, 0, 255)
    if distance_m < 3.0:
        return (0, 210, 255)
    return (0, 200, 0)


def annotate_columns(canvas_width: int, us: np.ndarray, vs: np.ndarray, ranges: np.ndarray,
                     columns: int, max_range_m: float, min_range_m: float) -> list[dict]:
    """Nearest obstacle per image column, as boxes to be drawn by either renderer.

    ``min_range_m`` skips the sensor's own mount: a fixed return a few tens of
    centimetres in front of the LiDAR would otherwise win every column and make
    the distance labels useless.
    """
    annotations: list[dict] = []
    for column in range(columns):
        x0 = int(column * canvas_width / columns)
        x1 = int((column + 1) * canvas_width / columns)
        inside = (us >= x0) & (us < x1) & (ranges <= max_range_m) & (ranges >= min_range_m)
        if inside.sum() < 6:
            continue
        nearest = float(ranges[inside].min())
        hit = inside & (ranges <= nearest + 0.6)
        anchor = int(np.argmin(np.where(hit, ranges, np.inf)))
        # Keep the box local to the nearest return rather than spanning the column.
        local = hit & (np.abs(us - int(us[anchor])) <= 70)
        if local.sum() < 3:
            local = hit
        usel, vsel = us[local], vs[local]
        annotations.append({
            "column": column,
            "distance_m": round(nearest, 2),
            "box": [int(max(0, usel.min()) - 4), int(max(0, vsel.min()) - 4),
                    int(usel.max() + 4), int(vsel.max() + 4)],
            "anchor": [int(us[anchor]), int(vs[anchor])],
        })
    return annotations


def draw_labels(canvas: np.ndarray, annotations: list[dict], offset_fn=None) -> None:
    for item in annotations:
        box = item["box"]
        x, y = box[0], box[1]
        if offset_fn is not None:
            x += offset_fn(item)
        text = f"{item['distance_m']:.1f} m"
        scale, thickness = 0.55, 1
        (tw, th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, thickness)
        top = max(0, y - th - 8)
        cv2.rectangle(canvas, (x, top), (x + tw + 8, top + th + 8), (0, 0, 0), -1)
        cv2.putText(canvas, text, (x + 4, top + th + 2),
                    cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), thickness, cv2.LINE_AA)


def render_2d(bgr: np.ndarray, us: np.ndarray, vs: np.ndarray, ranges: np.ndarray,
              annotations: list[dict], hud: str,
              near_m: float = 0.6, far_m: float = 8.0) -> np.ndarray:
    canvas = bgr.copy()
    if len(us):
        overlay = canvas.copy()
        paint(overlay, us, vs, range_colours(ranges, near_m, far_m), radius=1)
        canvas = cv2.addWeighted(overlay, 0.85, canvas, 0.15, 0.0)
    for item in annotations:
        x0, y0, x1, y1 = item["box"]
        cv2.rectangle(canvas, (x0, y0), (x1, y1), risk_colour(item["distance_m"]), 2)
    draw_labels(canvas, annotations)
    _draw_hud(canvas, hud)
    return canvas


def render_anaglyph(bgr: np.ndarray, us: np.ndarray, vs: np.ndarray, ranges: np.ndarray,
                    annotations: list[dict], model: DisparityModel, hud: str,
                    max_points: int = 700) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Left eye -> red channel, right eye -> green+blue.

    The camera image is identical in both eyes (flat and neutral); only the AR
    elements move, so their separation is the depth cue. The cloud is thinned
    hard: thousands of dots at a 10-plus pixel separation read as confetti,
    whereas a few hundred bigger dots fuse into single points at depth.
    """
    base = cv2.cvtColor(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY), cv2.COLOR_GRAY2BGR)
    left = base.copy()
    right = base.copy()
    if len(us):
        step = max(1, len(us) // max(1, max_points))
        us, vs, ranges = us[::step], vs[::step], ranges[::step]
        disparity_px = np.asarray([model.disparity_px(int(r * 1000.0)) for r in ranges], np.float32)
        half = np.round(disparity_px * 0.5).astype(np.int32)
        white = np.full((len(us), 3), 255, np.uint8)
        paint(left, us + half, vs, white, radius=2)
        paint(right, us - half, vs, white, radius=2)
    for item in annotations:
        half = int(round(model.disparity_px(int(item["distance_m"] * 1000.0)) * 0.5))
        x0, y0, x1, y1 = item["box"]
        colour = risk_colour(item["distance_m"])
        cv2.rectangle(left, (x0 + half, y0), (x1 + half, y1), colour, 2)
        cv2.rectangle(right, (x0 - half, y0), (x1 - half, y1), colour, 2)
    draw_labels(left, annotations)
    draw_labels(right, annotations)
    _draw_hud(left, hud)
    _draw_hud(right, hud)
    out = np.empty_like(base)
    out[:, :, 0] = right[:, :, 0]
    out[:, :, 1] = right[:, :, 1]
    out[:, :, 2] = left[:, :, 2]
    return out, left, right


def _draw_hud(canvas: np.ndarray, text: str) -> None:
    if not text:
        return
    cv2.rectangle(canvas, (0, 0), (canvas.shape[1], 26), (0, 0, 0), -1)
    cv2.putText(canvas, text, (8, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                (255, 255, 255), 1, cv2.LINE_AA)


def build_surface(cloud_mm: np.ndarray, az_limit_deg: float, el_min_deg: float,
                  el_max_deg: float, bin_deg: float, fx_px: float,
                  median_k: int = 5, upsample: int = 4, blur_sigma: float = 0.0,
                  texture_deg: float = 4.0) -> tuple[np.ndarray, np.ndarray, int]:
    """Turn a point cloud into a shaded surface by angular neighbourhood.

    A MID-360 cell gives points that are regular in (azimuth, elevation), so
    binning them into that grid and connecting neighbours *is* the mesh: every
    bin holds a range, and adjacent bins are adjacent on the surface. Bins with
    no return are filled from their neighbours (normalised box blur), which is
    what "just assume it is a surface" means here - no image is consulted.

    Returns (points_mm, shade, splat_radius_px).
    """
    x = cloud_mm[:, 0].astype(np.float64)
    y = cloud_mm[:, 1].astype(np.float64)
    z = cloud_mm[:, 2].astype(np.float64)
    radius = np.sqrt(x * x + y * y + z * z)
    azimuth = np.degrees(np.arctan2(y, x))
    elevation = np.degrees(np.arctan2(z, np.sqrt(x * x + y * y)))

    inside = ((radius > 0) & (np.abs(azimuth) <= az_limit_deg)
              & (elevation >= el_min_deg) & (elevation <= el_max_deg))
    columns = max(2, int(round(2 * az_limit_deg / bin_deg)))
    rows = max(2, int(round((el_max_deg - el_min_deg) / bin_deg)))
    if not inside.any():
        return np.zeros((0, 3), np.int64), np.zeros(0, np.uint8), 1

    column = np.clip(((azimuth[inside] + az_limit_deg) / (2 * az_limit_deg)
                      * columns).astype(np.int32), 0, columns - 1)
    row = np.clip(((elevation[inside] - el_min_deg) / (el_max_deg - el_min_deg)
                   * rows).astype(np.int32), 0, rows - 1)
    values = radius[inside]
    # Nearest return wins: write far first so near overwrites.
    order = np.argsort(-values)
    grid = np.full((rows, columns), np.nan)
    grid[row[order], column[order]] = values[order]

    # Fill empty bins from their neighbours so the surface is continuous.
    weight = cv2.blur(np.isfinite(grid).astype(np.float32), (5, 5))
    filled = cv2.blur(np.nan_to_num(grid).astype(np.float32), (5, 5))
    grid = np.where(weight > 1e-6, filled / np.maximum(weight, 1e-6), 0.0).astype(np.float32)
    covered = weight > 1e-6

    # A median pass removes the isolated long/short returns that show up as
    # burrs. Interpolating onto a finer grid then turns coarse bins into a smooth
    # dense mesh rather than one blocky patch per bin, which is where the
    # staircase edge in the first attempt came from.
    if median_k >= 3:
        grid = cv2.medianBlur(grid, median_k)
    if blur_sigma > 0:
        grid = cv2.GaussianBlur(grid, (0, 0), blur_sigma)
    if upsample > 1:
        size = (columns * upsample, rows * upsample)
        grid = cv2.resize(grid, size, interpolation=cv2.INTER_LINEAR)
        covered = cv2.resize(covered.astype(np.float32), size,
                             interpolation=cv2.INTER_LINEAR) > 0.5
        columns, rows = size
    grid = np.where(covered, grid, np.nan)

    azimuth_centre = np.radians(-az_limit_deg + (np.arange(columns) + 0.5)
                                * (2 * az_limit_deg / columns))
    elevation_centre = np.radians(el_min_deg + (np.arange(rows) + 0.5)
                                  * ((el_max_deg - el_min_deg) / rows))
    az_grid, el_grid = np.meshgrid(azimuth_centre, elevation_centre)
    points = np.stack([grid * np.cos(el_grid) * np.cos(az_grid),
                       grid * np.cos(el_grid) * np.sin(az_grid),
                       grid * np.sin(el_grid)], axis=2)

    # Normals from the grid tangents, then one Lambert term.
    along_az = np.full_like(points, np.nan)
    along_az[:, 1:-1] = points[:, 2:] - points[:, :-2]
    along_el = np.full_like(points, np.nan)
    along_el[1:-1, :] = points[2:, :] - points[:-2, :]
    normal = np.cross(along_az, along_el)
    length = np.linalg.norm(normal, axis=2, keepdims=True)
    normal = np.divide(normal, length, out=np.zeros_like(normal), where=length > 0)
    # The cross product can point either way; make it face back at the sensor so
    # the light term means "how directly does this patch look at the viewer".
    towards_sensor = -points
    flipped = np.nansum(normal * towards_sensor, axis=2) < 0
    normal = np.where(flipped[:, :, None], -normal, normal)
    light = np.array([-0.45, -0.50, 0.74])
    light /= np.linalg.norm(light)
    lambert = np.clip((normal * light).sum(axis=2), 0.0, 1.0)
    shade = np.where(np.isfinite(lambert), 70.0 + 185.0 * lambert, 90.0).astype(np.float32)
    # Feather the shading too: without this a single-bin outlier still shows up
    # as a bright speck even after the range image itself has been smoothed.
    shade = cv2.GaussianBlur(shade, (0, 0), max(0.6, upsample * 0.6))
    # A flat, smooth surface is nearly identical in both eyes except for its
    # outline, so an anaglyph of it barely reads as 3D. A checkered pattern in
    # angular space puts high frequency texture on every patch, which makes the
    # per-patch shift visible across the whole surface instead of only at edges.
    if texture_deg > 0:
        cell = max(1, int(round(texture_deg / (bin_deg / max(1, upsample)))))
        rows_index = (np.arange(rows) // cell)[:, None]
        columns_index = (np.arange(columns) // cell)[None, :]
        light_cell = ((rows_index + columns_index) % 2) == 0
        shade = np.where(light_cell, shade, shade * 0.30 + 18.0)
    shade = np.clip(shade, 0.0, 255.0).astype(np.uint8)
    keep = np.isfinite(grid)

    splat = max(1, int(round(fx_px * np.radians(bin_deg / max(1, upsample)) * 0.9)))
    flat_points = points[keep]
    flat_shade = shade[keep]
    finite = np.isfinite(flat_points).all(axis=1)
    return np.rint(flat_points[finite]).astype(np.int64), flat_shade[finite], splat


def render_anaglyph_surface(cloud_mm: np.ndarray, calibration: Calibration,
                            model: DisparityModel, annotations: list[dict], hud: str,
                            shape: tuple[int, int, int], bin_deg: float, fx_px: float,
                            az_limit_deg: float, el_min_deg: float, el_max_deg: float,
                            median_k: int = 5, upsample: int = 4,
                            blur_sigma: float = 0.0, texture_deg: float = 4.0
                            ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Red/cyan view of the point cloud as a shaded surface, with no camera image.

    Each surface patch is drawn at the pixel pair implied by its own measured
    range, so the whole surface takes on the disparity of its true depth and
    reads as a solid object through anaglyph glasses.
    """
    height, width = shape[0], shape[1]
    points, shade, splat = build_surface(cloud_mm, az_limit_deg, el_min_deg,
                                         el_max_deg, bin_deg, fx_px,
                                         median_k, upsample, blur_sigma, texture_deg)
    left = np.zeros((height, width, 3), np.uint8)
    right = np.zeros((height, width, 3), np.uint8)
    depth_left = np.full((height, width), np.inf, np.float64)
    depth_right = np.full((height, width), np.inf, np.float64)

    if len(points):
        rotation = np.asarray(calibration.r_q30, np.float64).reshape(3, 3) / float(Q30)
        translation = np.asarray(calibration.t_mm, np.float64)
        camera_z = (points.astype(np.float64) @ rotation.T + translation)[:, 2]
        ranges_mm = np.linalg.norm(points.astype(np.float64), axis=1)

        us = np.empty(len(points), np.int32)
        vs = np.empty(len(points), np.int32)
        visible = np.zeros(len(points), bool)
        for index in range(len(points)):
            pixel = project_point((int(points[index, 0]), int(points[index, 1]),
                                   int(points[index, 2])), calibration)
            if pixel is None:
                continue
            us[index], vs[index] = pixel
            visible[index] = True
        us, vs = us[visible], vs[visible]
        depth = camera_z[visible]
        colour = np.repeat(shade[visible, None], 3, axis=1)
        disparity = np.asarray([model.disparity_px(int(r)) for r in ranges_mm[visible]], np.float32)
        half = np.round(disparity * 0.5).astype(np.int32)

        _splat(left, depth_left, us + half, vs, depth, colour, splat)
        _splat(right, depth_right, us - half, vs, depth, colour, splat)

    draw_surface_annotations(left, annotations, model)
    draw_surface_annotations(right, annotations, model)
    draw_labels(left, annotations)
    draw_labels(right, annotations)
    _draw_hud(left, hud)
    _draw_hud(right, hud)

    out = np.empty((height, width, 3), np.uint8)
    out[:, :, 0] = right[:, :, 0]
    out[:, :, 1] = right[:, :, 1]
    out[:, :, 2] = left[:, :, 2]
    return out, left, right


def _splat(canvas: np.ndarray, depth_buffer: np.ndarray, us: np.ndarray, vs: np.ndarray,
           depth: np.ndarray, colour: np.ndarray, radius: int) -> None:
    """Draw overlapping discs with a z-buffer so nearer surface wins."""
    height, width = depth_buffer.shape
    for dy in range(-radius, radius + 1):
        rows = vs + dy
        inside_y = (rows >= 0) & (rows < height)
        for dx in range(-radius, radius + 1):
            if dx * dx + dy * dy > radius * radius:
                continue
            cols = us + dx
            inside = inside_y & (cols >= 0) & (cols < width)
            if not inside.any():
                continue
            rows_in, cols_in = rows[inside], cols[inside]
            depth_in, colour_in = depth[inside], colour[inside]
            current = depth_buffer[rows_in, cols_in]
            closer = depth_in < current
            depth_buffer[rows_in[closer], cols_in[closer]] = depth_in[closer]
            canvas[rows_in[closer], cols_in[closer]] = colour_in[closer]


def draw_surface_annotations(canvas: np.ndarray, annotations: list[dict],
                             model: DisparityModel) -> None:
    for item in annotations:
        half = int(round(model.disparity_px(int(item["distance_m"] * 1000.0)) * 0.5))
        x0, y0, x1, y1 = item["box"]
        cv2.rectangle(canvas, (x0 + half, y0), (x1 + half, y1),
                      risk_colour(item["distance_m"]), 2)


def pick_frames(total: int, wanted: int) -> list[int]:
    if total <= wanted:
        return list(range(total))
    return [int(round(v)) for v in np.linspace(0, total - 1, wanted)]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--recording", required=True, help="session directory with stream_1/2.bin")
    parser.add_argument("--out", help="output directory (created if missing); "
                                      "not needed with --save-camera-frame")
    parser.add_argument("--save-camera-frame", metavar="PATH",
                        help="write one camera frame with no overlay to PATH and exit")
    parser.add_argument("--camera-frame-index", type=int, default=0,
                        help="which camera record --save-camera-frame writes")
    parser.add_argument("--frames", type=int, default=40, help="how many camera frames to render")
    parser.add_argument("--half-window-ms", type=float, default=80.0,
                        help="radar accumulation half window around each camera frame")
    parser.add_argument("--min-range-m", type=float, default=0.3)
    parser.add_argument("--max-range-m", type=float, default=12.0)
    parser.add_argument("--fov-cone-deg", type=float, default=60.0,
                        help="half angle of the forward cone kept before projection")
    parser.add_argument("--max-points", type=int, default=20000)
    parser.add_argument("--fx-px", type=float, default=float(DEFAULT_FX_PX))
    parser.add_argument("--rotate-image-deg", type=int, default=180, choices=(0, 180),
                        help="rotate the camera frame before overlaying; the UVC module "
                             "on this rig is mounted upside down, hence 180")
    parser.add_argument("--roll-deg", type=float, default=0.0,
                        help="camera roll relative to the LiDAR, after --rotate-image-deg")
    parser.add_argument("--pitch-deg", type=float, default=0.0)
    parser.add_argument("--yaw-deg", type=float, default=0.0)
    parser.add_argument("--colour-near-m", type=float, default=0.0,
                        help="near end of the range colour ramp; 0 adapts to the frame")
    parser.add_argument("--colour-far-m", type=float, default=0.0,
                        help="far end of the range colour ramp; 0 adapts to the frame")
    parser.add_argument("--baseline-mm", type=int, default=DEFAULT_BASELINE_MM)
    parser.add_argument("--zero-parallax-mm", type=int, default=DEFAULT_ZERO_PARALLAX_MM)
    parser.add_argument("--max-disparity-px", type=int, default=DEFAULT_MAX_PX)
    parser.add_argument("--anaglyph-mode", choices=("camera", "surface"), default="surface",
                        help="'surface' renders the cloud as a shaded mesh with no camera "
                             "image; 'camera' keeps the desaturated camera frame behind it")
    parser.add_argument("--surface-bin-deg", type=float, default=0.9,
                        help="angular bin size of the range image that forms the mesh")
    parser.add_argument("--surface-upsample", type=int, default=4,
                        help="interpolate the range image onto a finer grid before meshing")
    parser.add_argument("--surface-median", type=int, default=5,
                        help="median kernel on the range image; removes single-bin spikes")
    parser.add_argument("--surface-blur-sigma", type=float, default=0.0,
                        help="extra Gaussian smoothing of the range image")
    parser.add_argument("--surface-texture-deg", type=float, default=4.0,
                        help="checker cell size on the surface; 0 for untextured shading. "
                             "Flat shading gives almost no red/cyan separation except at "
                             "the silhouette, so a pattern is what makes depth visible")
    parser.add_argument("--surface-az-limit-deg", type=float, default=65.0)
    parser.add_argument("--surface-el-min-deg", type=float, default=-30.0)
    parser.add_argument("--surface-el-max-deg", type=float, default=45.0)
    parser.add_argument("--anaglyph-max-points", type=int, default=700,
                        help="cloud points kept in the anaglyph; dense dots do not fuse")
    parser.add_argument("--columns", type=int, default=3, help="obstacle annotation columns")
    parser.add_argument("--annotate-min-range-m", type=float, default=0.6,
                        help="ignore returns nearer than this when labelling obstacles")
    parser.add_argument("--save-eye-pairs", action="store_true",
                        help="also write the separate left/right eye images so a "
                             "wiggle stereo clip can be built for viewing without glasses")
    parser.add_argument("--seed", type=int, default=20260929)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    recording = Path(args.recording)
    out = Path(args.out) if args.out else None
    if out is None and not args.save_camera_frame:
        raise SystemExit("--out is required unless --save-camera-frame is given")

    radar = StreamFile(recording / "stream_1.bin")
    camera = StreamFile(recording / "stream_2.bin")
    if sorted(radar.kinds) != [RADAR]:
        raise SystemExit(f"stream_1.bin is not a radar stream: kinds={sorted(radar.kinds)}")
    if sorted(camera.kinds) != [CAMERA]:
        raise SystemExit(f"stream_2.bin is not a camera stream: kinds={sorted(camera.kinds)}")

    if args.save_camera_frame:
        index = max(0, min(len(camera) - 1, args.camera_frame_index))
        frame_meta, raw = read_camera_meta(camera.payload(index))
        plain = yuyv_to_bgr(raw, frame_meta.width, frame_meta.height, frame_meta.stride)
        plain = rotate_image(plain, args.rotate_image_deg)
        target = Path(args.save_camera_frame)
        target.parent.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(target), plain)
        print(f"camera frame {index} of {len(camera)} -> {target}")
        return 0

    (out / "ar_2d").mkdir(parents=True, exist_ok=True)
    anaglyph_dir = out / ("anaglyph_surface" if args.anaglyph_mode == "surface"
                          else "anaglyph_camera")
    anaglyph_dir.mkdir(parents=True, exist_ok=True)
    eye_left_dir = out / "eye_left"
    eye_right_dir = out / "eye_right"
    if args.save_eye_pairs:
        eye_left_dir.mkdir(parents=True, exist_ok=True)
        eye_right_dir.mkdir(parents=True, exist_ok=True)

    first_meta, _ = read_camera_meta(camera.payload(0))
    calibration = assumed_calibration(first_meta.width, first_meta.height, args.fx_px,
                                      args.roll_deg, args.pitch_deg, args.yaw_deg)
    model = DisparityModel(baseline_mm=args.baseline_mm, fx_q16=int(args.fx_px * Q16),
                           zero_parallax_mm=args.zero_parallax_mm,
                           max_q8=args.max_disparity_px * 8)
    rng = np.random.default_rng(args.seed)
    half_us = int(args.half_window_ms * 1000)

    print(f"recording   : {recording}")
    print(f"camera      : {first_meta.width}x{first_meta.height} stride={first_meta.stride}, "
          f"{len(camera)} frames")
    print(f"radar       : {len(radar)} packets, {radar.duration_s():.1f}s")
    print(f"assumed cal : fx={args.fx_px:.0f}px, baseline={args.baseline_mm}mm, "
          f"zero-parallax={args.zero_parallax_mm}mm, clamp={args.max_disparity_px}px")

    chosen = pick_frames(len(camera), args.frames)
    frame_reports: list[dict] = []
    sheets: list[np.ndarray] = []
    started = time.time()

    for order, index in enumerate(chosen):
        entry = camera.entries[index]
        frame_meta, raw = read_camera_meta(camera.payload(index))
        needed = frame_meta.stride * frame_meta.height
        if (len(raw) < needed or frame_meta.width != calibration.width
                or frame_meta.height != calibration.height):
            continue
        bgr = yuyv_to_bgr(raw, frame_meta.width, frame_meta.height, frame_meta.stride)
        bgr = rotate_image(bgr, args.rotate_image_deg)

        cloud, decoded, bad = collect_points(radar, entry.capture_us, half_us)
        spans = np.sqrt((cloud.astype(np.float64) ** 2).sum(axis=1)) / 1000.0 if len(cloud) else np.zeros(0)
        keep = ((spans >= args.min_range_m) & (spans <= args.max_range_m)
                & forward_cone(cloud, args.fov_cone_deg))
        selected = cloud[keep]
        if args.max_points and len(selected) > args.max_points:
            selected = selected[rng.choice(len(selected), args.max_points, replace=False)]
        us, vs, ranges = project_cloud(selected, calibration)
        annotations = annotate_columns(frame_meta.width, us, vs, ranges, args.columns,
                                       args.max_range_m, args.annotate_min_range_m)

        nearest = float(ranges.min()) if len(ranges) else float("nan")
        hud = (f"MID-360+UVC | t={entry.capture_us / 1e6:.1f}s | pts={len(ranges)} | "
               f"near={nearest:.2f}m")
        # A stationary scene sits in a narrow range band, so a fixed ramp would
        # collapse to one colour; adapt to each frame unless overridden.
        near_m = args.colour_near_m or (float(np.percentile(ranges, 10)) if len(ranges) else 0.6)
        far_m = args.colour_far_m or (float(np.percentile(ranges, 90)) if len(ranges) else 8.0)
        if far_m <= near_m:
            far_m = near_m + 1.0
        overlay = render_2d(bgr, us, vs, ranges, annotations, hud, near_m, far_m)
        if args.anaglyph_mode == "surface":
            anaglyph, eye_left, eye_right = render_anaglyph_surface(
                selected, calibration, model, annotations, hud, bgr.shape,
                args.surface_bin_deg, args.fx_px, args.surface_az_limit_deg,
                args.surface_el_min_deg, args.surface_el_max_deg,
                args.surface_median, args.surface_upsample, args.surface_blur_sigma,
                args.surface_texture_deg)
        else:
            anaglyph, eye_left, eye_right = render_anaglyph(
                bgr, us, vs, ranges, annotations, model, hud, args.anaglyph_max_points)

        name = f"frame_{order:03d}_t{entry.capture_us // 1000:08d}.png"
        cv2.imwrite(str(out / "ar_2d" / name), overlay)
        cv2.imwrite(str(anaglyph_dir / name), anaglyph)
        if args.save_eye_pairs:
            cv2.imwrite(str(eye_left_dir / name), eye_left)
            cv2.imwrite(str(eye_right_dir / name), eye_right)
        sheets.append(cv2.resize(anaglyph, (frame_meta.width // 2, frame_meta.height // 2)))

        frame_reports.append({
            "index": index, "capture_us": entry.capture_us, "file": name,
            "packets_decoded": decoded, "packets_rejected": bad,
            "points_in_window": int(len(cloud)), "points_in_view": int(len(us)),
            "nearest_m": None if np.isnan(nearest) else round(nearest, 3),
            "range_p10_p50_p90_m": ([] if not len(ranges) else
                                    [round(float(np.percentile(ranges, q)), 2)
                                     for q in (10, 50, 90)]),
            "annotations": annotations,
        })
        if (order + 1) % 5 == 0 or order + 1 == len(chosen):
            print(f"  {order + 1}/{len(chosen)} frames  ({time.time() - started:.0f}s)")

    if sheets:
        per_row = 4
        rows = [np.hstack(sheets[i:i + per_row]) for i in range(0, len(sheets), per_row)]
        width = max(row.shape[1] for row in rows)
        rows = [np.pad(row, ((0, 0), (0, width - row.shape[1]), (0, 0))) for row in rows]
        cv2.imwrite(str(out / "contact_sheet_anaglyph.png"), np.vstack(rows))

    summary = {
        "recording": str(recording),
        "outputs": {"ar_2d": str(out / "ar_2d"), "anaglyph": str(anaglyph_dir)},
        "inputs": {
            "radar_packets": len(radar), "camera_frames": len(camera),
            "camera": {"width": first_meta.width, "height": first_meta.height,
                       "stride": first_meta.stride},
        },
        "parameters": {
            "frames_rendered": len(frame_reports),
            "half_window_ms": args.half_window_ms,
            "min_range_m": args.min_range_m, "max_range_m": args.max_range_m,
            "fov_cone_deg": args.fov_cone_deg,
            "max_points": args.max_points, "fx_px": args.fx_px,
            "baseline_mm": args.baseline_mm, "zero_parallax_mm": args.zero_parallax_mm,
            "max_disparity_px": args.max_disparity_px, "columns": args.columns,
            "annotate_min_range_m": args.annotate_min_range_m,
            "extrinsic_roll_deg": args.roll_deg, "extrinsic_pitch_deg": args.pitch_deg,
            "extrinsic_yaw_deg": args.yaw_deg,
            "rotate_image_deg": args.rotate_image_deg,
            "anaglyph_mode": args.anaglyph_mode,
            "surface_bin_deg": args.surface_bin_deg,
            "surface_upsample": args.surface_upsample,
            "surface_median": args.surface_median,
            "surface_blur_sigma": args.surface_blur_sigma,
            "surface_az_limit_deg": args.surface_az_limit_deg,
            "surface_el_min_deg": args.surface_el_min_deg,
            "surface_el_max_deg": args.surface_el_max_deg,
        },
        "calibration_note": ("extrinsic/intrinsic are assumed, not measured: the camera "
                             "frame is rotated 180 degrees because the UVC module is mounted "
                             "upside down, then LiDAR and camera are treated as co-located and "
                             "forward facing with the principal point at the image centre and "
                             "no lens distortion"),
        "frames": frame_reports,
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False),
                                      encoding="utf-8")
    radar.close()
    camera.close()
    print(f"done: {len(frame_reports)} frames in {time.time() - started:.0f}s -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())