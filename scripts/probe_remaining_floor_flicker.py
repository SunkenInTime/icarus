"""Inspect residual interval boundary contacts after global affine casting."""
import json
import numpy as np
from probe_global_piece_cast import REV
from probe_source_floor_regressions import source_model,load_support
from verify_native_floor_atlas import NativeAtlas
def run():
    source=source_model(REV,'split',True);atlas=NativeAtlas(REV,source);support=load_support(REV,'split',True)
    origin=np.array([20.599371111492427,39.51257844288108,6.781631480113873])
    angles=[5.273830805638859,5.2738308085646946,5.273830811490531]
    output=[]
    for angle in angles:
        direction=np.array([np.cos(angle),np.sin(angle)])
        result=atlas.cast(source,origin,direction,5)
        expected=support.cast(source,origin,direction,5,True,True,True,.35,True)
        pieces=[]
        for row in result['rows']:
            lo,hi,g0,g1,cell,hit,face,fallback=row
            if lo>1.692 or hi<1.690:continue
            plane=atlas.arrays['planes'][int(cell)] if cell>=0 else np.array([0,0,g0])
            a=np.r_[origin[:2],plane@np.r_[origin[:2],1]+1.75];b=np.r_[origin[:2]+direction*5,plane@np.r_[origin[:2]+direction*5,1]+1.75]
            scale=np.linalg.norm(b-a)/5
            nearby=source.cast(a,b,min_distance=max(0,lo*scale-1e-7),end_padding=max(0,(5-hi)*scale-1e-7),end_inclusive=True)
            pieces.append(dict(row=row.tolist(),plane=plane.tolist(),nearby=nearby,nearbyHorizontalDistance=None if nearby is None else nearby['distanceMeters']/scale))
        output.append(dict(angle=angle,native={**result,'rows':result['rows'].tolist()},expected=expected,pieces=pieces))
        print(angle,result['distanceMeters'],expected['distanceMeters'],[(p['row'][:2],p['nearbyHorizontalDistance']) for p in pieces],flush=True)
    (REV/'moving-floor-cone-probe-v1/remaining-global-interval-flicker.json').write_text(json.dumps(output,indent=2)+'\n')
if __name__=='__main__':run()
