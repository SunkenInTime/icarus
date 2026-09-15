"""Frozen visible-notch rays and standing doorway controls for V15/V16."""
import json,hashlib
import numpy as np
from native_reference_cast import NativeReferenceModel
from build_split_connected_tower import ROOT,REV

def main():
    frozen=json.loads((REV/'tower-v14-region-traces/short99-dark-notch.json').read_text());origin=np.array(frozen['query'][:3]);affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(affine[:,:2])
    probes=[]
    for row in frozen['rows']:probes.append(dict(id='notch-'+str(row['svg'][0]),origin=origin.tolist(),target=[*row['nativeTarget'],1.75],targetSvg=row['svg']))
    for y in np.linspace(134,147.5,28):
        xy=(np.array([[339.,y],[347.,y]])-affine[:,2])@inverse.T
        probes.append(dict(id='doorway-'+str(y),origin=[*xy[0],1.75],target=[*xy[1],1.75],targetSvg=[347.,y]))
    outputs={};full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces']
    for version in ['v15','v16']:
        folder=REV/f'split-wall-family-normalized-candidate-{version}';path=folder/'split.height.bin.gz';model=NativeReferenceModel(path,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll');parents=np.load(folder/'correspondence.npz')['sourceFaces'];rows=[]
        for probe in probes:
            hit=model.cast(probe['origin'],probe['target'])
            if hit:hit.update(originalFace=int(full[control[parents[hit['face']]]]),displaySvg=(np.array(hit['point'][:2])@affine[:,:2].T+affine[:,2]).tolist())
            rows.append(dict(**probe,hit=hit))
        outputs[version]=dict(packSha256=hashlib.sha256(path.read_bytes()).hexdigest(),rows=rows)
        del model
    changes=[]
    for a,b in zip(outputs['v15']['rows'],outputs['v16']['rows']):
        if a['id'].startswith('doorway') and (a['hit'] is None)!=(b['hit'] is None):changes.append(dict(before=a,after=b))
    report=dict(policy='Frozen control-relative standing rays. Source absolute-Z and final floor policy are separate.',versions=outputs,doorwayChangedHitState=changes)
    folder=REV/'split-wall-family-normalized-candidate-v16';(folder/'doorframe-frozen-rays.json').write_text(json.dumps(report,indent=2));print('Doorway state changes',len(changes));print([(r['id'],None if r['hit'] is None else r['hit']['displaySvg']) for r in outputs['v16']['rows'] if r['id'].startswith('notch')])

if __name__=='__main__':main()
