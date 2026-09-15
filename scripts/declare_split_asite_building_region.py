"""Connected A-site building proposal for source-backed authored contacts17..25."""
import copy
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from declare_split_asite_return18_region import ROOT, REV, sha
from seal_split_legacy105_rank_one_declarations import seal
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology


def main():
    out=REV/'split-asite-building-connected-proposal-v4'
    out.mkdir(exist_ok=False)
    prior_path=REV/'split-asite-return18-connected-proposal-v2/region-declaration.json'
    prior=json.loads(prior_path.read_text())
    old_s=np.array(prior['sourceVerticesSvg']);old_t=np.array(prior['targetVerticesSvg']);old_c=np.array(prior['triangles'])
    old_field=explicit_warp(old_s,old_t-old_s,old_c)
    wp=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc)
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path)
    metadata=json.loads(raw_path.with_suffix('.json').read_text())
    objects=sorted(set(prior['objects']+[372,430,*range(438,446),5840,5849,5858,5872]))
    mesh={}
    for oid in objects:
        ob=metadata['objects'][oid];tri=raw['points'][raw['faces'][ob['firstFace']:ob['firstFace']+ob['faceCount']]].astype(float)
        tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin;mesh[oid]=tri
    constraints=[]
    def exact(oid,axis,near):
        values=mesh[oid][:,:,axis].ravel();v=float(values[np.argmin(abs(values-near))]);assert abs(v-near)<1e-5,(oid,axis,near,v)
        ids=np.flatnonzero(np.any(mesh[oid][:,:,axis]==v,axis=1))+metadata['objects'][oid]['firstFace']
        constraints.append(dict(object=oid,axis=axis,sourceCoordinate=v,originalFaceIds=ids.tolist()));return v
    #430 includes both doorway jambs. Only the right jamb and its upper arch
    #bevel define20's depth; the left jamb and center header remain separate.
    frame_l=exact(430,0,386.29217472);frame_r=float(mesh[430][:,:,0].max())
    frame_top=float(mesh[430][:,:,1].min())
    turn_l=float(mesh[372][:,:,0].min());turn_r=exact(5849,0,390.763770)
    turn_y0=exact(5849,1,89.245090);turn_y1=exact(5849,1,89.952879)
    long_y0=min(float(mesh[i][:,:,1].min()) for i in range(438,442));long_y1=exact(5849,1,97.210369)
    ticket_l=exact(5849,0,433.400470);ticket_r=max(float(mesh[i][:,:,0].max()) for i in range(442,446))
    ticket_end_l=float(mesh[5858][:,:,0].max());ticket_end_r=float(mesh[5849][:,:,0].max())
    bottom_y0=float(mesh[5858][:,:,1].max());bottom_y1=float(mesh[5849][:,:,1].max())
    beam_x=prior['original17AlongContract']['upperBeamNearSourceX']
    backing_r=float(mesh[5873][:,:,0].max())
    # At83 this field inherits every affine interval of the approved proposal.
    interface=shapely.LineString([[340.,83.],[416.,83.]])
    cuts=shapely.get_coordinates(shapely.intersection(shapely.polygons(old_s[old_c]),interface))
    xs=sorted(set([340.,345.75439791,349.664063,382.,384.,frame_l,frame_r,turn_l,turn_r,
        400.,403.06294296,404.398642,beam_x,408.30832232903276,backing_r,412.,416.,420.,
        ticket_l,ticket_r,442.,ticket_end_l,ticket_end_r,470.,474.]+cuts[:,0].tolist()))
    ys=[83.,84.15520414,frame_top,85.86784045,turn_y0,turn_y1,long_y0,long_y1,bottom_y0,bottom_y1,119.,122.]
    xs=np.array(xs);ys=np.array(sorted(set(ys)))
    source=[];target=[]
    def interpolate(values,anchors,destination):
        assert np.all(np.diff(anchors)>0),('Source anchors must be strictly ordered',anchors)
        return np.interp(values,anchors,destination)
    for y in ys:
        if y<=84.15520414:
            q=forward.apply(np.column_stack((xs,np.full(len(xs),y))))
            keep=xs<=416.;q[keep]=old_field.apply(np.column_stack((xs[keep],np.full(keep.sum(),y))))
        elif y<=85.86784045:
            tx=interpolate(xs,[340.,382.,384.,frame_l,frame_r,beam_x,backing_r,416.,474.],
                [340.,382.,384.,388.058,388.058,409.855,409.855,416.,474.])
            weight=interpolate(xs,[340.,384.,frame_l,backing_r,416.,474.],[0.,0.,1.,1.,0.,0.])
            q=np.column_stack((tx,y+(84.9854-y)*weight))
        elif y<=turn_y1:
            tx=interpolate(xs,[340.,384.,frame_l,frame_r,turn_l,turn_r,400.,416.,474.],
                [340.,384.,388.058,388.058,391.248,391.248,400.,416.,474.])
            weight=interpolate(xs,[340.,384.,frame_l,turn_r,400.,474.],[0.,0.,1.,1.,0.,0.])
            q=np.column_stack((tx,y+(88.1752-y)*weight))
        elif y<=long_y1:
            tx=interpolate(xs,[340.,384.,turn_l,turn_r,ticket_l,ticket_r,ticket_end_l,ticket_end_r,474.],
                [340.,384.,391.248,391.248,436.968,436.968,465.676,465.676,474.])
            weight=interpolate(xs,[340.,384.,turn_l,ticket_r,442.,474.],[0.,0.,1.,1.,0.,0.])
            q=np.column_stack((tx,y+(95.618-y)*weight))
        elif y<=bottom_y1:
            tx=interpolate(xs,[340.,420.,ticket_l,ticket_r,ticket_end_l,ticket_end_r,474.],
                [340.,420.,436.968,436.968,465.676,465.676,474.])
            weight=interpolate(xs,[340.,420.,ticket_l,ticket_end_r,474.],[0.,0.,1.,1.,0.])
            q=np.column_stack((tx,y+(113.162-y)*weight))
        else:
            q=forward.apply(np.column_stack((xs,np.full(len(xs),y))))
        p=np.column_stack((xs,np.full(len(xs),y)))
        q[[0,-1]]=forward.apply(p[[0,-1]])
        source.extend(p);target.extend(q)
    source=np.array(source);target=np.array(target)
    pieces=[]
    upper=shapely.box(340.,44.,416.,83.)
    for ids in old_c:
        part=shapely.intersection(shapely.Polygon(old_s[ids]),upper)
        for poly in shapely.get_parts(part):
            if not isinstance(poly,shapely.Polygon) or poly.area==0:continue
            for tri in shapely.get_parts(shapely.constrained_delaunay_triangles(poly)):
                p=np.array(tri.exterior.coords)[:3];q=barycentric(p,old_s[ids])@old_t[ids]
                for axis in range(2):
                    if np.all(old_t[ids,axis]==old_t[ids[0],axis]):q[:,axis]=old_t[ids[0],axis]
                pieces.append((p,q))
    right=shapely.box(416.,44.,474.,83.)
    for ids in wc:
        part=shapely.intersection(shapely.Polygon(ws[ids]),right)
        for poly in shapely.get_parts(part):
            if not isinstance(poly,shapely.Polygon) or poly.area==0:continue
            for tri in shapely.get_parts(shapely.constrained_delaunay_triangles(poly)):
                p=np.array(tri.exterior.coords)[:3];pieces.append((p,forward.apply(p)))
    nx=len(xs);wp_poly=shapely.polygons(ws[wc]);tree=shapely.STRtree(wp_poly)
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col
            for ids in [[a,a+1,a+nx+1],[a,a+nx+1,a+nx]]:
                p0=source[ids];q0=target[ids];polygon=shapely.Polygon(p0)
                for wi in tree.query(polygon,predicate='intersects'):
                    for poly in shapely.get_parts(shapely.intersection(polygon,wp_poly[wi])):
                        if not isinstance(poly,shapely.Polygon) or poly.area==0:continue
                        for tri in shapely.get_parts(shapely.constrained_delaunay_triangles(poly)):
                            p=np.array(tri.exterior.coords)[:3];q=barycentric(p,p0)@q0
                            for axis in range(2):
                                if np.all(q0[:,axis]==q0[0,axis]):q[:,axis]=q0[0,axis]
                            pieces.append((p,q))
    # The upper inherited field and the new lower grid have different boundary
    # vertices. Node their literal straight interfaces before triangulation.
    # This preserves the existing affine maps and avoids unsplit T-junctions.
    all_points=np.concatenate([p for p,_ in pieces])
    horizontal=np.unique(all_points[all_points[:,1]==83.,0])
    vertical=np.unique(all_points[(all_points[:,0]==416.)&(all_points[:,1]<=83.),1])
    noded=[]
    for p,q in pieces:
        ring=[]
        for a,b in zip(p,np.roll(p,-1,axis=0)):
            ring.append(a)
            extra=[]
            if a[1]==b[1]==83.:
                extra=[np.array([x,83.]) for x in horizontal if min(a[0],b[0])<x<max(a[0],b[0])]
            elif a[0]==b[0]==416. and max(a[1],b[1])<=83.:
                extra=[np.array([416.,y]) for y in vertical if min(a[1],b[1])<y<max(a[1],b[1])]
            ring.extend(sorted(extra,key=lambda v:float((v-a)@(b-a))))
        if len(ring)==3:
            noded.append((p,q));continue
        for poly in shapely.get_parts(shapely.constrained_delaunay_triangles(shapely.Polygon(ring))):
            pp=np.array(poly.exterior.coords)[:3];qq=barycentric(pp,p)@q
            for axis in range(2):
                if np.all(q[:,axis]==q[0,axis]):qq[:,axis]=q[0,axis]
            noded.append((pp,qq))
    pieces=noded
    outer=shapely.box(340.,44.,474.,122.).boundary
    vertices=[];mapped=[];cells=[];lookup={}
    for p,q in pieces:
        boundary=shapely.distance(shapely.points(p),outer)<1e-10;q[boundary]=forward.apply(p[boundary]);ids=[]
        for a,b in zip(p,q):
            key=tuple(a)
            if key in lookup:
                index=lookup[key];assert np.linalg.norm(mapped[index]-b)<1e-9,(a,mapped[index],b)
            else:
                index=len(vertices);lookup[key]=index;vertices.append(a);mapped.append(b)
            ids.append(index)
        if len(set(ids))==3:cells.append(ids)
    family=copy.deepcopy(prior)
    for k in ['declaredRankOneMappings','declaredConstantPointCells']:family.pop(k,None)
    family.update(sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=cells,
        box=[340.,44.,474.,122.],objects=objects,reviewedSourceFaces=sorted(i for oid in objects for i in range(metadata['objects'][oid]['firstFace'],metadata['objects'][oid]['firstFace']+metadata['objects'][oid]['faceCount'])),
        sourceConstraints=prior['sourceConstraints']+constraints,
        role='Connected A-site building walls17..25, the finite430 doorway, complete5849 exterior,5858 ticket interior and reviewed mounted details. Original source Z, UV, caps and openings remain; pitched roofs are independent.',
        priorReturn18ProposalSha256=sha(prior_path),
        connectedBuildingSources=dict(doorFrameBounds=mesh[430].min((0,1)).tolist()+mesh[430].max((0,1)).tolist(),rightJambDepthBand=[frame_l,frame_r],
            mountedWindowObjects=list(range(438,446)),mountedLightObjects=[372,5840],
            depthBands=dict(lowerReturnX=[turn_l,turn_r],longWallY=[long_y0,long_y1],ticketWallX=[ticket_l,ticket_r]),
            exteriorMaximumY=bottom_y1,upperChainEndRole='5849 stops after25 with an upward finite end cap. Separate5893/5894 start below it and are explicit adjacent-height controls.'),
        pending=['Root source review and full local inventory for the expanded building.',
                 'Continuous17..25 contact, fixed upper interface, retained first rays and exact source partition.',
                 'Separate lower5893/5894 receiver and height controls; no whole-map or live-game claim.'])
    from tactical_alignment_audit import vector_lines
    authored=vector_lines(Path('assets/maps/split_map.svg'))
    family['reviewedAuthoredSpans']=[dict(legacyStraightEdgeIndex=i,startSvg=authored[i][0].tolist(),endSvg=authored[i][1].tolist()) for i in range(17,26)]
    family,rank=seal(family)
    (out/'region-declaration.json').write_text(json.dumps(family,indent=2)+'\n')
    proof=verify_region_topology(family,forward)
    (out/'topology-review.json').write_text(json.dumps(dict(topology=proof,rank=rank,scriptSha256=sha(Path(__file__))),indent=2)+'\n')
    print(json.dumps({k:v for k,v in proof.items() if k!='declaredRankOneStoredResiduals'}))


if __name__=='__main__':main()
