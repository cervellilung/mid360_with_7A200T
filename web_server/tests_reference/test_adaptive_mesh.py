"""Geometry tests independent of the angular mesh implementation."""
import unittest
import numpy as np
from web_server.car_showcase.adaptive_mesh import make_angular_mesh, AngularConfig


def wall(distance=2., spacing=1., slope=0., gap=0.):
    points = []
    for azimuth in np.arange(-12, 12.01, spacing)+.23:
        for elevation in np.arange(-8, 8.01, spacing)+.31:
            if abs(azimuth) < gap:
                continue
            az, el = np.radians((azimuth, elevation))
            direction = np.array([np.cos(el)*np.cos(az), np.cos(el)*np.sin(az), np.sin(el)])
            t = distance/(direction[0]-slope*direction[1])
            if t > 0:
                points.append(direction*t*1000)
    return np.asarray(points)


class AdaptiveMeshTests(unittest.TestCase):
    def test_range_invariant_neighbour_connectivity(self):
        config = AngularConfig(step_deg=.8)
        meshes = [make_angular_mesh(wall(d, 1.6), config) for d in (1., 4., 9.)]
        self.assertGreater(len(meshes[0].triangles), 100)
        for m in meshes[1:]:
            self.assertEqual(len(m.vertices), len(meshes[0].vertices))
            self.assertEqual(len(m.triangles), len(meshes[0].triangles))

    def test_slanted_far_plane_keeps_faces(self):
        mesh = make_angular_mesh(wall(6., .9, slope=1.2))
        self.assertGreater(len(mesh.triangles), 450)
        self.assertGreater(mesh.diagnostics['normal_reliable'], 100)
        self.assertTrue(np.allclose(mesh.vertices[:, 0]-1.2*mesh.vertices[:, 1], 6., atol=2e-6))

    def test_foreground_background_not_joined(self):
        points = wall(1.)
        points[points[:, 1] >= 0] *= 3
        mesh = make_angular_mesh(points)
        tri = mesh.vertices[mesh.triangles]
        self.assertFalse(np.any((tri[:, :, 0].min(axis=1) < 1.5) & (tri[:, :, 0].max(axis=1) > 2.5)))
        self.assertGreater(mesh.diagnostics['rejected_depth'], 0)

    def test_large_opening_not_bridged(self):
        mesh = make_angular_mesh(wall(4., gap=3.))
        tri = mesh.vertices[mesh.triangles]
        self.assertFalse(np.any((tri[:, :, 1].min(axis=1) < -.2) & (tri[:, :, 1].max(axis=1) > .2)))
        self.assertGreater(mesh.diagnostics['rejected_angle'], 0)

    def test_azimuth_seam_connects(self):
        points = wall(4., .9)
        points[:, :2] *= -1
        mesh = make_angular_mesh(points)
        tri = mesh.vertices[mesh.triangles]
        self.assertGreater(len(mesh.triangles), 450)
        self.assertTrue(np.any((tri[:, :, 1].min(axis=1) < 0) & (tri[:, :, 1].max(axis=1) > 0)))

    def test_raw_xyz_determinism_and_invalid_input(self):
        pts = wall(3., 1.3)
        mesh = make_angular_mesh(pts)
        again = make_angular_mesh(pts)
        np.testing.assert_array_equal(mesh.vertices, mesh.raw_vertices)
        np.testing.assert_array_equal(mesh.triangles, again.triangles)
        original = {tuple(x) for x in pts.astype(np.float32)/1000}
        self.assertTrue(all(tuple(x) in original for x in mesh.vertices))
        self.assertEqual(make_angular_mesh([[0, 0, 0], [np.nan, 0, 0]]).observed_cells, 0)
        self.assertEqual(len(make_angular_mesh([[1000, 0, 0], [2000, 0, 0], [3000, 0, 0]]).triangles), 0)


if __name__ == '__main__':
    unittest.main()
