"""Frozen A-site17 contacts against a connected-building declaration.

The proposal is queried as exact horizontal source sections partitioned by its
declared affine cells. Other geometry comes from the verified V29 original-Z
oracle, with selected source faces excluded. No candidate pack is written.
"""
import argparse
import ctypes
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from verify_region_mapping import verify_rank_one_declarations
from declare_split_legacy105_connected_region import ROOT, REV, sha
from native_reference_cast import NativeReferenceModel
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from world_visibility_ray_reference import sample_alpha


def main(declaration, out):
    out.mkdir(exist_ok=False)
    family=json.loads(declaration.read_text());assert isinstance(family,dict) and family['edge']==200018
    retained_ids=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    selected_ids=np.intersect1d(family['reviewedSourceFaces'],retained_ids)
    rank_one=verify_rank_one_declarations(family)
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
    raw_to_full={int(full_correspondence[i]):int(i) for i in full_selected}
    for raw_id,full_id in raw_to_full.items():
        np.testing.assert_allclose(original.arrays['vertices'][original.arrays['faces'][full_id]],points[faces[raw_id]],atol=1e-10,rtol=0)
    comp=np.load(complete/'composition-provenance.npz');control_to_full=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces']
    lift=np.load(REV/'split-source-world-fragments-v29-v1/source-world-fragments.npz')
    reviewed=np.load(REV/'split-source-height-region-oracle-v29-v1/original-source-provenance.npz')['fullSourceParents']
    full_ids=np.empty(len(comp['group']),dtype=np.int64)
    for group,lookup in enumerate([control_to_full,lift['fullSourceParents'],lift['discardedFullSourceParents'],reviewed]):
        mask=comp['group']==group;full_ids[mask]=lookup[comp['inputId'][mask]]
    baseline_raw=full_correspondence[full_ids]
    excluded=np.flatnonzero(np.isin(baseline_raw,selected_ids)).astype(np.int32)
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
    section_cache={}
    def mapped_sections(z):
        if z in section_cache:return section_cache[z]
        lines,ids=sections(selected,z);result=[];owners=[];section_alpha=[]
        def append(display,source_xy,raw_id,triangle,model,face_id):
            if np.linalg.norm(display[-1]-display[0])<=1e-12:return
            result.append(shapely.LineString(display));owners.append(int(raw_id))
            mask=int(model.arrays['faceMasks'][face_id])
            if mask<0:section_alpha.append(None);return
            xyz=np.column_stack((source_xy,np.full(len(source_xy),z)))
            uvw=np.linalg.lstsq((triangle[1:]-triangle[0]).T,(xyz-triangle[0]).T,rcond=None)[0].T
            weights=np.column_stack((1-uvw.sum(1),uvw))
            np.testing.assert_allclose(weights@triangle,xyz,atol=1e-8,rtol=0)
            material=model.materials[int(model.arrays['maskedMaterials'][mask])]
            section_alpha.append((weights@model.arrays['maskedUvs'][mask],material,model.textures[material['texture']]))
        for line,index in zip(lines,ids):
            raw_id=int(selected_ids[index]);full_id=raw_to_full[raw_id]
            segment=shapely.LineString(line)
            for part in shapely.get_parts(segment.difference(domain)):
                if part.geom_type=='LineString' and part.length>0:
                    p=np.array(part.coords);append(forward.apply(p),p,raw_id,selected[index],original,full_id)
            segment=segment.intersection(domain)
            if segment.is_empty or segment.geom_type!='LineString':continue
            for cell in region_tree.query(segment,predicate='intersects'):
                for part in shapely.get_parts(segment.intersection(region_polygons[cell])):
                    if part.geom_type!='LineString' or part.length==0:continue
                    p=np.array(part.coords);weights=barycentric(p,s[c[cell]]);q=weights@t[c[cell]]
                    if int(cell) in rank_one:
                        entry=rank_one[int(cell)];a,b=entry["endpoints"];q=a+(weights@entry["parameters"])[:,None]*(b-a)
                    append(q,p,raw_id,selected[index],original,full_id)
        section_cache[z]=(result,np.array(owners),section_alpha)
        return section_cache[z]
    nav_path=REV/'split-remaining-standing-origins-v1/edge-17.json'
    frozen=json.loads(nav_path.read_text())['records']
    source_evidence_path=REV/'split-asite-return18-source-review-v2/original-height-independent-rays.json'
    evidence=json.loads(source_evidence_path.read_text());cases=[]
    for entry in evidence:
        matches=[row for row in frozen if np.array_equal(row['frozenRay']['startSvg'],entry['startSvg'])]
        assert len(matches)==1
        assert any(a['parentBoundaryMarginMeters']>.15 and a['fiveVerticalBodyProbesClear'] for a in matches[0]['navFloorAssociations'])
        for ray in entry['originalHeightRays']:
            cases.append(dict(startSvg=entry['startSvg'],targetSvg=matches[0]['frozenRay']['finishSvg'],eyeZ=ray['eyeZ'],
                sourceFloorProbe=entry['floorProbe'],sourceStandingEvidence=matches[0]['navFloorAssociations']))
    records=[];fixture_rows=[]
    for number,case in enumerate(cases):
        z=float(case['eyeZ']);shown=np.array([case['startSvg']]);index=0
        start=np.r_[(backward.apply(shown[0])-origin)@inverse.T,z]
        target_points=[case['targetSvg']]
        geometries,owners,section_alpha=mapped_sections(z);section_tree=shapely.STRtree(geometries)
        fixture_rows.append(dict(id=number,originalEye=start.tolist(),displayedOriginSvg=shown[0].tolist(),**case))
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
                                alpha=section_alpha[si]
                                if alpha is not None:
                                    ends=np.array(geometries[si].coords);delta=ends[-1]-ends[0];parameter=float((q-ends[0])@delta/(delta@delta));uvs,material,texture=alpha
                                    uv=(1-parameter)*uvs[0]+parameter*uvs[-1]
                                    if sample_alpha(texture,uv,material)<material['threshold']:continue
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
        scriptSha256=sha(Path(__file__)),sourceStandingEvidenceSha256=sha(source_evidence_path),selectedMaterials='Selected masked sheets carry original-face UV endpoints through the source section and affine field, then use the independent alpha sampler. Existing material omissions are retained. Other faces come from the independently verified complete V29 original-height oracle.',
        fixtures=fixture_rows,records=records,limitations='This is a source-section hybrid diagnostic, not a baked candidate or actual app capture. Exact source partition and product renderer gates remain separate.')
    (out/'first-hit-controls.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(fixture_rows),flush=True)
    print('proposed owners',sorted(set(r['proposedHybridHit']['sourceObject'] for r in records if r['proposedHybridHit'])),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--declaration',type=Path,default=REV/'split-asite-building-connected-proposal-v6/region-declaration.json')
    parser.add_argument('--out',type=Path,default=REV/'split-asite-building-standing17-hybrid-v6')
    args=parser.parse_args()
    main(args.declaration,args.out)
