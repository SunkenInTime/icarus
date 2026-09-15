"""Measure a single native cone call against the frozen per-ray diagnostic.

The adaptive policy is unchanged and does not certify angular completeness.
Opaque source fallbacks stay native; exact alpha sampling calls Python only
when the nearest source face is masked.
"""
import ctypes
import hashlib
import json
import math
from pathlib import Path
import time
import numpy as np
from probe_source_floor_regressions import source_model
from verify_native_floor_atlas import NativeAtlas
from probe_moving_floor_cones import seed_angles,radial_chord
from world_visibility_ray_reference import sample_alpha

KEYS=['polygons','polygonRanges','planes','originalTriangles','sourceFaces','terrain','segments','segmentRanges','segmentFaces','segmentEndpointClosed','endpointTolerance','fallback','bvhBounds','bvhNodes','bvhCells','transitPolygons','transitRanges','transitGroups','transitSheets','transitCellGroups','transitAdjacency']
class NativeCone:
    def __init__(self,atlas,source):
        self.atlas=atlas;self.source=source;self.error=None;self.dll=atlas.dll
        callback_type=ctypes.CFUNCTYPE(ctypes.c_int,ctypes.c_int,ctypes.c_double,ctypes.c_double)
        def alpha(face,u,v):
            try:
                mask=int(source.arrays['faceMasks'][face]);material=source.materials[int(source.arrays['maskedMaterials'][mask])]
                uv=np.array([1-u-v,u,v])@source.arrays['maskedUvs'][mask]
                return int(sample_alpha(source.textures[material['texture']],uv,material)>=material['threshold'])
            except Exception as error:self.error=error;return -1
        self.callback=callback_type(alpha)
        pointers=(ctypes.c_void_p*len(KEYS))(*(atlas.arrays[key].ctypes.data for key in KEYS))
        self.source_arrays=[np.ascontiguousarray(source.arrays[key],dtype=dtype) for key,dtype in [('vertices',np.float64),('faces',np.uint32),('bounds',np.float64),('nodes',np.int32),('faceMasks',np.int32)]]
        source_pointers=(ctypes.c_void_p*5)(*(array.ctypes.data for array in self.source_arrays))
        create=self.dll.create_floor_cone;create.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p,callback_type];create.restype=ctypes.c_void_p
        self.handle=create(len(atlas.arrays['planes']),len(atlas.arrays['transitRanges']),pointers,source_pointers,self.callback)
        if not self.handle:raise RuntimeError('Native cone allocation failed')
        self.build=self.dll.build_floor_cone;self.build.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_double,ctypes.c_void_p,ctypes.c_int,ctypes.c_double,ctypes.c_int,ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p];self.build.restype=ctypes.c_int
        self.buffer=np.empty((20000,2));self.stats=np.empty(6)
    def close(self):
        if self.handle:
            self.dll.destroy_floor_cone.argtypes=[ctypes.c_void_p];self.dll.destroy_floor_cone(self.handle);self.handle=None
    def cone(self,origin,distance,seeds,tolerance=.01,maximum_queries=4096):
        origin=np.ascontiguousarray(origin,dtype=float);seeds=np.ascontiguousarray(seeds,dtype=float)
        if origin.shape!=(3,) or len(seeds)<2 or not np.isfinite(origin).all() or not np.isfinite(seeds).all() or not np.all(np.diff(seeds)>0) or distance<=0:raise ValueError('Invalid diagnostic cone inputs')
        start=time.perf_counter();count=self.build(self.handle,origin.ctypes.data,distance,seeds.ctypes.data,len(seeds),tolerance,maximum_queries,self.buffer.ctypes.data,len(self.buffer),self.stats.ctypes.data)
        if self.error:raise self.error
        if count<0:raise RuntimeError(f'Native cone failed {count}')
        return dict(mesh=self.buffer[:count].copy(),wallSeconds=time.perf_counter()-start,queries=int(self.stats[0]),sourceFallbacks=int(self.stats[1]),alphaCallbacks=int(self.stats[2]),pieces=int(self.stats[3]),limited=bool(self.stats[4]),nativeSeconds=float(self.stats[5]))

def run(revision,output_name='native-full-cone-probe-v1'):
    source=source_model(revision,'split',True);atlas=NativeAtlas(revision,source);cone=NativeCone(atlas,source)
    frozen=json.loads((revision/'moving-floor-cone-global-interval-v2/split.json').read_text());reports=[]
    try:
        for old in frozen['records']:
            origin=np.array(old['origin']);heading=old['headingRadians'];seeds=seed_angles(atlas.arrays,origin,heading,math.pi/2,5,True)
            # One warm-up then three measured repetitions of the same native call.
            cone.cone(origin,5,seeds)
            runs=[cone.cone(origin,5,seeds) for _ in range(3)];result=runs[-1];mesh=result['mesh'];errors=[]
            for angle,distance in mesh:
                oracle=atlas.cast(source,origin,[math.cos(angle),math.sin(angle)],5)
                errors.append(abs(distance-oracle['distanceMeters']))
            probes=heading-math.pi/4+(np.arange(128)+.38196601125)/128*math.pi/2;mesh_errors=[]
            for angle in probes:
                index=max(0,min(len(mesh)-2,int(np.searchsorted(mesh[:,0],angle)-1)))
                predicted=radial_chord(*mesh[index],*mesh[index+1],angle)
                oracle=atlas.cast(source,origin,[math.cos(angle),math.sin(angle)],5)
                mesh_errors.append(abs(predicted-oracle['distanceMeters']))
            record=dict(frame=old['frame'],origin=origin.tolist(),heading=heading,seeds=len(seeds),queries=result['queries'],frozenQueries=old['variants'][0]['queryCount'],sourceFallbacks=result['sourceFallbacks'],alphaCallbacks=result['alphaCallbacks'],pieces=result['pieces'],limited=result['limited'],medianNativeMilliseconds=float(np.median([r['nativeSeconds'] for r in runs])*1000),maximumVertexOracleErrorMeters=max(errors),maximumSampledMeshErrorMeters=max(mesh_errors),samplesAboveTolerance=sum(e>.01 for e in mesh_errors),mesh=mesh.tolist())
            reports.append(record);print({k:v for k,v in record.items() if k!='mesh'},flush=True)
    finally:cone.close()
    output=revision/output_name;output.mkdir(exist_ok=True)
    report=dict(scope=__doc__,nativeSha256=hashlib.sha256((revision/'native-tactical-rays-build/Release/tactical_floor_atlas.dll').read_bytes()).hexdigest(),records=reports,productionAcceptance=False,
                limitations=['Frozen adaptive sampling policy is unchanged; angular events are not exhaustively compiled.','Repeated ray traversal remains inside the native call, so this is not an angular beam traversal.','Only the bounded local Split atlas and eight moving Clove poses are measured.','Timings are diagnostic native call measurements, not quiet whole-app high-refresh performance.'])
    (output/'split.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('revision',type=Path);parser.add_argument('--output-name',default='native-full-cone-probe-v1');args=parser.parse_args();run(args.revision,args.output_name)
