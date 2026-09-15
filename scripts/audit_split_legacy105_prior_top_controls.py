"""First contacts against the held105 declaration at real nav standing heights.

The proposal is queried as exact horizontal source sections partitioned by its
declared affine cells. Other geometry comes from the verified V29 original-Z
oracle, with selected source faces excluded. No candidate pack is written.
"""
import ctypes
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from declare_split_legacy105_connected_region import ROOT, REV, sha
from native_reference_cast import NativeReferenceModel
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from world_visibility_ray_reference import sample_alpha


def main():
    out=REV/'split-legacy105-top-controls-prior-v2';out.mkdir(exist_ok=False)
    declaration=REV/'split-legacy105-connected-region-proposal-v2/region-declaration.json'
    family=json.loads(declaration.read_text());selected_ids=np.array(family['reviewedSourceFaces'])
    s=np.array(family['sourceVerticesSvg']);t=np.array(family['targetVerticesSvg']);c=np.array(family['triangles'])
    region_polygons=shapely.polygons(s[c]);region_tree=shapely.STRtree(region_polygons);domain=shapely.box(*family['box'])
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc);backward=explicit_warp(wt,ws-wt,wc)
    warp_polygons=shapely.polygons(ws[wc]);warp_tree=shapely.STRtree(warp_polygons)
    receivers=[receiver_domain(Path('assets/maps/split_map.svg')),receiver_domain(Path('assets/maps/split_map_defense.svg'))]
    side_matrix=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToDefenseSvg'])
    def defense(p):return ((np.asarray(p)-origin)@inverse.T)@side_matrix[:,:2].T+side_matrix[:,2]
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path);points=raw['points'];faces=raw['faces']
    meta=json.loads(raw_path.with_suffix('.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    selected=points[faces[selected_ids]].copy();selected[:,:,:2]=selected[:,:,:2]@matrix.T+origin
    full_correspondence=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    complete=REV/'split-complete-control-original-height-v29-v2';baseline=NativeReferenceModel(complete/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    original=NativeReferenceModel(REV/'full-height-input-v1/split/split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    full_selected=np.flatnonzero(np.isin(full_correspondence,selected_ids))
    assert np.all(original.arrays['faceMasks'][full_selected]<0), 'Masked selected faces require carried UV sampling'
    comp=np.load(complete/'composition-provenance.npz');control_to_full=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces']
    lift=np.load(REV/'split-source-world-fragments-v29-v1/source-world-fragments.npz')
    reviewed=np.load(REV/'split-source-height-region-oracle-v29-v1/original-source-provenance.npz')['fullSourceParents']
    full_ids=np.empty(len(comp['group']),dtype=np.int64)
    for group,lookup in enumerate([control_to_full,lift['fullSourceParents'],lift['discardedFullSourceParents'],reviewed]):
        mask=comp['group']==group;full_ids[mask]=lookup[comp['inputId'][mask]]
    baseline_raw=full_correspondence[full_ids];excluded=np.flatnonzero(np.isin(baseline_raw,selected_ids)).astype(np.int32)
    def retained_cast(start,end):
        fp=ctypes.POINTER(ctypes.c_double);ip=ctypes.POINTER(ctypes.c_int32);skips=excluded.copy();output=np.zeros(3)
        while True:
            fid=baseline.nearest(*baseline.pointers,start.ctypes.data_as(fp),end.ctypes.data_as(fp),1e-5,0.,1,skips.ctypes.data_as(ip),len(skips),output.ctypes.data_as(fp))
            if fid<0:return None
            mask=int(baseline.arrays['faceMasks'][fid])
            if mask>=0:
                material=baseline.materials[int(baseline.arrays['maskedMaterials'][mask])];u,v=output[1:];uv=np.array([1-u-v,u,v])@baseline.arrays['maskedUvs'][mask]
                if sample_alpha(baseline.textures[material['texture']],uv,material)<material['threshold']:
                    skips=np.r_[skips,np.int32(fid)];continue
            delta=end-start;delta/=np.linalg.norm(delta)
            return dict(rawSourceFace=int(baseline_raw[fid]),distanceMeters=float(output[0]),point=(start+delta*output[0]).tolist(),kind='retained-v29-original-height')
    def enrich(hit):
        if hit is None:return None
        raw_id=hit['rawSourceFace'];obj=int(np.searchsorted(starts,raw_id,side='right')-1)
        hit.update(sourceObject=obj,sourcePath=meta['objects'][obj]['path'],displayedHitSvg=forward.apply(np.array(hit['point'][:2])@matrix.T+origin).tolist());return hit
    def mapped_sections(z):
        lines,ids=sections(selected,z);result=[];owners=[]
        for line,index in zip(lines,ids):
            segment=shapely.LineString(line)
            for cell in region_tree.query(segment,predicate='intersects'):
                for part in shapely.get_parts(segment.intersection(region_polygons[cell])):
                    if part.geom_type!='LineString' or part.length==0:continue
                    p=np.array(part.coords);q=barycentric(p,s[c[cell]])@t[c[cell]]
                    if np.linalg.norm(q[-1]-q[0])>1e-12:result.append(shapely.LineString(q));owners.append(int(selected_ids[index]))
            for part in shapely.get_parts(segment.difference(domain)):
                if part.geom_type=='LineString' and part.length>0:
                    result.append(shapely.LineString(forward.apply(np.array(part.coords))));owners.append(int(selected_ids[index]))
        return result,np.array(owners)
    nav_path=Path('assets/maps/world/split_navigation.json.gz');nav=json.loads(gzip.decompress(nav_path.read_bytes()))
    assert 'sourcePolygonIds' not in nav
    ui=json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']['split']['uiTransform']
    fm=nav['floorMesh'];v=np.array(fm['vertices']).reshape(-1,3);indices=np.array(fm['triangles']).reshape(-1,4);centers=v[indices[:,1:]].mean(1)
    uv=centers[:,:2]/fm['coordinateScale'];native=np.column_stack(((uv[:,1]-ui['YScalarToAdd'])/(100*ui['YMultiplier']),-(uv[:,0]-ui['XScalarToAdd'])/(100*ui['XMultiplier'])))
    shown=forward.apply(native@matrix.T+origin);eligible=np.array(nav['walkable'])[indices[:,0]].astype(bool)
    eligible&=shapely.covers(receivers[0],shapely.points(shown));target_points=[[float(x),279.5] for x in np.linspace(279.2,292.2,27)]+[[278.5,283.],[278.5,287.]]
    records=[];fixture_rows=[]
    for number,wanted in enumerate([[288,285],[287,300],[289,309]]):
        distance=np.linalg.norm(shown-wanted,axis=1);distance[~eligible]=np.inf;index=int(distance.argmin());z=float(centers[index,2]/100+1.75)
        start=np.r_[native[index],z];geometries,owners=mapped_sections(z);section_tree=shapely.STRtree(geometries)
        fixture_rows.append(dict(id=number,sourceNavTriangle=index,sourceNavParent=int(indices[index,0]),sourceFloorMeters=z-1.75,originalEye=start.tolist(),displayedOriginSvg=shown[index].tolist(),selectionDistanceSvg=float(distance[index])))
        for target in target_points:
            end=np.r_[(backward.apply(np.array(target,dtype=float))-origin)@inverse.T,z];direction=end-start;limit=float(np.linalg.norm(direction));direction/=limit
            old=original.cast(start,end,end_padding=0,end_inclusive=True)
            if old:old['rawSourceFace']=int(full_correspondence[old['face']]);enrich(old)
            base=baseline.cast(start,end,end_padding=0,end_inclusive=True)
            if base:base['rawSourceFace']=int(baseline_raw[base['face']]);enrich(base)
            nearest=retained_cast(start,end);display_path=[]
            physical_line=shapely.LineString(np.array([start[:2],end[:2]])@matrix.T+origin)
            for wi in warp_tree.query(physical_line,predicate='intersects'):
                for part in shapely.get_parts(physical_line.intersection(warp_polygons[wi])):
                    if part.geom_type!='LineString' or part.length==0:continue
                    line=shapely.LineString(forward.apply(np.array(part.coords)));display_path.append(np.array(line.coords).tolist())
                    for si in section_tree.query(line,predicate='intersects'):
                        for contact in shapely.get_parts(line.intersection(geometries[si])):
                            for q in shapely.get_coordinates(contact):
                                native_hit=(backward.apply(q)-origin)@inverse.T;travel=float((native_hit-start[:2])@direction[:2])
                                if travel<=1e-5 or travel>limit+1e-8:continue
                                if nearest is None or travel<nearest['distanceMeters']:
                                    nearest=dict(rawSourceFace=int(owners[si]),distanceMeters=travel,point=[*native_hit,z],kind='proposed-source-section')
            enrich(nearest)
            rowside=[]
            for side,receiver in enumerate(receivers):
                eye2=shown[index] if side==0 else defense(shown[index]);target2=np.array(target) if side==0 else defense(target)
                intervals=[]
                for line in display_path:
                    coords=np.array(line) if side==0 else defense(line)
                    for part in shapely.get_parts(shapely.LineString(coords).intersection(receiver)):
                        if part.geom_type=='LineString' and part.length>0:intervals.append(np.array(part.coords).tolist())
                rowside.append(dict(side='attack' if side==0 else 'defense',originSvg=eye2.tolist(),targetSvg=target2.tolist(),originPainted=bool(receiver.covers(shapely.Point(eye2))),targetPainted=bool(receiver.covers(shapely.Point(target2))),paintedPathSegments=intervals))
            records.append(dict(originId=number,queryStart=start.tolist(),queryEnd=end.tolist(),targetSvg=target,originalSourceHit=old,v29OriginalHeightHit=base,proposedHybridHit=nearest,sideReceiver=rowside,displayPath=display_path))
    report=dict(scope=__doc__,declarationSha256=sha(declaration),sourceGeometrySha256=sha(raw_path),sourceNavigationSha256=sha(nav_path),baselinePackSha256=sha(complete/'split.height.bin.gz'),
        scriptSha256=sha(Path(__file__)),selectedMaterials='All selected retained full-source faces have faceMask=-1. Other faces use the original independent alpha sampler.',
        fixtures=fixture_rows,records=records,limitations='This is a source-section hybrid diagnostic, not a baked candidate or actual app capture. Exact source partition and product renderer gates remain separate.')
    (out/'first-hit-controls.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(fixture_rows),flush=True)
    print('proposed owners',sorted(set(r['proposedHybridHit']['sourceObject'] for r in records if r['proposedHybridHit'])),flush=True)


if __name__=='__main__':main()
