"""Freeze source-directed wall and corner poses at three explicit control heights."""
import gzip,json
from pathlib import Path
import numpy as np
import shapely
from build_split_connected_tower import ROOT,REV
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain

def main():
    candidate=REV/'split-wall-family-normalized-candidate-v17';summary=json.loads((candidate/'summary.json').read_text());base=json.loads((REV/'split-wall-family-normalized-candidate-v16/candidate-config.json').read_text());item=base['maps']['split'];item.update(folder=str(candidate/'native'),candidatePackSha256=summary['packSha256'],scopeLabel='V17 connected component2 region, provisional control-relative floor');base['scope']=item['scopeLabel'];(candidate/'candidate-config.json').write_text(json.dumps(base,indent=2))
    item.update(automaticQueries=False,queriesById={},samePhysicalPoseAcrossSides=True)
    region=next(f for f in json.loads((candidate/'bindings.json').read_text())['families'] if f['edge']==20082)
    w=json.loads(gzip.decompress(Path(item['displayWarpFile']).read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;t=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3));ground=GroundField(Path(item['groundFieldFile']));receiver=receiver_domain(Path('assets/maps/split_map.svg'))
    fixture=json.loads((REV/'gallery-display-all-v1/split-fixtures.json').read_text());fixture['cases']=[];fixture['policy']='Fixed physical source controls across both raw SVG sides. Standing and synthetic elevated control eyes are explicit; elevated cases do not claim reachable player positions or constant absolute-Z sightlines.'
    spans=region['reviewedAuthoredSpans'];corners=np.array([s['startSvg'] for s in spans]);center=corners.mean(0);poses=[]
    for span in spans:
        a,b=np.array(span['startSvg']),np.array(span['endSvg']);mid=(a+b)/2;direction=mid-center;direction/=np.linalg.norm(direction);start=mid+direction*4
        assert receiver.covers(shapely.Point(start)),('outside receiver',span['completeSpan'])
        poses.append((f"wall-{span['completeSpan']}-interior",start,mid,span['completeSpan']))
    for i,corner in enumerate(corners):
        direction=corner-center;direction/=np.linalg.norm(direction);start=corner+direction*4;target=corner-direction*.05
        assert receiver.covers(shapely.Point(start)),('corner outside receiver',i)
        poses.append((f'corner-{i}',start,target,None))
    for label,start,target,span in poses:
        xy=(unwarp.apply(np.array([start,target]))-origin)@inverse.T;direction=xy[1]-xy[0];direction/=np.linalg.norm(direction);floor=float(ground.heights(xy[:1])[0])
        for eye in [1.75,5.,8.25]:
            key=f'{label}-eye-{eye:g}';physical=floor+eye;query=[*xy[0],physical,*direction,15.,float(np.deg2rad(103))];control=[*xy[0],eye,*direction,15.,float(np.deg2rad(103))]
            fixture['cases'].append(dict(id=key,category='Connected component2 standing control' if eye==1.75 else 'Synthetic elevated control, no reachable-position claim',query=query,originSvg=start.tolist(),sourceDirectedTargetSvg=target.tolist(),eyeHeightMode='absolute',physicalSourceEye=[*xy[0],physical],controlRelativeEyeMeters=eye,sourceGroundAtOriginMeters=floor,completeSpan=span,agentIndex=8));item['queriesById'][key]=control
    out=REV/'gallery-component2-v17-fixtures';out.mkdir(exist_ok=True);(out/'split-fixtures.json').write_text(json.dumps(fixture,indent=2));(out/'candidate-config.json').write_text(json.dumps(base,indent=2));print(out)

if __name__=='__main__':main()
