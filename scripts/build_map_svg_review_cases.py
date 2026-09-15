"""Place review observers beside every wall and on every explicit top."""
import argparse
import json
import math
from pathlib import Path

import numpy as np
import shapely

from compile_reviewed_svg_height_map import polygon


def build(name,models,out):
    cases=[]
    for side in ['attack','defense']:
        model=json.loads((models/f'{name}-{side}.json').read_text())
        receiver=shapely.union_all([polygon(p) for p in model['receiver']])
        walls=shapely.union_all([polygon(p) for p in model['walls']])
        tops=shapely.union_all([polygon(p) for p in model['supports']])
        enclosed=[]
        for p in model['walls']:
            for shape in shapely.get_parts(polygon(p)):
                if shape.geom_type!='Polygon':continue
                for ring in shape.interiors:
                    interior=shapely.Polygon(ring)
                    if interior.area<250:enclosed.append(interior)
        # Ground poses cannot start inside compact closed cover. Top poses
        # below select their support explicitly instead.
        free=receiver.difference(walls).difference(tops).difference(shapely.union_all(enclosed))
        for wall in model['walls']:
            shape=polygon(wall);edges=[]
            for raw in wall['rings']:
                xy=np.array(raw).reshape(-1,2)
                for a,b in zip(xy,np.roll(xy,-1,axis=0)):
                    length=np.linalg.norm(b-a)
                    if length>1:edges.append((float(length),a,b))
            selected=[]
            for length,a,b in sorted(edges,key=lambda p:p[0],reverse=True):
                midpoint=(a+b)/2;normal=np.array([-(b-a)[1],(b-a)[0]])/length
                for sign in [1,-1]:
                    origin=midpoint+normal*sign*4
                    if not free.contains(shapely.Point(origin)):continue
                    if any(np.linalg.norm(origin-prev)<7 for prev in selected):continue
                    selected.append(origin)
                    center=(origin+midpoint)/2
                    cases.append(dict(id=f'{wall["id"]}-{side}-ground-{len(selected)}',side=side,wallId=wall['id'],
                        originSvg=origin.tolist(),directionRadians=math.atan2(*(midpoint-origin)[::-1]),rangeSvg=70.,apertureRadians=math.pi/2,
                        centerSvg=center.tolist(),cropSizeSvg=50.,description='Standing beside authored ink; inspect wall contact and height-based visibility.',
                        expectedWallBands=wall['bands'],wallFloorElevationMeters=wall['floorElevationMeters']))
                    if len(selected)>=2:break
                if len(selected)>=2:break
            if not selected:
                cases.append(dict(id=f'{wall["id"]}-{side}-no-free-pose',side=side,wallId=wall['id'],status='no-adjacent-free-observer'))
        for support in model['supports']:
            shape=polygon(support);origin=shape.representative_point()
            for direction in [0.,math.pi/2]:
                cases.append(dict(id=f'{support["id"]}-{side}-top-{int(direction>0)}',side=side,supportId=support['id'],
                    originSvg=[origin.x,origin.y],directionRadians=direction,rangeSvg=70.,apertureRadians=math.pi/2,
                    centerSvg=[origin.x,origin.y],cropSizeSvg=50.,description='Explicit source top; its own lower sides must not block vision.',
                    expectedEyeElevationMeters=support['surfaceElevationMeters']+model['defaultCameraHeightMeters']))
    out.mkdir(parents=True,exist_ok=True);path=out/f'{name}.json'
    path.write_text(json.dumps(dict(map=name,cases=cases),separators=(',',':'))+'\n')
    print(name,len(cases),'cases',sum('status' in p for p in cases),'without adjacent free pose',flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--maps',nargs='+',required=True);p.add_argument('--models',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    for name in a.maps:build(name,a.models,a.out)
