"""Replay short physical rays across reviewed authored diagonal spans."""
import gzip
import hashlib
import json
from collections import Counter
from pathlib import Path
import numpy as np
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
REV=ROOT/'tactical-visibility-revision'


def main():
    for name in ['split','ascent']:
        folder=REV/f'diagonal-wall-candidates-v1/{name}'
        proof=json.loads((folder/'bindings.json').read_text());family=proof['families'][0]
        path=folder/f'{name}.height.bin.gz'
        model=NativeReferenceModel(path,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
        parents=np.load(folder/'correspondence.npz')['sourceFaces']
        provenance=np.load(folder/'normalized-face-provenance.npz')
        bound=np.full(len(parents),-1,dtype=np.int32);bound[provenance['generatedFaceIds']]=provenance['generatedEdges']
        full=np.load(Path(proof['sourceBackup']).parent/'correspondence.npz')['sourceFaces']
        original=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces']
        wpath=REV/f'display-warps-v1/{name}.display-warp.json.gz';w=json.loads(gzip.decompress(wpath.read_bytes()))
        matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
        before=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;after=np.array(w['targetAttackSvg']).reshape(-1,2);triangles=np.array(w['triangles']).reshape(-1,3)
        warp=explicit_warp(before,after-before,triangles);unwarp=explicit_warp(after,before-after,triangles)
        frame=family['targetFrame'];fo=np.array(frame['origin']);tangent=np.array(frame['tangent']);normal=np.array(frame['normal']);lo,hi=family['targetAlong']
        locations=np.unique(np.r_[np.arange(lo+.125,hi,.25),lo+.005,hi-.005])
        records=[]
        for along in locations:
            for z in [.75,1.75,2.75]:
                for sign in [-1,1]:
                    target_svg=fo+along*tangent
                    ends_svg=np.array([target_svg+normal*2*sign,target_svg-normal*2*sign])
                    ends_native=(unwarp.apply(ends_svg)-origin)@inverse.T
                    ray=np.column_stack((ends_native,[z,z]))
                    hit=model.cast(*ray)
                    row=dict(alongSvg=float(along),relativeEyeHeightMeters=z,side=sign,query=ray.tolist(),status='no-hit')
                    if hit is not None:
                        fid=hit['face'];point=warp.apply(np.array(hit['point'][:2])[None,:]@matrix.T+origin)[0]
                        normal_error=float((point-fo)@normal)
                        row.update(hit=hit,hitSvg=point.tolist(),normalErrorSvg=normal_error,generatedEdge=int(bound[fid]),controlFace=int(parents[fid]),originalSourceFace=int(original[full[parents[fid]]]))
                        row['status']='exact-family' if bound[fid]==family['edge'] and abs(normal_error)<1e-7 else 'unbound-contact' if bound[fid]<0 else 'family-error'
                    records.append(row)
        result=dict(map=name,packSha256=hashlib.sha256(path.read_bytes()).hexdigest(),displayWarpSha256=hashlib.sha256(wpath.read_bytes()).hexdigest(),counts=dict(Counter(r['status'] for r in records)),maximumBoundNormalErrorSvg=max([abs(r['normalErrorSvg']) for r in records if r.get('generatedEdge')==family['edge']],default=0),records=records,scope='Short source-native rays from both displayed wall sides at provisional relative heights; outside-receiver origins are included intentionally as a geometry check. No gameplay or adjacent-return acceptance.')
        (folder/'normal-contact-rays.json').write_text(json.dumps(result,indent=2));print(name,result['counts'],result['maximumBoundNormalErrorSvg'],flush=True)


if __name__=='__main__':main()
