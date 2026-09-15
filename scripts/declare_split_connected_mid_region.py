"""Connected source region with explicit doorway and diagonal-corner cells."""
import gzip,json
import numpy as np
import shapely
from scipy.sparse import lil_matrix
from scipy.sparse.linalg import spsolve
from build_split_connected_tower import REV
from declare_split_hostel_balcony_mailroom_region import declaration as body
from declare_split_component2_cover_region import grid


def declaration():
    family=body()
    notch=np.load(REV/'split-original-scene-connected-source-review-v1/clove-upward-notch-full-source.npz')
    selected=np.isin(notch['sourceObjectIds'],[7609,7612,7797])
    family['reviewedSourceFaces']=sorted(set(family['reviewedSourceFaces'])|set(notch['sourceFaceIds'][selected].tolist()))
    family['objects']=sorted(set(family['objects'])|{7609,7612,7797})
    xbands=family['sourceProfileBands']['x']
    # The original square header is represented by the authored short bevel.
    # Its intermediate source point divides the original header by the two
    # authored section lengths, with the measured jamb and outer corner fixed.
    post_end=235.18003569025342
    outer_corner=240.2312494570628
    diagonal_length=float(np.linalg.norm(np.array([238.139,216.298])-np.array([236.012,213.64])))
    straight_length=240.797-238.139
    source_bevel_join=post_end+(outer_corner-post_end)*diagonal_length/(diagonal_length+straight_length)
    xbands.extend([
        dict(spans=[181],source=[212.82730106784453,212.82763663324448],target=212.62),
        dict(spans=[183],source=[219.8870750927633,220.8797744870143],target=222.445),
        dict(spans=[129],source=[234.127158234273,post_end],target=236.012),
        dict(spans=[130,131],source=[source_bevel_join,source_bevel_join],target=238.139),
        dict(spans=[102],source=[outer_corner,outer_corner],target=240.797)])
    xpoints={88.:88.,246.:246.,248.:248.}
    for b in xbands:
        for p in b['source']:xpoints[p]=b['target']
    xs=sorted(xpoints);tx=[xpoints[x] for x in xs]
    left={100.:100.,228.:228.,232.:232.}
    for b in family['sourceProfileBands']['y']:
        for value in b['source']:left[value]=b['target']
    header_low=212.454846658574
    header_high=212.64364320961064
    left.update({header_low:211.513,header_high:211.513})
    right={100.:100.,180.:180.,183.13924184175136:182.274,183.19176901236128:182.274,
           194.8692659633886:194.501,205.3136570106117:204.602,
           210.38670489944627:210.45,header_low:211.513,header_high:211.513,
           228.:228.,232.:232.}
    ys=sorted(set(left)|set(right))
    lx=sorted(left);ly=[left[y] for y in lx]
    rx=sorted(right)
    def target_at(x,y):
        ry=[right[p] for p in rx]
        header=float(np.interp(x,[220.8797744870143,234.127158234273,post_end,source_bevel_join,outer_corner],[211.513,213.64,213.64,216.298,216.298]))
        ry[rx.index(header_low)]=header;ry[rx.index(header_high)]=header
        weight=float(np.clip((x-201.3463783281243)/(212.82730106784453-201.3463783281243),0,1))
        # The notch field begins at its upper frontier. It must not blend
        # unrelated upper balcony wall167 back toward source coordinates.
        weight*=float(np.clip((y-180.)/(183.13924184175136-180.),0,1))
        return [float(np.interp(x,xs,tx)),float((1-weight)*np.interp(y,lx,ly)+weight*np.interp(y,rx,ry))]
    initial=grid(xs,ys,target_at)
    source=np.array(initial['sourceVerticesSvg']);target=np.array(initial['targetVerticesSvg']);cells=np.array(initial['triangles'])
    # Insert the measured diagonal source-profile strip into the shared mesh.
    # Shared vertices carry the same target on both sides of the strip.
    origin=np.array([212.82730106784453,194.8692659633886])
    end=np.array([220.64630299572727,205.3136570106117])
    tangent=(end-origin)/np.linalg.norm(end-origin);normal=np.array([-tangent[1],tangent[0]])
    length=float(np.linalg.norm(end-origin))
    faces=notch['trianglesSvgSourceZ'][notch['sourceObjectIds']==7797]
    normals=np.cross(faces[:,1]-faces[:,0],faces[:,2]-faces[:,0])
    horizontal=np.linalg.norm(normals[:,:2],axis=1)
    aligned=(horizontal>1e-10)&(abs(normals[:,2])<horizontal*.01)&(abs(normals[:,:2]@tangent)<horizontal*.12)
    coordinates=(faces[aligned,:,:2]-origin)@np.column_stack((tangent,normal))
    normal_min=float(coordinates[:,:,1].min());normal_max=float(coordinates[:,:,1].max())
    polygon=shapely.Polygon([origin+normal*normal_min, end+normal*normal_min,end+normal*normal_max,origin+normal*normal_max])
    points=[];mapped=[];triangles=[];lookup={}
    target_start=np.array([212.62,194.501]);target_end=np.array([222.445,204.602])
    def add(point,base):
        key=tuple(np.round(point,11))
        if key in lookup:return lookup[key]
        point=np.array(key)
        offset=point-origin;along=float(offset@tangent);across=float(offset@normal)
        if -1e-9<=along<=length+1e-9 and normal_min-1e-9<=across<=normal_max+1e-9:
            fraction=float(np.clip(along/length,0,1))
            if abs(along)<1e-10:destination=target_start.copy()
            elif abs(along-length)<1e-10:destination=target_end.copy()
            else:destination=target_start+fraction*(target_end-target_start)
        else:destination=np.asarray(base)
        index=len(points);lookup[key]=index;points.append(point);mapped.append(destination);return index
    for cell in cells:
        src=source[cell];dst=target[cell];triangle=shapely.Polygon(src)
        split_parts=[shapely.intersection(triangle,polygon),shapely.difference(triangle,polygon)] if triangle.intersects(polygon) else [triangle]
        matrix=np.column_stack((src[1]-src[0],src[2]-src[0]));inverse=np.linalg.inv(matrix)
        for part in split_parts:
            for piece in shapely.get_parts(part):
                if not isinstance(piece,shapely.Polygon) or piece.area<1e-16:continue
                for tri in shapely.get_parts(shapely.constrained_delaunay_triangles(piece)):
                    vertices=np.array(tri.exterior.coords)[:3]
                    uv=(vertices-src[0])@inverse.T
                    expected=dst[0]+uv[:,0,None]*(dst[1]-dst[0])+uv[:,1,None]*(dst[2]-dst[0])
                    ids=[add(p,q) for p,q in zip(vertices,expected)]
                    if len(set(ids))==3:triangles.append(ids)
    points=np.array(points);mapped=np.array(mapped);triangles=np.array(triangles)
    local=(points-origin)@np.column_stack((tangent,normal))
    on_strip=(local[:,0]>=-1e-9)&(local[:,0]<=length+1e-9)&(local[:,1]>=normal_min-1e-9)&(local[:,1]<=normal_max+1e-9)
    free=(local[:,0]>1e-8)&(local[:,0]<length-1e-8)&(local[:,1]>normal_min-3)&(local[:,1]<normal_max+3)&~on_strip
    free_ids=np.flatnonzero(free)
    edges={tuple(sorted((int(a),int(b)))) for tri in triangles for a,b in zip(tri,np.roll(tri,-1))}
    neighbors=[[] for _ in points]
    for a,b in edges:
        weight=1./np.linalg.norm(points[a]-points[b]);neighbors[a].append((b,weight));neighbors[b].append((a,weight))
    constrained_x=np.zeros(len(points),dtype=bool)
    for band in xbands:
        lo,hi=band['source']
        constrained_x|=(points[:,0]>=lo-1e-9)&(points[:,0]<=hi+1e-9)
    for dimension in range(2):
        dimension_free=free & ~constrained_x if dimension==0 else free
        ids=np.flatnonzero(dimension_free);row_for={int(v):i for i,v in enumerate(ids)}
        system=lil_matrix((len(ids),len(ids)));rhs=np.zeros(len(ids))
        for i,v in enumerate(ids):
            for n,weight in neighbors[v]:
                system[i,i]+=weight
                if dimension_free[n]:system[i,row_for[n]]-=weight
                else:rhs[i]+=weight*mapped[n,dimension]
        if len(ids):mapped[ids,dimension]=spsolve(system.tocsr(),rhs)
    family.update(sourceVerticesSvg=points.tolist(),targetVerticesSvg=mapped.tolist(),triangles=triangles.tolist(),box=initial['box'],identityOuterBoundary=True)
    family['diagonalTransitionConstruction']=dict(method='Positive inverse-source-edge-length harmonic interpolation of unconstrained neighboring mesh vertices; source strip and surrounding region targets fixed.',freeVertices=free_ids.tolist(),sourceNormalNeighborhoodMeters=None,sourceNormalNeighborhoodSvg=3.)
    for comp,ids in [(6,[182,183,184]),(4,[129,130,131])]:
        proposal=json.loads(gzip.decompress((REV/f'split-connected-contour-proposals-v2/component-{comp}.json.gz').read_bytes()))
        family['reviewedAuthoredSpans'].extend(dict(completeSpan=s['completeSpan'],legacyStraightEdgeIndex=s['legacyStraightEdgeIndex'],startSvg=s['authoredEndpoints'][0],endSvg=s['authoredEndpoints'][1]) for s in proposal['spans'] if s['completeSpan'] in ids)
    family['doorwayCornerCorrespondence']=dict(sourceJambEnd=post_end,sourceSquareCorner=outer_corner,sourceIntermediateByAuthoredArcLength=source_bevel_join,authoredIntermediate=[238.139,216.298],sourceHeaderBand=[header_low,header_high],heightPolicy='Original source profiles remain; no lower doorway fill.')
    family['diagonalSourceStrip']=dict(sourceStart=origin.tolist(),sourceEnd=end.tolist(),sourceNormalBand=[normal_min,normal_max],selectedSourceFaces=notch['sourceFaceIds'][notch['sourceObjectIds']==7797][aligned].tolist(),targetStart=target_start.tolist(),targetEnd=target_end.tolist())
    rank_one_cells=np.flatnonzero(on_strip[triangles].all(axis=1))
    parameters=np.clip(local[:,0]/length,0,1)
    parameters[abs(local[:,0])<1e-10]=0.
    parameters[abs(local[:,0]-length)<1e-10]=1.
    endpoint_ids=[int(np.flatnonzero(np.all(mapped==endpoint,axis=1))[0]) for endpoint in [target_start,target_end]]
    family['declaredRankOneMappings']=[dict(id='notch-182',targetEndpointVertexIds=endpoint_ids,
        targetEndpointsSvg=[target_start.tolist(),target_end.tolist()],sourceOriginSvg=origin.tolist(),
        sourceTangent=tangent.tolist(),sourceLengthSvg=length,sourceEndpointArithmeticSvg=1e-10,
        cells=[dict(cell=int(i),vertexParameters=parameters[triangles[i]].tolist()) for i in rank_one_cells])]
    family['status']='Connected corner prototype; requires no-fold topology and source/profile review before bake.'
    family['unresolvedFrontiers']=['Existing normalized181 supplies the upper diagonal join; exact shared source points must agree.','Finite continuation of102 belowY228 is not claimed to match the whole authored wall.','Separate7479 pipe and roof/prop silhouettes retain source roles.']
    return family


if __name__=='__main__':
    family=declaration();out=REV/'split-connected-mid-region-proposal-v1';out.mkdir(exist_ok=True);(out/'region-declaration.json').write_text(json.dumps(family,indent=2));print(out)
