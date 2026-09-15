"""Bounded left/right doorway tests for the composed Split Clove correction."""
import argparse
import json
from pathlib import Path

import numpy as np
from tactical_alignment_audit import pack, section, projection, first_hit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit-root', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    root = args.audit_root
    meta = json.loads((root / 'supplemented-v2/world/split/geometry.json').read_text())
    objects = [o for o in meta['objects'] if 'Shell_6_VentRoomDoorFrameADU/' in o['path']]
    full = np.load(root / 'tactical-visibility-revision/full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    flat_root = root / 'tactical-visibility-revision/global-ground-complete-v2/split'
    flat = np.load(flat_root / 'correspondence.npz')['sourceFaces']
    parents = np.load(args.candidate / 'candidate-parent-faces.npz')['parents']
    source_ids = full[flat]
    original_admitted = np.zeros(len(source_ids), dtype=bool)
    for obj in objects:
        original_admitted |= (source_ids >= obj['firstFace']) & (source_ids < obj['firstFace'] + obj['faceCount'])
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']['split']
    project = projection(catalog, json.loads((root / 'registration/results/split-registration.json').read_text()))
    lines_by_name = {}
    for name, path in [('before', flat_root / 'split.height.bin.gz'), ('candidate', args.candidate / 'split.height.bin.gz')]:
        _, arrays = pack(path)
        lines, ids = section(arrays, 1.763667525596051, vertical_only=False)
        admitted = original_admitted[ids if name == 'before' else parents[ids]]
        lines_by_name[name] = project(lines[admitted])
    origin = np.array([219.08024225141395, 259.01489066778504])
    tests = [([235., 210.], 'clear', 'right opening stays open'),
             ([236.6, 211.], 'blocked', 'right authored wall still blocks'),
             ([223., 210.], 'clear', 'left opening stays open'),
             ([222., 210.], 'blocked', 'left authored wall still blocks')]
    records = []
    for target, expected, label in tests:
        target = np.array(target)
        record = {'label': label, 'originSvg': origin.tolist(), 'targetSvg': target.tolist(), 'expected': expected}
        for name, lines in lines_by_name.items():
            _, distance, hit = first_hit(origin, target, lines)
            result = 'blocked' if distance <= np.linalg.norm(target - origin) else 'clear'
            record[name] = {'result': result, 'hitSvg': hit.tolist() if np.isfinite(distance) else None}
        record['passed'] = record['candidate']['result'] == expected
        records.append(record)
    report = {'scope': 'Exact isolated static doorway triangle sections; preserves open passage and each structural jamb. Full-scene receiver/render checks are separate.', 'sourceObjects': [o['path'] for o in objects], 'fixtures': records}
    (args.candidate / 'clove-bounded-fixtures.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    if not all(r['passed'] for r in records): raise ValueError('Clove bounded fixture failed')


if __name__ == '__main__':
    main()
