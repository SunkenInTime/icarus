"""Replay every frozen angle that exposed numerical floor visibility flicker."""
import hashlib
import json
import numpy as np
from probe_global_piece_cast import REV
from probe_source_floor_regressions import source_model
from verify_native_floor_atlas import NativeAtlas

def run():
    input_path=REV/'moving-floor-cone-probe-v1/frame6-seeds-False.json'
    samples=np.array(json.loads(input_path.read_text())['samples'])
    source=source_model(REV,'split',True);atlas=NativeAtlas(REV,source)
    origin=np.array([20.599371111492427,39.51257844288108,6.781631480113873])
    values=[atlas.cast(source,origin,[np.cos(t),np.sin(t)],5)['distanceMeters'] for t in samples[:,0]]
    near=np.diff(samples[:,0])<np.deg2rad(1e-5)
    old=near&(abs(np.diff(samples[:,1]))>.01);new=near&(abs(np.diff(values))>.01)
    result=dict(inputSha256=hashlib.sha256(input_path.read_bytes()).hexdigest(),rays=len(values),oldNearAngleJumps=int(sum(old)),newNearAngleJumps=int(sum(new)),
                remaining=[[samples[i].tolist(),samples[i+1].tolist(),values[i],values[i+1]] for i in np.flatnonzero(new)],distances=values)
    (REV/'moving-floor-cone-probe-v1/full-frozen-angle-replay-final.json').write_text(json.dumps(result)+'\n')
    print({k:v for k,v in result.items() if k not in ('distances',)},flush=True)
if __name__=='__main__':run()
