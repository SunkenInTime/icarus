"""Account for every focused wall-drop family against its complete primary mesh.

No cell-count, majority-height, or source-name gate removes a family. This is a
read-only geometric inventory, not a gameplay verdict or a wall-height patch.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_wall_height_drops import ROOT, read, sha


def projected_union(triangles):
    parts = [shapely.make_valid(shapely.Polygon(t[:, :2])) for t in triangles]
    return shapely.union_all(parts) if parts else shapely.GeometryCollection()


def eye_segments(triangles, eye):
    lines = []
    for tri in triangles:
        points = []
        for a, b in zip(tri, np.roll(tri, -1, axis=0)):
            if abs(a[2] - eye) < 1e-8:
                points.append(a[:2])
            if (a[2] < eye < b[2]) or (b[2] < eye < a[2]):
                points.append(a[:2] + (b[:2] - a[:2]) * (eye - a[2]) / (b[2] - a[2]))
        if len(points) >= 2:
            lines.append(shapely.LineString(points))
        elif points:
            lines.append(shapely.Point(points[0]))
    return shapely.union_all(lines) if lines else shapely.GeometryCollection()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, default=Path('work/fracture-wall-review-2026-09-14/all-map-height-drops'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--camera-height', type=float, default=1.75)
    args = parser.parse_args()
    output = args.output or args.inventory / 'primary-source-accounting'
    output.mkdir(parents=True, exist_ok=True)
    summary_path = args.inventory / 'summary.json'
    summary = read(summary_path)
    families = summary['focusedSameSourcePlinthFamilies']
    prior_path = args.inventory / 'source-role-review/dispositions.json'
    prior = {(r['map'], r['sourceObject']): r for r in read(prior_path)['families']} if prior_path.exists() else {}
    other_prior_path = args.inventory.parent / 'source-other-family-review.json'
    if other_prior_path.exists():
        for decision in read(other_prior_path)['findings']:
            prior[(decision['map'], decision['sourceObject'])] = decision
    fracture_prior_path = Path('scripts/data/fracture-reported-walls-2026-09-14.json')
    if fracture_prior_path.exists():
        review = read(fracture_prior_path)
        corrections = [r for r in review['corrections'] if 5336 in r.get('sourceObjects', [])]
        if corrections:
            prior[('fracture', 5336)] = dict(disposition='reviewed-reactor-facade-correction',
                sourceReviewPath=str(fracture_prior_path), sourceReviewSha256=sha(fracture_prior_path), corrections=corrections)
    grouped = defaultdict(list)
    for family in families:
        grouped[family['map']].append(family)
    results = []
    for name, map_families in sorted(grouped.items()):
        report_path = args.inventory / f'{name}.json'
        report = read(report_path)
        lookup = {(c['side'], row['wallId']): row for c in report['candidates'] for row in c['lowWalls']}
        geometry_path = ROOT / f'supplemented-v2/world/{name}/geometry.npz'
        metadata_path = geometry_path.with_suffix('.json')
        metadata = read(metadata_path)
        geometry = np.load(geometry_path)
        points, faces = geometry['points'], geometry['faces']
        hashes = dict(geometry=sha(geometry_path), metadata=sha(metadata_path), inventory=sha(report_path))
        for family in map_families:
            oid = family['sourceObject']
            obj = metadata['objects'][oid]
            assert obj['path'] == family['sourcePath']
            first, end = obj['firstFace'], obj['firstFace'] + obj['faceCount']
            tri = points[faces[first:end]].astype(float)
            bounds = [tri.min(axis=(0, 1)).tolist(), tri.max(axis=(0, 1)).tolist()]
            top = bounds[1][2]
            low_rows = []
            identities = sorted({(e['side'], e['lowWallId']) for e in family['evidence']})
            for side, wall_id in identities:
                row = lookup[(side, wall_id)]
                source = row['nearestSource']
                assert source['sourceObject'] == oid
                cap = row['absoluteCapMeters']
                deficit = top - cap
                if abs(deficit) <= .1:
                    classification = 'matches-complete-primary-cap'
                elif deficit < -.1:
                    classification = 'cap-above-complete-primary'
                elif deficit <= args.camera_height:
                    classification = 'primary-higher-within-camera-height'
                else:
                    classification = 'primary-higher-by-more-than-camera'
                selected = sorted({int(i) for component in (source.get('sourceComponents') or [])
                                   if component['object'] == oid for i in component.get('faces', [])})
                assert all(first <= i < end for i in selected)
                entry = dict(side=side, wallId=wall_id, capMeters=cap,
                    primaryTopMinusCapMeters=deficit, classification=classification,
                    bands=row['bands'], floorElevationMeters=row['floorElevationMeters'],
                    nearestArchivedSource=source, selectedPrimaryFaceIds=selected)
                if deficit > args.camera_height:
                    floor = source.get('floorElevationMeters')
                    if floor is None:
                        entry['eyeMeasurementStatus'] = 'missing-archived-ground'
                    elif not selected:
                        entry['eyeMeasurementStatus'] = 'missing-selected-primary-faces'
                    else:
                        eye = floor + args.camera_height
                        crossing = np.flatnonzero((tri[:, :, 2].min(axis=1) <= eye)
                                                  & (tri[:, :, 2].max(axis=1) >= eye))
                        selected_shape = projected_union(points[faces[selected]])
                        spanning_shape = projected_union(tri[crossing])
                        section = eye_segments(tri[crossing], eye)
                        entry.update(eyeMeasurementStatus='measured', archivedStandingEyeMeters=eye,
                            eyeSpanningPrimaryFaceIds=(crossing + first).tolist(),
                            selectedFacesToSpanningTriangleProjectionDistanceMeters=None if spanning_shape.is_empty else selected_shape.distance(spanning_shape),
                            selectedFacesToExactEyeSectionDistanceMeters=None if section.is_empty else selected_shape.distance(section),
                            selectedPrimaryFaceBoundsMeters=[points[faces[selected]].min(axis=(0,1)).tolist(),points[faces[selected]].max(axis=(0,1)).tolist()])
                low_rows.append(entry)
            has_deficit = any(r['classification'] == 'primary-higher-by-more-than-camera' for r in low_rows)
            decision = prior.get((name, oid))
            side_counts = Counter(r['side'] for r in low_rows)
            distances = [r['selectedFacesToExactEyeSectionDistanceMeters'] for r in low_rows
                         if r.get('selectedFacesToExactEyeSectionDistanceMeters') is not None]
            result = dict(map=name, sourceObject=oid, sourcePath=obj['path'],
                completePrimaryFaceCount=len(tri), completePrimaryBoundsMeters=bounds,
                metadataBoundsMeters=obj['boundsMeters'], sourceSha256=hashes,
                lowWallCount=len(low_rows), singleLowWall=len(low_rows)==1,
                lowWallCountsBySide=dict(side_counts), oneLowWallPerSide=max(side_counts.values())==1,
                primaryTopMinusLowCapRangeMeters=[min(r['primaryTopMinusCapMeters'] for r in low_rows),max(r['primaryTopMinusCapMeters'] for r in low_rows)],
                selectedFaceToExactEyeSectionDistanceRangeMeters=[min(distances),max(distances)] if distances else None,
                geometryClassification='incomplete-primary-height-candidate' if has_deficit else 'no-large-primary-height-deficit',
                roleDisposition=decision['disposition'] if decision else 'unresolved-primary-plinth-review' if has_deficit else 'no-large-primary-plinth-deficit-other-errors-not-assessed',
                priorExactRoleDecision=decision, lowWalls=low_rows)
            (output / f'{name}-{oid}.json').write_text(json.dumps(result, indent=2) + '\n')
            results.append({k:v for k,v in result.items() if k not in ['lowWalls', 'priorExactRoleDecision']})
        print(json.dumps(dict(map=name, families=len(map_families))), flush=True)
        del geometry, points, faces
    assert len(results) == len(families)
    counts = Counter(r['roleDisposition'] for r in results)
    unresolved = [r for r in results if r['roleDisposition']=='unresolved-primary-plinth-review']
    output_summary = dict(status='all-focused-families-accounted', inputFamilies=len(families),
        accountedFamilies=len(results), algorithmSha256=sha(Path(__file__)),
        inputInventorySha256=sha(summary_path), priorDispositionsSha256=sha(prior_path) if prior_path.exists() else None,
        otherPriorReviewSha256=sha(other_prior_path) if other_prior_path.exists() else None,
        fracturePriorReviewSha256=sha(fracture_prior_path) if fracture_prior_path.exists() else None,
        roleDispositionCounts=dict(counts), unresolvedPrimaryPlinthFamilies=len(unresolved),
        singleLowWallUnresolvedFamilies=sum(r['singleLowWall'] for r in unresolved),
        oneLowWallPerSideUnresolvedFamilies=sum(r['oneLowWallPerSide'] for r in unresolved),
        families=results, unresolvedPrimaryPlinthQueue=unresolved,
        limitations=[
            'Complete primary height is measured from every face. A taller object elsewhere does not prove the local low wall is wrong.',
            'Eye height uses the nearest archived source station ground plus camera height. It is not a newly verified current standing support.',
            'Distances use complete selected primary faces, which can extend beyond the original sampling window. Exact eye-plane section distance is reported separately from full triangle projection distance.',
            'No count, majority-tall, or name heuristic dismisses a family. Single-wall deficits remain in the review queue.',
            'Existing exact role decisions are retained as overlays. No gameplay verdict follows from geometry alone.',
            'No map asset, standing floor, box domain, or source mesh is changed.'])
    (output/'summary.json').write_text(json.dumps(output_summary,indent=2)+'\n')
    print(json.dumps({k:output_summary[k] for k in ['inputFamilies','accountedFamilies','roleDispositionCounts','unresolvedPrimaryPlinthFamilies','singleLowWallUnresolvedFamilies']}))


if __name__ == '__main__':
    main()
