"""Extend the connected building to both doorways and the finite left shell."""
import copy
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from declare_split_asite_return18_region import ROOT, REV, sha
from seal_split_legacy105_rank_one_declarations import seal
from tactical_alignment_audit import vector_lines
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology


def main():
    out=REV/'split-asite-building-connected-proposal-v6';out.mkdir(exist_ok=False)
    prior_path=REV/'split-asite-building-connected-proposal-v4/region-declaration.json';prior=json.loads(prior_path.read_text())
    os=np.array(prior['sourceVerticesSvg']);ot=np.array(prior['targetVerticesSvg']);oc=np.array(prior['triangles']);op=shapely.polygons(os[oc]);old=explicit_warp(os,ot-os,oc)
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(ws,wt-ws,wc)
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path);meta=json.loads(raw_path.with_suffix('.json').read_text())
    objects=sorted(set(prior['objects']+[429,447,5853]));mesh={}
    for oid in objects:
        ob=meta['objects'][oid];tri=raw['points'][raw['faces'][ob['firstFace']:ob['firstFace']+ob['faceCount']]].astype(float);tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin;mesh[oid]=tri
    constraints=[]
    def coordinate(oid,axis,near):
        v=mesh[oid][:,:,axis].ravel();value=float(v[np.argmin(abs(v-near))]);assert abs(value-near)<1e-5,(oid,axis,near,value)
        ids=np.flatnonzero(np.any(mesh[oid][:,:,axis]==value,axis=1))+meta['objects'][oid]['firstFace']
        constraints.append(dict(object=oid,axis=axis,sourceCoordinate=value,originalFaceIds=ids.tolist()));return value
    outer_l=float(mesh[5853][:,:,0].min());outer_r=coordinate(5857,0,345.754398)
    frame_x=float(mesh[429][:,:,0].min());inner_l=coordinate(5857,0,349.527465);inner_r=float(mesh[429][:,:,0].max())
    north_y=coordinate(429,1,60.15828108)
    south_y0=coordinate(429,1,73.43736457);south_y1=float(mesh[429][:,:,1].max())
    jamb_l=float(mesh[430][:,:,0].min());jamb_r=coordinate(430,0,375.76411603)
    step_x=float(mesh[5849][:,:,0].min())
    bottom_y0=float(mesh[430][:,:,1].min());bottom_y1=coordinate(5857,1,85.867751)
    step_y0=coordinate(5849,1,89.245090);step_y1=coordinate(5849,1,89.952879)
    outer_bottom=float(mesh[5853][:,:,1].max())
    domain=shapely.box(340,44,384,106)
    boundary=domain.boundary;points=shapely.get_coordinates(shapely.intersection(op,boundary))
    xs=sorted(set([340.,outer_l,frame_x,outer_r,inner_l,inner_r,360.,step_x,jamb_l,jamb_r,381.,384.]+points[(points[:,1]==44)|(points[:,1]==106),0].tolist()))
    ys=sorted(set([44.,54.,56.42,58.98,north_y,62.,south_y0,south_y1,bottom_y0,bottom_y1,step_y0,step_y1,94.,outer_bottom,106.]+points[(points[:,0]==340)|(points[:,0]==384),1].tolist()))
    xs=np.array(xs);ys=np.array(ys)
    old17=json.loads((REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json').read_text())
    f17=next(f for f in old17['families'] if f['edge']==17)
    along=lambda x:f17['targetAlong'][0]+(x-f17['sourceAlong'][0])/np.diff(f17['sourceAlong'])[0]*np.diff(f17['targetAlong'])[0]
    def interp(v,a,b):
        assert np.all(np.diff(a)>0),(a,b)
        return np.interp(v,a,b)
    # The right/bottom interfaces retain the previous affine field. No wall
    #inside either doorway serves as a fade boundary.
    base_ys=np.array([44.,54.,56.42,58.98,north_y,62.,south_y0,south_y1,bottom_y0,bottom_y1,step_y0,step_y1,94.,outer_bottom,106.])
    base_q=[]
    for y in base_ys:
        p=np.column_stack((xs,np.full(len(xs),y)));q=old.apply(p)
        if 56.42<=y<=north_y:
            active=interp(xs,[340.,frame_x,inner_r,360.,384.],[0.,1.,1.,0.,0.])
            if y<=58.98:active=interp(xs,[340.,frame_x,384.],[0.,1.,1.])
            q[:,0]=(1-active)*q[:,0]+active*along(xs)
            q[:,1]=(1-active)*q[:,1]+active*56.809
        elif 62.<=y<=outer_bottom:
            lower_weight=float(np.clip((y-south_y1)/(bottom_y0-south_y1),0,1))
            plain=interp(xs,[340.,outer_l,outer_r,inner_l,inner_r,step_x,jamb_l,jamb_r,384.],
                [340.,346.855,346.855,349.781,349.781,step_x,jamb_l,jamb_r,384.])
            doorway=interp(xs,[340.,outer_l,outer_r,inner_l,inner_r,step_x,jamb_l,jamb_r,384.],
                [340.,346.855,346.855,349.781,349.781,372.109,375.299,375.299,384.])
            tx=(1-lower_weight)*plain+lower_weight*doorway
            if y>=94.:
                tx=interp(xs,[340.,outer_l,outer_r,inner_l,384.],[340.,346.855,346.855,inner_l,384.])
            q[:,0]=tx
            outer_y=interp(y,[62.,south_y0,south_y1,outer_bottom],[62.,74.8844,74.8844,100.934])
            outer_weight=interp(xs,[340.,outer_l,outer_r,inner_l,384.],[0.,1.,1.,0.,0.])
            q[:,1]=(1-outer_weight)*q[:,1]+outer_weight*outer_y
            if y<=south_y1:
                inner_y=interp(y,[62.,south_y0,south_y1],[62.,74.8844,74.8844])
                weight=interp(xs,[340.,outer_l,inner_r,360.,384.],[0.,1.,1.,0.,0.])
                q[:,1]=(1-weight)*q[:,1]+weight*inner_y
            elif y<=bottom_y1:
                inner_y=interp(y,[south_y1,bottom_y0,bottom_y1],[74.8844,84.9854,84.9854])
                weight=interp(xs,[340.,outer_r,inner_l,jamb_r,384.],[0.,0.,1.,1.,0.])
                q[:,1]=(1-weight)*q[:,1]+weight*inner_y
            elif y<=step_y1:
                weight=interp(xs,[340.,360.,step_x,jamb_r,384.],[0.,0.,1.,1.,0.])
                q[:,1]=(1-weight)*q[:,1]+weight*88.1752
        for index in [0,len(xs)-1]:q[index]=old.apply(p[index:index+1])[0]
        if y in [44.,106.]:q=old.apply(p)
        base_q.append(q)
    base_q=np.array(base_q)
    source=[];target=[]
    for y in ys:
        p=np.column_stack((xs,np.full(len(xs),y)));j=np.searchsorted(base_ys,y)
        if j<len(base_ys) and base_ys[j]==y:q=base_q[j].copy()
        else:
            a,b=base_ys[j-1:j+1];weight=(y-a)/(b-a);q=(1-weight)*base_q[j-1]+weight*base_q[j]
        q[[0,-1]]=old.apply(p[[0,-1]])
        if y in [44.,106.]:q=old.apply(p)
        source.extend(p);target.extend(q)
    source=np.array(source);target=np.array(target);pieces=[]
    for ids,poly in zip(oc,op):
        for part in shapely.get_parts(shapely.difference(poly,domain)):
            if not isinstance(part,shapely.Polygon) or part.area==0:continue
            for triangle in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                p=np.array(triangle.exterior.coords)[:3];q=barycentric(p,os[ids])@ot[ids]
                for axis in range(2):
                    if np.all(ot[ids,axis]==ot[ids[0],axis]):q[:,axis]=ot[ids[0],axis]
                pieces.append((p,q))
    #The original field supplies every boundary kink. Interior grid cells do
    #not need source-W cuts; compilation separately splits their mapped output
    #against W. Keeping the declared cells avoids roundoff from redundant
    #polygon intersections at the literal outer plane y44.
    nx=len(xs)
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col
            for ids in [[a,a+1,a+nx+1],[a,a+nx+1,a+nx]]:
                pieces.append((source[ids].copy(),target[ids].copy()))
    #Explicitly node both interfaces without snapping any source coordinate.
    all_points=np.concatenate([p for p,_ in pieces]);horizontal=np.unique(all_points[(all_points[:,1]==106)&(all_points[:,0]<=384),0]);vertical=np.unique(all_points[(all_points[:,0]==384)&(all_points[:,1]<=106),1]);noded=[]
    for p,q in pieces:
        ring=[]
        for a,b in zip(p,np.roll(p,-1,axis=0)):
            ring.append(a);extra=[]
            if a[1]==b[1]==106 and max(a[0],b[0])<=384:extra=[np.array([x,106.]) for x in horizontal if min(a[0],b[0])<x<max(a[0],b[0])]
            elif a[0]==b[0]==384 and max(a[1],b[1])<=106:extra=[np.array([384.,y]) for y in vertical if min(a[1],b[1])<y<max(a[1],b[1])]
            ring.extend(sorted(extra,key=lambda point:float((point-a)@(b-a))))
        if len(ring)==3:noded.append((p,q));continue
        for triangle in shapely.get_parts(shapely.constrained_delaunay_triangles(shapely.Polygon(ring))):
            pp=np.array(triangle.exterior.coords)[:3];qq=barycentric(pp,p)@q
            for axis in range(2):
                if np.all(q[:,axis]==q[0,axis]):qq[:,axis]=q[0,axis]
            noded.append((pp,qq))
    vertices=[];mapped=[];cells=[];lookup={};outer=shapely.box(*prior['box']).boundary
    for p,q in noded:
        mask=shapely.distance(shapely.points(p),outer)<1e-10;q[mask]=forward.apply(p[mask]);ids=[]
        for a,b in zip(p,q):
            key=tuple(a)
            if key in lookup:index=lookup[key];assert np.linalg.norm(mapped[index]-b)<1e-9
            else:index=len(vertices);lookup[key]=index;vertices.append(a);mapped.append(b)
            ids.append(index)
        if len(set(ids))==3:cells.append(ids)
    family=copy.deepcopy(prior)
    for key in ['declaredRankOneMappings','declaredConstantPointCells']:family.pop(key,None)
    family.update(sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),triangles=cells,objects=objects,
        reviewedSourceFaces=sorted(i for oid in objects for i in range(meta['objects'][oid]['firstFace'],meta['objects'][oid]['firstFace']+meta['objects'][oid]['faceCount'])),
        sourceConstraints=prior['sourceConstraints']+constraints,priorBuildingDeclarationSha256=sha(prior_path),
        role='Connected finite A-site building, both original doorways, outer and inner shells and reviewed attached details. Original source Z, UV, finite caps and openings remain; pitched roofs stay separate.',
        precedence='Replace old17 membership for429 and5857 with this region. Keep old17 for7107. All other prior families stay unchanged.',
        leftShellContract=dict(outerDepthBand=[outer_l,outer_r],innerDepthBand=[inner_l,inner_r],northJambDepthBand=[56.42,north_y],southJambDepthBand=[south_y0,south_y1],
            oppositeJambDepthBand=[jamb_l,jamb_r],leftShortTurnSourceX=step_x,outerSourceEndY=outer_bottom,priorFieldBoundary=[340.,44.,384.,106.]),
        pending=['Independent exact contacts for both doorways and left shell, expanded original-height source profiles.','Root attachment/source-role review, frozen standing first hits and full source partition.'])
    authored=vector_lines(Path('assets/maps/split_map.svg'));family['reviewedAuthoredSpans']=[dict(legacyStraightEdgeIndex=i,startSvg=authored[i][0].tolist(),endSvg=authored[i][1].tolist()) for i in [*range(17,26),*range(73,80)]]
    family,rank=seal(family);(out/'region-declaration.json').write_text(json.dumps(family,indent=2)+'\n');proof=verify_region_topology(family,forward)
    (out/'topology-review.json').write_text(json.dumps(dict(topology=proof,rank=rank,scriptSha256=sha(Path(__file__))),indent=2)+'\n')
    print(json.dumps({k:v for k,v in proof.items() if k!='declaredRankOneStoredResiduals'}))


if __name__=='__main__':main()
