"""Verify floor-role inventory bindings and emit a small review table."""
import csv
import hashlib
import json
from pathlib import Path
import numpy as np


def main():
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    directory = revision / 'competing-floor-assemblies-v3'
    maps = ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven', 'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']
    summary, queue, pending = [], [], []
    for name in maps:
        path = directory / f'{name}.json'
        if not path.exists():
            pending.append(name); continue
        report = json.loads(path.read_text())
        support_meta = json.loads((revision / f'source-floor-support-all-walkable-v1/{name}.floor-support.json').read_text())
        assert report['supportSha256'] == support_meta['dataSha256']
        pair_path = directory / report['pairFile']
        assert report['pairSha256'] == hashlib.sha256(pair_path.read_bytes()).hexdigest()
        pairs = np.load(pair_path)
        assert pairs['supportIndices'].shape == (report['pairCount'], 2)
        assert np.all(pairs['minimumGapMeters'] >= .05 - 1e-10)
        assert np.all(pairs['maximumGapMeters'] <= .35 + 1e-10)
        assert np.all(pairs['minimumGapMeters'] <= pairs['maximumGapMeters'] + 1e-10)
        total_faces = []
        for row in report['records']:
            first = row['sourceObject']['firstFace']; end = first + row['sourceObject']['faceCount']
            assert all(first <= index < end for index in row['admittedOriginalSourceFaceIds'])
            assert row['role'] == 'unclassified-review-candidate'
            total_faces.extend(row['admittedFullPackFaceIds'])
            priority = row.get('terrainReviewQueue', {})
            if priority.get('priority'):
                queue.append({'map': name, 'objectIndex': row['sourceObjectIndex'], 'sourceFirstFace': first, 'objectPath': row['objectPath'], 'admittedFaces': len(row['admittedFullPackFaceIds']), 'sourceSourceBandAreaMeters2': priority['sourceSourceClimbBandAreaMeters2'], 'sourceRefinedConnectedNavSpanMeters': priority['connectedNavHeightSpanMeters'], 'nativeMesh': row['native'].get('mesh')})
        assert len(total_faces) == len(set(total_faces)), 'Distinct exact instances must not share admitted faces'
        finished = all('terrainReviewQueue' in row for row in report['records'])
        if not finished:
            pending.append(name + ':priority')
        summary.append({'map': name, 'admittedSourceFaces': report['sourceSupportTriangles'], 'climbBandPairs': report['pairCount'], 'competingExactObjects': report['assemblyCount'], 'priorityObjects': sum(row.get('terrainReviewQueue', {}).get('priority', False) for row in report['records']), 'priorityFinished': finished, 'reportSha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'supportSha256': report['supportSha256']})
    result = {'schemaVersion': 1, 'productionMutation': False, 'complete': not pending, 'pending': pending, 'scope': 'Exact instance inventory of source/nav height conflicts in5–35cm band. Priority source/source conflicts use experimental slope/area thresholds plus source-refined nav progression; no automatic terrain role is assigned. Independent native Recast evidence for steep faces is a separate report.', 'maps': summary, 'checks': 'All source-face IDs remain inside exact object ranges; no repeated assignment across different instances; pair gaps inside declared band; support and pair hashes match.'}
    (directory / 'summary.json').write_text(json.dumps(result, indent=2))
    if queue:
        with (directory / 'review-queue.csv').open('w', newline='') as file:
            writer = csv.DictWriter(file, fieldnames=list(queue[0])); writer.writeheader(); writer.writerows(queue)
    print(json.dumps({'complete': not pending, 'pending': pending, 'maps': len(summary), 'priorityObjects': len(queue)}))


if __name__ == '__main__':
    main()
