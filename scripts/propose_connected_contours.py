"""Nominate complete dark-fill contour source planes without accepting a bake.

All spans, including short returns and curves, remain in the manifest. Source
planes are nominated from exact retained contact faces, expanded within the same
source instance and finite review bounds. Endpoint-only and remote-plane evidence
is explicit, so the secondary90 tower mistake cannot silently become ownership.
"""
import argparse,gzip,hashlib,json
from collections import Counter,defaultdict
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from render_competing_floor_assemblies import clip_mesh_xy

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
POLICY=dict(sourcePlaneResidualSvg=.005,maximumNormalZ=.02,maximumAngleDegrees=10.,finiteReviewMarginSvg=3.,endpointBandSvg=.5,minimumInteriorContacts=2,scope='Nomination bounds only. No geometry acceptance, inferred solid height, or tolerance-based visual passing.')

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def component_stem(element, component, component_id_counts):
    # Different SVG elements restart their subpath numbering. Preserve both
    # inventories instead of overwriting the earlier component on disk.
    return (f'element-{element}-component-{component}'
            if component_id_counts[component] > 1 else f'component-{component}')

def build(name,version):
    out=REV/f'{name}-connected-contour-proposals-{version}';out.mkdir(exist_ok=True)
    coverage_path=REV/f'all-map-wall-span-coverage-v1/{name}/attack.coverage.json.gz';c=json.loads(gzip.decompress(coverage_path.read_bytes()))
    rawpath=ROOT/f'supplemented-v2/world/{name}/geometry.npz';raw=np.load(rawpath);p,f=raw['points'],raw['faces'];meta=json.loads(rawpath.with_suffix('.json').read_text());affine=np.array(json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2]
    object_cache={}
    def object_triangles(obj):
        if obj not in object_cache:
            entry=meta['objects'][obj];ids=np.arange(entry['firstFace'],entry['firstFace']+entry['faceCount']);xyz=p[f[ids]].copy();xyz[:,:,:2]=xyz[:,:,:2]@matrix.T+origin;object_cache[obj]=(ids,xyz)
        return object_cache[obj]
    staged_path=REV/'split-wall-family-normalized-candidate-v15/bindings.json'
    staged=json.loads(staged_path.read_text()) if name=='split' and staged_path.exists() else None
    rows=[]
    for span in c['spans']:
        target=np.array([span['startSvg'],span['endSvg']]);delta=target[1]-target[0];length=np.linalg.norm(delta)
        record=dict(completeSpan=span['span'],legacyStraightEdgeIndex=span['legacyStraightEdgeIndex'],elementIndex=span['elementIndex'],component=span['subpath'],segmentType=span['segmentType'],segmentSvg=span['segmentSvg'],authoredEndpoints=target.tolist(),lengthSvg=span['lengthSvg'],planes=[],reasons=[],status='unresolved')
        rows.append(record)
        record['existingStagedFamilyEdges']=[r['edge'] for r in staged['families'] if r.get('completeSpan')==span['span'] or ('completeSpan' not in r and r['edge']==span['legacyStraightEdgeIndex'])] if staged else []
        if span['segmentType']!='Line':record['reasons'].append('curve-requires-source-profile-and-shared-curve-policy');continue
        if length==0:record['reasons'].append('zero-length-authored-segment');continue
        tangent=delta/length;contacts=[c['samples'][i] for i in span['sampleRows'] if c['samples'][i]['status']=='contact'];record['sampleStatusCounts']=dict(Counter(c['samples'][i]['status'] for i in span['sampleRows']));record['standingContactCount']=sum(r.get('relativeEyeHeightMeters')==1.75 for r in contacts)
        planes=[]
        for hit in contacts:
            if hit.get('masked'):record['reasons'].append('masked-contact-needs-alpha-profile-ownership');continue
            fid=hit['originalSourceFace'];xyz=p[f[fid]];normal=np.cross(xyz[1]-xyz[0],xyz[2]-xyz[0]);norm=np.linalg.norm(normal)
            if norm==0:continue
            normal/=norm
            if abs(normal[2])>POLICY['maximumNormalZ']:continue
            xy=xyz[:,:2]@matrix.T+origin;_,_,basis=np.linalg.svd(xy-xy.mean(0));st=basis[0]
            if st@tangent<0:st=-st
            angle=float(np.rad2deg(np.arccos(np.clip(st@tangent,-1,1))))
            if angle>POLICY['maximumAngleDegrees']:continue
            sn=np.array([-st[1],st[0]]);offset=float(xy.mean(0)@sn);obj=hit['sourceObjectIndex']
            # A different source instance is never absorbed just because its
            # name or plane looks similar. The corner graph can propose a
            # multi-instance family later, with each identity retained.
            found=next((g for g in planes if g['sourceObjectIndex']==obj and abs(g['normal']@sn)>.99999 and abs(g['offset']-offset)<POLICY['sourcePlaneResidualSvg']),None)
            if found is None:
                found=dict(sourceObjectIndex=obj,normal=sn,tangent=st,offset=offset,sourceTargetAngleDegrees=angle,seeds=set(),contacts=[]);planes.append(found)
            found['seeds'].add(fid);found['contacts'].append(hit)
        for plane in planes:
            ids,xyz=object_triangles(plane['sourceObjectIndex']);residual=np.max(abs(xyz[:,:,:2]@plane['normal']-plane['offset']),axis=1);near=ids[residual<=POLICY['sourcePlaneResidualSvg']];lo=target.min(0)-POLICY['finiteReviewMarginSvg'];hi=target.max(0)+POLICY['finiteReviewMarginSvg'];selected=[];triangles=[];triangle_sources=[]
            for fid in near:
                tri=p[f[fid]].copy();tri[:,:2]=tri[:,:2]@matrix.T+origin
                pieces=clip_mesh_xy(np.array([tri]),lo,hi)
                if len(pieces):selected.append(int(fid));triangles.extend(pieces);triangle_sources.extend([int(fid)]*len(pieces))
            hits=plane['contacts'];band=min(POLICY['endpointBandSvg'],length*.2);interior=[h for h in hits if band<h['alongSvg']<length-band];standing=[h for h in interior if h.get('relativeEyeHeightMeters')==1.75];reasons=[]
            if not selected:reasons.append('no-plane-fragment-inside-finite-review-bound')
            if not interior:reasons.append('endpoint-only-plane-do-not-assign-whole-wall')
            if len({h['samplePosition'] for h in standing})<POLICY['minimumInteriorContacts']:reasons.append('insufficient-independent-standing-interior-positions')
            if max(abs(h['inwardGapSvg']) for h in hits)>POLICY['finiteReviewMarginSvg']:reasons.append('remote-first-contact-outside-local-wall-correspondence')
            if selected:
                allxy=np.array(triangles)[:,:,:2];along=(allxy-target[0])@tangent;interval=[float(along.min()),float(along.max())];overlap=max(0.,min(length,interval[1])-max(0.,interval[0]))
                if overlap<min(.25,length*.25):reasons.append('source-extent-mostly-beyond-authored-endpoint')
            else:interval=None;overlap=0.
            record['planes'].append(dict(sourceObjectIndex=plane['sourceObjectIndex'],sourceObject=meta['objects'][plane['sourceObjectIndex']],sourcePlane=dict(normal=plane['normal'].tolist(),tangent=plane['tangent'].tolist(),offset=plane['offset']),sourceTargetAngleDegrees=plane['sourceTargetAngleDegrees'],seedSourceFaces=sorted(plane['seeds']),expandedSourceFaces=selected,finiteReviewBoundsSvg=[*lo,*hi],sourceClippedTrianglesSvgZ=np.array(triangles).tolist(),sourceProjectedAlongInterval=interval,authoredIntervalOverlapSvg=overlap,contactSampleRows=[{k:h.get(k) for k in ['samplePosition','alongSvg','relativeEyeHeightMeters','originalSourceFace','inwardGapSvg']} for h in hits],interiorPositionCount=len({h['samplePosition'] for h in interior}),standingInteriorPositionCount=len({h['samplePosition'] for h in standing}),reasons=reasons,status='plane-proposal' if not reasons else 'ambiguous-plane'))
            record['planes'][-1]['clippedTriangleSourceFaces']=triangle_sources
        record['reasons']=sorted(set(record['reasons']))
        if not record['planes']:record['reasons'].append('no-source-plane-nominated-from-current-contact-records')
        eligible=[i for i,g in enumerate(record['planes']) if g['status']=='plane-proposal'];record['primaryPlaneCandidates']=eligible
        if len(eligible)==1:record['status']='single-primary-plane-proposal'
        elif len(eligible)>1:record['status']='multiple-primary-planes-need-source-family-review'
        else:record['status']='source-profile-or-ownership-review-required'
    owners=defaultdict(set)
    for row in rows:
        for plane in row['planes']:
            for fid in plane['expandedSourceFaces']:owners[fid].add(row['completeSpan'])
    for row in rows:
        for plane in row['planes']:
            plane['sharedSourceFaceOwnership']=[dict(sourceFace=fid,completeSpans=sorted(owners[fid])) for fid in plane['expandedSourceFaces'] if len(owners[fid])>1]
    components=[]
    component_keys=sorted({(r['elementIndex'],r['component']) for r in rows})
    component_id_counts=Counter(component for element,component in component_keys)
    for key in component_keys:
        selected=[r for r in rows if (r['elementIndex'],r['component'])==key];joins=[]
        for i,left in enumerate(selected):
            right=selected[(i+1)%len(selected)];target=np.array(left['authoredEndpoints'][1]);end_error=float(np.linalg.norm(target-np.array(right['authoredEndpoints'][0])));possibilities=[]
            for li,lp in enumerate(left['planes']):
                for ri,rp in enumerate(right['planes']):
                    normals=np.array([lp['sourcePlane']['normal'],rp['sourcePlane']['normal']]);det=float(np.linalg.det(normals))
                    if abs(det)<1e-8:continue
                    point=np.linalg.solve(normals,[lp['sourcePlane']['offset'],rp['sourcePlane']['offset']]);shift=float(np.linalg.norm(point-target));possibilities.append(dict(leftPlane=li,rightPlane=ri,sourceIntersectionSvg=point.tolist(),targetShiftSvg=shift,status='local-source-join-proposal' if shift<=4 and lp['status']=='plane-proposal' and rp['status']=='plane-proposal' else 'ambiguous-or-remote-join'))
            joins.append(dict(leftSpan=left['completeSpan'],rightSpan=right['completeSpan'],targetSvg=target.tolist(),authoredJoinErrorSvg=end_error,sourceJoinCandidates=possibilities,rule='One accepted shared source/target join must be reused by both incident spans. Parallel relief requires explicit common ownership; no nearest-wall projection.'))
        component=dict(elementIndex=key[0],component=key[1],spanCount=len(selected),statusCounts=dict(Counter(r['status'] for r in selected)),spans=selected,joins=joins,status='Proposals only. Source height gaps and unresolved secondary planes remain explicit. No candidate bake.')
        stem=component_stem(*key,component_id_counts)
        rawbytes=json.dumps(component,separators=(',',':')).encode();file=out/f'{stem}.json.gz';file.write_bytes(gzip.compress(rawbytes,mtime=0));components.append(dict(elementIndex=key[0],component=key[1],file=file.name,sha256=sha(file),spanCount=len(selected),statusCounts=component['statusCounts']))
        fig,ax=plt.subplots(figsize=(13,12));allpoints=[]
        for row in selected:
            line=np.array(row['authoredEndpoints']);allpoints.extend(line);ax.plot(*line.T,color='#ea580c',linewidth=2,linestyle='-' if row['segmentType']=='Line' else ':');ax.text(*line.mean(0),str(row['completeSpan']),fontsize=7,clip_on=True)
            for plane in row['planes']:
                color='#0284c7' if plane['status']=='plane-proposal' else '#dc2626'
                triangles=np.array(plane['sourceClippedTrianglesSvgZ'])
                if len(triangles):
                    outlines=triangles[:,[0,1,2,0],:2]
                    ax.add_collection(LineCollection(outlines,colors=color,linewidths=.25,alpha=.35))
        curve_note='\nDotted orange lines show unresolved curve endpoint chords only.' if any(r['segmentType']!='Line' for r in selected) else ''
        vv=np.array(allpoints);lo=vv.min(0)-5;hi=vv.max(0)+5;ax.set_xlim(lo[0],hi[0]);ax.set_ylim(hi[1],lo[1]);ax.set_aspect('equal');ax.grid(alpha=.15);ax.set_title(f'{name.title()} dark-fill element{key[0]}, component{key[1]}: {len(selected)} spans\nOrange authored; blue source-plane proposals; red ambiguous/endpoint/remote evidence. Labels use complete span IDs.'+curve_note);fig.tight_layout();fig.savefig(out/f'{stem}.png',dpi=150);plt.close(fig)
    assert len({r['completeSpan'] for r in rows})==len(c['spans'])
    assert sum(x['spanCount'] for x in components)==len(rows)
    result=dict(map=name,sourceGeometrySha256=meta['geometrySha256'],sourceCoverageSha256=sha(coverage_path),sourceArtworkSha256=sha(Path(f'assets/maps/{name}_map.svg')),generatorSha256=sha(Path(__file__)),existingStagedBindingsSha256=sha(staged_path) if staged else None,policy=POLICY,completeSpanCount=len(rows),componentCount=len(components),statusCounts=dict(Counter(r['status'] for r in rows)),planeReasonCounts=dict(Counter(reason for r in rows for g in r['planes'] for reason in g['reasons'])),components=components,scope='All authoritative dark-fill path spans in existing source coverage. Existing staged families are cross-referenced, not treated as final acceptance. Interior-cover strokes and separate artwork paths are a separate pass. Nothing is accepted or baked by this inventory.')
    (out/'summary.json').write_text(json.dumps(result,indent=2));print(result['statusCounts']);print(result['planeReasonCounts']);print(out)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--map',default='split');parser.add_argument('--version',default='v1');args=parser.parse_args();build(args.map,args.version)
