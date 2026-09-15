"""Compare compact profile membership with independent native triangle casts.

Only opaque profile interiors are certified by these finite samples. Numerical
boundary samples, masked regions and intervening unrelated faces are reported.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp


def run(folder, candidate, warp_path, library):
    path = folder / 'wall-profiles.json.gz'
    data = json.loads(gzip.decompress(path.read_bytes()))
    pack_path = candidate / (data['map'] + '.height.bin.gz')
    assert hashlib.sha256(pack_path.read_bytes()).hexdigest() == data['candidatePackSha256']
    assert hashlib.sha256(warp_path.read_bytes()).hexdigest() == data['displayWarpSha256']
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.array(warp['projection']['origin'])
    source_svg = np.array(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target_svg = np.array(warp['targetAttackSvg']).reshape(-1, 2)
    backward = explicit_warp(target_svg, source_svg - target_svg, np.array(warp['triangles']).reshape(-1, 3))
    source = NativeReferenceModel(pack_path, library)
    provenance = np.load(candidate / 'normalized-face-provenance.npz')
    edge_by_face = dict(zip(provenance['generatedFaceIds'].tolist(), provenance['generatedEdges'].tolist()))
    records, failures, tolerance_contacts = [], [], []
    for family in data['families']:
        region = shapely.from_geojson(json.dumps(family['opaqueRegion']))
        lo, zlo, hi, zhi = region.bounds
        grid = np.array(np.meshgrid(np.linspace(lo, hi, 61), np.linspace(zlo - .01, zhi + .01, 31))).reshape(2, -1).T
        vertices = shapely.get_coordinates(region)
        # Probe either side of every stored height/along transition, not only
        # regular interior points that could miss a small opening.
        offsets = np.array([[1e-5, 0], [-1e-5, 0], [0, 1e-5], [0, -1e-5]])
        probes = np.unique(np.vstack((grid, (vertices[:, None] + offsets).reshape(-1, 2))), axis=0)
        points = shapely.points(probes)
        numerical = shapely.distance(points, region.boundary) <= 1e-8
        masked = np.zeros(len(probes), dtype=bool)
        for item in family['maskedProfiles']:
            masked |= shapely.covers(shapely.Polygon(item['profile']).buffer(1e-8), points)
        eligible = ~(numerical | masked)
        expected = shapely.covers(region, points)
        frame = family['targetFrame']
        o, t, n = (np.array(frame[k]) for k in ('origin', 'tangent', 'normal'))
        along_svg = o + probes[:, :1] * t
        contact_native = (backward.apply(along_svg) - origin) @ np.linalg.inv(matrix).T
        counts = dict(matched=0, interveningOtherFace=0, nativeEdgeToleranceContacts=0, numericalBoundarySkipped=int(numerical.sum()),
                      maskedProfileSkipped=int((masked & ~numerical).sum()))
        for sign in (-1, 1):
            starts = (backward.apply(along_svg + n * sign * .001) - origin) @ np.linalg.inv(matrix).T
            for i in np.flatnonzero(eligible):
                a = np.r_[starts[i], probes[i, 1]]
                b = np.r_[2 * contact_native[i] - starts[i], probes[i, 1]]
                hit = source.cast(a, b)
                if hit is not None and edge_by_face.get(hit['face'], -1) != family['edge']:
                    counts['interveningOtherFace'] += 1
                    continue
                if (hit is not None) != bool(expected[i]):
                    if hit is not None and not expected[i]:
                        tri = source.arrays['vertices'][source.arrays['faces'][hit['face']]]
                        uv = np.linalg.lstsq((tri[1:] - tri[0]).T, np.array(hit['point']) - tri[0], rcond=None)[0]
                        bary = np.r_[1 - uv.sum(), uv]
                        # The existing native oracle admits barycentric values
                        # down to -1e-7. Keep that exterior halo visible as a
                        # distinct result; do not dilate the compact geometry.
                        if -1.01e-7 <= bary.min() < -1e-10:
                            nearest_bary = np.maximum(bary, 0)
                            nearest_bary /= nearest_bary.sum()
                            excess = float(np.linalg.norm(nearest_bary @ tri - np.array(hit['point'])))
                            tolerance_contacts.append(dict(edge=family['edge'], face=hit['face'],
                                                           minimumBarycentric=float(bary.min()),
                                                           maximumDistanceToTriangleMeters=excess))
                            counts['nativeEdgeToleranceContacts'] += 1
                            continue
                    failures.append(dict(edge=family['edge'], alongHeight=probes[i].tolist(),
                                         side=sign, profileBlocked=bool(expected[i]), nativeHit=hit))
                else:
                    counts['matched'] += 1
        records.append(dict(edge=family['edge'], **counts))
    report = dict(scope=__doc__, profileDataSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                  candidatePackSha256=data['candidatePackSha256'], probeSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  families=records, mismatches=failures, mismatchCount=len(failures),
                  nativeEdgeToleranceContacts=tolerance_contacts,
                  maximumNativeExteriorHaloMeters=max((r['maximumDistanceToTriangleMeters'] for r in tolerance_contacts), default=0),
                  exactRuntimeEquivalence=False)
    (folder / 'independent-native-probes.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(mismatches=len(failures), families=records), indent=2))
    assert not failures, 'Compact profile differs from the original candidate triangle oracle'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('folder', 'candidate', 'warp', 'library'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    run(args.folder, args.candidate, args.warp, args.library)
