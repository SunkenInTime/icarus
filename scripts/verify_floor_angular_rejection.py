"""Balanced angular-gate control with exact mesh and query-count preservation."""
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
    source=source_model(REV,'split',True);atlas=NativeAtlas(REV,source);cone=NativeCone(atlas,source)
    toggle=atlas.dll.set_floor_angular_rejection;toggle.argtypes=[ctypes.c_int]
    counts=atlas.dll.get_floor_angular_counts;counts.argtypes=[ctypes.c_void_p]
    reset=atlas.dll.reset_floor_profile;reset.argtypes=[ctypes.c_int]
    get_profile=atlas.dll.get_floor_profile;get_profile.argtypes=[ctypes.c_void_p]
    frozen=json.loads((REV/'native-full-cone-shared-clip-v1/split.json').read_text());comparisons=[];timings=[];profiles=[]
    try:
        for row in frozen['records']:
            origin=np.array(row['origin']);seeds=seed_angles(atlas.arrays,origin,row['heading'],math.pi/2,5,True)
            toggle(0);before=cone.cone(origin,5,seeds)
            toggle(1);after=cone.cone(origin,5,seeds);a=np.zeros(3);counts(a.ctypes.data)
            assert before['queries']==after['queries']
            assert np.array_equal(before['mesh'],after['mesh'])
            comparisons.append(dict(frame=row['frame'],queries=after['queries'],meshDifference=0,eligibleAngularChecks=int(a[0]),rejectedPolygons=int(a[1]),certifiedPolygons=int(a[2])))
        worst=max(frozen['records'],key=lambda row:row['medianNativeMilliseconds']);origin=np.array(worst['origin']);seeds=seed_angles(atlas.arrays,origin,worst['heading'],math.pi/2,5,True)
        for enabled in [False,True,True,False,False,True,True,False]:
            toggle(int(enabled));result=cone.cone(origin,5,seeds);a=np.zeros(3);counts(a.ctypes.data)
            timings.append(dict(enabled=enabled,milliseconds=result['nativeSeconds']*1000,counts=a.astype(int).tolist()))
        for enabled in [False,True]:
            reset(1);toggle(int(enabled));result=cone.cone(origin,5,seeds);profile=np.zeros(12);get_profile(profile.ctypes.data)
            profiles.append(dict(enabled=enabled,profile=profile.tolist()))
    finally:reset(0);toggle(0);cone.close()
    output=REV/'floor-angular-rejection-v1';output.mkdir(exist_ok=True)
    report=dict(comparisons=comparisons,worstFrame=worst['frame'],timings=timings,profiles=profiles,
                medianOffMilliseconds=float(np.median([r['milliseconds'] for r in timings if not r['enabled']])),medianOnMilliseconds=float(np.median([r['milliseconds'] for r in timings if r['enabled']])),
                nativeSha256=hashlib.sha256((REV/'native-tactical-rays-build/Release/tactical_floor_atlas.dll').read_bytes()).hexdigest(),
                scope='Conservative observer-local angular rejection before unchanged polygon clipping. Uncertain, tangent, wrap and origin-inside cases retain the ordinary clip. All8 mesh arrays and query counts must match bit-for-bit.',
                limitation='Bounded diagnostic atlas and same-process timing control; no production or high-refresh acceptance.')
    (output/'split.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report),flush=True)
if __name__=='__main__':run()
