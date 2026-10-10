"""PC visible-surface meshing from angular neighbours, preserving measured XYZ.

Angular Delaunay is only a candidate generator. Per-edge sampling scale,
bidirectional tangent-plane residuals and conservative depth checks prevent
foreground/background connections. No vertices or unseen backs are invented.
"""
from dataclasses import dataclass, asdict
import time
import numpy as np
from scipy.spatial import cKDTree, Delaunay, ConvexHull, QhullError
from .mesh import Mesh


@dataclass(frozen=True)
class AngularConfig:
    step_deg: float = .8
    min_range: float = .3
    max_range: float = 12.
    neighbour_order: int = 6
    spacing_factor: float = 2.5
    max_angle_deg: float = 3.2
    normal_neighbours: int = 16
    normal_iterations: int = 3
    normal_float32: bool = False
    candidate_mode: str = 'sectors'
    normal_rms_m: float = .015
    normal_range_factor: float = .002
    residual_m: float = .025
    residual_range_factor: float = .0025
    fallback_depth_m: float = .05
    fallback_range_factor: float = .025
    fallback_spacing_factor: float = 1.5


def make_angular_mesh(points_mm, config=None, *, include_geometry=False, include_audit=False, defer_normals=False):
    cfg = config or AngularConfig()
    if not (0 < cfg.step_deg <= 5 and 0 < cfg.max_angle_deg < 10
            and cfg.min_range < cfg.max_range and cfg.neighbour_order >= 1
            and cfg.normal_neighbours >= 4 and 1 <= cfg.normal_iterations <= 3
            and cfg.candidate_mode in ('sectors','sphere')):
        raise ValueError('invalid angular mesh configuration')
    started = time.perf_counter()
    source = np.asarray(points_mm, np.float32).reshape(-1, 3) / 1000
    radius = np.linalg.norm(source, axis=1)
    good = np.isfinite(source).all(axis=1) & (radius >= cfg.min_range) & (radius <= cfg.max_range)
    source, radius = source[good], radius[good]
    source_ids = np.flatnonzero(good)
    range_count = len(source)
    az = np.arctan2(source[:, 1], source[:, 0])
    el = np.arctan2(source[:, 2], np.hypot(source[:, 0], source[:, 1]))
    rows, cols = int(round(105/cfg.step_deg)), int(round(360/cfg.step_deg))
    rr = np.floor((np.degrees(el)+40)/cfg.step_deg).astype(int)
    cc = np.floor((np.degrees(az)+180)/cfg.step_deg).astype(int) % cols
    good = (rr >= 0) & (rr < rows)
    source, radius, az, el, rr, cc = (v[good] for v in (source, radius, az, el, rr, cc))
    source_ids = source_ids[good]
    order = np.lexsort((radius, rr*cols+cc))
    cells=(rr*cols+cc)[order]
    first=np.flatnonzero(np.r_[True,cells[1:]!=cells[:-1]]) if len(cells) else np.empty(0,int)
    chosen = order[first]
    vertices, radius, az, el = (v[chosen] for v in (source, radius, az, el))
    count = len(vertices)
    empty = np.zeros((0, 3), np.uint32)
    diagnostics = dict(algorithm='adaptive_angular_v1', config=asdict(cfg), candidates=0,
                       normal_reliable=0, rejected_angle=0, rejected_depth=0,
                       rejected_degenerate=0, depth_fallback_edges=0)
    audit = dict(selected_source_ids=source_ids[chosen], range_points=range_count,
                 elevation_removed=range_count-len(source), bucket_removed=len(source)-count,
                 candidates=empty, reasons=np.zeros(0, np.uint8))
    if count < 3:
        mesh = _mesh(vertices, empty, len(source), started, diagnostics)
        if include_audit: mesh.audit = audit
        return mesh
    rays = vertices / radius[:, None]
    tree = cKDTree(rays)
    k = min(count, max(cfg.normal_neighbours, cfg.neighbour_order+1))
    chord, neighbours = tree.query(rays, k=k, workers=1)
    angle = 2*np.arcsin(np.clip(chord/2, 0, 1))
    scale = angle[:, min(cfg.neighbour_order, k-1)]
    limit = np.minimum(np.radians(cfg.max_angle_deg), cfg.spacing_factor*scale)
    geometry = _normals(vertices, radius, neighbours, angle, scale, cfg, details=include_geometry)
    normal, reliable = geometry[:2]
    diagnostics['normal_reliable'] = int(reliable.sum())

    # Six overlapping gnomonic sectors avoid the azimuth seam. Ownership is
    # assigned by angular centroid; duplicate IDs are removed deterministically.
    pieces = []
    if cfg.candidate_mode=='sphere':
        # Hull of UNIT directions is spherical Delaunay, not a hull of world
        # surfaces. Every face still passes angular/depth/normal gates below.
        # Single topology avoids independently triangulated sector seams.
        unit=rays.astype(np.float64)
        unit/=np.linalg.norm(unit,axis=1,keepdims=True)
        try:pieces.append(ConvexHull(unit).simplices)
        except QhullError:pass
    for centre_deg in (range(-150,180,60) if cfg.candidate_mode=='sectors' else []):
        centre = np.radians(centre_deg)
        delta = (az-centre+np.pi) % (2*np.pi)-np.pi
        ids = np.flatnonzero(np.abs(delta) < np.radians(34))
        if len(ids) < 3:
            continue
        xy = np.column_stack((np.tan(delta[ids]), np.tan(el[ids])/np.cos(delta[ids])))
        try:
            candidate = ids[Delaunay(xy).simplices]
        except QhullError:
            continue  # Collinear sampling is not a supported surface.
        direction = rays[candidate].sum(axis=1)
        bearing = np.arctan2(direction[:, 1], direction[:, 0])
        ownership = (bearing-centre+np.pi) % (2*np.pi)-np.pi
        pieces.append(candidate[(ownership >= -np.pi/6) & (ownership < np.pi/6)])
    if pieces:
        canonical=np.sort(np.concatenate(pieces),axis=1)
        if cfg.normal_float32 and count<2**21:
            bits=max(1,(count-1).bit_length());a=canonical.astype(np.uint64)
            keys=(a[:,0]<<(2*bits)) | (a[:,1]<<bits) | a[:,2]
            _,indices=np.unique(keys,return_index=True)
            candidates=canonical[indices]
        else:
            candidates=np.unique(canonical,axis=0)
    else:candidates=empty
    diagnostics['candidates'] = len(candidates)
    if not len(candidates):
        mesh = _mesh(vertices, empty, len(source), started, diagnostics)
        if include_audit: mesh.audit = audit
        return mesh
    left = candidates[:, (0, 0, 1)]
    right = candidates[:, (1, 2, 2)]
    cosine = np.einsum('nki,nki->nk', rays[left], rays[right])
    theta = np.arccos(np.clip(cosine, -1, 1))
    angle_ok = (theta <= np.minimum(limit[left], limit[right])+1e-7).all(axis=1)
    # Natural transverse spacing scales with range, not a fixed metre limit.
    transverse = 2*np.sqrt(radius[left]*radius[right])*np.sin(theta/2)
    displacement = vertices[right]-vertices[left]
    residual_left = np.abs(np.einsum('nki,nki->nk', displacement, normal[left]))
    residual_right = np.abs(np.einsum('nki,nki->nk', displacement, normal[right]))
    tolerance = cfg.residual_m + cfg.residual_range_factor*np.minimum(radius[left], radius[right])
    has_left, has_right = reliable[left], reliable[right]
    tangent_ok = (~has_left | (residual_left <= tolerance)) & (~has_right | (residual_right <= tolerance))
    normal_agree = np.abs(np.einsum('nki,nki->nk', normal[left], normal[right])) >= np.cos(np.radians(35))
    tangent_ok &= ~(has_left & has_right) | normal_agree
    fallback = np.abs(radius[left]-radius[right]) <= (cfg.fallback_depth_m +
        cfg.fallback_range_factor*np.minimum(radius[left], radius[right]) + cfg.fallback_spacing_factor*transverse)
    # Both endpoints must have reliable local geometry before relaxing depth.
    # A reliable wall normal alone must not pull an isolated foreground return in.
    both = has_left & has_right
    depth_ok = (tangent_ok & (both | fallback)).all(axis=1)
    diagnostics['depth_fallback_edges'] = int((~both).sum())
    tri = vertices[candidates]
    area = np.linalg.norm(np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0]), axis=1)
    shape_ok = area > 1e-8
    diagnostics['rejected_angle'] = int((~angle_ok).sum())
    diagnostics['rejected_depth'] = int((angle_ok & ~depth_ok).sum())
    diagnostics['rejected_degenerate'] = int((angle_ok & depth_ok & ~shape_ok).sum())
    accepted = candidates[angle_ok & depth_ok & shape_ok].astype(np.uint32)
    mesh = _mesh(vertices, accepted, len(source), started, diagnostics, compute_normals=not defer_normals)
    if include_audit:
        # Non-exclusive flags: angle=1, tangent residual=2, normal disagreement=4,
        # fallback radial depth=8, degenerate=16. Aggregate old counters unchanged.
        reasons = (~angle_ok).astype(np.uint8)
        reasons |= ((~((~has_left | (residual_left <= tolerance)) &
                       (~has_right | (residual_right <= tolerance)))).any(axis=1)).astype(np.uint8)*2
        reasons |= (both & ~normal_agree).any(axis=1).astype(np.uint8)*4
        reasons |= (~both & ~fallback).any(axis=1).astype(np.uint8)*8
        reasons |= (~shape_ok).astype(np.uint8)*16
        audit.update(candidates=candidates.astype(np.uint32), reasons=reasons,
                     edge_angles_deg=np.degrees(theta).astype(np.float32),
                     radial_delta_m=np.abs(radius[left]-radius[right]).astype(np.float32),
                     tangent_left_m=residual_left.astype(np.float32),
                     tangent_right_m=residual_right.astype(np.float32),
                     reliable_left=has_left, reliable_right=has_right,
                     normal_agreement=normal_agree)
        mesh.audit = audit
    if include_geometry:
        mesh.local_geometry = dict(**geometry[2], normal=normal, reliable=reliable,
                                   neighbours=neighbours, angle=angle, scale=scale, radius=radius)
    return mesh


def _normals(vertices, radius, neighbours, angle, scale, cfg, *, details=False):
    dtype = np.float32 if cfg.normal_float32 else np.float64
    samples = vertices[neighbours].astype(dtype)
    supported = angle <= np.minimum(np.radians(cfg.max_angle_deg), 2.5*scale[:, None])
    centre = samples.mean(axis=1)
    normal = np.zeros_like(centre)
    weights = supported.astype(dtype)
    # Robust local covariance; two reweightings reject off-surface neighbours.
    for iteration in range(cfg.normal_iterations):
        total = np.maximum(weights.sum(axis=1), 1)
        centre = np.einsum('nk,nki->ni', weights, samples)/total[:, None]
        delta = samples-centre[:, None, :]
        # Float32 display mode uses batched 3xK @ Kx3 rather than a three-input
        # einsum. Same covariance, much less temporary arithmetic on this PC.
        # The original reference's float64 path remains unchanged.
        if cfg.normal_float32:
            covariance = np.swapaxes(delta, 1, 2) @ (weights[:, :, None]*delta)
            covariance /= total[:, None, None]
        else:
            covariance = np.einsum('nk,nki,nkj->nij', weights, delta, delta)/total[:, None, None]
        values, vectors = np.linalg.eigh(covariance)
        normal = vectors[:, :, 0]
        residual = np.abs(np.einsum('nki,ni->nk', delta, normal))
        tolerance = cfg.normal_rms_m + cfg.normal_range_factor*radius
        if iteration < cfg.normal_iterations-1:
            weights = supported * np.minimum(1, tolerance[:, None]/np.maximum(residual, 1e-9))**2
    inliers = supported & (residual <= tolerance[:, None]*2)
    rms = np.sqrt(np.sum(weights*residual**2, axis=1)/np.maximum(weights.sum(axis=1), 1))
    own_residual = np.abs(np.einsum('ni,ni->n', vertices-centre, normal))
    incidence = np.abs(np.einsum('ni,ni->n', vertices/radius[:, None], normal))
    reliable = (inliers.sum(axis=1) >= 8) & (rms <= tolerance) & (own_residual <= tolerance*2) & \
               (values[:, 1] > 1e-6) & (values[:, 1] > 3*values[:, 0]) & (incidence >= .08)
    if details:
        return normal, reliable, dict(centre=centre, eigenvalues=values, rms=rms, supported=supported)
    return normal, reliable


def _mesh(vertices, triangles, input_points, started, diagnostics, *, compute_normals=True):
    vertices = np.asarray(vertices, np.float32)
    normals = np.zeros_like(vertices)
    if len(triangles):
        tri = vertices[triangles]
        face = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
        flip = np.einsum('ni,ni->n', face, -tri.mean(axis=1)) < 0
        triangles[flip] = triangles[flip][:, (0, 2, 1)]
        tri = vertices[triangles]
        face = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
        if compute_normals:
            if diagnostics.get('config',{}).get('normal_float32'):
                ids=triangles.reshape(-1);weights=np.repeat(face,3,axis=0)
                for j in range(3):normals[:,j]=np.bincount(ids,weights=weights[:,j],minlength=len(vertices))
            else:
                for i in range(3):np.add.at(normals, triangles[:, i], face)
            normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-9)
    mesh = Mesh(vertices, vertices.copy(), triangles, normals, np.ones(len(vertices), bool),
                input_points, len(vertices), 0, diagnostics['candidates']-len(triangles),
                (time.perf_counter()-started)*1000, 0.)
    mesh.diagnostics = diagnostics
    return mesh
