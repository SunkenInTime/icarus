import copy
import gzip
import json
from pathlib import Path
import tempfile
import unittest

from pack_world_visibility import layer_segments, make_chunk, pack
from world_visibility_binary import decode_world, encode_world
from seal_world_plane_manifest import seal_plane_manifest
from world_plane_test_fixture import completed_fixture


FIXTURE = {'version': 1, 'map': 'split', 'coordinateScale': 1048576,
           'planarized': True, 'uvUnitsPerMeter': [.0078, .0078],
           'observerHeightCm': 175, 'defaultFloorElevationCm': 300,
           'menuElevationsCm': [475], 'vertices': [0, 0, 10, 0, 10, 10, 0, 10],
           'edges': [0, 1, 1, 2, 2, 3],
           'layers': [{'elevationCm': 475, 'globalOrigins': True, 'edges': [0, 1]},
                      {'elevationCm': 476, 'globalOrigins': False, 'edges': [2]},
                      {'elevationCm': 477, 'globalOrigins': False, 'edges': []}]}


def exact_edges(data, layer):
    return {tuple(sorted(map(tuple, pair))) for pair in layer_segments(data, layer)}


class ChunkTests(unittest.TestCase):
    def test_raw_budget_splits_blocks_without_losing_height_order(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.json'
            source.write_text(json.dumps(FIXTURE))
            manifest, report = pack(source, Path(folder) / 'packed', 3, maximum_block_bytes=512)
            self.assertEqual(report['chunks'], 3)
            self.assertEqual([layer['elevationCm'] for layer in manifest['layers']], [475, 476, 477])
            self.assertTrue(all(chunk['uncompressedBytes'] <= 512 for chunk in manifest['chunks']))

    def test_blocks_preserve_exact_geometry_and_local_only_planes(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source.json'
            source.write_text(json.dumps(FIXTURE))
            output = Path(folder) / 'packed'
            manifest, report = pack(source, output, 1)
            self.assertEqual(report['chunks'], 3)
            self.assertNotIn('vertices', manifest)
            for index, layer in enumerate(manifest['layers']):
                child = decode_world(gzip.decompress((output / manifest['chunks'][index]['asset']).read_bytes()),
                                     allow_no_global=True)
                self.assertEqual(layer['chunkIndex'], index)
                self.assertEqual(layer['localLayerIndex'], 0)
                self.assertEqual(layer['globalOrigins'], index == 0)
                self.assertEqual(exact_edges(child, child['layers'][0]),
                                 exact_edges(FIXTURE, FIXTURE['layers'][index]))

    def test_local_only_requires_explicit_binary_opt_in(self):
        child = make_chunk(FIXTURE, FIXTURE['layers'][1:])
        with self.assertRaisesRegex(ValueError, 'global origin'):
            encode_world(child)
        payload = encode_world(child, allow_no_global=True)
        with self.assertRaisesRegex(ValueError, 'global origin'):
            decode_world(payload)

    def test_plane_cache_matches_monolithic_source_without_shipping_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            data = copy.deepcopy(FIXTURE)
            data['format'] = 'plane-cache-v1'
            data.pop('vertices')
            data.pop('edges')
            for index, layer in enumerate(data['layers']):
                path = Path(folder) / f'{index}.json.gz'
                path.write_bytes(gzip.compress(json.dumps({'segments': layer_segments(FIXTURE, FIXTURE['layers'][index])}).encode()))
                layer.pop('edges')
                layer['cacheFile'] = str(path)
            self.assertEqual(make_chunk(data, data['layers']), make_chunk(FIXTURE, FIXTURE['layers']))
            source = Path(folder) / 'planes.json'
            source.write_text(json.dumps(data))
            with self.assertRaises(FileNotFoundError):
                pack(source, Path(folder) / 'packed', 2)

    def test_sealed_planes_pack_without_shipping_local_evidence_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            source, world = completed_fixture(folder)
            seal_plane_manifest(source, world)
            manifest, _ = pack(source, Path(folder) / 'packed', 2)
            self.assertNotIn('cacheFile', json.dumps(manifest))
            self.assertNotIn(str(Path(folder)), json.dumps(manifest))
            self.assertIn('planeSealSha256', manifest['source'])


if __name__ == '__main__':
    unittest.main()
