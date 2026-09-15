"""Resolve original source ownership for changed corner rays, without edits."""
import json,gzip
from pathlib import Path
import numpy as np
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def main():
    folder=REV/'split-wall-family-normalized-candidate-v14';report=json.loads((folder/'independent-junction-rays.json').read_text());proof=json.loads((folder/'bindings.json').read_text())
    selected=[r for r in report['records'] if r['svgEdge'] in [86,91,97] and (r['status']=='early-unbound-hit' or (r['status']=='no-candidate-hit' and r['sourceOriginallyBlocked']))]
    old=NativeReferenceModel(Path(proof['sourceBackup']),REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    full=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'][full];parents=np.load(folder/'correspondence.npz')['sourceFaces'];meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix);before=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;after=np.array(w['targetAttackSvg']).reshape(-1,2);back=explicit_warp(after,before-after,np.array(w['triangles']).reshape(-1,3))
    records=[]
    for r in selected:
        xy=(back.apply(np.array([r['startSvg'],r['finishSvg']]))-origin)@inverse.T;z=r['relativeEyeHeightMeters'];hit=old.cast(np.r_[xy[0],z],np.r_[xy[1],z]);row=dict(r)
        if hit is not None:
            rawid=int(original[hit['face']]);obj=int(np.searchsorted(starts,rawid,side='right')-1);row['oldHit']=dict(hit,rawSourceFace=rawid,sourceObjectIndex=obj,sourceObject=meta['objects'][obj])
        if r.get('face') is not None:
            parent=int(parents[r['face']]);rawid=int(original[parent]);obj=int(np.searchsorted(starts,rawid,side='right')-1);row['candidateSource']=dict(controlParent=parent,rawSourceFace=rawid,sourceObjectIndex=obj,sourceObject=meta['objects'][obj])
        records.append(row)
    (folder/'changed-tower-junction-source-traces.json').write_text(json.dumps(dict(scope='Exact source ownership, not automatic semantic acceptance',records=records),indent=2))
    for r in records:
        if r['status']=='no-candidate-hit':print(r['relativeEyeHeightMeters'],r['oldHit']['rawSourceFace'],r['oldHit']['sourceObjectIndex'],r['oldHit']['point'])
    print('new early source groups',sorted({(r['svgEdge'],r['candidateSource']['sourceObjectIndex'],r['candidateSource']['rawSourceFace']) for r in records if 'candidateSource' in r}))

if __name__=='__main__':main()
