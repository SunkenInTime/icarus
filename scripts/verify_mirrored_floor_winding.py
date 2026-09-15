"""Check authored triangle winding for demonstrated mirrored floor changes.

Requires usd-core. Correspondence audits permit vertex permutation, so their
placement determinants alone cannot establish an NPZ triangle's facing.
"""
import argparse
import json
from pathlib import Path

import numpy as np

from repair_world_material_bindings import correspondence_error
from seal_world_plane_manifest import digest


def verify(world, orientation_path, comparison_path, binding_path, output):
    from pxr import Usd, UsdGeom
    world, orientation_path, comparison_path, binding_path, output = map(Path,
        (world, orientation_path, comparison_path, binding_path, output))
    comparison = json.loads(comparison_path.read_bytes())
    orientation = json.loads(orientation_path.read_bytes())
    binding = json.loads(binding_path.read_bytes())
    metadata = json.loads((world / 'geometry.json').read_bytes())
    if (digest(world / 'geometry.npz') != comparison['source']['geometrySha256']
            or digest(orientation_path) != comparison['source']['orientationAuditSha256']
            or digest(binding['source']) != binding['sourceSha256']
            or binding['sourceSha256'] != orientation['sourceUsdSha256']):
        raise ValueError('Winding inputs differ from the measured source geometry.')
    stage = Usd.Stage.Open(binding['source'])
    cache = UsdGeom.XformCache()
    raw = np.load(world / 'geometry.npz')
    points, faces = raw['points'], raw['faces']
    groups = {}
    ordered_placements = sorted(orientation['placements'], key=lambda row: row['firstFace'])
    starts = np.asarray([row['firstFace'] for row in ordered_placements])
    for example in comparison['examples']:
        face = example['sourceFace']
        index = int(np.searchsorted(starts, face, side='right') - 1)
        placement = ordered_placements[index]
        if not placement['firstFace'] <= face < placement['firstFace'] + placement['faceCount']:
            raise ValueError('Affected face is outside its verified placement range.')
        groups.setdefault(index, set()).add(face)
    records = []
    for placement_index, selected in groups.items():
        placement = ordered_placements[placement_index]
        name = placement['path']
        source_path = placement['sourcePrim']
        prim = stage.GetPrimAtPath(source_path)
        mesh = UsdGeom.Mesh(prim)
        authored_orientation = mesh.GetOrientationAttr().Get()
        if authored_orientation not in ('rightHanded', 'leftHanded'):
            raise ValueError('Unknown authored USD mesh orientation.')
        vertices = np.asarray(mesh.GetPointsAttr().Get(), dtype=float)
        indices = np.asarray(mesh.GetFaceVertexIndicesAttr().Get(), dtype=int).reshape(-1, 3)
        if '/Prototypes/' in source_path:
            instancer = UsdGeom.PointInstancer(stage.GetPrimAtPath(source_path.split('/Prototypes/')[0]))
            parent = np.asarray(cache.GetLocalToWorldTransform(instancer.GetPrim()))
            transform = np.asarray(instancer.ComputeInstanceTransformsAtTime(
                Usd.TimeCode.Default(), Usd.TimeCode.Default())[placement['sourceInstance']]) @ parent
        else:
            transform = np.asarray(cache.GetLocalToWorldTransform(prim))
        determinant = float(np.linalg.det(transform[:3, :3]))
        if not np.isclose(determinant, placement['placementDeterminant'], rtol=1e-12, atol=1e-12):
            raise ValueError('Authored instance transform differs from the orientation audit.')
        selected = np.asarray(sorted(selected), dtype=int)
        local = vertices[indices[selected - placement['firstFace']]]
        expected = (local @ transform[:3, :3] + transform[3, :3]) * .01
        actual = points[faces[selected]].astype(float)
        error = correspondence_error(expected, actual)
        if error > placement['coordinateToleranceMeters']:
            raise ValueError('Affected floor triangles differ from their authored source.')
        actual_cross = np.cross(actual[:, 1] - actual[:, 0], actual[:, 2] - actual[:, 0])
        expected_cross = np.cross(expected[:, 1] - expected[:, 0], expected[:, 2] - expected[:, 0])
        authored_cross = np.cross(local[:, 1] - local[:, 0], local[:, 2] - local[:, 0]) @ np.linalg.inv(transform[:3, :3]).T
        if authored_orientation == 'leftHanded':
            authored_cross *= -1
        for value in (actual_cross, expected_cross, authored_cross):
            value /= np.linalg.norm(value, axis=1)[:, None]
        winding_dot = np.einsum('ij,ij->i', actual_cross, expected_cross)
        corrected_dot = np.einsum('ij,ij->i', actual_cross * np.sign(determinant), authored_cross)
        records.append({'object': name, 'sourcePrim': source_path, 'sourceInstance': placement['sourceInstance'],
            'authoredOrientation': authored_orientation,
            'placementDeterminant': determinant, 'coordinateErrorMeters': error,
            'faces': [{'sourceFace': int(face), 'actualCrossZ': float(actual_cross[i, 2]),
                       'authoredFacingZ': float(authored_cross[i, 2]),
                       'actualVersusTransformedWindingDot': float(winding_dot[i]),
                       'determinantCorrectedVersusAuthoredFacingDot': float(corrected_dot[i]),
                       'floorEligibilityMatchesAuthoredFacing': bool(
                           (actual_cross[i, 2] * np.sign(determinant) > .65) == (authored_cross[i, 2] > .65))}
                      for i, face in enumerate(selected)]})
    all_faces = [face for row in records for face in row['faces']]
    result = {'schemaVersion': 1, 'map': metadata['map'], 'status': 'affected-source-winding-checked',
        'source': {'geometrySha256': metadata['geometrySha256'], 'comparisonSha256': digest(comparison_path),
                   'orientationAuditSha256': digest(orientation_path), 'usdSha256': binding['sourceSha256'],
                   'scriptSha256': digest(__file__)},
        'summary': {'objects': len(records), 'affectedSourceFacesChecked': len(all_faces),
                    'windingMatches': sum(face['actualVersusTransformedWindingDot'] > .999999 for face in all_faces),
                    'windingSignMatches': sum(face['actualVersusTransformedWindingDot'] > 0 for face in all_faces),
                    'floorEligibilityMatchesAuthoredFacing': sum(face['floorEligibilityMatchesAuthoredFacing'] for face in all_faces),
                    'determinantCorrectionMatchesAuthoredFacing': sum(
                        face['determinantCorrectedVersusAuthoredFacingDot'] > .999999 for face in all_faces)},
        'objects': records}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, allow_nan=False), encoding='utf-8')
    print(json.dumps({'map': metadata['map'], **result['summary']}), flush=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('world', type=Path)
    parser.add_argument('orientation', type=Path)
    parser.add_argument('comparison', type=Path)
    parser.add_argument('binding', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    verify(args.world, args.orientation, args.comparison, args.binding, args.output)
