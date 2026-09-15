"""Control endpoint reconstruction by casting full affine lines with piece bounds."""
import json
from pathlib import Path
import numpy as np
from probe_source_floor_regressions import source_model
from verify_native_floor_atlas import NativeAtlas
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')

def cast_rows(source,atlas,origin,direction,rows,distance=5):
    best=distance; face=None
    for lo,hi,g0,g1,cell,hit,oldface,fallback in rows:
        if lo>best:break
        plane=atlas.arrays['planes'][int(cell)] if cell>=0 else np.array([0.,0.,g0])
        a=np.r_[origin[:2],plane@np.r_[origin[:2],1]+1.75]
        b=np.r_[origin[:2]+direction*distance,plane@np.r_[origin[:2]+direction*distance,1]+1.75]
        scale=np.linalg.norm(b-a)/distance
        value=source.cast(a,b,min_distance=lo*scale,end_padding=(distance-hi)*scale)
        if value and value['distanceMeters']/scale<best:best=value['distanceMeters']/scale;face=value['face']
    return best,face

def run():
    data=json.loads((REV/'moving-floor-cone-probe-v1/frame6-seeds-False.json').read_text())
    samples=np.array(data['samples']); source=source_model(REV,'split',True);atlas=NativeAtlas(REV,source)
    origin=np.array([20.599371111492427,39.51257844288108,6.781631480113873])
    samples=samples[(samples[:,0]>5.24943863)&(samples[:,0]<5.2494407)]
    output=[]; actual_distances=[]
    for angle,old in samples:
        direction=np.array([np.cos(angle),np.sin(angle)]);native=atlas.cast(source,origin,direction,5)
        actual_distances.append(native['distanceMeters'])
        value,face=cast_rows(source,atlas,origin,direction,native['rows'])
        output.append([float(angle),float(old),value,face])
    a=np.array([r[:3] for r in output]); result=dict(rows=output,oldJumps=int(sum(abs(np.diff(a[:,1]))>.01)),newJumps=int(sum(abs(np.diff(a[:,2]))>.01)),nativeJumps=int(sum(abs(np.diff(actual_distances))>.01)),maximumNativeDifference=float(np.max(abs(a[:,2]-actual_distances))))
    (REV/'moving-floor-cone-probe-v1/global-piece-fixed-replay.json').write_text(json.dumps(result,indent=2))
    print(len(output),result['oldJumps'],result['newJumps'],flush=True)
    print(result['nativeJumps'],result['maximumNativeDifference'],flush=True)
if __name__=='__main__':run()
