"""Bounded integer occupancy-grid reference matching a small RTL design."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path

import numpy as np

from .protocol import POINT_DTYPE


@dataclass(frozen=True)
class GridConfig:
    x_min_mm: int = 500
    x_max_mm: int = 6000  # exclusive
    y_min_mm: int = -3000
    y_max_mm: int = 3000  # exclusive
    cell_mm: int = 100
    max_points: int = 40_000
    max_objects: int = 32
    min_cells: int = 2
    min_points: int = 8
    core_cell_points: int = 2  # A single-hit cell must not bridge two dense objects.
    ground_margin_mm: int = 100
    # Ground signed distance: (nx*x + ny*y + nz*z) >> 30 + d_mm.
    plane_nx_q30: int = 0
    plane_ny_q30: int = 0
    plane_nz_q30: int = 1 << 30
    plane_d_mm: int = 0

    def __post_init__(self) -> None:
        if self.cell_mm <= 0 or self.x_max_mm <= self.x_min_mm or self.y_max_mm <= self.y_min_mm:
            raise ValueError("invalid grid dimensions")
        if (self.x_max_mm - self.x_min_mm) % self.cell_mm or (self.y_max_mm - self.y_min_mm) % self.cell_mm:
            raise ValueError("ROI must be an integer number of cells")
        if not 1 <= self.max_points <= 40_000 or not 1 <= self.max_objects <= 32:
            raise ValueError("unbounded point or object capacity")
        if self.core_cell_points not in (1, 2):
            raise ValueError("core_cell_points must be 1 or 2")

    @property
    def width(self) -> int:
        return (self.x_max_mm - self.x_min_mm) // self.cell_mm

    @property
    def height(self) -> int:
        return (self.y_max_mm - self.y_min_mm) // self.cell_mm

    @classmethod
    def load(cls, path: str | Path) -> "GridConfig":
        return cls(**json.loads(Path(path).read_text(encoding="utf-8")))

    def save(self, path: str | Path) -> None:
        Path(path).write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")


@dataclass(frozen=True)
class Detection:
    object_id: int
    cells: int
    points: int
    min_xyz_mm: tuple[int, int, int]
    max_xyz_mm: tuple[int, int, int]
    closest_xyz_mm: tuple[int, int, int]
    nearest_xy_sq_mm2: int

    @property
    def distance_mm(self) -> int:
        from math import isqrt
        return isqrt(self.nearest_xy_sq_mm2)


@dataclass(frozen=True)
class GridResult:
    detections: tuple[Detection, ...]
    accepted_points: int
    input_points: int
    overflow_points: int
    grid_counts: np.ndarray
    rejected_roi: int
    rejected_ground: int


class GridProcessor:
    """No full-frame point buffer, float, sqrt or unbounded allocation in core."""

    def __init__(self, config: GridConfig | None = None):
        self.config = config or GridConfig()

    def process(self, points: np.ndarray) -> GridResult:
        c = self.config
        pts = np.asarray(points)
        n_input = len(pts)
        n = min(n_input, c.max_points)
        overflow = n_input - n
        width, height = c.width, c.height
        cells = width * height
        count = [0] * cells       # Saturated 8-bit hardware counter.
        total = [0] * cells       # Saturated at max_points for cluster filtering.
        low = [[2**31 - 1] * 3 for _ in range(cells)]
        high = [[-2**31] * 3 for _ in range(cells)]
        closest_sq = [2**63 - 1] * cells
        closest = [[0, 0, 0] for _ in range(cells)]
        accepted = rejected_roi = rejected_ground = 0
        for i in range(n):
            p = pts[i]
            x, y, z = int(p["x"]), int(p["y"]), int(p["z"])
            if not c.x_min_mm <= x < c.x_max_mm or not c.y_min_mm <= y < c.y_max_mm:
                rejected_roi += 1
                continue
            height_mm = ((c.plane_nx_q30*x + c.plane_ny_q30*y + c.plane_nz_q30*z) >> 30) + c.plane_d_mm
            if height_mm <= c.ground_margin_mm:
                rejected_ground += 1
                continue
            col = (x - c.x_min_mm) // c.cell_mm
            row = (y - c.y_min_mm) // c.cell_mm
            idx = row * width + col
            count[idx] = min(255, count[idx] + 1)
            total[idx] = min(c.max_points, total[idx] + 1)
            xyz = (x, y, z)
            for axis in range(3):
                low[idx][axis] = min(low[idx][axis], xyz[axis])
                high[idx][axis] = max(high[idx][axis], xyz[axis])
            d2 = x*x + y*y
            if d2 < closest_sq[idx]:
                closest_sq[idx] = d2
                closest[idx] = [x, y, z]
            accepted += 1

        regions: list[Detection] = []
        # Two bounded 4-neighbour passes over the same grid. Dense cells form
        # object cores; isolated sparse components are still eligible, but
        # sparse chains touching a core cannot merge two dense objects.
        for pass_number in range(2 if c.core_cell_points == 2 else 1):
            visited = bytearray(cells)
            for start in range(cells):
                eligible = (count[start] >= c.core_cell_points if pass_number == 0
                            else count[start] == 1)
                if not eligible or visited[start]:
                    continue
                queue = [start]
                visited[start] = 1
                head = 0
                n_cells = n_points = 0
                touches_core = False
                region_low = [2**31 - 1] * 3
                region_high = [-2**31] * 3
                nearest = 2**63 - 1
                nearest_xyz = (0, 0, 0)
                while head < len(queue):
                    idx = queue[head]
                    head += 1
                    n_cells += 1
                    n_points += total[idx]
                    for axis in range(3):
                        region_low[axis] = min(region_low[axis], low[idx][axis])
                        region_high[axis] = max(region_high[axis], high[idx][axis])
                    if closest_sq[idx] < nearest:
                        nearest = closest_sq[idx]
                        nearest_xyz = tuple(closest[idx])
                    row, col = divmod(idx, width)
                    for neighbour in (idx-width if row else -1,
                                      idx+width if row+1 < height else -1,
                                      idx-1 if col else -1,
                                      idx+1 if col+1 < width else -1):
                        if neighbour < 0:
                            continue
                        if pass_number == 1 and count[neighbour] >= c.core_cell_points:
                            touches_core = True
                        eligible = (count[neighbour] >= c.core_cell_points if pass_number == 0
                                    else count[neighbour] == 1)
                        if eligible and not visited[neighbour]:
                            visited[neighbour] = 1
                            queue.append(neighbour)
                if (n_cells >= c.min_cells and n_points >= c.min_points and
                        not (pass_number == 1 and touches_core)):
                    regions.append(Detection(0, n_cells, n_points, tuple(region_low),
                                             tuple(region_high), nearest_xyz, nearest))
        regions.sort(key=lambda r: (r.nearest_xy_sq_mm2, r.min_xyz_mm))
        output = tuple(Detection(i+1, d.cells, d.points, d.min_xyz_mm,
                                 d.max_xyz_mm, d.closest_xyz_mm, d.nearest_xy_sq_mm2)
                       for i, d in enumerate(regions[:c.max_objects]))
        grid = np.asarray(count, dtype=np.uint8).reshape(height, width)
        return GridResult(output, accepted, n_input, overflow, grid, rejected_roi, rejected_ground)
