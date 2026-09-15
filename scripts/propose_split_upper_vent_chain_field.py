"""Held finite 169–172 wall chain. Existing distant tower fields stay separate."""
import gzip,json
from pathlib import Path
import numpy as np
import shapely
from authored_region_cells import barycentric
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology
from seal_split_legacy105_rank_one_declarations import seal
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def declaration():
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc)
    roomp=REV/'split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json';room=json.loads(roomp.read_text())
    rs=np.array(room['sourceVerticesSvg']);rt=np.array(room['targetVerticesSvg']);rc=np.array(room['triangles'])
    rshapes=shapely.polygons(rs[rc]);rtree=shapely.STRtree(rshapes)
    def room_x(x):
        p=np.array([x,169.45555596144112]);cell=int(rtree.query(shapely.Point(p),predicate='intersects')[0])
        return float((barycentric(p[None],rs[rc[cell]])@rt[rc[cell]])[0,0])
    xs=np.array([270.,273.,275.38123294219076,279.399263213494,281.2456633563162,282.9094711794969,
        283.6277601036635,286.,297.4689827537503,298.31642707186404,298.82220615672895,
        299.13914394850394,303.7826084692953,307.,309.])
    upper=np.array([270.,273.,275.38123294219076,281.201,281.201,281.201,283.6277601036635,
        286.,298.744,298.744,298.744,298.744,303.7826084692953,307.,309.])
    # Keep the literal room band's breakpoint. Sampling its rounded neighbor
    # changes the slope and leaves a measurable tangent mismatch at 172.
    refined=np.unique(np.r_[xs,281.2456484422984]);upper=np.interp(refined,xs,upper);xs=refined
    lower=upper.copy()
    for i,x in enumerate(xs):
        if 273<=x<=283.6277601036635:lower[i]=room_x(x)
    ys=np.array([96.,98.,100.9786039541338,101.03733535613882,110.81157589976911,
        140.4244211196933,142.08822894287403,142.5031369174248,146.4781402474419,
        165.074548325486,166.0351453,169.039082,169.45555596144112,169.4555708754589,
        171.11940852667513,175.,177.])
    ty=ys.copy();ty[2:4]=100.934;ty[5:8]=141.87;ty[11:15]=168.451
    source=[];target=[]
    for j,y in enumerate(ys):
        t=float(np.clip((y-142.5031369174248)/(166.0351453-142.5031369174248),0,1))
        for i,x in enumerate(xs):
            p=np.array([x,y]);q=np.array([(1-t)*upper[i]+t*lower[i],ty[j]])
            if i in [0,len(xs)-1] or j in [0,len(ys)-1]:q=forward.apply(p[None])[0]
            source.append(p);target.append(q)
    source=np.array(source);target=np.array(target);initial=[];nx=len(xs)
    for j in range(len(ys)-1):
        for i in range(nx-1):
            a=j*nx+i;b=a+1;c=a+nx;d=c+1;initial.extend([[a,b,d],[a,d,c]])
    wshapes=shapely.polygons(ws[wc]);tree=shapely.STRtree(wshapes);outer=shapely.box(xs[0],ys[0],xs[-1],ys[-1]).boundary
    vertices=[];mapped=[];cells=[];lookup={}
    def add(p,q):
        # Store exact wall normals throughout the measured solid-depth bands.
        if 273<=p[0]<=307:
            if ys[2]<=p[1]<=ys[3]:q[1]=100.934
            if ys[5]<=p[1]<=ys[7]:q[1]=141.87
            if ys[11]<=p[1]<=ys[14]:q[1]=168.451
        if 98<=p[1]<=175:
            if 297.4689827537503<=p[0]<=299.13914394850394:q[0]=298.744
            if p[1]<=ys[7] and 279.399263213494<=p[0]<=282.9094711794969:q[0]=281.201
        key=tuple(float(v) for v in p)
        if key in lookup:
            k=lookup[key];assert np.linalg.norm(mapped[k]-q)<1e-9;return k
        k=len(vertices);lookup[key]=k;vertices.append(p);mapped.append(q);return k
    for ids in initial:
        tri=source[ids];values=target[ids];poly=shapely.Polygon(tri)
        for index in tree.query(poly,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(poly,wshapes[index])):
                if not isinstance(part,shapely.Polygon) or part.area==0:continue
                for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                    p=np.array(piece.exterior.coords)[:3];q=barycentric(p,tri)@values
                    for axis in range(2):
                        if np.all(values[:,axis]==values[0,axis]):q[:,axis]=values[0,axis]
                    boundary=shapely.distance(shapely.points(p),outer)<1e-10;q[boundary]=forward.apply(p[boundary])
                    cell=[add(a,b) for a,b in zip(p,q)]
                    if len(set(cell))==3:cells.append(cell)
    raw=ROOT/'supplemented-v2/world/split/geometry.npz';meta=json.loads(raw.with_suffix('.json').read_text())
    objects=[5927,563,5902,5903,5926,5934,612];face_ids=[]
    for i in objects:
        obj=meta['objects'][i];face_ids.extend(range(obj['firstFace'],obj['firstFace']+obj['faceCount']))
    family=dict(edge=200172,mappingType='piecewise-affine-region-v1',objects=objects,
        sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=cells,
        box=[float(xs[0]),float(ys[0]),float(xs[-1]),float(ys[-1])],identityOuterBoundary=True,
        reviewedSourceFaces=face_ids,depthSourceFaces=face_ids,sourcePartitionMethod='finite-convex-cells-v1',sourceCoordinateConstruction='original-native-triangle-v1',
        sourceGeometrySha256=sha(raw),sourceMetadataSha256=sha(raw.with_suffix('.json')),displayWarpSha256=sha(wp),
        inheritedRoomDeclarationSha256=sha(roomp),inheritedCandidateBindingSha256=sha(REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json'),
        role='Finite continuous 169–172 source wall chain with room172 tangent inheritance. Source Z and alpha retained; no source extrusion.',
        status='Held proposal. Mounted source roles, full parent partition, unaffected distant fields and actual standing first hits require review.',
        sourceParameters=dict(xs=xs.tolist(),upperX=upper.tolist(),lowerX=lower.tolist(),ys=ys.tolist(),targetY=ty.tolist()),
        preservedDistantFamilies=[97,10099],
        pending=['Review measured depth bands and all mounted members against source sections.',
            'Clip whole raw parents with outside fragments retained under their existing baseline mappings.',
            'Verify complete source partition, alpha, original Z and existing distant 97/10099 rows.',
            'Compare source172 tangent inheritance and original source caps with V6 room.',
            'Replay identical416 standing section queries and new complete-chain observer controls.'])
    return family,forward

if __name__=='__main__':
    out=REV/'split-upper-vent-chain-field-proposal-v2';out.mkdir(exist_ok=False)
    f,w=declaration();sealed,rank=seal(f)
    for d in sealed['declaredRankOneMappings']:d['id']=d['id'].replace('legacy105','upper-vent-chain')
    (out/'held-region-declaration.json').write_text(json.dumps(sealed,indent=2)+'\n')
    try:rank['topology']=verify_region_topology(sealed,w);rank['passed']=True
    except AssertionError as e:rank['passed']=False;rank['failure']=str(e)
    rank.update(declarationSha256=sha(out/'held-region-declaration.json'),scriptSha256=sha(Path(__file__)))
    (out/'rank-and-topology-review.json').write_text(json.dumps(rank,indent=2)+'\n')
    print(json.dumps({k:v for k,v in rank.items() if k not in ['cells','topology']}))
