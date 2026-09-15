"""Identify source first hits in the reviewed ten-agent app scene."""
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp


def main():
    root = Path('E:/IcarusWorldAudit/2026-09-06')
    rev = root / 'tactical-visibility-revision'
    candidate = rev / 'split-wall-family-normalized-candidate-v18'
    manifest = json.loads((rev / 'frozen-split-app-scene-v18-run3/manifest.json').read_text())
    pack = candidate / 'split.height.bin.gz'
    assert hashlib.sha256(pack.read_bytes()).hexdigest() == manifest['candidatePackSha256']
    queries = manifest['records'][0]['sourceQueries']
    warp = json.loads(gzip.decompress((rev / 'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.array(warp['projection']['origin'])
    source = np.array(warp['sourceNativeMeters']).reshape(-1,2) @ matrix.T + origin
    target = np.array(warp['targetAttackSvg']).reshape(-1,2)
    cells = np.array(warp['triangles']).reshape(-1,3)
    backward = explicit_warp(target, source-target, cells)
    forward = explicit_warp(source, target-source, cells)
    model = NativeReferenceModel(pack, rev / 'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    bindings = json.loads((candidate / 'bindings.json').read_text())
    parents = np.load(candidate / 'correspondence.npz')['sourceFaces']
    control = np.load(Path(bindings['sourceBackup']).parent / 'correspondence.npz')['sourceFaces']
    full = np.load(rev / 'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    meta = json.loads((root / 'supplemented-v2/world/split/geometry.json').read_text())
    starts = np.array([obj['firstFace'] for obj in meta['objects']])
    targets = [(7, [[x,264.395] for x in [307,311,316,322,328,334,337]]),
               (4, [[x,y] for x in [233,235,237,239,241] for y in [198,201,204,207,210,212]]),
               (4, [[x,207.542] for x in [172,176,180,184,188,192,196]])]
    rows = []
    for agent, points in targets:
        query = queries[agent]
        for xy in points:
            destination = (backward.apply(np.array(xy, dtype=float))-origin) @ np.linalg.inv(matrix).T
            hit = model.cast(query[:3], np.r_[destination, query[2]])
            row = dict(agent=agent, targetSvg=xy, query=query, hit=hit)
            if hit:
                original = int(full[control[parents[hit['face']]]])
                obj = int(np.searchsorted(starts, original, side='right')-1)
                row.update(originalFace=original, sourceObject=obj, sourcePath=meta['objects'][obj]['path'],
                           hitSvg=forward.apply(np.array(hit['point'][:2])@matrix.T+origin).tolist())
            rows.append(row)
    report = dict(scope='Independent horizontal first-hit identification only. No wall-role acceptance or cone-angle membership claim.',
                  candidateSha256=manifest['candidatePackSha256'], records=rows)
    out = rev / 'root-frozen-scene-v18-hit-review.json'
    out.write_text(json.dumps(report, indent=2))
    for row in rows:
        print({k:v for k,v in row.items() if k not in ['query','hit']})


if __name__ == '__main__':
    main()
