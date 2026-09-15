"""Add independently interpolated native fallback floors to reference metadata.

The original 3D casts, sampled origins, heights and accuracy statistics stay
unchanged. Detailed-floor sampling alone cannot list a stacked native parent
whose detailed floor has a hole. Such a parent uses its refined native surface.
Write a new reference directory and retain hashes of the original references.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely


def read_json(path):
    raw = Path(path).read_bytes()
    return json.loads(gzip.decompress(raw) if raw[:2] == b'\x1f\x8b' else raw)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class NativeFallbackReference:
    """Native plane interpolation, independent of the Dart navigation code."""

    def __init__(self, navigation):
        self.navigation = navigation
        self.vertices = np.asarray(navigation['vertices'], dtype=float).reshape(-1, 3).copy()
        self.vertices[:, :2] /= navigation['coordinateScale']
        refined = navigation.get('refinedFloorHeightsCm')
        if refined is not None:
            for index, height in enumerate(refined):
                if height is not None:
                    self.vertices[index, 2] = height
        self.parents = [shapely.Polygon(self.vertices[indices, :2]) for indices in navigation['polygons']]
        self.walkable = np.asarray(navigation['walkable'], dtype=bool)
        self.native = self._index(self.vertices, navigation['triangles'])
        floor = navigation.get('floorMesh')
        if floor is None:
            self.detail = None
        else:
            vertices = np.asarray(floor['vertices'], dtype=float).reshape(-1, 3).copy()
            vertices[:, :2] /= floor['coordinateScale']
            self.detail = self._index(vertices, floor['triangles'])

    @staticmethod
    def _index(vertices, triangles):
        rows = np.asarray(triangles, dtype=int).reshape(-1, 4)
        corners = vertices[rows[:, 1:]]
        polygons = shapely.polygons(corners[:, :, :2])
        return rows, corners, shapely.STRtree(polygons)

    def _heights(self, index, position):
        rows, corners, tree = index
        point = shapely.Point(position)
        result = {}
        # Triangle selection uses the exact 2D domain. The samples are interior
        # points, so a permissive barycentric edge tolerance is unnecessary.
        for triangle in tree.query(point, predicate='intersects'):
            parent = int(rows[triangle, 0])
            if not self.walkable[parent] or not self.parents[parent].covers(point):
                continue
            a, b, c = corners[triangle]
            coefficients = np.linalg.solve(np.column_stack((b[:2] - a[:2], c[:2] - a[:2])),
                                           np.asarray(position) - a[:2])
            u, v = coefficients
            height = float(a[2] + u * (b[2] - a[2]) + v * (c[2] - a[2]))
            if parent not in result or height > result[parent]['floorHeightCm']:
                result[parent] = {'parentNavPolygon': parent, 'floorHeightCm': height,
                                  'sourceNativeTriangle': int(triangle),
                                  'nativeBarycentric': [float(1 - u - v), float(u), float(v)]}
        return result

    def fallback_at(self, position):
        native = self._heights(self.native, position)
        detail = self._heights(self.detail, position) if self.detail else {}
        return {parent: value for parent, value in native.items() if parent not in detail}


def complete_reference(reference, navigation):
    # Deep copy before adding annotations; callers retain the original evidence.
    output = json.loads(json.dumps(reference))
    calculator = NativeFallbackReference(navigation)
    positions = {}
    for ray in reference['rays']:
        positions.setdefault(ray['sample'], ray['startUv'])
    additions = []
    for origin in output['origins']:
        existing = {row['parentNavPolygon'] for row in origin['floorAlternatives']}
        extra = []
        for parent, row in sorted(calculator.fallback_at(positions[origin['id']]).items()):
            if parent in existing:
                raise ValueError('An existing detailed reference overlaps a native fallback parent.')
            extra.append({**row, 'sourceKind': 'refined-native-fallback'})
        if extra:
            origin['floorAlternatives'].extend(extra)
            additions.append({'origin': origin['id'], 'alternativesAdded': extra})
    assert output['rays'] == reference['rays']
    assert output['summary'] == reference['summary']
    for before, after in zip(reference['origins'], output['origins']):
        assert {k: v for k, v in before.items() if k != 'floorAlternatives'} == {
            k: v for k, v in after.items() if k != 'floorAlternatives'}
        assert after['floorAlternatives'][:len(before['floorAlternatives'])] == before['floorAlternatives']
    return output, additions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('references', type=Path)
    parser.add_argument('navigation', type=Path,
                        help='Folder of NAME_navigation.json.gz, including the encoded detailed floors.')
    parser.add_argument('output', type=Path)
    parser.add_argument('--maps', nargs='+', required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name in args.maps:
        target = args.output / (name + '.json')
        if target.exists():
            raise ValueError('Choose fresh reference outputs; existing evidence is never overwritten.')
        source = args.references / target.name
        navigation = args.navigation / (name + '_navigation.json.gz')
        reference, nav = read_json(source), read_json(navigation)
        if reference['map'] != name or nav['map'] != name:
            raise ValueError('Map identity differs.')
        result, additions = complete_reference(reference, nav)
        proof = {'schemaVersion': 1, 'map': name, 'gameplayCertified': False,
                 'sourceReferenceSha256': digest(source), 'navigationSha256': digest(navigation),
                 'scriptSha256': digest(__file__), 'raysAndStatisticsUnchanged': True,
                 'sourceReference': str(source.resolve()), 'navigationFile': str(navigation.resolve()),
                 'originsChecked': len(reference['origins']), 'additions': additions}
        proof_path = args.output / (name + '.native-fallback-proof.json')
        proof_path.write_text(json.dumps(proof, indent=2, allow_nan=False), encoding='utf-8')
        result['floorAlternativeCompletion'] = {'proofFile': proof_path.name, 'proofSha256': digest(proof_path),
                                              'sourceReferenceSha256': digest(source)}
        target.write_text(json.dumps(result, separators=(',', ':'), allow_nan=False), encoding='utf-8')
        policy = source.with_suffix('.policies.json')
        target.with_suffix('.policies.json').write_bytes(policy.read_bytes())
        print(json.dumps({'map': name, 'originsChecked': len(reference['origins']),
                          'originsWithAddedFallback': len(additions), 'referenceSha256': digest(target)}), flush=True)


if __name__ == '__main__':
    main()
