"""Add the original122 continuation branch to the connected barrier field."""
import json
import numpy as np
import shapely
from build_split_connected_tower import REV
from declare_split_barrier_corridor_region import declaration as base
from authored_wall_profile_cells import partition_linear


def conform_mesh(vertices,triangles,lookup):
    points=np.array(vertices);conforming=[]
    for cell in triangles:
        boundary=[]
        for a,b in zip(cell,np.roll(cell,-1)):
            start=points[a];direction=points[b]-start;length2=direction@direction
            if length2==0:continue
            along=(points-start)@direction/length2
            residual=points-(start+along[:,None]*direction)
            on=(along>1e-12)&(along<1-1e-12)&(np.linalg.norm(residual,axis=1)<1e-9)
            boundary.append(a);boundary.extend(np.flatnonzero(on)[np.argsort(along[on])].tolist())
        polygon=shapely.Polygon(points[boundary])
        if polygon.area==0:continue
        for tri in shapely.get_parts(shapely.constrained_delaunay_triangles(polygon)):
            ids=[lookup[tuple(np.round(p,11))] for p in np.array(tri.exterior.coords)[:3]]
            if len(set(ids))==3:conforming.append(ids)
    return conforming


def _declaration(refine_interior=True):
    family=base(refine_interior=refine_interior);source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    lo=337.9168145581444;hi=337.91724562417824;join_y=263.6525668098494
    vertices=[];mapped=[];triangles=[];lookup={}
    def add(point,value):
        key=tuple(np.round(point,11))
        if key in lookup:
            index=lookup[key];assert np.linalg.norm(mapped[index]-value)<1e-7;return index
        index=len(vertices);lookup[key]=index;vertices.append(np.array(key));mapped.append(value);return index
    for cell in cells:
        parts=partition_linear(np.column_stack((source[cell],target[cell])),np.zeros(2),np.array([0.,1.]),[join_y-1.,join_y,270.,272.])
        refined=[]
        for part in parts:
            if part[:,1].max()<=join_y-1. or part[:,1].min()>=272.:refined.append(part)
            else:refined.extend(partition_linear(part,np.zeros(2),np.array([1.,0.]),[lo,hi]))
        parts=refined
        for part in parts:
            points=part[:,:2];values=part[:,2:].copy()
            weight=np.clip(points[:,1]-(join_y-1),0,1)*np.clip((272-points[:,1])/2,0,1)
            selected=(points[:,0]>=lo-1e-10)&(points[:,0]<=hi+1e-10)
            values[selected,0]=(1-weight[selected])*values[selected,0]+weight[selected]*338.617
            ids=[add(p,q) for p,q in zip(points,values)]
            for j in range(1,len(ids)-1):
                if len({ids[0],ids[j],ids[j+1]})==3:triangles.append([ids[0],ids[j],ids[j+1]])
    points=np.array(vertices);conforming=conform_mesh(vertices,triangles,lookup)
    family.update(sourceVerticesSvg=points.tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=conforming)
    family['continuationBranch']=dict(object=6166,sourceXBand=[lo,hi],sourceJoinY=join_y,targetX=338.617,fullConstraintY=[join_y,270.],identityTransitionY=[270.,272.],heightPolicy='Original Z unchanged; continuation remains a separate geometric branch below the authored123/122 join. No inferred height fill.')
    family['status']='Continuation-branch prototype, no bake; requires topology and source profile checks.'
    return family


def declaration():
    reviewed=_declaration(True)
    simplified=_declaration(False)
    # The continuation branch has exactly zero influence below this line.
    # Preserve its reviewed triangulation above the line; below it, source-W
    # cuts inside a single affine cell are redundant. This avoids microscopic
    # containment cells without changing the branch's interpolation domain.
    boundary=263.6525668098494-1.
    vertices=[];mapped=[];triangles=[];lookup={}
    def add(point,value):
        key=tuple(np.round(point,11))
        if key in lookup:
            index=lookup[key]
            assert np.linalg.norm(mapped[index]-value)<1e-7
            return index
        index=len(vertices);lookup[key]=index;vertices.append(np.array(key));mapped.append(value);return index
    for family,upper in [(reviewed,True),(simplified,False)]:
        source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg'])
        for cell in np.array(family['triangles']):
            parts=partition_linear(np.column_stack((source[cell],target[cell])),np.zeros(2),np.array([0.,1.]),[boundary])
            for part in parts:
                if (part[:,1].mean()>=boundary)!=upper:continue
                ids=[add(p[:2],p[2:]) for p in part]
                for j in range(1,len(ids)-1):
                    if len({ids[0],ids[j],ids[j+1]})==3:triangles.append([ids[0],ids[j],ids[j+1]])
    points=np.array(vertices);conforming=[]
    seam_y=round(boundary,11);seam=np.flatnonzero(points[:,1]==seam_y)
    for cell in triangles:
        ring=[]
        for a,b in zip(cell,np.roll(cell,-1)):
            ring.append(a)
            if points[a,1]==seam_y and points[b,1]==seam_y:
                lo,hi=sorted([points[a,0],points[b,0]])
                inside=seam[(points[seam,0]>lo)&(points[seam,0]<hi)]
                order=np.argsort(points[inside,0])
                if points[b,0]<points[a,0]:order=order[::-1]
                ring.extend(inside[order].tolist())
        if len(ring)==3:conforming.append(cell);continue
        polygon=shapely.Polygon(points[ring])
        if polygon.area==0:continue
        for tri in shapely.get_parts(shapely.constrained_delaunay_triangles(polygon)):
            conforming.append([lookup[tuple(np.round(p,11))] for p in np.array(tri.exterior.coords)[:3]])
    reviewed.update(sourceVerticesSvg=points.tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=conforming)
    reviewed['sourcePartitionMethod']='finite-convex-cells-v1'
    reviewed['sourceContainmentArithmeticPolicy']=dict(format='icarus-source-cell-coordinate-certificate-v1',coordinateStorageUlps=1,maximumMappedExtensionErrorSvg=1e-7)
    reviewed['affineSubdivisionReduction']=dict(sourceYUpperBound=boundary,scope='Only below the exact zero-influence boundary of the continuation branch. Reviewed branch cells retained above it; outer source-W boundary splits retained.')
    return reviewed


if __name__=='__main__':
    out=REV/'split-barrier-corridor-region-proposal-v2';out.mkdir(exist_ok=True);(out/'region-declaration.json').write_text(json.dumps(declaration(),indent=2));print(out)
