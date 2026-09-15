import json
from pathlib import Path
import unittest

import numpy as np
import shapely

from audit_assumed_svg_height_sections import clipped_height_intervals
from audit_assumed_svg_sightlines import blocks
from compile_local_svg_wall_profiles import polygon, profile_height, station_cells
from svg_represented_source_objects import RepresentedSourceRays
from svg_source_navigation import SourceNavigation


class LocalWallProfilesTest(unittest.TestCase):
    def test_opposing_abyss_samples_cover_the_complete_authored_ring(self):
        data = json.loads((Path(__file__).parent / 'testdata/abyss_local_height_partition.json').read_text())
        shape = polygon(data)
        samples = [dict(**s, status='measured-facade', measuredTopMeters=5.,
                        measuredBottomMeters=0., floorElevationMeters=0.) for s in data['stations']]
        cells = station_cells(dict(stations=samples), shape, 0.)
        pieces = [shape.intersection(cell) for cell, _, _ in cells]
        assigned = shapely.union_all(pieces)
        self.assertLess(shape.symmetric_difference(assigned).area, 1e-9)
        self.assertAlmostEqual(sum(p.area for p in pieces), shape.area, places=8)

    def test_closed_height_ignores_floor_interpolation_noise(self):
        outputs = []
        for ground in [1.91, 1.99, 2.01]:
            sample = dict(status='measured-facade', measuredTopMeters=4.5000001,
                          measuredBottomMeters=2., floorElevationMeters=ground)
            floor, bands, unknown = profile_height(sample, 2.)
            outputs.append((floor, bands))
            wall = dict(floorElevationMeters=floor, bands=bands, unknownHeight=unknown)
            for eye in [-2., 2., 4.5]:
                self.assertTrue(blocks(wall, eye))
            self.assertFalse(blocks(wall, 4.50002))
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(outputs[1], outputs[2])

    def test_missing_source_stays_explicitly_unresolved(self):
        floor, bands, unknown = profile_height(dict(status='needs-source-role'), 3.)
        self.assertEqual((floor, bands, unknown), (3., [[0., None]], True))

    def test_tower_keeps_slab_between_lower_passage_and_upper_window(self):
        sample = dict(status='measured-facade', measuredBottomMeters=6.,
            floorElevationMeters=6., measuredTopMeters=22.,
            passageIntervalsMeters=[[6., 11.84316], [12.02473, 15.99]])
        floor, bands, unknown = profile_height(sample, 6.)
        wall = dict(floorElevationMeters=floor, bands=bands, unknownHeight=unknown)
        for eye in [7.75, 13.75]:
            self.assertFalse(blocks(wall, eye))
        for eye in [4., 6., 11.9, 16., 22.]:
            self.assertTrue(blocks(wall, eye))
        self.assertFalse(blocks(wall, 22.1))

    def test_bad_openings_cannot_remove_a_slab(self):
        for passages in [[[6., 12.], [11., 16.]], [[5., 12.]], [[8., 25.]]]:
            with self.assertRaises(ValueError):
                profile_height(dict(status='measured-facade', measuredBottomMeters=6.,
                    floorElevationMeters=6., measuredTopMeters=22.,
                    passageIntervalsMeters=passages), 6.)

    def test_runtime_bands_have_positive_extent_at_opening_base_and_below_zero(self):
        samples = [dict(status='measured-facade', measuredBottomMeters=6.,
            floorElevationMeters=6., measuredTopMeters=22., passageIntervalsMeters=[[6., 12.]]),
            dict(status='measured-ground-boundary', measuredBottomMeters=-2.,
                 floorElevationMeters=-2., measuredTopMeters=-2.)]
        for sample in samples:
            floor, bands, unknown = profile_height(sample, sample['floorElevationMeters'])
            self.assertTrue(all(hi > lo for lo, hi in bands))
            wall = dict(floorElevationMeters=floor, bands=bands, unknownHeight=unknown)
            self.assertTrue(blocks(wall, sample['floorElevationMeters']-.5))

    def test_flat_ground_has_a_measurable_top_without_an_upright_face(self):
        triangles = np.array([[[-2., -2., 3.], [2., -2., 3.], [0., 2., 3.]]])
        ids, bands = clipped_height_intervals(triangles, np.zeros(2), np.array([1., 0.]),
                                             .15, .85, include_flat=True)
        self.assertEqual(ids.tolist(), [0])
        self.assertEqual(bands.tolist(), [[3., 3.]])
        floor, height_bands, unknown = profile_height(dict(
            status='measured-ground-boundary', measuredBottomMeters=3.,
            measuredTopMeters=3., floorElevationMeters=3.), 3.)
        wall = dict(floorElevationMeters=floor, bands=height_bands, unknownHeight=unknown)
        self.assertFalse(blocks(wall, 4.75))

    def test_navigation_cannot_jump_to_an_upper_floor_to_prove_a_gap(self):
        nav = SourceNavigation.__new__(SourceNavigation)
        nav.heights = lambda p: [(0, 0. if p[0] < .1 else 2.)]
        self.assertIsNone(nav.crossing(np.zeros(2), np.array([1., 0.]), 0.))
        nav.heights = lambda p: [(0, .1 * p[0])]
        self.assertIsNotNone(nav.crossing(np.zeros(2), np.array([1., 0.]), 0.))

    def test_represented_source_ray_uses_actual_triangle_extent(self):
        rays = RepresentedSourceRays.__new__(RepresentedSourceRays)
        tri = np.array([[[0., -1., 0.], [0., 1., 0.], [0., 0., 3.]]])
        rays.objects = [(dict(object=42, path='solid/trunk'), np.array([100]), tri)]
        hit = rays.cast(np.array([-2., 0., 1.]), np.array([2., 0., 1.]))
        self.assertEqual(hit['sourceFace'], 100)
        self.assertEqual(hit['distanceMeters'], 2.)
        self.assertIsNone(rays.cast(np.array([-2., 0., 4.]), np.array([2., 0., 4.])))


if __name__ == '__main__':
    unittest.main()
