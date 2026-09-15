"""One finite U-shaped field for the sewer117/118 return and its barrier joint."""
import argparse
import gzip
import json
import numpy as np
import shapely
from authored_region_cells import barycentric
from declare_split_legacy105_connected_region import ROOT,REV,sha
from seal_split_legacy105_rank_one_declarations import seal
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology
from pathlib import Path


def main(version):
    out=REV/f'split-sewer117-simple-proposal-{version}';out.mkdir(exist_ok=False)
    old_path=REV/'split-wall-family-normalized-candidate-v31-precise-v1/bindings.json'
    old=next(f for f in json.loads(old_path.read_text())['families'] if f['edge']==200123)
    os=np.array(old['sourceVerticesSvg']);ot=np.array(old['targetVerticesSvg'])
    oldmap=explicit_warp(os,ot-os,np.array(old['triangles']))
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));offset=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    wc=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(ws,wt-ws,wc)
    gp=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(gp);meta=json.loads(gp.with_suffix('.json').read_text())
    ids=[];tri=[]
    for oid in [6166,6170]:
        o=meta['objects'][oid];fi=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);ids.extend(fi)
        tri.extend(raw['points'][raw['faces'][fi]])
    tri=np.array(tri).astype(float);tri[:,:,:2]=tri[:,:,:2]@matrix.T+offset;p=tri.reshape(-1,3)
    top=p[p[:,1]<250.,1];right=p[p[:,0]>356.,0]
    tl,th=float(top.min()),float(top.max());rl,rh=float(right.min()),float(right.max());left=float(p[:,0].min())
    field108=json.loads((REV/'split-sewer108-connected-proposal-v5/region-declaration.json').read_text())
    by=273.04475898890087;bl,bh=np.array(field108['upperContourSourceBand'])+by
    leftplane=337.91724562417824
    xs=np.array([330.,left,leftplane,343.,350.,rl,rh,365.])
    ys=np.array(sorted(set([240.,243.,tl,247.64799131114785,247.73112204623578,th,255.,263.6525668098494,270.,bl,273.25677276271335,bh,279.,291.3531326416215,298.])))
    old_y=oldmap.apply(np.column_stack((np.full(len(ys),leftplane),ys)))[:,1]
    left_targets=[];right_targets=[]
    for y,legacy_y in zip(ys,old_y):
        if y<=243. or y>=279.:
            ly=ry=y
        elif y<=th:
            ly=ry=248.196
        else:
            ly=float(legacy_y) if y<=old['box'][3] else float(forward.apply(np.array([[leftplane,y]]))[0,1])
            ry=float(np.interp(y,[th,bl,bh,279.],[248.196,273.182,273.182,279.]))
        left_targets.append(ly);right_targets.append(ry)
    assert (np.diff(left_targets)>=0).all() and (np.diff(right_targets)>=0).all()
    source=[];target=[]
    for y,ly,ry in zip(ys,left_targets,right_targets):
        s=np.column_stack((xs,np.full(len(xs),y)));base=forward.apply(s)
        xx=np.interp(xs,[330.,left,leftplane,rl,rh,365.],[base[0,0],338.617,338.617,357.755,357.755,base[-1,0]])
        active=float(np.interp(y,[240.,243.,tl,bh,279.,298.],[0.,0.,1.,1.,0.,0.]))
        xx=(1-active)*base[:,0]+active*xx
        yy=np.interp(xs,[330.,left,leftplane,rl,rh,365.],[base[0,1],ly,ly,ry,ry,base[-1,1]])
        t=np.column_stack((xx,yy))
        if y in [240.,298.]:t=base
        source.extend(s);target.extend(t)
    source=np.array(source);target=np.array(target);nx=len(xs)
    polygons=shapely.polygons(ws[wc]);tree=shapely.STRtree(polygons)
    vertices=[];mapped=[];cells=[];lookup={};outer=shapely.box(330.,240.,365.,298.).boundary
    def add(p,q):
        key=tuple(p)
        if key in lookup:
            i=lookup[key];assert np.linalg.norm(mapped[i]-q)<1e-10;return i
        i=len(vertices);vertices.append(p);mapped.append(q);lookup[key]=i;return i
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col
            for indices in [[a,a+1,a+nx+1],[a,a+nx+1,a+nx]]:
                src=source[indices];dst=target[indices];polygon=shapely.Polygon(src)
                for wi in tree.query(polygon,predicate='intersects'):
                    for part in shapely.get_parts(shapely.intersection(polygon,polygons[wi])):
                        if not isinstance(part,shapely.Polygon) or part.area==0:continue
                        for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                            p=np.array(piece.exterior.coords)[:3];q=barycentric(p,src)@dst
                            for axis in range(2):
                                if np.all(dst[:,axis]==dst[0,axis]):q[:,axis]=dst[0,axis]
                            boundary=shapely.distance(shapely.points(p),outer)<1e-10;q[boundary]=forward.apply(p[boundary])
                            cells.append([add(a,b) for a,b in zip(p,q)])
    f=dict(edge=200117,mappingType='piecewise-affine-region-v1',objects=[6166,6170],
        sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=cells,
        box=[330.,240.,365.,298.],reviewedSourceFaces=np.array(ids).tolist(),identityOuterBoundary=True,
        sourcePartitionMethod='finite-convex-cells-v1',sourceCoordinateConstruction='original-native-triangle-v1',
        sourceGeometrySha256=sha(gp),displayWarpSha256=sha(wp),priorBindingsSha256=sha(old_path),
        sourceBands=dict(top=[tl,th],right=[rl,rh],bottom=[bl,bh]),
        sharedContacts=dict(barrier=[338.617,264.145],upperLeft=[338.617,248.196],upperRight=[357.755,248.196],sewer116=[357.755,273.182]),
        precedence='Remove only6166 from200123; all other objects and their old field remain unchanged. Apply this field to6166 and6170. Match200108 left corner band before staging.',
        sourceZPolicy='Retain original finite source Z, UV, material, caps and openings. Existing lower continuation remains a finite source profile.',
        status='Proposal only; verify the actual shared barrier and sewer contact, then render cones. No unrelated geometry expansion.')
    (out/'unsealed-declaration.json').write_text(json.dumps(f,indent=2)+'\n');f,rank=seal(f)
    path=out/'region-declaration.json';path.write_text(json.dumps(f,indent=2)+'\n')
    topology=verify_region_topology(f,forward)
    (out/'report.json').write_text(json.dumps(dict(declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),topology=topology,rank=rank,sourceFaces=len(ids)),indent=2)+'\n')
    print(json.dumps(dict(output=str(out),sourceFaces=len(ids),topology={k:v for k,v in topology.items() if k!='declaredRankOneStoredResiduals'})))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',default='v1');main(p.parse_args().version)
