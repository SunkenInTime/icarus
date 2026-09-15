"""Install reviewed standing candidates only after source and production checks."""
import json
from pathlib import Path
from audit_all_map_gameplay_levels import MAPS,read
from build_all_physical_standing_surfaces import sha
from build_reviewed_standing_surfaces import OUTPUT,REVIEW


def install():
    source=read(OUTPUT/'source-verification.json');production=read(OUTPUT/'production-verification.json')
    assert source['status']==production['status']=='passed'
    assert source['samples']==454 and not source['failures'] and source['reviewSha256']==sha(REVIEW)
    assert production['runtimeSourceSha256']==sha(Path('lib/view_cone/svg_height_visibility.dart'))
    boundary=Path(production['boundaryAudit']);assert sha(boundary)==production['boundaryAuditSha256']
    assert read(boundary)['flaggedCones']==0
    source_maps={r['map']:r for r in source['maps']};rendered={r['map']:r for r in production['maps']}
    ready=[]
    for name in MAPS:
        directory=OUTPUT/name
        if name in read(REVIEW)['maps']:
            build=read(directory/'reviewed-standing-build.json')
            assert build['reviewSha256']==sha(REVIEW)
            assert build['buildScriptSha256']==sha(Path('scripts/build_reviewed_standing_surfaces.py'))
        assert source_maps[name]['candidateSha256']==rendered[name]['candidateSha256']
        assert sha(Path(rendered[name]['manifest']))==rendered[name]['manifestSha256']
        for side in ['attack','defense']:
            candidate=directory/f'candidate-{side}.json.gz';asset=Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
            assert sha(candidate)==source_maps[name]['candidateSha256'][side]
            assert sha(asset) in [source_maps[name]['beforeSha256'][side],sha(candidate)],(name,side,'Installed baseline changed')
            before=read(directory/f'before-{side}.json.gz');after=read(candidate)
            assert all(before[k]==after[k] for k in before if k!='supports')
            assert after['supports'][:len(before['supports'])]==before['supports']
            ready.append((asset,candidate))
    for asset,candidate in ready:
        asset.write_bytes(candidate.read_bytes());assert sha(asset)==sha(candidate)
    (OUTPUT/'installation.json').write_text(json.dumps(dict(status='installed',reviewSha256=sha(REVIEW),
        files=[dict(asset=str(a),sha256=sha(a)) for a,_ in ready]),indent=2))
    print(len(ready),'verified map-side assets installed')


if __name__=='__main__':install()
