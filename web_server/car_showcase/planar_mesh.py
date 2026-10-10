"""Experimental, current-window planar support meshing. PC only, no map fusion.

Plane fits never create a whole convex hull. Delaunay is only a candidate
generator: angular, local spacing, support and measured ray gates remain active.
"""
from dataclasses import dataclass, asdict
import time
import numpy as np
from scipy.spatial import cKDTree, Delaunay, QhullError
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from .adaptive_mesh import AngularConfig, make_angular_mesh, _mesh


@dataclass(frozen=True)
class PlanarConfig:
    min_range: float = .3
    max_range: float = 6.
    plane_m: float = .020
    plane_per_m: float = .001
    max_angle_deg: float = 3.2
    connection_scale: float = 2.8
    hole_radius_m: float = .20
    dedup_m: float = .010
    min_plane_points: int = 600
    max_planes: int = 8
    seed: int = 77
    recover_supported_gaps: bool = True
    angular_gap_support: bool = True
    support_angle_deg: float = 2.4


def valid_points(points_mm, config=None):
    cfg = config or PlanarConfig()
    if not (np.isfinite(cfg.min_range) and np.isfinite(cfg.max_range)
            and 0 < cfg.min_range < cfg.max_range):
        raise ValueError('Invalid reconstruction range')
    p = np.asarray(points_mm, np.float64).reshape(-1, 3)/1000
    r = np.linalg.norm(p, axis=1)
    mask = np.isfinite(p).all(axis=1) & (r >= cfg.min_range) & (r <= cfg.max_range)
    return p[mask], np.flatnonzero(mask)


def make_range_baseline(points_mm, config=None, *, include_audit=True, include_geometry=False):
    """Apply the exact same radial ROI before angular float32 computations."""
    cfg = config or PlanarConfig()
    _, ids = valid_points(points_mm, cfg)
    cloud = np.asarray(points_mm).reshape(-1, 3)
    base = make_angular_mesh(cloud[ids], AngularConfig(min_range=cfg.min_range,
        max_range=cfg.max_range, max_angle_deg=cfg.max_angle_deg), include_audit=include_audit,
        include_geometry=include_geometry)
    if include_audit:
        base.audit['selected_source_ids'] = ids[base.audit['selected_source_ids']]
    return base


def fit_planes(p, cfg):
    """Deterministic sample RANSAC, then fit and classify all training returns."""
    rng = np.random.default_rng(cfg.seed)
    remaining = np.arange(len(p)); result = []
    tolerance = cfg.plane_m + cfg.plane_per_m*np.linalg.norm(p, axis=1)
    for _ in range(cfg.max_planes):
        if len(remaining) < cfg.min_plane_points: break
        sample = rng.choice(remaining, min(2500, len(remaining)), replace=False)
        triplets = rng.choice(remaining, (160, 3), replace=True)
        a, b, c = (p[triplets[:, j]] for j in range(3))
        normal = np.cross(b-a, c-a)
        length = np.linalg.norm(normal, axis=1)
        normal /= np.maximum(length[:, None], 1e-12)
        offsets = -np.einsum('ij,ij->i', normal, a)
        score = (np.abs(p[sample]@normal.T+offsets) <= tolerance[sample, None]).sum(axis=0)
        score[length < 1e-6] = 0
        best = int(score.argmax()); n, d = normal[best], offsets[best]
        ids = remaining[np.abs(p[remaining]@n+d) <= tolerance[remaining]]
        if len(ids) < cfg.min_plane_points: break
        for _ in range(3):
            centre = p[ids].mean(axis=0)
            values, vectors = np.linalg.eigh(np.cov((p[ids]-centre).T))
            n = vectors[:, 0]; d = -n@centre
            ids = remaining[np.abs(p[remaining]@n+d) <= tolerance[remaining]]
            if len(ids) < cfg.min_plane_points: break
        if len(ids) < cfg.min_plane_points or values[1] < .003: break
        if d < 0: n, d = -n, -d
        axis = np.eye(3)[np.argmin(np.abs(n))]
        u = np.cross(n, axis); u /= np.linalg.norm(u); v = np.cross(n, u)
        result.append(dict(normal=n, offset=float(d), centre=centre, basis=np.array([u, v]), ids=ids))
        remaining = remaining[~np.isin(remaining, ids)]
    return result


def ring_supported(query, tree, uv, scale):
    """Only infer enclosed short gaps; an open outer boundary has an angular gap."""
    result = np.zeros(len(query), bool)
    for i, (q, s) in enumerate(zip(query, scale)):
        ids = tree.query_ball_point(q, max(.04, 2.5*s))
        if len(ids) < 6: continue
        delta = uv[ids]-q
        delta = delta[np.linalg.norm(delta, axis=1) > max(.003, .15*s)]
        if len(delta) < 6: continue
        angles = np.sort(np.arctan2(delta[:, 1], delta[:, 0]))
        result[i] = np.max(np.diff(np.r_[angles, angles[0]+2*np.pi])) < np.radians(155)
    return result


def ray_contradictions(probes, normal, offset, rays_tree, rays, radii):
    """Compare measured ranges with intersection along EACH measured ray.

    This does not reject a slanted plane simply for a radial depth difference.
    Contradiction includes nearer occluders AND farther returns through an opening.
    No matching ray is unknown, not proof of a solid surface.
    """
    r = np.linalg.norm(probes, axis=1)
    distances, ids = rays_tree.query(probes/np.maximum(r[:, None], 1e-9), k=min(4, len(rays)))
    if distances.ndim == 1: distances, ids = distances[:, None], ids[:, None]
    denom = rays[ids]@normal
    expected = -offset/np.where(np.abs(denom) > 1e-8, denom, 1e-8)
    near = distances < 2*np.sin(np.radians(.35)/2)
    contradict = near & (expected > 0) & (np.abs(radii[ids]-expected) > .08+.005*expected)
    return contradict.sum(axis=1) >= 2


def bounded_gap_support(probes, tree, uv, radius):
    """All seven probes need nearby bilateral/enclosing measured support.

    A scalar nearest-neighbour spacing can underestimate the sparse direction
    of an anisotropically sampled plane. This alternative never extends the
    convex observation boundary and does not remove the angular/ray gates.
    """
    result = np.ones(len(probes), bool)
    for i, triangle in enumerate(probes):
        for q in triangle:
            ids = tree.query_ball_point(q, radius)
            delta = uv[ids]-q
            delta = delta[np.linalg.norm(delta, axis=1) > .003]
            if len(delta) < 6:
                result[i] = False; break
            angles = np.sort(np.arctan2(delta[:, 1], delta[:, 0]))
            if np.max(np.diff(np.r_[angles, angles[0]+2*np.pi])) >= np.radians(155):
                result[i] = False; break
    return result


def angular_enclosed_support(probes, support_rays, support_angle_deg):
    """Enclosing measured support on the unit sphere, with no metre cutoff.

    Projecting a probe on the fitted plane and then onto a unit ray makes
    this test depend on angular sampling. The corresponding physical patch
    grows with range AND stretches with oblique incidence. A tangent chart
    around EACH probe avoids azimuth seams and pole singularities.
    """
    flat = np.asarray(probes, float).reshape(-1, 3)
    q = flat/np.maximum(np.linalg.norm(flat, axis=1)[:, None], 1e-12)
    tree = cKDTree(support_rays)
    radius = 2*np.sin(np.radians(support_angle_deg)/2)
    nearby = tree.query_ball_point(q, radius)
    good = np.zeros(len(q), bool)
    nearest = 2*np.arcsin(np.clip(tree.query(q)[0]/2, 0, 1))
    for i, ids in enumerate(nearby):
        if len(ids) < 6: continue
        axis = np.eye(3)[np.argmin(np.abs(q[i]))]
        u = np.cross(q[i], axis); u /= np.linalg.norm(u)
        basis = np.array([u, np.cross(q[i], u)])
        selected = support_rays[ids]
        xy = (selected@basis.T)/np.maximum((selected@q[i])[:, None], 1e-9)
        # Repeated/clumped returns cannot count as six independent supports.
        xy = xy[np.linalg.norm(xy, axis=1) > np.tan(np.radians(.03))]
        if len(xy) < 6: continue
        _, unique = np.unique(np.floor(xy/np.tan(np.radians(.10))).astype(np.int64),
                              axis=0, return_index=True)
        xy = xy[unique]
        if len(xy) < 6: continue
        angles = np.sort(np.arctan2(xy[:, 1], xy[:, 0]))
        good[i] = np.max(np.diff(np.r_[angles, angles[0]+2*np.pi])) < np.radians(155)
    return good.reshape(np.asarray(probes).shape[:-1]).all(axis=1), np.degrees(nearest).reshape(-1, 7)


def make_planar_mesh(points_mm, config=None, *, base=None):
    cfg = config or PlanarConfig(); started = time.perf_counter()
    if not .1 <= cfg.support_angle_deg <= 5 or not .1 <= cfg.max_angle_deg <= 5:
        raise ValueError('Invalid planar angular support configuration')
    p, source_ids = valid_points(points_mm, cfg)
    if base is None:
        base = make_range_baseline(points_mm, cfg)
    else:
        base_cfg = getattr(base, 'diagnostics', {}).get('config', {})
        if (base_cfg.get('min_range') != cfg.min_range
                or base_cfg.get('max_range') != cfg.max_range):
            raise ValueError('Baseline and planar reconstruction ranges must match')
    planes = fit_planes(p, cfg)
    if not planes:
        base.face_group = np.full(len(base.triangles), -1, np.int16)
        base.face_inferred = np.zeros(len(base.triangles), np.uint8)
        base.planes = []; base.planar_report = dict(config=asdict(cfg), planes=[],inferred_faces=0,max_shift_mm=0)
        return base
    radii = np.linalg.norm(p, axis=1); rays = p/radii[:, None]; ray_tree = cKDTree(rays)
    vertices = [base.vertices.copy()]; raw_vertices = [base.raw_vertices.copy()]
    faces = []; groups = []; inferred = []; summaries = []; offset = len(base.vertices)
    base_labels = np.full(len(base.vertices), -1, np.int16)
    for group, plane in enumerate(planes):
        n, d, basis, ids = plane['normal'], plane['offset'], plane['basis'], plane['ids']
        residual = np.abs(base.raw_vertices@n+d)
        base_labels[(base_labels < 0) & (residual <= cfg.plane_m+cfg.plane_per_m*np.linalg.norm(base.raw_vertices, axis=1))] = group
        uv_all = (p[ids]-plane['centre'])@basis.T
        # Reuse all raw support, not only the nearest return in angular buckets.
        # UV dedup limits numerical slivers, retains an actual measurement per cell.
        _, chosen = np.unique(np.floor(uv_all/cfg.dedup_m).astype(np.int64), axis=0, return_index=True)
        ids = ids[chosen]; uv = uv_all[chosen]
        if len(ids) < 3: continue
        tree = cKDTree(uv)
        dist, _ = tree.query(uv, k=min(7, len(uv)))
        scale = np.maximum(.020, dist[:, -1])
        try: triangles = Delaunay(uv).simplices
        except QhullError: continue
        tri_uv = uv[triangles]; tri_raw = p[ids][triangles]
        edge = np.linalg.norm(tri_uv[:, (0, 0, 1)]-tri_uv[:, (1, 2, 2)], axis=2)
        spacing = np.minimum(scale[triangles[:, (0, 0, 1)]], scale[triangles[:, (1, 2, 2)]])
        # Fit coplanarity globally, but mesh spatially connected local regions.
        # Sparse bridges cannot connect two separate coplanar objects.
        left = triangles[:, (0,0,1)].ravel(); right = triangles[:, (1,2,2)].ravel()
        strong = (edge <= 2.0*spacing).ravel()
        graph = coo_matrix((np.ones(strong.sum()),(left[strong],right[strong])),shape=(len(uv),len(uv)))
        _, components = connected_components(graph,directed=False)
        component_size = np.bincount(components)
        connected = (components[triangles] == components[triangles[:, :1]]).all(axis=1) & (component_size[components[triangles[:,0]]] >= 30)
        edge_ok = (edge <= cfg.connection_scale*spacing).all(axis=1)
        tri_rays = rays[ids][triangles]
        theta = np.arccos(np.clip(np.einsum('nki,nki->nk', tri_rays[:, (0, 0, 1)], tri_rays[:, (1, 2, 2)]), -1, 1))
        angle_ok = (theta <= np.radians(cfg.max_angle_deg)+1e-7).all(axis=1)
        angular_connected = connected
        if cfg.angular_gap_support:
            # Build a separate angular connectivity graph for recovery; do not
            # change the original metre-gated faces or their components.
            angular_strong = (theta <= np.radians(cfg.max_angle_deg)).ravel()
            angular_graph = coo_matrix((np.ones(angular_strong.sum()),
                (left[angular_strong], right[angular_strong])), shape=(len(uv),len(uv)))
            _, angular_components = connected_components(angular_graph, directed=False)
            angular_size = np.bincount(angular_components)
            angular_connected = (angular_components[triangles] == angular_components[triangles[:,:1]]).all(axis=1)
            angular_connected &= angular_size[angular_components[triangles[:,0]]] >= 30
        area = np.abs(np.cross(tri_uv[:, 1]-tri_uv[:, 0], tri_uv[:, 2]-tri_uv[:, 0]))/2
        shape_ok = area > 1e-7
        probes_weights = np.array([[1/3]*3, [.6,.2,.2], [.2,.6,.2], [.2,.2,.6], [.5,.5,0], [.5,0,.5], [0,.5,.5]])
        probe_uv = np.einsum('pk,nkj->npj', probes_weights, tri_uv)
        distances, nearest = tree.query(probe_uv.reshape(-1, 2))
        local = scale[nearest].reshape(-1, 7)
        distances = distances.reshape(-1, 7)
        measured = (distances <= .65*local).all(axis=1)
        supported = (distances <= 1.15*local).all(axis=1)
        infer_possible = ~measured & supported & edge_ok & angle_ok & shape_ok & (distances.max(axis=1) <= cfg.hole_radius_m)
        enclosed = np.zeros(len(triangles), bool)
        to_check = np.flatnonzero(infer_possible)
        enclosed[to_check] = ring_supported(probe_uv[to_check, 0], tree, uv, np.max(local[to_check], axis=1))
        support_ok = measured | enclosed
        projected_probes = np.einsum('npj,jk->npk', probe_uv, basis)+plane['centre']
        projected_probes -= (projected_probes@n+d)[..., None]*n
        ray_bad = np.zeros(len(triangles), bool)
        eligible = np.flatnonzero(edge_ok & angle_ok & shape_ok & support_ok)
        if len(eligible):
            ray_bad[eligible] = ray_contradictions(projected_probes[eligible].reshape(-1, 3), n, d, ray_tree, rays, radii).reshape(-1, 7).any(axis=1)
        accept = edge_ok & angle_ok & shape_ok & support_ok & ~ray_bad & connected
        original_accept = accept.copy()
        # Only revisit local spacing/support refusals in the same UV
        # triangulation. No overlay mesh, long bridges or whole-plane hull.
        recovery_candidates = np.flatnonzero(~accept & angle_ok & shape_ok & connected
            & ~ray_bad & (edge.max(axis=1) <= 2*cfg.hole_radius_m)
            & (distances.max(axis=1) <= cfg.hole_radius_m)
            & (area/np.maximum(edge.max(axis=1)**2, 1e-12) >= .03))
        recovered = np.zeros(len(triangles), bool)
        recovery_nearest_deg = np.empty((0,7))
        if cfg.recover_supported_gaps and len(recovery_candidates):
            enclosed_all = bounded_gap_support(probe_uv[recovery_candidates], tree, uv, cfg.hole_radius_m)
            supported_ids = recovery_candidates[enclosed_all]
            if len(supported_ids):
                conflicts = ray_contradictions(projected_probes[supported_ids].reshape(-1,3),
                    n,d,ray_tree,rays,radii).reshape(-1,7).any(axis=1)
                recovered[supported_ids[~conflicts]] = True
            accept |= recovered
        metre_recovered = recovered.copy()
        angular_recovered = np.zeros(len(triangles), bool)
        angular_area = np.linalg.norm(np.cross(tri_rays[:,1]-tri_rays[:,0],
            tri_rays[:,2]-tri_rays[:,0]),axis=1)/2
        angular_edge = np.linalg.norm(tri_rays[:,(0,0,1)]-tri_rays[:,(1,2,2)],axis=2)
        # A good angular triangle can be stretched on a grazing plane. Reject
        # angular slivers, not valid oblique patches merely elongated in metres.
        angular_shape_ok = angular_area/np.maximum(angular_edge.max(axis=1)**2,1e-12) >= .03
        angular_candidates = np.flatnonzero(~accept & angle_ok & shape_ok & angular_connected
            & ~ray_bad & angular_shape_ok)
        if cfg.recover_supported_gaps and cfg.angular_gap_support and len(angular_candidates):
            surrounded, recovery_nearest_deg = angular_enclosed_support(projected_probes[angular_candidates],
                rays[plane['ids']], min(cfg.support_angle_deg, cfg.max_angle_deg))
            supported_ids = angular_candidates[surrounded]
            if len(supported_ids):
                conflicts = ray_contradictions(projected_probes[supported_ids].reshape(-1,3),
                    n,d,ray_tree,rays,radii).reshape(-1,7).any(axis=1)
                angular_recovered[supported_ids[~conflicts]] = True
            recovered |= angular_recovered
            accept |= angular_recovered
        display = p[ids]-(p[ids]@n+d)[:, None]*n
        # A plane projection must not move a measured boundary point outside ROI.
        # Keep its original measured coordinate rather than inventing a clip vertex.
        display_r = np.linalg.norm(display, axis=1)
        outside = (display_r < cfg.min_range) | (display_r > cfg.max_range)
        display[outside] = p[ids][outside]
        vertices.append(display.astype(np.float32)); raw_vertices.append(p[ids].astype(np.float32))
        faces.append((triangles[accept]+offset).astype(np.uint32)); offset += len(ids)
        groups.append(np.full(accept.sum(), group, np.int16)); inferred.append((~measured[accept] | recovered[accept]).astype(np.uint8))
        summaries.append(dict(group=group, raw_support=int(len(plane['ids'])), vertices=len(ids),
            candidates=len(triangles), accepted=int(accept.sum()), inferred=int((accept & (~measured | recovered)).sum()),
            original_accepted=int(original_accept.sum()), recovered=int(recovered.sum()),
            recovery_candidates=len(recovery_candidates),
            metre_recovered=int(metre_recovered.sum()), angular_recovered=int(angular_recovered.sum()),
            angular_candidates=len(angular_candidates),
            angular_support_rejected=int(len(angular_candidates)-(surrounded.sum() if cfg.recover_supported_gaps and cfg.angular_gap_support and len(angular_candidates) else 0)),
            recovered_max_edge_m=float(edge[angular_recovered].max(initial=0)),
            recovered_max_probe_distance_m=float(distances[angular_recovered].max(initial=0)),
            angular_support_nearest_p95_deg=float(np.percentile(recovery_nearest_deg,95)) if recovery_nearest_deg.size else 0,
            reject_angle=int((~angle_ok).sum()), reject_spacing=int((~edge_ok).sum()),
            reject_support=int((~support_ok).sum()), reject_ray=int(ray_bad.sum()), reject_degenerate=int((~shape_ok).sum()),
            reject_component=int((~connected).sum()), components=int(len(component_size)),
            spacing_median_m=float(np.median(scale)), normal=n.tolist(), offset_m=d,
            residual_p95_mm=float(np.percentile(np.abs(p[plane['ids']]@n+d),95)*1000)))
        plane.update(uv=uv, scale=scale)
    labels = base_labels[base.triangles]
    same_plane = (labels[:, 0] >= 0) & (labels == labels[:, :1]).all(axis=1)
    # Separate supported folds instead of spanning two planes with one face.
    mixed_planes = ((labels >= 0).sum(axis=1) >= 2) & (np.max(labels, axis=1) != np.min(np.where(labels >= 0, labels, 32767), axis=1))
    keep = ~(same_plane | mixed_planes)
    faces.insert(0, base.triangles[keep].copy()); groups.insert(0, np.full(keep.sum(), -1, np.int16)); inferred.insert(0, np.zeros(keep.sum(), np.uint8))
    diagnostics = dict(candidates=sum(s['candidates'] for s in summaries)+int(keep.sum()))
    mesh = _mesh(np.concatenate(vertices), np.concatenate(faces), len(p), started, diagnostics)
    mesh.raw_vertices = np.concatenate(raw_vertices); mesh.face_group = np.concatenate(groups); mesh.face_inferred = np.concatenate(inferred)
    shift = np.linalg.norm(mesh.vertices-mesh.raw_vertices, axis=1)*1000
    mesh.p95_shift_mm = float(np.percentile(shift,95)) if len(shift) else 0
    mesh.planes = planes
    audit = getattr(base, 'audit', None)
    recoverable = 0
    if audit is not None and len(audit['candidates']):
        labs = base_labels[audit['candidates']]
        recoverable = int(((audit['reasons'] != 0) & (labs[:, 0] >= 0) & (labs == labs[:, :1]).all(axis=1)).sum())
    mesh.planar_report = dict(config=asdict(cfg), planes=summaries, baseline_rejected_same_plane=recoverable,
        baseline_same_plane_faces_replaced=int(same_plane.sum()), baseline_cross_plane_faces_removed=int(mixed_planes.sum()),
        inferred_faces=int(mesh.face_inferred.sum()), max_shift_mm=float(shift.max(initial=0)),
        shared_corner_edges=False, corner_policy='Independent measured planes; no unsupported intersection stitching')
    return mesh
