"""Verify the reviewed footprints, measured elevations, and both artwork sides."""
from collections import Counter
import json
import math
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import MAPS,ROOT,read
from build_all_map_gameplay_supports import ground_sampler,support_elevation
from build_all_physical_standing_surfaces import sha,affine
from build_reviewed_standing_surfaces import OUTPUT,REVIEW
from compile_reviewed_svg_height_map import polygon


def verify():
    review=read(REVIEW);results=[];failures=[]
    stage=OUTPUT/'render-models';stage.mkdir(exist_ok=True)
    old=ROOT/'tactical-visibility-revision/all-map-standing-surfaces-v9'
    for name in MAPS:
        directory=OUTPUT/name;entry=review['maps'].get(name);cases=[];positions=[]
        models={s:read(directory/f'candidate-{s}.json.gz') for s in ['attack','defense']}
        align=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
        matrices={s:np.array(align[f'nativeTo{s.title()}Svg']) for s in models}
        before={s:read(directory/f'before-{s}.json.gz') for s in models}
        hashes={s:sha(directory/f'candidate-{s}.json.gz') for s in models}
        for side,model in models.items():
            assert all(model[k]==before[side][k] for k in model if k!='supports')
            assert model['supports'][:len(before[side]['supports'])]==before[side]['supports']
            assert sha(directory/f'before-{side}.json.gz')==sha(old/name/f'candidate-{side}.json.gz')
            (stage/f'{name}-{side}.json').write_text(json.dumps(model,separators=(',',':')))
        added={s:models[s]['supports'][len(before[s]['supports']):] for s in models}
        assert [s['id'] for s in added['attack']]==[s['id'] for s in added['defense']]
        a,d=matrices['attack'],matrices['defense'];linear=d[:,:2]@np.linalg.inv(a[:,:2]);shift=d[:,2]-linear@a[:,2]
        for one,two in zip(added['attack'],added['defense']):
            assert one['automaticStandingAllowed'] and two['automaticStandingAllowed']
            assert len(one['rings'])==len(two['rings'])
            for x,y in zip(one['rings'],two['rings']):
                assert np.max(abs(np.array(x).reshape(-1,2)@linear.T+shift-np.array(y).reshape(-1,2)))<1e-9
            assert polygon(one).is_valid and polygon(two).is_valid
        if name=='bind':
            rule=entry['exclusions'][0];ring=polygon(dict(rings=rule['nativeRings'],fillRule='evenodd'))
            for side in models:
                svg_ring=affine_transform(ring,affine(matrices[side]))
                for support in added[side]:
                    assert polygon(support).intersection(svg_ring).area<1e-5,(support['id'],'Ring was included')
                inside=shapely.Polygon(ring.interiors[0]);center=inside.representative_point()
                outer=shapely.Point([60.,58.4])
                for label,p in [('center',center),('outer',outer)]:
                    svg=shapely.Point(matrices[side][:,:2]@[p.x,p.y]+matrices[side][:,2])
                    assert any(polygon(s).covers(svg) for s in added[side]),(side,label,'Standing basin missing')
        for side,model in models.items():
            support=[s for s in model['supports'] if s.get('automaticStandingAllowed')]
            tree=shapely.STRtree([polygon(s) for s in support]);ground=ground_sampler(model)
            walltree=shapely.STRtree([polygon(w) for w in model['walls']]);rendered_objects=set()
            if entry is None:
                for c in read(old/name/'production-cases.json')['cases']:
                    if c['side']==side and c.get('automatic'):
                        cases.append(dict(c,id=side+'-retained-standing-regression',render=True));break
                continue
            for row in entry['samples']:
                xy=matrices[side][:,:2]@row['nativeXY']+matrices[side][:,2];point=shapely.Point(xy)
                expected=row['physicalFloor']['floorMeters'] if row['physicalFloor'] else row['renderedElevationMeters']
                local=[support[i] for i in tree.query(point,predicate='intersects')]
                matching=sorted([s for s in local if abs(support_elevation(s,xy)-expected)<.02],key=lambda s:abs(support_elevation(s,xy)-expected))
                g=ground(xy)
                if not matching and (g is None or abs(g-expected)>=.02):
                    failures.append(dict(map=name,side=side,id=row['id'],sourceObject=row['sourceObject'],expected=expected,ground=g,
                        localLevels=[support_elevation(s,xy) for s in local]));continue
                chosen=matching[0] if matching else None
                floor=support_elevation(chosen,xy) if chosen else g
                walls=[model['walls'][i] for i in walltree.query(point,predicate='intersects')]
                def clear(z):
                    return not any(lo<=z+model['defaultCameraHeightMeters']-w['floorElevationMeters']<=hi
                        or lo==0 and z+model['defaultCameraHeightMeters']<w['floorElevationMeters'] for w in walls for lo,hi in w['bands'])
                assert clear(floor),(name,side,row['id'],'Reviewed floor inside SVG wall')
                automatic=[support_elevation(s,xy) for s in local if clear(support_elevation(s,xy))]
                if g is None or clear(g):automatic.append(g if g is not None else 0.)
                highest=max(automatic) if automatic else (g if g is not None else 0.)
                render=row['sourceObject'] not in rendered_objects
                rendered_objects.add(row['sourceObject'])
                base=dict(side=side,originSvg=xy.tolist(),centerSvg=xy.tolist(),directionRadians=math.pi*.25*(len(positions)%8),
                    rangeSvg=65.,apertureRadians=math.pi*.75,cropSizeSvg=130.,reviewedSample=row['id'])
                cases.append(dict(**base,id=side+'-'+row['id']+'-reviewed-floor',supportId=chosen['id'] if chosen else None,
                    expectedEyeElevationMeters=floor+model['defaultCameraHeightMeters'],render=render))
                cases.append(dict(**base,id=side+'-'+row['id']+'-automatic',automatic=True,
                    expectedEyeElevationMeters=highest+model['defaultCameraHeightMeters'],render=False))
                positions.append(dict(id=row['id'],side=side,sourceElevationMeters=expected,selectedFloorMeters=floor,
                    supportId=chosen['id'] if chosen else None,automaticFloorMeters=highest))
        (directory/'production-cases.json').write_text(json.dumps(dict(candidateSha256=hashes,cases=cases),separators=(',',':')))
        result=dict(map=name,reviewedSamples=len(entry['samples']) if entry else 0,newSupports=len(added['attack']),
            candidateSha256=hashes,beforeSha256={s:sha(directory/f'before-{s}.json.gz') for s in models},positions=positions)
        (directory/'reviewed-standing-verification.json').write_text(json.dumps(result,indent=2))
        results.append({k:v for k,v in result.items() if k!='positions'})
        print(name,len(positions),'verified side/sample pairs,',len(cases),'production queries',flush=True)
    report=dict(status='passed' if not failures else 'failed',reviewSha256=sha(REVIEW),maps=results,failures=failures,
        samples=sum(r['reviewedSamples'] for r in results),
        provenance='Gameplay eligibility is supplied by Dara. Source heights and collision evidence remain separately recorded.')
    (OUTPUT/'source-verification.json').write_text(json.dumps(report,indent=2))
    assert not failures,failures[:10]
    print(json.dumps(dict(status=report['status'],samples=report['samples'],newSupports=sum(r['newSupports'] for r in results))))


if __name__=='__main__':verify()
