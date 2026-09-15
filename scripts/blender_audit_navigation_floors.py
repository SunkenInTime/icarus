"""Check interpolated nav floor heights at independent triangle interior points."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from mathutils import Vector
from mathutils.bvhtree import BVHTree
import numpy as np


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world', required=True, type=Path)
    parser.add_argument('--navigation', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    raw = json.loads(args.navigation.read_text())
    refined = json.loads((args.world / 'floor-refinement.json').read_text())
    metadata = json.loads((args.world / 'geometry.json').read_text())
    if digest(args.navigation) != refined['sourceXYZSha256']:
        raise ValueError('Stale navigation floor refinement')
    if digest(args.world / 'geometry.npz') != metadata['geometrySha256']:
        raise ValueError('Stale reference geometry')
    geometry = np.load(args.world / 'geometry.npz')
    material_ids = geometry['material_indices']
    source_faces = geometry['faces']
    xyz = geometry['points'][source_faces]
    normals = np.cross(xyz[:, 1] - xyz[:, 0], xyz[:, 2] - xyz[:, 0])
    solid = np.asarray([m['category'] in ('opaque', 'unresolved')
                        for m in metadata['materials']])
    eligible = np.flatnonzero((normals[:, 2] > .65 * np.linalg.norm(normals, axis=1)) &
                              solid[material_ids])
    # Build the independent ray reference from admitted floor faces. Advancing
    # past a rejected coincident decal/down-facing face can otherwise skip an
    # opaque upward face at exactly the same height.
    tree = BVHTree.FromPolygons(geometry['points'].tolist(), source_faces[eligible].tolist(),
                                all_triangles=True, epsilon=0)
    vertices = np.asarray(raw['vertices']).reshape(-1, 3)
    triangles = np.asarray(raw['triangles']).reshape(-1, 4)
    heights = np.asarray(refined['refinedFloorHeightsCm'])
    samples = []
    for triangle, row in enumerate(triangles):
        polygon, *indices = row.tolist()
        for weights in [(1/3, 1/3, 1/3), (.6, .2, .2), (.2, .6, .2), (.2, .2, .6)]:
            raw_point = np.asarray(weights) @ vertices[indices]
            predicted = float(np.asarray(weights) @ heights[indices])
            seed = Vector((raw_point[0] / 100, -raw_point[1] / 100, raw_point[2] / 100))
            start, end = seed + Vector((0, 0, .3)), seed - Vector((0, 0, .7))
            hit, normal, face, _ = tree.ray_cast(start, Vector((0, 0, -1)), start.z - end.z)
            accepted = face is not None and abs(hit.z - seed.z) <= .60001
            face = int(eligible[face]) if face is not None else None
            category = metadata['materials'][int(material_ids[face])]['category'] if face is not None else None
            measured = hit.z * 100 if accepted else None
            neighbor_heights = [measured] if accepted else []
            # Points exactly on tread/mesh edges can choose either incident
            # face in a float BVH. Keep that uncertainty explicit instead of
            # interpreting a sub-mm XY tie as a centimetre-scale height error.
            for dx, dy in ((.0001, 0), (-.0001, 0), (0, .0001), (0, -.0001)):
                nearby = seed + Vector((dx, dy, .3))
                neighbor, _, neighbor_face, _ = tree.ray_cast(nearby, Vector((0, 0, -1)), 1.0)
                if neighbor_face is not None and abs(neighbor.z - seed.z) <= .60001:
                    neighbor_heights.append(neighbor.z * 100)
            samples.append({'triangle': triangle, 'polygon': polygon, 'weights': weights,
                            'originWorldCm': raw_point.tolist(), 'predictedZCm': predicted,
                            'measuredZCm': measured, 'category': category,
                            'errorCm': abs(predicted - measured) if accepted else None,
                            'floorRangeWithin0_01cmCm': [min(neighbor_heights), max(neighbor_heights)]
                                if neighbor_heights else None,
                            'face': face if accepted else None})
    errors = [s['errorCm'] for s in samples if s['category'] == 'opaque' and s['errorCm'] is not None]
    summary = {'map': raw['map'], 'samples': len(samples), 'opaqueMeasured': len(errors),
               'p50ErrorCm': float(np.percentile(errors, 50)),
               'p95ErrorCm': float(np.percentile(errors, 95)),
               'p99ErrorCm': float(np.percentile(errors, 99)), 'maxErrorCm': max(errors),
               'over1cm': sum(e > 1 for e in errors), 'over5cm': sum(e > 5 for e in errors),
               'over10cm': sum(e > 10 for e in errors)}
    report = {'schemaVersion': 2, 'summary': summary,
              'referencePolicy': 'BVH of upward opaque/unresolved faces; no skipping coincident surfaces.',
              'navigationSourceSha256': digest(args.navigation),
              'floorRefinementSha256': digest(args.world / 'floor-refinement.json'),
              'geometrySha256': metadata['geometrySha256'], 'samples': samples}
    args.output.write_text(json.dumps(report), encoding='utf8')
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
