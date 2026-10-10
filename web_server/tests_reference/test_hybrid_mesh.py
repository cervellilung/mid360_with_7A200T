import unittest
from unittest.mock import patch
import numpy as np
from scipy.spatial import cKDTree
from web_server.car_showcase.hybrid_mesh import make_hybrid_mesh, _guard_projection, _crease_patches
from web_server.car_showcase.planar_mesh import PlanarConfig, make_range_baseline


class HybridTests(unittest.TestCase):
    def wall(self):
        y,z=np.meshgrid(np.arange(-1,1.001,.035),np.arange(-.6,.601,.035))
        rng=np.random.default_rng(5)
        return np.c_[3000+rng.normal(0,4,y.size),y.ravel()*1000,z.ravel()*1000].astype(np.int32)

    def test_retains_source_faces_and_raw_measurements(self):
        p=self.wall(); base=make_range_baseline(p); m=make_hybrid_mesh(p)
        self.assertEqual(len(np.unique(m.face_origin)),len(base.triangles))
        np.testing.assert_array_equal(m.raw_vertices[:len(base.vertices)],base.raw_vertices)
        self.assertLessEqual(m.hybrid_report['max_shift_mm'],26.001)
        self.assertGreater(m.hybrid_report['counts']['projected'],100)

    def test_no_plane_exact_fallback(self):
        p=self.wall();base=make_range_baseline(p)
        with patch('web_server.car_showcase.hybrid_mesh.fit_planes',return_value=[]):m=make_hybrid_mesh(p)
        np.testing.assert_array_equal(base.vertices,m.vertices)
        np.testing.assert_array_equal(base.triangles,m.triangles)

    def test_deterministic_and_far_returns_ignored(self):
        p=self.wall();far=p.copy();far[:,0]=8000
        a=make_hybrid_mesh(p);b=make_hybrid_mesh(np.concatenate([p,far]))
        np.testing.assert_array_equal(a.vertices,b.vertices)
        np.testing.assert_array_equal(a.triangles,b.triangles)

    def test_door_remains_open(self):
        p=self.wall();p=p[(np.abs(p[:,1])>300)|(np.abs(p[:,2])>400)]
        m=make_hybrid_mesh(p);centres=m.vertices[m.triangles].mean(axis=1)
        self.assertFalse(((np.abs(centres[:,1])<.20)&(np.abs(centres[:,2])<.3)).any())

    def test_sparse_slanted_surface_keeps_angular_topology(self):
        p=self.wall()[::5];p[:,0]+=p[:,1]//3
        base=make_range_baseline(p);m=make_hybrid_mesh(p)
        self.assertEqual(len(base.triangles),len(m.triangles))

    def test_projection_flip_and_roi_rollback(self):
        raw=np.array([[3.,0,0],[3.,.001,0],[3.,0,.001]])
        proposed=raw.copy();proposed[1]=raw[0]+[0,-.001,0]
        rolled=_guard_projection(raw,proposed,np.array([[0,1,2]]),PlanarConfig())
        self.assertTrue(rolled.any());np.testing.assert_array_equal(raw,proposed)
        raw=np.array([[6.,0,0],[5.999,0,0],[5.999,.001,0]])
        proposed=raw.copy();proposed[0,0]+=.001
        self.assertTrue(_guard_projection(raw,proposed,np.array([[0,1,2]]),PlanarConfig())[0])

    def corner_fixture(self):
        # Two perpendicular observed strips, dense bilateral support along z.
        z,s=np.meshgrid(np.arange(0,.201,.005),np.arange(0,.041,.005))
        a=np.c_[np.full(z.size,3.),1.5-s.ravel(),z.ravel()]
        b=np.c_[3.-s.ravel(),np.full(z.size,1.5),z.ravel()]
        points=np.r_[a,b];r=np.linalg.norm(points,axis=1);rays=points/r[:,None]
        planes=[dict(normal=np.array([-1.,0,0]),offset=3.,ids=np.arange(len(a))),
                dict(normal=np.array([0,-1.,0]),offset=1.5,ids=np.arange(len(a),len(points)))]
        raw=np.array([[3,1.48,.02],[2.98,1.5,.02],[3,1.48,.08],[2.98,1.5,.08]])
        faces=np.array([[0,1,2],[1,3,2]],np.uint32)
        return raw,faces,planes,points,cKDTree(rays),rays,r

    def test_crease_shared_vertices_hard_normals(self):
        raw,faces,planes,points,tree,rays,r=self.corner_fixture()
        out=_crease_patches(raw,raw.copy(),faces,planes,points,tree,rays,r,PlanarConfig())
        v,measured,f,groups,origin,inferred,observed,report=out
        self.assertEqual(report['split_source_faces'],2)
        self.assertGreater(report['shared_vertices'],0)
        self.assertEqual(set(groups),{0,1})
        self.assertEqual(set(origin),{0,1})
        shared=np.flatnonzero(~observed)
        np.testing.assert_allclose(v[shared,:2],np.tile([3,1.5],(len(shared),1)))
        for i in shared:self.assertTrue((groups[(f==i).any(axis=1)]==0).any() and (groups[(f==i).any(axis=1)]==1).any())

    def test_missing_bilateral_support_keeps_unknown(self):
        raw,faces,planes,points,tree,rays,r=self.corner_fixture();planes[1]['ids']=planes[1]['ids'][:3]
        out=_crease_patches(raw,raw.copy(),faces,planes,points,tree,rays,r,PlanarConfig())
        self.assertEqual(out[-1]['split_source_faces'],0)
        np.testing.assert_array_equal(out[2],faces)

    def test_non_right_angle_is_not_forced_to_ninety(self):
        raw,faces,planes,points,tree,rays,r=self.corner_fixture()
        slope=np.tan(np.radians(12));ids=planes[1]['ids']
        points[ids,1]=1.5+(3-points[ids,0])*slope
        raw[[1,3],1]=1.5+(3-raw[[1,3],0])*slope
        n=np.array([-np.sin(np.radians(12)),-np.cos(np.radians(12)),0])
        planes[1]['normal']=n;planes[1]['offset']=-n@np.array([3,1.5,0])
        r=np.linalg.norm(points,axis=1);rays=points/r[:,None]
        out=_crease_patches(raw,raw.copy(),faces,planes,points,cKDTree(rays),rays,r,PlanarConfig())
        self.assertEqual(out[-1]['split_source_faces'],2)
        self.assertAlmostEqual(out[-1]['pairs'][0]['angle_deg'],78.)

    def test_failed_incident_patch_does_not_leave_t_junction(self):
        raw,faces,planes,points,tree,rays,r=self.corner_fixture()
        raw[3,0]=2.6  # One adjacent face cannot stay within the displacement bound.
        out=_crease_patches(raw,raw.copy(),faces,planes,points,tree,rays,r,PlanarConfig())
        self.assertEqual(out[-1]['split_source_faces'],0)
        np.testing.assert_array_equal(out[2],faces)

    def test_foreground_ray_conflicts_reject_corner(self):
        raw,faces,planes,points,tree,rays,r=self.corner_fixture()
        with patch('web_server.car_showcase.hybrid_mesh.ray_contradictions',side_effect=lambda p,*a:np.ones(len(p),bool)):
            out=_crease_patches(raw,raw.copy(),faces,planes,points,tree,rays,r,PlanarConfig())
        self.assertEqual(out[-1]['split_source_faces'],0)

    def test_empty(self):
        m=make_hybrid_mesh(np.empty((0,3)))
        self.assertEqual(len(m.triangles),0)


if __name__=='__main__':unittest.main()
