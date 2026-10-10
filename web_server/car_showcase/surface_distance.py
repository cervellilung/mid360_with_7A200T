"""Distance to finite triangles, including edges, not merely infinite planes."""
import numpy as np
from scipy.spatial import cKDTree


def triangle_distances(point, triangles):
    a, b, c = triangles[:, 0], triangles[:, 1], triangles[:, 2]
    ab, ac, ap = b-a, c-a, point-a
    normal = np.cross(ab, ac); nn = np.sum(normal*normal, axis=1)
    height = np.einsum('ij,ij->i', ap, normal)/np.maximum(nn, 1e-30)
    projected = ap-height[:, None]*normal
    aa = np.sum(ab*ab, axis=1); cc = np.sum(ac*ac, axis=1); dot = np.sum(ab*ac, axis=1)
    den = aa*cc-dot*dot
    u = (cc*np.sum(projected*ab,axis=1)-dot*np.sum(projected*ac,axis=1))/np.maximum(den,1e-30)
    v = (aa*np.sum(projected*ac,axis=1)-dot*np.sum(projected*ab,axis=1))/np.maximum(den,1e-30)
    inside = (u >= 0) & (v >= 0) & (u+v <= 1) & (nn > 1e-20)
    squared = np.where(inside, height*height*nn, np.inf)
    for x, y in ((a,b),(b,c),(c,a)):
        edge = y-x; t = np.sum((point-x)*edge,axis=1)/np.maximum(np.sum(edge*edge,axis=1),1e-30)
        delta = point-(x+np.clip(t,0,1)[:,None]*edge)
        squared = np.minimum(squared,np.sum(delta*delta,axis=1))
    return np.sqrt(squared)


def surface_distances(points, mesh):
    tri = mesh.vertices[mesh.triangles].astype(np.float64)
    if not len(tri): return np.full(len(points), np.inf)
    centres = tri.mean(axis=1); bounds = np.linalg.norm(tri-centres[:,None],axis=2).max(axis=1)
    tree = cKDTree(centres); bound = float(bounds.max())
    _, initial = tree.query(points, k=min(12,len(tri)))
    initial = np.asarray(initial).reshape(len(points), -1)
    out = np.empty(len(points))
    for i, point in enumerate(points):
        upper = triangle_distances(point,tri[initial[i]]).min()
        # Any closer finite face has its centre inside upper+bounding_radius.
        ids = tree.query_ball_point(point,upper+bound+1e-9)
        ids = np.asarray(ids)
        ids = ids[np.linalg.norm(centres[ids]-point,axis=1)-bounds[ids] <= upper+1e-9]
        out[i] = triangle_distances(point,tri[ids]).min()
    return out


def summary(distances):
    finite = distances[np.isfinite(distances)]
    return dict(points=len(distances), covered_50mm=float((distances <= .05).mean()) if len(distances) else 0,
        uncovered_50mm=float((distances > .05).mean()) if len(distances) else 1,
        p50_mm=float(np.percentile(finite,50)*1000) if len(finite) else None,
        p95_mm=float(np.percentile(finite,95)*1000) if len(finite) else None,
        rmse_mm=float(np.sqrt(np.mean(finite**2))*1000) if len(finite) else None,
        infinite=int((~np.isfinite(distances)).sum()))
