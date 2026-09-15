"""Bounded explicit terrain-role experiment; no automatic asset classification."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from probe_source_floor_regressions import load_support, source_model


def run(revision, continuity=False):
    name = 'fracture'
    support = load_support(revision, name, True)
    source = source_model(revision, name, True)
    object_path = 'Canyon_Asite/Shell_3_AsiteRampToPlatform/StaticMeshComponent0.146'
    ids = np.array([int(face) for face, path in zip(support.source_ids, support.objects)
                    if path == object_path and face >= 0], dtype=int)
    assert len(ids), 'Audited stair object absent from frozen support'
    triangles = source.arrays['vertices'][source.arrays['faces'][ids]]
    normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    normal_z = normals[:, 2] / np.linalg.norm(normals, axis=1)
    steep = ids[normal_z < .65]
    ids = ids[normal_z >= .65]
    correspondence = np.load(revision / 'full-height-input-v1/fracture/source-correspondence.npz')['sourceFaces']
    originals = correspondence[ids]
    assert np.all((originals >= 1759474) & (originals < 1759474 + 358))
    support_path = revision / 'source-floor-support-all-walkable-v1/fracture.floor-support.npz'
    output = revision / 'source-floor-audited-terrain-v3'
    output.mkdir(exist_ok=True)
    manifest = dict(version=1, map=name, status='bounded-audited-role-experiment',
                    role='structural-terrain', objectPath=object_path,
                    nativeMesh='/Game/Environment/Canyon/Asset/Props/Shell/3/Shell_3_AsiteRampToPlatform.2',
                    evidence='Source-backed stair treads and rising navigation transition at the frozen south portal. Role is an explicit bounded audit decision, not inferred from Props package naming or collision flags.',
                    supportSha256=hashlib.sha256(support_path.read_bytes()).hexdigest(),
                    entryLocalReference=True, minimumUpwardNormalZ=.65,
                    originalFootprintsHavePriority=True,
                    steepAssemblyFacesNotRoleEnabled=steep.tolist(),
                    fullPackFaceIds=ids.tolist(), originalSourceFaceIds=originals.tolist())
    (output / 'fracture.terrain-role.json').write_text(json.dumps(manifest, indent=2) + '\n')
    cases = []
    if continuity:
        origins = [('south', [73.48316666666666, -40.82916666666667, 7.2501]),
                   ('north', [104.90183333333333, 39.62116666666666, 6.75]),
                   ('lower', [85.5614583333, 29.125, 2.7262669]),
                   ('upper', [85.5614583333, 29.125, 7.25])]
        for label, base in origins:
            samples = []
            for offset in [0, .01, -.01]:
                for angle in range(360):
                    origin = np.array(base) + [offset, 0, 0]
                    direction = [np.cos(np.deg2rad(angle)), np.sin(np.deg2rad(angle))]
                    result = support.cast(source, origin, direction, 65, True, True, True, .35, True,
                                          terrain_source_faces=ids)
                    result.update(origin=origin.tolist(), angleRadians=float(np.deg2rad(angle)), offset=[offset, 0])
                    samples.append(result)
                print(label, offset, 'complete', flush=True)
            cases.append(dict(id=label, samples=samples))
            (output / 'fracture-continuity.json').write_text(json.dumps(dict(scope=__doc__, cases=cases), indent=2) + '\n')
        return
    for angle in [291, 295, 297]:
        samples = []
        for offset in [0, .01, -.01]:
            origin = np.array([73.48316666666666 + offset, -40.82916666666667, 7.2501])
            direction = [np.cos(np.deg2rad(angle)), np.sin(np.deg2rad(angle))]
            result = support.cast(source, origin, direction, 65, True, True, True, .35, True,
                                  terrain_source_faces=ids)
            result.update(origin=origin.tolist(), offset=offset)
            samples.append(result)
        cases.append(dict(angleDegrees=angle, samples=samples,
                          maximumDistanceDifferenceMeters=max(s['distanceMeters'] for s in samples) - min(s['distanceMeters'] for s in samples)))
        print(angle, [round(s['distanceMeters'], 9) for s in samples], flush=True)
    (output / 'fracture-south-regressions.json').write_text(json.dumps(dict(scope=__doc__, cases=cases), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('--continuity', action='store_true')
    args = parser.parse_args()
    run(args.revision, args.continuity)
