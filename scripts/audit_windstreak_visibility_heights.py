"""Bound Wind effect visibility against standing and source-following heights."""
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import load_support
from audit_null_material_receiver_scope import source_receiver


def main():
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    support = load_support(revision, 'icebox')
    receiver = source_receiver(revision, 'icebox')
    evidence = json.loads((revision / 'floor-support-audited-exclusions-v2/icebox.json').read_text())
    raw = np.load(revision.parent / 'supplemented-v2/world/icebox/geometry.npz')
    rows = []
    for record in evidence['rows']:
        if not record['fullPackFaceIds']:
            continue
        triangles = raw['points'][raw['faces'][record['originalSourceFaceIds']]]
        effect = shapely.union_all(shapely.polygons(triangles[:, :, :2]))
        wind_z = [float(triangles[:, :, 2].min()), float(triangles[:, :, 2].max())]
        support_ids = support.tree.query(effect, predicate='intersects')
        minimum = None
        crossings = []
        for index in support_ids:
            intersection = effect.intersection(support.polygons[index])
            coordinates = shapely.get_coordinates(intersection)
            if len(coordinates) == 0:
                continue
            eyes = coordinates @ support.planes[index, :2] + support.planes[index, 2] + 1.75
            low, high = float(eyes.min()), float(eyes.max())
            if minimum is None or low < minimum['eyeMeters']:
                minimum = {'eyeMeters': low, 'supportIndex': int(index), 'sourceFace': int(support.source_ids[index]), 'object': support.objects[index], 'xy': coordinates[eyes.argmin()].tolist()}
            if low <= wind_z[1] and high >= wind_z[0]:
                painted = intersection.intersection(receiver)
                painted_xy = shapely.get_coordinates(painted)
                painted_eye = painted_xy @ support.planes[index, :2] + support.planes[index, 2] + 1.75
                painted_range = [float(painted_eye.min()), float(painted_eye.max())] if len(painted_eye) else None
                crossings.append({'supportIndex': int(index), 'sourceFace': int(support.source_ids[index]), 'object': support.objects[index], 'eyeRangeMeters': [low, high], 'intersection': shapely.to_geojson(intersection), 'receiverOverlapAreaMeters2': float(painted.area), 'paintedEyeRangeMeters': painted_range, 'paintedCrossingPossible': painted_range is not None and painted_range[0] <= wind_z[1] and painted_range[1] >= wind_z[0]})
        row = {'object': record['sourceObjectPath'], 'fullPackFaceIds': record['fullPackFaceIds'], 'windHeightRangeMeters': wind_z, 'supportIntersections': len(support_ids), 'minimumSupportedEye': minimum, 'crossingSupportPlanes': crossings}
        rows.append(row)
        print(record['sourceObjectPath'], minimum, 'crossings', len(crossings), flush=True)
    floor = json.loads((revision.parent / 'supplemented-v2/world/icebox/floor-mesh.json').read_text())['floorMesh']
    z = np.asarray(floor['vertices']).reshape(-1, 3)[:, 2] / 100
    report = {'sourceGeometrySha256': evidence['sourceGeometrySha256'], 'fullHeightSourcePackSha256': evidence['fullHeightSourcePackSha256'], 'supportFileSha256': hashlib.sha256((revision / 'source-floor-support-union-v6/icebox.floor-support.npz').read_bytes()).hexdigest(), 'standingCameraHeightMeters': 1.75, 'detailedNavigationStandingEyeRangeMeters': [float(z.min() + 1.75), float(z.max() + 1.75)], 'scope': 'Exact horizontal Wind planes versus all detailed navigation heights and every intersecting buffered source-support plane. No gameplay ray claimed where heights cannot meet.', 'rows': rows}
    out = revision / 'windstreak-visibility-audit-v1'
    out.mkdir(exist_ok=True)
    (out / 'height-intersection-proof.json').write_text(json.dumps(report, indent=2))
    snowman_path = Path('E:/IcarusWorldAudit/2026-09-04/all-worlds-13.05/Port/Exports/ShooterGame/Content/Environment/Asset/Props/Snowman/0/M0/Snowman_0_M0_PreRound_MI.json')
    snowman = json.loads(snowman_path.read_text())['Parameters']
    assert snowman['IsNull'] is False and snowman['BlendMode'] == 0
    decision = {
        'schemaVersion': 1,
        'map': 'icebox',
        'productionMutation': False,
        'sourceGeometrySha256': evidence['sourceGeometrySha256'],
        'fullHeightSourcePackSha256': evidence['fullHeightSourcePackSha256'],
        'windDecision': 'Exclude the exact 24 retained Wind effect faces from structural visibility and standing support in the final bake. Preserve original full-pack face IDs until bound floor references are regenerated.',
        'basis': 'Each placed StaticMesh component inherits the verified WindStreaks_BP NoCollision template and assigns a MID whose exact native parent is WindStreaks_Inst. That parent explicitly uses BLEND_TranslucentGreyTransmittance and MSM_Unlit, with Global Opacity 0.5 and scrolling noise inputs. These are decorative effects, not opaque structural blockers. Effective per-pixel opacity is shader-dependent; 0.5 is not asserted as final pixel alpha.',
        'confirmedDefect': 'The exported placed MID Parameters.IsNull=true placeholder was classified opaque blend0. All 24 full-height faces have faceMask -1, so the visibility pack would treat an intersecting ray as opaque.',
        'heightProof': 'Every retained Wind face is horizontal, max Z1.290010929m. Minimum detailed-nav standing eye1.7387m at the adopted1.75m eye height. Thus no horizontal standing ray from these nav floors can intersect Wind.',
        'sourceFollowingScope': 'Eight source-support/effect height crossings exist on dock catch slopes, including authored receiver overlap. A separate96-ray probe from valid detailed-nav centroids found no Wind first hit. This bounded search does not prove absence of all source-following failures.',
        'windFullPackFaceIds': sorted(i for row in evidence['rows'] for i in row['fullPackFaceIds']),
        'snowmanDecision': 'Keep current visibility; retain support-only exclusion. NoCollision does not imply visually transparent. Snowman is an opaque non-null material export with diffuse/normals and snow physical material. Dynamic round state remains outside this audit.',
        'snowmanMaterialEvidence': {'path': str(snowman_path), 'sha256': hashlib.sha256(snowman_path.read_bytes()).hexdigest(), 'parameters': snowman},
        'nativeEvidence': evidence['evidence'],
        'scopeWarning': 'A blocker outside the SVG painted receiver may still matter to a physical ray crossing an unpainted gap and re-entering. Receiver overlap only prioritizes investigation; it is not an exclusion rule.'
    }
    (out / 'recommendation.json').write_text(json.dumps(decision, indent=2))


if __name__ == '__main__':
    main()
