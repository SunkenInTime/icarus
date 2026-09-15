"""Diagnostic native consumer of reviewed wall profiles, with exact ring holes."""
import ctypes,gzip,json,hashlib
from pathlib import Path
import numpy as np
from tactical_alignment_composite import explicit_warp
from authored_wall_profile_cells import frame_wall_breakpoints
FP=ctypes.POINTER(ctypes.c_double);IP=ctypes.POINTER(ctypes.c_int32);UP=ctypes.POINTER(ctypes.c_uint32)
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def pointer(a,kind=FP):return a.ctypes.data_as(kind)
class NativeProfiles:
    def __init__(self,library,points,rings,pieces,families,masks,mask_families):
        self.arrays=[np.ascontiguousarray(a,dtype=d) for a,d in [(points,float),(rings,np.int32),(pieces,float),(families,np.int32),(masks,float),(mask_families,np.int32)]]
        p,r,w,f,m,mf=self.arrays;self.mask_count=len(m)
        self.dll=ctypes.CDLL(str(library));self.dll.profile_create.argtypes=[FP,IP,ctypes.c_int,FP,IP,ctypes.c_int,FP,IP,ctypes.c_int];self.dll.profile_create.restype=ctypes.c_void_p
        self.handle=self.dll.profile_create(pointer(p),pointer(r,IP),len(r),pointer(w),pointer(f,IP),len(w),pointer(m),pointer(mf,IP),len(m))
        self.dll.profile_batch.argtypes=[ctypes.c_void_p,FP,ctypes.c_int,ctypes.c_double,ctypes.c_double,FP,FP]
        self.dll.profile_destroy.argtypes=[ctypes.c_void_p]
        self.dll.profile_bvh_batch.argtypes=[FP,UP,FP,IP,FP,ctypes.c_int,ctypes.c_double,ctypes.c_double,FP]
    def close(self):
        if self.handle:self.dll.profile_destroy(self.handle);self.handle=None
    def cast(self,queries,minimum=1e-5,padding=1e-5):
        queries=np.ascontiguousarray(queries,dtype=float);out=np.empty((len(queries),4));masks=np.empty((len(queries),self.mask_count))
        self.dll.profile_batch(self.handle,pointer(queries),len(queries),minimum,padding,pointer(out),pointer(masks));return out,masks
    def bvh(self,source,queries,minimum=1e-5,padding=1e-5):
        queries=np.ascontiguousarray(queries,dtype=float);out=np.empty((len(queries),4));a=source.arrays
        self.dll.profile_bvh_batch(pointer(a['vertices']),pointer(a['faces'],UP),pointer(a['bounds']),pointer(a['nodes'],IP),pointer(queries),len(queries),minimum,padding,pointer(out));return out

def compile_input(data,warp):
    matrix=np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']));origin=np.array(warp['projection']['origin']);inv=np.linalg.inv(matrix)
    source_svg=np.array(warp['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target_svg=np.array(warp['targetAttackSvg']).reshape(-1,2)
    backward=explicit_warp(target_svg,source_svg-target_svg,np.array(warp['triangles']).reshape(-1,3))
    points=[];rings=[];pieces=[];piece_families=[];masks=[];mask_families=[];references=[]
    for fi,f in enumerate(data['families']):
        region=f['opaqueRegion'];polygons=region['coordinates'] if region['type']=='MultiPolygon' else [region['coordinates']]
        for pi,polygon in enumerate(polygons):
            for hi,ring in enumerate(polygon):
                rings.append([fi,pi,int(hi>0),len(points),len(ring)]);points.extend(ring)
        for mask in f['maskedProfiles']:
            masks.append(mask['profile']);mask_families.append(fi);references.append(dict(family=fi,edge=f['edge'],**mask))
        lo,hi=f['targetAlong'];breaks=[lo,*frame_wall_breakpoints(backward,f['targetFrame'],lo,hi),hi]
        frame=f['targetFrame'];xy=np.array(frame['origin'])+np.array(breaks)[:,None]*np.array(frame['tangent']);native=(backward.apply(xy)-origin)@inv.T
        for i in range(len(breaks)-1):pieces.append([*native[i],*native[i+1],breaks[i],breaks[i+1]]);piece_families.append(fi)
    arrays=[np.asarray(points,float),np.asarray(rings,np.int32),np.asarray(pieces,float),np.asarray(piece_families,np.int32),np.asarray(masks,float).reshape(-1,3,2),np.asarray(mask_families,np.int32)]
    return arrays,references,(backward,matrix,origin)
