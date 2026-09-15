"""Fresh physical-source controls for the registered lower cover and its corners."""
import gzip,json
from pathlib import Path
import numpy as np
import shapely
from build_split_connected_tower import ROOT,REV
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain

def main():
    candidate=REV/'split-wall-family-normalized-candidate-v18';summary=json.loads((candidate/'summary.json').read_text());base=json.loads((REV/'split-wall-family-normalized-candidate-v17/candidate-config.json').read_text());item=base['maps']['split'];item.update(folder=str(candidate/'native'),candidatePackSha256=summary['packSha256'],scopeLabel='V18 connected lower-cover registration; provisional control-relative floor');base['scope']=item['scopeLabel'];(candidate/'candidate-config.json').write_text(json.dumps(base,indent=2));item.update(automaticQueries=False,queriesById={},samePhysicalPoseAcrossSides=True)
    w=json.loads(gzip.decompress(Path(item['displayWarpFile']).read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;t=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3));ground=GroundField(Path(item['groundFieldFile']));receiver=receiver_domain(Path('assets/maps/split_map.svg'))
    fixture=json.loads((REV/'gallery-display-all-v1/split-fixtures.json').read_text());fixture['cases']=[];fixture['policy']='Same physical source controls across sides. Synthetic elevated control eyes are explicit and do not assert reachable player positions or constant absolute source-height rays.'
    poses=[]
    for name,start,target in [('left',[413.298,138.946],[417.298,138.946]),('front',[421.0195,146.933],[421.0195,142.933]),('right',[428.741,138.946],[424.741,138.946])]:
        for eye in [1.75,3.5,4.25]:poses.append((f'cover-{name}-eye-{eye:g}',start,target,eye))
    for name,target,shift in [('rear-left',[417.298,134.959],[-3,3]),('rear-right',[424.741,134.959],[3,3]),('front-left',[417.298,142.933],[-3,3]),('front-right',[424.741,142.933],[3,3])]:poses.append((f'cover-{name}-corner',list(np.array(target)+shift),target,1.75))
    for key,start,target,eye in poses:
        start=np.array(start);target=np.array(target);assert receiver.covers(shapely.Point(start)),key;xy=(unwarp.apply(np.array([start,target]))-origin)@inverse.T;direction=xy[1]-xy[0];direction/=np.linalg.norm(direction);floor=float(ground.heights(xy[:1])[0]);physical=floor+eye;query=[*xy[0],physical,*direction,15.,float(np.deg2rad(103))];control=[*xy[0],eye,*direction,15.,float(np.deg2rad(103))]
        fixture['cases'].append(dict(id=key,category='Standing lower-cover control' if eye==1.75 else 'Synthetic elevated lower-cover control',query=query,originSvg=start.tolist(),sourceDirectedTargetSvg=target.tolist(),eyeHeightMode='absolute',physicalSourceEye=[*xy[0],physical],controlRelativeEyeMeters=eye,sourceGroundAtOriginMeters=floor,agentIndex=8));item['queriesById'][key]=control
    out=REV/'gallery-cover-v18-fixtures';out.mkdir(exist_ok=True);(out/'split-fixtures.json').write_text(json.dumps(fixture,indent=2));(out/'candidate-config.json').write_text(json.dumps(base,indent=2));print(out)

if __name__=='__main__':main()
