"""Measure exact-wall profile opportunities in a reviewed source-height oracle.

Read-only inventory. Candidates must follow an explicitly reviewed authored span;
unassigned geometry remains in the 3D reference. Nothing is simplified or dropped.
"""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np

from lift_reviewed_wall_source_heights import sha
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import profile_frame


def inventory(oracle, candidate, warp_path, output):
    if output.exists():
        raise FileExistsError(output)
    bindings = json.loads((candidate / 'bindings.json').read_text())
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    oracle_path = oracle / f'{warp["map"]}.height.bin.gz'
    _, scene = pack(oracle_path)
    with np.load(oracle / 'original-source-provenance.npz') as archive:
        edges = archive['edges']
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    native = np.asarray(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target = np.asarray(warp['targetAttackSvg']).reshape(-1, 2)
    forward = explicit_warp(native, target-native, np.asarray(warp['triangles']).reshape(-1, 3))
    triangles = scene['vertices'][scene['faces']]
    displayed = forward.apply((triangles[:, :, :2] @ matrix.T + origin).reshape(-1, 2)).reshape(-1, 3, 2)
    records = []
    for family in bindings['families']:
        indices = np.flatnonzero(edges == family['edge'])
        xy = displayed[indices]
        matched = np.zeros(len(indices), dtype=bool)
        if family.get('mappingType') == 'piecewise-affine-region-v1':
            spans = [dict(id=s['completeSpan'], start=np.asarray(s['startSvg']), end=np.asarray(s['endSvg']))
                     for s in family.get('reviewedAuthoredSpans', [])]
        else:
            o, t, _ = profile_frame(family, 'target')
            spans = [dict(id=family['edge'], start=o+family['targetAlong'][0]*t,
                          end=o+family['targetAlong'][1]*t)]
        rows = []
        for span in spans:
            delta = span['end'] - span['start']; length = np.linalg.norm(delta)
            tangent = delta / length; normal = np.array([-tangent[1], tangent[0]])
            along = (xy-span['start']) @ tangent
            distance = abs((xy-span['start']) @ normal).max(1)
            selected = (~matched) & (distance <= 1e-10) & (along.min(1) >= -1e-10) & (along.max(1) <= length+1e-10)
            matched |= selected
            masked = scene['faceMasks'][indices[selected]] >= 0
            profile = np.stack((along[selected], triangles[indices[selected], :, 2]), axis=2)
            a = profile[:, 1] - profile[:, 0]; b = profile[:, 2] - profile[:, 0]
            positive = (a[:, 0]*b[:, 1]-a[:, 1]*b[:, 0]) != 0
            rows.append(dict(span=span['id'], triangles=int(selected.sum()), masked=int(masked.sum()),
                positiveProfileArea=int(positive.sum()), maximumContactResidualSvg=float(distance[selected].max(initial=0))))
        records.append(dict(family=family['edge'], triangles=len(indices),
            profileCandidates=int(matched.sum()), residual3dTriangles=int((~matched).sum()), spans=rows))
    report = dict(scope=__doc__, oraclePackSha256=sha(oracle_path),
        provenanceSha256=sha(oracle/'original-source-provenance.npz'), bindingsSha256=sha(candidate/'bindings.json'),
        displayWarpSha256=sha(warp_path), scriptSha256=sha(Path(__file__)),
        profileCandidates=sum(r['profileCandidates'] for r in records),
        residual3dTriangles=sum(r['residual3dTriangles'] for r in records), families=records,
        limitations=['Contact tolerance1e-10SVG is an inventory criterion, not a new runtime approximation.',
                     'Profiles still need union, alpha and endpoint-equivalence validation.',
                     'Zero-area source pieces and unmatched geometry remain in the reference; no performance claim.'])
    output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['profileCandidates','residual3dTriangles']}))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['oracle','candidate','warp','output']:
        parser.add_argument(name,type=Path)
    args=parser.parse_args()
    inventory(args.oracle,args.candidate,args.warp,args.output)
