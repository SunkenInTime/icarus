"""Isolated traversal regressions; no source coordinates or hit predicates change."""
import ctypes,json,math,unittest
from fractions import Fraction
from pathlib import Path
import numpy as np
from native_reference_cast import NativeReferenceModel

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
DLL=REV/'native-rounded-profile-oracle-build/build/Release/rounded_profile_oracle.dll'

class RoundedTraversalTest(unittest.TestCase):
    def test_slab_contains_exact_input_interval_arithmetic(self):
        dll=ctypes.CDLL(str(DLL));fn=dll.reference_slab_interval
        fn.argtypes=[ctypes.c_double]*4+[ctypes.POINTER(ctypes.c_double)]
        rng=np.random.default_rng(4719)
        cases=[(1.,1.,1.,1.),(-1.,-1.,-1.,-1.),(64.,np.nextafter(64.,np.inf),64.,.003)]
        for _ in range(3000):
            origin=float(rng.uniform(-1000,1000));lo=float(origin+rng.uniform(-100,100));hi=float(lo+10**rng.uniform(-13,2));direction=float(rng.uniform(-1,1))
            cases.append((lo,hi,origin,direction))
        for lo,hi,origin,direction in cases:
            result=np.empty(2);fn(lo,hi,origin,direction,result.ctypes.data_as(ctypes.POINTER(ctypes.c_double)))
            f=lambda x:Fraction.from_float(float(x))
            dl=f(np.nextafter(lo,-np.inf))-f(np.nextafter(origin,np.inf))
            dh=f(np.nextafter(hi,np.inf))-f(np.nextafter(origin,-np.inf))
            vl=f(np.nextafter(direction,-np.inf));vh=f(np.nextafter(direction,np.inf))
            exact=[n/d for n in [dl,dh] for d in [vl,vh]]
            self.assertLessEqual(f(result[0]),min(exact))
            self.assertGreaterEqual(f(result[1]),max(exact))

    def test_saved_inverse_w_join_hits_unchanged_face(self):
        folder=REV/'root-generalized-source-world-probes-v1/case-2-split'
        q=np.array(json.loads((folder/'root-failed-point-source-triangles.json').read_text())['query'])
        pack=REV/'root-generalized-source-world-profiles-v1/case-2-split/oracle/split.height.bin.gz'
        old=NativeReferenceModel(pack,REV/'native-wall-profiles-build/Release/compact_wall_profiles.dll')
        new=NativeReferenceModel(pack,DLL)
        for start,end in [(q[:3],q[3:]),(q[3:],q[:3])]:
            self.assertIsNone(old.cast(start,end))
            hit=new.cast(start,end)
            self.assertIsNotNone(hit);self.assertIn(hit['face'],[427,476])
            self.assertLess(abs(hit['distanceMeters']-.00025577931599),1e-12)

if __name__=='__main__':unittest.main()
