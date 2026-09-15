"""Measure remaining short SVG/source registration gaps without moving ink.

This second pass records the closest actual facade point and bounds the shift
to 1.5 source meters. It produces review candidates, never installed assets.
"""
import argparse
from functools import lru_cache
import json
from pathlib import Path
import shutil

import numpy as np
import shapely

from audit_all_map_gameplay_levels import MAPS, ROOT, read
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals, wall_stations
from audit_svg_source_height_associations import projected_distance
from compile_reviewed_svg_height_map import polygon
from resolve_local_svg_wall_profiles import OUTPUT, sha, source_role, source_eligible
from svg_review_source import source_world, verified_source_pack


def nearest_xy(triangle, point):
    if projected_distance(triangle[None], point)[0] < 1e-10:
        return point.copy()
    a = triangle[:, :2]
    edge = np.roll(a, -1, axis=0) - a
    t = np.sum((point - a) * edge, axis=1) / np.maximum(np.sum(edge * edge, axis=1), 1e-30)
    closest = a + np.clip(t, 0, 1)[:, None] * edge
    return closest[np.linalg.norm(closest - point, axis=1).argmin()]


def refine(name, output=OUTPUT):
    directory = output / name
    path = directory / 'local-source-profiles.json'
    profiles = read(path)
    if not any(s['status'].startswith('needs') for w in profiles['records'] for s in w['stations']):
        print(name, 'no unresolved local measurements', flush=True)
        return
    original_hash = sha(path)
    backup = directory / f'profiles-before-refinement-{original_hash[:12]}.json'
    if not backup.exists():
        shutil.copyfile(path, backup)
    inventory = {w['wallId']: w for w in read(directory / 'assumed-height-review.json')['records']}
    model = read(directory / 'seed-attack.json.gz')
    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    source = source_world(name)
    metadata = read(source / 'geometry.json')['objects']
    with np.load(source / 'geometry.npz') as archive:
        points, faces = archive['points'], archive['faces']
    retained = verified_source_pack(name)['retained']
    eligible = [i for i, o in enumerate(metadata) if o['faceCount'] and source_eligible(o['path'])]
    bounds = np.array([metadata[i]['boundsMeters'] for i in eligible])
    tree = shapely.STRtree(shapely.box(bounds[:, 0, 0], bounds[:, 0, 1], bounds[:, 1, 0], bounds[:, 1, 1]))
    matrix = np.array(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])

    @lru_cache(maxsize=128)
    def geometry(oid):
        o = metadata[oid]
        ids = np.arange(o['firstFace'], o['firstFace'] + o['faceCount'])
        ids = ids[retained[ids]]
        tri = points[faces[ids]].astype(float)
        n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        n /= np.maximum(np.linalg.norm(n, axis=1)[:, None], 1e-30)
        return ids, tri, n

    def local_sections(center, tangent, half_cross=.85, half_along=.15):
        result = []
        radius = half_cross + half_along
        for index in tree.query(shapely.box(*(center - radius), *(center + radius))):
            oid = eligible[index]
            ids, tri, _ = geometry(oid)
            lo, hi = tri[:, :, :2].min(1), tri[:, :, :2].max(1)
            nearby = np.flatnonzero((lo <= center + radius).all(1) & (hi >= center - radius).all(1))
            selected, bands = clipped_height_intervals(tri[nearby], center, tangent, half_along,
                                                       half_cross, include_flat=True)
            if len(selected):
                result.append(dict(object=oid, role=source_role(metadata[oid]['path']),
                                   faces=ids[nearby[selected]].tolist(), bands=merge_intervals(bands)))
        return result

    changes = []
    for wall in profiles['records']:
        tangents = list(wall_stations(inventory[wall['wallId']]))
        for index, sample in enumerate(wall['stations']):
            if not sample['status'].startswith('needs'):
                continue
            center = np.array(sample['native'])
            tangent = inverse @ tangents[index][3]
            tangent /= np.linalg.norm(tangent)
            normal = np.array([-tangent[1], tangent[0]])
            floor = sample['floorElevationMeters']
            local = local_sections(center, tangent)
            body = [s for s in local if s['role'] != 'overhead']
            # Thin seats, curbs and ground-facing edges still have an exact
            # local top, even where their end contains no upright facade.
            if body and receiver.boundary.distance(shapely.Point(sample['associationSvg'])) <= 1.:
                top = max(hi for s in body for lo, hi in s['bands'])
                if top < floor + model['defaultCameraHeightMeters'] - .05:
                    sample.update(status='measured-ground-boundary', sourceRole='measured-low-boundary',
                        sourceComponents=body, sourceObjects=[s['object'] for s in body],
                        sourceFaces=[f for s in body for f in s['faces']],
                        sourceBands=merge_intervals([b for s in body for b in s['bands']]),
                        measuredTopMeters=top, measuredBottomMeters=min(lo for s in body for lo, hi in s['bands']),
                        associationMethod='local-low-boundary-section')
                    changes.append(dict(wallId=wall['wallId'], station=index, method=sample['associationMethod']))
                    continue
            known_objects = set()
            for other in wall['stations']:
                if (other['status'] == 'measured-facade'
                        and np.linalg.norm(np.array(other['associationSvg']) - sample['associationSvg']) <= 3.):
                    known_objects.update(s['object'] for s in other.get('sourceComponents', []))
            candidates = []
            for source_index in tree.query(shapely.box(*(center - 1.5), *(center + 1.5))):
                oid = eligible[source_index]
                if source_role(metadata[oid]['path']) != 'structure':
                    continue
                # A floating fragment needs a local association to an already
                # measured part of this same authored wall.
                if metadata[oid]['boundsMeters'][0][2] > floor + .5 and oid not in known_objects:
                    continue
                ids, tri, normals = geometry(oid)
                take = ((abs(normals[:, 2]) < .75) & (abs(normals[:, :2] @ normal) > .4)
                        & (tri[:, :, 2].max(1) > floor + .05))
                indices = np.flatnonzero(take)
                if not len(indices):
                    continue
                distances = projected_distance(tri[indices], center)
                for j in np.flatnonzero(distances <= 1.5):
                    k = indices[j]
                    candidates.append((float(distances[j]), oid, int(ids[k]), nearest_xy(tri[k], center)))
            if not candidates:
                continue
            distance, oid, face, measured_center = min(candidates, key=lambda r: (r[0], r[1], r[2]))
            sections = local_sections(measured_center, tangent, .45)
            body = [s for s in sections if s['object'] == oid]
            if not body:
                continue
            bands = merge_intervals([b for s in body for b in s['bands']])
            pending = [s for s in sections if s not in body]
            changed = True
            while changed:
                changed = False
                for section in list(pending):
                    if any(lo <= b + .08 and hi >= a - .08 for lo, hi in section['bands'] for a, b in bands):
                        body.append(section)
                        pending.remove(section)
                        bands = merge_intervals([*bands, *section['bands']])
                        changed = True
            sample.update(status='measured-facade', sourceObject=oid, sourcePath=metadata[oid]['path'],
                sourceRole='structure', sourceComponents=body, sourceFaces=[f for s in body for f in s['faces']],
                sourceBands=bands, measuredTopMeters=max(hi for lo, hi in bands),
                measuredBottomMeters=min(lo for lo, hi in bands), registrationDistanceMeters=distance,
                associationMethod='bounded-source-registration', measurementNative=measured_center.tolist(),
                registrationSourceFace=face)
            changes.append(dict(wallId=wall['wallId'], station=index, method=sample['associationMethod'],
                                sourceObject=oid, registrationMeters=distance))
        wall['unresolvedStations'] = sum(s['status'].startswith('needs') for s in wall['stations'])
    profiles.setdefault('refinements', []).append(dict(algorithmSha256=sha(Path(__file__)),
        inputProfilesSha256=original_hash, inputProfilesFile=backup.name, changes=changes))
    path.write_text(json.dumps(profiles, separators=(',', ':')))
    print(name, 'refined', len(changes), 'remaining', sum(w['unresolvedStations'] for w in profiles['records']), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    for name in args.maps:
        refine(name, args.output)
