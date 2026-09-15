"""Compare rendered shadow geometry with independent rays over a bounded grid.

This detects cone-mesh disagreements with its input candidate. It does not
certify the candidate's source ownership, floor policy, or gameplay accuracy.
Every disagreement is retained, including those near float32 mesh edges.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from audit_wall_contact_pixels import PhysicalGeometry
from native_reference_cast import NativeReferenceModel
from tactical_alignment_receiver import receiver_domain


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(folder, case, side, candidate, library, bounds, step, output):
    if output.exists():
        raise FileExistsError(output)
    manifest_path = folder/'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    row = next(r for r in manifest['cases'] if r['id'] == case and r['side'] == side)
    assert sha(candidate) == manifest['declaredCandidatePackSha256']
    warp_path = Path(manifest['displayWarpFile'])
    assert sha(warp_path) == manifest['displayWarpSha256']
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    mesh_path = Path(row['prefix']+'-shadow.f32')
    assert sha(mesh_path) == row['meshSha256']
    mesh = np.frombuffer(mesh_path.read_bytes(), dtype='<f4').astype(float)
    geometry = PhysicalGeometry(warp, row, mesh)
    receiver_path = Path('assets/maps') / (manifest['map']+'_map'+('_defense' if side == 'defense' else '')+'.svg')
    assert sha(receiver_path) == row['svgSha256']
    receiver = receiver_domain(receiver_path)
    xs = np.arange(bounds[0]+step/2, bounds[2], step)
    ys = np.arange(bounds[1]+step/2, bounds[3], step)
    xx, yy = np.meshgrid(xs, ys)
    attack_points = np.column_stack([xx.ravel(), yy.ravel()])
    points = np.array(warp['attackToDefenseSvg']['origin'])-attack_points if side == 'defense' else attack_points
    inside_receiver = shapely.covers(receiver, shapely.points(points))
    inside_frustum = geometry.in_frustum(points, margin=False)
    points = points[inside_receiver & inside_frustum]
    physical = geometry.native(points)
    actual = geometry.clear(points)
    source = NativeReferenceModel(candidate, library)
    q = np.array(row['query'])
    records = []
    blocked = 0
    # This bound classifies numerical diagnostics only. It does not move any
    # wall, discard a disagreement, or permit a visible pixel gap.
    mesh_rounding_band = float(16*np.finfo(np.float32).eps*max(1., float(abs(mesh).max(initial=0))))
    triangles = shapely.polygons(mesh.reshape(-1, 3, 2))
    boundaries = shapely.STRtree(shapely.boundary(triangles))
    for index, (xy, native, visible) in enumerate(zip(points, physical, actual)):
        hit = source.cast(q[:3], np.r_[native, q[2]])
        expected = hit is None
        blocked += not expected
        if expected == visible:
            continue
        point = shapely.Point(native-q[:2])
        nearest = boundaries.nearest(point)
        boundary_distance = float(shapely.distance(point, boundaries.geometries[nearest]))
        records.append(dict(pointSvg=xy.tolist(), pointNativeMeters=native.tolist(),
            expectedClear=expected, meshClear=bool(visible), sourceHit=hit,
            nearestShadowTriangleEdgeMeters=boundary_distance,
            withinFloat32EdgeBand=boundary_distance <= mesh_rounding_band))
    result = dict(scope=__doc__, case=case, side=side, query=row['query'],
        attackBoundsSvg=bounds, stepSvg=step, offeredGridPoints=len(attack_points),
        excludedOutsideReceiver=int((~inside_receiver).sum()),
        excludedOutsideFrustum=int((inside_receiver & ~inside_frustum).sum()),
        testedPoints=len(points), sourceBlockedPoints=int(blocked),
        disagreementCount=len(records), disagreements=records,
        meshFloat32EdgeBandMeters=mesh_rounding_band,
        disagreementsBeyondFloat32EdgeBand=sum(not r['withinFloat32EdgeBand'] for r in records),
        manifestSha256=sha(manifest_path), sourcePackSha256=sha(candidate),
        referenceLibrarySha256=sha(library), meshSha256=sha(mesh_path),
        scriptSha256=sha(Path(__file__)),
        limitations=['Finite grid of point queries, not an exhaustive angular proof.',
            'Same provisional candidate heights as the rendered query.',
            'Compares the shadow mesh before raster antialiasing; wall-contact raster audits remain separate.'])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: result[k] for k in ['case', 'side', 'testedPoints',
        'sourceBlockedPoints', 'disagreementCount', 'disagreementsBeyondFloat32EdgeBand']}), flush=True)
    assert result['disagreementsBeyondFloat32EdgeBand'] == 0, (
        f'Cone mesh disagrees with candidate rays; preserved report: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['folder', 'candidate', 'library', 'output']:
        parser.add_argument(name, type=Path)
    parser.add_argument('--case', required=True)
    parser.add_argument('--side', choices=['attack', 'defense'], default='attack')
    parser.add_argument('--bounds', type=float, nargs=4, required=True)
    parser.add_argument('--step', type=float, default=.125)
    args = parser.parse_args()
    if args.step <= 0 or args.bounds[0] >= args.bounds[2] or args.bounds[1] >= args.bounds[3]:
        parser.error('Bounds must enclose a positive region and step must be positive.')
    run(args.folder, args.case, args.side, args.candidate, args.library,
        args.bounds, args.step, args.output)
