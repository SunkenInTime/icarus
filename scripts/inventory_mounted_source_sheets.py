"""Find source sheets near backing geometry before wall normalization.

This is a geometric review queue, not automatic blocker classification. It uses
original world coordinates and opaque triangle probes. Material and gameplay
roles require separate review. No source or production data is changed.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def nearest_opaque(triangles, raw_ids, origin, direction, length=.03):
    """Probe unfiltered raw triangles, including faces omitted by material policy."""
    ab, ac = triangles[:, 1]-triangles[:, 0], triangles[:, 2]-triangles[:, 0]
    p = np.cross(direction, ac)
    determinant = np.einsum('ij,ij->i', ab, p)
    valid = abs(determinant) > 1e-12
    inverse = np.zeros_like(determinant)
    inverse[valid] = 1 / determinant[valid]
    relative = origin-triangles[:, 0]
    q = np.cross(relative, ab)
    u = np.einsum('ij,ij->i', relative, p)*inverse
    v = q @ direction * inverse
    distance = np.einsum('ij,ij->i', ac, q)*inverse
    valid &= (u >= -1e-7) & (v >= -1e-7) & (u+v <= 1+1e-7)
    valid &= (distance >= 1e-7) & (distance <= length)
    hits = np.flatnonzero(valid)
    if not len(hits):
        return None
    face = hits[np.argmin(distance[hits])]
    normal = np.cross(ab[face], ac[face])
    magnitude = np.linalg.norm(normal)
    if magnitude == 0:
        return None
    return int(raw_ids[face]), float(distance[face]), normal / magnitude


def inventory(name, output):
    if output.exists():
        raise FileExistsError(output)
    raw_path = ROOT / f'supplemented-v2/world/{name}/geometry.npz'
    metadata = json.loads(raw_path.with_suffix('.json').read_text())
    raw = np.load(raw_path)
    points, faces = raw['points'], raw['faces']
    objects = metadata['objects']
    starts = np.array([ob['firstFace'] for ob in objects])
    bounds = np.asarray([ob['boundsMeters'] for ob in objects], dtype=float)
    assert bounds.shape == (len(objects), 2, 3) and np.isfinite(bounds).all()
    records, considered = [], 0
    for index, ob in enumerate(objects):
        if not 1 <= ob['faceCount'] <= 8:
            continue
        raw_ids = np.arange(ob['firstFace'], ob['firstFace'] + ob['faceCount'])
        triangles = points[faces[raw_ids]].astype(float)
        xyz = np.unique(triangles.reshape(-1, 3), axis=0)
        center = xyz.mean(0)
        _, singular, vh = np.linalg.svd(xyz-center, full_matrices=False)
        if len(singular) < 3 or singular[1] < .02 or singular[2] > 1e-5:
            continue
        normal = vh[-1]
        if abs(normal[2]) > .15:
            continue
        area = float(np.linalg.norm(np.cross(triangles[:, 1]-triangles[:, 0],
                                             triangles[:, 2]-triangles[:, 0]), axis=1).sum() / 2)
        if not .02 <= area <= 20:
            continue
        considered += 1
        neighbors = np.flatnonzero((bounds[:, 1] >= xyz.min(0)-.03).all(1)
                                  & (bounds[:, 0] <= xyz.max(0)+.03).all(1))
        neighbors = neighbors[neighbors != index]
        if not len(neighbors):
            continue
        neighbor_faces = np.concatenate([np.arange(objects[j]['firstFace'], objects[j]['firstFace']
                                                   + objects[j]['faceCount']) for j in neighbors])
        neighbor_triangles = points[faces[neighbor_faces]].astype(float)
        # Inset vertex probes avoid assigning a neighboring wall merely
        # because a sheet's corner touches it. Every result retains its source.
        probes = np.vstack((center, center + .98 * (xyz-center)))
        hits = []
        for probe_id, point in enumerate(probes):
            for side in [-1, 1]:
                hit = nearest_opaque(neighbor_triangles, neighbor_faces, point, side * normal)
                if hit is None:
                    continue
                face, distance, backing_normal = hit
                alignment = abs(float(normal @ backing_normal))
                if alignment < .98:
                    continue
                raw_face = face
                backing = int(np.searchsorted(starts, raw_face, side='right')-1)
                hits.append(dict(probe=probe_id, side=side, sourcePoint=point.tolist(),
                                 distanceMeters=distance, backingRawFace=raw_face,
                                 backingObject=backing, normalAlignment=alignment))
        if not hits:
            continue
        backed_probes = {h['probe'] for h in hits}
        backing_ids = sorted({h['backingObject'] for h in hits})
        records.append(dict(sourceObject=index, sourcePath=ob['path'], sourceFaces=raw_ids.tolist(),
                            areaSquareMeters=area, planeResidualMeters=float(singular[2]),
                            sourceBounds=[xyz.min(0).tolist(), xyz.max(0).tolist()],
                            probes=len(probes), backedProbes=len(backed_probes),
                            fullProbeCoverage=len(backed_probes) == len(probes),
                            backingObjects=[dict(sourceObject=i, path=objects[i]['path']) for i in backing_ids],
                            hits=hits))
    report = dict(scope=__doc__, map=name, sourceGeometrySha256=sha(raw_path),
                  sourceMetadataSha256=sha(raw_path.with_suffix('.json')),
                  scriptSha256=sha(Path(__file__)),
                  inputPolicy='All raw source faces, independent of filtered blocker packs.',
                  thresholds=dict(maximumFaces=8, maximumPlaneResidualMeters=1e-5,
                                  maximumBackingDistanceMeters=.03, minimumNormalAlignment=.98),
                  consideredSheets=considered, matchedSheets=len(records), records=records,
                  limitations=['Candidate queue only. No automatic wall ownership or removal.',
                               'Finite probes do not prove continuous backing over the whole sheet.',
                               'Opaque geometric reference ignores material alpha for this inventory.',
                               'Only small flat near-vertical source instances are included.'])
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(dict(map=name, considered=considered, matched=len(records),
                          fullProbeCoverage=sum(row['fullProbeCoverage'] for row in records))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('map')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    inventory(args.map, args.output)
