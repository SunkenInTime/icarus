"""Check every added standing domain against its physical contact and capsule."""
import argparse
from collections import Counter
import json
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import MAPS, ROOT, OUT, read
from build_all_physical_standing_surfaces import OUTPUT, sha, affine, top_planes
from build_all_map_gameplay_supports import ground_sampler, support_elevation, standing_obstacles
from compile_reviewed_svg_height_map import polygon
from gameplay_standing_volumes import StandingVolumes, vertical_contacts
from verify_all_map_gameplay_supports import points


def verify(name, centers_only=False):
    directory=OUTPUT/name
    report=read(directory/'physical-top-build.json')
    models={s:read(directory/f'candidate-{s}.json.gz') for s in ['attack','defense']}
    before={s:read(directory/f'before-{s}.json.gz') for s in models}
    for side in models:
        assert sha(directory/f'candidate-{side}.json.gz')==report['candidateSha256'][side]
        assert all(models[side][k]==before[side][k] for k in before[side] if k!='supports')
        assert models[side]['supports'][:len(before[side]['supports'])]==before[side]['supports']
    alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
    attack=np.asarray(alignment['nativeToAttackSvg'])
    defense=np.asarray(alignment['nativeToDefenseSvg'])
    inverse=np.linalg.inv(attack[:,:2])
    scale=np.linalg.norm(attack[0,:2])
    matrix=np.c_[defense[:,:2]@inverse,defense[:,2]-defense[:,:2]@inverse@attack[:,2]]
    by_id={s['id']:s for s in models['defense']['supports']}
    evidence={r['supportId']:r for r in report['records'] if r.get('supportId')}
    volumes=StandingVolumes(name)
    volume_ids={r['id']:i for i,r in enumerate(volumes.rows)}
    failures=[];checked=0;cases=[]
    for support in models['attack']['supports'][len(before['attack']['supports']):]:
        sid=support['id'];domain=polygon(support).buffer(0);source=evidence[sid]
        assert domain.is_valid and not domain.is_empty
        # Compare the serialized rings directly. GEOS Hausdorff can retain a
        # zero-area floating-point spur differently after the affine transform.
        other=by_id[sid]
        assert len(support['rings'])==len(other['rings'])
        for first,second in zip(support['rings'],other['rings']):
            a=np.asarray(first).reshape(-1,2);b=np.asarray(second).reshape(-1,2)
            assert a.shape==b.shape
            assert np.max(abs(a@matrix[:,:2].T+matrix[:,2]-b))<1e-7
        index=volume_ids[source['collision']]
        plane=np.asarray(source['nativeSurfacePlane'])
        contact_offset=.42*plane[:2]/np.sqrt(1+float(plane[:2]@plane[:2]))
        sample=[p.representative_point() for p in shapely.get_parts(domain) if p.geom_type=='Polygon'] if centers_only else points(domain,.75*scale)
        for p in sample:
            xy=(np.array([p.x,p.y])-attack[:,2])@inverse.T
            z=support_elevation(support,[p.x,p.y])
            standing=volumes.standing_contact(index,xy,z,plane)
            contact=standing is not None
            excluded=volumes.exclusions(xy,z,standing_plane=plane,
                capsule_floor_override=standing['capsuleFloorMeters'] if standing else None)
            checked+=1
            if not contact or excluded:
                failures.append(dict(supportId=sid,collision=source['collision'],svg=[p.x,p.y],native=xy.tolist(),
                    elevationMeters=z,contact=contact,standingContact=standing,exclusions=excluded))
        p=domain.representative_point()
        cases.append(dict(supportId=sid,originSvg=[p.x,p.y],surfaceElevationMeters=support_elevation(support,[p.x,p.y])))
    # Revisit the exact old samples that were pending solely for connectivity.
    old=read(OUT/name/'support-build.json')['unconfirmedDetachedSamples']
    available=[s for s in models['attack']['supports'] if s.get('automaticStandingAllowed')]
    shapes=[polygon(s) for s in available];tree=shapely.STRtree(shapes)
    ground=ground_sampler(models['attack'])
    wall_shapes=[polygon(w) for w in models['attack']['walls']];wall_tree=shapely.STRtree(wall_shapes)
    receiver=shapely.union_all([polygon(r) for r in models['attack']['receiver']])
    previous=[]
    for row in old:
        p=shapely.Point(row['svg']);z=row['physicalFloorZ']
        match=[available[i]['id'] for i in tree.query(p,predicate='intersects')
               if abs(support_elevation(available[i],row['svg'])-z)<.02]
        g=ground(row['svg'])
        eye=z+models['attack']['defaultCameraHeightMeters']
        walls=[models['attack']['walls'][i]['id'] for i in wall_tree.query(p,predicate='intersects')
               if any(lo<=eye-models['attack']['walls'][i]['floorElevationMeters']<=hi
                      for lo,hi in models['attack']['walls'][i]['bands'])]
        if match:status='covered-by-physical-standing'
        elif g is not None and abs(g-z)<.02:status='covered-by-ground'
        elif not receiver.covers(p):status='outside-svg-displayed-floor'
        elif walls:status='source-position-inside-active-svg-wall'
        else:status='unresolved-standing-domain'
        exclusions=volumes.exclusions(np.asarray(row['nativeXY']),z) if status=='unresolved-standing-domain' else []
        if exclusions:status='source-position-has-no-standing-clearance'
        previous.append(dict(**row,coverageStatus=status,automaticSupports=match,activeSvgWalls=walls,
            currentPhysicalExclusions=exclusions))
    unknown=[]
    native_receiver=affine_transform(receiver,affine(np.c_[inverse,-inverse@attack[:,2]]))
    for i,row in enumerate(volumes.rows):
        if not row.get('collisionDefaultsUnknown'):continue
        remaining=[]
        for key,faces in top_planes(volumes.triangles[i],volumes.equations[i],44.).items():
            plane=np.asarray(key)
            domain=shapely.union_all(shapely.polygons(volumes.triangles[i][faces,:,:2])).intersection(native_receiver)
            if domain.is_empty:continue
            xyz=shapely.get_coordinates(domain)@plane[:2]+plane[2]
            obstacle=standing_obstacles(volumes,domain,float(xyz.min()),ignored={i},floor_plane=plane)
            clear=shapely.set_precision(domain,1e-7).difference(shapely.set_precision(obstacle,1e-7))
            if clear.area>1e-10:remaining.append(dict(plane=key,possibleAreaSquareMeters=clear.area))
        unknown.append(dict(collision=row['id'],possibleStandingDomains=remaining,
            status='unresolved-possible-standing-surface' if remaining else 'fully-blocked-by-other-known-player-collision'))
    code_names=['verify_all_physical_standing_surfaces.py','gameplay_standing_volumes.py',
        'audit_navigation_components.py','compile_reviewed_svg_height_map.py',
        'build_all_map_gameplay_supports.py','build_all_physical_standing_surfaces.py','standing_complex_clearance.py']
    result=dict(map=name,centersOnly=centers_only,sampledPositions=checked,addedSupports=len(cases),failures=failures,cases=cases,
        standingContactPolicy='global-walkable-capsule-contact-v1',
        verificationCodeSha256={n:sha(Path(__file__).parent/n) for n in code_names},
        previousDetachedSamples=previous,previousDetachedCounts=dict(Counter(r['coverageStatus'] for r in previous)),
        unknownCollisionDomains=unknown,
        candidateSha256=report['candidateSha256'],buildReportSha256=sha(directory/'physical-top-build.json'))
    (directory/('physical-top-centers.json' if centers_only else 'physical-top-verification.json')).write_text(json.dumps(result,separators=(',',':')))
    print(json.dumps({k:v for k,v in result.items() if k in ['map','sampledPositions','addedSupports','previousDetachedCounts']}),len(failures),'failures',flush=True)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('maps',nargs='*',default=MAPS);parser.add_argument('--centers-only',action='store_true')
    args=parser.parse_args()
    results=[verify(name,args.centers_only) for name in args.maps]
    if any(r['failures'] or r['previousDetachedCounts'].get('unresolved-standing-domain')
           or any(u['possibleStandingDomains'] for u in r['unknownCollisionDomains']) for r in results):
        raise SystemExit(1)
