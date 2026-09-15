"""Replay frozen profile grids with isolated rounded traversal and classify changes."""
import ctypes,json,subprocess,sys
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import sha
from native_reference_cast import NativeReferenceModel

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
out=REV/'native-rounded-world-probes-v1';dll=REV/'native-rounded-profile-oracle-build/build/Release/rounded_profile_oracle.dll'
cases=[(f'case-{i}-{m}',m,REV/f'root-generalized-source-world-profiles-v1/case-{i}-{m}',REV/f'root-generalized-source-world-probes-v1/case-{i}-{m}') for i,m in enumerate(['ascent','icebox','split','ascent'])]
cases.append(('split-v2','split',REV/'split-source-world-wall-profiles-v2',REV/'native-source-world-wall-profiles-v1'))
rows=[]
for name,map_id,folder,control in cases:
    destination=out/name
    if not destination.exists():
        subprocess.run([sys.executable,'scripts/probe_native_compact_wall_profiles.py',str(folder),str(folder/'oracle'),str(REV/f'display-warps-v1/{map_id}.display-warp.json.gz'),str(dll),str(destination)],check=True)
    old=np.load(control/'queries-results.npz');new=np.load(destination/'queries-results.npz');assert np.array_equal(old['queries'],new['queries']);assert np.array_equal(old['native'],new['native']);assert np.array_equal(old['metadata'],new['metadata'])
    a,b=old['bvh'],new['bvh'];changed=np.flatnonzero(np.any(a!=b,axis=1));visibility=np.flatnonzero((a[:,0]>=0)!=(b[:,0]>=0));eligible=~new['metadata'][:,4:6].astype(bool).any(1)
    source=NativeReferenceModel(folder/'oracle'/f'{map_id}.height.bin.gz',REV/'native-wall-profiles-build/Release/compact_wall_profiles.dll')
    fp=ctypes.POINTER(ctypes.c_double);ip=ctypes.POINTER(ctypes.c_int32);bounds=np.array([[-1e9]*3+[1e9]*3],float);excluded=np.array([-1],np.int32);direct_error=0.
    for i in changed:
        face=int(b[i,0])
        if face<0:continue
        nodes=np.array([[face,1,-1,-1]],np.int32);result=np.zeros(3);q=np.ascontiguousarray(new['queries'][i]);hit=source.nearest(*source.pointers[:2],bounds.ctypes.data_as(fp),nodes.ctypes.data_as(ip),q[:3].ctypes.data_as(fp),q[3:].ctypes.data_as(fp),1e-5,1e-5,0,excluded.ctypes.data_as(ip),0,result.ctypes.data_as(fp))
        assert hit==face,(name,int(i),face,hit)
        direct_error=max(direct_error,float(abs(result[0]-b[i,1])))
    assert direct_error<1e-12
    row=dict(case=name,queries=len(a),changedSourceResults=len(changed),changedSourceHitState=len(visibility),changedEligibleHitState=int(eligible[visibility].sum()),oldMissToNewHit=int(((a[:,0]<0)&(b[:,0]>=0)).sum()),oldHitToNewMiss=int(((a[:,0]>=0)&(b[:,0]<0)).sum()),profileResultsBitIdentical=True,changedHitsPassOriginalNativePrimitive=True,maximumChangedDirectPrimitiveDistanceError=direct_error,oldResultsSha256=sha(control/'queries-results.npz'),newResultsSha256=sha(destination/'queries-results.npz'),changes=[dict(query=int(i),old=a[i].tolist(),new=b[i].tolist(),metadata=new['metadata'][i].tolist()) for i in changed])
    rows.append(row)
(out/'comparison.json').write_text(json.dumps(dict(librarySha256=sha(dll),cases=rows,productionMutation=False),indent=2)+'\n')
print(json.dumps([{k:v for k,v in row.items() if k!='changes'} for row in rows],indent=2))
