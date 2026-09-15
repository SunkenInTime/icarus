"""Measure the worst frozen cone without changing its geometry or event policy."""
import ctypes
import hashlib
import json
import math
import numpy as np
from compile_redundant_section_seeds import REV
from probe_source_floor_regressions import source_model
from probe_moving_floor_cones import seed_angles
from verify_native_floor_atlas import NativeAtlas
from verify_native_floor_cone import NativeCone

def run():
    previous=json.loads((REV/'native-full-cone-shared-clip-v1/split.json').read_text())
    worst=max(previous['records'],key=lambda row:row['medianNativeMilliseconds'])
    source=source_model(REV,'split',True);atlas=NativeAtlas(REV,source);cone=NativeCone(atlas,source)
    origin=np.array(worst['origin']);seeds=seed_angles(atlas.arrays,origin,worst['heading'],math.pi/2,5,True)
    reset=atlas.dll.reset_floor_profile;reset.argtypes=[ctypes.c_int]
    get_floor=atlas.dll.get_floor_profile;get_floor.argtypes=[ctypes.c_void_p]
    get_cone=atlas.dll.get_cone_profile;get_cone.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
    records=[];reference=None
    try:
        reset(0);cone.cone(origin,5,seeds)
        for enabled in [False,True,True,False,False,True,True,False]:
            reset(int(enabled));result=cone.cone(origin,5,seeds)
            floor=np.zeros(12);stages=np.zeros(5);get_floor(floor.ctypes.data);get_cone(cone.handle,stages.ctypes.data)
            if reference is None:reference=result['mesh'].copy()
            difference=float(np.max(abs(reference-result['mesh'])))
            if difference!=0:raise AssertionError(f'Profiler changed mesh by {difference}')
            records.append(dict(enabled=enabled,nativeMilliseconds=result['nativeSeconds']*1000,queries=result['queries'],sourceFallbacks=result['sourceFallbacks'],alphaCallbacks=result['alphaCallbacks'],
                                floorMilliseconds=(floor[:4]*1000).tolist(),coneMilliseconds=(stages*1000).tolist(),counts=floor[4:].astype(int).tolist(),meshDifference=difference))
        reset(0)
        errors=[]
        for angle,distance in reference:
            oracle=atlas.cast(source,origin,[math.cos(angle),math.sin(angle)],5)
            errors.append(abs(distance-oracle['distanceMeters']))
    finally:reset(0);cone.close()
    profiled=[row for row in records if row['enabled']];unprofiled=[row for row in records if not row['enabled']]
    floor=np.median([row['floorMilliseconds'] for row in profiled],axis=0);stages=np.median([row['coneMilliseconds'] for row in profiled],axis=0)
    breakdown=dict(floorIntervalConstruction=float(floor[0]),eventSorting=float(floor[1]),eventTraversalAndFloorSelection=float(floor[2]),atlasSectionStageIncludingTimingOverhead=float(floor[3]),sourceFallback=float(stages[3]),sharedClipSetup=float(stages[1]),adaptiveValidationCacheAndMesh=float(stages[4]),otherRayDispatch=float(stages[2]-floor.sum()-stages[3]))
    output=REV/'native-full-cone-profile-v1';output.mkdir(exist_ok=True)
    report=dict(scope=__doc__,frame=worst['frame'],origin=origin.tolist(),headingRadians=worst['heading'],seeds=len(seeds),records=records,
                medianProfiledMilliseconds=float(np.median([row['nativeMilliseconds'] for row in profiled])),medianUnprofiledMilliseconds=float(np.median([row['nativeMilliseconds'] for row in unprofiled])),
                medianStageMilliseconds=breakdown,countLabels=['rayQueries','floorIntervals','floorEvents','visitedPieces','sectionTests','bvhNodeVisits','polygonEdgesOffered','activeCandidateVisits'],
                maximumVertexOracleErrorMeters=float(max(errors)),atlasSha256=hashlib.sha256((REV/'local-floor-atlas-v1/split.npz').read_bytes()).hexdigest(),nativeSha256=hashlib.sha256((REV/'native-tactical-rays-build/Release/tactical_floor_atlas.dll').read_bytes()).hexdigest(),
                sectionTimingNote='Consult sectionTests before interpreting section-stage time. This pose tests zero sections, so its section-stage measurement mainly includes empty-stage checks and per-piece clock overhead.',
                limitation='Diagnostic counters add timing overhead. Balanced same-process controls expose that overhead; this is not a quiet full-app FPS measurement. Adaptive validation here means refinement probes, not the external oracle audit.')
    (output/'split.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:value for key,value in report.items() if key!='records'}),flush=True)
if __name__=='__main__':run()
