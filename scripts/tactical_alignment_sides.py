"""Measure actual defense artwork against reflected attack artwork, without edits."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree
from shapely import LineString, MultiLineString, points, distance

from audit_map_registration import svg_contours
from tactical_alignment_audit import projection


def metrics(values):
    return {'count': len(values), 'medianSvg': float(np.median(values)),
            'p95Svg': float(np.percentile(values, 95)), 'maxSvg': float(np.max(values))}


def audit(name, root):
    attack_file = Path(f'assets/maps/{name}_map.svg')
    defense_file = Path(f'assets/maps/{name}_map_defense.svg')
    attack, corners, paths, box = svg_contours(attack_file)
    defense, dcorners, dpaths, dbox = svg_contours(defense_file)
    center_sum = np.array([2 * box[0] + box[2], 2 * box[1] + box[3]])
    reflected = center_sum - corners
    # Reciprocal nearby exact vector corners, then spatial held-out validation.
    tree = cKDTree(dcorners)
    delta = np.median(dcorners[tree.query(reflected)[1]] - reflected, axis=0)
    for _ in range(5):
        ds, ids = tree.query(reflected + delta)
        reverse = cKDTree(reflected + delta).query(dcorners)[1]
        admitted = (ds < 3) & (reverse[ids] == np.arange(len(reflected)))
        delta = np.median(dcorners[ids[admitted]] - reflected[admitted], axis=0)
    source, target = reflected[admitted], dcorners[ids[admitted]]
    train = (np.floor(source[:, 0] / 50) + np.floor(source[:, 1] / 50)).astype(int) % 2 == 0
    fitted_delta = np.median(target[train] - source[train], axis=0)
    errors = np.linalg.norm(source + fitted_delta - target, axis=1)
    # Full continuous contours establish whether unmatched/local artwork also differs.
    defense_lines = MultiLineString([np.vstack((p, p[0])) for p in dpaths])
    fitted_attack_paths = [center_sum - p + fitted_delta for p in paths]
    attack_lines = MultiLineString([np.vstack((p, p[0])) for p in fitted_attack_paths])
    full_distances = np.r_[distance(points(center_sum - attack + fitted_delta), defense_lines),
                           distance(points(defense), attack_lines)]
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]
    registration = json.loads((root / f'registration/results/{name}-registration.json').read_text())
    project = projection(catalog, registration)
    origin = project(np.zeros(2))
    matrix = np.column_stack((project(np.array([1., 0])) - origin, project(np.array([0., 1])) - origin))
    attack_affine = np.column_stack((matrix, origin))
    defense_affine = np.column_stack((-matrix, center_sum - origin + fitted_delta))
    return {'map': name, 'attackSha256': hashlib.sha256(attack_file.read_bytes()).hexdigest(),
            'defenseSha256': hashlib.sha256(defense_file.read_bytes()).hexdigest(),
            'attackViewBox': box, 'defenseViewBox': dbox,
            'defenseDeltaAfterReflectionSvg': fitted_delta.tolist(),
            'nativeToAttackSvg': attack_affine.tolist(), 'nativeToDefenseSvg': defense_affine.tolist(),
            'matchedCorners': len(source), 'trainingCorners': int(train.sum()),
            'heldOutCorners': metrics(errors[~train]), 'allMatchedCorners': metrics(errors),
            'bidirectionalContour': metrics(full_distances),
            'translationSufficientWithin0_01Svg': bool(np.max(full_distances) <= .01),
            'convention': 'defenseSVG = (viewBox origin*2 + size) - attackSVG + delta; native input meters. Query origin uses inverse of the same side affine. No claim that mirrored saved markers represent identical physical positions.',
            'heldOutMatches': [{'reflectedAttack': a.tolist(), 'defense': b.tolist(), 'errorSvg': float(e)}
                               for a, b, e in zip(source[~train], target[~train], errors[~train])]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    names = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']
    results = []
    for name in names:
        result = audit(name, args.audit_root)
        (args.output / f'{name}.json').write_text(json.dumps(result, indent=2))
        results.append(result)
        print(name, result['defenseDeltaAfterReflectionSvg'], result['heldOutCorners'], result['bidirectionalContour'], flush=True)
    (args.output / 'summary.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
