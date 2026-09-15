"""Build flat standing regions from physical floors corroborated by navigation.

Player volumes supply only standing domains and heights. All visibility walls
and the receiver remain the existing SVG footprints.
"""
import argparse
from collections import Counter,defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import MAPS, OUT, ROOT, read, planes
from compile_reviewed_svg_height_map import polygon, rings
from gameplay_standing_volumes import StandingVolumes, inside_closed_mesh


def source_roles(name):
    row=read(Path(__file__).parent/'data/gameplay-standing-source-roles-v5.json')['maps'][name]
    metadata=ROOT/f'supplemented-v2/world/{name}/geometry.json'
    if hashlib.sha256(metadata.read_bytes()).hexdigest()!=row['sourceMetadataSha256']:
        raise ValueError((name,'Standing source identities changed'))
    return {r['sourceObject']:r for r in row['objects']}


def support_elevation(support,xy):
    plane=support.get('surfacePlane')
    return support['surfaceElevationMeters'] if plane is None else float(np.array(plane[:2])@xy+plane[2])


def ground_sampler(model):
    vertices=np.array(model['ground']['vertices']).reshape(-1,3)
    tri=vertices[np.array(model['ground']['triangles']).reshape(-1,3)]
    tree=shapely.STRtree(shapely.polygons(tri[:,:,:2]));coefficients=planes(tri)
    def sample(xy):
        ids=tree.query(shapely.Point(xy),predicate='intersects')
        return None if not len(ids) else float(coefficients[min(ids),:2]@xy+coefficients[min(ids),2])
    return sample


def plane_region(shape,plane,lower,upper):
    """Clip a painted region by the local plane's elevation interval."""
    if shape.is_empty: return shapely.Polygon()
    magnitude=float(np.linalg.norm(plane[:2]))
    if magnitude<1e-12:
        return shape if lower<=plane[2]<=upper else shapely.Polygon()
    u=plane[:2]/magnitude;v=np.array([-u[1],u[0]])
    coordinates=shapely.get_coordinates(shape);along=coordinates@u;across=coordinates@v
    low=max(float(along.min())-1,(lower-plane[2])/magnitude)
    high=min(float(along.max())+1,(upper-plane[2])/magnitude)
    if low>=high:return shapely.Polygon()
    t0,t1=float(across.min())-1,float(across.max())+1
    clip=shapely.Polygon([low*u+t0*v,high*u+t0*v,high*u+t1*v,low*u+t1*v])
    return shape.intersection(clip)


def clip_z(triangle,low,high):
    points=triangle.tolist()
    for z,sign in [(low,1),(high,-1)]:
        output=[]
        for a,b in zip(points,points[1:]+points[:1]):
            inside_a=(a[2]-z)*sign>=0;inside_b=(b[2]-z)*sign>=0
            if inside_a:output.append(a)
            if inside_a!=inside_b:
                t=(z-a[2])/(b[2]-a[2]);output.append((np.array(a)+t*(np.array(b)-a)).tolist())
        points=output
        if not points:break
    return points


def convex_capsule_obstacle(volumes,index,domain,plane,height=1.96,contact_tolerance=.001):
    """Conservative rounded-capsule clearance on a local standing plane.

    A collision occurs when the standing origin lies inside the Minkowski sum
    of the convex body and the reversed capsule. Intersect support halfplanes
    of that sum with the standing plane. The sampled directions enclose the
    rounded shape; they cannot admit a blocked capsule. Native face normals
    keep exact floor contact and straight wall clearance.
    """
    cache=getattr(volumes,'_capsule_support',None)
    if cache is None:cache=volumes._capsule_support={}
    if index not in cache:
        k=np.arange(256);zz=1-2*(k+.5)/256;angle=k*np.pi*(3-np.sqrt(5));rr=np.sqrt(1-zz*zz)
        directions=np.concatenate([volumes.equations[index][:,:3],np.eye(3),-np.eye(3),np.c_[rr*np.cos(angle),rr*np.sin(angle),zz]])
        # Rounded transitions at long source edges need their own directions.
        # A global sphere sample can be too sparse near those edge normals.
        edge_normals={};arcs=set();arc=[]
        for triangle,normal in zip(volumes.triangles[index],volumes.equations[index][:,:3]):
            for j in range(3):
                edge=tuple(sorted([tuple(triangle[j]),tuple(triangle[(j+1)%3])]))
                if edge in edge_normals:
                    other=edge_normals[edge]
                    if abs(float(normal@other))>.999999:continue
                    arcs.add(tuple(sorted([tuple(np.round(normal,10)),tuple(np.round(other,10))])))
                else:edge_normals[edge]=normal
        for pair in sorted(arcs):
            n,other=np.array(pair)
            blended=np.linspace(0.,1.,65)[1:-1,None]*n+np.linspace(1.,0.,65)[1:-1,None]*other
            arc.extend(blended/np.linalg.norm(blended,axis=1)[:,None])
        if arc:directions=np.concatenate([directions,np.array(arc)])
        vertices=np.unique(volumes.triangles[index].reshape(-1,3),axis=0)
        cache[index]=(directions,(vertices@directions.T).max(axis=0))
    directions,support=cache[index]
    return clip_support_to_standing_domain(directions, support, domain, plane, height, contact_tolerance)


def clip_support_to_standing_domain(directions, support, domain, plane, height=1.96, contact_tolerance=.001):
    """Intersect support halfplanes with the standing plane without sampling points."""
    radius=.42
    lift=radius*(np.sqrt(1+float(plane[:2]@plane[:2]))-1)
    a=directions[:,:2]+directions[:,2,None]*plane[:2]
    b=support+radius-contact_tolerance-np.minimum(radius*directions[:,2],(height-radius)*directions[:,2])-directions[:,2]*(plane[2]+lift)
    x0,y0,x1,y1=domain.bounds
    vertices=np.array([[x0,y0],[x1,y0],[x1,y1],[x0,y1]])
    distances=vertices@a.T-b
    if np.any(np.min(distances,axis=0)>0):return shapely.Polygon()
    crossing=np.max(distances,axis=0)>0
    a,b=a[crossing],b[crossing]
    for normal,limit in zip(a,b):
        distances=vertices@normal-limit;inside=distances<=0
        if inside.all():continue
        if not inside.any():return shapely.Polygon()
        result=[]
        for j in range(len(vertices)):
            nxt=(j+1)%len(vertices)
            if inside[j]:result.append(vertices[j])
            if inside[j]!=inside[nxt]:result.append(vertices[j]+distances[j]/(distances[j]-distances[nxt])*(vertices[nxt]-vertices[j]))
        vertices=np.array(result)
    return shapely.MultiPoint(vertices).convex_hull if len(vertices)>=3 else shapely.Polygon()


def union_clearance(obstacles,shapes):
    """Keep coincident source contacts stable before combining player clearance."""
    polygonal=[]
    for shape in [obstacles,*shapes]:
        for part in shapely.get_parts(shape):
            if part.is_empty:continue
            # Exact contact can clip to a line or a point. Retain that contact
            # on the precision grid without a mixed-dimension overlay.
            polygonal.append(part if part.geom_type=='Polygon' else part.buffer(1e-7))
    return shapely.union_all(polygonal,grid_size=1e-7)


def standing_obstacles(volumes,domain,z,*,ignored=(),height=1.96,floor_plane=None):
    """Remove positions obstructed by the standing player capsule.

    Convex collision uses a conservative capsule configuration-space boundary
    on the local floor plane. Complex meshes use a full-radius height slab,
    which can exclude valid edge positions. Floor contact is not penetration.
    """
    pieces=[];unwalkable=[];rounded=[]
    local_plane=np.array([0.,0.,z]) if floor_plane is None else np.array(floor_plane)
    for i in volumes.tree.query(domain.buffer(.42)):
        if i in ignored:continue
        row=volumes.rows[i]
        contact_tolerance=-.0002 if row['unwalkable'] or row['kill'] or row.get('collisionDefaultsUnknown') else .001
        if row.get('analyticCapsule') is not None:
            from native_capsule_standing import analytic_capsule_obstacle
            shape=analytic_capsule_obstacle(row['analyticCapsule'], domain, local_plane,
                1.96 if floor_plane is not None else height, contact_tolerance)
            if not shape.is_empty:rounded.append(shape)
            continue
        if volumes.equations[i] is not None:
            shape=convex_capsule_obstacle(volumes,i,domain,local_plane,1.96 if floor_plane is not None else height,contact_tolerance)
            if not shape.is_empty:rounded.append(shape)
            continue
        if floor_plane is not None:
            from standing_complex_clearance import complex_capsule_obstacle
            shape=complex_capsule_obstacle(volumes,i,domain,local_plane,contact_tolerance=contact_tolerance)
            if not shape.is_empty:rounded.append(shape)
            continue
        if row['bounds'][1][2]<=z+.001 or row['bounds'][0][2]>=z+height:continue
        section=[]
        for tri in volumes.triangles[i]:
            clipped=clip_z(tri,z+.001,z+height)
            if len(clipped)<2:continue
            points=np.array(clipped)[:,:2]
            shape=shapely.MultiPoint(points).convex_hull
            if not shape.is_empty:pieces.append(shape)
            middle=z+.98
            cuts=[]
            for a,b in zip(tri,np.roll(tri,-1,axis=0)):
                if (a[2]<middle<b[2]) or (b[2]<middle<a[2]):
                    cuts.append((a+(middle-a[2])/(b[2]-a[2])*(b-a))[:2])
            if len(cuts)==2:section.append(shapely.LineString(cuts))
        # A closed volume that surrounds a whole capsule has no top or bottom
        # triangle in the height slab. Fill its actual middle cross-section.
        if volumes.equations[i] is not None and section:
            areas=[shapely.MultiPoint([p for line in section for p in line.coords]).convex_hull]
        else:
            # Adjacent triangle cuts can differ by floating point roundoff.
            # Snap only this offline clearance cross-section before stitching.
            lines=shapely.set_precision(shapely.union_all(section),1e-8)
            areas=shapely.get_parts(shapely.polygonize(shapely.get_parts(lines)))
        for area in areas:
            p=area.representative_point();point=np.array([p.x,p.y,z+.98])
            equations=volumes.equations[i]
            inside=(np.all(equations[:,:3]@point+equations[:,3]<1e-6) if equations is not None
                    else inside_closed_mesh(volumes.triangles[i],point))
            if inside:pieces.append(area)
    obstacles=shapely.union_all(pieces,grid_size=1e-8).buffer(.42,quad_segs=16) if pieces else shapely.Polygon()
    # Near-coincident source faces can make floating-precision overlay drop
    # part of a blocker. Snap only this offline clearance union, before it is
    # combined with other collision, to a tenth of a micrometre.
    return union_clearance(obstacles,unwalkable+rounded)


def navigation_triangles(name):
    source=read(ROOT/f'nav/baked/{name}_source_xyz.json')
    nav=read(ROOT/f'nav/baked/{name}_navigation.json')
    xyz=np.array(source['vertices'],dtype=float).reshape(-1,3)/100;xyz[:,1]*=-1
    raw=np.array(source['triangles']).reshape(-1,4)
    raw=raw[np.array(nav['walkable'])[raw[:,0]]]
    triangles=xyz[raw[:,1:]]
    return triangles[shapely.area(shapely.polygons(triangles[:,:,:2]))>1e-10]


def build(name):
    directory=OUT/name
    clearance=read(directory/'standing-clearance.json')
    if clearance['unresolvedVolumes']:raise ValueError((name,'Unresolved player volumes'))
    base=lambda side:directory/(f'height-base-{side}.json.gz' if (directory/f'height-base-{side}.json.gz').exists() else f'before-{side}.json.gz')
    model=read(base('attack'))
    sample_ground=ground_sampler(model)
    volumes=StandingVolumes(name)
    volume_ids={r['id']:i for i,r in enumerate(volumes.rows)}
    alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
    matrix=np.array(alignment['nativeToAttackSvg'])
    transform=[*matrix[0,:2],*matrix[1,:2],matrix[0,2],matrix[1,2]]
    receiver=shapely.union_all([polygon(r) for r in model['receiver']])
    protected=shapely.union_all([polygon(s) for s in model['supports'] if s.get('automaticStandingAllowed')])
    navtri=navigation_triangles(name)
    main_component=Counter(r['navComponent'] for r in clearance['samples']).most_common(1)[0][0]
    grouped=defaultdict(list);unconfirmed=[]
    for row in clearance['samples']:
        if not row['eligible']:continue
        row=dict(row,groundZ=sample_ground(row['svg']))
        # Abilities provide access to disconnected surfaces. Eligibility is
        # established by the physical floor and standing player clearance.
        grouped[row['standingCollision']].append(row)
    combined=defaultdict(list);evidence=[];rejected=[]
    for contact,samples in grouped.items():
        index=volume_ids[contact];triangles=volumes.triangles[index]
        flat=np.ptp(triangles[:,:,2],axis=1)<1e-5
        for z in np.unique(np.round(triangles[flat,:,2].mean(axis=1),5)):
            matched=[r for r in samples if abs(r['physicalFloorZ']-z)<1e-4]
            if not matched:continue
            # Keep connected ramps in the existing continuous ground. A flat
            # region needs an actual missing upper level or an existing prop.
            raised=[r for r in matched if r['matchingSupports'] or r['groundZ'] is None or z-r['groundZ']>.25]
            if not raised:continue
            faces=triangles[flat & (abs(triangles[:,:,2].mean(axis=1)-z)<1e-4)]
            domain=shapely.union_all(shapely.polygons(faces[:,:,:2]))
            nav_ids=sorted(set(r['navTriangle'] for r in matched))
            navdomain=shapely.union_all(shapely.polygons(navtri[nav_ids,:,:2])).buffer(.42,quad_segs=16)
            domain=domain.intersection(navdomain)
            if domain.is_empty:continue
            domain=domain.difference(standing_obstacles(volumes,domain,z))
            svg=affine_transform(domain,transform).intersection(receiver).difference(protected)
            before_ink=float(svg.area)
            active=[]
            for wall in model['walls']:
                relative=z+model['defaultCameraHeightMeters']-wall.get('floorElevationMeters',0)
                if wall['unknownHeight'] or any((bottom<=relative and (top is None or relative<=top)) or (bottom==0 and relative<0) for bottom,top in wall['bands']):
                    active.append(polygon(wall))
            svg=svg.difference(shapely.union_all(active))
            if svg.is_empty:
                rejected.append(dict(collision=contact,z=z,reason='No standing region remains after player clearance and active SVG walls',areaBeforeInk=before_ink));continue
            combined[float(z)].append(svg)
            evidence.append(dict(collision=contact,sourceUsd=volumes.rows[index]['sourceUsd'],nativeMesh=volumes.rows[index]['nativeMesh'],
                elevationMeters=float(z),originalNavTriangles=nav_ids,sourceObjects=sorted(set(r['sourceObject'] for r in matched)),
                corroboratingSamples=len(matched),missingOrPropSamples=len(raised),areaSvg=float(svg.area),areaBeforeInk=before_ink))
    supports=[]
    for z,domains in sorted(combined.items()):
        domain=shapely.union_all(domains)
        encoded=[ring for part in shapely.get_parts(domain) if part.geom_type=='Polygon' and part.area>1e-8 for ring in rings(part)]
        if not encoded:continue
        sid=f'{name}-physical-standing-{z:.5f}'.replace('.','p').replace('-0p','-neg0p')
        supports.append(dict(id=sid,label='Platform',rings=encoded,fillRule='evenodd',
            floorElevationMeters=0.,heightAboveFloorMeters=z,surfaceElevationMeters=z,automaticStandingAllowed=True))
    # Use the recorded affine for each side. Preserve every existing
    # wall, ground triangle, support, ID, and receiver byte-for-byte in JSON.
    current_attack=model
    results=[]
    for side in ['attack','defense']:
        current=read(base(side))
        side_matrix=np.array(alignment['nativeToAttackSvg' if side=='attack' else 'nativeToDefenseSvg'])
        inverse=np.linalg.inv(matrix[:,:2])
        additions=[]
        for support in supports:
            copy=dict(support)
            copy['rings']=[(((np.array(ring).reshape(-1,2)-matrix[:,2])@inverse.T)@side_matrix[:,:2].T+side_matrix[:,2]).reshape(-1).tolist() for ring in support['rings']]
            additions.append(copy)
        current['supports']=current['supports']+additions
        payload=json.dumps(current,separators=(',',':'),allow_nan=False).encode()
        destination=directory/f'candidate-{side}.json.gz'
        destination.write_bytes(gzip.compress(payload,mtime=0))
        results.append(dict(side=side,supports=len(current['supports']),compressedBytes=destination.stat().st_size,
            sha256=hashlib.sha256(destination.read_bytes()).hexdigest()))
    report=dict(map=name,mainNavigationComponent=main_component,addedSupports=len(supports),sourceRegions=len(evidence),evidence=evidence,rejected=rejected,assets=results,
        unconfirmedDetachedSamples=unconfirmed,
        limitations=['This stage adds flat physical floors. The following incline stage adds continuous slopes.',
            'Convex collision uses rounded capsule clearance; complex meshes retain conservative full-radius clearance.',
            'Original navigation and serialized collision are source evidence, not a live gameplay certification.'])
    (directory/'support-build.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k not in ['evidence','rejected','limitations','unconfirmedDetachedSamples']}),flush=True)
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
    result=[build(name) for name in p.parse_args().maps]
    (OUT/'support-build-summary.json').write_text(json.dumps(result,indent=2))
