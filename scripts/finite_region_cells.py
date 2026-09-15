"""Finite-cell clipping prototype; no source geometry or field simplification."""
from fractions import Fraction
from itertools import combinations
import numpy as np
from authored_region_cells import barycentric
from authored_wall_profile_cells import target_barycentrics
from finite_edge_owners import edge_owners


def source_frame(data):
    candidates=list(combinations(range(len(data)),3))
    def area(ids):
        p=data[list(ids),4:6];a=p[1]-p[0];b=p[2]-p[0];return abs(a[0]*b[1]-a[1]*b[0])
    basis=max(candidates,key=area);local=None
    if area(basis)>0:
        reference=data[list(basis)]
        try:local=barycentric(data[:,4:6],reference[:,4:6])
        except np.linalg.LinAlgError:
            ref=[[Fraction(float(v)) for v in p] for p in reference[:,4:6]];a=[ref[1][i]-ref[0][i] for i in range(2)];b=[ref[2][i]-ref[0][i] for i in range(2)];det=a[0]*b[1]-a[1]*b[0]
            if det:
                rows=[]
                for point in data[:,4:6]:
                    d=[Fraction(float(point[i]))-ref[0][i] for i in range(2)];u=(d[0]*b[1]-d[1]*b[0])/det;v=(a[0]*d[1]-a[1]*d[0])/det;rows.append([float(1-u-v),float(u),float(v)])
                local=np.array(rows)
    if local is None:
        local=data[:,3:6];reference=np.zeros((3,data.shape[1]));reference[:,:2]=np.linalg.lstsq(local,data[:,:2],rcond=None)[0]
    return reference,local


def exact_initial_data(data,certificate=None,*,source_construction=None):
    rows=[[Fraction(float(x)) for x in row] for row in data]
    original=source_construction
    legacy=getattr(certificate,'exact_source_data',None)
    if original is None:original=legacy
    elif legacy is not None and original!=legacy:raise ValueError('Conflicting exact source constructions')
    if original is not None:
        if len(original)!=3 or any(len(row)!=data.shape[1] for row in original):raise ValueError('Invalid original source triangle construction')
        if any(not isinstance(value,Fraction) for row in original for value in row):raise TypeError('Exact source construction requires rational coordinates')
        if [row[3:6] for row in original]!=[[Fraction(int(i==j)) for i in range(3)] for j in range(3)]:raise ValueError('Source construction must use the original triangle barycentric basis')
        return [[original[0][k]+row[4]*(original[1][k]-original[0][k])+row[5]*(original[2][k]-original[0][k]) for k in range(len(row))] for row in rows]
    def area(ids):
        a,b,c=[rows[i] for i in ids];return (b[4]-a[4])*(c[5]-a[5])-(b[5]-a[5])*(c[4]-a[4])
    basis=max(combinations(range(len(rows)),3),key=lambda ids:abs(area(ids)))
    determinant=area(basis)
    if not determinant:return rows
    a,b,c=[rows[i] for i in basis];output=[]
    for row in rows:
        x,y=row[4]-a[4],row[5]-a[5];u=(x*(c[5]-a[5])-y*(c[4]-a[4]))/determinant;v=((b[4]-a[4])*y-(b[5]-a[5])*x)/determinant
        output.append([a[k]+u*(b[k]-a[k])+v*(c[k]-a[k]) for k in range(len(row))])
    return output


def exact_weights(point,triangle):
    a,b,c=triangle;u=[b[k]-a[k] for k in range(2)];v=[c[k]-a[k] for k in range(2)];d=[point[k]-a[k] for k in range(2)]
    det=u[0]*v[1]-u[1]*v[0]
    if not det:raise ValueError('Degenerate source cell')
    x=(d[0]*v[1]-d[1]*v[0])/det;y=(u[0]*d[1]-u[1]*d[0])/det
    return [1-x-y,x,y]


def partition_mesh(data,points,triangles,*,containment_certificate=None,return_weights=False,
                   source_construction=None,exact_rows=None,return_exact=False):
    if exact_rows is not None and source_construction is not None:raise ValueError('Ambiguous exact source input')
    initial=exact_rows if exact_rows is not None else exact_initial_data(data,containment_certificate,source_construction=source_construction)
    if exact_rows is not None and any(not isinstance(x,Fraction) for row in initial for x in row):raise TypeError('Exact clipping rows must be rational')
    bounds_data=np.array([[float(x) for x in row[:2]] for row in initial]) if source_construction is not None or exact_rows is not None else data[:,:2]
    lower=np.nextafter(bounds_data.min(0),-np.inf);upper=np.nextafter(bounds_data.max(0),np.inf)
    coords=points[triangles];relevant=(coords.max(1)>=lower-1e-10).all(1)&(coords.min(1)<=upper+1e-10).all(1)
    output=[];owners=edge_owners(triangles);zero_pieces=set()
    point_image=all(row[:2]==initial[0][:2] for row in initial)
    for cell in np.flatnonzero(relevant):
        triangle=[[Fraction(float(x)) for x in row] for row in coords[cell]];a,b,c=triangle;orientation=(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);assert orientation!=0;sign=1 if orientation>0 else -1;part=initial
        for i,j in zip(range(3),[1,2,0]):
            a,b=triangle[i],triangle[j];direction=[b[k]-a[k] for k in range(2)]
            def distance(row):return sign*(direction[0]*(row[1]-a[1])-direction[1]*(row[0]-a[0]))
            # Exact shared-edge ownership retains vertical source sheets once.
            if all(distance(row)==0 for row in initial) and owners[tuple(sorted((int(triangles[cell,i]),int(triangles[cell,j]))))]!=cell:
                part=[];break
            values=[distance(row) for row in part]
            if min(values,default=0)>=0:continue
            clipped=[]
            for k,(v,next_v) in enumerate(zip(part,part[1:]+part[:1])):
                av,bv=values[k],values[(k+1)%len(part)]
                if av>=0:clipped.append(v)
                if (av>=0)!=(bv>=0):
                    parameter=av/(av-bv);clipped.append([x+(y-x)*parameter for x,y in zip(v,next_v)])
            part=[]
            for row in clipped:
                if not part or row!=part[-1]:part.append(row)
            if len(part)>1 and part[0]==part[-1]:part.pop()
            if not part:break
        if not part:continue
        # Keep nonempty line/point intersections in explicit degenerate rows.
        # Identical zero-source-area pieces receive the first cell only.
        area=sum((a[4]*b[5]-a[5]*b[4] for a,b in zip(part,part[1:]+part[:1])),Fraction(0))
        if area==0:
            key=tuple(sorted(set(tuple(row[3:6]) for row in part)))
            if key in zero_pieces:continue
            zero_pieces.add(key)
        while len(part)<3:part.append(part[-1])
        exact_part=part
        rational_weights=[exact_weights(row,triangle) for row in exact_part]
        assert min(value for row in rational_weights for value in row)>=0, 'Exact clipping escaped its finite cell'
        part=np.array([[float(x) for x in row] for row in part])
        # Precise construction already proved these weights inside the cell.
        # Re-inverting rounded coordinates can put a thin cell's boundary
        # outside itself. Preserve the exact clipping result for interpolation.
        weights=(np.array([[float(x) for x in row] for row in rational_weights])
                 if source_construction is not None or exact_rows is not None
                 or getattr(containment_certificate,'exact_source_data',None) is not None
                 else barycentric(part[:,:2],coords[cell]))
        if weights.min() < -1e-8:
            if containment_certificate is None:raise ValueError('Finite region piece has no containing cell')
            selected=np.zeros(len(triangles),bool);selected[cell]=True;certified,weights=containment_certificate(part,points,triangles,selected);assert certified==cell
        if return_exact:output.append((part,int(cell),weights,exact_part,rational_weights))
        else:output.append((part,int(cell),weights) if return_weights else (part,int(cell)))
        if point_image:break
    if not output:raise ValueError('Finite source polygon is outside its declared region')
    return output


def region_fragments(data,family,warp,*,containment_certificate=None,source_construction=None):
    source=np.asarray(family['sourceVerticesSvg']);target=np.asarray(family['targetVerticesSvg']);triangles=np.asarray(family['triangles'],dtype=int)
    rank_one={row['cell']:(declaration,row) for declaration in family.get('declaredRankOneMappings',[]) for row in declaration['cells']};output=[]
    precise=source_construction is not None
    parts=partition_mesh(data,source,triangles,containment_certificate=containment_certificate,return_weights=True,
        source_construction=source_construction,return_exact=precise)
    for entry in parts:
        part,region_cell,weights=entry[:3]
        canonical=part.copy()
        if region_cell in rank_one:
            declaration,row=rank_one[region_cell];endpoints=np.asarray(declaration['targetEndpointsSvg'],dtype=float);parameters=np.asarray(row['vertexParameters'],dtype=float);expected=endpoints[0]+parameters[:,None]*(endpoints[1]-endpoints[0]);arithmetic=np.finfo(float).eps*8*max(1.,float(np.abs(expected).max()))
            if np.abs(expected-target[triangles[region_cell]]).max()>arithmetic:raise ValueError('Rank-one declaration differs from stored target vertices')
            canonical[:,:2]=endpoints[0]+(weights@parameters)[:,None]*(endpoints[1]-endpoints[0])
        else:canonical[:,:2]=weights@target[triangles[region_cell]]
        exact_canonical=None
        if precise:
            exact_part,rational_weights=entry[3:]
            exact_canonical=[row.copy() for row in exact_part]
            if region_cell in rank_one:
                endpoints=[[Fraction(float(x)) for x in row] for row in declaration['targetEndpointsSvg']]
                parameters=[Fraction(float(x)) for x in row['vertexParameters']]
                for row,w in zip(exact_canonical,rational_weights):
                    t=sum(a*b for a,b in zip(w,parameters))
                    row[:2]=[endpoints[0][k]+t*(endpoints[1][k]-endpoints[0][k]) for k in range(2)]
            else:
                destination=[[Fraction(float(x)) for x in row] for row in target[triangles[region_cell]]]
                for row,w in zip(exact_canonical,rational_weights):
                    row[:2]=[destination[0][k]+w[1]*(destination[1][k]-destination[0][k])+w[2]*(destination[2][k]-destination[0][k]) for k in range(2)]
            canonical=np.array([[float(x) for x in row] for row in exact_canonical])
        for final,warp_cell in partition_mesh(canonical,warp.points,warp.tri.simplices,exact_rows=exact_canonical):
            if target_barycentrics(final[:,:2],warp,warp_cell).min() < -1e-8:raise ValueError('Finite region fragment crosses W cell')
            output.append((final,warp_cell,region_cell))
    return output
