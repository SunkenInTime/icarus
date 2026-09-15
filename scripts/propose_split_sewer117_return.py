"""Carry the known sewer117/118 return into the existing barrier junction."""
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
    out=REV/f'split-sewer117-return-proposal-{version}'
    out.mkdir(exist_ok=False)
    old_path=REV/'split-wall-family-normalized-candidate-v31-precise-v1/bindings.json'
    old=next(f for f in json.loads(old_path.read_text())['families'] if f['edge']==200123)
    s=np.array(old['sourceVerticesSvg']);t=np.array(old['targetVerticesSvg']);c=np.array(old['triangles'])
    inherited=explicit_warp(s,t-s,c)
    wp=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    offset=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset
    wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc)
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz'
    raw=np.load(raw_path);meta=json.loads(raw_path.with_suffix('.json').read_text())
    raw_ids=[];native=[]
    for oid in [6166,6170]:
        o=meta['objects'][oid];ids=np.arange(o['firstFace'],o['firstFace']+o['faceCount'])
        raw_ids.extend(ids);native.extend(raw['points'][raw['faces'][ids]])
    source_tri=np.array(native).astype(float);source_tri[:,:,:2]=source_tri[:,:,:2]@matrix.T+offset
    p=source_tri.reshape(-1,3)
    top=p[p[:,1]<250.,1]
    top_low,top_high=float(top.min()),float(top.max())
    right=p[p[:,0]>356.,0]
    right_low,right_high=float(right.min()),float(right.max())
    left_body=float(p[:,0].min())
    proposal108=REV/'split-sewer108-connected-proposal-v5/region-declaration.json'
    field108=json.loads(proposal108.read_text())
    ybase=next(row['coordinate'] for row in field108['sourceConstraints'] if row.get('object')==6169 and row['axis']==1 and abs(row['coordinate']-273.04475899)<1e-5)
    bottom_low,bottom_high=np.array(field108['upperContourSourceBand'])+ybase
    old_box=shapely.box(*old['box'])

    def base(points):
        values=forward.apply(points)
        keep=shapely.covers(old_box,shapely.points(points))
        values[keep]=inherited.apply(points[keep])
        return values

    def field(points,values):
        result=values.copy();x,y=points.T
        bleft=base(np.column_stack((np.full(len(x),343.),y)))[:,0]
        bright=forward.apply(np.column_stack((np.full(len(x),365.),y)))[:,0]
        desired_x=np.where(x<=343.,values[:,0],
            np.where(x<right_low,bleft+(x-343.)/(right_low-343.)*(357.755-bleft),
            np.where(x<=right_high,357.755,357.755+(x-right_high)/(365.-right_high)*(bright-357.755))))
        active_y=np.interp(y,[222.,243.,top_low,bottom_high,279.,300.],[0.,0.,1.,1.,0.,0.])
        result[:,0]=(1-active_y)*values[:,0]+active_y*desired_x
        top_x=np.interp(x,[old['box'][0],335.,left_body,right_high,365.],[0.,0.,1.,1.,0.])
        top_y=np.interp(y,[222.,243.,top_low,top_high,255.,300.],[0.,0.,1.,1.,0.,0.])
        blend=top_x*top_y
        result[:,1]=(1-blend)*values[:,1]+blend*248.196
        lower_x=np.interp(x,[old['box'][0],350.,right_low,365.],[0.,0.,1.,0.])
        lower_x[(x>=right_low)&(x<=right_high)]=1.
        after=x>right_high
        lower_x[after]=(365.-x[after])/(365.-right_high)
        lower_y=np.interp(y,[222.,270.,bottom_low,bottom_high,278.,300.],[0.,0.,1.,1.,0.,0.])
        blend=lower_x*lower_y
        result[:,1]=(1-blend)*result[:,1]+blend*273.182
        return result

    xs=sorted(set([old['box'][0],330.,335.,left_body,337.91724562417824,340.91717105408935,
                   343.,old['box'][2],350.,right_low,right_high,365.]))
    ys=sorted(set([222.,238.,243.,top_low,247.64799131114785,247.73112204623578,top_high,
                   251.,255.,263.6525668098494,270.,bottom_low,old['box'][3],bottom_high,278.,279.,300.]))
    old_polys=shapely.polygons(s[c]);old_tree=shapely.STRtree(old_polys)
    warp_polys=shapely.polygons(ws[wc]);warp_tree=shapely.STRtree(warp_polys)
    vertices=[];target=[];cells=[];lookup={}
    outer=shapely.box(xs[0],ys[0],xs[-1],ys[-1]).boundary
    def add(p,q):
        key=tuple(p)
        if key in lookup:
            i=lookup[key];assert np.linalg.norm(target[i]-q)<1e-10
            return i
        i=len(vertices);vertices.append(p);target.append(q);lookup[key]=i
        return i
    for row in range(len(ys)-1):
        for col in range(len(xs)-1):
            a,b=xs[col:col+2];d,e=ys[row:row+2]
            for grid in [[[a,d],[b,d],[b,e]],[[a,d],[b,e],[a,e]]]:
                polygon=shapely.Polygon(grid)
                pieces=[]
                for i in old_tree.query(polygon,predicate='intersects'):
                    pieces.append((shapely.intersection(polygon,old_polys[i]),s[c[i]],t[c[i]]))
                outside=shapely.difference(polygon,old_box)
                for i in warp_tree.query(outside,predicate='intersects'):
                    pieces.append((shapely.intersection(outside,warp_polys[i]),ws[wc[i]],wt[wc[i]]))
                for geometry,src,dst in pieces:
                    for part in shapely.get_parts(geometry):
                        if not isinstance(part,shapely.Polygon) or part.area==0:continue
                        for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                            p=np.array(piece.exterior.coords)[:3]
                            original=barycentric(p,src)@dst
                            for axis in range(2):
                                if np.all(dst[:,axis]==dst[0,axis]):original[:,axis]=dst[0,axis]
                            q=field(p,original)
                            boundary=shapely.distance(shapely.points(p),outer)<1e-10
                            q[boundary]=forward.apply(p[boundary])
                            cells.append([add(a,b) for a,b in zip(p,q)])
    family=dict(edge=200117,mappingType='piecewise-affine-region-v1',objects=[6166,6170],
        sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(target).tolist(),triangles=cells,
        box=[xs[0],ys[0],xs[-1],ys[-1]],reviewedSourceFaces=np.array(raw_ids).tolist(),identityOuterBoundary=True,
        sourcePartitionMethod='finite-convex-cells-v1',sourceCoordinateConstruction='original-native-triangle-v1',
        sourceGeometrySha256=sha(raw_path),displayWarpSha256=sha(wp),priorBindingsSha256=sha(old_path),
        sourceObjectInventory=[dict(object=oid,**meta['objects'][oid]) for oid in [6166,6170]],
        reviewedAuthoredSpans=[dict(legacyStraightEdgeIndex=117,startSvg=[357.755,273.182],endSvg=[357.755,248.196]),
                             dict(legacyStraightEdgeIndex=118,startSvg=[357.755,248.196],endSvg=[338.617,248.196])],
        sourceBands=dict(top=[top_low,top_high],right=[right_low,right_high],bottom=[bottom_low,bottom_high]),
        preservedBarrierInterface='The existing200123 field remains literal for x<=343 and y>=255. All other objects stay in200123 unchanged. The upper corner of6166 and its actual117/118 return are the bounded changes.',
        precedence='Remove only6166 from200123. Apply this declaration to6166 and6170. Update200108 left corner band to the same right-band far bound before staging.',
        status='Proposal only; both terminal seams remain held until source/contact and rendered-cone review.',
        sourceZPolicy='Every finite original Z, UV/material and cap remains source-derived. No extruded replacement wall.')
    (out/'unsealed-declaration.json').write_text(json.dumps(family,indent=2)+'\n')
    family,rank=seal(family)
    path=out/'region-declaration.json';path.write_text(json.dumps(family,indent=2)+'\n')
    try:topology=verify_region_topology(family,forward)
    except (AssertionError,ValueError) as error:topology=dict(passed=False,error=str(error))
    (out/'report.json').write_text(json.dumps(dict(declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),
        topology=topology,rank=rank,sourceFaces=len(raw_ids),productionMutation=False),indent=2)+'\n')
    print(json.dumps(dict(output=str(out),sourceFaces=len(raw_ids),topology={k:v for k,v in topology.items() if k!='declaredRankOneStoredResiduals'})))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',default='v1')
    main(p.parse_args().version)
