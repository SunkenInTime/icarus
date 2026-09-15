"""Isolate strict BVH slab rejection from the unchanged native triangle predicate."""
import ctypes,json,math
from pathlib import Path
import numpy as np
from native_reference_cast import NativeReferenceModel
from native_compact_wall_profiles import sha
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');folder=REV/'root-generalized-source-world-probes-v1/case-2-split';trace=json.loads((folder/'root-failed-point-source-triangles.json').read_text());pack=REV/'root-generalized-source-world-profiles-v1/case-2-split/oracle/split.height.bin.gz';lib=REV/'native-wall-profiles-build/Release/compact_wall_profiles.dll';source=NativeReferenceModel(pack,lib);a=source.arrays;fp=ctypes.POINTER(ctypes.c_double);ip=ctypes.POINTER(ctypes.c_int32);up=ctypes.POINTER(ctypes.c_uint32)
a['bounds']=a['bounds'].copy();source.pointers[2]=a['bounds'].ctypes.data_as(fp)
parents={int(child):i for i,row in enumerate(a['nodes']) if row[1]==0 for child in row[2:4]};rows=[]
for sign in [1,-1]:
 q=np.array(trace['query']);start=q[:3] if sign==1 else q[3:];end=q[3:] if sign==1 else q[:3];d=end-start;length=math.sqrt(d[0]*d[0]+d[1]*d[1]+d[2]*d[2]);d/=length
 for face in [427,476]:
  leaf=next(i for i,node in enumerate(a['nodes']) if node[1]>0 and node[0]<=face<node[0]+node[1]);path=[leaf]
  while path[-1] in parents:path.append(parents[path[-1]])
  path.reverse();slabs=[]
  for node in path:
   box=a['bounds'][node];lo=0.;hi=length;valid=True;axes=[]
   for axis in range(3):
    if abs(d[axis])<1e-15:
     if start[axis]<box[axis] or start[axis]>box[axis+3]:valid=False
     axes.append(dict(axis=axis,parallel=True,valid=valid))
    else:
     t1=(box[axis]-start[axis])/d[axis];t2=(box[axis+3]-start[axis])/d[axis];lo=max(lo,min(t1,t2));hi=min(hi,max(t1,t2));valid=hi>=lo;axes.append(dict(axis=axis,low=float(lo),high=float(hi),gapMeters=float(lo-hi),valid=valid))
    if not valid:break
   slabs.append(dict(node=int(node),bounds=box.tolist(),valid=valid,axes=axes))
   if not valid:break
  # Keep the exact native triangle code; remove only traversal's opportunity to reject it.
  bounds=np.array([[-1e9]*3+[1e9]*3],float);nodes=np.array([[face,1,-1,-1]],np.int32);out=np.zeros(3);ex=np.array([-1],np.int32)
  result=source.nearest(a['vertices'].ctypes.data_as(fp),a['faces'].ctypes.data_as(up),bounds.ctypes.data_as(fp),nodes.ctypes.data_as(ip),start.ctypes.data_as(fp),end.ctypes.data_as(fp),1e-5,1e-5,0,ex.ctypes.data_as(ip),0,out.ctypes.data_as(fp))
  rows.append(dict(side=sign,face=face,directNativeFace=int(result),directNativeDistance=float(out[0]),directNativeBary=[float(1-out[1]-out[2]),float(out[1]),float(out[2])],slabPath=slabs))
 original=a['bounds'].copy();trials=[]
 try:
  for ulps in [0,1,2,4,8]:
   a['bounds'][:]=original
   for _ in range(ulps):a['bounds'][:,:3]=np.nextafter(a['bounds'][:,:3],-np.inf);a['bounds'][:,3:]=np.nextafter(a['bounds'][:,3:],np.inf)
   hit=source.cast(start,end);trials.append(dict(boundUlpsOutward=ulps,hit=hit))
 finally:a['bounds'][:]=original
 rows.append(dict(side=sign,boundsOnlyTrials=trials))
report=dict(scope=__doc__,oraclePackSha256=sha(pack),nativeLibrarySha256=sha(lib),query=trace['query'],rows=rows,productionMutation=False);path=folder/'independent-native-bvh-slab-diagnosis.json';path.write_text(json.dumps(report,indent=2,default=lambda value:value.item())+'\n');print(json.dumps(report,indent=2,default=lambda value:value.item()))
