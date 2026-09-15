import copy
import gzip
import json
import random
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from world_visibility_binary import MAGIC, DELTA_ENCODING, encode_world, decode_world, write_binary


FIXTURE = {
    'version': 1,
    'map': 'split',
    'coordinateScale': 1048576,
    'planarized': True,
    'observerHeightCm': 175,
    'defaultFloorElevationCm': 300,
    'uvUnitsPerMeter': [0.0078, 0.0078],
    'menuElevationsCm': [475],
    'maxDistanceMeters': 40,
    'vertices': [-2147483648, 2147483647, 0, -7, 100, 50, 1048576, 2097152],
    'edges': [0, 1, 1, 2, 2, 3],
    'layers': [
        {'elevationCm': 475, 'globalOrigins': True, 'edges': [2, 0]},
        {'elevationCm': 477.125, 'globalOrigins': False, 'edges': []},
        {'elevationCm': 480, 'globalOrigins': False, 'edges': [1, 2],
         'fixtureLabel': 'preserved'},
    ],
    'source': {'geometrySha256': '0123456789abcdef', 'note': 'standing 1.75 m; café'},
    'unknownMetadata': {'futureVersion': None, 'flags': [True, False]},
}

def modify_header(payload, modify):
    size = struct.unpack_from('<I', payload, 8)[0]
    start = 12 + size + 3 & ~3
    header = json.loads(payload[12:12 + size])
    modify(header)
    encoded = json.dumps(header, separators=(',', ':')).encode()
    prefix = MAGIC + struct.pack('<I', len(encoded)) + encoded
    return prefix + b'\x00' * (-len(prefix) % 4) + payload[start:]

class BinaryTests(unittest.TestCase):

    def delta_fixture(self):
        data = copy.deepcopy(FIXTURE)
        data['vertices'][:2] = [-1048576, 2097152]
        return data

    def test_delta_roundtrip_restarts_xy_and_each_layer_chain(self):
        data = self.delta_fixture()
        payload = encode_world(data, encoding=DELTA_ENCODING)
        self.assertEqual(decode_world(payload), data)
        size = struct.unpack_from('<I', payload, 8)[0]
        header = json.loads(payload[12:12+size])
        start = (12 + size + 3) & ~3
        self.assertEqual(header['encoding'], DELTA_ENCODING)
        self.assertEqual(struct.unpack_from('<8i', payload, start),
                         (-1048576, 2097152, 1048576, -2097159, 100, 57, 1048476, 2097102))
        offset = start + header['binaryArrays']['layerEdges']['byteOffset']
        self.assertEqual(struct.unpack_from('<4i', payload, offset), (2, -2, 1, 1))

    def test_delta_overflow_is_rejected_without_wrapping(self):
        with self.assertRaisesRegex(ValueError, 'int32 delta'):
            encode_world(FIXTURE, encoding=DELTA_ENCODING)
        data = self.delta_fixture()
        payload = bytearray(encode_world(data, encoding=DELTA_ENCODING))
        size = struct.unpack_from('<I', payload, 8)[0]
        start = (12 + size + 3) & ~3
        struct.pack_into('<i', payload, start, (1 << 31) - 1)
        with self.assertRaisesRegex(ValueError, 'decoded int32 value'):
            decode_world(payload)

    def test_unknown_delta_encoding_is_rejected(self):
        payload = modify_header(encode_world(self.delta_fixture()),
                                lambda h: h.update(encoding='future-unsupported'))
        with self.assertRaisesRegex(ValueError, 'Unsupported binary encoding'):
            decode_world(payload)

    def test_roundtrip_preserves_ordered_edge_ids_int32_extremes_flags_and_unknown_metadata(self):
        self.assertEqual(decode_world(encode_world(FIXTURE)), FIXTURE)

    def test_gzip_fixture_is_deterministic_and_roundtrips(self):
        raw = encode_world(FIXTURE)
        a = gzip.compress(raw, mtime=0)
        b = gzip.compress(encode_world(copy.deepcopy(FIXTURE)), mtime=0)
        self.assertEqual(a, b)
        self.assertEqual(decode_world(gzip.decompress(a)), FIXTURE)

    def test_actual_wire_is_little_endian_and_arrays_aligned(self):
        payload = encode_world(FIXTURE)
        size = struct.unpack_from('<I', payload, 8)[0]
        start = 12 + size + 3 & ~3
        header = json.loads(payload[12:12 + size])
        self.assertEqual(start % 4, 0)
        self.assertEqual(payload[start:start + 8], b'\x00\x00\x00\x80\xff\xff\xff\x7f')
        self.assertEqual(struct.unpack_from('<8i', payload, start), tuple(FIXTURE['vertices']))
        layer = header['binaryArrays']['layerEdges']
        self.assertEqual(struct.unpack_from('<4i', payload, start + layer['byteOffset']), (2, 0, 1, 2))

    def test_legacy_missing_global_flag_is_preserved(self):
        data = copy.deepcopy(FIXTURE)
        del data['layers'][0]['globalOrigins']
        self.assertEqual(decode_world(encode_world(data)), data)

    def test_random_shared_graphs_roundtrip(self):
        rng = random.Random(604)
        for iteration in range(32):
            data = copy.deepcopy(FIXTURE)
            data['vertices'] = [rng.randrange(-2 ** 31, 2 ** 31) for _ in range(160)]
            data['edges'] = []
            for i in range(100):
                data['edges'].extend(rng.sample(range(80), 2))
            data['layers'] = [{'elevationCm': 100 + i * 0.125, 'globalOrigins': i == 0, 'edges': rng.sample(range(100), rng.randrange(100))} for i in range(7)]
            self.assertEqual(decode_world(encode_world(data)), data)

    def test_truncated_header_arrays_and_trailing_data_are_rejected(self):
        payload = encode_world(FIXTURE)
        for bad in [payload[:11], payload[:20], payload[:-1], payload + b'\x00']:
            with self.assertRaises(ValueError):
                decode_world(bad)

    def test_magic_version_and_nonzero_padding_are_rejected(self):
        payload = encode_world(FIXTURE)
        with self.assertRaises(ValueError):
            decode_world(payload[:4] + b'\x02' + payload[5:])
        data = copy.deepcopy(FIXTURE)
        while True:
            payload = encode_world(data)
            size = struct.unpack_from('<I', payload, 8)[0]
            if (12 + size) % 4:
                break
            data['paddingFixture'] = data.get('paddingFixture', '') + 'x'
        changed = bytearray(payload)
        changed[12 + size] = 1
        with self.assertRaises(ValueError):
            decode_world(changed)

    def test_array_overlap_misalignment_and_huge_count_are_rejected(self):
        payload = encode_world(FIXTURE)
        for name, value in [('byteOffset', 1), ('byteOffset', 0), ('elementCount', 2 ** 60)]:
            bad = modify_header(payload, lambda h: h['binaryArrays']['edges'].__setitem__(name, value))
            with self.assertRaises(ValueError):
                decode_world(bad)

    def test_layer_ranges_must_partition_the_array(self):
        for key, value in [('edgeOffset', 1), ('edgeCount', 100)]:
            bad = modify_header(encode_world(FIXTURE), lambda h: h['layers'][0].__setitem__(key, value))
            with self.assertRaises(ValueError):
                decode_world(bad)

    def test_malformed_index_values_are_rejected_on_decode(self):
        payload = bytearray(encode_world(FIXTURE))
        size = struct.unpack_from('<I', payload, 8)[0]
        header = json.loads(payload[12:12 + size])
        start = 12 + size + 3 & ~3
        offset = start + header['binaryArrays']['edges']['byteOffset']
        struct.pack_into('<i', payload, offset, -1)
        with self.assertRaises(ValueError):
            decode_world(payload)

    def test_encoder_rejects_overflow_boolean_indices_duplicates_and_degenerate_edges(self):
        mutations = [lambda d: d['vertices'].__setitem__(0, 2 ** 31), lambda d: d['edges'].__setitem__(0, True), lambda d: d['layers'][0]['edges'].append(2), lambda d: d['edges'].__setitem__(0, 1)]
        for mutate in mutations:
            data = copy.deepcopy(FIXTURE)
            mutate(data)
            with self.assertRaises(ValueError):
                encode_world(data)

    def test_empty_geometry_can_represent_clear_global_layer(self):
        data = copy.deepcopy(FIXTURE)
        data.update(vertices=[], edges=[], layers=[{'elevationCm': 475, 'globalOrigins': True, 'edges': []}])
        self.assertEqual(decode_world(encode_world(data)), data)

    def test_existing_output_requires_force_and_force_replaces_it(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'map_visibility.bin.gz'
            write_binary(output, b'old')
            with self.assertRaises(FileExistsError):
                write_binary(output, b'new')
            self.assertEqual(output.read_bytes(), b'old')
            write_binary(output, b'new', force=True)
            self.assertEqual(output.read_bytes(), b'new')
            self.assertEqual(list(Path(directory).iterdir()), [output])

    def test_failed_atomic_replace_keeps_previous_asset_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'map_visibility.bin.gz'
            output.write_bytes(b'old')
            with patch('world_visibility_binary.os.replace', side_effect=OSError('simulated replacement failure')):
                with self.assertRaises(OSError):
                    write_binary(output, b'new', force=True)
            self.assertEqual(output.read_bytes(), b'old')
            self.assertEqual(list(Path(directory).iterdir()), [output])
if __name__ == '__main__':
    unittest.main()
