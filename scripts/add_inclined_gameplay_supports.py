"""Keep measured slopes on physical floors corroborated by walkable navigation."""
import argparse
from collections import Counter,defaultdict
import gzip
import hashlib
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import MAPS,OUT,ROOT,read
from build_all_map_gameplay_supports import navigation_triangles,standing_obstacles,ground_sampler,clip_z,plane_region
from compile_reviewed_svg_height_map import polygon,rings
from gameplay_standing_volumes import StandingVolumes,walkable_slope_angle


def add(name):
    directory=OUT/name;clearance=read(directory/'standing-clearance.json')
    models={side:read(directory/f'candidate-{side}.json.gz') for side in ['attack','defense']}
    for m in models.values():m['supports']=[s for s in m['supports'] if not s['id'].startswith(f'{name}-physical-incline-')]
    volumes=StandingVolumes(name);volume_ids={r['id']:i for i,r in enumerate(volumes.rows)}
    groups=defaultdict(list)
    sample_ground=ground_sampler(models['attack'])
    for r in clearance['samples']:
        if r['eligible']:groups[r['standingCollision']].append(dict(r,groundZ=sample_ground(r['svg'])))
    alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json');nav=navigation_triangles(name)
    evidence=[]
    for contact,samples in groups.items():
        index=volume_ids[contact]
        if volumes.equations[index] is None:continue
        tri=volumes.triangles[index]
        n=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);length=np.linalg.norm(n,axis=1)
        allowed=(abs(n[:,2])>=length*np.cos(np.deg2rad(walkable_slope_angle(volumes.rows[index]))))&(np.ptp(tri[:,:,2],axis=1)>=1e-5)&(length>1e-9)
        planes=defaultdict(list)
        for face in tri[allowed]:
            plane=np.linalg.solve(np.c_[face[:,:2],np.ones(3)],face[:,2])
            if np.linalg.norm(plane[:2])<1e-9:continue
            planes[tuple(np.round(plane,7))].append(face)
        for key,faces in planes.items():
            plane=np.array(key)
            matched=[r for r in samples if abs(plane[:2]@r['nativeXY']+plane[2]-r['physicalFloorZ'])<1e-4]
            if not any(r['groundZ'] is None or r['physicalFloorZ']-r['groundZ']>.25 or r['matchingSupports'] for r in matched):continue
            faces=np.array(faces);domain=shapely.union_all(shapely.polygons(faces[:,:,:2]))
            nav_ids=sorted(set(r['navTriangle'] for r in matched));domain=domain.intersection(shapely.union_all(shapely.polygons(nav[nav_ids,:,:2])).buffer(.42))
            if domain.is_empty:continue
            coordinates=shapely.get_coordinates(domain);z=coordinates@plane[:2]+plane[2];low,high=float(z.min()),float(z.max())
            capsule_lift=.42*(np.sqrt(1+float(plane[:2]@plane[:2]))-1)
            domain=domain.difference(standing_obstacles(volumes,domain,low+capsule_lift,ignored={index},height=1.96+high-low,floor_plane=plane))
            # At a ramp landing, another body can become the actual floor
            # while still clearing the rounded feet. Clip that overlap using
            # its height relative to this plane, not the ramp's minimum Z.
            competing=[]
            for other in volumes.tree.query(domain):
                if other==index or volumes.rows[other]['kill']:continue
                if volumes.bounds[other,1,2]<low+.015 or volumes.bounds[other,0,2]>high+.2:continue
                for face in volumes.triangles[other]:
                    relative=face.copy();relative[:,2]-=face[:,:2]@plane[:2]+plane[2]
                    clipped=clip_z(relative,.015,.2)
                    if len(clipped)>=3:
                        shape=shapely.MultiPoint(np.array(clipped)[:,:2]).convex_hull
                        if shape.geom_type=='Polygon':competing.append(shape)
            if competing:domain=domain.difference(shapely.union_all(competing))
            if domain.is_empty:continue
            sid=f'{name}-physical-incline-'+hashlib.sha256((contact+str(key)).encode()).hexdigest()[:10]
            emitted=[];side_domains={};side_planes={}
            for side,model in models.items():
                matrix=np.array(alignment[f'nativeTo{side.title()}Svg']);inverse=np.linalg.inv(matrix[:,:2])
                svg_plane=np.r_[plane[:2]@inverse,plane[2]-(plane[:2]@inverse)@matrix[:,2]]
                svg=affine_transform(domain,[*matrix[0,:2],*matrix[1,:2],*matrix[:,2]])
                receiver=shapely.union_all([polygon(r) for r in model['receiver']]);protected=shapely.union_all([polygon(s) for s in model['supports'] if s.get('automaticStandingAllowed') and '-physical-' not in s['id']])
                active=[]
                for w in model['walls']:
                    shape=polygon(w)
                    if w['unknownHeight']:active.append(shape);continue
                    for lo,hi in w['bands']:
                        bottom=-np.inf if lo==0 else w['floorElevationMeters']+lo-model['defaultCameraHeightMeters']
                        top=np.inf if hi is None else w['floorElevationMeters']+hi-model['defaultCameraHeightMeters']
                        active.append(plane_region(shape,svg_plane,bottom,top))
                svg=svg.intersection(receiver).difference(protected).difference(shapely.union_all(active))
                side_domains[side]=svg;side_planes[side]=svg_plane
            # The two SVG files round some reflected wall coordinates slightly
            # differently. Intersect both legal domains in one coordinate space
            # before encoding the same standing region for the two sides.
            attack=np.array(alignment['nativeToAttackSvg']);defense=np.array(alignment['nativeToDefenseSvg'])
            linear=attack[:,:2]@np.linalg.inv(defense[:,:2]);offset=attack[:,2]-linear@defense[:,2]
            paired=side_domains['attack'].intersection(affine_transform(side_domains['defense'],[*linear[0],*linear[1],*offset]))
            if not paired.is_empty:
                center=paired.representative_point();anchor=float(side_planes['attack'][:2]@[center.x,center.y]+side_planes['attack'][2])
                for side,model in models.items():
                    matrix=np.array(alignment[f'nativeTo{side.title()}Svg']);linear=matrix[:,:2]@np.linalg.inv(attack[:,:2]);offset=matrix[:,2]-linear@attack[:,2]
                    svg=paired if side=='attack' else affine_transform(paired,[*linear[0],*linear[1],*offset])
                    encoded=[ring for p in shapely.get_parts(svg) if p.geom_type=='Polygon' and p.area>1e-8 for ring in rings(p)]
                    if not encoded:continue
                    model['supports'].append(dict(id=sid,label='Platform',rings=encoded,fillRule='evenodd',floorElevationMeters=0.,heightAboveFloorMeters=anchor,surfaceElevationMeters=anchor,surfacePlane=side_planes[side].tolist(),automaticStandingAllowed=True))
                    emitted.append(side)
            if emitted and len(emitted)!=2:raise ValueError((sid,'Incomplete paired platform'))
            if emitted:evidence.append(dict(id=sid,collision=contact,nativeSurfacePlane=plane.tolist(),sourceObjects=sorted(set(r['sourceObject'] for r in matched)),navTriangles=nav_ids,elevationRange=[low,high]))
    for side,model in models.items():(directory/f'candidate-{side}.json.gz').write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
    (directory/'inclined-supports.json').write_text(json.dumps(dict(map=name,supports=evidence),indent=2))
    print(json.dumps(dict(map=name,addedInclines=len(evidence))),flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
    for name in p.parse_args().maps:add(name)
