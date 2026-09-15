"""Five frozen jamb rays, current ground versus straight source-height sightlines."""
import gzip,json
from pathlib import Path
import numpy as np
import shapely
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from native_reference_cast import NativeReferenceModel
from tactical_alignment_audit import pack

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
C=REV/'split-wall-family-normalized-candidate-v32-precise-v1'
frozen=json.loads((C/'vent-left-jamb-shadow-detail.json').read_text())
nav=json.loads((C/'vent-jamb-ground-nav.json').read_text())
q=np.array(frozen['query']);eye=nav[0]['originalWalkableNav'][0]['floor']+1.75
g=GroundField(REV/'global-ground-complete-v2/split/split.tactical-ground.json.gz')
w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
s=np.array(w['sourceNativeMeters']).reshape(-1,2);t=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3)
fw=explicit_warp(s,t-s,cells);bw=explicit_warp(t,s-t,cells)
caster=NativeReferenceModel(C/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
_,control=pack(REV/'global-ground-complete-v2/split/split.height.bin.gz')
p=np.load(C/'normalized-face-provenance.npz');generated={int(v):i for i,v in enumerate(p['generatedFaceIds'])}
parents=np.load(C/'correspondence.npz')['sourceFaces'];control_to_full=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];full_to_raw=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
meta=json.loads((REV.parent/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([o['firstFace']for o in meta['objects']])

def enrich(hit):
    if hit is None:return None
    face=hit['face'];parent=int(parents[face]);raw=int(full_to_raw[control_to_full[parent]]);row=generated.get(face)
    triangle=caster.arrays['vertices'][caster.arrays['faces'][face]];point=np.array(hit['point'])
    uv=np.linalg.lstsq((triangle[1:]-triangle[0]).T,point-triangle[0],rcond=None)[0];bary=np.r_[1-uv.sum(),uv]
    cb=bary@p['generatedBarycentrics'][row]if row is not None else bary
    original=control['vertices'][control['faces'][parent]].copy();original[:,2]+=g.heights(original[:,:2]);source=cb@original
    hit.update(rawSourceFace=raw,sourceObject=int(np.searchsorted(starts,raw,side='right')-1),family=int(p['generatedEdges'][row])if row is not None else -1,
        displaySvg=fw.apply(point[None,:2])[0].tolist(),originalSourcePoint=source.tolist(),groundAtMappedHit=float(g.heights(point[None,:2])[0]),sourceVsMappedGroundHeightDifference=float(source[2]-(point[2]+g.heights(point[None,:2])[0])))
    return hit

def straight(endxy,end_z):
    delta=endxy-q[:2];line=shapely.LineString([q[:2],endxy]);events=[0.,1.]
    for cell in g.tree.query(line,predicate='intersects'):
        for xy in shapely.get_coordinates(line.intersection(g.polygons[cell])):
            events.append(float(np.clip((xy-q[:2])@delta/(delta@delta),0,1)))
    events=np.unique(events);pieces=[]
    for lo,hi in zip(events,events[1:]):
        if hi-lo<1e-12:continue
        xy=q[:2]+np.array([lo,hi])[:,None]*delta;cell=g.locate(xy.mean(0)[None])[0];ground=xy@g.planes[cell,:2]+g.planes[cell,2]
        z=eye+np.array([lo,hi])*(end_z-eye)-ground
        hit=caster.cast(np.r_[xy[0],z[0]],np.r_[xy[1],z[1]],min_distance=1e-5 if lo==0 else 0.,end_padding=0.,end_inclusive=True)
        pieces.append(dict(parameter=[lo,hi],cell=int(cell),ground=ground.tolist(),relativeZ=z.tolist()))
        if hit:return dict(hit=enrich(hit),pieces=pieces)
    return dict(hit=None,pieces=pieces)

rows=[]
for record in frozen['records']:
    end=bw.apply(np.array(record['targetSvg'])[None])[0];target_floor=float(g.heights(end[None])[0])
    corrected_relative=eye-nav[0]['currentGround']
    rows.append(dict(targetSvg=record['targetSvg'],endNative=end.tolist(),targetFloorProvisional=target_floor,
        current=record['hit'],navOriginFloorFollowing=enrich(caster.cast(np.r_[q[:2],corrected_relative],np.r_[end,corrected_relative],end_padding=0,end_inclusive=True)),
        straightTargetHead=straight(end,target_floor+1.75),straightHorizontal=straight(end,eye)))
report=dict(scope=__doc__,standingEye=eye,originNav=nav[0],rows=rows,
    limits='Target strips have no walkable nav association. Target head uses provisional local6.5m ground. Piecewise straight rays subtract ground at mapped XY; each hit records exact recovered original source Z and mapping offset. No pack or app mutation.')
(C/'vent-jamb-five-ray-height-review.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(eye=eye,rows=[dict(targetSvg=r['targetSvg'],current=r['current']['displaySvg']if r['current']else None,navCorrected=r['navOriginFloorFollowing'],straightHead=r['straightTargetHead']['hit'],horizontal=r['straightHorizontal']['hit'])for r in rows]),indent=2))
