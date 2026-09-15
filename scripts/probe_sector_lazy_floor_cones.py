"""Compare an isolated observer-local edge sector index with the same frozen cone policy."""
import ctypes,json,math,time
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import sha
from probe_source_floor_regressions import source_model
from verify_native_floor_atlas import NativeAtlas
from verify_native_floor_cone import NativeCone
from probe_moving_floor_cones import seed_angles
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
def run(output):
    source=source_model(REV,'split',True);atlas=NativeAtlas(REV,source);old_cone=NativeCone(atlas,source)
    library=REV/'native-floor-sectors-lazy-build/build/Release/floor_sectors.dll';atlas.dll=ctypes.CDLL(str(library));cone=NativeCone(atlas,source);toggle=atlas.dll.set_floor_sector_index;toggle.argtypes=[ctypes.c_int];reset=atlas.dll.reset_floor_profile;reset.argtypes=[ctypes.c_int];get_floor=atlas.dll.get_floor_profile;get_floor.argtypes=[ctypes.c_void_p];get_cone=atlas.dll.get_cone_profile;get_cone.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
    frozen=json.loads((REV/'moving-floor-cone-global-interval-v2/split.json').read_text());records=[];worst=None
    for row in frozen['records']:
        origin=np.array(row['origin']);heading=row['headingRadians'];seeds=seed_angles(atlas.arrays,origin,heading,math.pi/2,5,True);toggle(0);reference=old_cone.cone(origin,5,seeds);before=cone.cone(origin,5,seeds);toggle(1);after=cone.cone(origin,5,seeds)
        sector_counts=np.zeros(5);atlas.dll.get_floor_sector_counts.argtypes=[ctypes.c_void_p];atlas.dll.get_floor_sector_counts(sector_counts.ctypes.data)
        unchanged=np.array_equal(reference['mesh'],before['mesh']) and np.array_equal(before['mesh'],after['mesh'])
        counters=['queries','sourceFallbacks','alphaCallbacks','pieces','limited'];assert unchanged and all(reference[k]==before[k]==after[k] for k in counters),'Optimization changed cone'
        record=dict(frame=row['frame'],origin=origin.tolist(),heading=heading,seeds=len(seeds),exactMeshEqual=unchanged,**{k:after[k] for k in counters},beforeNativeMs=before['nativeSeconds']*1000,afterNativeMs=after['nativeSeconds']*1000)
        record['sectorCounts']={k:float(v) for k,v in zip(['indexedCells','indexedSectors','indexedQueries','emptySectorRejections','selectedEdgesTested'],sector_counts)}
        records.append(record)
        if row['frame']==1:worst=(before['nativeSeconds'],row,origin,seeds,reference['mesh'])
        print(record,flush=True)
    _,row,origin,seeds,mesh=worst;timings=[]
    # A bounded balanced sequence, not a whole-application FPS measurement.
    for enabled in [False,True,True,False]*3:
        toggle(int(enabled));reset(0);result=cone.cone(origin,5,seeds);assert np.array_equal(mesh,result['mesh']);timings.append(dict(enabled=enabled,nativeMs=result['nativeSeconds']*1000))
    stages=[]
    for enabled in [False,True,True,False]:
        toggle(int(enabled));reset(1);result=cone.cone(origin,5,seeds);floor=np.zeros(12);profile=np.zeros(5);get_floor(floor.ctypes.data);get_cone(cone.handle,profile.ctypes.data);assert np.array_equal(mesh,result['mesh']);stages.append(dict(enabled=enabled,nativeMs=result['nativeSeconds']*1000,floorMilliseconds=(floor[:4]*1000).tolist(),coneMilliseconds=(profile*1000).tolist(),counts=floor[4:].tolist()))
    reset(0);errors=[]
    for angle,distance in mesh[::max(1,len(mesh)//128)]:errors.append(abs(distance-atlas.cast(source,origin,[math.cos(angle),math.sin(angle)],5)['distanceMeters']))
    report=dict(scope=__doc__,librarySha256=sha(library),atlasSha256=sha(REV/'local-floor-atlas-v1/split.npz'),records=records,benchmarkFrame=row['frame'],balancedTimings=timings,profileStages=stages,mediansNativeMs={str(enabled):float(np.median([r['nativeMs'] for r in timings if r['enabled']==enabled])) for enabled in [False,True]},sampledIndependentOracleErrorMeters=max(errors),productionMutation=False,limitations=['Only the eight frozen local Split cones.','The adaptive angular policy and its known completeness limits are unchanged.','Timing is native diagnostic time, not app FPS.','No source, floor selection, event threshold, masks or geometry changes.'])
    output.mkdir(exist_ok=False);(output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['benchmarkFrame','mediansNativeMs','sampledIndependentOracleErrorMeters']},indent=2));cone.close();old_cone.close()
if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args();run(a.output)


