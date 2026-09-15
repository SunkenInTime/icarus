"""Bind production cones and their independent boundary audit to the candidates."""
import argparse
import json
from pathlib import Path
import numpy as np
from audit_all_map_gameplay_levels import MAPS, read
from build_all_physical_standing_surfaces import OUTPUT, sha
from audit_svg_cone_boundaries import run


def verify(production, model_root=OUTPUT):
    manifests=[];queries=[]
    for name in MAPS:
        fixture=read(model_root/name/'production-cases.json')
        manifest=production/name/'manifest.json'
        rendered=read(manifest)
        assert rendered['runtimeSourceSha256']==sha(Path('lib/view_cone/svg_height_visibility.dart'))
        rows=rendered['records']
        assert len(rows)==len(fixture['cases'])
        assert {r['id'] for r in rows}=={r['id'] for r in fixture['cases']}
        hashes={s:sha(model_root/name/f'candidate-{s}.json.gz') for s in ['attack','defense']}
        assert hashes==fixture['candidateSha256']
        for side in hashes:
            assert read(model_root/f'render-models/{name}-{side}.json')==read(model_root/name/f'candidate-{side}.json.gz')
        assert all(len(r['polygonSvg'])>=3 for r in rows)
        assert all(r['nativeReferenceBoundaryDifferenceSvg']<1e-6 for r in rows)
        assert all(abs(r['eyeElevationMeters']-r['expectedEyeElevationMeters'])<1e-6 for r in rows)
        assert all(r['receiverContainsOrigin'] for r in rows if 'image' in r)
        queries.extend(rows)
        timings=[r['queryWithStandingMicroseconds'] for r in rows]
        manifests.append(dict(map=name,candidateSha256=hashes,manifest=str(manifest),manifestSha256=sha(manifest),
            queries=len(rows),renders=sum('image' in r for r in rows),
            queryMedianMicros=float(np.median(timings)),queryP95Micros=float(np.percentile(timings,95))))
    (production/'cones.jsonl').write_text('\n'.join(json.dumps(r,separators=(',',':')) for r in queries)+'\n')
    run(production,model_root)
    boundary=read(production/'boundary-audit.json')
    assert boundary['flaggedCones']==0
    report=dict(status='passed',maps=manifests,queries=len(queries),renders=sum('image' in r for r in queries),
        runtimeSourceSha256=sha(Path('lib/view_cone/svg_height_visibility.dart')),
        boundaryAudit=str(production/'boundary-audit.json'),boundaryAuditSha256=sha(production/'boundary-audit.json'))
    (model_root/'production-verification.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k in ['status','queries','renders']}))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('production',type=Path);p.add_argument('--models',type=Path,default=OUTPUT)
    args=p.parse_args();verify(args.production,args.models)
