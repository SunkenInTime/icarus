"""Rounded standing-capsule clearance against the actual complex triangle soup."""
from collections import OrderedDict
from types import SimpleNamespace
import numpy as np
import shapely
from scipy.spatial import ConvexHull
from gameplay_standing_volumes import inside_closed_mesh


def complex_capsule_obstacle(volumes,index,domain,plane,height=1.96,contact_tolerance=.001):
    from build_all_map_gameplay_supports import convex_capsule_obstacle,union_clearance
    triangles=volumes.triangles[index]
    models=getattr(volumes,'_complex_capsules',None)
    if models is None:models=volumes._complex_capsules=OrderedDict()
    key=(index,height)
    if key not in models:
        bounds=np.stack([triangles[:,:,:2].min(1),triangles[:,:,:2].max(1)],axis=1)
        models[key]=SimpleNamespace(triangles=[None]*len(triangles),equations=[None]*len(triangles),
            tree=shapely.STRtree(shapely.box(bounds[:,0,0],bounds[:,0,1],bounds[:,1,0],bounds[:,1,1])),
            _capsule_support={})
        if len(models)>8:models.popitem(last=False)
    models.move_to_end(key);model=models[key]
    pieces=[];radius=.42
    lift=radius*(np.sqrt(1+float(plane[:2]@plane[:2]))-1)
    relative=triangles[:,:,2]-triangles[:,:,:2]@plane[:2]-plane[2]-lift
    horizontal_allowance=radius*np.linalg.norm(plane[:2])
    for face in model.tree.query(domain.buffer(radius)):
        if relative[face].max() < -horizontal_allowance-.001 or relative[face].min()>height+horizontal_allowance:
            continue
        if model.triangles[face] is None:
            t=triangles[face]
            normal=np.cross(t[1]-t[0],t[2]-t[0]);length=np.linalg.norm(normal)
            if length<1e-12:continue
            # Sweep the triangle by the capsule axis. The remaining rounded
            # section is a sphere whose centre is radius above the feet.
            vertices=np.concatenate([t,t-[0.,0.,height-2*radius]])
            _,singular,axes=np.linalg.svd(vertices-vertices[0],full_matrices=False)
            if singular[-1]<1e-7:
                normal=axes[-1]*1e-7
                vertices=np.concatenate([vertices+normal,vertices-normal])
            # Build thin vertical prisms in a centred, scaled frame. World
            # coordinates plus sub-micrometre thickness otherwise make Qhull
            # merge the two sides of a valid prism.
            center=vertices.mean(axis=0)
            local=(vertices-center)@axes.T
            scales=np.ptp(local,axis=0)
            hull=ConvexHull(local/scales)
            normals=(hull.equations[:,:3]/scales)@axes
            offsets=hull.equations[:,3]-normals@center
            lengths=np.linalg.norm(normals,axis=1)
            model.triangles[face]=vertices[hull.simplices]
            model.equations[face]=np.c_[normals/lengths[:,None],offsets/lengths]
        shape=convex_capsule_obstacle(model,face,domain,plane,height=2*radius,contact_tolerance=contact_tolerance)
        if not shape.is_empty:pieces.append(shape)
        if len(model._capsule_support)>512:
            model._capsule_support.pop(next(iter(model._capsule_support)))
    # Boundary distance alone misses a capsule completely enclosed by a solid.
    # Slice the real mesh at its local centre, preserving concavities and holes.
    cuts=np.zeros((len(triangles),2,2));count=np.zeros(len(triangles),dtype=int)
    for j in range(3):
        k=(j+1)%3
        crosses=(relative[:,j]<height/2)&(relative[:,k]>height/2) | (relative[:,k]<height/2)&(relative[:,j]>height/2)
        ids=np.flatnonzero(crosses)
        fraction=(height/2-relative[ids,j])/(relative[ids,k]-relative[ids,j])
        cuts[ids,count[ids]]=triangles[ids,j,:2]+fraction[:,None]*(triangles[ids,k,:2]-triangles[ids,j,:2])
        count[ids]+=1
    lines=shapely.set_precision(shapely.union_all(shapely.linestrings(cuts[count==2])),1e-7)
    for area in shapely.get_parts(shapely.polygonize(shapely.get_parts(lines))):
        if not area.intersects(domain):continue
        p=area.representative_point();z=plane[:2]@[p.x,p.y]+plane[2]+lift+height/2
        if inside_closed_mesh(triangles,np.array([p.x,p.y,z])):
            pieces.append(shapely.intersection(shapely.make_valid(area),shapely.make_valid(domain),grid_size=1e-7))
    return union_clearance(shapely.Polygon(),pieces)
