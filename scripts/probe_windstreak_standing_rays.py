"""Search frozen valid standing origins for audited Wind first-hit defects."""
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from audit_navigation_components import native_vertices
from audit_null_material_receiver_scope import source_receiver
from probe_source_floor_regressions import load_support, source_model, step_height


def main():
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    out = revision / 'windstreak-visibility-audit-v1'
    proof = json.loads((out / 'height-intersection-proof.json').read_text())
    support = load_support(revision, 'icebox')
    source = source_model(revision, 'icebox', True)
    nav = json.loads(gzip.decompress((revision / 'baseline-world/icebox_navigation.json.gz').read_bytes()))
    catalog = json.loads((revision / 'baseline-world/height_catalog.json').read_text())['maps']['icebox']
    detail = nav['floorMesh']
    vertices = native_vertices(detail['vertices'], detail['coordinateScale'], catalog['uiTransform'])
    triangles = np.asarray(detail['triangles']).reshape(-1, 4)
    valid = np.asarray(nav['walkable'])[triangles[:, 0]]
    centers = vertices[triangles[valid, 1:]].mean(axis=1)
    detail_ids = np.flatnonzero(valid)
    receiver = source_receiver(revision, 'icebox')
    wind_ids = {i for row in proof['rows'] for i in row['fullPackFaceIds']}
    results = []
    for row in proof['rows']:
        for crossing in row['crossingSupportPlanes']:
            index = crossing['supportIndex']
            coordinates = shapely.get_coordinates(shapely.from_geojson(crossing['intersection']).intersection(receiver))
            heights = coordinates @ support.planes[index, :2] + support.planes[index, 2] + 1.75
            low, high = int(heights.argmin()), int(heights.argmax())
            z = row['windHeightRangeMeters'][0]
            fraction = (z - heights[low]) / (heights[high] - heights[low])
            target_xy = coordinates[low] * (1 - fraction) + coordinates[high] * fraction
            nearest = np.argsort(np.linalg.norm(centers[:, :2] - target_xy, axis=1))[:12]
            for chosen in nearest:
                origin = centers[chosen] + [0, 0, 1.75]
                direction = target_xy - origin[:2]
                distance = float(np.linalg.norm(direction))
                if distance < 1e-6:
                    continue
                direction /= distance
                result = support.cast(source, origin, direction, distance + .5, True, True, True, step_height(revision, 'icebox', True), True)
                result.update(origin=origin.tolist(), detailedNavigationTriangle=int(detail_ids[chosen]), supportTargetIndex=index, targetXY=target_xy.tolist(), direction=direction.tolist(), requestedDistanceMeters=distance + .5)
                results.append(result)
            print(index, 'probes', len(results), 'Wind first hits', sum(r.get('hit') is not None and r['hit']['face'] in wind_ids for r in results), flush=True)
    report = {'scope': '12 nearest valid detailed-nav centroid standing origins for each of 8 exact painted support/Wind height crossings. Current bounded-step detached v6 source-following policy. Not exhaustive game validation.', 'sourceGeometrySha256': proof['sourceGeometrySha256'], 'fullHeightSourcePackSha256': proof['fullHeightSourcePackSha256'], 'cases': results}
    (out / 'standing-source-following-probes.json').write_text(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
