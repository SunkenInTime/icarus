"""Connected reviewed barrier chain, with shared profile bands and W identity."""
import gzip,json
import numpy as np
import shapely
from build_split_connected_tower import REV
from tactical_alignment_composite import explicit_warp
from authored_region_cells import barycentric


def declaration(refine_interior=True, identity_guard=8.):
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    a=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));s=np.array(w['sourceNativeMeters']).reshape(-1,2)@a.T+w['projection']['origin'];t=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(s,t-s,wc);warp_polygons=shapely.polygons(s[wc]);warp_tree=shapely.STRtree(warp_polygons)
    center=np.array([[294.57942,224.],[294.57942,232.],[294.57318757809855,251.60627602723713],
        [306.6183448953599,263.6525668098494],[337.91717105408935,263.6525668098494],
        [337.91717105408935,247.64799131114785],[337.91717105408935,240.]])
    authored=np.array([[294.491,224.],[294.491,232.],[294.491,251.917],[306.719,264.145],
        [338.617,264.145],[338.617,248.196],[338.617,240.]])
    tangent=np.diff(center,axis=0);tangent/=np.linalg.norm(tangent,axis=1)[:,None];normals=np.column_stack((-tangent[:,1],tangent[:,0]))
    miters=[normals[0]]
    for left,right in zip(normals[:-1],normals[1:]):miters.append((left+right)/(1+left@right))
    miters=np.array([*miters,normals[-1]])
    offsets=np.array([-identity_guard,-3.,0.,3.,identity_guard]);source=(center[:,None,:]+miters[:,None,:]*offsets[None,:,None]).reshape(-1,2)
    targets=[]
    for row in range(len(center)):
        for column,offset in enumerate(offsets):
            point=source[row*len(offsets)+column]
            targets.append(forward.apply(point[None])[0] if row in [0,len(center)-1] or abs(offset)==identity_guard else authored[row])
    targets=np.array(targets);cells=[]
    for row in range(len(center)-1):
        for col in range(len(offsets)-1):
            i=row*len(offsets)+col;j=i+len(offsets);cells.extend([[i,i+1,j+1],[i,j+1,j]])
    cells=np.array(cells);corridor=shapely.union_all(shapely.polygons(source[cells]));bounds=np.array(corridor.bounds);box=[float(bounds[0]-2),float(bounds[1]-2),float(bounds[2]+2),float(bounds[3]+2)]
    outer=shapely.box(*box);remainder=shapely.difference(outer,corridor)
    initial=[(source[cell],targets[cell],False) for cell in cells]
    for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(remainder)):
        points=np.array(piece.exterior.coords)[:3];initial.append((points,forward.apply(points),True))
    # Split the declaration itself at source W cells. Outer/far pieces use
    # actual W(source), so physical identity holds continuously at boundaries.
    vertices=[];mapped=[];triangles=[];lookup={}
    def add(point,value):
        key=tuple(float(v) for v in point)
        if key in lookup:
            index=lookup[key]
            assert np.linalg.norm(mapped[index]-value)<1e-7
            return index
        index=len(vertices);lookup[key]=index;vertices.append(point);mapped.append(value);return index
    for original,target,identity in initial:
        polygon=shapely.Polygon(original)
        # Strictly interior cells already declare one affine map. Splitting
        # those again by source W adds no mapping information and can create
        # microscopic slivers where two independently measured lines meet.
        # Physical identity at the outer contour still needs every W break.
        interior=not refine_interior and not identity and polygon.distance(corridor.boundary)>0
        pieces=[polygon] if interior else [shapely.intersection(polygon,warp_polygons[warp_cell]) for warp_cell in warp_tree.query(polygon,predicate='intersects')]
        for intersection in pieces:
            for part in shapely.get_parts(intersection):
                if not isinstance(part,shapely.Polygon) or part.area==0:continue
                for tri in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                    points=np.array(tri.exterior.coords)[:3]
                    values=forward.apply(points) if identity else barycentric(points,original)@target
                    if not identity:
                        for axis in range(2):
                            if np.all(target[:,axis]==target[0,axis]):values[:,axis]=target[0,axis]
                    # Shared outer corridor edges also have physical identity.
                    on_boundary=shapely.distance(shapely.points(points),corridor.boundary)<1e-10
                    values[on_boundary]=forward.apply(points[on_boundary])
                    ids=[add(p,q) for p,q in zip(points,values)]
                    if len(set(ids))==3:triangles.append(ids)
    packet_names=['split-original-scene-connected-source-review-v1/iso-bottom-and-diagonal-full-source.npz',
        'split-barrier-connected-endpoints-review-v1/barrier-upper-angle-and-continuation-full-source.npz',
        'split-barrier-connected-endpoints-review-v1/barrier-right-shared-wall-full-source.npz']
    objects=[4579,4580,4581,4582,4583,4584,4585,4586,5898,598,597,600,6166,5917];ids=set()
    for name in packet_names:
        data=np.load(REV/name);ids.update(data['sourceFaceIds'][np.isin(data['sourceObjectIds'],objects)].tolist())
    proposal=json.loads(gzip.decompress((REV/'split-connected-contour-proposals-v2/component-4.json.gz').read_bytes()))
    return dict(edge=200123,mappingType='piecewise-affine-region-v1',sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=triangles,box=box,
        objects=objects,reviewedSourceFaces=sorted(ids),identityOuterBoundary=True,
        reviewedAuthoredSpans=[dict(completeSpan=p['completeSpan'],legacyStraightEdgeIndex=p['legacyStraightEdgeIndex'],startSvg=p['authoredEndpoints'][0],endSvg=p['authoredEndpoints'][1]) for p in proposal['spans'] if p['completeSpan'] in [122,123,124]],
        sourceSharedJoinsSvg=center.tolist(),authoredSharedJoinsSvg=authored.tolist(),sourceProfileNormalBandSvg=[-3.,3.],sourceIdentityGuardSvg=identity_guard,sourcePacketFiles=packet_names,
        role='Connected reviewed construction barriers and mounted sheets share corner/normal bands. Original Z/UV and panel gaps remain. The taller122/125 source assemblies retain their original height profiles.',
        unresolved=['Only finite125 continuation near the upper barrier is included; full125 is not certified.','Standalone4381/501 remain separate.','Requires topology, continuous join, exact source profile and renderer gates before bake.'],status='Connected source corridor prototype, no bake.')


if __name__=='__main__':
    out=REV/'split-barrier-corridor-region-proposal-v1';out.mkdir(exist_ok=True);(out/'region-declaration.json').write_text(json.dumps(declaration(),indent=2));print(out)
