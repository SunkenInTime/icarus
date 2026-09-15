"""Replay frozen absolute-height corridors through one bounded source XY region.

Rebuild from original source Z, including fragments discarded by the provisional
floor policy. Other changed families must be spatially disjoint from every ray.
This checks the declared field, not the application's unfinished floor policy.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np

from authored_region_cells import region_fragments
from authored_wall_profile_cells import inverse_in_cell
from build_split_normalized_wall_families import cut
from native_reference_cast import NativeReferenceModel
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from world_visibility_ray_reference import ray_triangle

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def overlapping(triangles, start, end, dimensions=3):
    low = np.minimum(start, end)[:dimensions]
    high = np.maximum(start, end)[:dimensions]
    xyz = triangles[:, :, :dimensions]
    return np.flatnonzero((xyz.max(1) >= low - 1e-10).all(1)
                         & (xyz.min(1) <= high + 1e-10).all(1))


def conservative_hits(triangles, start, end):
    direction = end - start
    length = np.linalg.norm(direction)
    direction /= length
    hits, unresolved = [], []
    for index in overlapping(triangles, start, end):
        triangle = triangles[index]
        normal = np.cross(triangle[1]-triangle[0], triangle[2]-triangle[0])
        magnitude = np.linalg.norm(normal)
        if magnitude == 0:
            continue
        determinant = abs(float(direction @ normal))
        if determinant <= 1e-12:
            # Do not silently certify a coplanar/near-parallel intersection.
            if abs(float((start-triangle[0]) @ normal)) / magnitude <= 1e-9:
                unresolved.append(int(index))
            continue
        hit = ray_triangle(start, direction, triangle)
        if hit is not None and hit[0] <= length + 1e-10:
            hits.append(dict(triangle=int(index), distanceMeters=hit[0]))
    return hits, unresolved


def run(candidate, edge, fixture_path, output):
    if output.exists():
        raise FileExistsError(output)
    bindings = json.loads((candidate/'bindings.json').read_text())
    candidate_pack, = [p for p in candidate.glob('*.height.bin.gz') if 'backup' not in p.name]
    header, scene = pack(candidate_pack)
    name = header['map']
    proof_path = candidate/'root-independent-profile-review.json'
    proof = json.loads(proof_path.read_text())
    assert proof['candidatePackSha256'] == sha(candidate_pack)
    assert proof['wallBindingsSha256'] == sha(candidate/'bindings.json')
    assert proof['status'] == 'attribute-and-continuous-span-contact-checks-passed'
    family, = [f for f in bindings['families'] if f['edge'] == edge]
    assert family['mappingType'] == 'piecewise-affine-region-v1'
    fixtures = json.loads(fixture_path.read_text())
    raw_path = ROOT/f'supplemented-v2/world/{name}/geometry.npz'
    full_path = REV/f'full-height-input-v1/{name}/{name}.height.bin.gz'
    warp_path = REV/f'display-warps-v1/{name}.display-warp.json.gz'
    assert sha(raw_path) == fixtures['sourceGeometrySha256']
    assert sha(full_path) == fixtures['sourcePackSha256']
    assert sha(warp_path) == bindings['displayWarpSha256']
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.array(warp['projection']['origin'])
    inverse = np.linalg.inv(matrix)
    source = np.array(warp['sourceNativeMeters']).reshape(-1,2) @ matrix.T + origin
    target = np.array(warp['targetAttackSvg']).reshape(-1,2)
    backward = explicit_warp(target, source-target, np.array(warp['triangles']).reshape(-1,3))
    raw = np.load(raw_path)
    source_ids = family.get('reviewedSourceFaces', family.get('reviewedSourceFaceIds'))
    assert source_ids
    triangles = raw['points'][raw['faces'][source_ids]].astype(float)
    triangles[:, :, :2] = triangles[:, :, :2] @ matrix.T + origin
    mapped, parents = [], []
    for source_id, triangle in zip(source_ids, triangles):
        inside, _ = cut(list(np.column_stack((triangle, np.eye(3)))), family['box'])
        if len(inside) < 3:
            continue
        for fragment, cell, _ in region_fragments(np.array(inside), family, backward):
            xyz = fragment[:, :3].copy()
            xyz[:, :2] = (inverse_in_cell(xyz[:, :2], backward, cell)-origin) @ inverse.T
            for j in range(1, len(xyz)-1):
                mapped.append(xyz[[0,j,j+1]])
                parents.append(source_id)
    mapped = np.asarray(mapped)
    print('Original-height mapped fragments:', len(mapped), flush=True)
    provenance = np.load(candidate/'normalized-face-provenance.npz')
    other_ids = provenance['generatedFaceIds'][
        (provenance['generatedEdges'] != edge) & (provenance['generatedEdges'] != -1)]
    other_triangles = scene['vertices'][scene['faces'][other_ids]]
    original = NativeReferenceModel(full_path, REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    rows = []
    for fixture in fixtures['fixtures']:
        start = np.array(fixture['originNativeMeters'], dtype=float)
        end = np.array(fixture['targetNativeMeters'], dtype=float)
        other = overlapping(other_triangles, start, end, dimensions=2)
        hits, unresolved = conservative_hits(mapped, start, end)
        for hit in hits:
            hit['originalSourceFace'] = int(parents[hit['triangle']])
        source_hit = original.cast(start, end, end_padding=0, end_inclusive=True)
        rows.append(dict(id=fixture['id'], sourceHit=source_hit, mappedHits=hits,
                         unresolvedCoplanarTriangles=unresolved,
                         otherChangedFamilyXYOverlaps=len(other),
                         passed=source_hit is None and not hits and not unresolved and not len(other)))
    report = dict(scope=__doc__, candidatePackSha256=sha(candidate/f'{name}.height.bin.gz'),
                  bindingsSha256=sha(candidate/'bindings.json'), fixtureSha256=sha(fixture_path),
                  sourceProfileProofSha256=sha(proof_path),
                  sourceGeometrySha256=sha(raw_path), originalPackSha256=sha(full_path),
                  scriptSha256=sha(Path(__file__)), region=edge,
                  regionMappingHelperSha256=sha(Path(__file__).with_name('authored_region_cells.py')),
                  profilePartitionHelperSha256=sha(Path(__file__).with_name('authored_wall_profile_cells.py')),
                  boundsClipHelperSha256=sha(Path(__file__).with_name('build_split_normalized_wall_families.py')),
                  rebuiltOriginalHeightFragments=len(mapped), records=rows,
                  passed=all(row['passed'] for row in rows),
                  limitations=['Five frozen controls only; no whole-map sightline certification.',
                               'Absolute source field replay; not a relative-ground runtime test.',
                               'All mapped triangles treated opaque, conservatively.'])
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2), flush=True)
    assert report['passed'], 'Source-height corridor regression or unresolved query'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('edge', type=int)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    run(args.candidate, args.edge, args.fixtures, args.output)
