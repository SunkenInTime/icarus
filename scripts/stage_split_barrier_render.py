"""Frozen physical barrier/interior/corner poses for both authored SVG sides."""
import argparse,gzip,json
from pathlib import Path
import numpy as np
import shapely
from build_split_connected_tower import REV
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--version',default='v28');parser.add_argument('--family-file');args=parser.parse_args();candidate=REV/f'split-wall-family-normalized-candidate-{args.version}'
    summary=json.loads((candidate/'summary.json').read_text());config=json.loads((REV/'split-wall-family-normalized-candidate-v26/candidate-config.json').read_text());item=config['maps']['split'];item.update(folder=str(candidate/'native'),candidatePackSha256=summary['packSha256'],scopeLabel=f'{args.version.upper()} reviewed connected barrier123/124 and taller122; provisional relative-floor diagnostic')
    config['scope']=item['scopeLabel']
    if not (candidate/'candidate-config.json').exists():(candidate/'candidate-config.json').write_text(json.dumps(config,indent=2))
    item.update(automaticQueries=False,queriesById={},samePhysicalPoseAcrossSides=True)
    w=json.loads(gzip.decompress(Path(item['displayWarpFile']).read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));offset=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix);source=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset;target=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(target,source-target,np.array(w['triangles']).reshape(-1,3));ground=GroundField(Path(item['groundFieldFile']));receiver=receiver_domain(Path('assets/maps/split_map.svg'))
    family=json.loads(Path(args.family_file).read_text()) if args.family_file else next(f for f in json.loads((candidate/'bindings.json').read_text())['families'] if f['edge']==200123);spans={s['completeSpan']:s for s in family['reviewedAuthoredSpans']};poses=[]
    for number in [122,123,124]:
        s=spans[number];a,b=np.array(s['startSvg']),np.array(s['endSvg']);direction=(b-a)/np.linalg.norm(b-a);normal=np.array([-direction[1],direction[0]]);mid=(a+b)/2;starts=[p for p in [mid+normal*4,mid-normal*4] if receiver.covers(shapely.Point(p))];assert starts,number
        poses.append((f'barrier-{number}-interior',starts[0],mid,number,[.75,1.75,5.,8.25]))
        # Aim through the real shared authored endpoint from every locally
        # painted quadrant. Do not silently choose an unpainted observer.
        candidates=[b+np.array(v)*3 for v in [[-1,-1],[1,-1],[-1,1],[1,1]]];starts=[p for p in candidates if receiver.covers(shapely.Point(p))];assert starts,number
        for index,start in enumerate(starts):poses.append((f'barrier-{number}-end-quadrant-{index}',start,b,number,[1.75]))
    fixture=json.loads((REV/'gallery-display-all-v1/split-fixtures.json').read_text());fixture['cases']=[];fixture['policy']='Same physical source observers and heading on both raw authored SVG sides. Provisional relative-floor pack; synthetic heights test retained source profiles, not game walkability. Upper125/front121 remain unaccepted frontier.'
    for label,start,target,number,heights in poses:
        xy=(unwarp.apply(np.array([start,target]))-offset)@inverse.T;direction=xy[1]-xy[0];direction/=np.linalg.norm(direction);floor=float(ground.heights(xy[:1])[0])
        for eye in heights:
            key=f'{label}-eye-{eye:g}';physical=floor+eye;query=[*xy[0],physical,*direction,20.,float(np.deg2rad(103))]
            fixture['cases'].append(dict(id=key,category='Standing-height diagnostic' if eye==1.75 else 'Synthetic height-profile diagnostic',query=query,originSvg=start.tolist(),sourceDirectedTargetSvg=target.tolist(),eyeHeightMode='absolute',physicalSourceEye=[*xy[0],physical],controlRelativeEyeMeters=eye,sourceGroundAtOriginMeters=floor,completeSpan=number,agentIndex=8));item['queriesById'][key]=[*xy[0],eye,*direction,20.,float(np.deg2rad(103))]
    out=REV/f'gallery-barrier-{args.version}-fixtures';out.mkdir(exist_ok=True);(out/'candidate-config.json').write_text(json.dumps(config,indent=2));(out/'split-fixtures.json').write_text(json.dumps(fixture,indent=2));print(out,len(fixture['cases']))

if __name__=='__main__':main()
