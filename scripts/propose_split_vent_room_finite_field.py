"""Unbaked full-room field experiment. Acceptance requires the listed interfaces."""
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06'); REV=ROOT/'tactical-visibility-revision'


def declaration():
    wp=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc)
    # Full source room, not a small 174-only blend across its adjoining wall.
    xb=[(205.,205.),(208.,208.),(209.42852318566105,212.62),
        (213.45656076289248,212.62),(219.8870750927633,222.445),
        (220.8797744870143,222.445),(224.63315766092913,224.63315766092913),
        (234.127158234273,236.012),(235.65405673577322,236.012),
        (240.2312494570628,240.797),(248.,248.),
        (255.80903050904556,256.214),(256.2341993278268,256.214),
        (261.1306,263.657),(263.7171436931447,263.657),
        (264.11541509877037,263.657),
        (281.2456484422984,282.796),(283.6278,282.796),(286.,286.),(288.,288.)]
    # Band starts from a source bound must be literal, not the printed 4-digit inventory.
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz'
    d=np.load(raw_path);points,faces=d['points'],d['faces']
    meta=json.loads(raw_path.with_suffix('.json').read_text())
    obj=meta['objects'][7796]
    xy=points[faces[obj['firstFace']:obj['firstFace']+obj['faceCount']]][:,:,:2]@matrix.T+origin
    xb=[(float(xy[:,:,0].min()) if x==261.1306 else
         float(xy[:,:,0].max()) if x==283.6278 else x,y) for x,y in xb]
    bottom_front=float((points[faces[2824572]][:,:2]@matrix.T+origin)[:,1].min())
    bottom_back=float(xy[:,:,1].max())
    xs=np.array([a for a,b in xb]);tx=np.array([b for a,b in xb])
    assert (np.diff(xs)>0).all() and (np.diff(tx)>=0).all()
    base={164.:164.,165.:165.,169.45555596144112:168.451,
          183.13922692773357:182.274,183.1956019149299:182.274,
          195.86419500329725:195.86419500329725,
          195.99:196.096,196.87543997865373:196.096,
          210.48249763562671:210.45,210.50658377433626:210.45,
          212.461:212.461,218.:218.,220.:220.}
    base.update({bottom_front:bottom_front,bottom_back:bottom_back})
    ys=np.array(sorted(base))
    source=[];target=[]
    for y in ys:
        for x,xx in xb:
            values=np.array([base[z] for z in ys])
            # 177's endpoint and the bottom tube lie on another contour.
            west=np.clip((235.65405673577322-x)/(235.65405673577322-213.45656076289248),0,1)
            values[list(ys).index(195.86419500329725)]=(1-west)*195.86419500329725+west*194.501
            for z in [195.99,196.87543997865373]:
                values[list(ys).index(z)]=(1-west)*196.096+west*(194.501+(z-195.86419500329725))
            east=np.clip((x-234.127158234273)/(235.65405673577322-234.127158234273),0,1)
            for i,z in enumerate(ys):
                if bottom_front<=z<=bottom_back:values[i]=(1-east)*values[i]+east*210.45
            # Keep finite wall heights. No triangle, cap, or door span is added.
            yy=float(np.interp(y,ys,values))
            q=np.array([xx,yy]);p=np.array([x,y])
            if x in [xs[0],xs[-1]] or y in [ys[0],ys[-1]]:q=forward.apply(p[None])[0]
            source.append(p);target.append(q)
    source=np.array(source);target=np.array(target);initial=[];nx=len(xs)
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col;b=a+1;c=a+nx;d=c+1
            initial.extend([[a,b,d],[a,d,c]])
    polygons=shapely.polygons(ws[wc]);tree=shapely.STRtree(polygons)
    outer=shapely.box(xs[0],ys[0],xs[-1],ys[-1]).boundary
    vertices=[];mapped=[];cells=[];lookup={}
    def add(p,q):
        if 165. <= p[1] <= 218.:
            # X is a separable scalar function throughout this interior. Store
            # its literal band values so shared cells cannot invent thin folds.
            q[0]=np.interp(p[0],xs,tx)
        if 208. <= p[0] <= 286.:
            if 183.13922692773357 <= p[1] <= 183.1956019149299:q[1]=182.274
            if 210.48249763562671 <= p[1] <= 210.50658377433626:q[1]=210.45
            if p[0]>=235.65405673577322 and 195.99<=p[1]<=196.87543997865373:q[1]=196.096
            if p[0]>=235.65405673577322 and bottom_front<=p[1]<=bottom_back:q[1]=210.45
        key=tuple(float(v) for v in p)
        if key in lookup:
            i=lookup[key];assert np.linalg.norm(mapped[i]-q)<1e-9;return i
        i=len(vertices);lookup[key]=i;vertices.append(p);mapped.append(q);return i
    for ids in initial:
        tri=source[ids];values=target[ids];polygon=shapely.Polygon(tri)
        for index in tree.query(polygon,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(polygon,polygons[index])):
                if not isinstance(part,shapely.Polygon) or part.area==0:continue
                for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                    p=np.array(piece.exterior.coords)[:3];q=barycentric(p,tri)@values
                    for axis in range(2):
                        if np.all(values[:,axis]==values[0,axis]):q[:,axis]=values[0,axis]
                    boundary=shapely.distance(shapely.points(p),outer)<1e-10
                    q[boundary]=forward.apply(p[boundary])
                    cell=[add(a,b) for a,b in zip(p,q)]
                    if len(set(cell))==3:cells.append(cell)
    ids=[]
    for o in [7795,7796,4773]:
        obj=meta['objects'][o];ids.extend(range(obj['firstFace'],obj['firstFace']+obj['faceCount']))
    family=dict(edge=200174,mappingType='piecewise-affine-region-v1',objects=[7795,7796,4773],
        sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=cells,
        reviewedSourceFaces=ids,box=[float(xs[0]),float(ys[0]),float(xs[-1]),float(ys[-1])],identityOuterBoundary=True,
        sourceGeometrySha256=sha(raw_path),sourceMetadataSha256=sha(raw_path.with_suffix('.json')),
        displayWarpSha256=sha(wp),inheritedCandidateBindingSha256=sha(REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json'),
        sourcePartitionMethod='finite-convex-cells-v1',sourceCoordinateConstruction='original-native-triangle-v1',
        depthSourceFaces=ids,
        lower125ProfileBand=dict(sourceNormalSvg=[bottom_front,bottom_back],targetNormalSvg=210.45,
            fullWeightFromSourceX=235.65405673577322,transitionStartsSourceX=234.127158234273,
            sourceFrontWitnessFace=2824572,sourceBackBoundObject=7796,
            role='Original bottom wall panels, inset faces and backing retain source Z and alpha. No whole-height extrusion.'),
        role='Whole lower vent room XY field experiment. Original source heights and UVs remain the source of profiles. The accepted V30 200190 field is not edited.',
        status='Held experiment, not approved for a bake. Numeric topology is not source-role or gameplay acceptance.',
        unresolved=['Prove continuous contact with existing 175/176 geometry and all mounted wall details.',
            'Review source176/177 and125 contacts introduced by full 7795 ownership.',
            'Do not assume the recessed173 structure and281 right-room return have the same blocker role at every height.',
            'Replay actual standing and upper/lower doorway controls, then inspect actual attack and defense renders.',
            'Seal explicit rank-one mappings before any compiler uses this declaration.'])
    return family,forward


if __name__=='__main__':
    out=REV/'split-vent-room-finite-field-experiment-v5';out.mkdir(exist_ok=False)
    family,forward=declaration()
    (out/'held-region-declaration.json').write_text(json.dumps(family,indent=2)+'\n')
    try:
        proof=verify_region_topology(family,forward)
        report=dict(topologyPassed=True,proof=proof,scope='Held declaration only. No pack changed.')
    except AssertionError as error:
        report=dict(topologyPassed=False,error=str(error),scope='Rejected declaration experiment. No pack changed.')
    report['scriptSha256']=sha(Path(__file__))
    (out/'topology-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
