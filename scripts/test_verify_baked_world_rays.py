import unittest
import json
from pathlib import Path
import tempfile
import numpy as np
from verify_baked_world_rays import PlaneSource, nearest_layers, ray_distances
from pack_world_visibility import pack
from test_pack_world_visibility import FIXTURE


class IndependentRayTests(unittest.TestCase):
    def test_closest_hit_parallel_collinear_and_range(self):
        segments = np.array([[[2, -1], [2, 1]], [[4, -1], [4, 1]], [[3, 3], [5, 3]]], dtype=float)
        starts = np.array([[0, 0], [0, 2], [0, 3], [0, 4]], dtype=float)
        ends = starts + [10, 0]
        np.testing.assert_allclose(ray_distances(segments, starts, ends), [2, 10, 3, 10])

    def test_nearest_plane_ties_choose_lower_and_clamp_ends(self):
        np.testing.assert_equal(nearest_layers([100, 105, 110], [-1, 102.5, 104, 107.5, 999]), [0, 0, 1, 1, 2])

    def test_chunk_reader_preserves_metric_intersections_and_checks_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.json'
            source.write_text(json.dumps(FIXTURE))
            output = Path(folder) / 'packed'
            manifest, _ = pack(source, output, 1)
            original = PlaneSource(source)
            chunked = PlaneSource(output / 'split_visibility.manifest.json')
            canonical = lambda segments: sorted(tuple(sorted(map(tuple, pair))) for pair in segments)
            for index in range(3):
                self.assertEqual(canonical(chunked.segments(index)), canonical(original.segments(index)))
            child = output / manifest['chunks'][0]['asset']
            child.write_bytes(child.read_bytes() + b'corruption')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                chunked.segments(0)


if __name__ == '__main__':
    unittest.main()
