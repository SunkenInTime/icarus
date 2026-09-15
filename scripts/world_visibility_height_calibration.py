"""Calibrate standing-height slices against independent source-scene 3D rays.

Refinement subdivides complete failed height intervals. Verification uses a
different seed after the elevation list is fixed. The report and elevation
list are written even when acceptance fails; check report['accepted'] before
using the list for a final bake. This tests height sampling, not game fidelity.
"""
import argparse
import bisect
from collections import Counter
import json
import math
from pathlib import Path
import random
import subprocess
import sys
import time

_SCRIPT_DIRECTORY = str(Path(__file__).resolve().parent)
if _SCRIPT_DIRECTORY not in sys.path:
    sys.path.insert(0, _SCRIPT_DIRECTORY)

from refine_world_elevations import refine
from world_visibility_ray_reference import digest, heldout_origins, load_reference_scene


def nearest_layer(elevations, height):
    index = bisect.bisect_left(elevations, height)
    if index == 0:
        return 0
    if index == len(elevations):
        return index - 1
    return index - 1 if height - elevations[index - 1] <= elevations[index] - height else index


class CachedCaster:
    def __init__(self, cast):
        self.cast = cast
        self.cache = {}
        self.hits = 0
        self.calls = 0

    def __call__(self, origin, direction, distance):
        key = (*map(float, origin), *map(float, direction), float(distance))
        if key in self.cache:
            self.hits += 1
            return self.cache[key]
        self.calls += 1
        try:
            result = self.cast(origin, direction, distance)
            value = result['distanceMeters']
            if not math.isfinite(value) or value < 0 or value > distance + .001:
                raise ValueError('Caster returned an invalid hit distance.')
        except (ValueError, RuntimeError, OSError, KeyError, TypeError) as error:
            result = {'castError': type(error).__name__ + ': ' + str(error),
                      'distanceMeters': None, 'materialCertain': False}
        self.cache[key] = result
        return result


def compare_heights(origins, elevations, cast, *, eye_height_cm, directions,
                    range_meters, phase, label):
    """Compare true-eye and nearest-plane casts without section-bake geometry."""
    failures, exceptions, uncertain = [], [], []
    within2 = within10 = total = 0
    maximum = 0.0
    for sample in origins:
        x, y, floor = sample['positionMeters']
        eye = floor + eye_height_cm / 100
        index = nearest_layer(elevations, eye * 100)
        selected = elevations[index]
        for ray in range(directions):
            angle = (ray + phase) * math.tau / directions
            direction = (math.cos(angle), math.sin(angle), 0)
            exact = cast((x, y, eye), direction, range_meters)
            quantized = cast((x, y, selected / 100), direction, range_meters)
            row = {'ray': f'{label}/{sample["id"]}-{ray}', 'sample': sample['id'],
                   'elevationCm': eye * 100, 'layerIndex': index,
                   'layerElevationCm': selected, 'trueRay': exact, 'planeRay': quantized}
            total += 1
            if 'castError' in exact or 'castError' in quantized:
                row['errorMeters'] = None
                exceptions.append(row)
                continue
            error = quantized['distanceMeters'] - exact['distanceMeters']
            row['errorMeters'] = error
            magnitude = abs(error)
            within2 += magnitude <= .02
            within10 += magnitude <= .1
            maximum = max(maximum, magnitude)
            if magnitude > .02:
                failures.append(row)
            if not exact.get('materialCertain', False) or not quantized.get('materialCertain', False):
                uncertain.append(row)
    return {
        'summary': {'rays': total, 'within2Cm': within2, 'within10Cm': within10,
                    'within2CmFraction': within2 / total if total else 0,
                    'within10CmFraction': within10 / total if total else 0,
                    'maximumDistanceDifferenceMeters': maximum,
                    'exceptions': len(exceptions), 'uncertainMaterialRays': len(uncertain)},
        'failures': failures, 'exceptions': exceptions, 'uncertainMaterialRays': uncertain,
    }


def floor_checks(origins, cast):
    results = []
    for sample in origins:
        x, y, z = sample['positionMeters']
        hit = cast((x, y, z + .02), (0, 0, -1), .04)
        agrees = ('castError' not in hit and hit.get('hitMeters') is not None
                  and abs(hit['hitMeters'][2] - z) <= .01)
        results.append({'sample': sample['id'], 'agreesWithin1Cm': agrees, 'reference': hit})
    return {'samples': len(results), 'agreeWithin1Cm': sum(r['agreesWithin1Cm'] for r in results),
            'results': results}


def calibrate(origins, initial_elevations, cast, *, eye_height_cm=175, directions=16,
              range_meters=65, phase=.371, max_refinements=4):
    elevations = sorted(set(initial_elevations))
    if not elevations or not all(math.isfinite(h) for h in elevations):
        raise ValueError('Candidate elevations must be finite and nonempty.')
    rounds = []
    for iteration in range(max_refinements + 1):
        comparison = compare_heights(origins, elevations, cast, eye_height_cm=eye_height_cm,
                                     directions=directions, range_meters=range_meters,
                                     phase=phase, label='calibration')
        comparison.update(iteration=iteration, elevationCount=len(elevations))
        rounds.append(comparison)
        print(json.dumps({'iteration': iteration, 'elevations': len(elevations),
                          **comparison['summary']}), flush=True)
        if comparison['summary']['within10Cm'] == comparison['summary']['rays']:
            break
        if iteration == max_refinements:
            break
        refined, summary = refine(elevations, comparison['failures'],
                                  tolerance_meters=.1, maximum_step_cm=1)
        comparison['refinement'] = summary
        if not summary['addedPlanes']:
            break
        elevations = refined
    return elevations, rounds


def _write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.writing')
    temporary.write_text(json.dumps(data, allow_nan=False, separators=(',', ':')), encoding='utf-8')
    temporary.replace(path)


def blender_calibration(args):
    import bpy

    started = time.perf_counter()
    scene = load_reference_scene(args.world, args.policies)
    initial = json.loads(Path(args.initial_elevations).read_text(encoding='utf-8'))
    cast = CachedCaster(scene.cast)
    ground_cast = CachedCaster(scene.ground_cast)
    ui, floor = scene.metadata['uiTransform'], scene.floor_report['floorMesh']
    walkable = scene.policy_document['walkable']
    origins = heldout_origins(floor, ui, args.samples, args.seed, walkable)
    calibration_floor = floor_checks(origins, ground_cast)
    calibration_sight_floor = floor_checks(origins, cast)
    phase = random.Random(args.seed).random()
    elevations, rounds = calibrate(origins, initial, cast, eye_height_cm=args.eye_height_cm,
                                   directions=args.directions, range_meters=args.range_meters,
                                   phase=phase, max_refinements=args.max_refinements)
    # These origins are generated only after calibration has fixed the list.
    # Their failures never feed the refinement helper.
    verification_origins = heldout_origins(floor, ui, args.verification_samples,
                                           args.verification_seed, walkable)
    verification_floor = floor_checks(verification_origins, ground_cast)
    verification_sight_floor = floor_checks(verification_origins, cast)
    verification_phase = random.Random(args.verification_seed).random()
    verification = compare_heights(verification_origins, elevations, cast,
                                   eye_height_cm=args.eye_height_cm, directions=args.directions,
                                   range_meters=args.range_meters, phase=verification_phase,
                                   label='verification')
    accepted = (rounds[-1]['summary']['within10CmFraction'] >= args.target_fraction
                and verification['summary']['within10CmFraction'] >= args.target_fraction
                and not rounds[-1]['exceptions'] and not verification['exceptions']
                and calibration_floor['agreeWithin1Cm'] == calibration_floor['samples']
                and verification_floor['agreeWithin1Cm'] == verification_floor['samples'])
    report = {
        'schemaVersion': 1, 'map': scene.metadata['map'],
        'status': 'independent-3d-height-calibration', 'accepted': accepted, 'gameplayCertified': False,
        'eyeHeightCm': args.eye_height_cm, 'rangeMeters': args.range_meters,
        'acceptance': {'minimumWithin10CmFraction': args.target_fraction,
                       'requiresNoCastExceptions': True, 'requiresEligibleGroundWithin1Cm': True,
                       'genericSightMaterialDownwardCastIsDiagnosticOnly': True},
        'initialElevationsCm': initial, 'selectedElevationsCm': elevations,
        'calibration': {'seed': args.seed, 'directionPhase': phase, 'directions': args.directions,
                        'origins': origins, 'floorChecks': calibration_floor,
                        'genericSightFloorDiagnostics': calibration_sight_floor, 'rounds': rounds},
        'verification': {'seed': args.verification_seed, 'directionPhase': verification_phase,
                         'directions': args.directions, 'origins': verification_origins,
                         'floorChecks': verification_floor,
                         'genericSightFloorDiagnostics': verification_sight_floor, **verification},
        'source': {'geometrySha256': scene.geometry_sha256,
                   'metadataSha256': digest(Path(args.world) / 'geometry.json'),
                   'floorMeshSha256': digest(Path(args.world) / 'floor-mesh.json'),
                   'navigationSha256': scene.policy_document['navigationSha256'],
                   'materialPoliciesSha256': digest(args.policies),
                   'initialElevationsSha256': digest(args.initial_elevations),
                   'casterScriptSha256': digest(Path(__file__).with_name('world_visibility_ray_reference.py')),
                   'calibrationScriptSha256': digest(__file__), 'bpyVersion': bpy.app.version_string},
        'summary': {'initialPlanes': len(initial), 'selectedPlanes': len(elevations),
                    'calibrationRounds': len(rounds), 'uniqueCasts': cast.calls, 'cachedCasts': cast.hits,
                    'uniqueGroundCasts': ground_cast.calls,
                    'calibrationWithin2CmFraction': rounds[-1]['summary']['within2CmFraction'],
                    'calibrationWithin10CmFraction': rounds[-1]['summary']['within10CmFraction'],
                    'verificationWithin2CmFraction': verification['summary']['within2CmFraction'],
                    'verificationWithin10CmFraction': verification['summary']['within10CmFraction'],
                    **scene.diagnostics(), 'seconds': time.perf_counter() - started},
        'limitations': [
            'Calibration compares the same original placed triangles at two heights; it does not read baked visibility segments.',
            'Static selected art and full-resolution exported alpha policy; dynamic state and native shader or mip differences remain.',
            'Only standing horizontal sightlines are sampled; held-out agreement is statistical evidence, not a universal bound.',
            'Every >2 cm mismatch and caster exception is retained. Verification failures do not alter the candidate elevation list.',
        ],
    }
    _write(args.output, report)
    _write(Path(args.output).with_suffix('.elevations.json'), elevations)
    print(json.dumps({'accepted': accepted, **report['summary']}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world', required=True)
    parser.add_argument('--navigation', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--blender')
    parser.add_argument('--samples', type=int, default=512)
    parser.add_argument('--verification-samples', type=int, default=1024)
    parser.add_argument('--directions', type=int, default=16)
    parser.add_argument('--range-meters', type=float, default=65)
    parser.add_argument('--eye-height-cm', type=float, default=175)
    parser.add_argument('--initial-step-cm', type=float, default=5)
    parser.add_argument('--max-refinements', type=int, default=4)
    parser.add_argument('--target-fraction', type=float, default=.999)
    parser.add_argument('--seed', type=int, default=473831)
    parser.add_argument('--verification-seed', type=int, default=930173)
    parser.add_argument('--texture-properties-root')
    parser.add_argument('--initial-elevations')
    parser.add_argument('--policies')
    parser.add_argument('--inside-blender', action='store_true')
    arguments = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    args = parser.parse_args(arguments)
    if (not all(math.isfinite(v) for v in (args.range_meters, args.eye_height_cm,
                                          args.initial_step_cm, args.target_fraction))
            or args.samples <= 0 or args.verification_samples <= 0 or args.directions < 4
            or args.range_meters <= 0 or args.eye_height_cm <= 0 or args.max_refinements < 0
            or args.initial_step_cm <= 0 or args.seed < 0 or args.verification_seed < 0
            or not 0 < args.target_fraction <= 1 or args.seed == args.verification_seed):
        parser.error('Use positive sample/range/height counts, at least four directions, distinct seeds and a target in (0,1].')
    if args.inside_blender:
        if not args.policies or not args.initial_elevations:
            parser.error('Blender calibration requires policy and initial-elevation files.')
        blender_calibration(args)
        return
    if not args.blender:
        parser.error('--blender is required for the launcher')
    from world_geometry_bake import standing_elevations
    from world_visibility_materials import build_policy
    folder, output = Path(args.world), Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    metadata = json.loads((folder / 'geometry.json').read_text(encoding='utf-8'))
    navigation = json.loads(Path(args.navigation).read_text(encoding='utf-8'))
    if not args.initial_elevations:
        refinement = json.loads((folder / 'floor-refinement.json').read_text(encoding='utf-8'))
        floor = json.loads((folder / 'floor-mesh.json').read_text(encoding='utf-8'))['floorMesh']
        elevations = standing_elevations(navigation, refinement, floor, args.eye_height_cm, args.initial_step_cm)
        common = Counter(int(round(z)) for z in refinement['refinedFloorHeightsCm'])
        menu = [z + args.eye_height_cm for z, count in common.items()
                if count >= max(8, len(refinement['refinedFloorHeightsCm']) * .02)]
        menu = menu or [common.most_common(1)[0][0] + args.eye_height_cm]
        args.initial_elevations = str(output.with_suffix('.initial-elevations.json'))
        _write(args.initial_elevations, sorted(set(elevations) | set(menu)))
    args.policies = str(output.with_suffix('.policies.json'))
    _write(args.policies, {'walkable': navigation['walkable'], 'navigationSha256': digest(args.navigation),
                           'policies': [build_policy(m, texture_properties_root=args.texture_properties_root)
                                        for m in metadata['materials']]})
    command = [str(Path(args.blender).resolve()), '--background', '--factory-startup', '--python-exit-code', '1', '--python',
               str(Path(__file__).resolve()), '--', '--inside-blender']
    for name in ('world', 'navigation', 'output', 'samples', 'verification_samples', 'directions',
                 'range_meters', 'eye_height_cm', 'max_refinements', 'target_fraction', 'seed',
                 'verification_seed', 'initial_elevations', 'policies'):
        command.extend(('--' + name.replace('_', '-'), str(getattr(args, name))))
    subprocess.run(command, check=True)
    if not output.is_file():
        raise RuntimeError('Blender returned without a height calibration report.')


if __name__ == '__main__':
    main()
