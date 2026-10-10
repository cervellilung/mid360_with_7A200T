"""PC hybrid: preserve angular support; constrain display and finite creases.

No history, whole-plane retriangulation, convex-hull filling or semantic ceiling
special case. Raw coordinates and the source face of every output face survive.
"""
from dataclasses import asdict
from itertools import combinations
import time
import numpy as np
from scipy.spatial import cKDTree
from .planar_mesh import (PlanarConfig, valid_points, make_range_baseline,
                          fit_planes, ray_contradictions)
from .adaptive_mesh import _mesh
from .surface_distance import triangle_distances


def _edges(faces):
    edges = np.sort(np.concatenate([faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]]]), axis=1)
    return np.unique(edges, axis=0, return_counts=True)


def _guard_projection(raw, display, faces, cfg):
    """Monotone rollback; no face is dropped to make a projection succeed."""
    rollback = np.zeros(len(raw), bool)
    radius = np.linalg.norm(display, axis=1)
    bound = cfg.plane_m+cfg.plane_per_m*np.linalg.norm(raw, axis=1)
    bad = ((radius < cfg.min_range) | (radius > cfg.max_range)
           | (np.linalg.norm(display-raw, axis=1) > bound+1e-8))
    display[bad] = raw[bad]; rollback |= bad
    original = raw[faces]
    old_normal = np.cross(original[:, 1]-original[:, 0], original[:, 2]-original[:, 0])
    old_area = np.linalg.norm(old_normal, axis=1)
    for _ in range(8):
        tri = display[faces]
        normal = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
        area = np.linalg.norm(normal, axis=1)
        dot = np.einsum('ni,ni->n', normal, old_normal)
        bad = (area < .25*old_area) | (dot < .8*area*old_area)
        bad &= np.any(np.linalg.norm(display[faces]-original, axis=2) > 1e-9, axis=1)
        if not bad.any(): break
        ids = np.unique(faces[bad]); display[ids] = raw[ids]; rollback[ids] = True
    else:
        rollback |= np.linalg.norm(display-raw, axis=1) > 1e-9
        display[:] = raw
    return rollback


def _straighten_boundary(raw, display, faces, labels, planes, cfg):
    """Fit short boundary chains, never bridge, extend or add faces."""
    edges, counts = _edges(faces); boundary = edges[counts == 1]
    adjacency = {}
    for a, b in boundary:
        if labels[a] >= 0 and labels[a] == labels[b]:
            adjacency.setdefault(int(a), []).append(int(b)); adjacency.setdefault(int(b), []).append(int(a))
    proposed = display.copy(); fitted = {}; tested = 0
    for vertex, neighbours in adjacency.items():
        if len(neighbours) != 2: continue  # An endpoint/junction stays anchored.
        group = labels[vertex]; visited = {vertex}; frontier = [vertex]
        for _ in range(10):
            frontier = [j for i in frontier for j in adjacency.get(i, [])
                        if j not in visited and labels[j] == group
                        and np.linalg.norm(raw[j]-raw[vertex]) <= .30]
            if not frontier: break
            visited.update(frontier)
            if len(visited) >= 24: break
        if len(visited) < 6: continue
        ids = np.array(sorted(visited)); pts = display[ids]; centre = pts.mean(axis=0)
        _, values, vectors = np.linalg.svd(pts-centre, full_matrices=False)
        if values[0] < .15 or values[1] > .12*values[0]: continue
        direction = vectors[0]; along = (pts-centre)@direction
        target = centre + ((display[vertex]-centre)@direction)*direction
        residual = np.linalg.norm(pts-centre-along[:, None]*direction, axis=1)
        bound = cfg.plane_m+cfg.plane_per_m*np.linalg.norm(raw[vertex])
        tested += 1
        if np.percentile(residual, 95) > bound: continue
        if np.linalg.norm(target-raw[vertex]) > bound: continue
        location = (target-centre)@direction
        if not along.min()+.01 < location < along.max()-.01: continue
        proposed[vertex] = target
        fitted[vertex] = (centre, direction)
    return proposed, fitted, dict(tested=tested, candidates=len(fitted))


def _crease_patches(raw, display, faces, planes, points, ray_tree, rays, radii, cfg):
    """Split existing mixed faces only inside measured, bilateral line support.

    Intersection points are cached by source edge and plane pair. A transaction
    is discarded if any incident face cannot accept the split (no T junction).
    """
    candidates = {}; seam = {}; pairs_report = []
    edges_to_faces = {}
    for fi, face in enumerate(faces):
        for a, b in ((face[0], face[1]), (face[1], face[2]), (face[2], face[0])):
            edges_to_faces.setdefault(tuple(sorted((int(a), int(b)))), []).append(fi)
    tolerance = cfg.plane_m+cfg.plane_per_m*np.linalg.norm(raw, axis=1)
    all_residual = np.array([np.abs(raw@p['normal']+p['offset']) for p in planes])
    nearest = np.argmin(all_residual, axis=0) if len(planes) else np.full(len(raw), -1)
    supported_vertex = all_residual.min(axis=0) <= tolerance if len(planes) else np.zeros(len(raw), bool)
    for ga, gb in combinations(range(len(planes)), 2):
        pa, pb = planes[ga], planes[gb]; na, nb = pa['normal'], pb['normal']
        angle = np.degrees(np.arccos(np.clip(abs(na@nb), 0, 1)))
        if angle < 20: continue
        axis = np.cross(na, nb); axis /= np.linalg.norm(axis)
        origin = np.linalg.lstsq(np.array([na, nb]), -np.array([pa['offset'], pb['offset']]), rcond=None)[0]
        bins = []
        for plane in (pa, pb):
            sample = points[plane['ids']]; along = (sample-origin)@axis
            distance = np.linalg.norm(sample-origin-along[:, None]*axis, axis=1)
            spacing = cKDTree(sample).query(sample, k=min(7, len(sample)))[0][:, -1]
            width = np.minimum(.20, np.maximum(.04, 2*spacing))
            b, c = np.unique(np.floor(along[distance <= width]/.1).astype(int), return_counts=True)
            bins.append(set(b[c >= 6]))
        supported_bins = bins[0] & bins[1]
        if supported_bins:
            ordered = np.array(sorted(supported_bins))
            probe = origin+(ordered[:, None]+.5)*.1*axis
            valid = (np.linalg.norm(probe, axis=1) <= cfg.max_range)
            valid &= ~ray_contradictions(probe, na, pa['offset'], ray_tree, rays, radii)
            valid &= ~ray_contradictions(probe, nb, pb['offset'], ray_tree, rays, radii)
            supported_bins = set(ordered[valid])
        report = dict(pair=[ga, gb], angle_deg=float(angle), supported_bins=len(supported_bins), proposed_faces=0)
        pairs_report.append(report)
        if not supported_bins: continue
        labs = nearest[faces]
        eligible = (supported_vertex[faces].all(axis=1)
                    & ((labs == ga) | (labs == gb)).all(axis=1)
                    & (labs == ga).any(axis=1) & (labs == gb).any(axis=1))
        for fi in np.flatnonzero(eligible):
            if fi in candidates: continue  # Triple junctions are not zipped.
            face = faces[fi]; signed = all_residual[ga, face]-all_residual[gb, face]
            if np.any(np.abs(signed) < 1e-8): continue
            crossings = {}; failed = False
            for k in range(3):
                j = (k+1) % 3
                if signed[k]*signed[j] >= 0: continue
                a, b = int(face[k]), int(face[j]); alpha = signed[k]/(signed[k]-signed[j])
                q = (1-alpha)*raw[a]+alpha*raw[b]
                along = (q-origin)@axis; target = origin+along*axis
                bound = cfg.plane_m+cfg.plane_per_m*np.linalg.norm(q)
                if (int(np.floor(along/.1)) not in supported_bins
                        or np.linalg.norm(q-target) > bound
                        or not cfg.min_range <= np.linalg.norm(target) <= cfg.max_range):
                    failed = True; break
                edge = tuple(sorted((a, b))); key = (ga, gb, *edge)
                crossings[edge] = key; seam[key] = (target, q)
            if failed or len(crossings) != 2: continue
            pieces = []
            for group, sign in ((ga, -1), (gb, 1)):
                polygon = []
                for k in range(3):
                    j = (k+1) % 3; a, b = int(face[k]), int(face[j])
                    if sign*signed[k] > 0: polygon.append(a)
                    key = crossings.get(tuple(sorted((a, b))))
                    if key is not None: polygon.append(key)
                for k in range(1, len(polygon)-1): pieces.append((group, [polygon[0], polygon[k], polygon[k+1]]))
            xyz = lambda key: seam[key][0] if isinstance(key, tuple) else display[key]
            tri = np.array([[xyz(i) for i in polygon] for _, polygon in pieces])
            old = raw[face]; old_n = np.cross(old[1]-old[0], old[2]-old[0]); old_area = np.linalg.norm(old_n)
            normals = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0]); areas = np.linalg.norm(normals, axis=1)
            probes = np.array([old.mean(axis=0), (old[0]+old[1])/2, (old[1]+old[2])/2, (old[0]+old[2])/2])
            bound = cfg.plane_m+cfg.plane_per_m*np.linalg.norm(probes, axis=1)
            # A supported 90-degree crease unfolds a chamfer by sqrt(2).
            if ((areas <= 1e-9).any() or not .75*old_area <= areas.sum() <= 1.60*old_area
                    or (normals@old_n < .5*areas*old_area).any()
                    or any(triangle_distances(q, tri).min() > b+1e-6 for q, b in zip(probes, bound))): continue
            candidates[int(fi)] = (pieces, crossings); report['proposed_faces'] += 1
    # Every face sharing a cut edge must make the same cut; prune to a fixed point.
    for _ in range(len(candidates)+1):
        remove = []
        for fi, (_, cuts) in candidates.items():
            if any(any(adj not in candidates or candidates[adj][1].get(edge) != key
                       for adj in edges_to_faces[edge]) for edge, key in cuts.items()): remove.append(fi)
        if not remove: break
        for fi in remove: del candidates[fi]
    vertices = list(display); measured = list(raw); observed = [True]*len(raw); indices = {}
    output = []; groups = []; origins = []; inferred = []
    for fi, face in enumerate(faces):
        if fi not in candidates:
            output.append(face.tolist()); groups.append(-1); origins.append(fi); inferred.append(False); continue
        pieces, _ = candidates[fi]
        for group, polygon in pieces:
            ids = []
            for vertex in polygon:
                if isinstance(vertex, tuple):
                    if vertex not in indices:
                        indices[vertex] = len(vertices); target, q = seam[vertex]
                        vertices.append(target); measured.append(q); observed.append(False)
                    vertex = indices[vertex]
                ids.append(vertex)
            output.append(ids); groups.append(group); origins.append(fi); inferred.append(True)
    return (np.asarray(vertices, float).reshape(-1, 3), np.asarray(measured, float).reshape(-1, 3),
            np.asarray(output, np.uint32).reshape(-1, 3), np.array(groups, np.int16),
            np.array(origins), np.array(inferred, np.uint8), np.array(observed),
            dict(pairs=pairs_report, split_source_faces=len(candidates), shared_vertices=len(indices)))


def make_hybrid_mesh(points_mm, config=None):
    cfg = config or PlanarConfig(); start = time.perf_counter(); stages = {}
    tick = time.perf_counter(); p, _ = valid_points(points_mm, cfg)
    base = make_range_baseline(points_mm, cfg, include_geometry=True)
    stages['angular_ms'] = (time.perf_counter()-tick)*1000
    tick = time.perf_counter(); planes = fit_planes(p, cfg)
    stages['fit_ms'] = (time.perf_counter()-tick)*1000
    raw = base.raw_vertices.astype(float); display = raw.copy(); faces = base.triangles.copy()
    labels = np.full(len(raw), -1, np.int16); radius = np.linalg.norm(raw, axis=1)
    geometry = getattr(base, 'local_geometry', None)
    ray_tree = None
    counts = dict(projected=0, ray_rejected=0, boundary_candidates=0, boundary_moved=0, rollbacks=0)
    tick = time.perf_counter()
    if len(p) and planes and geometry is not None:
        radii = np.linalg.norm(p, axis=1); rays = p/radii[:, None]; ray_tree = cKDTree(rays)
        tolerance = cfg.plane_m+cfg.plane_per_m*radius
        best = np.full(len(raw), np.inf)
        for group, plane in enumerate(planes):
            n, d = plane['normal'], plane['offset']; residual = np.abs(raw@n+d)
            agree = np.abs(geometry['normal']@n) >= np.cos(np.radians(25))
            valid = geometry['reliable'] & agree & (residual <= tolerance) & (residual < best)
            labels[valid] = group; best[valid] = residual[valid]
        support = geometry['supported']; neighbour_labels = labels[geometry['neighbours']]
        fraction = ((neighbour_labels == labels[:, None]) & support).sum(axis=1)/np.maximum(support.sum(axis=1), 1)
        interior = (labels >= 0) & (support.sum(axis=1) >= 8) & (fraction >= .85)
        for group, plane in enumerate(planes):
            ids = np.flatnonzero(interior & (labels == group)); n, d = plane['normal'], plane['offset']
            proposed = raw[ids]-(raw[ids]@n+d)[:, None]*n
            bad = ray_contradictions(proposed, n, d, ray_tree, rays, radii) if len(ids) else np.zeros(0, bool)
            counts['ray_rejected'] += int(bad.sum()); display[ids[~bad]] = proposed[~bad]
        counts['projected'] = int((np.linalg.norm(display-raw, axis=1) > 1e-9).sum())
    stages['projection_ms'] = (time.perf_counter()-tick)*1000
    tick = time.perf_counter()
    if planes and len(faces):
        proposed, fitted, boundary_info = _straighten_boundary(raw, display, faces, labels, planes, cfg)
        # The full-frame guard protects tiny triangles after boundary adjustment.
        counts['boundary_candidates'] = boundary_info['candidates']; display = proposed
    else: fitted = {}
    rolled = _guard_projection(raw, display, faces, cfg); counts['rollbacks'] = int(rolled.sum())
    stable = [i for i in fitted if not rolled[i] and np.linalg.norm(display[i]-raw[i]) > 1e-9]
    counts['boundary_moved'] = len(stable)
    def line_error(coords):
        errors = [np.linalg.norm(coords[i]-fitted[i][0]-((coords[i]-fitted[i][0])@fitted[i][1])*fitted[i][1]) for i in stable]
        return float(np.percentile(errors, 95)*1000) if errors else None
    boundary_error = dict(raw_p95_mm=line_error(raw), refined_p95_mm=line_error(display), samples=len(stable))
    stages['boundary_guard_ms'] = (time.perf_counter()-tick)*1000
    tick = time.perf_counter()
    original_faces = faces.copy()
    if len(planes) >= 2 and ray_tree is not None and len(faces):
        display, measured, faces, groups, origins, inferred, observed, corners = _crease_patches(
            raw, display, faces, planes, p, ray_tree, rays, radii, cfg)
    else:
        measured = raw.copy(); groups = np.full(len(faces), -1, np.int16)
        origins = np.arange(len(faces)); inferred = np.zeros(len(faces), np.uint8)
        observed = np.ones(len(raw), bool); corners = dict(pairs=[], split_source_faces=0, shared_vertices=0)
    stages['crease_ms'] = (time.perf_counter()-tick)*1000
    tick = time.perf_counter()
    # Label unsplit faces only when all three original vertices agree.
    unsplit = inferred == 0; labs = labels[faces[unsplit]]
    same = (labs[:, 0] >= 0) & (labs == labs[:, :1]).all(axis=1)
    ids = np.flatnonzero(unsplit)[same]; groups[ids] = labs[same, 0]
    mesh = _mesh(display, faces, len(p), start, dict(candidates=len(faces), algorithm='hybrid_angular_planar_v1',config=asdict(cfg)))
    mesh.raw_vertices = measured.astype(np.float32); mesh.observed = observed
    mesh.face_group = groups; mesh.face_inferred = inferred; mesh.face_origin = origins
    region = np.zeros(len(faces), np.uint8)
    changed = np.linalg.norm(display[:len(raw)]-raw, axis=1) > 1e-9
    region[unsplit] = changed[faces[unsplit]].any(axis=1).astype(np.uint8)
    if stable: region[unsplit & np.isin(origins, np.flatnonzero(np.isin(original_faces, stable).any(axis=1)))] = 2
    region[inferred > 0] = 3
    region[unsplit & rolled[original_faces[origins]].any(axis=1)] = 4
    mesh.face_region = region
    # Per-face normals allow shared geometric crease vertices with hard shading.
    tri = mesh.vertices[mesh.triangles]; fn = np.cross(tri[:, 1]-tri[:, 0], tri[:, 2]-tri[:, 0])
    fn /= np.maximum(np.linalg.norm(fn, axis=1, keepdims=True), 1e-12)
    for group, plane in enumerate(planes):
        planar = groups == group; normal = plane['normal'].copy()
        if plane['offset'] < 0: normal *= -1
        fn[planar] = normal
    mesh.face_normals = fn.astype(np.float32)
    stages['normals_ms'] = (time.perf_counter()-tick)*1000
    shift = np.linalg.norm(mesh.vertices.astype(float)-measured, axis=1)*1000
    mesh.p95_shift_mm = float(np.percentile(shift, 95)) if len(shift) else 0.
    mesh.planes = planes; mesh.build_ms = (time.perf_counter()-start)*1000
    mesh.hybrid_report = dict(config=asdict(cfg), stages_ms=stages, counts=counts, corners=corners,
        boundary_error=boundary_error, max_shift_mm=float(shift.max(initial=0)),
        original_faces=len(original_faces), retained_source_faces=len(np.unique(origins)),
        inferred_faces=int(inferred.sum()), projection='bounded plane display; measured raw XYZ retained',
        regions={'unchanged':0,'projected':1,'boundary':2,'crease':3,'rollback':4},
        planes=[dict(group=i,normal=x['normal'].tolist(),offset_m=x['offset'],support=len(x['ids'])) for i,x in enumerate(planes)],
        limitations=['No semantic opening truth','No accumulated map/pose','No entire-plane replacement','PC offline; 300ms not claimed'])
    return mesh
