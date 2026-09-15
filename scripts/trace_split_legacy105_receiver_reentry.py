"""Separate changed exterior rays from visible receiver re-entry at old105."""
import gzip
import json
import hashlib
from pathlib import Path

import numpy as np
import shapely

from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def main():
    out=REV/'split-legacy105-frontier-review-v1'
    report_path=out/'continued-standing-ray-receiver-check.json'
    if report_path.exists():raise FileExistsError(report_path)
    input_path=out/'source-nav-rays.json'
    queries=json.loads(input_path.read_text())
    warp_path=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    source=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    target=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(source,target-source,cells)
    backward=explicit_warp(target,source-target,cells)
    polygons=shapely.polygons(source[cells]);tree=shapely.STRtree(polygons)
    receiver=receiver_domain(Path('assets/maps/split_map.svg'))
    model=NativeReferenceModel(REV/'split-wall-family-normalized-candidate-v29/split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    rows=[]
    for fixture in queries['fixtures']:
        for case in fixture['records']:
            old=case['relativeEye1.75']['sourceControl']
            new=case['relativeEye1.75']['v29']
            if old is None or new is not None:continue
            start=np.asarray(fixture['nativeOrigin'])
            target=(backward.apply(np.array(case['targetSvg']))-origin)@inverse.T
            direction=target-start;direction/=np.linalg.norm(direction)
            hit=model.cast(np.r_[start,1.75],np.r_[start+direction*20,1.75],end_padding=0,end_inclusive=True)
            limit=hit['distanceMeters'] if hit else 20.
            line=shapely.LineString(np.array([start,start+direction*limit])@matrix.T+origin)
            intervals=[]
            for cell in tree.query(line,predicate='intersects'):
                for piece in shapely.get_parts(line.intersection(polygons[cell])):
                    if piece.is_empty or piece.geom_type!='LineString':continue
                    shown=shapely.LineString(forward.apply(shapely.get_coordinates(piece)))
                    for visible in shapely.get_parts(shown.intersection(receiver)):
                        if visible.is_empty or visible.geom_type!='LineString':continue
                        coord=(backward.apply(shapely.get_coordinates(visible))-origin)@inverse.T
                        distance=(coord-start)@direction
                        intervals.append([float(distance.min()),float(distance.max())])
            intervals.sort();merged=[]
            for low,high in intervals:
                if merged and low<=merged[-1][1]+1e-8:
                    merged[-1][1]=max(merged[-1][1],high)
                else:merged.append([low,high])
            rows.append(dict(originId=fixture['id'],targetSvg=case['targetSvg'],oldNearHit=old,
                v29ExtendedHit=hit,visibleReceiverDistanceIntervalsMeters=merged,
                receiverReentryBeforeHit=len(merged)>1))
    sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    report_path.write_text(json.dumps(dict(scope=__doc__,inputSha256=sha(input_path),
        warpSha256=sha(warp_path),svgSha256=sha(Path('assets/maps/split_map.svg')),
        scriptSha256=sha(Path(__file__)),records=rows),indent=2))
    for row in rows:print(row['originId'],row['targetSvg'],row['visibleReceiverDistanceIntervalsMeters'],flush=True)


if __name__=='__main__':main()
