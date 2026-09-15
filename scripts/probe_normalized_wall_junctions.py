"""Oblique rays near reviewed SVG wall endpoints expose normalization cracks.

Only the explicit candidate wall families are treated as expected solid spans.
Unrelated first hits and absent height profiles remain separately reported.
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
from tactical_alignment_receiver import receiver_domain
from verify_normalized_wall_profiles import profile_frame

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def inverse_wall_lines(lines, target_cells, backward, matrix, origin):
    inverse = np.linalg.inv(matrix)
    cell_tree = shapely.STRtree(target_cells)
    native_lines = []
    for line in lines:
        touched = cell_tree.query(line, predicate='intersects')
        for part in shapely.get_parts(shapely.intersection(line, target_cells[touched])):
            coordinates = shapely.get_coordinates(part)
            if len(coordinates) < 2:
                continue
            physical = (backward.apply(coordinates) - origin) @ inverse.T
            native_lines.append(shapely.LineString(physical))
    return shapely.union_all(native_lines)


def select_receiver_side(signs, explicit=None):
    if explicit is not None:
        if explicit not in (-1, 1) or explicit not in signs:
            raise ValueError('Reviewed observer side must be within the SVG receiver')
        return explicit
    if len(signs) != 1:
        raise ValueError('Ambiguous receiver side; an interior cover needs an explicit source-reviewed side')
    return signs[0]


def run(folder, map_name='split', side_contract_path=None):
    proof = json.loads((folder / 'bindings.json').read_text())
    side_contract = json.loads(side_contract_path.read_text()) if side_contract_path else {}
    used_contracts = set()
    if not map_name.isalpha() or not map_name.islower():
        raise ValueError('Invalid map name')
    warp_path = REV / f'display-warps-v1/{map_name}.display-warp.json.gz'
    assert hashlib.sha256(warp_path.read_bytes()).hexdigest() == proof['displayWarpSha256']
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    inverse = np.linalg.inv(matrix)
    origin = np.array(warp['projection']['origin'])
    native_svg = np.array(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target_svg = np.array(warp['targetAttackSvg']).reshape(-1, 2)
    indices = np.array(warp['triangles']).reshape(-1, 3)
    backward = explicit_warp(target_svg, native_svg - target_svg, indices)
    forward = explicit_warp(native_svg, target_svg - native_svg, indices)
    receiver = receiver_domain(Path(f'assets/maps/{map_name}_map.svg'))
    candidate_path = folder / f'{map_name}.height.bin.gz'
    source = NativeReferenceModel(candidate_path, REV / 'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    baseline = NativeReferenceModel(Path(proof['sourceBackup']), REV / 'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    provenance = np.load(folder / 'normalized-face-provenance.npz')
    family_by_face = dict(zip(provenance['generatedFaceIds'].tolist(), provenance['generatedEdges'].tolist()))
    span_families = []
    for family in proof['families']:
        if family.get('mappingType') != 'piecewise-affine-region-v1':
            span_families.append(family)
            continue
        for span in family.get('reviewedAuthoredSpans', []):
            start, finish = np.asarray([span['startSvg'], span['endSvg']], dtype=float)
            tangent = finish - start
            length = float(np.linalg.norm(tangent))
            assert length > 0
            tangent /= length
            span_families.append(dict(edge=family['edge'], completeSpan=span['completeSpan'],
                mappingRegionEdge=family['edge'], targetAlong=[0., length],
                sourceFrame=dict(origin=start, tangent=tangent, normal=[-tangent[1], tangent[0]]),
                targetFrame=dict(origin=start, tangent=tangent, normal=[-tangent[1], tangent[0]])))
    # A region's perimeter is a transform boundary, not a physical wall.
    # Its triangles still participate in every cast against the candidate.
    lines = []
    for family in span_families:
        frame_origin, tangent, _ = profile_frame(family, 'target')
        points = frame_origin + np.array(family['targetAlong'])[:, None] * tangent
        lines.append(shapely.LineString(points))
    walls = shapely.union_all(lines)
    # A straight physical ray can bend in the displayed coordinate system.
    # Split each authored span at W cells before inverse mapping it. Intersect
    # the physical ray with those exact native pieces, never a straight SVG
    # line used as a substitute for the displayed ray.
    target_cells = shapely.polygons(target_svg[indices])
    native_walls = inverse_wall_lines(lines, target_cells, backward, matrix, origin)
    records, skipped, wall_origins, outside_span_targets = [], 0, 0, 0
    for family, line in zip(span_families, lines):
        endpoints = np.array(line.coords)
        tangent = (endpoints[1] - endpoints[0]) / line.length
        normal = np.array([-tangent[1], tangent[0]])
        middle = endpoints.mean(0)
        signs = [sign for sign in (-1, 1) if receiver.covers(shapely.Point(middle + normal * sign * .5))]
        key = str(family.get('completeSpan', family['edge']))
        explicit = side_contract.get(key, {}).get('normalSign')
        if explicit is not None:
            used_contracts.add(key)
        inward = normal * select_receiver_side(signs, explicit)
        for end in (0, 1):
            for inset in (.005, .025, .05, .1, .25, .5, 1., 2.):
                if inset >= line.length:
                    # Short authored corner returns are real walls. A fixed
                    # two-unit probe must not put its target beyond that wall.
                    outside_span_targets += 1
                    continue
                target = endpoints[end] + tangent * inset * (1 if end == 0 else -1)
                for tangent_shift in (-4., -2., 0., 2., 4.):
                    start = target + inward * 4 + tangent * tangent_shift
                    finish = target - inward * 2 - tangent * tangent_shift * .5
                    if not receiver.covers(shapely.Point(start)):
                        skipped += 1
                        continue
                    if walls.distance(shapely.Point(start)) <= 1e-7:
                        # Native rays exclude t=0 self-contact. Such an origin
                        # cannot test whether the next wall contact is aligned.
                        wall_origins += 1
                        continue
                    start_and_target = (backward.apply(np.array([start, target])) - origin) @ inverse.T
                    xy = np.array([start_and_target[0], start_and_target[1] +
                                   .5 * (start_and_target[1] - start_and_target[0])])
                    finish = forward.apply(xy[1] @ matrix.T + origin)
                    ray = shapely.LineString(xy)
                    contacts = shapely.get_coordinates(ray.intersection(native_walls))
                    if not len(contacts):
                        raise ValueError(('Test ray misses authored wall', family['edge'], end, inset, tangent_shift))
                    native_contact = contacts[np.argmin(np.linalg.norm(contacts - xy[0], axis=1))]
                    contact = forward.apply(native_contact @ matrix.T + origin)
                    direction = xy[1] - xy[0]
                    direction /= np.linalg.norm(direction)
                    scale_svg = float(np.linalg.norm(matrix @ direction))
                    for height in (.75, 1.75, 2.75):
                        a, b = np.r_[xy[0], height], np.r_[xy[1], height]
                        hit, old_hit = source.cast(a, b), baseline.cast(a, b)
                        row = dict(svgEdge=family['edge'], endpoint=end, insetSvg=inset,
                                   tangentShiftSvg=tangent_shift, relativeEyeHeightMeters=height,
                                   startSvg=start.tolist(), finishSvg=finish.tolist(), expectedContactSvg=contact.tolist(),
                                   sourceOriginallyBlocked=old_hit is not None,
                                   status='no-candidate-hit' if hit is None else 'hit')
                        if 'mappingRegionEdge' in family:
                            row.update(completeSpan=family['completeSpan'], mappingRegionEdge=family['mappingRegionEdge'])
                        if hit is not None:
                            display_hit = forward.apply(np.array(hit['point'][:2]) @ matrix.T + origin)
                            signed_error = float((np.array(hit['point'][:2]) - native_contact) @ direction) * scale_svg
                            edge = family_by_face.get(int(hit['face']), -1)
                            row.update(hitSvg=display_hit.tolist(), generatedEdge=edge,
                                       signedContactErrorSvg=signed_error, face=int(hit['face']))
                            if signed_error > 1e-6:
                                row['status'] = 'passed-authored-wall'
                            elif signed_error < -1e-6:
                                row['status'] = 'early-family-hit' if edge >= 0 else 'early-unbound-hit'
                            else:
                                row['status'] = 'exact-contact'
                        records.append(row)
    assert used_contracts == set(side_contract), 'Unused observer-side contracts'
    counts = {status: sum(row['status'] == status for row in records) for status in sorted({row['status'] for row in records})}
    report = dict(scope=__doc__, sourcePackSha256=proof['sourcePackSha256'],
                  candidatePackSha256=hashlib.sha256(candidate_path.read_bytes()).hexdigest(),
                  probeSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  wallBindingsSha256=hashlib.sha256((folder / 'bindings.json').read_bytes()).hexdigest(),
                  displayWarpSha256=proof['displayWarpSha256'],
                  observerSideContracts=side_contract,
                  observerSideContractSha256=hashlib.sha256(side_contract_path.read_bytes()).hexdigest() if side_contract_path else None,
                  candidate=str(folder), rays=len(records), originsOutsideSvgSkipped=skipped,
                  originsOnReviewedWallsSkipped=wall_origins,
                  probeTargetsOutsideFiniteSpanSkipped=outside_span_targets,
                  reviewedTargets=[dict(familyEdge=f['edge'], completeSpan=f.get('completeSpan'),
                                        mappingRegionEdge=f.get('mappingRegionEdge')) for f in span_families],
                  statusCounts=counts, records=records)
    (folder / 'independent-junction-rays.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(rays=len(records), statusCounts=counts), indent=2))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--map', default='split')
    parser.add_argument('--side-contract', type=Path)
    args = parser.parse_args()
    run(args.folder, args.map, args.side_contract)
