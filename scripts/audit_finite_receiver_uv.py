"""Verify finite-receiver homographies against frozen masked source triangles."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from native_reference_cast import NativeReferenceModel
from finite_receiver_shadows import Receiver
from finite_receiver_uv import build_projective_uv
from probe_real_receiver_room_controls import sha
from world_visibility_ray_reference import ray_triangle, sample_alpha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--diagnostic-expanded-footprint', action='store_true',
                        help='Use the source plane over an unverified100m square to stress actual masked materials')
    args = parser.parse_args()
    out = args.output; out.mkdir(parents=True, exist_ok=False)
    report_path = args.fixtures/'report.json'
    source = json.loads(report_path.read_bytes())
    pack = args.revision/'split-complete-control-original-height-v29-v2/split.height.bin.gz'
    assert sha(pack) == source['completePackSha256']
    model = NativeReferenceModel(pack, args.revision/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    rng = np.random.default_rng(814263)
    records, textures = [], {}
    for fixture in source['records']:
        path = args.fixtures/(fixture['id']+'.npz')
        with np.load(path) as data:
            eye = data['observer']; receiver = Receiver(data['receiverFootprint'], data['receiverPlane'])
            face_ids = data['sourceFaceIds'][data['faceMasks'] >= 0]
        if args.diagnostic_expanded_footprint:
            receiver = Receiver(eye[:2]+np.array([[-50., -50.], [50., -50.], [50., 50.], [-50., 50.]]), receiver.floor_plane)
        for face in face_ids:
            mask = int(model.arrays['faceMasks'][face])
            assert mask >= 0
            tri = model.arrays['vertices'][model.arrays['faces'][face]]
            uv = model.arrays['maskedUvs'][mask]
            material_id = int(model.arrays['maskedMaterials'][mask])
            policy = model.materials[material_id]
            texture_id = policy['texture']; texture = model.textures[texture_id]
            textures[str(texture_id)] = dict(shape=list(texture.shape), frozenAlphaUint8Sha256=hashlib.sha256(np.rint(texture*255).astype(np.uint8).tobytes()).hexdigest(), bytes=texture.size)
            mapping, polygon, reason = build_projective_uv(eye, tri, uv, receiver)
            row = dict(fixture=fixture['id'], fixtureSha256=sha(path), sourceFace=int(face), mask=mask,
                       material=material_id, policy=policy, texture=texture_id, sourceUV=uv.tolist(),
                       status='fallback' if reason else 'empty-candidate' if mapping is None else 'projective-candidate', reason=reason,
                       receiverDomain='unverified-expanded-plane-material-stress' if args.diagnostic_expanded_footprint else 'frozen-receiver-footprint')
            if mapping is None:
                records.append(row); continue
            row['homography'] = mapping.coefficients.tolist(); row['eyeXY'] = mapping.eye_xy.tolist()
            row['candidatePolygon'] = polygon.tolist()
            center = polygon.mean(0)
            samples = [center]
            for i in range(len(polygon)):
                corner, next_corner = polygon[i], polygon[(i+1) % len(polygon)]
                for weights in rng.dirichlet([2, 2, 2], 24):
                    samples.append(weights@np.array([center, corner, next_corner]))
            checks = []
            max_uv, max_alpha, max_uv32, max_alpha32 = 0., 0., 0., 0.
            for xy in samples:
                target = receiver.lift(xy)
                delta = target-eye; length = np.linalg.norm(delta)
                hit = ray_triangle(eye, delta/length, tri)
                if hit is None or hit[0] > length+1e-8:
                    checks.append(dict(xy=xy.tolist(), reason='independent-ray-misses-candidate-triangle'))
                    continue
                distance, bary = hit
                expected_uv = np.array(bary)@uv
                expected_alpha = sample_alpha(texture, expected_uv, policy)
                actual_uv, fallback = mapping.evaluate(xy)
                if fallback:
                    checks.append(dict(xy=xy.tolist(), reason=fallback)); continue
                actual_alpha = sample_alpha(texture, actual_uv, policy)
                scene_hit = model.cast(eye, target)
                uerr = float(np.max(abs(expected_uv-actual_uv))); aerr = abs(expected_alpha-actual_alpha)
                max_uv, max_alpha = max(max_uv,uerr), max(max_alpha,aerr)
                uv32, reason32 = mapping.evaluate(xy, coefficient_dtype=np.float32)
                alpha32 = None if reason32 else sample_alpha(texture, uv32, policy)
                if alpha32 is not None:
                    max_uv32 = max(max_uv32, float(np.max(abs(expected_uv-uv32))))
                    max_alpha32 = max(max_alpha32, abs(expected_alpha-alpha32))
                threshold = policy['threshold']
                checks.append(dict(xy=xy.tolist(), sourceRayBarycentric=list(bary), sourceDistance=distance,
                                   expectedUV=expected_uv.tolist(), expectedAlpha=expected_alpha,
                                   fullSceneFirstHit=scene_hit,
                                   fullSceneHitMinusMaskedFaceMeters=None if scene_hit is None else scene_hit['distanceMeters']-distance,
                                   projectedUV=actual_uv.tolist(), projectedAlpha=actual_alpha,
                                   classificationDifference=(expected_alpha>=threshold)!=(actual_alpha>=threshold),
                                   distanceToThreshold=abs(expected_alpha-threshold),
                                   float32CoefficientFallback=reason32,
                                   float32CoefficientClassificationDifference=None if alpha32 is None else (expected_alpha>=threshold)!=(alpha32>=threshold)))
            row.update(samples=checks, maximumUVError=max_uv, maximumAlphaError=max_alpha,
                       maximumFloat32CoefficientUVError=max_uv32, maximumFloat32CoefficientAlphaError=max_alpha32)
            records.append(row)
    tested = [x for x in records if x['status'] == 'projective-candidate']
    checks = [v for x in tested for v in x['samples']]
    report = dict(scope=__doc__, fixtureReportSha256=sha(report_path), completePackSha256=sha(pack),
                  scriptSha256=sha(Path(__file__)), projectionSha256=sha(Path(__file__).with_name('finite_receiver_uv.py')),
                  textures=textures, records=records,
                  summary=dict(maskedReceiverFacePairs=len(records), projectiveCandidates=len(tested),
                               emptyCandidates=sum(x['status']=='empty-candidate' for x in records),
                               explicitFallbackPairs=sum(x['status']=='fallback' for x in records),
                               sampledRays=len(checks), sampleFallbacks=sum('reason' in x for x in checks),
                               opaqueSamples=sum(x.get('expectedAlpha',-1) >= row['policy']['threshold'] for row in tested for x in row['samples']),
                               transparentSamples=sum(x.get('expectedAlpha',1) < row['policy']['threshold'] for row in tested for x in row['samples']),
                               transparentSamplesStillOpaqueBlocked=sum(x.get('expectedAlpha',1) < row['policy']['threshold'] and x.get('fullSceneFirstHit') is not None and not x['fullSceneFirstHit']['masked'] for row in tested for x in row['samples']),
                               doubleClassificationDifferences=sum(x.get('classificationDifference',False) for x in checks),
                               float32CoefficientClassificationDifferences=sum(bool(x.get('float32CoefficientClassificationDifference')) for x in checks),
                               maximumUVError=max((x['maximumUVError'] for x in tested),default=0),
                               maximumAlphaError=max((x['maximumAlphaError'] for x in tested),default=0),
                               maximumFloat32CoefficientUVError=max((x['maximumFloat32CoefficientUVError'] for x in tested),default=0),
                               maximumFloat32CoefficientAlphaError=max((x['maximumFloat32CoefficientAlphaError'] for x in tested),default=0),
                               coefficientBytesFloat64=len(tested)*9*8,
                               sharedTextureBytes=sum(x['bytes'] for x in textures.values())),
                  limitations=['Opaque and other masked blockers still combine by union; one transparent face cannot clear a coincident opaque face.',
                               'When expanded-domain mode is enabled, source planes are extrapolated for material stress only; those targets are not verified floor positions or frozen cone/range coverage.',
                               'Textures, wrapping, bias, scale and threshold are the frozen source sampler policy, not arbitrary animated game shaders.',
                               'Float32 test quantizes coefficients only; it does not emulate a GPU shader evaluation or prove a threshold error bound.',
                               'Degenerate, coplanar and unrepresentable candidate polygons remain explicit source fallback.',
                               'This is bounded source-face UV verification, not a complete receiver-layer or visibility rendering implementation.'])
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['summary'],indent=2))
    if report['summary']['doubleClassificationDifferences'] or report['summary']['sampleFallbacks']:
        raise AssertionError('Projective UV disagrees with an independent source-ray sample')


if __name__ == '__main__':
    main()
