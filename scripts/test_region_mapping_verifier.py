import copy
import unittest

import numpy as np
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import declared_mapping, verify_region_topology, verify_region_fragments


class RegionMappingVerifierTest(unittest.TestCase):
    def setUp(self):
        self.source = np.array([[0., 0.], [2., 0.], [2., 2.], [0., 2.], [1., 1.]])
        self.cells = np.array([[0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]])
        self.target = self.source.copy()
        self.target[4] += [.2, -.1]
        self.family = dict(edge=300, mappingType='piecewise-affine-region-v1',
                           sourceVerticesSvg=self.source.tolist(),
                           targetVerticesSvg=self.target.tolist(), triangles=self.cells.tolist())
        self.forward = explicit_warp(self.source, np.zeros_like(self.source), self.cells)

    def test_accepts_connected_map_and_rejects_detached_boundary(self):
        verify_region_topology(self.family, self.forward)
        broken = copy.deepcopy(self.family)
        broken['targetVerticesSvg'][0][0] += .01
        with self.assertRaisesRegex(AssertionError, 'outer edge'):
            verify_region_topology(broken, self.forward)

    def test_rejects_fold_and_duplicate_cells(self):
        folded = copy.deepcopy(self.family)
        folded['targetVerticesSvg'][4] = [3., 1.]
        with self.assertRaisesRegex(AssertionError, 'folds'):
            verify_region_topology(folded, self.forward)
        duplicate = copy.deepcopy(self.family)
        duplicate['triangles'].append(duplicate['triangles'][0])
        with self.assertRaisesRegex(AssertionError, 'Overlapping'):
            verify_region_topology(duplicate, self.forward)

    def test_declared_cell_cannot_hide_unsplit_mapping_kink(self):
        points = np.array([[[.4, .1], [1.6, .1], [.1, 1.6]]])
        with self.assertRaisesRegex(AssertionError, 'source cell'):
            declared_mapping(self.family, points, np.array([0]))

    def test_actual_fragment_must_follow_declared_mapping(self):
        points = np.array([[[.8, .1], [1.2, .1], [1., .2]]])
        mapped, _ = declared_mapping(self.family, points, np.array([0]))
        probes = np.array([[1., 0., 0.], [0., 1., 0.], [0., 0., 1.], [1/3]*3])
        verify_region_fragments(self.family, points, mapped, np.array([0]), np.array([0]), self.forward, probes)
        with self.assertRaisesRegex(AssertionError, 'differs'):
            verify_region_fragments(self.family, points, mapped + .001,
                                    np.array([0]), np.array([0]), self.forward, probes)

    def test_identity_means_display_w_not_raw_svg_coordinates(self):
        delta = np.tile([.3, .7], (5, 1))
        forward = explicit_warp(self.source, delta, self.cells)
        family = copy.deepcopy(self.family)
        family['targetVerticesSvg'] = (self.target + delta).tolist()
        verify_region_topology(family, forward)
        with self.assertRaisesRegex(AssertionError, 'outer edge'):
            verify_region_topology(self.family, forward)

    def test_centroid_samples_cannot_hide_opposite_vertex_errors(self):
        points=np.array([[[.8,.1],[1.2,.1],[1.,.2]]])
        mapped,_=declared_mapping(self.family,points,np.array([0]))
        mapped[0,0,0]+=.01
        mapped[0,1,0]-=.01
        with self.assertRaisesRegex(AssertionError,'differs'):
            verify_region_fragments(self.family,points,mapped,np.array([0]),np.array([0]),self.forward,np.array([[1/3]*3]))


if __name__ == '__main__':
    unittest.main()
