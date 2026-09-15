"""Compare serialized wall-profile sections with independent triangle intervals."""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp


def merge_intervals(values):
    result = []
    for low, high in sorted(values):
        if result and low <= result[-1][1]:
            result[-1][1] = max(result[-1][1], high)
        else:
            result.append([low, high])
    return result


def triangle_intervals(profiles, height):
    result = []
    ids = np.flatnonzero((profiles[:, :, 1].min(1) <= height) & (profiles[:, :, 1].max(1) >= height))
    for triangle in profiles[ids]:
        contacts = []
        for a, b in zip(triangle, np.roll(triangle, -1, axis=0)):
            if a[1] == height:
                contacts.append(float(a[0]))
            if min(a[1], b[1]) < height < max(a[1], b[1]):
                contacts.append(float(a[0] + (height-a[1]) / (b[1]-a[1]) * (b[0]-a[0])))
        if contacts:
            result.append([min(contacts), max(contacts)])
    return merge_intervals(result)


def geometry_intervals(geometry):
    if geometry.is_empty:
        return []
    if geometry.geom_type in ('LineString', 'Point'):
        x = np.asarray(geometry.coords)[:, 0]
        return [[float(x.min()), float(x.max())]]
    return merge_intervals([value for part in geometry.geoms for value in geometry_intervals(part)])


def interval_error(expected, observed):
    # Positive-area differences use exact interval membership. Point/end contact
    # distances are checked separately so a dropped isolated point cannot pass.
    events = sorted({v for line in expected+observed for v in line})
    missing = 0.
    for a, b in zip(events, events[1:]):
        mid = a + (b-a)*.5
        first = any(lo < mid < hi for lo, hi in expected)
        second = any(lo < mid < hi for lo, hi in observed)
        if first != second:
            missing += b-a
    def directed(a, b):
        if not a:
            return 0.
        if not b:
            return float('inf')
        return max(min(max(low-x, 0., x-high) for low, high in b) for line in a for x in line)
    return missing, max(directed(expected, observed), directed(observed, expected))


def verify(compiled, oracle, warp_path, output, diagnostic=False):
    if output.exists():
        raise FileExistsError(output)
    report = json.loads((compiled / 'report.json').read_text())
    profile_path = compiled / 'wall-profiles.json.gz'
    data = json.loads(gzip.decompress(profile_path.read_bytes()))
    assert sha(profile_path) == report['profileSha256']
    assert sha(compiled / 'assignment.npz') == report['assignmentSha256']
    assert sha(warp_path) == data['displayWarpSha256']
    oracle_path = oracle / f'{data["map"]}.height.bin.gz'
    assert sha(oracle_path) == data['oraclePackSha256'] == report['oraclePackSha256']
    _, scene = pack(oracle_path)
    with np.load(compiled / 'assignment.npz') as archive:
        assignment, residual = archive['profileRegion'], archive['residualOracleFaces']
    assert len(assignment) == len(scene['faces'])
    assert np.array_equal(residual, np.flatnonzero(assignment < 0))
    assert ((assignment >= -1) & (assignment < len(data['regions']))).all()
    assert (assignment[scene['faceMasks'] >= 0] < 0).all()
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    native = np.asarray(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target = np.asarray(warp['targetAttackSvg']).reshape(-1, 2)
    forward = explicit_warp(native, target-native, np.asarray(warp['triangles']).reshape(-1, 3))
    xyz = scene['vertices'][scene['faces']]
    xy = forward.apply((xyz[:, :, :2] @ matrix.T + origin).reshape(-1, 2)).reshape(-1, 3, 2)
    results, failures = [], []
    for index, region in enumerate(data['regions']):
        ids = np.flatnonzero(assignment == index)
        o, tangent = np.asarray(region['startSvg']), np.asarray(region['tangentSvg'])
        along = (xy[ids]-o) @ tangent
        normal = np.array([-tangent[1], tangent[0]])
        contact = float(abs((xy[ids]-o) @ normal).max(initial=0))
        assert contact <= 1e-10
        profiles = np.stack((along, xyz[ids, :, 2]), axis=2)
        heights = np.unique(profiles[:, :, 1])
        # All source height events, plus every adjacent interval's midpoint.
        probes = np.unique(np.r_[heights, heights[:-1]+np.diff(heights)*.5])
        geometry = shapely.from_geojson(json.dumps(region['opaqueRegion']))
        lo, hi = float(along.min())-1, float(along.max())+1
        max_length, max_endpoint = 0., 0.
        for height in probes:
            expected = triangle_intervals(profiles, height)
            observed = geometry_intervals(geometry.intersection(shapely.LineString([[lo,height],[hi,height]])))
            length, endpoint = interval_error(expected, observed)
            max_length, max_endpoint = max(max_length, length), max(max_endpoint, endpoint)
            if not (length < 1e-8 and endpoint < 1e-8):
                failures.append(dict(region=index, height=float(height), length=length, endpoint=endpoint,
                    expected=expected, observed=observed))
                if not diagnostic:
                    raise AssertionError((index, height, length, endpoint))
        results.append(dict(region=index, family=region['family'], span=region['span'], heights=len(probes),
            maximumSectionSymmetricDifferenceSvg=max_length, maximumEndpointDistanceSvg=max_endpoint))
        print('region', index, 'sections', len(probes), 'max', max_length, max_endpoint, flush=True)
    result = dict(scope=__doc__, passed=not failures, diagnostic=diagnostic, failures=failures, regions=results, testedHeightSections=sum(r['heights'] for r in results),
        profileSha256=sha(profile_path), oraclePackSha256=sha(oracle_path), verifierSha256=sha(Path(__file__)),
        limitation='All source-height events and interval midpoints tested. Floating section tolerance1e-8SVG; not exact union proof, native inverse-W or gameplay validation.')
    output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k,v in result.items() if k != 'regions'}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['compiled', 'oracle', 'warp_path', 'output']:
        parser.add_argument(key, type=Path)
    parser.add_argument('--diagnostic', action='store_true')
    verify(**vars(parser.parse_args()))
