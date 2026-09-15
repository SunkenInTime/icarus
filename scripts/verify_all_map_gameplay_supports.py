"""Validate candidate standing regions without changing the installed assets."""
import argparse
import hashlib
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import MAPS,OUT,ROOT,read
from compile_reviewed_svg_height_map import polygon
from gameplay_standing_volumes import StandingVolumes
from build_all_map_gameplay_supports import support_elevation


def points(domain,spacing):
    output=[]
    for part in shapely.get_parts(domain):
        if part.geom_type!='Polygon' or part.is_empty:continue
        output.append(part.representative_point())
        x0,y0,x1,y1=part.bounds
        for x in np.arange(x0+spacing/2,x1,spacing):
            for y in np.arange(y0+spacing/2,y1,spacing):
                p=shapely.Point(x,y)
                if part.contains(p):output.append(p)
        # Exercise edges and holes as well as the center. Move a small amount
        # towards the interior to avoid testing an unrelated adjacent level.
        inner=part.buffer(-.01)
        for piece in shapely.get_parts(inner):
            if piece.geom_type!='Polygon' or piece.is_empty:continue
            line=piece.exterior
            count=max(1,int(np.ceil(line.length/spacing)))
            output.extend(line.interpolate((i+.5)/count,normalized=True) for i in range(count))
    return output


def verify(name):
    directory=OUT/name
    base=lambda side:directory/(f'height-base-{side}.json.gz' if (directory/f'height-base-{side}.json.gz').exists() else f'before-{side}.json.gz')
    before=read(base('attack'));after=read(directory/'candidate-attack.json.gz')
    for key in before:
        if key!='supports':assert after[key]==before[key],(name,key,'Changed visibility data')
    assert after['supports'][:len(before['supports'])]==before['supports']
    alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
    matrix=np.array(alignment['nativeToAttackSvg']);inverse=np.linalg.inv(matrix[:,:2]);scale=np.linalg.norm(matrix[0,:2])
    defender=np.array(alignment['nativeToDefenseSvg']);relative=defender[:,:2]@inverse;shift=defender[:,2]-relative@matrix[:,2]
    attack_to_defense=[*relative[0],*relative[1],*shift]
    d_before=read(base('defense'));d_after=read(directory/'candidate-defense.json.gz')
    for key in d_before:
        if key!='supports':assert d_after[key]==d_before[key],(name,key,'Changed defense visibility data')
    assert d_after['supports'][:len(d_before['supports'])]==d_before['supports']
    by_id={s['id']:s for s in d_after['supports']}
    volumes=StandingVolumes(name);failures=[];count=0;cases=[]
    receiver=shapely.union_all([polygon(r) for r in after['receiver']])
    for support in after['supports'][len(before['supports']):]:
        domain=polygon(support);z=support['surfaceElevationMeters'];sid=support['id']
        assert domain.is_valid and not domain.is_empty
        assert domain.difference(receiver).area<1e-7
        assert affine_transform(domain,attack_to_defense).hausdorff_distance(polygon(by_id[sid]))<1e-8
        assert abs(by_id[sid]['surfaceElevationMeters']-z)<1e-9
        for point in points(domain,.5*scale):
            z=support_elevation(support,[point.x,point.y])
            xy=(np.array([point.x,point.y])-matrix[:,2])@inverse.T
            floor,contact=volumes.physical_floor(xy,z)
            errors=volumes.exclusions(xy,z)
            count+=1
            if contact is None or abs(floor-z)>.015 or errors:
                failures.append(dict(support=sid,svg=[point.x,point.y],physicalFloor=floor,z=z,contact=contact,exclusions=errors))
        point=domain.representative_point()
        cases.append(dict(support=sid,origin=[point.x,point.y],surfaceElevationMeters=support_elevation(support,[point.x,point.y])))
    report=dict(map=name,addedSupports=len(cases),sampledPositions=count,failures=failures,cases=cases,
        candidateSha256={side:hashlib.sha256((directory/f'candidate-{side}.json.gz').read_bytes()).hexdigest() for side in ['attack','defense']})
    (directory/'support-verification.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(dict(map=name,addedSupports=len(cases),samples=count,failures=len(failures))),flush=True)
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
    result=[verify(name) for name in p.parse_args().maps]
    (OUT/'support-verification-summary.json').write_text(json.dumps(result,indent=2))
    if any(r['failures'] for r in result):raise SystemExit(1)
