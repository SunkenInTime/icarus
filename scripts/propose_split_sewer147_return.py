"""Repair the known lower sewer joint without moving the deeper interior walls."""
import argparse
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from authored_region_cells import barycentric
from declare_split_legacy105_connected_region import ROOT,REV,sha
from seal_split_legacy105_rank_one_declarations import seal
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology


def main(version):
    out=REV/f'split-sewer147-return-proposal-{version}';out.mkdir(exist_ok=False)
    gp=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(gp);meta=json.loads(gp.with_suffix('.json').read_text())
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));offset=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    wc=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(ws,wt-ws,wc)
    obj=meta['objects'][6168];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
    tri=raw['points'][raw['faces'][ids]].astype(float);tri[:,:,:2]=tri[:,:,:2]@matrix.T+offset
    p=tri.reshape(-1,3);near=float(p[p[:,0]>388.,0].min());far=float(p[:,0].max());bottom=float(p[:,1].max())
    path108=REV/'split-sewer108-connected-proposal-v6/region-declaration.json';old=json.loads(path108.read_text())
    low=next(v['coordinate'] for v in old['sourceConstraints'] if v.get('object')==6169 and v['axis']==1 and abs(v['coordinate']-311.68115512)<1e-5)
    high=next(v['coordinate'] for v in old['sourceConstraints'] if v.get('object')==6169 and v['axis']==1 and abs(v['coordinate']-312.25218304)<1e-5)
    xs=np.array([383.,385.,near,far,392.,394.]);ys=np.array([306.,308.,low,high,315.,bottom,338.,340.])
    source=[];target=[]
    for y in ys:
        s=np.column_stack((xs,np.full(len(xs),y)));base=forward.apply(s)
        xx=np.interp(xs,[383.,385.,near,far,392.,394.],[base[0,0],base[1,0],389.122,389.122,base[-2,0],base[-1,0]])
        active=float(np.interp(y,[306.,308.,low,bottom,338.,340.],[0.,0.,1.,1.,0.,0.]))
        xx=(1-active)*base[:,0]+active*xx
        yy=np.full(len(xs),float(np.interp(y,[306.,308.,low,high,315.,340.],[306.,308.,311.46,311.46,315.,340.])))
        blend=np.interp(xs,[383.,385.,near,far,392.,394.],[0.,0.,1.,1.,0.,0.])
        yy=(1-blend)*base[:,1]+blend*yy
        t=np.column_stack((xx,yy));t[[0,-1]]=base[[0,-1]]
        if y in [306.,340.]:t=base
        source.extend(s);target.extend(t)
    source=np.array(source);target=np.array(target);nx=len(xs)
    wp_poly=shapely.polygons(ws[wc]);tree=shapely.STRtree(wp_poly)
    vertices=[];mapped=[];cells=[];lookup={};outer=shapely.box(383.,306.,394.,340.).boundary
    def add(p,q):
        key=tuple(p)
        if key in lookup:
            i=lookup[key];assert np.linalg.norm(mapped[i]-q)<1e-10;return i
        i=len(vertices);vertices.append(p);mapped.append(q);lookup[key]=i;return i
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col
            for ids_cell in [[a,a+1,a+nx+1],[a,a+nx+1,a+nx]]:
                s=source[ids_cell];t=target[ids_cell];polygon=shapely.Polygon(s)
                for wi in tree.query(polygon,predicate='intersects'):
                    for part in shapely.get_parts(shapely.intersection(polygon,wp_poly[wi])):
                        if not isinstance(part,shapely.Polygon) or part.area==0:continue
                        for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                            p=np.array(piece.exterior.coords)[:3];q=barycentric(p,s)@t
                            for axis in range(2):
                                if np.all(t[:,axis]==t[0,axis]):q[:,axis]=t[0,axis]
                            boundary=shapely.distance(shapely.points(p),outer)<1e-10;q[boundary]=forward.apply(p[boundary])
                            cells.append([add(a,b) for a,b in zip(p,q)])
    f=dict(edge=200147,mappingType='piecewise-affine-region-v1',objects=[6168],
        sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=cells,
        box=[383.,306.,394.,340.],reviewedSourceFaces=ids.tolist(),identityOuterBoundary=True,
        sourcePartitionMethod='finite-convex-cells-v1',sourceCoordinateConstruction='original-native-triangle-v1',
        sourceGeometrySha256=sha(gp),displayWarpSha256=sha(wp),sourceBands=dict(right=[near,far],top=[low,high],finiteSourceBottom=bottom),
        sourceObjectInventory=[dict(object=6168,**obj)],sharedContactSvg=[389.122,311.46],
        sourceZPolicy='All original source Z, UV, materials and openings retained. The wall147 normal aligns to its SVG. Its adjoining bottom cap travels with the same source field, with no new vertical seam.',
        preservedOtherRoles='Deeper6165/1006 interior surfaces are not wall attachments. No membership or location change for them.',
        scope='The demonstrated146/147 joint and continuous wall147 normal. The farther bottom wall148 drawing is not part of this bounded repair.',
        precedence='New6168 membership only. Match the200108 lower corner band to these exact source depth bounds before staging.',
        status='Proposal only, pending source-joint overlay and actual cone contact review.')
    f,rank=seal(f);path=out/'region-declaration.json';path.write_text(json.dumps(f,indent=2)+'\n')
    topology=verify_region_topology(f,forward)
    (out/'report.json').write_text(json.dumps(dict(declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),topology=topology,rank=rank),indent=2)+'\n')
    print(json.dumps(dict(output=str(out),sourceFaces=len(ids),topology={k:v for k,v in topology.items() if k!='declaredRankOneStoredResiduals'})))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',default='v1');main(p.parse_args().version)
