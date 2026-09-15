"""Bind first hits from frozen component7 poses to original source assemblies."""
import gzip,hashlib,json
from pathlib import Path
from collections import Counter
import numpy as np
from build_split_connected_tower import ROOT,REV
from tactical_alignment_composite import explicit_warp
from native_reference_cast import NativeReferenceModel


def main():
    folder=REV/'split-wall-family-normalized-candidate-v20';config=json.loads((REV/'gallery-component7-v20-fixtures/candidate-config.json').read_text())['maps']['split'];pack=folder/'split.height.bin.gz';model=NativeReferenceModel(pack,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    w=json.loads(gzip.decompress(Path(config['displayWarpFile']).read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);inv=np.linalg.inv(m);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);tri=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(s,t-s,tri);unwarp=explicit_warp(t,s-t,tri)
    families=json.loads((folder/'bindings.json').read_text())['families'];spans={v['completeSpan']:v for f in families if f['edge']==200190 for v in f['reviewedAuthoredSpans']};ca=np.load(folder/'correspondence.npz')['sourceFaces'];co=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([obj['firstFace'] for obj in meta['objects']]);rows=[]
    for span,eye in [(199,1.75),(197,5.),(198,5.),(199,8.25),(201,8.25),(191,8.25),(192,5.),(192,8.25)]:
        key=f'wall-{span}-interior-eye-{eye:g}';query=np.array(config['queriesById'][key]);a,b=np.array(spans[span]['startSvg']),np.array(spans[span]['endSvg']);hits=[]
        for fraction in np.linspace(.002,.998,257):
            target=a+(b-a)*fraction;xy=(unwarp.apply(target[None,:])[0]-o)@inv.T;delta=xy-query[:2];distance=np.linalg.norm(delta);direction=delta/distance;in_cone=float(direction@query[3:5])>=np.cos(query[6]/2)
            if not in_cone:continue
            end=np.r_[query[:2]+direction*(distance+1.),query[2]];hit=model.cast(query[:3],end)
            if hit:
                source_id=int(full[co[ca[hit['face']]]]);obj=int(np.searchsorted(starts,source_id,side='right')-1);display=forward.apply((np.array(hit['point'][:2])@m.T+o)[None,:])[0];hit.update(sourceObject=obj,originalSourceFace=source_id,path=meta['objects'][obj]['path'],pointSvg=display.tolist(),targetErrorSvg=float(np.linalg.norm(display-target)))
            hits.append(dict(fraction=float(fraction),targetSvg=target.tolist(),hit=hit))
        counts=Counter(None if q['hit'] is None else q['hit']['sourceObject'] for q in hits);rows.append(dict(id=key,query=query.tolist(),records=hits,sourceObjectCounts=dict(counts)));print(key,dict(counts),flush=True)
    report=dict(scope='Exact frozen-pose rays through authored spans inside the FOV, in the provisional control-relative candidate. Source IDs are original raw geometry; no new role acceptance.',candidateSha256=hashlib.sha256(pack.read_bytes()).hexdigest(),rows=rows);(folder/'frozen-render-contact-source-traces.json').write_text(json.dumps(report,indent=2))


if __name__=='__main__':main()
