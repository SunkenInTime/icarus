import unittest
import numpy as np
import shapely
from compact_tactical_floor_support import compact


class FloorCompactionTest(unittest.TestCase):
    def test_stacked_floors_remain_separate_and_preserve_holes(self):
        ring = shapely.Polygon([(0, 0), (4, 0), (4, 4), (0, 4)],
                               [[(1, 1), (1, 3), (3, 3), (3, 1)]])
        children = list(shapely.get_parts(shapely.constrained_delaunay_triangles(ring)))
        xy = np.concatenate([np.asarray(p.exterior.coords)[:3] for p in children])
        vertices = np.vstack([np.c_[xy, np.zeros(len(xy))], np.c_[xy, np.full(len(xy), 5.)]])
        faces = np.arange(len(vertices)).reshape(-1, 3)
        arrays, report = compact(vertices, faces, np.arange(len(faces)))
        self.assertEqual(report['planeGroups'], 2)
        for group in range(2):
            triangles = arrays['triangles'][arrays['triangleGroups'] == group]
            surface = shapely.union_all(shapely.polygons(arrays['vertices'][triangles, :2]))
            self.assertLess(surface.symmetric_difference(ring).area, 1e-10)
            self.assertFalse(surface.covers(shapely.Point(2, 2)))
        self.assertEqual(set(arrays['vertices'][:, 2]), {0., 5.})

    def test_sloped_floor_keeps_height_and_source_provenance(self):
        vertices = np.array([[0, 0, 2], [4, 0, 4], [4, 4, 4], [0, 4, 2]], dtype=float)
        arrays, report = compact(vertices, np.array([[0, 1, 2], [0, 2, 3]]), np.array([41, -7]))
        np.testing.assert_allclose(arrays['vertices'][:, 2], 2 + arrays['vertices'][:, 0] / 2)
        self.assertEqual(set(arrays['groupSourceFaces']), {41, -7})
        self.assertLess(report['maximumHeightErrorMeters'], 1e-12)


if __name__ == '__main__':
    unittest.main()
