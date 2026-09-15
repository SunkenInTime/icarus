"""Read source player volumes for standing eligibility, never runtime wall XY."""
from functools import lru_cache
from collections import Counter
import json
import re
from pathlib import Path
import numpy as np
import shapely
from scipy.spatial import ConvexHull
from scipy.spatial.transform import Rotation
from pxr import Usd, UsdGeom, Sdf
from audit_all_map_gameplay_levels import OUT, ROOT
from audit_navigation_components import nearest_triangle_point

CODES = dict(zip('abyss ascent bind breeze corrode fracture haven icebox lotus pearl split summit sunset'.split(),
    'Infinity Ascent Duality Foxtrot Rook Canyon Triad Port Jam Pitt Bonsai Plummet Juliett'.split()))
EXPORT = OUT / 'native-volume-export/properties/ShooterGame/Content'
DEPENDENCIES = OUT / 'native-volume-dependencies/properties/ShooterGame/Content'
ABYSS_EXPORT = OUT / 'native-abyss-volume/properties/ShooterGame/Content'
REMAINING_EXPORT = OUT / 'native-remaining-volumes/properties/ShooterGame/Content'
REMAINING_DEPENDENCIES = OUT / 'native-remaining-dependencies/properties/ShooterGame/Content'
SUPERGRID_EXPORT = OUT / 'native-supergrid-floor/properties/ShooterGame/Content'


def walkable_slope_angle(row, default=44.):
    """Apply local collision slope overrides to the extracted map slope limit."""
    override = row.get('body', {}).get('WalkableSlopeOverride', {})
    behavior = override.get('WalkableSlopeBehavior', '')
    angle = override.get('WalkableSlopeAngle', 0.)
    if behavior.endswith('WalkableSlope_Increase'):
        return max(default, angle)
    if behavior.endswith('WalkableSlope_Decrease'):
        return min(default, angle)
    return default


def package_path(reference):
    if reference.startswith('/Engine/'):
        path = OUT/'native-engine-cube/properties/Engine/Content'/(reference.split('.')[0].removeprefix('/Engine/')+'.json')
        return path if path.exists() else None
    relative = reference.split('.')[0].removeprefix('/Game/') + '.json'
    return next((root / relative for root in [EXPORT, DEPENDENCIES, ABYSS_EXPORT, REMAINING_EXPORT, REMAINING_DEPENDENCIES, SUPERGRID_EXPORT]
                 if (root / relative).exists()), None)


def vector(value):
    return np.array([value[k] for k in 'XYZ'], dtype=float)


def collision_parts(body, render_triangles, matrix):
    """Use serialized simple collision, or the explicitly selected complex mesh."""
    if body.get('CollisionTraceFlag', '').endswith('CTF_UseComplexAsSimple'):
        # Some complex collision meshes are closed convex ramps. Certify the
        # same boundary before using convex clearance; never fill an open sheet
        # or a concavity merely because its vertices have a convex hull.
        vertices, indices = np.unique(render_triangles.reshape(-1, 3), axis=0, return_inverse=True)
        indices = indices.reshape(-1, 3)
        edges = np.sort(np.concatenate([indices[:,[0,1]],indices[:,[1,2]],indices[:,[2,0]]]),axis=1)
        closed = bool(np.all(np.unique(edges,axis=0,return_counts=True)[1]==2))
        if len(vertices) >= 4 and np.linalg.matrix_rank(vertices-vertices[0]) == 3:
            hull = ConvexHull(vertices)
            area = np.linalg.norm(np.cross(render_triangles[:,1]-render_triangles[:,0],
                render_triangles[:,2]-render_triangles[:,0]),axis=1).sum()/2
            centers = render_triangles.mean(axis=1)
            on_boundary = np.max(centers @ hull.equations[:,:3].T+hull.equations[:,3],axis=1)
            if closed and abs(area-hull.area) < 1e-7*max(1.,hull.area) and np.all(abs(on_boundary)<1e-7):
                return [(vertices[hull.simplices], hull.equations)]
        return [(render_triangles, None)]
    aggregate = body.get('AggGeom', {})
    if any(aggregate.get(k) for k in ['SphereElems', 'SphylElems', 'TaperedCapsuleElems']):
        raise ValueError('Unsupported serialized collision shape')
    pieces = []
    for box in aggregate.get('BoxElems', []):
        if any(box['Rotation'].values()):
            raise ValueError('Nonzero box element rotation needs explicit conversion')
        corners = np.array([[x,y,z] for x in [-.5,.5] for y in [-.5,.5] for z in [-.5,.5]])
        # UE 5.3 ChaosInterfaceUtils::CreateGeometry clamps each scaled box
        # half extent to UE_KINDA_SMALL_NUMBER (1e-4 cm), including flat planes.
        # Undo that axis scale here because the placement matrix applies it below.
        scale = np.linalg.norm(matrix[:3, :3], axis=1)
        if np.any(scale <= 0):
            raise ValueError('Zero collision placement scale')
        axes = matrix[:3, :3] / scale[:, None]
        if not np.allclose(axes @ axes.T, np.eye(3), atol=1e-6):
            raise ValueError('Sheared box collision placement needs explicit conversion')
        dimensions = np.maximum(vector(box), 2e-4 / scale)
        pieces.append(corners * dimensions + vector(box['Center']))
    for convex in aggregate.get('ConvexElems', []):
        xyz = np.array([vector(v) for v in convex['VertexData']])
        transform = convex['Transform']; q = transform['Rotation']
        xyz = Rotation.from_quat([q[k] for k in 'XYZW']).apply(xyz * vector(transform['Scale3D'])) + vector(transform['Translation'])
        pieces.append(xyz)
    if not pieces:
        raise ValueError('Missing serialized simple collision')
    result = []
    for xyz in pieces:
        xyz[:, 1] *= -1
        xyz = (xyz @ matrix[:3,:3] + matrix[3,:3]) * .01
        hull = ConvexHull(xyz)
        result.append((xyz[hull.simplices], hull.equations))
    return result


def inside_closed_mesh(triangles, point):
    # Signed solid angle supports concave closed meshes. Open sheets do not
    # become fictitious closed blockers through a convex hull.
    a,b,c = (triangles-point).transpose(1,0,2)
    lengths = np.linalg.norm(triangles-point, axis=2)
    numerator = np.einsum('ij,ij->i', a, np.cross(b,c))
    denominator = np.prod(lengths,axis=1) + np.einsum('ij,ij->i',a,b)*lengths[:,2] + np.einsum('ij,ij->i',b,c)*lengths[:,0] + np.einsum('ij,ij->i',c,a)*lengths[:,1]
    angle = abs(float((2*np.arctan2(numerator,denominator)).sum()))
    return abs(angle-4*np.pi) < 1e-4


def vertical_contacts(triangles, xy):
    a,b=triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]
    det=a[:,0]*b[:,1]-a[:,1]*b[:,0]
    valid=abs(det)>1e-12; d=xy-triangles[:,0,:2]
    u=np.zeros(len(triangles));v=np.zeros(len(triangles))
    u[valid]=(d[valid,0]*b[valid,1]-d[valid,1]*b[valid,0])/det[valid]
    v[valid]=(a[valid,0]*d[valid,1]-a[valid,1]*d[valid,0])/det[valid]
    valid&=(u>=-1e-8)&(v>=-1e-8)&(u+v<=1+1e-8)
    return triangles[:,0,2]+u*a[:,2]+v*b[:,2], valid


@lru_cache(maxsize=64)
def load_json(path):
    return json.loads(Path(path).read_text())


def capsule_mesh_distance(triangles, xy, floor, radius=.42, height=1.96):
    """Exact surface distance from the capsule's vertical axis segment."""
    start = np.r_[xy, floor + radius]
    end = np.r_[xy, floor + height - radius]
    axis = end - start
    a = float(axis @ axis)
    best = min(float(nearest_triangle_point(triangles, start)[0].min()),
               float(nearest_triangle_point(triangles, end)[0].min()))
    # The segment crosses a triangle interior when XY lies in its projection.
    u, v = triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0]
    n = np.cross(u, v)
    det = n[:, 2]
    good = abs(det) > 1e-12
    if good.any():
        t = triangles[good]; uu, vv, dd = u[good], v[good], det[good]
        delta = xy - t[:, 0, :2]
        b = (delta[:, 0] * vv[:, 1] - delta[:, 1] * vv[:, 0]) / dd
        c = (uu[:, 0] * delta[:, 1] - uu[:, 1] * delta[:, 0]) / dd
        z = t[:, 0, 2] + b * uu[:, 2] + c * vv[:, 2]
        if ((b >= 0) & (c >= 0) & (b+c <= 1) & (z >= start[2]) & (z <= end[2])).any():
            return 0.
    # Otherwise the closest triangle point lies on an edge or is closest to
    # one of the segment endpoints. Evaluate all edge boundary cases exactly.
    for i in range(3):
        p = triangles[:, i]; edge = triangles[:, (i+1)%3] - p
        c = np.einsum('ij,ij->i', edge, edge)
        b = edge @ axis; w = start - p
        d = w @ axis; e = np.einsum('ij,ij->i', edge, w)
        den = a*c-b*b
        valid = den > 1e-20
        s, t = np.zeros(len(edge)), np.zeros(len(edge))
        s[valid] = (b[valid]*e[valid]-c[valid]*d[valid])/den[valid]
        t[valid] = (a*e[valid]-b[valid]*d[valid])/den[valid]
        valid &= (s >= 0)&(s <= 1)&(t >= 0)&(t <= 1)
        delta = start + s[:,None]*axis - p - t[:,None]*edge
        if valid.any():
            best = min(best,float(np.sum(delta[valid]**2,axis=1).min()))
        for endpoint in [p, p+edge]:
            s = np.clip((endpoint-start) @ axis/a,0,1)
            best = min(best,float(np.sum((endpoint-start-s[:,None]*axis)**2,axis=1).min()))
    return float(np.sqrt(best))


class StandingVolumes:
    def __init__(self, name):
        self.name, self.rows, self.triangles, self.equations, self.unresolved = name, [], [], [], []
        code = CODES[name]
        roots=list((ROOT.parent/'2026-09-04/all-worlds-13.05').glob(f'*/Exports/ShooterGame/Content/Maps/{code}'))
        if name=='split':roots=[ROOT.parent/'2026-09-04/split-cli-13.05-verified-options/Exports/ShooterGame/Content/Maps/Bonsai']
        root=next((p for p in roots if '-detex' in str(p)),roots[0])
        paths=[p for p in root.glob('*.usda') if p.stem==code or any(p.stem.endswith('_'+s) for s in ['BVPawn','BV_Pawn','Gameplay','KillVolumes','BVProjectile','BV_Projectile'])]
        self.levels=[p.stem for p in paths]
        for path in paths:
            suffix=path.stem.removeprefix(code+'_')
            levelpath = package_path(f'/Game/Maps/{code}/{path.stem}')
            if levelpath is None:
                self.unresolved.append(dict(level=path.stem,reason='Missing native volume level'));continue
            data = load_json(str(levelpath))
            resolved = load_json(str(levelpath).replace('/properties/', '/components/').replace('\\properties\\', '\\components\\'))
            component_meshes = {r['path']:r for r in resolved}
            # FModel allocates duplicate actor labels in the level's actor
            # order, which differs from the package's export-index order.
            actors={};names=Counter()
            level=next(r for r in data if r['Type']=='Level')
            for ref in level['Actors']:
                if ref is None:continue
                actor=data[int(ref['ObjectPath'].rsplit('.',1)[1])]
                label=re.sub(r'[^A-Za-z0-9_]','_',actor.get('ActorLabel',actor['Name']))
                if label and label[0].isdigit():label='_'+label
                name_index=names[label];names[label]+=1
                actors[label if name_index==0 else f'{label}_{name_index}']=actor
            # The persistent world composes every art sublevel. Its own volume
            # actors must be read once, without traversing those sublevels again.
            layer=Sdf.Layer.CreateAnonymous();layer.TransferContent(Sdf.Layer.FindOrOpen(str(path)));layer.subLayerPaths=[]
            for reference in layer.GetExternalReferences():
                if not Path(reference).is_absolute():layer.UpdateExternalReference(reference,str((path.parent/reference).resolve()).replace('\\','/'))
            stage = Usd.Stage.Open(layer); cache=UsdGeom.XformCache()
            for prim in stage.Traverse():
                if not prim.IsA(UsdGeom.Mesh):continue
                if str(prim.GetPath()).split('/')[1]!=path.stem:continue
                label = str(prim.GetPath()).split('/')[2]
                actor = actors.get(label)
                if actor is None:
                    if any(s in label for s in ['BlockingVolume','Unwalkable','PlayerKillVolume']):
                        self.unresolved.append(dict(level=f'{code}_{suffix}',label=label,reason='Missing native actor identity'))
                    continue
                kind = actor['Type']
                explicit_static=kind=='StaticMeshActor' and suffix in ['BVPawn','BV_Pawn','BVProjectile','BV_Projectile','KillVolumes']
                if not explicit_static and not any(s in kind for s in ['BlockingVolume','Unwalkable','PlayerKillVolume','StuckPickupVolume']):continue
                if actor.get('Properties',{}).get('bActorEnableCollision') is False:continue
                components = [r for r in data if r['Type']=='StaticMeshComponent' and f"PersistentLevel.{actor['Name']}'" in str(r.get('Outer'))]
                comp = next((r for r in components if r['Name']==prim.GetName()),None)
                if comp is None:
                    self.unresolved.append(dict(level=f'{code}_{suffix}',label=label,reason='Missing native component identity'));continue
                instance = comp.get('Properties',{})
                template = comp.get('Template',{}).get('ObjectPath','').split('.')[0]
                templatepath=package_path(template)
                default = {}
                if templatepath is not None:
                    defaults = [r for r in load_json(str(templatepath)) if r.get('Type')=='StaticMeshComponent']
                    if len(defaults)==1:default=defaults[0].get('Properties',{})
                body = {**default.get('BodyInstance',{}),**instance.get('BodyInstance',{})}
                if str(body.get('CollisionEnabled','')).endswith('NoCollision'):continue
                responses = body.get('CollisionResponses',{}).get('ResponseArray',[])
                pawn = next((r.get('Response','').split('::')[-1] for r in responses if r.get('Channel')=='Pawn'),None)
                if pawn in ['ECR_Ignore','ECR_Overlap'] and 'PlayerKillVolume' not in kind:continue
                unwalkable = body.get('WalkableSlopeOverride',{}).get('WalkableSlopeBehavior')=='EWalkableSlopeBehavior::WalkableSlope_Unwalkable'
                if 'Unwalkable' in kind and not unwalkable:
                    self.unresolved.append(dict(level=f'{code}_{suffix}',label=label,reason='Unresolved unwalkable slope override'));continue
                # A native StaticMeshActor can omit all component defaults.
                # Retain its exact collision as a conservative exclusion, but
                # never use that unconfirmed actor to certify a standing floor.
                collision_defaults_unknown = not body
                mesh=UsdGeom.Mesh(prim); xyz=np.asarray(mesh.GetPointsAttr().Get(),dtype=float); matrix=np.asarray(cache.GetLocalToWorldTransform(prim))
                root_component=actor.get('Properties',{}).get('RootComponent',{}).get('ObjectPath')
                if root_component and data[int(root_component.rsplit('.',1)[1])] is comp and 'RelativeLocation' in instance:
                    translation=vector(instance['RelativeLocation']);translation[1]*=-1
                    if np.max(abs(translation-matrix[3,:3]))>.2:
                        raise ValueError(('Native volume and USD actor transforms disagree',path.stem,label))
                xyz=(xyz@matrix[:3,:3]+matrix[3,:3])*.01
                counts=np.asarray(mesh.GetFaceVertexCountsAttr().Get()); ids=np.asarray(mesh.GetFaceVertexIndicesAttr().Get())
                if not (counts==3).all():raise ValueError(('Nontriangular volume',str(prim.GetPath())))
                tri=xyz[ids.reshape(-1,3)]
                resolved_component = next((r for k,r in component_meshes.items() if k.endswith(f"PersistentLevel.{actor['Name']}.{comp['Name']}")), None)
                mesh_reference=(resolved_component.get('mesh') if resolved_component else None) or instance.get('StaticMesh') or default.get('StaticMesh')
                meshpath = package_path(mesh_reference['ObjectPath']) if mesh_reference else None
                setups = [r for r in load_json(str(meshpath)) if r['Type']=='BodySetup'] if meshpath else []
                try:
                    if len(setups)!=1:raise ValueError('Missing collision body setup')
                    parts = collision_parts(setups[0].get('Properties',{}),tri,matrix)
                except ValueError as error:
                    self.unresolved.append(dict(level=f'{code}_{suffix}',label=label,reason=str(error),mesh=mesh_reference));continue
                for part,(tri,equations) in enumerate(parts):
                    xyz = tri.reshape(-1,3)
                    self.rows.append(dict(id=f'{prim.GetPath()}#{part}',kind=kind,unwalkable=unwalkable,
                        kill='PlayerKillVolume' in kind,body=body,collisionDefaultsUnknown=collision_defaults_unknown,nativeLevel=str(levelpath),sourceUsd=str(path),
                        nativeMesh=str(meshpath), bounds=[xyz.min(0).tolist(),xyz.max(0).tolist()]))
                    self.triangles.append(tri);self.equations.append(equations)
        self.bounds=np.array([r['bounds'] for r in self.rows])
        self.tree=shapely.STRtree(shapely.box(self.bounds[:,0,0],self.bounds[:,0,1],self.bounds[:,1,0],self.bounds[:,1,1]))

    def physical_floor(self, xy, source_floor, maximum_offset=.6):
        contacts=[]
        for i in self.tree.query(shapely.Point(xy)):
            if self.rows[i]['kill'] or self.rows[i].get('collisionDefaultsUnknown'):continue
            z,valid=vertical_contacts(self.triangles[i],xy)
            if not valid.any():continue
            top=float(z[valid].max())
            if source_floor-maximum_offset<=top<=source_floor+.2:
                contacts.append((top,self.rows[i]['id']))
        return max(contacts,default=(source_floor,None))

    def capsule_floor(self, xy, floor, radius=.42):
        """Place the rounded feet tangent to a local walkable floor plane.

        On a slope the capsule's lowest point is slightly above the geometric
        floor directly under its axis. Testing it at the flat-floor position
        incorrectly reports ordinary ramps as player penetration.
        """
        lift=0.
        for i in self.tree.query(shapely.Point(xy)):
            if self.rows[i]['kill']:continue
            tri=self.triangles[i];z,valid=vertical_contacts(tri,xy)
            if not valid.any() or abs(float(z[valid].max())-floor)>.015:continue
            contacts=tri[valid & (abs(z-floor)<.015)]
            n=np.cross(contacts[:,1]-contacts[:,0],contacts[:,2]-contacts[:,0]);length=np.linalg.norm(n,axis=1)
            cosine=np.cos(np.deg2rad(walkable_slope_angle(self.rows[i])))
            walkable=(abs(n[:,2])>=length*cosine-1e-9)&(abs(n[:,2])>1e-9)&(length>1e-9)
            if walkable.any():lift=max(lift,float((radius*(length[walkable]/abs(n[walkable,2])-1)).max()))
        return floor+lift

    def standing_contact(self,index,xy,floor,plane,radius=.42):
        """Settle the rounded feet onto the highest contacting player collider."""
        lift=radius*(np.sqrt(1+float(np.asarray(plane[:2])@plane[:2]))-1)
        candidates=[]
        for i in self.tree.query(shapely.Point(xy).buffer(radius)):
            if self.bounds[i,1,2]<floor-.0011 or self.bounds[i,0,2]>floor+radius+lift:continue
            contact=self.body_standing_contact(i,xy,floor,plane,radius)
            if contact is not None:candidates.append(dict(**contact,collision=self.rows[i]['id']))
        return max(candidates,key=lambda r:r['capsuleFloorMeters'],default=None)

    def body_standing_contact(self,index,xy,floor,plane,radius=.42):
        """Find an actual walkable bottom-sphere contact, including mesh edges."""
        triangles=self.triangles[index]
        cosine=np.cos(np.deg2rad(walkable_slope_angle(self.rows[index])))
        lift=radius*(np.sqrt(1+float(np.asarray(plane[:2])@plane[:2]))-1)
        lower,upper=floor+radius-.0011,floor+radius+lift+.0011
        candidates=[]
        def add(heights,points,valid,kind):
            valid=valid & np.isfinite(heights) & (heights>=lower) & (heights<=upper)
            ids=np.flatnonzero(valid)
            if len(ids):
                i=ids[np.argmax(heights[ids])]
                candidates.append(dict(capsuleFloorMeters=float(heights[i]-radius),
                    contactPoint=points[i].tolist(),contactKind=kind))
        normals=np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0])
        lengths=np.linalg.norm(normals,axis=1)
        normals=np.divide(normals,lengths[:,None],out=np.zeros_like(normals),where=lengths[:,None]>1e-12)
        normals[normals[:,2]<0]*=-1
        valid=(normals[:,2]>=cosine)&(normals[:,2]>1e-8)
        heights=np.full(len(triangles),np.nan)
        heights[valid]=(np.einsum('ij,ij->i',normals[valid],triangles[valid,0])-normals[valid,:2]@xy+radius)/normals[valid,2]
        points=np.c_[np.broadcast_to(xy,(len(triangles),2)),heights]-radius*normals
        _,inside=vertical_contacts(triangles,points[:,:2])
        add(heights,points,valid & inside,'face')
        for j in range(3):
            a=triangles[:,j];edge=triangles[:,(j+1)%3]-a;delta=xy-a[:,:2]
            squared=np.einsum('ij,ij->i',edge,edge);dot=np.einsum('ij,ij->i',delta,edge[:,:2])
            good=squared>1e-16
            A=np.zeros(len(a));B=np.zeros(len(a));C=np.zeros(len(a))
            A[good]=np.sum(edge[good,:2]**2,axis=1)/squared[good]
            B[good]=-2*dot[good]*edge[good,2]/squared[good]
            C[good]=np.sum(delta[good]**2,axis=1)-dot[good]**2/squared[good]-radius**2
            discriminant=B*B-4*A*C
            good &= (A>1e-12)&(discriminant>=0)
            offset=np.zeros(len(a));offset[good]=(-B[good]+np.sqrt(discriminant[good]))/(2*A[good])
            fraction=np.zeros(len(a));fraction[good]=(dot[good]+offset[good]*edge[good,2])/squared[good]
            points=a+fraction[:,None]*edge;heights=a[:,2]+offset
            good &= (fraction>=0)&(fraction<=1)&((heights-points[:,2])/radius>=cosine)
            add(heights,points,good,'edge')
            remaining=radius**2-np.sum(delta**2,axis=1)
            good=remaining>=0;heights=a[:,2]+np.sqrt(np.maximum(remaining,0))
            good &= (heights-a[:,2])/radius>=cosine
            add(heights,a,good,'vertex')
        return max(candidates,key=lambda r:r['capsuleFloorMeters'],default=None)

    def exclusions(self, xy, floor, radius=.42,height=1.96,standing_plane=None,capsule_floor_override=None):
        result=[]
        capsule_floor=(self.capsule_floor(xy,floor,radius) if standing_plane is None
            else floor+radius*(np.sqrt(1+float(np.asarray(standing_plane[:2])@standing_plane[:2]))-1))
        if capsule_floor_override is not None:capsule_floor=capsule_floor_override
        for i in self.tree.query(shapely.Point(xy).buffer(radius)):
            row=self.rows[i];bounds=self.bounds[i]
            if bounds[1,2] < floor-.1 or bounds[0,2] > capsule_floor+height:continue
            tri=self.triangles[i];equations=self.equations[i]
            midpoint=np.r_[xy,capsule_floor+height/2]
            inside=(np.all(equations[:,:3]@midpoint+equations[:,3]<-1e-6)
                    if equations is not None else inside_closed_mesh(tri,midpoint))
            distance=0. if inside else capsule_mesh_distance(tri,xy,capsule_floor,radius,height)
            if (row['unwalkable'] or row.get('collisionDefaultsUnknown')) and distance<radius+.00011:
                result.append(dict(volume=row['id'],reason='unconfirmed-collision-defaults' if row.get('collisionDefaultsUnknown') else 'explicit-unwalkable-contact',surfaceDistanceMeters=distance));continue
            # Match the builder's one-millimetre contact tolerance, with a
            # tenth of a millimetre for serialized plane/clip roundoff.
            if distance<(radius+.00011 if row['kill'] else radius-.0011):
                result.append(dict(volume=row['id'],reason='player-kill-volume' if row['kill'] else 'player-capsule-blocked',surfaceDistanceMeters=distance))
        return result
