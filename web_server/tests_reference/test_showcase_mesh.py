"""Safety checks for the visual mesh's depth-discontinuity handling."""

import unittest

import numpy as np

from car_showcase.mesh import make_mesh


class ShowcaseMeshTests(unittest.TestCase):
    def test_near_and_far_surfaces_do_not_bridge(self):
        samples = []
        for az_deg in np.arange(-8, 8.1, 1.0):
            for el_deg in np.arange(-5, 5.1, 1.0):
                distance = 1.0 if az_deg < 0 else 3.0
                az, el = np.radians((az_deg, el_deg))
                samples.append((distance * np.cos(el) * np.cos(az),
                                distance * np.cos(el) * np.sin(az),
                                distance * np.sin(el)))
        mesh = make_mesh(np.asarray(samples) * 1000, step_deg=1.0)
        self.assertGreater(len(mesh.triangles), 40)
        self.assertGreater(mesh.edge_rejections, 0)
        faces = mesh.vertices[mesh.triangles]
        self.assertFalse(np.any((faces[:, :, 0].min(axis=1) < 1.2) &
                                (faces[:, :, 0].max(axis=1) > 2.5)))
        self.assertLess(mesh.p95_shift_mm, 50)

    @staticmethod
    def wall(missing=(), noise=0):
        rng = np.random.default_rng(42)
        points = []
        for r in range(31, 50):
            for c in range(170, 191):
                if (r, c) in missing:
                    continue
                az, el = np.radians((-180+(c+.23), -40+(r+.31)))
                x = 2.0 + rng.normal(0, noise)
                points.append((x, x*np.tan(az), x*np.tan(el)/np.cos(az)))
        return np.asarray(points)*1000

    def test_preserves_exact_raw_coordinates(self):
        points = self.wall()
        mesh = make_mesh(points, 1.0)
        original = {tuple(x) for x in points.astype(np.float32)/1000}
        self.assertTrue(all(tuple(x) in original for x in mesh.raw_vertices[mesh.observed]))
        self.assertLess(mesh.p95_shift_mm, .001)

    def test_closed_hole_fits_plane_not_radial_average(self):
        mesh = make_mesh(self.wall({(40, 180)}), 1.0)
        self.assertEqual(mesh.filled_cells, 1)
        self.assertTrue(np.allclose(mesh.vertices[~mesh.observed, 0], 2, atol=1e-5))

    def test_open_gap_and_repeated_net_holes_remain(self):
        gap = {(r, c) for r in range(31, 50) for c in (179, 180, 181)}
        self.assertEqual(make_mesh(self.wall(gap), 1).filled_cells, 0)
        net = {(r,c) for r in range(31,50) for c in range(170,191) if r%2 and c%2}
        self.assertEqual(make_mesh(self.wall(net), 1).filled_cells, 0)

    def test_noise_reduction_is_bounded(self):
        mesh = make_mesh(self.wall(noise=.004), 1)
        movement = np.linalg.norm(mesh.vertices-mesh.raw_vertices, axis=1)
        self.assertLessEqual(movement.max(), .010001)
        self.assertLess(np.std(mesh.vertices[:,0]), np.std(mesh.raw_vertices[:,0]))

    def test_three_corner_face_survives_any_missing_corner(self):
        for absent in range(4):
            points = []
            for i, (r,c) in enumerate(((40,180),(41,180),(40,181),(41,181))):
                if i == absent:
                    continue
                az,el=np.radians((-180+c+.2,-40+r+.3))
                points.append((2,2*np.tan(az),2*np.tan(el)/np.cos(az)))
            mesh=make_mesh(np.asarray(points)*1000,1)
            self.assertEqual(len(mesh.triangles),1)

    def test_planar_mode_fills_supported_medium_hole(self):
        hole={(r,c) for r in range(37,42) for c in range(177,182)}
        points=self.wall(hole)
        strict=make_mesh(points,1)
        planar=make_mesh(points,1,planar_fill=True)
        self.assertEqual(strict.filled_cells,0)
        self.assertEqual(planar.filled_cells,25)
        self.assertTrue(np.allclose(planar.vertices[~planar.observed,0],2,atol=1e-5))
        np.testing.assert_array_equal(strict.raw_vertices[strict.observed],planar.raw_vertices[planar.observed])
        np.testing.assert_array_equal(strict.vertices[strict.observed],planar.vertices[planar.observed])

    def test_planar_mode_rejects_net_open_gap_and_depth_edge(self):
        net={(r,c) for r in range(31,50) for c in range(170,191) if r%2 and c%2}
        self.assertEqual(make_mesh(self.wall(net),1,planar_fill=True).filled_cells,0)
        gap={(r,c) for r in range(31,50) for c in (179,180,181)}
        self.assertEqual(make_mesh(self.wall(gap),1,planar_fill=True).filled_cells,0)
        hole={(r,c) for r in range(37,42) for c in range(177,182)}
        points=self.wall(hole)
        points[points[:,1]>0]*=1.8
        self.assertEqual(make_mesh(points,1,planar_fill=True).filled_cells,0)

    def test_invalid_points_and_empty_scene(self):
        mesh = make_mesh(np.array([[0, 0, 0], [np.nan, 0, 0], [13000, 0, 0]]))
        self.assertEqual(len(mesh.triangles), 0)
        self.assertEqual(mesh.observed_cells, 0)


if __name__ == "__main__":
    unittest.main()
