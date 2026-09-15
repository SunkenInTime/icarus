"""Freeze nearby angular floor-ray disagreements and their exact piece contacts."""
import json
from pathlib import Path
import numpy as np
from probe_source_floor_regressions import load_support, source_model
from verify_native_floor_atlas import NativeAtlas

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
def run():
    data = json.loads((REV/'moving-floor-cone-probe-v1/frame6-seeds-False.json').read_text())
    print(list(data), flush=True)
    pairs = np.array(data['samples'] if 'samples' in data else data['allSamples'])
    near = np.flatnonzero((np.diff(pairs[:,0]) < np.deg2rad(1e-5)) & (abs(np.diff(pairs[:,1])) > 1))
    selected = sorted(set([int(i) for i in near[:2]] + [int(i+1) for i in near[:2]]))
    source=source_model(REV,'split',True); atlas=NativeAtlas(REV,source); support=load_support(REV,'split',True)
    print('hit triangles',source.arrays['vertices'][source.arrays['faces'][[713752,713753]]].tolist(),flush=True)
    origin=np.array([20.599371111492427,39.51257844288108,6.781631480113873])
    results=[]
    for i in selected:
        angle=float(pairs[i,0]); direction=np.array([np.cos(angle),np.sin(angle)])
        actual=atlas.cast(source,origin,direction,5)
        expected=support.cast(source,origin,direction,5,True,True,True,.35,True)
        probes=[]; global_hits=[]
        for row in actual['rows']:
            lo,hi,g0,g1,cell,hit,face,fallback=row
            plane=atlas.arrays['planes'][int(cell)] if cell>=0 else np.array([0,0,g0])
            start=np.r_[origin[:2],plane@np.r_[origin[:2],1]+1.75]
            end=np.r_[origin[:2]+direction*5,plane@np.r_[origin[:2]+direction*5,1]+1.75]
            factor=np.linalg.norm(end-start)/5
            found=source.cast(start,end,min_distance=lo*factor,end_padding=(5-hi)*factor)
            if found:global_hits.append(dict(row=row.tolist(),hit=found,globalDistance=found['distanceMeters']/factor))
        for row in actual['rows']:
            lo,hi,g0,g1,cell,hit,face,fallback=row
            if not 1.7 < hi < 1.85 and not 1.7 < lo < 1.85: continue
            a=np.r_[origin[:2]+direction*lo,g0+1.75]; b=np.r_[origin[:2]+direction*hi,g1+1.75]
            delta=b-a; length=np.linalg.norm(delta)
            normal=source.cast(a,b,min_distance=0,end_padding=0)
            extended=source.cast(a-delta/length*1e-7,b+delta/length*1e-7,min_distance=0,end_padding=0)
            probes.append(dict(row=row.tolist(),length=float(length),normal=normal,extended=extended))
        results.append(dict(angle=angle,oldDistance=float(pairs[i,1]),actual={**actual,'rows':actual['rows'].tolist()},expected=expected,probes=probes,globalHits=global_hits))
        print('global',[(h['globalDistance'],h['hit']['face']) for h in global_hits],flush=True)
        d=(21.5-origin[0])/direction[0]; print('xwall',d,(origin[:2]+d*direction).tolist(),flush=True)
        print(angle,actual['distanceMeters'],expected['distanceMeters'],[(p['length'],p['normal'] and p['normal']['face'],p['extended'] and p['extended']['face']) for p in probes],flush=True)
    (REV/'moving-floor-cone-probe-v1/flicker-piece-diagnostic.json').write_text(json.dumps(results,indent=2)+'\n')

if __name__=='__main__':run()
