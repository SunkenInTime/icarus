"""Associate frozen endpoint origins with extracted navigation and body probes.

Tests preserve original SVG XY. Each overlapping navigation floor is recorded
separately; this tool neither chooses a global floor nor certifies pawn collision.
Candidate rays still use the provisional relative-height rendering policy.
"""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from build_global_tactical_candidate import GroundField
from lift_reviewed_wall_source_heights import sha
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp


def audit(candidate, edge, output):
    if output.exists():raise FileExistsError(output)
    rev=candidate.parent
    report_path=candidate/'independent-junction-rays.json'
    frozen=json.loads(report_path.read_text())
    rows=[r for r in frozen['records'] if r['svgEdge']==edge and
          r['relativeEyeHeightMeters']==1.75 and r['status']=='early-unbound-hit']
    if not rows:raise ValueError('No selected frozen rays')
    config_path=candidate/'candidate-config.json'
    config=json.loads(config_path.read_text())['maps']['split']
    warp_path=Path(config['displayWarpFile'])
    assert sha(warp_path)==frozen['displayWarpSha256']
    warp=json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix=np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']))
    origin=np.array(warp['projection']['origin'])
    source=np.array(warp['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    target=np.array(warp['targetAttackSvg']).reshape(-1,2)
    cells=np.array(warp['triangles']).reshape(-1,3)
    backward=explicit_warp(target,source-target,cells)
    forward=explicit_warp(source,target-source,cells)
    native=lambda xy:(backward.apply(np.atleast_2d(xy))-origin)@np.linalg.inv(matrix).T
    ground_path=Path(config['groundFieldFile']);ground=GroundField(ground_path)
    nav_path=rev.parent/'nav/baked/split_navigation.json'
    raw_path=rev.parent/'nav/baked/split_source_xyz.json'
    nav=json.loads(nav_path.read_text());raw=json.loads(raw_path.read_text())
    assert raw['navigationSha256']==sha(nav_path)
    vertices=np.array(raw['vertices']).reshape(-1,3)/100;vertices[:,1]*=-1
    refs=np.array(raw['triangles']).reshape(-1,4)
    tris=vertices[refs[:,1:]]
    shapes=shapely.polygons(tris[:,:,:2])
    valid=np.flatnonzero(np.asarray(nav['walkable'])[refs[:,0]] & (shapely.area(shapes)>1e-10))
    tree=shapely.STRtree(shapes[valid])
    library=rev/'native-tactical-rays-build/Release/tactical_reference_cast.dll'
    complete_path=rev/'split-complete-control-original-height-v29-v2/split.height.bin.gz'
    gate_path=complete_path.parent/'root-independent-composition-review-v2.json'
    gate=json.loads(gate_path.read_text())
    assert gate['passed'] and gate['completePackSha256']==sha(complete_path)
    original=NativeReferenceModel(complete_path,library)
    packed_path=candidate/'split.height.bin.gz'
    assert sha(packed_path)==frozen['candidatePackSha256']
    model=NativeReferenceModel(packed_path,library)
    bindings=json.loads((candidate/'bindings.json').read_text())
    candidate_to_control=np.load(candidate/'correspondence.npz')['sourceFaces']
    control_to_full=np.load(Path(bindings['sourceBackup']).parent/'correspondence.npz')['sourceFaces']
    full_to_raw=np.load(rev/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    metadata_path=rev.parent/'supplemented-v2/world/split/geometry.json'
    objects=json.loads(metadata_path.read_text())['objects']
    starts=np.array([o['firstFace'] for o in objects])
    records=[]
    for row in rows:
        start,end=native([row['startSvg'],row['finishSvg']])
        point=shapely.Point(start);associated=[]
        for tid in valid[tree.query(point,predicate='intersects')]:
            plane=np.linalg.solve(np.c_[tris[tid,:,:2],np.ones(3)],tris[tid,:,2])
            floor=float(start@plane[:2]+plane[2]);feet=np.r_[start,floor]
            body=[]
            for dx,dy in [(0,0),(.12,0),(-.12,0),(0,.12),(0,-.12)]:
                body.append(original.cast(feet+[dx,dy,.2],feet+[dx,dy,1.75]))
            height=floor+1.75-float(ground.heights(start[None])[0])
            hit=model.cast(np.r_[start,height],np.r_[end,height])
            if hit is not None:
                hit['displayedSvg']=forward.apply(np.array(hit['point'][:2])@matrix.T+origin).tolist()
                raw_face=int(full_to_raw[control_to_full[candidate_to_control[hit['face']]]])
                obj=int(np.searchsorted(starts,raw_face,side='right')-1)
                hit.update(rawSourceFace=raw_face,sourceObject=obj,sourceObjectPath=objects[obj]['path'])
            parent=int(refs[tid,0]);shape=shapely.Polygon(vertices[raw['polygons'][parent],:2])
            associated.append(dict(navTriangle=int(tid),navParent=parent,nativeFeet=feet.tolist(),
                parentBoundaryMarginMeters=float(shape.boundary.distance(point)),bodyHits=body,
                fiveVerticalBodyProbesClear=all(h is None for h in body),
                candidateRelativeEye=height,candidateHit=hit))
        records.append(dict(frozenRay=row,navFloorAssociations=associated))
    data=dict(scope=__doc__,edge=edge,candidateSha256=sha(packed_path),
        completeReferenceSha256=sha(complete_path),completeGateSha256=sha(gate_path),
        junctionReportSha256=sha(report_path),groundSha256=sha(ground_path),
        navigationSha256=sha(nav_path),rawNavigationSha256=sha(raw_path),
        displayWarpSha256=sha(warp_path),sourceMetadataSha256=sha(metadata_path),
        scriptSha256=sha(Path(__file__)),records=records)
    output.parent.mkdir(exist_ok=True,parents=True)
    output.write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps(dict(rays=len(records),associations=sum(len(x['navFloorAssociations']) for x in records),
        bodyClear=sum(a['fiveVerticalBodyProbesClear'] for r in records for a in r['navFloorAssociations']))))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate',type=Path);parser.add_argument('edge',type=int)
    parser.add_argument('output',type=Path)
    audit(**vars(parser.parse_args()))
