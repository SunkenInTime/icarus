"""Install only a fully verified support addition against the frozen baseline."""
import json
from pathlib import Path
from audit_all_map_gameplay_levels import MAPS, read
from build_all_physical_standing_surfaces import OUTPUT, sha


def install():
    ready=[]
    production=read(OUTPUT/'production-verification.json')
    assert production['status']=='passed'
    assert production['runtimeSourceSha256']==sha(Path('lib/view_cone/svg_height_visibility.dart'))
    assert sha(Path(production['boundaryAudit']))==production['boundaryAuditSha256']
    assert read(Path(production['boundaryAudit']))['flaggedCones']==0
    rendered={r['map']:r for r in production['maps']}
    for name in MAPS:
        directory=OUTPUT/name
        build=read(directory/'physical-top-build.json')
        proof=read(directory/'physical-top-verification.json')
        assert not proof['centersOnly'] and not proof['failures']
        assert proof['sampledPositions']>0
        assert proof['standingContactPolicy']=='global-walkable-capsule-contact-v1'
        for name_,digest in proof['verificationCodeSha256'].items():
            assert sha(Path(__file__).parent/name_)==digest
        assert proof['previousDetachedCounts'].get('unresolved-standing-domain',0)==0
        assert not any(r['possibleStandingDomains'] for r in proof['unknownCollisionDomains'])
        assert proof['buildReportSha256']==sha(directory/'physical-top-build.json')
        assert proof['candidateSha256']==build['candidateSha256']
        coverage=read(directory/'all-prior-floor-coverage.json')
        assert coverage['candidateSha256']==build['candidateSha256']
        assert coverage['counts'].get('unresolved-physical-standing-domain',0)==0
        assert rendered[name]['candidateSha256']==build['candidateSha256']
        assert sha(Path(rendered[name]['manifest']))==rendered[name]['manifestSha256']
        for side in ['attack','defense']:
            candidate=directory/f'candidate-{side}.json.gz'
            asset=Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
            before=directory/f'before-{side}.json.gz'
            assert sha(before)==build['beforeSha256'][side]
            assert sha(candidate)==build['candidateSha256'][side]
            assert sha(asset) in [sha(before),sha(candidate)],(name,side,'Baseline changed')
            a,b=read(before),read(candidate)
            assert a.keys()==b.keys()
            assert all(a[k]==b[k] for k in a if k!='supports')
            assert b['supports'][:len(a['supports'])]==a['supports']
            ready.append((asset,candidate))
    for asset,candidate in ready:
        asset.write_bytes(candidate.read_bytes())
        assert sha(asset)==sha(candidate)
    (OUTPUT/'installation.json').write_text(json.dumps(dict(status='installed',
        files=[dict(asset=str(a),sha256=sha(a)) for a,_ in ready]),indent=2))
    print(len(ready),'verified assets installed')


if __name__=='__main__':install()
