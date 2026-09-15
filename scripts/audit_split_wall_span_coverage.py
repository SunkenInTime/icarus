"""Name-independent first-blocker coverage on every authored Split outline span."""
import gzip
import hashlib
import json
import re
import argparse
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_audit import pack,vector_lines
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from native_reference_cast import NativeReferenceModel

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
OUT=REV/'split-wall-span-coverage-v1'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main(only=None,output=None,pack_override=None):
    global OUT
    if output is not None:OUT=Path(output)
    OUT.mkdir(exist_ok=True)
    control_path=REV/'global-ground-complete-v2/split/split.height.bin.gz'
    source_path=Path(pack_override) if pack_override else control_path
    print('loading control pack',flush=True)
    source=NativeReferenceModel(source_path,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    raw_meta_path=ROOT/'supplemented-v2/world/split/geometry.json';meta=json.loads(raw_meta_path.read_text())
    raw=np.load(raw_meta_path.with_suffix('.npz'));raw_points,raw_faces=raw['points'],raw['faces'];starts=np.array([r['firstFace'] for r in meta['objects']])
    control_to_full=np.load(control_path.parent/'correspondence.npz')['sourceFaces']
    candidate_to_control=np.load(source_path.parent/'correspondence.npz')['sourceFaces'] if pack_override else None
    full_to_original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    warp_path=REV/'display-warps-v1/split.display-warp.json.gz';data=json.loads(gzip.decompress(warp_path.read_bytes()))
    native=np.array(data['sourceNativeMeters']).reshape(-1,2);target=np.array(data['targetAttackSvg']).reshape(-1,2);tri=np.array(data['triangles']).reshape(-1,3)
    projection=data['projection'];matrix=np.column_stack((projection['axisU'],projection['axisV']));origin=np.array(projection['origin']);inverse=np.linalg.inv(matrix)
    original=native@matrix.T+origin
    forward=explicit_warp(original,target-original,tri);backward=explicit_warp(target,original-target,tri)
    svg=Path('assets/maps/split_map.svg');lines=vector_lines(svg);receiver=receiver_domain(svg)
    records=[];face_records={}
    order=only if only is not None else list(range(len(lines)))
    print('casting selected edges',order,flush=True)
    for edge in order:
        line=lines[edge]
        length=float(np.linalg.norm(line[1]-line[0]));axis=(line[1]-line[0])/length;normal=np.array([-axis[1],axis[0]])
        distances=np.unique(np.r_[.001,np.arange(.25,length,.75),length-.001])
        rows=[]
        for distance in distances:
            point=line[0]+axis*distance
            sides=[receiver.covers(shapely.Point(point+sign*.5*normal)) for sign in (-1,1)]
            if sum(sides)!=1:
                rows.append(dict(alongSvg=float(distance),status='receiver-side-ambiguous',receiverSides=sides));continue
            sign=-1 if sides[0] else 1
            endpoints=np.array([point+sign*normal*6,point-sign*normal*6])
            xy=(backward.apply(endpoints)-origin)@inverse.T
            for height in (.75,1.75,2.75):
                hit=source.cast(np.r_[xy[0],height],np.r_[xy[1],height])
                row=dict(alongSvg=float(distance),relativeEyeHeightMeters=height,receiverSign=sign,status='no-control-blocker' if hit is None else 'hit')
                if hit is not None:
                    candidate=int(hit['face']);control=int(candidate_to_control[candidate]) if candidate_to_control is not None else candidate;full=int(control_to_full[control]);original_face=int(full_to_original[full]);obj=int(np.searchsorted(starts,original_face,side='right')-1)
                    xyz=raw_points[raw_faces[original_face]];n=np.cross(xyz[1]-xyz[0],xyz[2]-xyz[0]);n/=np.linalg.norm(n)
                    uv=forward.apply(np.array(hit['point'][:2])@matrix.T+origin);offset=float((uv-point)@normal)
                    row.update(candidateFace=candidate,controlFace=control,fullPackFace=full,originalSourceFace=original_face,sourceObjectIndex=obj,hitSvg=uv.tolist(),inwardGapSvg=offset*sign,sourceNormalZ=float(n[2]),structurallyVertical=bool(abs(n[2])<=.025))
                    if abs(n[2])>.025:row['status']='nonvertical-first-blocker'
                    if abs(offset)>3:row['status']='distant-first-blocker'
                    if original_face not in face_records:
                        path=meta['objects'][obj]['path'];face_records[original_face]=dict(originalSourceFace=original_face,sourceObjectIndex=obj,sourceObject=meta['objects'][obj],verticesNativeMeters=xyz.tolist(),normal=n.tolist(),priorNameGateEligible=bool(re.search('wall|building',path,re.I) and not re.search('floor|stair|ramp|foliage|fence|grate|door|glass|window',path,re.I)))
                rows.append(row)
        solid=[r for r in rows if r['status']=='hit' and r['structurallyVertical']]
        gaps=[abs(r['inwardGapSvg']) for r in solid]
        records.append(dict(svgEdge=edge,lineSvg=line.tolist(),lengthSvg=length,samples=rows,verticalContactSamples=len(solid),maximumAbsoluteGapSvg=max(gaps,default=None),unresolvedSamples=sum(r['status']!='hit' for r in rows),exactContactSamples=sum(g<1e-4 for g in gaps)))
        print('edge',edge,'samples',len(rows),'maxgap',max(gaps,default=None),flush=True)
    report=dict(map='split',sourcePackSha256=sha(source_path),sourceGeometrySha256=meta['geometrySha256'],displayWarpSha256=sha(warp_path),artSha256=sha(svg),scope='Every straight authored dark-fill outline edge >=2 SVG units, sampled each .75 SVG and .001 inside endpoints. Three control relative-eye heights. No object-name gate. This measures first contacts under the frozen control floor policy, not every possible player elevation or proven wall/opening semantics. Unresolved samples remain explicit and are not acceptance.',records=records,sourceFaces=list(face_records.values()))
    (OUT/'coverage.json').write_text(json.dumps(report,indent=2))
    priority=[dict(svgEdge=r['svgEdge'],lineSvg=r['lineSvg'],gap=r['maximumAbsoluteGapSvg'],verticalSamples=r['verticalContactSamples'],unresolved=r['unresolvedSamples']) for r in records if r['maximumAbsoluteGapSvg'] is not None and r['maximumAbsoluteGapSvg']>1e-4]
    (OUT/'priority.json').write_text(json.dumps(priority,indent=2));print('edges',len(records),'misaligned',len(priority),'source faces',len(face_records))
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--edges',nargs='*',type=int);parser.add_argument('--output');parser.add_argument('--pack');args=parser.parse_args();main(args.edges,args.output,args.pack)
