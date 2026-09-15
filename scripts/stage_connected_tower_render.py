"""Freeze standing source-directed contour and sparse-profile diagnostic poses."""
import json,gzip
from pathlib import Path
import numpy as np
import shapely
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def main():
    out=REV/'gallery-connected-tower-v14-fixtures';out.mkdir(exist_ok=True)
    c=json.loads((REV/'split-wall-family-normalized-candidate-v14/candidate-config.json').read_text());item=c['maps']['split'];item.update(automaticQueries=False,queriesById={},samePhysicalPoseAcrossSides=True)
    declarations=json.loads((REV/'split-tower-connected-declarations-v14.json').read_text());families={f['edge']:f for f in declarations['families']}
    w=json.loads(gzip.decompress(Path(item['displayWarpFile']).read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix);before=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;after=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(after,before-after,np.array(w['triangles']).reshape(-1,3))
    ground=GroundField(Path(item['groundFieldFile']));receiver=receiver_domain(Path('assets/maps/split_map.svg'))
    fixture=json.loads((REV/'gallery-display-all-v1/split-fixtures.json').read_text());fixture['cases']=[];fixture['policy']='Frozen physical standing poses,1.75m above source field. Same physical source eye and heading across sides. Control-relative floor policy remains provisional.'
    for edge,fraction,label in [(87,.99,'87-88-join'),(88,.01,'88-87-join'),(91,.5,'91-source-opening-profile'),(92,.25,'92-low-profile'),(92,.75,'92-raised-profile'),(96,.99,'96-short99-join'),(10099,.5,'short99-frontage'),(97,.01,'97-short99-join'),(97,.99,'97-98-join')]:
        family=families[edge];endpoints=np.array(family['sharedAuthoredJoins']);tangent=endpoints[1]-endpoints[0];tangent/=np.linalg.norm(tangent);normal=np.array([-tangent[1],tangent[0]]);target=endpoints[0]+fraction*(endpoints[1]-endpoints[0]);mid=endpoints.mean(0)
        signs=[s for s in [-1,1] if receiver.covers(shapely.Point(mid+normal*.1*s))];assert len(signs)==1,(edge,signs)
        candidates=[target+normal*signs[0]*distance+tangent*shift for distance in [4.,2.,1.] for shift in [0.,-2.,2.]]
        start=next((p for p in candidates if receiver.covers(shapely.Point(p))),None);assert start is not None,edge
        xy=(unwarp.apply(np.array([start,target]))-origin)@inverse.T;direction=xy[1]-xy[0];direction/=np.linalg.norm(direction);eye=float(ground.heights(xy[:1])[0])+1.75
        query=[*((start-origin)@inverse.T).tolist(),eye,*direction.tolist(),15.,float(np.deg2rad(103))];candidate=[*xy[0].tolist(),1.75,*direction.tolist(),15.,float(np.deg2rad(103))]
        fixture['cases'].append(dict(id=label,category='Connected tower standing profile diagnostic',query=query,originSvg=start.tolist(),sourceDirectedTargetSvg=target.tolist(),eyeHeightMode='absolute',expectedAuthoredSpan=endpoints.tolist(),completeSpan=family['completeSpan'],familyEdge=edge,physicalSourceEye=[*xy[0].tolist(),eye],agentIndex=8));item['queriesById'][label]=candidate
    (out/'split-fixtures.json').write_text(json.dumps(fixture,indent=2));(out/'candidate-config.json').write_text(json.dumps(c,indent=2));print(out)

if __name__=='__main__':main()
