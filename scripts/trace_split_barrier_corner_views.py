"""Bind two frozen barrier render changes to exact retained source faces.

Queries use the provisional relative-height control pack, matching the rendered
mesh. This does not certify the eventual original-height floor policy.
"""
import gzip
import hashlib
import json
from collections import Counter
from pathlib import Path

import numpy as np

from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT/'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = REV/'split-wall-family-normalized-candidate-v29/barrier-render-corner-source-trace.json'
    if out.exists():
        raise FileExistsError(out)
    manifest_path = REV/'barrier-contact-v29/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    warp_path = Path(manifest['displayWarpFile'])
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.array(warp['projection']['origin'])
    inverse = np.linalg.inv(matrix)
    source = np.array(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target = np.array(warp['targetAttackSvg']).reshape(-1, 2)
    cells = np.array(warp['triangles']).reshape(-1, 3)
    backward = explicit_warp(target, source-target, cells)
    forward = explicit_warp(source, target-source, cells)
    full_to_raw = np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    control_to_full = np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces']
    metadata_path = ROOT/'supplemented-v2/world/split/geometry.json'
    metadata = json.loads(metadata_path.read_text())
    starts = np.array([obj['firstFace'] for obj in metadata['objects']])
    models = {}
    for version in ('v26', 'v29'):
        folder = REV/f'split-wall-family-normalized-candidate-{version}'
        model = NativeReferenceModel(folder/'split.height.bin.gz', REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
        parents = np.load(folder/'correspondence.npz')['sourceFaces']
        proof = np.load(folder/'normalized-face-provenance.npz')
        edges = dict(zip(proof['generatedFaceIds'].tolist(), proof['generatedEdges'].tolist()))
        models[version] = (model, parents, edges)

    def cast(version, start, end):
        model, parents, edges = models[version]
        hit = model.cast(start, end, end_padding=0, end_inclusive=True)
        if hit is None:
            return None
        parent = int(parents[hit['face']])
        raw = int(full_to_raw[control_to_full[parent]])
        obj = int(np.searchsorted(starts, raw, side='right')-1)
        hit.update(controlParent=parent, rawSourceFace=raw, sourceObject=obj,
                   object=metadata['objects'][obj], generatedEdge=edges.get(hit['face'], -1),
                   displayedHitSvg=forward.apply(np.array(hit['point'][:2]) @ matrix.T + origin).tolist())
        return hit

    output = []
    wanted = ['barrier-123-end-quadrant-0-eye-1.75', 'barrier-122-end-quadrant-0-eye-1.75']
    for case_id in wanted:
        case = next(row for row in manifest['cases'] if row['side']=='attack' and row['id']==case_id)
        query = np.array(case['query'])
        eye = query[:3]
        heading = np.arctan2(query[4], query[3])
        rows = []
        for angle in np.linspace(-query[6]/2, query[6]/2, 413):
            direction = np.array([np.cos(heading+angle), np.sin(heading+angle), 0.])
            finish = eye + direction*query[5]
            rows.append(dict(angleOffsetDegrees=float(np.rad2deg(angle)),
                             before=cast('v26', eye, finish), after=cast('v29', eye, finish)))
        targets = ([[337.3125,263.3125], [337.5625,263.4375], [337.8125,263.5625],
                    [337.5625,263.0625], [337.0625,263.8125]] if '122-' in case_id else
                   [[306.,261.5], [310.,261.5], [315.,262.], [320.,263.],
                    [306.719,264.145], [308.,264.145], [306.,263.426]])
        probes = []
        for target_svg in targets:
            xy = (backward.apply(np.array(target_svg))-origin) @ inverse.T
            end = np.r_[xy, eye[2]]
            probes.append(dict(targetSvg=target_svg, nativeTarget=end.tolist(),
                               before=cast('v26', eye, end), after=cast('v29', eye, end)))
        summary = {}
        for version, key in [('v26','before'),('v29','after')]:
            hits = [row[key] for row in rows if row[key] is not None]
            distances = [hit['distanceMeters'] for hit in hits]
            summary[version] = dict(hits=len(hits), clear=len(rows)-len(hits),
                minimumDistanceMeters=min(distances, default=None),
                medianDistanceMeters=float(np.median(distances)) if distances else None,
                hitsWithin10cm=sum(x<.1 for x in distances),
                sourceObjects=dict(Counter(hit['sourceObject'] for hit in hits)))
        output.append(dict(id=case_id, query=query.tolist(),
                           originDisplayedSvg=forward.apply(eye[:2]@matrix.T+origin).tolist(),
                           sweep=rows, summary=summary, targetedPixelRays=probes))
    report = dict(scope=__doc__, manifestSha256=sha(manifest_path), displayWarpSha256=sha(warp_path),
                  metadataSha256=sha(metadata_path), scriptSha256=sha(Path(__file__)),
                  packs={v: sha(REV/f'split-wall-family-normalized-candidate-{v}/split.height.bin.gz') for v in models},
                  cases=output)
    out.write_text(json.dumps(report, indent=2))
    print(json.dumps([dict(id=row['id'], summary=row['summary'], targetedPixelRays=row['targetedPixelRays']) for row in output], indent=2))


if __name__ == '__main__':
    main()
