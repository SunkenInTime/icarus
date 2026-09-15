"""Freeze three source-directed diagonal poses per map for production rendering."""
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    output=REV/'gallery-diagonal-walls-v1';output.mkdir(exist_ok=True)
    config=json.loads((REV/'display-all-candidate-config-v1.json').read_text());config['maps']={name:config['maps'][name] for name in ['split','ascent']}
    for name,item in config['maps'].items():
        folder=REV/f'diagonal-wall-candidates-v1/{name}'
        proof=json.loads((folder/'bindings.json').read_text());family=proof['families'][0]
        summary=json.loads((folder/'summary.json').read_text())
        item.update(folder=str(folder/'native'),automaticQueries=False,queriesById={},candidatePackSha256=summary['packSha256'],scopeLabel='Isolated reviewed diagonal plane; adjacent returns and provisional floor remain separate')
        w=json.loads(gzip.decompress(Path(item['displayWarpFile']).read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
        before=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;after=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(after,before-after,np.array(w['triangles']).reshape(-1,3))
        ground=GroundField(Path(item['groundFieldFile']));receiver=receiver_domain(Path(f'assets/maps/{name}_map.svg'))
        frame=family['targetFrame'];fo=np.array(frame['origin']);tangent=np.array(frame['tangent']);normal=np.array(frame['normal']);lo,hi=family['targetAlong'];middle=fo+(lo+hi)/2*tangent
        signs=[sign for sign in [-1,1] if receiver.covers(shapely.Point(middle+normal*.5*sign))]
        assert len(signs)==1;inward=normal*signs[0]
        fixture=json.loads((REV/f'gallery-display-all-v1/{name}-fixtures.json').read_text());fixture['cases']=[];fixture['policy']='Three frozen source-directed diagonal geometry poses. Standing eye1.75m above frozen source reference; provisional floor policy is not acceptance.'
        for label,along in [('interior',(lo+hi)/2),('start-corner',lo+.05),('end-corner',hi-.05)]:
            target=fo+along*tangent;start=target+inward*4
            assert receiver.covers(shapely.Point(start)),(name,label,start)
            source_xy=(unwarp.apply(np.array([start,target]))-origin)@inverse.T
            direction=source_xy[1]-source_xy[0];direction/=np.linalg.norm(direction)
            absolute_eye=float(ground.heights(source_xy[:1])[0])+1.75
            q=[*((start-origin)@inverse.T).tolist(),absolute_eye,*direction.tolist(),15.,float(np.deg2rad(103))]
            cq=[*source_xy[0].tolist(),1.75,*direction.tolist(),15.,float(np.deg2rad(103))]
            id=f'diagonal-{family["edge"]}-{label}'
            fixture['cases'].append(dict(id=id,category='reviewed diagonal wall',query=q,originSvg=start.tolist(),eyeHeightMode='absolute',sourceDirectedTargetSvg=target.tolist(),expectedAuthoredSpan=[(fo+lo*tangent).tolist(),(fo+hi*tangent).tolist()]))
            item['queriesById'][id]=cq
        (output/f'{name}-fixtures.json').write_text(json.dumps(fixture,indent=2))
    config['scope']='Two isolated reviewed diagonal-plane candidates, with exact source-native directions and frozen display positions. Neighboring return and floor semantics remain provisional.'
    (output/'candidate-config.json').write_text(json.dumps(config,indent=2))
    print(output)


if __name__=='__main__':main()
