"""Inventory first contacts along every authored dark-fill span on all maps.

This is a measurement under frozen tactical control geometry. It does not label
an SVG span as a solid wall or an opening, and does not certify gameplay accuracy.
"""
import argparse
from collections import Counter,defaultdict
import csv
import gzip
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import time
import traceback
import xml.etree.ElementTree as ET
import numpy as np
import shapely
from svgpathtools import Line,parse_path
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from native_reference_cast import NativeReferenceModel

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
MAPS=['abyss','ascent','bind','breeze','corrode','fracture','haven','icebox','lotus','pearl','split','summit','sunset']
HEIGHTS=(.75,1.75,2.75)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def header(path):
    with gzip.open(path,'rb') as stream:
        magic,length=struct.unpack('<4sI',stream.read(8))
        if magic!=b'IHD1':raise ValueError('Unexpected source pack')
        return json.loads(stream.read(length))
def save(path,data):path.write_bytes(gzip.compress((json.dumps(data,separators=(',',':'))+'\n').encode(),mtime=0))

def authored_spans(svg):
    root=ET.parse(svg).getroot();parents={child:parent for parent in root.iter() for child in parent};spans=[];legacy_index=0
    for element_index,element in enumerate(root.iter()):
        if not element.tag.endswith('path') or element.get('fill','').lower()!='#271406':continue
        ancestor=element
        while ancestor is not None:
            if 'transform' in ancestor.attrib or 'style' in ancestor.attrib:raise ValueError('Unsupported transformed/styled dark fill')
            ancestor=parents.get(ancestor)
        for subpath_index,subpath in enumerate(parse_path(element.get('d')).continuous_subpaths()):
            segments=list(subpath);implicit=False
            if segments and segments[-1].end!=segments[0].start:
                segments.append(Line(segments[-1].end,segments[0].start));implicit=True
            for segment_index,segment in enumerate(segments):
                length=float(segment.length());closing=implicit and segment_index==len(segments)-1
                legacy=legacy_index if isinstance(segment,Line) and length>=2 and not closing else None
                if legacy is not None:legacy_index+=1
                spans.append((dict(span=len(spans),elementIndex=element_index,elementId=element.get('id'),subpath=subpath_index,segment=segment_index,
                                   segmentType=type(segment).__name__,implicitFillClosure=closing,legacyStraightEdgeIndex=legacy,
                                   segmentSvg=segment.d() if hasattr(segment,'d') else str(segment),
                                   startSvg=[segment.start.real,segment.start.imag],endSvg=[segment.end.real,segment.end.imag],
                                   lengthSvg=length),segment))
    return spans

def sample_side(name,side,svg,source,control_to_full,full_to_original,meta,raw_points,raw_faces,forward,backward,projection,defense_origin,output):
    spans=authored_spans(svg);receiver=receiver_domain(svg);samples=[];records=[]
    for record,segment in spans:
        record['samplePositions']=[];record['unresolved']=[];length=record['lengthSvg'];records.append(record)
        if length<=0:record['unresolved'].append('zero-length-authored-span');continue
        margin=min(.001,length/4)
        distances=np.unique(np.r_[margin,np.arange(.25,length,.75),length-margin])
        for distance in distances:
            parameter=float(distance/length if isinstance(segment,Line) else segment.ilength(float(distance)))
            value=segment.point(parameter);tangent=segment.derivative(parameter)
            if abs(tangent)==0:record['unresolved'].append(dict(alongSvg=float(distance),reason='undefined-curve-tangent'));continue
            axis=np.array([tangent.real,tangent.imag])/abs(tangent);normal=np.array([-axis[1],axis[0]])
            record['samplePositions'].append(len(samples))
            samples.append(dict(span=record['span'],alongSvg=float(distance),parameter=parameter,pointSvg=[value.real,value.imag],axis=axis.tolist(),normal=normal.tolist()))
    points=np.array([row['pointSvg'] for row in samples]);normals=np.array([row['normal'] for row in samples])
    sides=np.c_[shapely.covers(receiver,shapely.points(points-.5*normals)),shapely.covers(receiver,shapely.points(points+.5*normals))]
    valid=np.flatnonzero(sides.sum(1)==1);signs=np.where(sides[:,0],-1,1)
    endpoints=np.stack([points+signs[:,None]*normals*6,points-signs[:,None]*normals*6],axis=1)
    start_inside=shapely.covers(receiver,shapely.points(endpoints[:,0]))
    attack_endpoints=endpoints if side=='attack' else defense_origin-endpoints
    warp_cells=backward.tri.find_simplex(attack_endpoints.reshape(-1,2)).reshape(-1,2)
    projected=backward.apply(attack_endpoints)
    origin,matrix=projection;inverse=np.linalg.inv(matrix);native_xy=(projected-origin)@inverse.T
    rows=[];faces={};objects={};object_starts=np.array([row['firstFace'] for row in meta['objects']]);hit_rows=[];hit_points=[]
    valid_set=set(valid.tolist())
    for sample_id,sample in enumerate(samples):
        base=dict(samplePosition=sample_id,span=sample['span'],alongSvg=sample['alongSvg'],parameter=sample['parameter'],pointSvg=sample['pointSvg'],receiverSides=sides[sample_id].tolist())
        if sample_id not in valid_set:
            rows.append({**base,'status':'receiver-side-ambiguous','unresolved':['receiver-side-ambiguous']});continue
        if np.any(warp_cells[sample_id]<0):
            rows.append({**base,'status':'probe-outside-display-warp','unresolved':['probe-outside-display-warp']});continue
        for height in HEIGHTS:
            a,b=native_xy[sample_id]
            hit=source.cast(np.r_[a,height],np.r_[b,height])
            unresolved=[] if start_inside[sample_id] else ['probe-origin-outside-receiver']
            row={**base,'relativeEyeHeightMeters':height,'receiverSign':int(signs[sample_id]),'probeStartInsideReceiver':bool(start_inside[sample_id]),
                 'probeNativeXY':native_xy[sample_id].tolist(),'status':'no-control-contact' if hit is None else 'contact','unresolved':unresolved}
            if hit is None:row['unresolved'].append('no-contact-within-probe')
            else:
                control=int(hit['face']);full=int(control_to_full[control]);original=int(full_to_original[full]);obj=int(np.searchsorted(object_starts,original,side='right')-1)
                obj_record=meta['objects'][obj]
                if not obj_record['firstFace']<=original<obj_record['firstFace']+obj_record['faceCount']:raise ValueError('Source instance correspondence is out of range')
                if original not in faces:
                    triangle=raw_points[raw_faces[original]];normal=np.cross(triangle[1]-triangle[0],triangle[2]-triangle[0]);size=np.linalg.norm(normal)
                    normal=normal/size if size>0 else np.array([np.nan]*3)
                    faces[original]=dict(originalSourceFace=original,sourceObjectIndex=obj,verticesNativeMeters=triangle.tolist(),normal=None if size==0 else normal.tolist(),degenerate=bool(size==0))
                    objects[obj]=obj_record
                face=faces[original];normal=face['normal'];near_vertical=normal is not None and abs(normal[2])<=.025
                if normal is None:row['unresolved'].append('degenerate-original-face')
                elif not near_vertical:row['unresolved'].append('nonvertical-original-face')
                row.update(controlFace=control,fullPackFace=full,originalSourceFace=original,sourceObjectIndex=obj,nearVerticalOriginalFace=near_vertical,
                           hitControlXYZ=hit['point'],controlNormal=hit['normal'],masked=hit['masked'])
                hit_rows.append(len(rows));hit_points.append(hit['point'][:2])
            rows.append(row)
        if sample_id and sample_id%2000==0:print(name,side,sample_id,'of',len(samples),'positions',flush=True)
    if hit_rows:
        hit_svg=forward.apply(np.array(hit_points)@matrix.T+origin)
        if side=='defense':hit_svg=defense_origin-hit_svg
        for index,point in zip(hit_rows,hit_svg):
            row=rows[index];sample=samples[row['samplePosition']];offset=point-np.array(sample['pointSvg'])
            inward=float(offset@np.array(sample['normal'])*row['receiverSign'])
            row.update(hitSvg=point.tolist(),inwardGapSvg=inward,tangentOffsetSvg=float(offset@np.array(sample['axis'])),
                       contactPosition='early' if inward>1e-4 else 'late' if inward< -1e-4 else 'within-numerical-contact-band')
            if abs(inward)>3:row['unresolved'].append('distant-control-contact')
    by_span=defaultdict(list)
    for row_id,row in enumerate(rows):by_span[row['span']].append(row_id)
    priorities=[]
    for record in records:
        ids=by_span[record['span']];record['sampleRows']=ids;contacts=[rows[i] for i in ids if rows[i]['status']=='contact']
        offsets=[row['inwardGapSvg'] for row in contacts];record['contactPositions']=dict(Counter(row['contactPosition'] for row in contacts))
        record['unresolvedRows']=sum(bool(rows[i]['unresolved']) for i in ids);record['maximumAbsoluteGapSvg']=max(map(abs,offsets),default=None)
        if any(abs(value)>1e-4 for value in offsets):priorities.append(dict(side=side,span=record['span'],lengthSvg=record['lengthSvg'],maximumAbsoluteGapSvg=record['maximumAbsoluteGapSvg'],contactPositions=record['contactPositions'],unresolvedRows=record['unresolvedRows']))
    report=dict(map=name,side=side,artSha256=sha(svg),receiverFlatteningToleranceSvg=1e-5,spans=records,samples=rows,sourceFaces=list(faces.values()),sourceObjects=[dict(sourceObjectIndex=index,**value) for index,value in sorted(objects.items())],
                scope='Every authored dark-fill path span including short, curved and implicit fill-closure spans. Curves use arc-length samples and local normals. Receiver-side ambiguity includes covered/internal path portions and remains unresolved. Native probes are straight chords between inverse-mapped SVG endpoints, matching the physical source-coordinate query convention.')
    save(output/f'{side}.coverage.json.gz',report)
    summary=dict(side=side,authoredSpans=len(records),curvedSpans=sum(record['segmentType']!='Line' for record in records),shortSpans=sum(record['lengthSvg']<2 for record in records),samplePositions=len(samples),sampleRows=len(rows),
                 castRays=sum('relativeEyeHeightMeters' in row for row in rows),contacts=len(hit_rows),statusCounts=dict(Counter(row['status'] for row in rows)),unresolvedReasons=dict(Counter(reason for row in rows for reason in row['unresolved'])),
                 contactPositions=dict(Counter(row['contactPosition'] for row in rows if 'contactPosition' in row)),spansWithMeasuredOffset=len(priorities),sourceFaceBindings=len(faces),sourceInstanceBindings=len(objects))
    return summary,priorities

def worker(name,output):
    started=time.perf_counter();folder=output/name;folder.mkdir(parents=True,exist_ok=False)
    manifest=json.loads((ROOT/'completeness/combined-manifest-release-inputs-v2.json').read_text());entry=next(row for row in manifest if row['map']==name)
    meta_path=Path(entry['combinedWorldFolder'])/'geometry.json';meta=json.loads(meta_path.read_text());full_path=REV/f'full-height-input-v1/{name}/{name}.height.bin.gz'
    full_header=header(full_path)
    if full_header['sourceGeometrySha256']!=meta['geometrySha256']:raise ValueError('Frozen source geometry hash mismatch')
    control=REV/f'global-ground-complete-v2/{name}/{name}.height.bin.gz';source=NativeReferenceModel(control,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    control_correspondence=control.parent/'correspondence.npz';full_correspondence=full_path.parent/'source-correspondence.npz'
    control_to_full=np.load(control_correspondence)['sourceFaces'];full_to_original=np.load(full_correspondence)['sourceFaces']
    if len(control_to_full)!=len(source.arrays['faces']):raise ValueError('Control correspondence length mismatch')
    if control_to_full.min()<0 or control_to_full.max()>=len(full_to_original):raise ValueError('Control correspondence range mismatch')
    raw=np.load(meta_path.with_suffix('.npz'));raw_points,raw_faces=raw['points'],raw['faces']
    if full_to_original.max()>=len(raw_faces):raise ValueError('Original source correspondence range mismatch')
    warp_path=REV/f'display-warps-v1/{name}.display-warp.json.gz';warp=json.loads(gzip.decompress(warp_path.read_bytes()))
    native=np.array(warp['sourceNativeMeters']).reshape(-1,2);target=np.array(warp['targetAttackSvg']).reshape(-1,2);tri=np.array(warp['triangles']).reshape(-1,3)
    matrix=np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']));origin=np.array(warp['projection']['origin']);original=native@matrix.T+origin
    forward=explicit_warp(original,target-original,tri);backward=explicit_warp(target,original-target,tri);defense_origin=np.array(warp['attackToDefenseSvg']['origin'])
    summaries=[];priorities=[]
    for side,suffix in [('attack',''),('defense','_defense')]:
        svg=Path(f'assets/maps/{name}_map{suffix}.svg')
        if sha(svg)!=warp['art'][side]['sha256']:raise ValueError('Artwork hash differs from frozen display warp')
        summary,priority=sample_side(name,side,svg,source,control_to_full,full_to_original,meta,raw_points,raw_faces,forward,backward,(origin,matrix),defense_origin,folder)
        summaries.append(summary);priorities.extend(priority);print(name,json.dumps(summary),flush=True)
    report=dict(map=name,sides=summaries,seconds=time.perf_counter()-started,sourcePackSha256=sha(control),sourceGeometrySha256=meta['geometrySha256'],sourceMetadataSha256=sha(meta_path),displayWarpSha256=sha(warp_path),
                controlCorrespondenceSha256=sha(control_correspondence),fullCorrespondenceSha256=sha(full_correspondence),sourceCasterSha256=sha(REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll'),runnerSha256=sha(Path(__file__)),
                sampling=dict(spacingSvg=.75,initialAlongSvg=.25,endpointInsetSvg=.001,receiverSideProbeSvg=.5,rayHalfLengthSvg=6,relativeEyeHeightsMeters=HEIGHTS,contactBandSvg=1e-4),
                status='inventory-only-unresolved-semantics',scope=__doc__,limitations=['Three frozen control-relative eye heights do not cover every standing floor layer.','First-contact offsets do not establish wall/opening semantics or source-family ownership.','Probe origins outside the receiver, ambiguous sides and absent contacts remain explicit.','No source filtering by asset or object names; no geometry or production edits.'])
    (folder/'summary.json').write_text(json.dumps(report,indent=2)+'\n');save(folder/'priority.json.gz',priorities)
    return report

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--map',choices=MAPS);parser.add_argument('--output',type=Path,default=REV/'all-map-wall-span-coverage-v1');args=parser.parse_args()
    if args.map:
        try:worker(args.map,args.output)
        except Exception:
            (args.output/args.map/'failure.txt').write_text(traceback.format_exc());raise
        return
    args.output.mkdir(parents=True,exist_ok=False);results=[]
    for name in MAPS:
        with (args.output/f'{name}.log').open('w') as log:
            result=subprocess.run([sys.executable,str(Path(__file__)), '--map',name,'--output',str(args.output)],stdout=log,stderr=subprocess.STDOUT)
        path=args.output/name/'summary.json'
        row=json.loads(path.read_text()) if result.returncode==0 and path.exists() else dict(map=name,status='worker-failed',returnCode=result.returncode)
        results.append(row);(args.output/'summary.json').write_text(json.dumps(dict(scope=__doc__,maps=results,complete=len(results)==len(MAPS)),indent=2)+'\n')
        print(name,row.get('status'),'seconds',row.get('seconds'),flush=True)
    fields=['map','side','authoredSpans','curvedSpans','shortSpans','samplePositions','castRays','contacts','spansWithMeasuredOffset','sourceFaceBindings','sourceInstanceBindings']
    with (args.output/'inventory.csv').open('w',newline='') as stream:
        writer=csv.DictWriter(stream,fieldnames=fields);writer.writeheader()
        for row in results:
            for side in row.get('sides',[]):writer.writerow({key:row['map'] if key=='map' else side[key] for key in fields})

if __name__=='__main__':main()
