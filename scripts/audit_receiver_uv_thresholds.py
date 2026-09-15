"""Probe actual frozen alpha threshold crossings, retaining precision failures."""
import argparse
import json
from pathlib import Path
import numpy as np

from audit_tactical_target_rays import ReferenceModel
from finite_receiver_shadows import Receiver
from finite_receiver_uv import ProjectiveUV
from probe_real_receiver_room_controls import sha
from world_visibility_ray_reference import ray_triangle, sample_alpha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('stress_report', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    out = args.output; out.mkdir(parents=True, exist_ok=False)
    stress = json.loads(args.stress_report.read_bytes())
    pack = args.revision/'split-complete-control-original-height-v29-v2/split.height.bin.gz'
    assert sha(pack) == stress['completePackSha256']
    model = ReferenceModel(pack)
    fixtures = args.revision/'source-refined-nav-standing-controls-v2'
    results = []
    for row in stress['records']:
        if row['status'] != 'projective-candidate':
            continue
        policy = row['policy']; threshold = policy['threshold']
        opaque = [x for x in row['samples'] if x.get('expectedAlpha', -1) >= threshold]
        transparent = [x for x in row['samples'] if x.get('expectedAlpha', 1) < threshold]
        if not opaque or not transparent:
            continue
        with np.load(fixtures/(row['fixture']+'.npz')) as data:
            receiver = Receiver(data['receiverFootprint'], data['receiverPlane'])
            eye = data['observer']
        triangle = model.arrays['vertices'][model.arrays['faces'][row['sourceFace']]]
        source_uv = model.arrays['maskedUvs'][row['mask']]
        texture = model.textures[row['texture']]
        mapping = ProjectiveUV(np.array(row['eyeXY']), np.array(row['homography']))
        def sample(xy):
            target = receiver.lift(xy); direction = target-eye; direction /= np.linalg.norm(direction)
            hit = ray_triangle(eye, direction, triangle)
            if hit is None:
                raise AssertionError('Interior threshold chord lost actual source hit')
            expected_uv = np.array(hit[1])@source_uv
            expected = sample_alpha(texture, expected_uv, policy)
            uv, reason = mapping.evaluate(xy); uv32, reason32 = mapping.evaluate(xy, coefficient_dtype=np.float32)
            assert reason is None and reason32 is None
            actual, actual32 = sample_alpha(texture, uv, policy), sample_alpha(texture, uv32, policy)
            return dict(xy=xy.tolist(), expectedAlpha=expected, projectedAlpha=actual, quantizedCoefficientAlpha=actual32,
                        expectedOpaque=expected >= threshold, doubleDifference=(actual >= threshold)!=(expected >= threshold),
                        quantizedCoefficientDifference=(actual32 >= threshold)!=(expected >= threshold),
                        distanceToThreshold=abs(expected-threshold))
        low, high = np.array(transparent[0]['xy']), np.array(opaque[0]['xy'])
        # Freeze both sides of the actual source sampler's crossing, rather
        # than inventing a threshold based on the tested homography itself.
        for _ in range(55):
            mid = (low+high)*.5
            if np.array_equal(mid, low) or np.array_equal(mid, high):
                break
            if sample(mid)['expectedOpaque']:
                high = mid
            else:
                low = mid
        probes = [sample(low), sample(high)]
        results.append(dict(fixture=row['fixture'], sourceFace=row['sourceFace'], policy=policy,
                            domain='unverified-expanded-plane-material-stress', probes=probes))
    report = dict(scope=__doc__, sourceStressReportSha256=sha(args.stress_report), packSha256=sha(pack),
                  scriptSha256=sha(Path(__file__)), records=results,
                  summary=dict(crossings=len(results), probes=sum(len(x['probes']) for x in results),
                               doubleDifferences=sum(p['doubleDifference'] for x in results for p in x['probes']),
                               quantizedCoefficientDifferences=sum(p['quantizedCoefficientDifference'] for x in results for p in x['probes'])),
                  limitation='These deliberately threshold-adjacent samples expose finite-precision classification sensitivity. No error-band or shader acceptance is implied; coefficient quantization alone is not a GPU emulation.')
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()
