"""Preserve attack ring correspondence when encoding mirrored supplement masks."""
import argparse
import gzip
import json
import numpy as np
from build_all_physical_standing_surfaces import OUTPUT, ROOT, read, sha


def normalize(name):
    directory=OUTPUT/name
    report=read(directory/'physical-top-build.json')
    changed=set(report.get('groundOverlapSupplement',{}).get('changedSupports',[]))
    if not changed:return
    attack=read(directory/'candidate-attack.json.gz')
    defense=read(directory/'candidate-defense.json.gz')
    a=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
    first=np.asarray(a['nativeToAttackSvg']);second=np.asarray(a['nativeToDefenseSvg'])
    linear=second[:,:2]@np.linalg.inv(first[:,:2]);shift=second[:,2]-linear@first[:,2]
    source={s['id']:s for s in attack['supports']}
    for s in defense['supports']:
        if s['id'] in changed:
            s['rings']=[(np.asarray(r).reshape(-1,2)@linear.T+shift).reshape(-1).tolist()
                        for r in source[s['id']]['rings']]
    path=directory/'candidate-defense.json.gz'
    path.write_bytes(gzip.compress(json.dumps(defense,separators=(',',':'),allow_nan=False).encode(),mtime=0))
    report['candidateSha256']['defense']=sha(path)
    (directory/'physical-top-build.json').write_text(json.dumps(report,separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='+')
    for name in p.parse_args().maps:normalize(name)
