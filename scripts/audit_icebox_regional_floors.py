"""Measure every resolved regional collision floor before reading app assets."""
from collections import defaultdict, Counter
import argparse
import json
import hashlib
from pathlib import Path

import numpy as np
import shapely
from scipy.spatial import QhullError
from shapely.affinity import translate
from pxr import Usd, UsdGeom

from audit_all_map_gameplay_levels import ROOT, planes
from build_all_map_gameplay_supports import standing_obstacles
from gameplay_source_floors import SourceFloors
from gameplay_standing_volumes import StandingVolumes, collision_parts, walkable_slope_angle
from native_instance_collision import instance_physics_matrix
from redundant_capsule_collision import enclosed_capsules
from native_capsule_collision import outside_capsules
from checkpoint_floor_measurements import checkpointed_measurements
from polygonal_area import polygonal

OUT = Path('work/icebox-acceptance')
CLEARANCE_PRECISION_METERS = 1e-7


def merge_floor_faces(faces):
    # Per-face capsule shifts can leave nearly coincident vertices. Floating
    # union can lose a complete triangle at such a join. Use the same grid
    # before union as the later clearance overlays.
    return polygonal(shapely.union_all(faces, grid_size=CLEARANCE_PRECISION_METERS))


def subtract_clearance(domain, obstacles):
    # standing_obstacles uses this grid. Subtract on the same grid so rounding
    # its outer edge cannot leave a false floor along the audit boundary.
    return polygonal(shapely.difference(polygonal(domain), polygonal(obstacles),
        grid_size=CLEARANCE_PRECISION_METERS))


def build(output=OUT, collisions_only=False, all_colliders=False, workers=1):
    algorithm = Path(__file__).read_bytes()
    algorithm_sha256 = hashlib.sha256(algorithm).hexdigest()
    inventory = json.loads((output / 'source-inventory.json').read_bytes())
    map_name = inventory.get('map', 'icebox')
    region = shapely.from_geojson(json.dumps(inventory['sourceRegion']))
    source = SourceFloors(map_name)
    raw = np.load(ROOT / f'supplemented-v2/world/{map_name}/geometry.npz')
    points, faces = raw['points'], raw['faces']
    volumes = StandingVolumes(map_name)
    known_volume_count = len(volumes.rows)
    shapes, pending, redundant, outside, stages = {}, [], {}, {}, {}
    # A body just outside the standing region can still obstruct a capsule.
    for oid, obj in enumerate(source.objects):
        lo, hi = np.asarray(obj['boundsMeters'])
        if not all_colliders and not region.buffer(.42).intersects(shapely.box(*lo[:2], *hi[:2])):
            continue
        evidence = source.object(oid)
        kind = evidence['classification']
        if kind.startswith('excluded'):
            continue
        if not kind.startswith('declared-pawn-blocking'):
            pending.append(dict(sourceObject=oid, reason=kind))
            continue
        triangles = points[faces[obj['firstFace']:obj['firstFace'] + obj['faceCount']]].astype(float)
        placement = source.placement(oid)
        instanced = placement is not None and '/Prototypes/' in placement['sourcePrim']
        physics_evidence = None
        if kind != 'declared-pawn-blocking-complex' or instanced:
            if placement is None:
                pending.append(dict(sourceObject=oid, reason='Simple collision instance transform needs verification'))
                continue
            stage_path = placement.get('sourceUsd') or str(ROOT.parent / f'2026-09-04/verification-final-13.05/{map_name}/static-art.usda')
            if stage_path not in stages:
                stages[stage_path] = Usd.Stage.Open(stage_path)
            stage = stages[stage_path]
            prim = stage.GetPrimAtPath(placement['sourcePrim'])
            cache = UsdGeom.XformCache()
            if instanced:
                instancer = UsdGeom.PointInstancer(stage.GetPrimAtPath(placement['sourcePrim'].split('/Prototypes/')[0]))
                parent = np.asarray(cache.GetLocalToWorldTransform(instancer.GetPrim()))
                transforms = instancer.ComputeInstanceTransformsAtTime(Usd.TimeCode.Default(), Usd.TimeCode.Default())
                matrix = np.asarray(transforms[placement['sourceInstance']]) @ parent
            else:
                matrix = np.asarray(cache.GetLocalToWorldTransform(prim))
            if not np.isclose(np.linalg.det(matrix[:3, :3]), placement['placementDeterminant'], atol=1e-12, rtol=1e-12):
                raise ValueError('Simple collider transform differs from verified placement')
            local = np.asarray(UsdGeom.Mesh(prim).GetPointsAttr().Get())
            expected = (local @ matrix[:3, :3] + matrix[3, :3]) * .01
            error = float(max(np.max(abs(expected.min(0) - triangles.reshape(-1, 3).min(0))),
                              np.max(abs(expected.max(0) - triangles.reshape(-1, 3).max(0)))))
            if error > .001:
                pending.append(dict(sourceObject=oid, reason='Simple collider and source placement disagree', boundsErrorMeters=error))
                continue
            if instanced:
                component = source.level(placement['nativeLevel'])[placement['nativeComponentIndex']]
                physics, physics_evidence = instance_physics_matrix(ROOT, placement, component, parent,
                    export=ROOT/f'{map_name}-native-instance-transforms-v1')
                local_triangles = (triangles * 100 - matrix[3, :3]) @ np.linalg.inv(matrix[:3, :3])
                physical_triangles = (local_triangles @ physics[:3, :3] + physics[3, :3]) * .01
                physics_evidence['maximumRenderVertexDifferenceMeters'] = float(np.linalg.norm(physical_triangles - triangles, axis=2).max())
                triangles, matrix = physical_triangles, physics
        if kind == 'declared-pawn-blocking-complex':
            enabled = np.zeros(len(triangles), dtype=bool)
            for section in evidence['sections']:
                if section.get('bEnableCollision') is True:
                    first = section['FirstIndex'] // 3
                    enabled[first:first + section['NumTriangles']] = True
            if evidence['bodySetup'].get('bMeshCollideAll'):
                enabled[:] = True
            parts = [(triangles[enabled], None)]
        else:
            try:
                parts = collision_parts(evidence['bodySetup'], triangles, matrix)
            except QhullError:
                pending.append(dict(sourceObject=oid, reason='Degenerate serialized simple collision'))
                continue
            except ValueError as error:
                proof = enclosed_capsules(evidence['bodySetup'], matrix, volumes)
                if proof is not None:
                    shapes[oid] = []
                    redundant[oid] = proof
                    continue
                proof = outside_capsules(evidence['bodySetup'], matrix, region)
                if proof is not None:
                    shapes[oid] = []
                    outside[oid] = proof
                    continue
                # Preserve true capsules as analytic clearance bodies. Standing
                # is resolved after the complete surrounding assembly is loaded.
                from native_capsule_collision import capsule_parts
                try:
                    analytic = capsule_parts(evidence['bodySetup'], matrix)
                except ValueError:
                    pending.append(dict(sourceObject=oid, reason=str(error)))
                    continue
                indices = []
                for part, capsule in enumerate(analytic):
                    index = len(volumes.rows)
                    volumes.rows.append(dict(id=f'source-object-{oid}-part-{part}', sourceObject=oid,
                        unwalkable=evidence.get('unwalkable', False), kill=False,
                        body=evidence['effectiveBody'], bounds=capsule['bounds'],
                        physicsTransformEvidence=physics_evidence, analyticCapsule=capsule))
                    volumes.triangles.append(np.empty((0, 3, 3)))
                    volumes.equations.append(None)
                    indices.append(index)
                shapes[oid] = indices
                continue
        indices = []
        for part, (tri, equations) in enumerate(parts):
            if not len(tri):
                continue
            if equations is not None:
                # Qhull simplex winding is arbitrary; its plane normals are outward.
                tri = tri.copy()
                normals = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
                reverse = np.einsum('ij,ij->i', normals, equations[:, :3]) < 0
                tri[reverse] = tri[reverse][:, [0, 2, 1]]
            index = len(volumes.rows)
            bounds = [tri.reshape(-1, 3).min(0).tolist(), tri.reshape(-1, 3).max(0).tolist()]
            volumes.rows.append(dict(id=f'source-object-{oid}-part-{part}', sourceObject=oid,
                unwalkable=evidence.get('unwalkable', False), kill=False,
                body=evidence['effectiveBody'], bounds=bounds, physicsTransformEvidence=physics_evidence))
            volumes.triangles.append(tri)
            volumes.equations.append(equations)
            indices.append(index)
        shapes[oid] = indices
    bounds = np.asarray([r['bounds'] for r in volumes.rows])
    volumes.tree = shapely.STRtree(shapely.box(bounds[:, 0, 0], bounds[:, 0, 1], bounds[:, 1, 0], bounds[:, 1, 1]))
    from native_capsule_standing import (blocked_standing_prism, enclosed_in_assembly,
        blocked_contact_prism)
    for index, row in enumerate(volumes.rows):
        capsule = row.get('analyticCapsule')
        if capsule is None:
            continue
        proof = (blocked_standing_prism(capsule, volumes, walkable_slope_angle(row)) or
            enclosed_in_assembly(capsule, volumes) or
            blocked_contact_prism(capsule, volumes, walkable_slope_angle(row)))
        if proof is not None:
            row['analyticStandingExclusion'] = proof
        else:
            pending.append(dict(sourceObject=row['sourceObject'],
                reason='Analytic capsule standing contacts require additional source evidence'))
    print(f'Loaded {len(shapes)} regional/margin mesh colliders; {len(pending)} unresolved influencing records.', flush=True)
    (output / 'source-colliders.json').write_text(json.dumps(volumes.rows))
    np.savez_compressed(output / 'source-colliders.npz', **{str(i): t for i, t in enumerate(volumes.triangles)})
    (output / 'collision-accounting.json').write_text(json.dumps(dict(
        meshColliders=len(shapes), unresolved=pending, redundantCollision=redundant,
        outsideRegionCollision=outside,
        allSceneColliders=all_colliders, algorithmSha256=algorithm_sha256), indent=2) + '\n')
    (output / 'collision-algorithm.py').write_bytes(algorithm)
    if collisions_only:
        return
    rows, domains = [], []
    obligations = []
    for item in inventory['inventory']:
        if item['status'] == 'unresolved':
            oid = item['sourceObject']
            obligations.append((f'mesh-{oid}', dict(sourceObject=oid,
                sourcePath=source.objects[oid]['path']), shapes.get(oid)))
    for index, row in enumerate(volumes.rows[:known_volume_count]):
        lo, hi = np.asarray(row['bounds'])
        if region.intersects(shapely.box(*lo[:2], *hi[:2])):
            obligations.append((f'volume-{index}', dict(sourceCollision=row['id']), [index]))
    dependencies = [Path(__file__), Path(__file__).with_name('checkpoint_floor_measurements.py'),
        Path(__file__).with_name('polygonal_area.py'),
        Path(__file__).with_name('build_all_map_gameplay_supports.py'),
        Path(__file__).with_name('standing_complex_clearance.py'),
        Path(__file__).with_name('redundant_capsule_collision.py'),
        Path(__file__).with_name('native_capsule_collision.py'),
        Path(__file__).with_name('native_capsule_standing.py'),
        Path(__file__).with_name('gameplay_standing_volumes.py'),
        Path(__file__).with_name('audit_all_map_gameplay_levels.py')]
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in dependencies}
    archive = output/'algorithm-sources'
    archive.mkdir(exist_ok=True)
    for path in dependencies:
        target = archive/path.name
        if target.exists() and target.read_bytes() != path.read_bytes():
            raise ValueError('Choose a new source folder after changing measurement algorithms')
        target.write_bytes(path.read_bytes())
    for name in ['source-inventory.json', 'source-colliders.json', 'source-colliders.npz', 'collision-accounting.json']:
        hashes[name] = hashlib.sha256((output/name).read_bytes()).hexdigest()
    fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    measurements = checkpointed_measurements(obligations, measure_obligation,
        (volumes, known_volume_count, region, redundant, outside), output/'floor-checkpoints', fingerprint, workers)
    for measurement in measurements:
        rows.append(measurement['row'])
        domains.extend(measurement['domains'])
    result = dict(status='source-domain-measurement', sourceRows=rows, domains=domains,
        sourceInventorySha256=hashlib.sha256((output / 'source-inventory.json').read_bytes()).hexdigest(),
        algorithmSha256=algorithm_sha256,
        measurementInputsSha256=hashes, checkpointFingerprint=fingerprint,
        clearanceOverlayPrecisionMeters=CLEARANCE_PRECISION_METERS,
        unresolvedInfluencingCollision=pending,
        limitations=['Rounded capsule clipping is conservative near curved boundaries.',
                    'Native UE 5.3 defaults apply only to verified native mesh classes or exact actor roots beneath resolved serialized overrides.',
                    'This source-only phase does not establish runtime representation or wall correspondence.'])
    (output / 'regional-floors.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(counts=dict(Counter(r['status'] for r in rows)), domains=len(domains))), flush=True)


def measure_obligation(obligation, volumes, known_volume_count, region, redundant, outside=None):
    source_key, identity, indices = obligation
    if indices is None:
        return dict(row=dict(**identity, status='unresolved-collision'), domains=[])
    groups = defaultdict(list)
    for index in indices:
        lo, hi = volumes.rows[index]['bounds']
        if not region.buffer(.42).intersects(shapely.box(*lo[:2], *hi[:2])):
            continue
        if volumes.rows[index].get('analyticStandingExclusion') is not None:
            continue
        tri = volumes.triangles[index]
        normal = (volumes.equations[index][:, :3] if volumes.equations[index] is not None else
            np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]))
        lengths = np.linalg.norm(normal, axis=1)
        slope = walkable_slope_angle(volumes.rows[index])
        possible = (lengths > 1e-10) & (normal[:, 2] >= np.cos(np.deg2rad(slope)) * lengths)
        if volumes.rows[index]['unwalkable'] or volumes.rows[index]['kill'] or volumes.rows[index].get('collisionDefaultsUnknown'):
            possible[:] = False
        for face, triangle, plane in zip(np.flatnonzero(possible), tri[possible], planes(tri[possible])):
            # The rounded foot touches a slope away from the capsule axis.
            shift = -.42 * plane[:2] / np.sqrt(1 + plane[:2] @ plane[:2])
            domain = translate(shapely.Polygon(triangle[:, :2]), *shift).intersection(region)
            if domain.area < 1e-10:
                continue
            # Group near-coplanar source triangles, retaining their original
            # face identities. This precision is below the 2 cm height tolerance.
            plane_key = tuple(np.round(plane, 4))
            groups[plane_key].append((index, int(face), domain))
    kept, blocked_area, raw_area = [], 0., 0.
    for plane, entries in groups.items():
        domain = merge_floor_faces([e[2] for e in entries])
        raw_area += domain.area
        known = standing_obstacles(volumes, domain, plane[2], floor_plane=plane,
            ignored=range(known_volume_count, len(volumes.rows)))
        clear = subtract_clearance(domain, known)
        if clear.area > 1e-10:
            # Include the supporting mesh itself: a lower face under its
            # upper sheet is not a usable player floor.
            all_obstacles = standing_obstacles(volumes, clear, plane[2], floor_plane=plane)
            clear = subtract_clearance(clear, all_obstacles)
        blocked_area += domain.area - clear.area
        if clear.area <= 1e-6:
            continue
        record = dict(id=f'{source_key}-{len(kept)}', **identity,
            sourceFaces=[[int(e[0]), int(e[1])] for e in entries], nativePlane=list(plane),
            nativeGeometry=json.loads(shapely.to_geojson(clear)), areaSquareMeters=clear.area)
        kept.append(record)
    row = dict(**identity,
        status='standing-domains-measured' if kept else 'no-clear-standing-domain',
        candidatePlaneGroups=len(groups), candidateAreaSquareMeters=raw_area,
        blockedAreaSquareMeters=blocked_area, standingAreaSquareMeters=sum(d['areaSquareMeters'] for d in kept),
        domains=len(kept))
    analytic_records = [dict(sourceCollision=volumes.rows[index]['id'],
        analyticCapsule=volumes.rows[index]['analyticCapsule'],
        standingExclusion=volumes.rows[index].get('analyticStandingExclusion'),
        standingApproximation=volumes.rows[index].get('standingApproximation'))
        for index in indices if volumes.rows[index].get('analyticCapsule') is not None]
    if analytic_records:
        row['analyticCapsuleEvidence'] = analytic_records
    if identity.get('sourceObject') in redundant:
        row['collisionContainment'] = redundant[identity['sourceObject']]
    if identity.get('sourceObject') in (outside or {}):
        row['collisionOutsideRegion'] = outside[identity['sourceObject']]
    return dict(row=row, domains=kept)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=OUT)
    parser.add_argument('--collisions-only', action='store_true')
    parser.add_argument('--all-colliders', action='store_true')
    parser.add_argument('--workers', type=int, default=1)
    args = parser.parse_args()
    build(args.output, args.collisions_only, args.all_colliders, args.workers)
