"""Exercise added surfaces and retained lower levels with the production painter."""
import json
import math
import numpy as np
import shapely
from audit_all_map_gameplay_levels import MAPS, read
from build_all_physical_standing_surfaces import OUTPUT, sha
from build_all_map_gameplay_supports import ground_sampler, support_elevation
from compile_reviewed_svg_height_map import polygon


def prepare(name):
    directory=OUTPUT/name
    verification=read(directory/'physical-top-verification.json')
    assert not verification['failures']
    assert not verification['previousDetachedCounts'].get('unresolved-standing-domain')
    assert not any(r['possibleStandingDomains'] for r in verification['unknownCollisionDomains'])
    stage=OUTPUT/'render-models';stage.mkdir(exist_ok=True)
    cases=[]
    evidence={r['supportId']:r for r in read(directory/'physical-top-build.json')['records'] if r.get('supportId')}
    for side in ['attack','defense']:
        path=directory/f'candidate-{side}.json.gz'
        assert sha(path)==verification['candidateSha256'][side]
        model=read(path)
        (stage/f'{name}-{side}.json').write_text(json.dumps(model,separators=(',',':')))
        before=read(directory/f'before-{side}.json.gz')
        added=model['supports'][len(before['supports']):]
        available=[s for s in model['supports'] if s.get('automaticStandingAllowed')]
        tree=shapely.STRtree([polygon(s) for s in available])
        wall_tree=shapely.STRtree([polygon(w) for w in model['walls']])
        ground=ground_sampler(model);camera=model['defaultCameraHeightMeters']
        ranked=sorted(added,key=lambda s:-polygon(s).area)
        rendered=[];chosen=set()
        # Inspect large tops, surfaces absent from navigation, and inclines.
        for predicate in [lambda s:True,
                lambda s:evidence[s['id']]['navigationCorroboratingSamples']==0,
                lambda s:'surfacePlane' in s]:
            count=0
            for index,s in enumerate(ranked):
                p=polygon(s).representative_point()
                if index in chosen or not predicate(s) or any(p.distance(q)<15 for q in rendered):continue
                chosen.add(index);rendered.append(p);count+=1
                if count==2:break
        for index,s in enumerate(ranked):
            p=polygon(s).representative_point();xy=[p.x,p.y]
            z=ground(xy);floor=support_elevation(s,xy)
            local_walls=[model['walls'][i] for i in wall_tree.query(p,predicate='intersects')]
            def clear(floor):
                return not any(lo<=floor+camera-w['floorElevationMeters']<=hi
                    or lo==0 and floor+camera<w['floorElevationMeters']
                    for w in local_walls for lo,hi in w['bands'])
            heights=[support_elevation(available[i],xy) for i in tree.query(p,predicate='intersects')]
            heights=[h for h in heights if clear(h)]
            if z is None or clear(z):heights.append(z if z is not None else 0.)
            highest=max(heights) if heights else (z if z is not None else 0.)
            render=index in chosen or z is not None and highest<z-.02
            base=dict(side=side,originSvg=xy,centerSvg=xy,directionRadians=math.pi*.25*(index%8),
                rangeSvg=65.,apertureRadians=math.pi*.75,cropSizeSvg=130.,sourceSupport=s['id'])
            cases.append(dict(**base,id=f'{side}-automatic-{index}',automatic=True,
                expectedEyeElevationMeters=highest+camera,render=render))
            if highest-floor>.02:
                cases.append(dict(**base,id=f'{side}-lower-{index}',supportId=s['id'],
                    expectedEyeElevationMeters=floor+camera,render=False))
    (directory/'production-cases.json').write_text(json.dumps(dict(cases=cases,
        candidateSha256=verification['candidateSha256']),separators=(',',':')))
    print(name,len(cases),'queries',sum(r['render'] for r in cases),'renders',flush=True)


if __name__=='__main__':
    for name in MAPS:prepare(name)
