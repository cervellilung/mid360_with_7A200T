"""Offline visible-surface meshing. Never fills unseen backs or wide gaps."""

from __future__ import annotations

from dataclasses import dataclass
import time

import numpy as np
from scipy import ndimage


@dataclass
class Mesh:
    vertices: np.ndarray
    raw_vertices: np.ndarray
    triangles: np.ndarray
    normals: np.ndarray
    observed: np.ndarray
    input_points: int
    observed_cells: int
    filled_cells: int
    edge_rejections: int
    build_ms: float
    p95_shift_mm: float


def make_mesh(points_mm: np.ndarray, step_deg: float = 0.8, *, planar_fill: bool = False,
              min_range: float = .3, max_range: float = 12.) -> Mesh:
    start = time.perf_counter()
    if not (np.isfinite(min_range) and np.isfinite(max_range) and 0 < min_range < max_range):
        raise ValueError('Invalid reconstruction range')
    exact = np.asarray(points_mm, dtype=np.float64).reshape(-1, 3) / 1000.0
    radius = np.linalg.norm(exact, axis=1)
    valid = np.isfinite(exact).all(axis=1) & (radius >= min_range) & (radius <= max_range)
    # Keep the legacy measured-coordinate representation bit-identical;
    # float64 is used only for the ROI admission test.
    source = np.asarray(points_mm, dtype=np.float32).reshape(-1, 3)[valid] / 1000.0
    radius = np.linalg.norm(source, axis=1)
    input_points = len(source)
    cols = int(round(360 / step_deg))
    rows = int(round(105 / step_deg))
    empty = np.full((rows, cols), np.nan, np.float32)
    if not len(source):
        z3 = np.zeros((0, 3), np.float32)
        return Mesh(z3, z3, np.zeros((0, 3), np.uint32), z3, np.zeros(0, bool),
                    0, 0, 0, 0, 0.0, 0.0)

    az = np.degrees(np.arctan2(source[:, 1], source[:, 0]))
    el = np.degrees(np.arctan2(source[:, 2], np.hypot(source[:, 0], source[:, 1])))
    row = np.floor((el + 40) / step_deg).astype(np.int32)
    col = np.floor((az + 180) / step_deg).astype(np.int32)
    take = (row >= 0) & (row < rows) & (col >= 0) & (col < cols)
    row, col, radius, source = row[take], col[take], radius[take], source[take]
    linear = row * cols + col
    order = np.lexsort((radius, linear))
    index, first = np.unique(linear[order], return_index=True)
    chosen = order[first]
    empty.flat[index] = radius[chosen]
    measured = np.isfinite(empty)
    xyz = np.full((rows, cols, 3), np.nan, np.float32)
    xyz.reshape(-1, 3)[index] = source[chosen]
    raw = xyz.copy()  # Exact selected measured XYZ, never angular-bin centres.
    filled = np.zeros_like(measured)

    # Only enclosed, tiny holes in dense planar patches. Never grow the support
    # recursively, bridge open gaps, or infer a backside. Inferred flags stay false.
    enclosed = ndimage.binary_fill_holes(measured) & ~measured
    labels, _ = ndimage.label(enclosed)
    for label, region in enumerate(ndimage.find_objects(labels), 1):
        if region is None:
            continue
        ys, xs = region
        hole = labels[region] == label
        size = int(hole.sum())
        limit, side = (256, 24) if planar_fill else (4, 2)
        if size > limit or ys.stop-ys.start > side or xs.stop-xs.start > side:
            continue
        y0, y1 = max(0, ys.start-2), min(rows, ys.stop+2)
        x0, x1 = max(0, xs.start-2), min(cols, xs.stop+2)
        support = measured[y0:y1, x0:x1]
        extended = planar_fill and (size > 4 or ys.stop-ys.start > 2 or xs.stop-xs.start > 2)
        if extended:
            # Fit only the measured ring, never an already invented interior.
            local_hole = np.zeros_like(support)
            local_hole[ys.start-y0:ys.stop-y0, xs.start-x0:xs.stop-x0] = hole
            ring = ndimage.binary_dilation(local_hole, iterations=2) & ~local_hole
            support = support & ring
            if support.sum() < 24 or support.sum()/max(1, ring.sum()) < .80:
                continue
        elif support.sum() < 12 or support.mean() < .85:
            continue
        samples = raw[y0:y1, x0:x1][support]
        centre = samples.mean(axis=0)
        _, singular, vh = np.linalg.svd(samples-centre, full_matrices=False)
        if singular[1] < .015:  # Collinear returns cannot support a surface.
            continue
        normal = vh[-1]
        residual = np.abs((samples-centre) @ normal)
        if np.sqrt(np.mean(residual**2)) > .008 or residual.max() > .020:
            continue
        depth_limit = .35 if extended else .12+.025*np.linalg.norm(centre)
        if np.ptp(np.linalg.norm(samples, axis=1)) > depth_limit:
            continue
        hr, hc = np.where(hole)
        hr, hc = hr+ys.start, hc+xs.start
        azimuth = np.radians(-180+(hc+.5)*step_deg)
        elevation = np.radians(-40+(hr+.5)*step_deg)
        rays = np.stack((np.cos(elevation)*np.cos(azimuth),
                         np.cos(elevation)*np.sin(azimuth), np.sin(elevation)), axis=1)
        denominator = rays @ normal
        if np.any(np.abs(denominator) < .2):
            continue
        distance = (centre @ normal) / denominator
        if np.any((distance < min_range) | (distance > max_range)):
            continue
        inferred = rays * distance[:, None]
        if extended and np.linalg.norm(np.ptp(np.concatenate((samples, inferred)), axis=0)) > .65:
            continue
        xyz[hr, hc] = inferred
        raw[hr, hc] = xyz[hr, hc]
        filled[hr, hc] = True

    # Batched local plane fits: only dense, geometrically coherent neighbourhoods
    # move. Cap measured displacement at 10 mm and keep 50% of raw measurement.
    # Boundary points and depth discontinuities stay anchored.
    measured_raw = np.where(measured[:, :, None], raw, np.nan)
    neighbourhood = np.stack([np.roll(measured_raw, (dy, dx), axis=(0, 1))
                              for dy in (-1, 0, 1) for dx in (-1, 0, 1)], axis=2)
    dense = np.isfinite(neighbourhood).all(axis=(2, 3)) & measured
    dense[[0, -1], :] = False
    dense[:, [0, -1]] = False
    patches = neighbourhood[dense]
    if len(patches):
        centres = patches.mean(axis=1)
        delta = patches-centres[:, None, :]
        _, singular, vh = np.linalg.svd(delta, full_matrices=False)
        normal = vh[:, -1]
        residual = np.einsum('nki,ni->nk', delta, normal)
        patch_range = np.ptp(np.linalg.norm(patches, axis=2), axis=1)
        good = (np.sqrt(np.mean(residual**2, axis=1)) < .008) & \
               (np.abs(residual).max(axis=1) < .020) & (singular[:, 1] > .008) & \
               (patch_range < .12+.025*np.linalg.norm(centres, axis=1))
        correction = np.einsum('ni,ni->n', raw[dense]-centres, normal)
        correction = np.clip(correction*.5, -.010, .010)
        updated = raw[dense]-normal*correction[:, None]
        updated_radius = np.linalg.norm(updated.astype(np.float64), axis=1)
        good &= (updated_radius >= min_range) & (updated_radius <= max_range)
        xyz[dense] = np.where(good[:, None], updated, raw[dense])
    rr, cc = np.where(measured | filled)
    vertices = xyz[rr, cc]
    raw_vertices = raw[rr, cc]
    ids = np.full((rows, cols), -1, np.int32)
    ids[rr, cc] = np.arange(len(rr))
    a, b, c, e = ids[:-1, :-1], ids[1:, :-1], ids[:-1, 1:], ids[1:, 1:]
    # Four returns: select the shorter diagonal. Three returns: emit the one
    # supported triangle regardless of which corner is missing.
    quad = np.stack((a, b, c, e), axis=-1).reshape(-1, 4)
    present = quad >= 0
    complete = quad[present.all(axis=1)]
    partial = quad[present.sum(axis=1) == 3]
    candidates_list = [partial[partial >= 0].reshape(-1, 3)]
    if len(complete):
        av, bv, cv, ev = (vertices[complete[:, k]] for k in range(4))
        alternate = np.linalg.norm(av-ev, axis=1) < np.linalg.norm(bv-cv, axis=1)
        standard, alt = complete[~alternate], complete[alternate]
        candidates_list.extend((standard[:, [0, 1, 2]], standard[:, [3, 2, 1]],
                                alt[:, [0, 1, 3]], alt[:, [0, 3, 2]]))
    candidates = np.concatenate(candidates_list)
    if len(candidates):
        tri = vertices[candidates]
        edges = np.stack((np.linalg.norm(tri[:, 0] - tri[:, 1], axis=1),
                          np.linalg.norm(tri[:, 0] - tri[:, 2], axis=1),
                          np.linalg.norm(tri[:, 1] - tri[:, 2], axis=1)), axis=1)
        r = np.linalg.norm(tri.mean(axis=1), axis=1)
        safe = (edges.max(axis=1) < (0.09 + 0.030 * r)) & \
               (np.ptp(np.linalg.norm(tri, axis=2), axis=1) < (0.12 + 0.025 * r)) & \
               (np.linalg.norm(np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0]), axis=1) > 1e-8)
        rejected = int((~safe).sum())
        triangles = candidates[safe].astype(np.uint32)
    else:
        triangles, rejected = np.zeros((0, 3), np.uint32), 0
    normals = np.zeros_like(vertices)
    if len(triangles):
        tri = vertices[triangles]
        face = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        flip = np.sum(face * -tri.mean(axis=1), axis=1) < 0
        triangles[flip, 1], triangles[flip, 2] = triangles[flip, 2].copy(), triangles[flip, 1].copy()
        tri = vertices[triangles]
        face = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        for k in range(3):
            np.add.at(normals, triangles[:, k], face)
        normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-9)
    shifts = np.linalg.norm((vertices-raw_vertices)[measured[rr, cc]], axis=1) * 1000
    return Mesh(vertices, raw_vertices, triangles, normals, measured[rr, cc], input_points,
                int(measured.sum()), int(filled.sum()), rejected,
                (time.perf_counter() - start) * 1000,
                float(np.percentile(shifts, 95)) if len(shifts) else 0.0)
