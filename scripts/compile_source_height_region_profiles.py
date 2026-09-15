"""Union opaque original-height wall faces on explicitly reviewed SVG spans.

Every masked, unmatched or zero-area face remains in a residual reference list.
The data is offline and still requires inverse-display splitting for native rays.
No geometry simplification or production asset replacement is performed.
"""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import profile_frame


def compile_profiles(oracle, candidate, warp_path, output):
    if output.exists():
        raise FileExistsError(output)
    bindings_path = candidate / 'bindings.json'
    bindings = json.loads(bindings_path.read_text())
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    height_gate_path, xy_gate_path = oracle / 'root-height-material-review.json', oracle / 'root-restored-xy-review.json'
    height_gate, xy_gate = json.loads(height_gate_path.read_text()), json.loads(xy_gate_path.read_text())
    oracle_path = oracle / f'{warp["map"]}.height.bin.gz'
    provenance_path = oracle / 'original-source-provenance.npz'
    assert height_gate['passed'] and xy_gate['passed']
    assert height_gate['oraclePackSha256'] == xy_gate['oraclePackSha256'] == sha(oracle_path)
    assert height_gate['candidatePackSha256'] == xy_gate['candidatePackSha256'] == sha(candidate / f'{warp["map"]}.height.bin.gz')
    assert height_gate['bindingsSha256'] == sha(bindings_path)
    assert height_gate['sourceProvenanceSha256'] == xy_gate['oracleProvenanceSha256'] == sha(provenance_path)
    assert bindings['displayWarpSha256'] == sha(warp_path)
    _, scene = pack(oracle_path)
    with np.load(provenance_path) as archive:
        edges = archive['edges']
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    native = np.asarray(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target = np.asarray(warp['targetAttackSvg']).reshape(-1, 2)
    forward = explicit_warp(native, target - native, np.asarray(warp['triangles']).reshape(-1, 3))
    triangles = scene['vertices'][scene['faces']]
    xy = forward.apply((triangles[:, :, :2] @ matrix.T + origin).reshape(-1, 2)).reshape(-1, 3, 2)
    assigned = np.full(len(triangles), -1, dtype=np.int32)
    regions = []
    for family in bindings['families']:
        ids = np.flatnonzero(edges == family['edge'])
        if family.get('mappingType') == 'piecewise-affine-region-v1':
            spans = [dict(id=s['completeSpan'], start=np.asarray(s['startSvg']), end=np.asarray(s['endSvg'])) for s in family.get('reviewedAuthoredSpans', [])]
        else:
            o, t, _ = profile_frame(family, 'target')
            spans = [dict(id=family['edge'], start=o + family['targetAlong'][0]*t, end=o + family['targetAlong'][1]*t)]
        for span in spans:
            delta = span['end'] - span['start']; length = np.linalg.norm(delta)
            tangent = delta / length; normal = np.array([-tangent[1], tangent[0]])
            along = (xy[ids] - span['start']) @ tangent
            error = abs((xy[ids] - span['start']) @ normal).max(1)
            eligible = (assigned[ids] < 0) & (scene['faceMasks'][ids] < 0) & (error <= 1e-10)
            eligible &= (along.min(1) >= -1e-10) & (along.max(1) <= length + 1e-10)
            profiles = np.stack((along, triangles[ids, :, 2]), axis=2)
            a, b = profiles[:, 1] - profiles[:, 0], profiles[:, 2] - profiles[:, 0]
            area2 = abs(a[:, 0]*b[:, 1] - a[:, 1]*b[:, 0])
            # Nearly horizontal/degenerate profiles are a poor input for a
            # floating polygon union. Keep their original triangles intact in
            # the residual instead. This is a routing choice, not deletion or
            # a claim that their geometry has zero area.
            spacing = abs(np.spacing(profiles)).max(1)
            extent = np.ptp(profiles, axis=1)
            union_condition_floor = 32 * (extent[:, 0]*spacing[:, 1] + extent[:, 1]*spacing[:, 0])
            eligible &= area2 > union_condition_floor
            selected = np.flatnonzero(eligible)
            if not len(selected):
                continue
            polygons = shapely.polygons(profiles[selected])
            assert shapely.is_valid(polygons).all()
            union = shapely.union_all(polygons)
            assert union.is_valid
            encoded = shapely.to_geojson(union)
            assert union.equals_exact(shapely.from_geojson(encoded), tolerance=0)
            row = dict(family=family['edge'], span=span['id'], startSvg=span['start'].tolist(),
                endSvg=span['end'].tolist(), tangentSvg=tangent.tolist(), opaqueRegion=json.loads(encoded),
                sourceTriangles=len(selected), boundaryVertices=int(shapely.get_num_coordinates(union)),
                maximumSourceContactResidualSvg=float(error[selected].max(initial=0)))
            assigned[ids[selected]] = len(regions)
            regions.append(row)
    residual = np.flatnonzero(assigned < 0)
    assert np.all(assigned[scene['faceMasks'] >= 0] < 0), 'Masked faces must remain source-backed'
    data = dict(format='icarus-original-height-reviewed-region-profiles-v1', version=1, map=warp['map'],
        coordinatePolicy='Reviewed SVG span distance and original source height in meters',
        oraclePackSha256=sha(oracle_path), bindingsSha256=sha(bindings_path), displayWarpSha256=sha(warp_path),
        profileContactLimitSvg=1e-10, simplificationTolerance=0, regions=regions,
        residualConditionPolicy='Keep area2 <= 32*(extentAlong*ulpZ + extentZ*ulpAlong) in original triangle form. No faces deleted.',
        residualGeometry='Retain every referenced oracle face. Mask data and textures remain in the bound oracle pack.')
    raw = json.dumps(data, separators=(',', ':'), allow_nan=False).encode()
    output.mkdir(parents=True)
    profile_path = output / 'wall-profiles.json.gz'
    profile_path.write_bytes(gzip.compress(raw, mtime=0))
    np.savez_compressed(output / 'assignment.npz', profileRegion=assigned, residualOracleFaces=residual)
    report = dict(scope=__doc__, oraclePackSha256=sha(oracle_path), oracleTriangles=len(triangles),
        profileTriangles=int((assigned >= 0).sum()), residualTriangles=len(residual),
        maskedResidualTriangles=int((scene['faceMasks'][residual] >= 0).sum()),
        regions=len(regions), profileBoundaryVertices=sum(r['boundaryVertices'] for r in regions),
        compressedProfileBytes=profile_path.stat().st_size, rawProfileBytes=len(raw),
        assignmentBytes=(output / 'assignment.npz').stat().st_size,
        profileSha256=sha(profile_path), assignmentSha256=sha(output / 'assignment.npz'),
        compilerSha256=sha(Path(__file__)), productionMutation=False,
        limitations=['Only explicitly reviewed line spans are distilled; remaining geometry stays in the reference.',
                     'Union uses floating polygon arithmetic; independent section/ray equivalence verification required.',
                     'Inverse-display splitting, masked-source fallback, receiver floors and native runtime not implemented here.',
                     'Byte counts exclude residual geometry, textures and the full map. No refresh-rate claim.'])
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['oracle', 'candidate', 'warp_path', 'output']:
        parser.add_argument(key, type=Path)
    compile_profiles(**vars(parser.parse_args()))
