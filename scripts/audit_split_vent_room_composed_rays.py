"""Frozen standing rays against unchanged original-height scene plus vent fragments."""
import ctypes,gzip,json
from pathlib import Path
import numpy as np
import shapely
from native_reference_cast import NativeReferenceModel
from world_visibility_ray_reference import sample_alpha
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    out=REV/'split-vent-room-composed-standing-rays-v5';out.mkdir(exist_ok=False)
    fragment_path=REV/'split-vent-room-raw-partition-v3/raw-source-fragments.npz';fr=np.load(fragment_path)
    source_path=REV/'full-height-input-v1/split/split.height.bin.gz'
    reference=NativeReferenceModel(source_path,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    corr=np.load(source_path.parent/'source-correspondence.npz')['sourceFaces']
    raw_to_full={int(raw):i for i,raw in enumerate(corr)}
    admit=np.array([int(parent) in raw_to_full for parent in fr['sourceFaces']]) & ~fr['collapsedPhysicalFaces']
    triangles=fr['trianglesNativeSourceZ'][admit];parents=fr['sourceFaces'][admit];bary=fr['barycentrics'][admit]
    full=np.array([raw_to_full[int(parent)] for parent in parents]);masks=reference.arrays['faceMasks'][full]
    candidate_uv=np.zeros((len(parents),3,2));masked=masks>=0
    candidate_uv[masked]=np.einsum('nij,njk->nik',bary[masked],reference.arrays['maskedUvs'][masks[masked]])
    complete=REV/'split-complete-control-original-height-v29-v2';base=NativeReferenceModel(complete/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    comp=np.load(complete/'composition-provenance.npz');lift=np.load(REV/'split-source-world-fragments-v29-v1/source-world-fragments.npz')
    groups=[np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'],lift['fullSourceParents'],lift['discardedFullSourceParents'],np.load(REV/'split-source-height-region-oracle-v29-v1/original-source-provenance.npz')['fullSourceParents']]
    base_full=np.empty(len(comp['group']),dtype=np.int64)
    for group,lookup in enumerate(groups):
        use=comp['group']==group;base_full[use]=lookup[comp['inputId'][use]]
    base_raw=corr[base_full];exclude=np.flatnonzero(np.isin(base_raw,fr['originalSourceFaces'])).astype(np.int32)
    def retained(start,end):
        fp=ctypes.POINTER(ctypes.c_double);ip=ctypes.POINTER(ctypes.c_int32);skips=exclude.copy();result=np.zeros(3)
        while True:
            face=base.nearest(*base.pointers,start.ctypes.data_as(fp),end.ctypes.data_as(fp),1e-5,0.,1,skips.ctypes.data_as(ip),len(skips),result.ctypes.data_as(fp))
            if face==-2:raise ValueError('BVH stack overflow')
            if face<0:return None
            mask=int(base.arrays['faceMasks'][face]);distance,u,v=result
            if mask>=0:
                material=base.materials[int(base.arrays['maskedMaterials'][mask])];uv=np.array([1-u-v,u,v])@base.arrays['maskedUvs'][mask]
                if sample_alpha(base.textures[material['texture']],uv,material)<material['threshold']:
                    skips=np.r_[skips,np.int32(face)];continue
            return dict(rawSourceFace=int(base_raw[face]),distanceMeters=float(distance),kind='retained-original-height')
    edge1=triangles[:,1]-triangles[:,0];edge2=triangles[:,2]-triangles[:,0]
    def candidate(start,end):
        delta=end-start;limit=np.linalg.norm(delta);direction=delta/limit
        cross=np.cross(direction,edge2);det=np.einsum('ij,ij->i',edge1,cross);valid=abs(det)>1e-12
        inv=np.zeros(len(det));inv[valid]=1/det[valid];tvec=start-triangles[:,0]
        u=np.einsum('ij,ij->i',tvec,cross)*inv;q=np.cross(tvec,edge1)
        v=q@direction*inv;distance=np.einsum('ij,ij->i',edge2,q)*inv
        valid &= (u>=0)&(v>=0)&(u+v<=1)&(distance>=1e-5)&(distance<=limit)
        rows=np.flatnonzero(valid)
        for i in rows[np.argsort(distance[rows])]:
            mask=masks[i]
            if mask>=0:
                material=reference.materials[int(reference.arrays['maskedMaterials'][mask])]
                uv=np.array([1-u[i]-v[i],u[i],v[i]])@candidate_uv[i]
                if sample_alpha(reference.textures[material['texture']],uv,material)<material['threshold']:continue
            return dict(rawSourceFace=int(parents[i]),distanceMeters=float(distance[i]),kind='held-vent-source-fragment')
        return None
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc);backward=explicit_warp(wt,ws-wt,wc);flip=np.array(w['attackToDefenseSvg']['origin'])
    receivers=[receiver_domain(Path('assets/maps/split_map.svg')),receiver_domain(Path('assets/maps/split_map_defense.svg'))]
    meta_path=ROOT/'supplemented-v2/world/split/geometry.json';meta=json.loads(meta_path.read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    def enrich(hit,start,end):
        if hit is None:return None
        delta=end-start;point=start+delta/np.linalg.norm(delta)*hit['distanceMeters'];shown=forward.apply(point[None,:2]@matrix.T+origin)[0]
        obj=int(np.searchsorted(starts,hit['rawSourceFace'],side='right')-1)
        positions=[shown,flip-shown]
        boundary_distances=[float(receiver.boundary.distance(shapely.Point(position))) for receiver,position in zip(receivers,positions)]
        covers=[bool(receiver.covers(shapely.Point(position))) for receiver,position in zip(receivers,positions)]
        classifications=['on-boundary-within-coordinate-arithmetic' if distance<=4*np.spacing(max(1.,float(abs(position).max()))) else
                         'painted-interior' if covered else 'unpainted' for position,distance,covered in zip(positions,boundary_distances,covers)]
        return dict(**hit,point=point.tolist(),displaySvg=shown.tolist(),sourceObject=obj,sourcePath=meta['objects'][obj]['path'],
                    paintedReceiver=covers,receiverBoundaryDistanceSvg=boundary_distances,receiverClassifications=classifications)
    nav_path=REV/'split-174-receiver-first-hit-review-v2/nav-standing-origin-review-v2.json';nav=json.loads(nav_path.read_text());records=[]
    # Additional observers are admitted from the original extracted navigation
    # at their fixed SVG positions. Keep every overlapping floor separate.
    raw_nav_path=ROOT/'nav/baked/split_source_xyz.json';nav_header_path=ROOT/'nav/baked/split_navigation.json'
    raw_nav=json.loads(raw_nav_path.read_text());nav_header=json.loads(nav_header_path.read_text())
    assert raw_nav['navigationSha256']==sha(nav_header_path)
    nav_vertices=np.array(raw_nav['vertices']).reshape(-1,3)/100;nav_vertices[:,1]*=-1
    nav_refs=np.array(raw_nav['triangles']).reshape(-1,4);nav_tris=nav_vertices[nav_refs[:,1:]]
    nav_shapes=shapely.polygons(nav_tris[:,:,:2]);nav_valid=np.flatnonzero(np.array(nav_header['walkable'])[nav_refs[:,0]] & (shapely.area(nav_shapes)>1e-10));nav_tree=shapely.STRtree(nav_shapes[nav_valid])
    probes=[]
    for edge,axis,fixed,lo,hi,side in [(173,0,263.657,169.,195.9,1),(175,0,256.214,182.5,195.9,-1),
            (176,1,182.274,213.,255.9,1),(125,1,210.45,236.2,282.5,-1),
            (124,0,282.796,169.,210.2,-1),(172,1,168.451,263.9,298.5,1)]:
        for along in np.arange(lo,hi,.5):
            p=np.zeros(2);p[axis]=fixed+side*4.8875;p[1-axis]=along
            q=p.copy();q[axis]=fixed-side*1.955
            probes.append(dict(edge=edge,originSvg=p.tolist(),targetSvg=q.tolist(),wallAxis=axis,authoredFixed=fixed))
    grid_records=[]
    for probe in probes:
        xy=(backward.apply(np.array(probe['originSvg'])[None])[0]-origin)@inverse.T;point=shapely.Point(xy);associations=[]
        if not receivers[0].covers(shapely.Point(probe['originSvg'])):continue
        for tid in nav_valid[nav_tree.query(point,predicate='intersects')]:
            parent=int(nav_refs[tid,0]);polygon=shapely.Polygon(nav_vertices[raw_nav['polygons'][parent],:2]);margin=float(polygon.boundary.distance(point))
            if margin<.15:continue
            plane=np.linalg.solve(np.c_[nav_tris[tid,:,:2],np.ones(3)],nav_tris[tid,:,2]);floor=float(xy@plane[:2]+plane[2]);feet=np.r_[xy,floor]
            body=[base.cast(feet+[dx,dy,.2],feet+[dx,dy,1.75]) for dx,dy in [(0,0),(.12,0),(-.12,0),(0,.12),(0,-.12)]]
            if any(hit is not None for hit in body):continue
            associations.append(dict(navTriangle=int(tid),navParent=parent,nativeFeet=feet.tolist(),fiveVerticalBodyProbesClear=True,parentBoundaryMarginMeters=margin,bodyHits=body))
        if associations:grid_records.append(dict(frozenRay=dict(finishSvg=probe['targetSvg']),navFloorAssociations=associations,gridProbe=probe))
    nav['records'].extend(grid_records)
    frozen=[]
    for index,row in enumerate(nav['records']):
        for association in row['navFloorAssociations']:
            if not association['fiveVerticalBodyProbesClear']:continue
            start=np.array(association['nativeFeet']);start[2]+=1.75
            targets=[('original-frozen-target',row['frozenRay']['finishSvg']),('lower-doorway-interior',[260.,194.]),('lower-left-wall-receiver',[260.,204.]),('right-wall-receiver',[284.,204.]),('bottom-wall-receiver',[276.,211.]),('top-wall-termination',[284.,168.])]
            if 'gridProbe' in row:targets=[(f"standing-grid-wall-{row['gridProbe']['edge']}",row['frozenRay']['finishSvg'])]
            for name,target in targets:
                end=np.r_[(backward.apply(np.array(target,dtype=float)[None])[0]-origin)@inverse.T,start[2]]
                old=base.cast(start,end,end_padding=0,end_inclusive=True)
                if old:old=dict(rawSourceFace=int(base_raw[old['face']]),distanceMeters=old['distanceMeters'],kind='baseline-original-height')
                retained_hit=retained(start,end);changed_hit=candidate(start,end)
                candidates=[hit for hit in [retained_hit,changed_hit] if hit is not None]
                hit=min(candidates,key=lambda x:x['distanceMeters']) if candidates else None
                records.append(dict(frozenRecord=index,navTriangle=association['navTriangle'],navParent=association['navParent'],fiveOriginalBodyProbesClear=True,parentBoundaryMarginMeters=association['parentBoundaryMarginMeters'],
                    targetRole=name,originalEye=start.tolist(),originalTarget=end.tolist(),targetSvg=target,
                    gridProbe=row.get('gridProbe'),before=enrich(old,start,end),after=enrich(hit,start,end),retained=enrich(retained_hit,start,end),changed=enrich(changed_hit,start,end)))
            frozen.append(dict(record=index,navTriangle=association['navTriangle'],originalEye=start.tolist()))
    report=dict(scope=__doc__,rawFragmentSha256=sha(fragment_path),sourcePartitionReportSha256=sha(fragment_path.parent/'partition-review.json'),
        frozenNavReviewSha256=sha(nav_path),baselineOriginalHeightSha256=sha(complete/'split.height.bin.gz'),fullSourceHeightSha256=sha(source_path),
        scriptSha256=sha(Path(__file__)),declarationSha256=sha(REV/'split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json'),
        maskedAdmittedFragments=int(masked.sum()),admittedSourceFragments=len(triangles),sourceMaskAdmission='Existing full original-height material and source-face admission. Raw faces absent from that pack are not newly admitted.',
        frozenStandingAssociations=frozen,records=records,
        additionalNavGrid=dict(rawNavigationSha256=sha(raw_nav_path),navHeaderSha256=sha(nav_header_path),minimumParentBoundaryMarginMeters=.15,requestedProbes=len(probes),admittedProbePositions=len(grid_records),records=grid_records),
        limits='Frozen original nav coordinates and actual source feet heights. Existing five body probes are frozen input evidence, not full pawn collision. New targets are diagnostic receiver targets, not extra certified player poses. No production candidate or game capture.')
    (out/'composed-rays.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(output=str(out),rays=len(records),standingAssociations=len(frozen),maskedFragments=int(masked.sum()),firstHitObjects=sorted(set(r['after']['sourceObject'] for r in records if r['after'])))))


if __name__=='__main__':main()
