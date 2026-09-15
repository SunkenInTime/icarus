"""Remove only interior seed points on equivalent opaque source sections.

Queries and atlas sections remain unchanged. Exact source floor and wall planes
define equivalence. Competing floor planes and opacity/contact events retain
their endpoints. This certifies a bounded seed reduction, not angular coverage.
"""
from collections import defaultdict,Counter
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from probe_sheet_transit_certificate import exact_plane_keys
from probe_source_floor_regressions import source_model

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
def canonical(key):
    first=next(value for value in key if value)
    return tuple(-value for value in key) if first<0 else key

def run():
    path=REV/'local-floor-atlas-v1/split.npz';data=np.load(path);source=source_model(REV,'split',True)
    cells=np.repeat(np.arange(len(data['planes'])),data['segmentRanges'][:,1]);source_ids=data['sourceFaces']
    actual=np.flatnonzero(source_ids>=0)
    floor_keys=dict(zip(actual,[canonical(k) for k in exact_plane_keys(source.arrays['vertices'][source.arrays['faces'][source_ids[actual]]])]))
    wall_keys=[canonical(k) for k in exact_plane_keys(source.arrays['vertices'][source.arrays['faces'][data['segmentFaces']]])]
    floor_polygons=np.array([shapely.Polygon(data['polygons'][start:start+count]) for start,count in data['polygonRanges']],dtype=object)
    tree=shapely.STRtree(floor_polygons)
    groups=defaultdict(list)
    keep=np.ones((len(cells),2),dtype=bool);reasons=Counter();removed=[]
    for segment,cell in enumerate(cells):
        if source.arrays['faceMasks'][data['segmentFaces'][segment]]>=0 or not data['segmentEndpointClosed'][segment].all():
            reasons['opacity-event']+=2;continue
        line=data['segments'][segment]
        if np.array_equal(*line):reasons['point-contact']+=2;continue
        groups[(floor_keys[cell],wall_keys[segment])].append(segment)
    for (floor_key,wall_key),ids in groups.items():
        if len(ids)<2:reasons['no-equivalent-section']+=2;continue
        representative=data['segments'][ids[0]];vector=representative[1]-representative[0];vector/=np.linalg.norm(vector)
        intervals=np.sort(data['segments'][ids]@vector,axis=1)
        for local,segment in enumerate(ids):
            for endpoint,point in enumerate(data['segments'][segment]):
                t=float(point@vector)
                # A strictly covering section makes this endpoint redundant.
                # Touching joins remain: their exact endpoint ownership may differ.
                covers=np.flatnonzero((intervals[:,0]<t-1e-10)&(intervals[:,1]>t+1e-10))
                touching=False
                if not len(covers):
                    # A closed touching join is also interior when both sides
                    # meet at the identical stored XY, not a tolerance-snapped point.
                    left=[];right=[]
                    for candidate,candidate_segment in enumerate(ids):
                        candidate_line=data['segments'][candidate_segment]
                        if not np.any(np.all(candidate_line==point,axis=1)):continue
                        if intervals[candidate,0]<t and intervals[candidate,1]==t:left.append(candidate)
                        if intervals[candidate,0]==t and intervals[candidate,1]>t:right.append(candidate)
                    if left and right:
                        covers=np.array(left+right,dtype=int);touching=True
                    else:reasons['coverage-boundary']+=1;continue
                nearby=tree.query(shapely.Point(point).buffer(1e-9),predicate='intersects')
                different=[int(cell) for cell in nearby if source_ids[cell]>=0 and floor_keys[cell]!=floor_key]
                if different:reasons['competing-floor-state']+=1;continue
                # Confirm the coincident source sections really share XY here.
                lines=data['segments'][np.array(ids)[covers]]
                residual=np.abs((point[0]-lines[:,0,0])*(lines[:,1,1]-lines[:,0,1])-(point[1]-lines[:,0,1])*(lines[:,1,0]-lines[:,0,0]))/np.linalg.norm(lines[:,1]-lines[:,0],axis=1)
                if residual.min()>1e-10:reasons['numeric-line-disagreement']+=1;continue
                keep[segment,endpoint]=False
                removed.append(dict(segment=int(segment),endpoint=endpoint,point=point.tolist(),sourceFace=int(data['segmentFaces'][segment]),floorSourceFace=int(source_ids[cells[segment]]),coveringSections=[int(ids[i]) for i in covers],closedTouchingJoin=touching,lineResidualMeters=float(residual.min())))
    output=REV/'redundant-section-seeds-v1';output.mkdir(exist_ok=True)
    np.savez_compressed(output/'split.npz',keepEndpoints=keep)
    report=dict(atlasSha256=hashlib.sha256(path.read_bytes()).hexdigest(),compilerSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),sectionCount=len(cells),equivalentGroups=len(groups),endpointsBefore=int(keep.size),endpointsAfter=int(keep.sum()),uniquePointsBefore=len(np.unique(data['segments'].reshape(-1,2),axis=0)),uniquePointsAfter=len(np.unique(data['segments'][keep],axis=0)),retainedReasons=dict(reasons),removed=removed,
                limitation='Closed opaque interior events only, including identical-XY closed joins; preserve all competing physical floor planes, opacity states and source queries. No full-cone angular completeness claim.')
    (output/'split.json').write_text(json.dumps(report,indent=2)+'\n')
    print({key:value for key,value in report.items() if key!='removed'},flush=True)
if __name__=='__main__':run()
