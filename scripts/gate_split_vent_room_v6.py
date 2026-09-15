"""Independent finite topology and evidence gate; this does not approve a bake."""
import gzip,json
from pathlib import Path
import numpy as np
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology,verify_rank_one_declarations
from lift_reviewed_wall_source_heights import sha

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
out=REV/'split-vent-room-finite-field-experiment-v6';p=out/'sealed-held-region-declaration.json';f=json.loads(p.read_text())
wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
forward=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
topology=verify_region_topology(f,forward);ranks=verify_rank_one_declarations(f)
parts=REV/'split-vent-room-raw-partition-v3/partition-review.json'
rays=REV/'split-vent-room-composed-standing-rays-v5/membership-comparison.json'
old=json.loads((REV/'split-vent-room-finite-field-experiment-v5/sealed-held-region-declaration.json').read_text())
same={key:f[key]==old[key] for key in ['sourceVerticesSvg','targetVerticesSvg','triangles','declaredRankOneMappings','declaredConstantPointCells','box']}
assert all(same.values())
report=dict(declarationSha256=sha(p),scriptSha256=sha(Path(__file__)),topology=topology,
    independentlyVerifiedScalarCells=len(ranks),constantPointCells=len(f['declaredConstantPointCells']),
    fieldAndRankUnchangedFromV5=same,partitionReportSha256=sha(parts),partition=json.loads(parts.read_text()),
    composedQueryComparisonSha256=sha(rays),comparison=json.loads(rays.read_text()),
    unresolved=['Upper172 continuation on source5927 is separate and remains early.',
        'Actual standing section evidence does not establish the final tactical receiver layer policy.',
        'Attack124 and literal defense SVG differ by 0.0008 SVG after canonical flip.',
        'Full composed pack gate, application cones, and performance tests have not run.'],
    status='Held room evidence gate only. No bake or production promotion.')
(out/'independent-room-gate.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(topologyPassed=True,scalarCells=len(ranks),constantCells=len(f['declaredConstantPointCells']),output=str(out/'independent-room-gate.json'))))
