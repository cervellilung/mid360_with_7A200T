"""PC local-feature display refinement on range/angle-aware measured topology.

Inspired by planar/non-planar separation in LGFaware-Meshing (Niu et al.,
10.1080/10095020.2025.2502481) and Whelan et al. (10.1016/j.robot.2014.08.019).
This is NOT a reproduction of their PDM, zipper or planar decimation algorithms.
No faces/vertices are added: sparse-range connectivity remains angular_v1's job.
Refined positions are display estimates; raw_vertices stay authoritative.
"""
from dataclasses import dataclass, asdict
import time
import numpy as np
from .adaptive_mesh import make_angular_mesh, _mesh

UNKNOWN, PLANAR, COMPLEX, EDGE = 0, 1, 2, 3
FEATURE_NAMES = ('uncertain', 'planar', 'complex', 'edge')


@dataclass(frozen=True)
class FeatureConfig:
    curvature_max: float = .012
    agreement_deg: float = 15.
    agreement_fraction: float = .85
    min_support: int = 10
    strength: float = .65
    max_shift_m: float = .008
    shift_range_factor: float = .001
    min_incidence: float = .2
    depth_base_m: float = .035
    depth_range_factor: float = .003
    min_face_normal_cos: float = .8


def make_feature_mesh(points_mm, config=None, *, base=None):
    """Same topology as angular mesh; feature-gated bounded radial projection.

    If base carries local_geometry, covariance and triangulation are reused.
    build_ms counts base construction plus this refinement, not refinement alone.
    """
    cfg = config or FeatureConfig()
    if not (0 <= cfg.strength <= 1 and 0 < cfg.agreement_fraction <= 1
            and cfg.min_support >= 3 and cfg.max_shift_m >= 0
            and cfg.shift_range_factor >= 0 and 0 < cfg.min_incidence <= 1):
        raise ValueError('invalid local feature configuration')
    if base is None or not hasattr(base, 'local_geometry'):
        base = make_angular_mesh(points_mm, include_geometry=True)
    started = time.perf_counter()
    raw = base.raw_vertices
    n = len(raw)
    labels = np.zeros(n, np.uint8)
    refined = raw.copy()
    rejected = 0
    geometry = getattr(base, 'local_geometry', None)
    if geometry is not None and n:
        normal, reliable = geometry['normal'], geometry['reliable']
        neighbours, supported = geometry['neighbours'], geometry['supported']
        radius = geometry['radius']
        rays = raw/radius[:, None]
        displacement = raw[neighbours]-raw[:, None, :]
        residual = np.abs(np.einsum('nki,ni->nk', displacement, normal))
        near_plane = residual <= (cfg.depth_base_m+cfg.depth_range_factor*radius[:, None])
        agrees = np.abs(np.einsum('ni,nki->nk', normal, normal[neighbours])) >= np.cos(np.radians(cfg.agreement_deg))
        total = supported.sum(axis=1)
        compatible = supported & near_plane & agrees & reliable[neighbours]
        fraction = compatible.sum(axis=1)/np.maximum(total, 1)
        curvature = geometry['eigenvalues'][:, 0]/np.maximum(geometry['eigenvalues'].sum(axis=1), 1e-12)
        incidence = np.abs(np.einsum('ni,ni->n', normal, rays))
        # Nearby off-plane samples mark an edge even when a local PCA fits one
        # side of the corner. Edge and uncertain vertices are never projected.
        edge = (supported & (~near_plane | (reliable[neighbours] & ~agrees))).any(axis=1)
        labels[reliable] = COMPLEX
        labels[edge] = EDGE
        plane = (reliable & ~edge & (total >= cfg.min_support)
                 & (fraction >= cfg.agreement_fraction) & (curvature <= cfg.curvature_max)
                 & (incidence >= cfg.min_incidence))
        labels[plane] = PLANAR
        signed = np.einsum('ni,ni->n', raw-geometry['centre'], normal)
        denominator = np.einsum('ni,ni->n', rays, normal)
        radial = np.zeros(n, np.float64)
        radial[plane] = -cfg.strength*signed[plane]/denominator[plane]
        bound = cfg.max_shift_m+cfg.shift_range_factor*radius
        radial = np.clip(radial, -bound, bound)
        refined += (radial[:, None]*rays).astype(np.float32)
        # A per-vertex displacement cap alone cannot protect tiny triangles.
        # Roll back every vertex of any face that collapses, flips or strongly
        # changes its normal, then recompute until no changed bad face remains.
        triangles = base.triangles
        if len(triangles):
            original = raw[triangles]
            old_normal = np.cross(original[:, 1]-original[:, 0], original[:, 2]-original[:, 0])
            old_area = np.linalg.norm(old_normal, axis=1)
            for attempt in range(8):
                tri = refined[triangles]
                new_normal = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
                new_area = np.linalg.norm(new_normal, axis=1)
                agreement = np.einsum('ni,ni->n', old_normal, new_normal)/np.maximum(old_area*new_area, 1e-20)
                bad = (new_area < old_area*.25) | (agreement < cfg.min_face_normal_cos)
                changed = np.any(refined != raw, axis=1)
                bad &= changed[triangles].any(axis=1)
                if not bad.any():
                    break
                if attempt == 7:
                    # Bounded work even for pathological skinny-face chains.
                    rejected += int(changed.sum())
                    refined[:] = raw
                    break
                ids = np.unique(triangles[bad])
                rejected += int(changed[ids].sum())
                refined[ids] = raw[ids]
        # The loop only removes modified vertices. No topology is altered.
    shift = np.linalg.norm(refined-raw, axis=1)*1000
    diagnostics = dict(base.diagnostics, algorithm='local_feature_v1', feature_config=asdict(cfg),
                       feature_counts={name:int((labels==i).sum()) for i,name in enumerate(FEATURE_NAMES)},
                       projection_rollbacks=rejected, max_shift_mm=float(shift.max(initial=0)),
                       rms_shift_mm=float(np.sqrt(np.mean(shift**2))) if n else 0.,
                       moved_vertices=int((shift>.001).sum()),
                       topology='identical to angular_v1; no hole filling or simplification')
    # Use raw normals first, then recompute for constrained display positions.
    mesh = _mesh(refined, base.triangles.copy(), base.input_points, started, diagnostics)
    mesh.raw_vertices = raw.copy()
    if geometry is not None:
        # Reliable flat regions use their robust local-plane normal for shading;
        # complex/edge regions keep the normals of the actual display geometry.
        ids = labels == PLANAR
        fitted = geometry['normal'][ids].copy()
        fitted[np.einsum('ni,ni->n', fitted, -raw[ids]) < 0] *= -1
        mesh.normals[ids] = fitted.astype(np.float32)
    mesh.p95_shift_mm = float(np.percentile(shift, 95)) if n else 0.
    mesh.build_ms += base.build_ms
    mesh.features = labels
    mesh.diagnostics['refine_ms'] = mesh.build_ms-base.build_ms
    return mesh
