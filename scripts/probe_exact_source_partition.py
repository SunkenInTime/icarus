"""Independently diagnose every GEOS union failure in a frozen candidate."""
import argparse,json
from pathlib import Path
import numpy as np
import shapely
from exact_source_partition import prove_partition
from native_compact_wall_profiles import sha


def main(folder):
    folder=Path(folder);proof=json.loads((folder/'bindings.json').read_text());p=folder/'normalized-face-provenance.npz';data=np.load(p);correspondence=np.load(folder/'correspondence.npz')['sourceFaces'];ids=data['generatedFaceIds'];bary=data['generatedBarycentrics'];parents=correspondence[ids];dparents=data['discardedSourceFaces'];dbary=data['discardedBarycentrics'];parents=np.r_[parents,dparents];bary=np.concatenate((bary,dbary));order=np.argsort(parents);starts=np.r_[0,np.flatnonzero(np.diff(parents[order]))+1,len(order)];reference=shapely.Polygon([(0,0),(1,0),(0,1)]);rows=[]
    assert set(parents.tolist())==set(proof['removedControlFaces'])
    for lo,hi in zip(starts[:-1],starts[1:]):
        b=bary[order[lo:hi]];shapes=shapely.polygons(b[:,:,1:]);union=shapely.union_all(shapes);missing=reference.symmetric_difference(union).area*2;overlap=max(0.,shapely.area(shapes).sum()-union.area)*2
        if missing<1e-9 and overlap<1e-9:continue
        parent=int(parents[order[lo]]);print('exact parent',parent,'pieces',len(b),'GEOS',missing,overlap,flush=True);r=prove_partition(b);rows.append(dict(controlParent=parent,geosRelativeMissing=missing,geosRelativeOverlap=overlap,exact=r));print('result',r['passed'],r['relativeSymmetricDifferenceUpperBound']['decimal'],r['relativeOverlapUpperBound']['decimal'],flush=True)
    report=dict(format='icarus-exact-source-partition-control-v1',candidatePackSha256=sha(folder/f"{proof['map']}.height.bin.gz"),provenanceSha256=sha(p),diagnosticSha256=sha(Path(__file__)),exactHelperSha256=sha(Path(__file__).with_name('exact_source_partition.py')),sourceParents=len(starts)-1,geosFailures=len(rows),exactFailures=sum(not r['exact']['passed'] for r in rows),rows=rows,productionMutation=False)
    path=folder/'exact-source-partition-review.json';path.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='rows'},indent=2));assert report['exactFailures']==0


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('folder');main(p.parse_args().folder)
