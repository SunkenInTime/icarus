"""Verify event pruning preserves every previously audited cone boundary."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import shapely


def main(root):
    before=root/'cones-unpruned.jsonl'; after=root/'cones.jsonl'
    count=0; maximum=0.; failures=[]; old_vertices=0;new_vertices=0
    with before.open() as a, after.open() as b:
        for left,right in itertools.zip_longest(a,b):
            assert left is not None and right is not None,'Case count changed'
            x,y=json.loads(left),json.loads(right)
            for key in ['id','originSvg','eyeElevationMeters','activeWallIds','rangeSvg','directionRadians','supportId']:
                assert x[key]==y[key],(x['id'],key)
            old=shapely.LineString(x['polygonSvg']+[x['polygonSvg'][0]])
            new=shapely.LineString(y['polygonSvg']+[y['polygonSvg'][0]])
            error=float(shapely.hausdorff_distance(old,new))
            maximum=max(maximum,error);count+=1
            old_vertices+=len(x['polygonSvg']);new_vertices+=len(y['polygonSvg'])
            if error>1e-7: failures.append(dict(id=x['id'],boundaryDifferenceSvg=error))
    report=dict(cones=count,maximumBoundaryDifferenceSvg=maximum,failures=failures,
        verticesBeforePruning=old_vertices,verticesAfterPruning=new_vertices,
        beforeSha256=hashlib.sha256(before.read_bytes()).hexdigest(),
        afterSha256=hashlib.sha256(after.read_bytes()).hexdigest())
    (root/'pruning-equivalence.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report));assert not failures


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);main(p.parse_args().root)
