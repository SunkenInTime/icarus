"""Freeze and cast source-backed boundary rays for the three Split role proposals."""
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import load_support, source_model
from audit_split_floor_roles import REV, OUT

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main(name='split', version='v1', frozen_fixture=None, include_generated=True):
    global OUT
    OUT=REV/f'{name}-audited-floor-role-proposals-{version}'
    role_file=OUT/f'{name}.floor-role-proposals.json'
    report=json.loads(role_file.read_text())
    support=load_support(REV,name,True)
    source=source_model(REV,name,True)
    terrain=sum([r['proposedFullPackFaceIds'] for r in report['records'] if r['role']=='structural-terrain'],[])
    raised=sum([r['proposedFullPackFaceIds'] for r in report['records'] if r['role']=='raised-support'],[])
    navids=support.detailed_navigation_indices
    navcenters=support.points[navids].mean(axis=1)
    cases=[]
    for row in report['records']:
        if not row['proposedCount']:
            continue
        faceids=np.array([r['supportIndex'] for r in row['faces'] if r['proposed']])
        polys=support.original_polygons[faceids]
        localtree=shapely.STRtree(polys)
        owners,local=localtree.query(shapely.points(navcenters[:,:2]),predicate='intersects')
        floor=navcenters[owners,:2]*support.planes[faceids[local],:2]
        floor=floor.sum(axis=1)+support.planes[faceids[local],2]
        keep=abs(floor-navcenters[owners,2])<=.35
        owners,local,floor=owners[keep],local[keep],floor[keep]
        assert len(owners)
        points=np.column_stack((navcenters[owners,:2],floor))
        low=int(np.argmin(points[:,2]));high=int(np.argmax(points[:,2]))
        if row['role']=='structural-terrain':
            pairs=[('low-to-high',low,high),('high-to-low',high,low)]
            for label,a,b in pairs:
                origin=points[a].copy();origin[2]+=1.75
                vector=points[b,:2]-origin[:2];distance=float(np.linalg.norm(vector));direction=vector/distance
                cases.append(dict(id=f"object-{row['sourceObjectIndex']}-{label}",query=[*origin,*direction,distance+2,0],sourceObjectIndex=row['sourceObjectIndex'],originKind='source-surface-at-detailed-nav-center',originSupportIndex=int(faceids[local[a]]),originFullPackFace=int(support.source_ids[faceids[local[a]]]),navSupportIndex=int(navids[owners[a]]),targetSurfacePoint=points[b].tolist(),boundary='Source ascent and reverse descent across the whole audited assembly, extended 2m past target.'))
        else:
            # Explicit top origin is separate from ground origins approaching
            # the footprint. A raised top cannot establish ground continuity.
            top=points[high]
            footprint=shapely.union_all(polys)
            outside=~shapely.intersects(shapely.points(navcenters[:,:2]),footprint)
            candidates=np.flatnonzero(outside & (navcenters[:,2]<top[2]-.4))
            order=candidates[np.argsort(np.linalg.norm(navcenters[candidates,:2]-top[:2],axis=1))]
            selected=[]
            for item in order:
                angle=np.arctan2(*(navcenters[item,:2]-top[:2])[::-1])
                if all(abs(np.arctan2(np.sin(angle-prev),np.cos(angle-prev)))>.5 for _,prev in selected):
                    selected.append((int(item),angle))
                if len(selected)==3:break
            for index,(item,angle) in enumerate(selected):
                xy=navcenters[item,:2]
                nearby=support.tree.query(shapely.Point(xy),predicate='intersects')
                nearby=nearby[support.source_ids[nearby]>=0]
                heights=support.planes[nearby,:2]@xy+support.planes[nearby,2]
                pick=int(np.argmin(abs(heights-navcenters[item,2])))
                assert abs(heights[pick]-navcenters[item,2])<=.35
                ground=np.r_[xy,heights[pick]]
                for label,start,target,startface,navid in [('incoming-ground',ground,top,int(nearby[pick]),int(navids[item])),('explicit-top',top,ground,int(faceids[local[high]]),int(navids[owners[high]]))]:
                    origin=start+[0,0,1.75];vector=target[:2]-start[:2];distance=float(np.linalg.norm(vector));direction=vector/distance
                    cases.append(dict(id=f"object-{row['sourceObjectIndex']}-{label}-{index}",query=[*origin,*direction,distance+2,0],sourceObjectIndex=row['sourceObjectIndex'],originKind=label,originSupportIndex=startface,originFullPackFace=int(support.source_ids[startface]),navSupportIndex=navid,targetSurfacePoint=target.tolist(),boundary='Ground incoming to raised footprint versus independently supported top outgoing.'))
    if frozen_fixture is not None:
        frozen=json.loads(Path(frozen_fixture).read_text())['cases']
        ids={case['id'] for case in frozen}
        cases=frozen+[case for case in cases if case['id'] not in ids] if include_generated else frozen
    for case in cases:
        case.update(terrainSourceFaces=terrain,raisedSourceFaces=raised)
    fixture=dict(version=1,map=name,roleManifestSha256=digest(role_file),supportSha256=report['supportSha256'],fullPackSha256=report['fullPackSha256'],sourceGeometrySha256=report['sourceGeometrySha256'],frozenInputSha256=digest(Path(frozen_fixture)) if frozen_fixture else None,cases=cases)
    (OUT/'boundary-fixtures.json').write_text(json.dumps(fixture,indent=2))
    results=[]
    for case in cases:
        q=case['query'];origin=np.array(q[:3]);direction=np.array(q[3:5]);distance=q[5]
        samples=[]
        for offset in (0.,-.01,.01):
            shifted=origin.copy();shifted[:2]+=np.array([-direction[1],direction[0]])*offset
            before=support.cast(source,shifted,direction,distance,True,True,True,.35,True)
            after=support.cast(source,shifted,direction,distance,True,True,True,.35,True,terrain_source_faces=terrain,raised_source_faces=raised)
            horizontal=source.cast(shifted,shifted+np.r_[direction*distance,0.])
            samples.append(dict(lateralOffsetMeters=offset,origin=shifted.tolist(),before=before,proposedRoles=after,originalSourceHorizontal=horizontal))
        results.append(dict(id=case['id'],samples=samples))
        (OUT/'boundary-regressions.json').write_text(json.dumps(dict(fixtureSha256=digest(OUT/'boundary-fixtures.json'),selectorSha256=digest(Path(__file__).with_name('probe_source_floor_support.py')),scope='Diagnostic comparisons against the unchanged original full-height source. The floor-following policies deliberately change the vertical ray path; longer distance alone does not prove game visibility. Lateral probes keep frozen eye Z and are sensitivity tests, not independently validated standing origins.',cases=results),indent=2))
        print(case['id'],[(round(s['before']['distanceMeters'],3),round(s['proposedRoles']['distanceMeters'],3)) for s in samples],flush=True)

if __name__=='__main__':main()
