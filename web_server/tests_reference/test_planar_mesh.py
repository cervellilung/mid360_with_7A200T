import unittest
import numpy as np
from scipy.spatial import cKDTree
from web_server.car_showcase.planar_mesh import make_planar_mesh, make_range_baseline, valid_points, PlanarConfig, ring_supported, ray_contradictions, bounded_gap_support, angular_enclosed_support
from web_server.car_showcase.adaptive_mesh import make_angular_mesh
from web_server.car_showcase.surface_distance import triangle_distances, surface_distances
from types import SimpleNamespace
from web_server.car_showcase.mesh import make_mesh


class PlanarTests(unittest.TestCase):
    def test_angular_support_is_range_invariant_and_crosses_seam(self):
        for q in (np.array([1.,0,0]),np.array([-1.,0,0]),np.array([0.,0,1.])):
            axis=np.eye(3)[np.argmin(abs(q))];u=np.cross(q,axis);u/=np.linalg.norm(u);v=np.cross(q,u)
            a=np.arange(32)*2*np.pi/32
            rays=q+np.tan(np.radians(1.))*((np.cos(a)[:,None]*u)+(np.sin(a)[:,None]*v))
            rays/=np.linalg.norm(rays,axis=1)[:,None]
            for distance in (1.,5.9):
                probes=np.tile(q*distance,(1,7,1))
                good,nearest=angular_enclosed_support(probes,rays,2.4)
                self.assertTrue(good[0]);np.testing.assert_allclose(nearest,1.,atol=1e-10)
            self.assertFalse(angular_enclosed_support(np.tile(q,(1,7,1)),rays,.5)[0][0])

    def test_angular_support_rejects_one_sided_or_repeated_returns(self):
        q=np.array([1.,0,0]);probes=np.tile(q,(1,7,1))
        a=np.linspace(-.5,.5,32);rays=np.c_[np.ones(32),.01*np.cos(a),.01*np.sin(a)]
        rays/=np.linalg.norm(rays,axis=1)[:,None]
        self.assertFalse(angular_enclosed_support(probes,rays,2.4)[0][0])
        rays=np.tile([1.,.01,0],(100,1));rays/=np.linalg.norm(rays,axis=1)[:,None]
        self.assertFalse(angular_enclosed_support(probes,rays,2.4)[0][0])

    def test_oblique_sparse_plane_recovers_long_edges(self):
        from dataclasses import replace
        az,el=np.meshgrid(np.radians(np.arange(-18,18,.3)),np.radians(np.arange(18,40,1.5)))
        horizontal=1.8/np.tan(el)
        p=np.c_[horizontal.ravel()*np.cos(az.ravel()),horizontal.ravel()*np.sin(az.ravel()),np.full(az.size,1.8)]*1000
        cfg=PlanarConfig();old=make_planar_mesh(p,replace(cfg,angular_gap_support=False));new=make_planar_mesh(p,cfg)
        self.assertTrue(set(map(tuple,old.triangles)).issubset(set(map(tuple,new.triangles))))
        self.assertGreater(len(new.triangles),len(old.triangles))
        self.assertGreater(max(s['recovered_max_edge_m'] for s in new.planar_report['planes']),.4)
        centre=new.vertices[new.triangles].mean(axis=1)
        self.assertTrue((np.linalg.norm(centre[:,:2],axis=1)>2.).all())

    def test_bounded_gap_cannot_extend_open_edge(self):
        uv=np.c_[np.zeros(30),np.linspace(-.2,.2,30)]
        probes=np.full((1,7,2),[.04,0.])
        self.assertFalse(bounded_gap_support(probes,cKDTree(uv),uv,.2)[0])

    def test_bounded_gap_enclosed_and_radius_limited(self):
        a=np.arange(24)*2*np.pi/24
        uv=np.c_[np.cos(a),np.sin(a)]*.1
        probes=np.zeros((1,7,2))
        self.assertTrue(bounded_gap_support(probes,cKDTree(uv),uv,.2)[0])
        self.assertFalse(bounded_gap_support(probes,cKDTree(uv),uv,.08)[0])

    def test_recovery_keeps_original_uv_faces(self):
        from dataclasses import replace
        cfg=PlanarConfig();p=self.wall()
        a=make_planar_mesh(p,replace(cfg,recover_supported_gaps=False));b=make_planar_mesh(p,cfg)
        self.assertTrue(set(map(tuple,a.triangles)).issubset(set(map(tuple,b.triangles))))
        self.assertEqual(len(b.triangles),len(np.unique(np.sort(b.triangles,axis=1),axis=0)))

    def wall(self):
        y,z = np.meshgrid(np.arange(-1,1.001,.05),np.arange(-.6,.601,.05))
        return np.c_[np.full(y.size,3000),y.ravel()*1000,z.ravel()*1000].astype(np.int32)

    def test_audit_is_passive(self):
        p=self.wall(); a=make_angular_mesh(p); b=make_angular_mesh(p,include_audit=True)
        np.testing.assert_array_equal(a.triangles,b.triangles)
        accepted=b.audit['candidates'][b.audit['reasons']==0]
        self.assertEqual(set(map(tuple,np.sort(accepted,axis=1))),set(map(tuple,np.sort(b.triangles,axis=1))))

    def test_finite_triangle(self):
        tri=np.array([[[0,0,0],[1,0,0],[0,1,0]]],float)
        self.assertAlmostEqual(triangle_distances(np.array([2,2,0]),tri)[0],np.sqrt(4.5))
        self.assertAlmostEqual(triangle_distances(np.array([.2,.2,.03]),tri)[0],.03)

    def test_exact_query_matches_all_faces(self):
        rng=np.random.default_rng(42);v=rng.uniform(-1,1,(120,3));f=np.arange(120).reshape(-1,3)
        p=rng.uniform(-2,2,(20,3));m=SimpleNamespace(vertices=v,triangles=f)
        brute=np.array([triangle_distances(point,v[f]).min() for point in p])
        np.testing.assert_allclose(surface_distances(p,m),brute,atol=1e-12)

    def test_open_boundary_not_enclosed(self):
        uv=np.c_[np.zeros(21),np.linspace(-1,1,21)]
        self.assertFalse(ring_supported(np.array([[.1,0]]),cKDTree(uv),uv,np.array([.1]))[0])

    def test_slanted_ray_gate(self):
        n=np.array([1.,.5,0]); n/=np.linalg.norm(n); d=-3.
        rays=np.array([[1,.1,0],[1,-.1,0],[1,.05,0],[1,-.05,0]],float); rays/=np.linalg.norm(rays,axis=1)[:,None]
        radii=-d/(rays@n); probes=rays*radii[:,None]
        self.assertFalse(ray_contradictions(probes,n,d,cKDTree(rays),rays,radii).any())

    def test_wall_and_determinism(self):
        p=self.wall(); a=make_planar_mesh(p); b=make_planar_mesh(p)
        self.assertGreater(len(a.triangles),300)
        np.testing.assert_array_equal(a.triangles,b.triangles)
        self.assertLess(a.planar_report['max_shift_mm'],.1)

    def test_door_gap_not_convex_hull(self):
        p=self.wall(); p=p[(np.abs(p[:,1])>250)|(np.abs(p[:,2])>400)]
        m=make_planar_mesh(p)
        centroid=m.vertices[m.triangles].mean(axis=1)
        self.assertFalse(((np.abs(centroid[:,1])<.18)&(np.abs(centroid[:,2])<.30)).any())

    def test_disconnected_wall(self):
        p=self.wall(); p=p[np.abs(p[:,1])>400]
        m=make_planar_mesh(p); tri=m.vertices[m.triangles]
        self.assertFalse(((tri[:,:,1].min(axis=1)<-.4)&(tri[:,:,1].max(axis=1)>.4)).any())

    def test_fold_keeps_separate_normals(self):
        a=self.wall();b=a.copy();b[:,0]=2000+a[:,1];b[:,1]=1000
        m=make_planar_mesh(np.concatenate([a,b]))
        groups=m.face_group[m.face_group>=0]
        self.assertGreater(len(np.unique(groups)),1)
        tri=m.vertices[m.triangles]
        planar=m.face_group>=0
        on_x=(np.abs(tri[:,:,0]-3)<.001).all(axis=1)
        on_y=(np.abs(tri[:,:,1]-1)<.001).all(axis=1)
        self.assertTrue((on_x[planar]|on_y[planar]).all())

    def test_foreground_and_background_contradiction(self):
        rays=np.array([[1,.0001,0],[1,-.0001,0],[1,0,.0001],[1,0,-.0001]],float)
        rays/=np.linalg.norm(rays,axis=1)[:,None]
        tree=cKDTree(rays);probes=np.array([[3.,0,0]])
        for radius in (2.,4.):
            self.assertTrue(ray_contradictions(probes,np.array([1.,0,0]),-3.,tree,rays,np.full(4,radius))[0])

    def test_empty(self):
        m=make_planar_mesh(np.empty((0,3)))
        self.assertEqual(len(m.triangles),0)

    def test_exact_six_metre_radial_boundary(self):
        # The second point is beyond 6 m, although float32 norm rounds to 6.
        p=np.array([[6000,0,0],[6000,1,0],[6001,0,0],[5000,4000,0],
                    [0,0,300],[0,0,299],[3000,0,0]],dtype=np.int32)
        valid,ids=valid_points(p)
        np.testing.assert_array_equal(ids,[0,4,6])
        self.assertTrue((np.linalg.norm(valid,axis=1)<=6).all())
        base=make_range_baseline(p)
        self.assertTrue(set(base.audit['selected_source_ids']).issubset(set(ids)))

    def test_far_returns_do_not_change_near_mesh(self):
        near=self.wall(); far=near.copy(); far[:,0]=8000
        a=make_planar_mesh(near); b=make_planar_mesh(np.concatenate([near,far]))
        np.testing.assert_array_equal(a.raw_vertices,b.raw_vertices)
        np.testing.assert_array_equal(a.vertices,b.vertices)
        np.testing.assert_array_equal(a.triangles,b.triangles)

    def test_projection_keeps_six_metre_boundary(self):
        p=self.wall().astype(float)
        p[:,0]=5950+.04*p[:,1]
        m=make_planar_mesh(p)
        self.assertGreater(len(m.triangles),0)
        self.assertTrue((np.linalg.norm(m.raw_vertices,axis=1)<=6+1e-6).all())
        self.assertTrue((np.linalg.norm(m.vertices,axis=1)<=6+1e-6).all())

    def test_mismatched_baseline_is_rejected(self):
        p=self.wall()
        with self.assertRaisesRegex(ValueError,'ranges must match'):
            make_planar_mesh(p,base=make_angular_mesh(p))

    def test_invalid_range(self):
        for maximum in (float('nan'),float('inf'),.3,-1):
            with self.assertRaises(ValueError):
                valid_points(self.wall(),PlanarConfig(max_range=maximum))

    def test_legacy_exact_range_and_far_independence(self):
        near=self.wall(); far=near.copy(); far[:,0]=8000
        a=make_mesh(near,max_range=6)
        b=make_mesh(np.concatenate([near,far,[[6000,1,0]]]),max_range=6)
        np.testing.assert_array_equal(a.vertices,b.vertices)
        np.testing.assert_array_equal(a.triangles,b.triangles)
        self.assertEqual(b.input_points,len(near))

    def test_legacy_smoothing_within_range(self):
        p=self.wall().astype(float); p[:,0]=5950+.04*p[:,1]
        m=make_mesh(p,max_range=6)
        self.assertTrue((np.linalg.norm(m.vertices.astype(float),axis=1)<=6+1e-6).all())
        self.assertTrue((np.linalg.norm(m.raw_vertices.astype(float),axis=1)<=6+1e-6).all())

    def test_legacy_invalid_range(self):
        with self.assertRaises(ValueError):
            make_mesh(self.wall(),max_range=float('nan'))


if __name__=='__main__':unittest.main()
