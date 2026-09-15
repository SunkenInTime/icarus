"""Subdivide height intervals where independent reference rays expose errors.

This refines complete height intervals rather than inserting a test ray's exact
height. A separate held-out origin seed must verify the resulting asset.
"""
import argparse
import gzip
import json
import math
from pathlib import Path


def refine(elevations, failures, tolerance_meters=.1, maximum_step_cm=1):
    if maximum_step_cm <= 0 or tolerance_meters <= 0:
        raise ValueError('Spacing and distance tolerance must be positive.')
    intervals = set()
    exact_height_errors = []
    for failure in failures:
        if abs(failure['errorMeters']) <= tolerance_meters:
            continue
        index = failure['layerIndex']
        if abs(elevations[index] - failure['layerElevationCm']) > 1e-6:
            raise ValueError('Failure report does not match the supplied elevation list.')
        height = failure['elevationCm']
        if abs(height - elevations[index]) < .001:
            exact_height_errors.append(failure['ray'])
            continue
        other = index - 1 if height < elevations[index] else index + 1
        if not 0 <= other < len(elevations):
            raise ValueError('Reference elevation lies outside the baked range.')
        intervals.add(tuple(sorted((index, other))))
    output = set(elevations)
    refined = []
    for a, b in sorted(intervals):
        low, high = elevations[a], elevations[b]
        # Always make progress if a previously refined interval still fails.
        pieces = max(2, math.ceil((high - low) / maximum_step_cm))
        output.update(round(low + (high - low) * i / pieces, 6) for i in range(1, pieces))
        refined.append({'lowerCm': low, 'upperCm': high, 'newStepCm': (high - low) / pieces})
    return sorted(output), {'refinedIntervals': refined, 'addedPlanes': len(output) - len(elevations),
                            'exactHeightErrors': exact_height_errors,
                            'distanceToleranceMeters': tolerance_meters,
                            'maximumNewStepCm': maximum_step_cm}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('asset', type=Path)
    parser.add_argument('report', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--tolerance-meters', type=float, default=.1)
    parser.add_argument('--maximum-step-cm', type=float, default=1)
    args = parser.parse_args()
    asset = json.loads(gzip.decompress(args.asset.read_bytes()))
    report = json.loads(args.report.read_text())
    if asset['map'] != report['map']:
        raise ValueError('Reference report names a different map.')
    elevations, summary = refine([layer['elevationCm'] for layer in asset['layers']], report['failures'],
                                  args.tolerance_meters, args.maximum_step_cm)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(elevations), encoding='utf-8')
    args.output.with_suffix('.refinement.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary), flush=True)
