"""Carry source barycentrics through a declared continuous XY region field."""
import numpy as np
from itertools import combinations
from fractions import Fraction
from authored_wall_profile_cells import partition_linear, target_barycentrics

def barycentric(xy,tri):
    # Translation belongs outside the solve. Homogeneous coordinates amplify
    # large absolute SVG offsets in narrow cells and can reject valid pieces.
    uv=np.linalg.solve((tri[1:]-tri[0]).T,(xy-tri[0]).T).T
    return np.column_stack((1-uv.sum(1),uv))

def partition_mesh(data,points,triangles,*,containment_certificate=None,return_weights=False):
    """Split by cell edges, then assign each piece once, including vertical sheets."""
    coords=points[triangles]
    relevant=(coords.max(1)>=data[:,:2].min(0)-1e-10).all(1)&(coords.min(1)<=data[:,:2].max(0)+1e-10).all(1)
    edges=sorted(set(tuple(sorted(e)) for t in triangles[relevant] for e in zip(t,np.roll(t,-1))))
    # Cuts must be affine in the original source triangle, including when XY
    # has collapsed onto a point or line. Re-evaluating near-zero XY dot
    # products on successively rounded intersections can give a convex source
    # polygon alternating signs, producing overlapping fan triangles.
    # Carry a fixed source-barycentric frame through every cut instead.
    indices=list(combinations(range(len(data)),3))
    def area(ids):
        p=data[list(ids),4:6];a=p[1]-p[0];b=p[2]-p[0]
        return abs(a[0]*b[1]-a[1]*b[0])
    basis=max(indices,key=area)
    local=None
    if area(basis)>0:
        reference=data[list(basis)]
        try:local=barycentric(data[:,4:6],reference[:,4:6])
        except np.linalg.LinAlgError:
            # Some zero-area boundary pieces round to a tiny nonzero float
            # determinant. Distinguish them from a real narrow source basis
            # using the exact stored binary64 values, without an area cutoff.
            ref=[[Fraction(float(v)) for v in p] for p in reference[:,4:6]]
            a=[ref[1][i]-ref[0][i] for i in range(2)];b=[ref[2][i]-ref[0][i] for i in range(2)]
            determinant=a[0]*b[1]-a[1]*b[0]
            if determinant:
                rows=[]
                for point in data[:,4:6]:
                    q=[Fraction(float(point[i]))-ref[0][i] for i in range(2)]
                    u=(q[0]*b[1]-q[1]*b[0])/determinant;v=(a[0]*q[1]-a[1]*q[0])/determinant
                    rows.append([float(1-u-v),float(u),float(v)])
                local=np.array(rows)
    if local is None:
        # A zero-source-area boundary fragment still needs cell membership;
        # its original source weights provide a consistent affine extension.
        local=data[:,3:6]
        reference=np.zeros((3,data.shape[1]));reference[:,:2]=np.linalg.lstsq(local,data[:,:2],rcond=None)[0]
    width=data.shape[1]
    parts=[np.column_stack((data,local))]
    for a,b in edges:
        origin=points[a];d=points[b]-origin;normal=np.array([-d[1],d[0]])
        if np.linalg.norm(normal)<1e-12:continue
        reference_distances=(reference[:,:2]-origin)@normal
        updated=[]
        for part in parts:
            distances=part[:,width:]@reference_distances
            if distances.min()>=0 or distances.max()<=0:
                updated.append(part);continue
            left=[];right=[]
            for i,(v,next_v) in enumerate(zip(part,np.roll(part,-1,axis=0))):
                av=float(distances[i]);bv=float(distances[(i+1)%len(part)])
                (right if av>=0 else left).append(v)
                if (av>=0)!=(bv>=0):
                    q=v+(next_v-v)*av/(av-bv);left.append(q);right.append(q)
            if len(left)>=3:updated.append(np.array(left))
            if len(right)>=3:updated.append(np.array(right))
        parts=updated
    output=[]
    for part in parts:
        chosen=[]
        for cell in np.flatnonzero(relevant):
            weights=barycentric(part[:,:2],coords[cell])
            if weights.min()>=-1e-8:chosen.append(int(cell))
        if not chosen:
            if containment_certificate is None:raise ValueError('Region piece has no containing cell')
            cell,weights=containment_certificate(part[:,:width],points,triangles,relevant)
            chosen=[cell]
        else:weights=barycentric(part[:,:2],coords[chosen[0]])
        output.append((part[:,:width],chosen[0],weights) if return_weights else (part[:,:width],chosen[0]))
    return output

def region_fragments(data,family,warp,*,containment_certificate=None):
    source=np.asarray(family['sourceVerticesSvg']);target=np.asarray(family['targetVerticesSvg']);triangles=np.asarray(family['triangles'],dtype=int)
    rank_one={row['cell']:(declaration,row) for declaration in family.get('declaredRankOneMappings',[]) for row in declaration['cells']}
    output=[]
    for part,region_cell,weights in partition_mesh(data,source,triangles,containment_certificate=containment_certificate,return_weights=True):
        canonical=part.copy()
        if region_cell in rank_one:
            declaration,row=rank_one[region_cell]
            endpoints=np.asarray(declaration['targetEndpointsSvg'],dtype=float)
            parameters=np.asarray(row['vertexParameters'],dtype=float)
            expected=endpoints[0]+parameters[:,None]*(endpoints[1]-endpoints[0])
            arithmetic=np.finfo(float).eps*8*max(1.,float(np.abs(expected).max()))
            if np.abs(expected-target[triangles[region_cell]]).max()>arithmetic:
                raise ValueError('Rank-one declaration differs from stored target vertices')
            canonical[:,:2]=endpoints[0]+(weights@parameters)[:,None]*(endpoints[1]-endpoints[0])
        else:canonical[:,:2]=weights@target[triangles[region_cell]]
        for final,warp_cell in partition_mesh(canonical,warp.points,warp.tri.simplices):
            if target_barycentrics(final[:,:2],warp,warp_cell).min() < -1e-8:raise ValueError('Region fragment crosses W cell')
            output.append((final,warp_cell,region_cell))
    return output
