"""Refine finite ramp-edge domains where settling the capsule changes clearance."""
import argparse
from collections import Counter
import gzip
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import ROOT, read
from build_all_physical_standing_surfaces import OUTPUT, affine, sha, standing_face_domain
from compile_reviewed_svg_height_map import polygon, rings
from gameplay_standing_volumes import StandingVolumes


def refine(name):
    directory=OUTPUT/name;proof_path=directory/'physical-top-verification.json'
    proof=read(proof_path);report=read(directory/'physical-top-build.json')
    assert proof['candidateSha256']==report['candidateSha256']
    failed={r['supportId'] for r in proof['failures']}
    if not failed:return
    models={s:read(directory/f'candidate-{s}.json.gz') for s in ['attack','defense']}
    for side in models:
        path=directory/f'candidate-{side}.json.gz'
        assert sha(path)==report['candidateSha256'][side]
        (directory/f'contact-refinement-input-{sha(path)[:12]}-{side}.json.gz').write_bytes(path.read_bytes())
    alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
    matrices={s:np.asarray(alignment[f'nativeTo{s.title()}Svg']) for s in models}
    a=matrices['attack'];inverse=np.c_[np.linalg.inv(a[:,:2]),-np.linalg.inv(a[:,:2])@a[:,2]]
    volumes=StandingVolumes(name);indices={r['id']:i for i,r in enumerate(volumes.rows)}
    evidence={r['supportId']:r for r in report['records'] if r.get('supportId')}
    changes=[];removed=set()
    for support in models['attack']['supports']:
        sid=support['id']
        if sid not in failed:continue
        source=evidence[sid];plane=np.asarray(source['nativeSurfacePlane']);index=indices[source['collision']]
        domain=affine_transform(polygon(support).buffer(0),affine(inverse))
        tangent=standing_face_domain(volumes.triangles[index],source['sourceCollisionFaces'],plane)
        core=domain.intersection(tangent).buffer(-1e-7)
        bad_points=[shapely.Point(r['native']) for r in proof['failures'] if r['supportId']==sid]
        if any(core.covers(p) for p in bad_points):core=shapely.Polygon()
        edge=domain.difference(core)
        cache={};accepted=[];rejected=0
        def clear(x,y):
            key=(round(float(x),9),round(float(y),9))
            if key not in cache:
                xy=np.asarray(key);floor=float(plane[:2]@xy+plane[2])
                contact=volumes.standing_contact(index,xy,floor,plane)
                cache[key]=contact is not None and not volumes.exclusions(xy,floor,
                    capsule_floor_override=contact['capsuleFloorMeters'] if contact else None)
            return cache[key]
        def visit(bounds):
            nonlocal rejected
            x0,y0,x1,y1=bounds
            cell=edge.intersection(shapely.box(*bounds))
            if cell.is_empty or cell.area<1e-12:return
            width=max(x1-x0,y1-y0)
            if width>.025:
                split(bounds);return
            coordinates=shapely.get_coordinates(cell)
            points=[*coordinates]
            points.extend(np.array([p.x,p.y]) for part in shapely.get_parts(cell)
                if part.geom_type=='Polygon' for p in [part.representative_point()])
            points.extend(np.array([p.x,p.y]) for p in bad_points if cell.covers(p))
            good=all(clear(*p) for p in points)
            if good:accepted.append(cell)
            elif width>.0025:split(bounds)
            else:rejected+=1
        def split(bounds):
            x0,y0,x1,y1=bounds
            if x1-x0>=y1-y0:
                mid=(x0+x1)/2;visit((x0,y0,mid,y1));visit((mid,y0,x1,y1))
            else:
                mid=(y0+y1)/2;visit((x0,y0,x1,mid));visit((x0,mid,x1,y1))
        if not edge.is_empty:visit(edge.bounds)
        result=shapely.union_all([core,*accepted],grid_size=1e-7).buffer(0)
        change=dict(supportId=sid,sourceCollision=source['collision'],originalAreaSquareMeters=domain.area,
            refinedAreaSquareMeters=result.area,checkedPositions=len(cache),rejectedBoundaryCells=rejected,
            acceptedCellMaximumMeters=.025,mixedCellMinimumMeters=.0025)
        changes.append(change)
        if result.is_empty:
            removed.add(sid);source['status']='no-clear-standing-domain-after-contact-refinement'
        else:
            for side,model in models.items():
                item=next(s for s in model['supports'] if s['id']==sid)
                shape=affine_transform(result,affine(matrices[side]))
                item['rings']=[r for p in shapely.get_parts(shape) if p.geom_type=='Polygon' for r in rings(p)]
            source['addedAreaSvg']=float(affine_transform(result,affine(a)).area)
        print(name,change,flush=True)
    for side,model in models.items():
        model['supports']=[s for s in model['supports'] if s['id'] not in removed]
        (directory/f'candidate-{side}.json.gz').write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
    refinement=dict(inputCandidateSha256=report['candidateSha256'],inputVerificationSha256=sha(proof_path),
        sourceScriptSha256=sha(__import__('pathlib').Path(__file__)),changes=changes)
    report.setdefault('contactRefinements',[]).append(refinement)
    report['candidateSha256']={s:sha(directory/f'candidate-{s}.json.gz') for s in models}
    report['newSupports']-=len(removed)
    report['counts']=dict(Counter(r['status'] for r in report['records']))
    (directory/'physical-top-build.json').write_text(json.dumps(report,separators=(',',':')))
    (directory/'contact-refinement.json').write_text(json.dumps(refinement,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='+')
    for name in p.parse_args().maps:refine(name)
