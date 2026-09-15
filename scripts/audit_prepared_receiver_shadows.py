"""Measure shared eye-plane preparation on frozen Split receiver workloads.

This is an offline CPU experiment. It neither selects floors nor integrates
the projection into the application, and it does not resolve alpha fallbacks.
"""
import argparse
import ctypes as ct
import hashlib
import json
from pathlib import Path
import time
import numpy as np
from finite_receiver_shadows import Receiver
from native_finite_shadows import NativeFiniteShadows


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
DP=ct.POINTER(ct.c_double);BP=ct.POINTER(ct.c_uint8);IP=ct.POINTER(ct.c_int32);FP=ct.POINTER(ct.c_float)


class Prepared:
    def __init__(self,path):
        self.old=NativeFiniteShadows(path);dll=self.old.library
        self.prepare=dll.finite_shadow_prepare
        self.prepare.argtypes=[DP,DP,ct.c_int,DP,BP];self.prepare.restype=ct.c_int
        self.project=dll.finite_receiver_project_prepared
        self.project.argtypes=[DP,DP,BP,ct.c_int,IP,ct.c_int,DP,ct.c_double,DP,ct.c_int,FP,ct.c_int,BP]
        self.project.restype=ct.c_int

    def prepare_group(self,eye,triangles):
        planes=np.empty((len(triangles),16),dtype=np.float64);states=np.empty(len(triangles),dtype=np.uint8)
        status=self.prepare(eye.ctypes.data_as(DP),triangles.ctypes.data_as(DP),len(triangles),planes.ctypes.data_as(DP),states.ctypes.data_as(BP))
        if status!=0:raise ValueError(status)
        return planes,states

    def project_patch(self,eye,prepared,ids,receiver):
        planes,states=prepared
        plane=np.ascontiguousarray(receiver.floor_plane,dtype=np.float64)
        footprint=np.ascontiguousarray(receiver.footprint,dtype=np.float64)
        output=np.empty(max(1,len(ids)*(len(footprint)+6)*6),dtype=np.float32)
        fallback=np.empty(len(ids),dtype=np.uint8)
        count=self.project(eye.ctypes.data_as(DP),planes.ctypes.data_as(DP),states.ctypes.data_as(BP),len(states),
            ids.ctypes.data_as(IP),len(ids),plane.ctypes.data_as(DP),receiver.standing_height,footprint.ctypes.data_as(DP),len(footprint),
            output.ctypes.data_as(FP),len(output),fallback.ctypes.data_as(BP))
        if count<0:raise ValueError(count)
        return output[:count].reshape(-1,3,2),fallback


def main(library,fixtures,out):
    if out.exists():raise FileExistsError(out)
    report_path=fixtures/'report.json';source=json.loads(report_path.read_text())
    native=Prepared(library);groups={};fixture_manifest=[]
    for record in source['records']:
        path=fixtures/(record['id']+'.npz')
        with np.load(path) as data:
            opaque=data['faceMasks']<0;eye=np.ascontiguousarray(data['observer'],dtype=np.float64)
            triangles=np.ascontiguousarray(data['sourceTriangles'][opaque],dtype=np.float64)
            ids=data['sourceFaceIds'][opaque]
            receiver=Receiver(data['receiverFootprint'].copy(),data['receiverPlane'].copy())
        group=groups.setdefault(eye.tobytes(),dict(eye=eye,faces={},patches=[]))
        for fid,tri in zip(ids,triangles):
            if int(fid) in group['faces']:np.testing.assert_array_equal(group['faces'][int(fid)],tri)
            else:group['faces'][int(fid)]=tri.copy()
        group['patches'].append(dict(id=record['id'],sourceIds=ids,triangles=triangles,receiver=receiver))
        fixture_manifest.append(dict(path=str(path),sha256=sha(path)))
    assert groups and sum(len(g['patches']) for g in groups.values())==23
    checks=[]
    for group in groups.values():
        lookup={fid:i for i,fid in enumerate(group['faces'])}
        group['triangles']=np.ascontiguousarray(list(group['faces'].values()),dtype=np.float64)
        prepared=native.prepare_group(group['eye'],group['triangles'])
        for patch in group['patches']:
            patch['ids']=np.array([lookup[int(fid)] for fid in patch['sourceIds']],dtype=np.int32)
            old,old_fallback=native.old.project(group['eye'],patch['triangles'],patch['receiver'])
            new,new_fallback=native.project_patch(group['eye'],prepared,patch['ids'],patch['receiver'])
            np.testing.assert_array_equal(old,new);np.testing.assert_array_equal(old_fallback,new_fallback)
            checks.append(dict(id=patch['id'],sourceFaces=len(patch['triangles']),outputTriangles=len(new),fallbackFaces=int((new_fallback>0).sum()),
                float32MeshBitwiseEqual=True,fallbackCodesBitwiseEqual=True,meshSha256=hashlib.sha256(new.tobytes()).hexdigest()))
    # Repeat a whole workload, including prepare/allocation/FFI for each eye.
    def baseline():
        for group in groups.values():
            for patch in group['patches']:native.old.project(group['eye'],patch['triangles'],patch['receiver'])
    def reused():
        for group in groups.values():
            prepared=native.prepare_group(group['eye'],group['triangles'])
            for patch in group['patches']:native.project_patch(group['eye'],prepared,patch['ids'],patch['receiver'])
    baseline();reused();timings={'baseline':[],'prepared':[]}
    for iteration in range(41):
        for name,fn in ([('baseline',baseline),('prepared',reused)] if iteration%2==0 else [('prepared',reused),('baseline',baseline)]):
            start=time.perf_counter();fn();timings[name].append((time.perf_counter()-start)*1000)
    stats={name:dict(p50Milliseconds=float(np.percentile(v,50)),p95Milliseconds=float(np.percentile(v,95))) for name,v in timings.items()}
    report=dict(scope=__doc__,sourceReportSha256=sha(report_path),librarySha256=sha(library),
        preparedSourceSha256=sha(Path('scripts/native_prepared_shadows/prepared.cpp')),
        baselineSourceSha256=sha(Path('scripts/native_finite_shadows/projection.cpp')),scriptSha256=sha(Path(__file__)),
        fixtures=fixture_manifest,checks=checks,observerGroups=len(groups),receiverPatches=len(checks),
        sourceFaceOccurrences=sum(c['sourceFaces'] for c in checks),uniqueFaceObserverPairs=sum(len(g['faces']) for g in groups.values()),
        maximumTemporaryPlaneTableBytes=max(len(g['faces'])*129 for g in groups.values()),
        packagedDataBytesAdded=0,timing=stats,rawTimingsMilliseconds=timings,
        scopeLimits=['Actual frozen23-patch workload, not a complete frame or map sweep.',
            'Includes fresh eye preparation and Python/FFI/output allocations. Excludes source loading, receiver selection, broadphase, source-ID grouping, alpha and exact-contact resolution, raster and compositing.',
            'No floor choice, geometry reduction, source face removal or precision change. Existing projected Float32 meshes and all fallback codes are bitwise equal.'])
    out.mkdir();(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['fixtures','checks','rawTimingsMilliseconds']},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('library',type=Path);parser.add_argument('fixtures',type=Path);parser.add_argument('out',type=Path)
    args=parser.parse_args();main(args.library,args.fixtures,args.out)
