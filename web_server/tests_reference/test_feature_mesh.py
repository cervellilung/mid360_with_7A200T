"""Independent geometry invariants for local-feature display refinement."""
import unittest
import numpy as np
from web_server.car_showcase.adaptive_mesh import make_angular_mesh
from web_server.car_showcase.feature_mesh import make_feature_mesh, FeatureConfig, PLANAR, EDGE
from web_server.tests_reference.test_adaptive_mesh import wall


class FeatureMeshTests(unittest.TestCase):
    def test_noisy_plane_improves_without_filling(self):
        points = wall(4., .85)
        rng = np.random.default_rng(71)
        points += rng.normal(0, 6, (len(points), 1))*points/np.linalg.norm(points, axis=1)[:, None]
        base = make_angular_mesh(points, include_geometry=True)
        mesh = make_feature_mesh(points, base=base)
        self.assertGreater(int((mesh.features == PLANAR).sum()), 100)
        before = np.sqrt(np.mean((mesh.raw_vertices[:, 0]-4)**2))
        after = np.sqrt(np.mean((mesh.vertices[:, 0]-4)**2))
        self.assertLess(after, before*.85)
        np.testing.assert_array_equal(mesh.raw_vertices, base.raw_vertices)
        np.testing.assert_array_equal(mesh.triangles, base.triangles)
        self.assertEqual(mesh.filled_cells, 0)

    def test_foreground_and_corner_protected(self):
        points = wall(2., .9)
        points[points[:, 1] > 0] *= 2
        mesh = make_feature_mesh(points)
        self.assertGreater(int((mesh.features == EDGE).sum()), 0)
        np.testing.assert_array_equal(mesh.vertices[mesh.features == EDGE], mesh.raw_vertices[mesh.features == EDGE])
        faces = mesh.raw_vertices[mesh.triangles]
        self.assertFalse(np.any((faces[:, :, 0].min(axis=1) < 2.5) & (faces[:, :, 0].max(axis=1) > 3.5)))

    def test_range_scaled_bounds_and_ray_directions(self):
        for distance in (1., 5., 9.):
            points = wall(distance, .95)
            points += np.random.default_rng(22).normal(0, 15, (len(points), 1))
            mesh = make_feature_mesh(points)
            raw_radius = np.linalg.norm(mesh.raw_vertices, axis=1)
            shift = np.linalg.norm(mesh.vertices-mesh.raw_vertices, axis=1)
            self.assertTrue(np.all(shift <= .008+.001*raw_radius+1e-6))
            np.testing.assert_allclose(mesh.vertices/np.linalg.norm(mesh.vertices, axis=1)[:, None],
                                       mesh.raw_vertices/raw_radius[:, None], atol=2e-7)

    def test_opening_topology_and_determinism(self):
        points = wall(5., 1.1, gap=3.)
        mesh = make_feature_mesh(points)
        again = make_feature_mesh(points)
        np.testing.assert_array_equal(mesh.vertices, again.vertices)
        np.testing.assert_array_equal(mesh.triangles, again.triangles)
        base = make_angular_mesh(points)
        np.testing.assert_array_equal(mesh.triangles, base.triangles)
        self.assertFalse(np.any((mesh.vertices[mesh.triangles][:, :, 1].min(axis=1) < -.25)
                                & (mesh.vertices[mesh.triangles][:, :, 1].max(axis=1) > .25)))

    def test_empty_and_small_cloud(self):
        for points in ([], [[1000, 0, 0]], [[1000, 0, 0], [1000, 100, 0]]):
            mesh = make_feature_mesh(points)
            self.assertEqual(len(mesh.triangles), 0)
            np.testing.assert_array_equal(mesh.vertices, mesh.raw_vertices)

    def test_zero_strength_preserves_measurements(self):
        points = wall(4.)
        points += np.random.default_rng(3).normal(0, 5, points.shape)
        mesh = make_feature_mesh(points, FeatureConfig(strength=0))
        np.testing.assert_array_equal(mesh.vertices, mesh.raw_vertices)
        self.assertEqual(mesh.diagnostics['moved_vertices'], 0)

    def test_two_faces_keep_sharp_crease(self):
        left = wall(4., .85, slope=.7)
        right = wall(4., .85, slope=-.7)
        points = np.concatenate([left[left[:, 1] < 0], right[right[:, 1] >= 0]])
        mesh = make_feature_mesh(points)
        self.assertGreater(int((mesh.features == EDGE).sum()), 0)
        # Known analytic surfaces, not the classifier's own fitted plane.
        analytic_error = mesh.vertices[:, 0]+.7*np.abs(mesh.vertices[:, 1])-4
        self.assertLess(float(np.abs(analytic_error).max()), 1e-5)
        protected = mesh.features == EDGE
        np.testing.assert_array_equal(mesh.vertices[protected], mesh.raw_vertices[protected])


if __name__ == '__main__':
    unittest.main()
