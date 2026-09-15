"""Regression coverage for thin source triangles crossing registration cells."""
import unittest

import numpy as np

from tactical_alignment_cells import split_arrays
from tactical_alignment_warps import from_controls
from tactical_alignment_navigation import warp_navigation


class CellPartitionTest(unittest.TestCase):
    def test_navigation_cell_vertex_contacts_do_not_create_polygons(self):
        points = np.array([[x, y] for x in [0., 1., 2.] for y in [0., 1., 2.]])
        delta = np.zeros_like(points)
        delta[4] = [.1, 0.]
        warp = from_controls(points, delta)
        vertices = [0, 0, 0, 1000000, 0, 0, 0, 1000000, 0]
        nav = {'vertices': vertices, 'coordinateScale': 1000000,
               'refinedFloorHeightsCm': [0., 0., 0.], 'polygons': [[0, 1, 2]],
               'triangles': [0, 0, 1, 2], 'walkable': [True], 'components': [0], 'links': [],
               'floorMesh': {'vertices': vertices, 'coordinateScale': 1000000,
                             'triangles': [0, 0, 1, 2]}}
        candidate, proof = warp_navigation(nav, lambda x: x, lambda x: x, warp, local_only=False)
        self.assertTrue(all(len(p) >= 3 for p in candidate['polygons']))
        self.assertLess(proof['relativeFloorAreaDifference'], 1e-8)
        self.assertEqual(proof['unreachableInternalParents'], [])

        untouched = [10000000, 0, 17.25, 11000000, 0, 18.5, 10000000, 1000000, 19.75]
        nav['vertices'] += untouched
        nav['refinedFloorHeightsCm'] += [17.25, 18.5, 19.75]
        nav['polygons'].append([3, 4, 5])
        nav['triangles'] += [1, 3, 4, 5]
        nav['walkable'].append(True)
        nav['components'].append(1)
        nav['floorMesh']['triangles'] += [1, 3, 4, 5]
        candidate, proof = warp_navigation(nav, lambda x: x, lambda x: x, warp, local_only=True)
        self.assertEqual(proof['unchangedSourceParents'], 2)
        self.assertEqual(proof['unchangedSourceFloorTriangles'], 2)
        floor = candidate['floorMesh']
        coords = np.array(floor['vertices']).reshape(-1, 3)
        rows = np.array(floor['triangles']).reshape(-1, 4)
        child = candidate['sourcePolygonIds'].index(1)
        unchanged_row = rows[rows[:, 0] == child][0]
        self.assertTrue(np.array_equal(coords[unchanged_row[1:]].view(np.uint64),
                                       np.array(untouched).reshape(3, 3).view(np.uint64)))

    def test_thin_vertical_triangle_retains_barycentric_area_and_alpha(self):
        # A previous ground cut can produce a long triangle with two vertices
        # almost coincident. Its absolute area must not become a discard cutoff.
        vertices = np.array([[.4, .2, 2.], [.4, 1.8, 3.],
                             [.4, 1.8, 3. + 1e-12]])
        points = np.array([[x, y] for x in [0., 1., 2.] for y in [0., 1., 2.]])
        delta = np.zeros_like(points)
        delta[4] = [.1, 0.]
        warp = from_controls(points, delta)
        uv = np.array([[[0., 0.], [1., 0.], [0., 1.]]])
        arrays = {'vertices': vertices, 'faces': np.array([[0, 1, 2]], dtype=np.uint32),
                  'faceMasks': np.array([0], dtype=np.int32), 'maskedUvs': uv,
                  'maskedMaterials': np.array([7], dtype=np.uint32)}
        result, parents, proof = split_arrays(arrays, lambda x: x, lambda x: x, warp)
        self.assertGreater(len(parents), 1)
        self.assertTrue(np.all(parents == 0))
        self.assertLess(proof['maximumSourceAreaRelativeError'], 1e-9)
        # UVs are the source barycentric coordinates, giving an independent
        # partition-area check unaffected by the tiny world-space cross product.
        child_uv = result['maskedUvs']
        edges = child_uv[:, 1:] - child_uv[:, :1]
        area_fraction = abs(edges[:, 0, 0] * edges[:, 1, 1] - edges[:, 0, 1] * edges[:, 1, 0]).sum()
        self.assertAlmostEqual(area_fraction, 1., places=10)
        self.assertTrue(np.all(result['maskedMaterials'] == 7))


if __name__ == '__main__':
    unittest.main()
