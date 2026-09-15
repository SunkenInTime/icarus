"""Discard zero-area encoding remnants on both sides of a new standing mask."""
import argparse
import gzip
import json
import numpy as np
from build_all_physical_standing_surfaces import MAPS, OUTPUT, read, sha


def area(ring):
    p=np.asarray(ring).reshape(-1,2);p=p-p[0]
    return sum(float(a[0]*b[1]-a[1]*b[0]) for a,b in zip(p,np.roll(p,-1,axis=0)))/2


def clean(name):
    directory=OUTPUT/name
    models={s:read(directory/f'candidate-{s}.json.gz') for s in ['attack','defense']}
    lookup={s:{r['id']:r for r in m['supports']} for s,m in models.items()}
    before={s['id'] for s in read(directory/'before-attack.json.gz')['supports']}
    removed=[]
    for sid,a in lookup['attack'].items():
        if sid in before:continue
        b=lookup['defense'][sid]
        bad=[i for i,(x,y) in enumerate(zip(a['rings'],b['rings'])) if area(x)==0 or area(y)==0]
        if not bad:continue
        assert all(abs(area(r['rings'][i]))<1e-10 for r in [a,b] for i in bad)
        removed.append(dict(supportId=sid,ringIndices=bad,areas=[area(a['rings'][i]) for i in bad]))
        for r in [a,b]:
            r['rings']=[ring for i,ring in enumerate(r['rings']) if i not in bad]
            assert r['rings']
    if not removed:return
    report=read(directory/'physical-top-build.json')
    report.setdefault('degenerateEncodingRingsRemoved',[]).extend(removed)
    for side,model in models.items():
        path=directory/f'candidate-{side}.json.gz'
        path.write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
        report['candidateSha256'][side]=sha(path)
    (directory/'physical-top-build.json').write_text(json.dumps(report,separators=(',',':')))
    print(name,removed,flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
    for name in p.parse_args().maps:clean(name)
