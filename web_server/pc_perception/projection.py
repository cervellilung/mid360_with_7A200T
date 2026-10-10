"""Sparse fixed-point LiDAR-to-camera projection with a small distortion LUT."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path

from .grid import Detection


Q30 = 1 << 30
Q16 = 1 << 16
Q8 = 1 << 8


@dataclass(frozen=True)
class Calibration:
    width: int
    height: int
    camera_id: str
    mount_id: str
    r_q30: tuple[int, ...]  # row-major LiDAR -> camera
    t_mm: tuple[int, int, int]
    fx_q16: int
    fy_q16: int
    cx_q16: int
    cy_q16: int
    lut_width: int
    lut_height: int
    distortion_du_q8: tuple[int, ...]
    distortion_dv_q8: tuple[int, ...]
    reprojection_p95_px: float
    valid: bool

    @classmethod
    def load(cls, path: str | Path) -> "Calibration":
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        for key in ("r_q30", "t_mm", "distortion_du_q8", "distortion_dv_q8"):
            raw[key] = tuple(raw[key])
        obj = cls(**raw)
        if len(obj.r_q30) != 9 or len(obj.t_mm) != 3 or obj.lut_width < 2 or obj.lut_height < 2:
            raise ValueError("invalid calibration dimensions")
        if len(obj.distortion_du_q8) != obj.lut_width * obj.lut_height or len(obj.distortion_dv_q8) != obj.lut_width * obj.lut_height:
            raise ValueError("invalid distortion LUT dimensions")
        return obj

    def compatible(self, width: int, height: int, camera_id: str, mount_id: str) -> bool:
        return (self.valid and self.width == width and self.height == height and
                self.camera_id == camera_id and self.mount_id == mount_id)


def _lut_correction(cal: Calibration, u_q16: int, v_q16: int) -> tuple[int, int]:
    # Bilinear interpolation in Q16 grid position; output pixel offsets in Q8.
    gx_q16 = u_q16 * (cal.lut_width-1) // max(1, cal.width-1)
    gy_q16 = v_q16 * (cal.lut_height-1) // max(1, cal.height-1)
    gx_q16 = max(0, min((cal.lut_width-1)*Q16, gx_q16))
    gy_q16 = max(0, min((cal.lut_height-1)*Q16, gy_q16))
    x, y = min(cal.lut_width-2, gx_q16 >> 16), min(cal.lut_height-2, gy_q16 >> 16)
    ax, ay = gx_q16 - x*Q16, gy_q16 - y*Q16

    def sample(values: tuple[int, ...]) -> int:
        i = y*cal.lut_width+x
        top = (values[i]*(Q16-ax) + values[i+1]*ax) >> 16
        bottom = (values[i+cal.lut_width]*(Q16-ax) + values[i+cal.lut_width+1]*ax) >> 16
        return (top*(Q16-ay) + bottom*ay) >> 16
    return sample(cal.distortion_du_q8), sample(cal.distortion_dv_q8)


def project_point(point_mm: tuple[int, int, int], cal: Calibration) -> tuple[int, int] | None:
    xyz = [int(v) for v in point_mm]
    camera = [((sum(cal.r_q30[3*row+col]*xyz[col] for col in range(3))) >> 30) + cal.t_mm[row]
              for row in range(3)]
    x, y, z = camera
    if z <= 100:
        return None
    u_q16 = cal.fx_q16*x//z + cal.cx_q16
    v_q16 = cal.fy_q16*y//z + cal.cy_q16
    du, dv = _lut_correction(cal, u_q16, v_q16)
    u_q16 += du << 8
    v_q16 += dv << 8
    u, v = u_q16 >> 16, v_q16 >> 16
    if not (0 <= u < cal.width and 0 <= v < cal.height):
        return None
    return u, v


def project_box(det: Detection, cal: Calibration) -> tuple[int, int, int, int] | None:
    lo, hi = det.min_xyz_mm, det.max_xyz_mm
    pixels = [project_point((x, y, z), cal) for x in (lo[0], hi[0])
              for y in (lo[1], hi[1]) for z in (lo[2], hi[2])]
    visible = [p for p in pixels if p is not None]
    if not visible:
        return None
    return (min(p[0] for p in visible), min(p[1] for p in visible),
            max(p[0] for p in visible), max(p[1] for p in visible))
