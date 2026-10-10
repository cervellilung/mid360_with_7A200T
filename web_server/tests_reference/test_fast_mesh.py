"""Geometry boundaries for the faster PC display candidate (not timing tests)."""
import unittest
import numpy as np
from web_server.car_showcase.fast_mesh import make_fast_mesh,FastConfig
from web_server.tests_reference.test_adaptive_mesh import wall


class FastMeshTests(unittest.TestCase):
    def test_depth_step_and_opening_remain_open(self):
        points=wall(2.,.85);points[points[:,1]>0]*=3
        mesh=make_fast_mesh(points);tri=mesh.raw_vertices[mesh.triangles]
        self.assertFalse(np.any((tri[:,:,0].min(axis=1)<2.5)&(tri[:,:,0].max(axis=1)>5.5)))
        mesh=make_fast_mesh(wall(4.,.85,gap=3.))
        tri=mesh.raw_vertices[mesh.triangles]
        self.assertFalse(np.any((tri[:,:,1].min(axis=1)<-.2)&(tri[:,:,1].max(axis=1)>.2)))

    def test_far_slanted_plane_and_raw_measurements(self):
        points=wall(7.,1.5,slope=.7);copy=points.copy()
        mesh=make_fast_mesh(points)
        self.assertGreater(len(mesh.triangles),180)
        np.testing.assert_array_equal(points,copy)
        self.assertLess(np.abs(mesh.vertices[:,0]-.7*mesh.vertices[:,1]-7).max(),2e-5)
        cfg=FastConfig().feature;r=np.linalg.norm(mesh.raw_vertices,axis=1)
        shift=np.linalg.norm(mesh.vertices-mesh.raw_vertices,axis=1)
        self.assertTrue(np.all(shift<=cfg.max_shift_m+cfg.shift_range_factor*r+1e-6))
        original={tuple(x) for x in points.astype(np.float32)/1000}
        self.assertTrue(all(tuple(x) in original for x in mesh.raw_vertices))

    def test_noisy_wall_error_reduced_and_faces_do_not_flip(self):
        points=wall(4.,.85);rng=np.random.default_rng(71)
        points+=rng.normal(0,6,(len(points),1))*points/np.linalg.norm(points,axis=1)[:,None]
        mesh=make_fast_mesh(points)
        before=np.sqrt(np.mean((mesh.raw_vertices[:,0]-4)**2))
        after=np.sqrt(np.mean((mesh.vertices[:,0]-4)**2))
        self.assertLess(after,before)
        a=mesh.raw_vertices[mesh.triangles];b=mesh.vertices[mesh.triangles]
        old=np.cross(a[:,1]-a[:,0],a[:,2]-a[:,0]);new=np.cross(b[:,1]-b[:,0],b[:,2]-b[:,0])
        cosine=np.sum(old*new,axis=1)/np.maximum(np.linalg.norm(old,axis=1)*np.linalg.norm(new,axis=1),1e-20)
        self.assertTrue(np.all(cosine>=.8-1e-5))

    def test_repeat_and_empty(self):
        p=wall(3.,1.2);a=make_fast_mesh(p);b=make_fast_mesh(p)
        np.testing.assert_array_equal(a.vertices,b.vertices)
        np.testing.assert_array_equal(a.triangles,b.triangles)
        for points in ([],[[1000,0,0]],[[0,0,0],[np.nan,0,0]]):
            self.assertEqual(len(make_fast_mesh(points).triangles),0)

    def test_spherical_seam_has_no_repeated_or_overconnected_faces(self):
        points=wall(4.,.85);points[:,:2]*=-1
        mesh=make_fast_mesh(points)
        f=mesh.triangles
        self.assertGreater(len(f),450)
        self.assertEqual(len(np.unique(np.sort(f,axis=1),axis=0)),len(f))
        e=np.sort(np.concatenate([f[:,(0,1)],f[:,(1,2)],f[:,(2,0)]]),axis=1)
        _,count=np.unique(e,axis=0,return_counts=True)
        self.assertLessEqual(count.max(),2)


if __name__=='__main__':unittest.main()
