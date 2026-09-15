"""Differential checks of the isolated native convex sector clip primitive."""
import ctypes,json,math
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import sha
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
LIB=REV/'native-floor-sectors-lazy-build/build/Release/floor_sectors.dll'
class NativeSector:
    def __init__(self):
        self.dll=ctypes.CDLL(str(LIB));self.fn=self.dll.probe_floor_sector_clip;self.fn.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
    def clips(self,polygon,origin,directions,enabled):
        polygon=np.ascontiguousarray(polygon,float);origin=np.ascontiguousarray(origin,float);directions=np.ascontiguousarray(directions,float);output=np.zeros((len(directions),4))
        self.fn(polygon.ctypes.data,len(polygon),origin.ctypes.data,directions.ctypes.data,len(directions),int(enabled),output.ctypes.data);return output

def verify():
    model=NativeSector();atlas_path=REV/'local-floor-atlas-v1/split.npz';a=np.load(atlas_path);frozen_path=REV/'moving-floor-cone-global-interval-v2/split.json';frozen=json.loads(frozen_path.read_text());rng=np.random.default_rng(983172);queries=positive=fast=before_edges=after_edges=0;failures=[]
    for origin_index,row in enumerate(frozen['records']):
        origin=np.array(row['origin'][:2])
        for cell,(first,size) in enumerate(a['polygonRanges']):
            if size<8:continue
            polygon=a['polygons'][first:first+size];center=polygon.mean(0)-origin;angles=list(rng.uniform(0,2*math.pi,12))+[math.atan2(center[1],center[0])]
            for v in polygon[[0,size//2,size-1]]-origin:
                angle=math.atan2(v[1],v[0]);angles.extend(angle+d for d in [0,-1e-13,1e-13,-1e-9,1e-9])
            directions=np.array([[math.cos(x)*150,math.sin(x)*150] for x in angles]);old=model.clips(polygon,origin,directions,False);new=model.clips(polygon,origin,directions,True)
            valid=old[:,1]>=old[:,0];other=new[:,1]>=new[:,0];bad=(valid!=other)|(valid&np.any(old[:,:2]!=new[:,:2],axis=1));queries+=len(old);positive+=int(valid.sum());fast+=int(new[:,2].sum());before_edges+=int(old[:,3].sum());after_edges+=int(new[:,3].sum())
            for index in np.flatnonzero(bad):failures.append(dict(origin=origin_index,cell=int(cell),query=int(index),angle=angles[index],old=old[index].tolist(),new=new[index].tolist()))
    report=dict(queries=queries,positiveIntervals=positive,indexedQueries=fast,ordinaryEdgesTested=before_edges,indexedEdgesTested=after_edges,failures=failures,atlasSha256=sha(atlas_path),frozenSha256=sha(frozen_path),librarySha256=sha(LIB),productionMutation=False)
    path=REV/'native-floor-sectors-lazy-v1/interval-differential.json';path.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='failures'},indent=2));assert not failures
if __name__=='__main__':verify()
