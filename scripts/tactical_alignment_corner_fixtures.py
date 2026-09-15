"""Check bounded rays on audited structural objects, separately from other geometry."""
import argparse
import json
from pathlib import Path

import numpy as np

from tactical_alignment_audit import pack, projection, section, first_hit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    root = args.audit_root
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']['split']
    project = projection(catalog, json.loads((root / 'registration/results/split-registration.json').read_text()))
    metadata = json.loads((root / 'supplemented-v2/world/split/geometry.json').read_text())
    correspondence = np.load(root / 'compact-prototype/all-map-height-scoped-v2/split/source-correspondence.npz')['sourceFaces']
    parents = np.load(args.candidate / 'candidate-parent-faces.npz')['parents']
    fixtures = [
        {'object': 'Shell_6_AtkPathASewerBuildingASideGenerator_0', 'height': 5.369910668478667,
         'origin': [338.2, 244], 'target': [338.2, 251], 'expected': 'clear', 'label': 'outside-left-corner'},
        {'object': 'Shell_6_AtkPathASewerBuildingASideGenerator_0', 'height': 5.369910668478667,
         'origin': [339., 244], 'target': [339., 251], 'expected': 'blocked', 'expectedHit': [339., 248.196], 'label': 'inside-left-corner'},
        {'object': 'Shell_6_AtkPathASewerBuildingASideGenerator_0', 'height': 5.369910668478667,
         'origin': [350., 244], 'target': [350., 251], 'expected': 'blocked', 'expectedHit': [350., 248.196], 'label': 'facade-interior'},
        {'object': 'Shell_6_AtkPathASewerBuildingASideGenerator_0', 'height': 5.369910668478667,
         'origin': [358., 244], 'target': [358., 251], 'expected': 'clear', 'label': 'outside-right-corner'},
        {'object': 'Shell_9_DefPathToAWallB_0', 'height': 5.989216358122881,
         'origin': [280., 92], 'target': [280., 82], 'expected': 'blocked', 'expectedHit': [280., 83.9221], 'label': 'deadlock-facade-interior'},
    ]
    arrays_by_name = {name: pack(path)[1] for name, path in [
        ('before', Path('assets/maps/world/split.height.bin.gz')),
        ('candidate', args.candidate / 'split.height.bin.gz')]}
    for fixture in fixtures:
        objects = [o for o in metadata['objects'] if fixture['object'] in o['path']]
        source_admitted = np.zeros(len(correspondence), dtype=bool)
        for obj in objects:
            source_admitted |= (correspondence >= obj['firstFace']) & (correspondence < obj['firstFace'] + obj['faceCount'])
        for name, arrays in arrays_by_name.items():
            lines, ids = section(arrays, fixture['height'], vertical_only=False)
            allowed = source_admitted[ids if name == 'before' else parents[ids]]
            lines = project(lines[allowed])
            origin, target = np.array(fixture['origin']), np.array(fixture['target'])
            _, distance, hit = first_hit(origin, target, lines)
            blocked = distance <= np.linalg.norm(target - origin)
            fixture[name] = {'result': 'blocked' if blocked else 'clear',
                             'firstHitSvg': hit.tolist() if np.isfinite(distance) else None,
                             'boundedDistanceSvg': float(distance) if np.isfinite(distance) else None}
        result = fixture['candidate']
        fixture['passed'] = result['result'] == fixture['expected']
        if 'expectedHit' in fixture and result['firstHitSvg'] is not None:
            fixture['candidateHitErrorSvg'] = float(np.linalg.norm(np.array(result['firstHitSvg']) - fixture['expectedHit']))
            fixture['passed'] &= fixture['candidateHitErrorSvg'] <= .001
    report = {'scope': 'Object-isolated bounded horizontal rays against exact triangle sections. Establishes only local structural correspondence; other objects and tactical floor semantics require composed scene tests.', 'fixtures': fixtures}
    (args.candidate / 'bounded-corner-fixtures.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    if not all(f['passed'] for f in fixtures):
        raise ValueError('One or more bounded structural fixtures failed')


if __name__ == '__main__':
    main()
