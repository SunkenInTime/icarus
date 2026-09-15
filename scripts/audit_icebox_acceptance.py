"""Create a source-first Icebox acceptance fixture and regional inventory.

This command writes audit output and a portable fixture, never map assets.
The source domains and expected heights are established before assets are read.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from gameplay_standing_volumes import StandingVolumes
from gameplay_source_floors import SourceFloors
from build_all_map_gameplay_supports import standing_obstacles
from audit_all_map_gameplay_levels import ROOT as EXTRACTED_ROOT


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def affine(matrix):
    return [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]


def sample_domain(domain, spacing=.5):
    """Interior grid and inward offsets along every source-domain boundary."""
    points = [part.representative_point() for part in shapely.get_parts(domain)
              if part.geom_type == 'Polygon']
    x0, y0, x1, y1 = domain.bounds
    for x in np.arange(np.ceil(x0 / spacing) * spacing, x1, spacing):
        for y in np.arange(np.ceil(y0 / spacing) * spacing, y1, spacing):
            p = shapely.Point(x, y)
            if domain.contains(p):
                points.append(p)
    # These are intentionally generated from source boundaries, not supports.
    inner = domain.buffer(-.02)
    for part in shapely.get_parts(inner):
        if part.geom_type != 'Polygon':
            continue
        for ring in [part.exterior, *part.interiors]:
            for d in np.arange(0, ring.length, spacing):
                points.append(ring.interpolate(d))
    return np.unique(np.round([[p.x, p.y] for p in points], 8), axis=0)


def build(root, output, fixture_path, region_bounds=(270, 140, 345, 225)):
    if root.resolve() != EXTRACTED_ROOT.resolve():
        raise ValueError('The current extraction readers are bound to the recorded source root.')
    revision = root / 'tactical-visibility-revision'
    alignment_path = root / 'tactical-alignment-sides-v1/icebox.json'
    alignment = read(alignment_path)
    matrices = {side: np.array(alignment[f'nativeTo{side.title()}Svg'])
                for side in ['attack', 'defense']}
    attack = matrices['attack']
    inverse = np.linalg.inv(attack[:, :2])
    native_matrix = np.c_[inverse, -inverse @ attack[:, 2]]
    region_svg = shapely.box(*region_bounds)
    region_native = affine_transform(region_svg, affine(native_matrix))
    geometry_path = root / 'supplemented-v2/world/icebox/geometry.npz'
    metadata_path = geometry_path.with_suffix('.json')
    geometry = np.load(geometry_path)
    world_points, world_faces = geometry['points'], geometry['faces']
    objects = read(metadata_path)['objects']
    review_path = Path('scripts/data/icebox-playable-space-review.json')
    review = read(review_path)
    assert review['metadataSha256'] == digest(metadata_path)
    decisions = {d['sourceObject']: d for d in review['decisions']}
    source = SourceFloors('icebox')
    volumes = StandingVolumes('icebox')
    assert not volumes.unresolved, volumes.unresolved
    print('Loaded source geometry and player volumes.', flush=True)

    # Inventory geometry independently of the current runtime asset.
    inventory = []
    for oid, obj in enumerate(objects):
        if not obj['faceCount']:
            continue
        faces = world_points[world_faces[obj['firstFace']:obj['firstFace'] + obj['faceCount']]].astype(float)
        lo, hi = faces[:, :, :2].min(axis=(0, 1)), faces[:, :, :2].max(axis=(0, 1))
        if not region_native.buffer(.42).intersects(shapely.box(*lo, *hi)):
            continue
        normal = np.cross(faces[:, 1] - faces[:, 0], faces[:, 2] - faces[:, 0])
        lengths = np.linalg.norm(normal, axis=1)
        possible = (lengths > 1e-9) & (abs(normal[:, 2]) > 1e-9)
        shapes = shapely.polygons(faces[possible, :, :2])
        hits = shapely.intersects(shapes, region_native)
        # Keep every intersecting placed mesh bounding box. Render-face slope
        # cannot exclude an unseen simple collision top, and an empty projected
        # face intersection is a measurement outcome rather than an inventory filter.
        try:
            evidence = source.object(oid)
        except (ValueError, KeyError, FileNotFoundError) as error:
            evidence = dict(classification='unresolved-source-identity',
                            diagnostic=f'{type(error).__name__}: {error}')
        classification = evidence['classification']
        excluded = classification.startswith('excluded')
        if oid in decisions:
            decision = decisions[oid]
            assert decision['sourcePath'] == obj['path']
            excluded = decision['status'] == 'excluded'
            classification = decision['reason']
        inventory.append(dict(sourceObject=oid, path=obj['path'],
            possibleFacesInRegion=int(hits.sum()), status='excluded' if excluded else 'unresolved',
            reason=classification,
            evidence={k: v for k, v in evidence.items() if k != 'sections'},
            scope='Player support; an excluded render mesh can have a separate player blocking volume.'))
    print('Inventoried', len(inventory), 'source mesh instances.', flush=True)
    collision_inventory = [dict(collision=row['id'], kill=row['kill'], unwalkable=row['unwalkable'],
        status='excluded' if row['kill'] or row['unwalkable'] else 'resolved-collision-body',
        bounds=row['bounds']) for row in volumes.rows
        if region_native.intersects(shapely.box(*row['bounds'][0][:2], *row['bounds'][1][:2]))]

    # Source expectation 1: the actual Top Screens player collider.
    collision = '/Port_BVPawn/BP_BlockingVolume167/Cube#0'
    index = next(i for i, r in enumerate(volumes.rows) if r['id'] == collision)
    triangles = volumes.triangles[index]
    top = triangles[np.max(abs(triangles[:, :, 2] - 7.), axis=1) < 1e-6]
    assert len(top) > 0
    screens = shapely.union_all(shapely.polygons(top[:, :, :2]))
    screens = screens.difference(standing_obstacles(volumes, screens, 7., ignored={index}))
    assert not screens.is_empty
    screens_review = revision / 'sightline-review/reviews/1788883963581-57243566.json'
    pipe_review = revision / 'sightline-review/reviews/1788823493671-212d5f8.json'
    screens_pose = read(screens_review)['cones'][3]
    pipe_pose = read(pipe_review)['cones'][3]
    domains = [dict(id='top-screens', sourceCollision=collision,
        basis='Player-collision top with known-volume standing clearance; reported gameplay position.',
        nativeGeometry=json.loads(shapely.to_geojson(screens)), expectedFloorMeters=7.)]
    cases = []

    def add_case(identifier, xy, floor, kind, direction=0.):
        cases.append(dict(id=identifier, nativeXY=np.asarray(xy).tolist(), expectedFloorMeters=float(floor),
            expectedEyeMeters=float(floor + 1.75), selection=kind, directionAttack=direction))

    for i, xy in enumerate(sample_domain(screens)):
        add_case(f'top-screens-domain-{i}', xy, 7., 'level-present')
    screens_xy = inverse @ (np.asarray(screens_pose['origin']) - attack[:, 2])
    assert screens.covers(shapely.Point(screens_xy))
    add_case('top-screens-reported', screens_xy, 7., 'automatic', screens_pose['direction'])
    cases[-1]['savedReferenceEyeMeters'] = read(screens_review)['computed'][3]['eyeMeters']
    cases[-1]['savedReferenceScope'] = 'Compatibility with the frozen lower ground choice; not physical-floor certification.'
    # A continuous segment of the independently defined platform interior.
    p = screens.representative_point()
    segment = screens.buffer(-.05).intersection(shapely.LineString([(p.x - 20, p.y), (p.x + 20, p.y)]))
    for part in shapely.get_parts(segment):
        if part.geom_type != 'LineString':
            continue
        for i, distance in enumerate(np.arange(0, part.length, .1)):
            xy = np.asarray(part.interpolate(distance).coords)[0]
            add_case(f'top-screens-walk-{len(cases)}', xy, 7., 'level-present')

    # Source expectation 2: the exact local pipe faces identified in gameplay review.
    oid = 3730
    obj = objects[oid]
    assert 'Pipe' in obj['path'] or 'pipe' in obj['path'], obj['path']
    local_faces = [104, 105, 106, 107, 170, 171, 178, 179]
    selected = world_points[world_faces[obj['firstFace'] + np.array(local_faces)]].astype(float)
    pipe_xy = inverse @ (np.asarray(pipe_pose['origin']) - attack[:, 2])
    points = shapely.polygons(selected[:, :, :2])
    plane = np.linalg.solve(np.concatenate([selected[:, :, :2], np.ones((len(selected), 3, 1))], axis=2), selected[:, :, 2, None])[:, :, 0]
    matches = np.flatnonzero(shapely.covers(points, shapely.Point(pipe_xy)))
    assert len(matches) > 0
    elevations = plane[matches, :2] @ pipe_xy + plane[matches, 2]
    assert np.ptp(elevations) < .002
    floor = float(elevations.max())
    add_case('lower-pipe-reported', pipe_xy, floor, 'automatic', pipe_pose['direction'])
    domains.append(dict(id='lower-pipe-step', sourceObject=oid, sourcePath=obj['path'],
        sourceLocalFaces=local_faces, basis='Local rendered faces identified by the recorded gameplay review; independent physical-contact certification remains separate.',
        nativeGeometry=json.loads(shapely.to_geojson(shapely.union_all(points))), expectedFloorMeters=floor))
    for case in cases:
        xy = np.array(case['nativeXY'])
        case['svg'] = {side: (m[:, :2] @ xy + m[:, 2]).tolist() for side, m in matrices.items()}

    collision_hash = hashlib.sha256(json.dumps(volumes.rows, sort_keys=True, separators=(',', ':')).encode())
    for triangles in volumes.triangles:
        collision_hash.update(np.asarray(triangles, dtype='<f8').tobytes())
    evidence = dict(geometrySha256=digest(geometry_path), metadataSha256=digest(metadata_path),
        sourceInventoryAlgorithmSha256=digest(Path(__file__)),
        playableSpaceReviewSha256=digest(review_path),
        nativePlacementAuditSha256=digest(root / 'native-material-audit/world/icebox/native-slot-audit.json'),
        collisionConfigurationSha256=digest(root / 'icebox-acceptance-collision-v2/collision-configuration.json'),
        collisionResolutionCode={p: digest(Path('scripts') / p) for p in
            ['gameplay_source_floors.py', 'native_collision_defaults.py', 'cooked_collision_evidence.py',
             'native_instance_collision.py', 'gameplay_standing_volumes.py',
             'build_all_map_gameplay_supports.py', 'standing_complex_clearance.py',
             'redundant_capsule_collision.py']},
        decodedPlayerCollisionSha256=collision_hash.hexdigest(),
        alignmentSha256=digest(alignment_path),
        reviews={p.stem: digest(p) for p in [screens_review, pipe_review]})
    fixture = dict(version=1, map='icebox', scope='A Top Screens and local lower pipe; source-defined standing checks, not region-wide gameplay certification.',
        heightToleranceMeters=.02, source=evidence, regionSvgBounds=list(region_bounds),
        domains=domains, cases=cases)
    output.mkdir(parents=True, exist_ok=True)
    fixture_path.parent.mkdir(parents=True, exist_ok=True)
    fixture_path.write_text(json.dumps(fixture, indent=2) + '\n')
    counts = dict(Counter(r['status'] for r in inventory))
    result = dict(source=evidence, sourceRegion=json.loads(shapely.to_geojson(region_native)),
        sourceInventoryMarginMeters=.42,
        requiredSourceObjects=[r['sourceObject'] for r in inventory],
        inventory=inventory, collisionBodies=collision_inventory, counts=counts,
        sourceCaseCount=len(cases), sourceFixtureSha256=digest(fixture_path),
        status='unresolved' if counts.get('unresolved') else 'inventory-classified',
        limitations=['Static-mesh collision defaults and local contact shapes must be resolved before full regional acceptance.',
                    'Known-volume capsule clearance does not establish collision completeness.',
                    'Local reviewed pipe faces are not blanket approval of the source object.',
                    'Standing inventory is not a complete sightline-blocker inventory outside the region.'])
    (output / 'source-inventory.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(counts=counts, collisionBodies=len(collision_inventory), cases=len(cases),
        domains=[dict(id=d['id'], floor=d['expectedFloorMeters']) for d in domains], status=result['status'])), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path('E:/IcarusWorldAudit/2026-09-06'))
    parser.add_argument('--output', type=Path, default=Path('work/icebox-acceptance'))
    parser.add_argument('--fixture', type=Path, default=Path('test/fixtures/icebox_vision_acceptance.json'))
    parser.add_argument('--region-svg-bounds', nargs=4, type=float, default=[270, 140, 345, 225])
    args = parser.parse_args()
    build(args.source_root, args.output, args.fixture, args.region_svg_bounds)
